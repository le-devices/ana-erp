%% SPDX-FileCopyrightText: 2026 LE Devices
%% SPDX-License-Identifier: AGPL-3.0-or-later
%% Connector administration (spec 017, RF-017-01/02/09). Admin only; every change
%% goes to admin_log. Secrets are write-only: the API reports which keys exist.
-module(ana_connectors).
-export([list/0, save/3, remove/2, put_secret/4, delete_secret/3, smtp_test/3]).

-define(FIELDS, [<<"description">>, <<"kind">>, <<"base_url">>, <<"auth">>, <<"api_key_header">>, <<"token_url">>,
                 <<"allowed_hosts">>, <<"timeout_ms">>, <<"rate_per_min">>, <<"outbound_program">>,
                 <<"inbound_program">>, <<"signature_header">>, <<"timestamp_header">>, <<"event_id_header">>,
                 <<"replay_window_s">>, <<"max_attempts">>, <<"run_as">>, <<"active">>, <<"options">>,
                 <<"default_email">>]).

list() ->
    {ok, Rows} = ana_db:rows(
        "SELECT c.name, c.description, c.kind, c.base_url, c.auth, c.api_key_header, c.token_url, c.allowed_hosts, "
        "  c.timeout_ms, c.rate_per_min, c.outbound_program, c.inbound_program, c.signature_header, c.timestamp_header, "
        "  c.event_id_header, c.replay_window_s, c.max_attempts, c.run_as, c.active, c.options, c.updated_at, c.updated_by, "
        "  c.default_email, "
        "  COALESCE((SELECT jsonb_agg(jsonb_build_object('key', s.key, 'expires_at', s.expires_at, "
        "     'expiring', s.expires_at < current_date + 30) ORDER BY s.key) "
        "   FROM integration.secret s WHERE s.connector = c.name), '[]') AS secrets "
        "FROM integration.connector c ORDER BY c.name", []),
    {ok, #{connectors => Rows, vault => ana_vault:enabled()}}.

save(Name, Body, #{username := Who}) ->
    case {re:run(Name, "^[a-z][a-z0-9_]{1,62}$", [{capture, none}]), smtp_ok(Name, Body)} of
        {nomatch, _} -> {error, <<"nome inválido: letras minúsculas, números e _"/utf8>>};
        {_, {error, M}} -> {error, M};
        {match, ok} ->
            V = [maps:get(F, Body, null) || F <- ?FIELDS],
            Options = case maps:get(<<"options">>, Body, #{}) of
                O when is_map(O) -> iolist_to_binary(json:encode(O));
                _ -> <<"{}">>
            end,
            Hosts = case maps:get(<<"allowed_hosts">>, Body, []) of
                L when is_list(L) -> [string:lowercase(H) || H <- L, is_binary(H), H =/= <<>>];
                _ -> []
            end,
            {ok, Before} = ana_db:one("SELECT to_jsonb(c) - 'updated_at' AS row FROM integration.connector c WHERE name = $1",
                                      [Name]),
            %% Spec 044 (D4): at most one default e-mail connector; choosing another moves the mark.
            Default = maps:get(<<"default_email">>, Body, false) =:= true,
            _ = Default andalso ana_db:exec("UPDATE integration.connector SET default_email = false "
                                            "WHERE default_email AND name <> $1", [Name]) =/= ok,
            R = ana_db:exec(
                "INSERT INTO integration.connector (name, description, kind, base_url, auth, api_key_header, token_url, "
                "  allowed_hosts, timeout_ms, rate_per_min, outbound_program, inbound_program, signature_header, "
                "  timestamp_header, event_id_header, replay_window_s, max_attempts, run_as, active, options, updated_by, default_email) "
                "VALUES ($1, COALESCE($2, ''), $3, $4, COALESCE($5, 'none'), COALESCE($6, 'X-API-Key'), $7, $8, "
                "  COALESCE($9::int, 15000), COALESCE($10::int, 600), $11, $12, COALESCE($13, 'X-Signature'), "
                "  COALESCE($14, 'X-Timestamp'), COALESCE($15, 'X-Event-Id'), COALESCE($16::int, 300), "
                "  COALESCE($17::int, 8), COALESCE($18, 'system'), COALESCE($19::boolean, true), "
                "  COALESCE($20::text::jsonb, '{}'), $21, COALESCE($22::boolean, false)) "
                "ON CONFLICT (name) DO UPDATE SET description = EXCLUDED.description, kind = EXCLUDED.kind, "
                "  base_url = EXCLUDED.base_url, auth = EXCLUDED.auth, api_key_header = EXCLUDED.api_key_header, "
                "  token_url = EXCLUDED.token_url, allowed_hosts = EXCLUDED.allowed_hosts, timeout_ms = EXCLUDED.timeout_ms, "
                "  rate_per_min = EXCLUDED.rate_per_min, outbound_program = EXCLUDED.outbound_program, "
                "  inbound_program = EXCLUDED.inbound_program, signature_header = EXCLUDED.signature_header, "
                "  timestamp_header = EXCLUDED.timestamp_header, event_id_header = EXCLUDED.event_id_header, "
                "  replay_window_s = EXCLUDED.replay_window_s, max_attempts = EXCLUDED.max_attempts, "
                "  run_as = EXCLUDED.run_as, active = EXCLUDED.active, options = EXCLUDED.options, updated_at = now(), "
                "  updated_by = EXCLUDED.updated_by, default_email = EXCLUDED.default_email",
                [Name | lists:sublist(V, 6)] ++ [Hosts | lists:sublist(lists:nthtail(7, V), 11)] ++ [Options, Who, Default]),
            case R of
                {ok, _} ->
                    ok = ana_admin:log(Who, <<"connector.save">>, Name, case Before of undefined -> null; #{<<"row">> := B} -> B end,
                                       maps:with(?FIELDS, Body)),
                    {ok, #{name => Name}};
                {error, #{message := M}} -> {error, M};
                {error, _} -> {error, <<"dados inválidos"/utf8>>}
            end
    end.

remove(Name, #{username := Who}) ->
    case ana_db:exec("UPDATE integration.connector SET active = false, updated_at = now(), updated_by = $2 WHERE name = $1",
                     [Name, Who]) of
        {ok, 0} -> {error, not_found};
        {ok, _} -> ok = ana_admin:log(Who, <<"connector.deactivate">>, Name, null, null), {ok, #{name => Name}}
    end.

put_secret(Name, Key, #{<<"value">> := Value} = B, #{username := Who}) when is_binary(Value) ->
    case ana_vault:store(Name, Key, Value, maps:get(<<"expires_at">>, B, null), Who) of
        ok ->
            ok = ana_admin:log(Who, <<"connector.secret">>, <<Name/binary, ":", Key/binary>>, null,
                               #{expires_at => maps:get(<<"expires_at">>, B, null)}),   % never the value
            {ok, #{connector => Name, key => Key}};
        {error, M} -> {error, M}
    end;
put_secret(_, _, _, _) -> {error, <<"informe o valor do segredo"/utf8>>}.

delete_secret(Name, Key, #{username := Who}) ->
    ok = ana_vault:delete(Name, Key),
    ok = ana_admin:log(Who, <<"connector.secret_delete">>, <<Name/binary, ":", Key/binary>>, null, null),
    {ok, #{connector => Name, key => Key}}.

%% Spec 044: the SMTP settings are complete and safe before saving (sending with them comes later).
smtp_ok(Name, #{<<"kind">> := <<"smtp">>} = B) ->
    Auth = maps:get(<<"auth">>, B, <<"none">>),
    case lists:member(Auth, [null, <<"none">>, <<"basic">>]) of
        false -> {error, <<"e-mail (SMTP) usa autenticação nenhuma ou usuário e senha"/utf8>>};
        true ->
            case ana_smtp:config(#{<<"name">> => Name, <<"options">> => maps:get(<<"options">>, B, #{}),
                                   <<"timeout_ms">> => 15000, <<"auth">> => Auth}) of
                {ok, _} -> ok;
                E -> E
            end
    end;
smtp_ok(_, #{<<"default_email">> := true}) -> {error, <<"só um conector de e-mail (SMTP) pode ser o padrão"/utf8>>};
smtp_ok(_, _) -> ok.

%% "Testar conexão" (no To) and "Enviar e-mail de teste" (with To), answered at once (RF-044-01).
smtp_test(Name, Body, #{username := Who}) ->
    case ana_db:one("SELECT name, kind, auth, timeout_ms, options FROM integration.connector WHERE name = $1", [Name]) of
        {ok, #{<<"kind">> := <<"smtp">>} = C} ->
            case ana_smtp:config(C) of
                {error, M} -> {error, M};
                {ok, Cfg} ->
                    To = maps:get(<<"to">>, Body, null),
                    R = case To of
                        null -> ana_smtp:test(Cfg);
                        _ -> case ana_smtp:valid_address(To) of
                                 true -> ana_smtp:send_test(Cfg, To, Who);
                                 false -> {error, #{<<"message">> => <<"destinatário inválido"/utf8>>}}
                             end
                    end,
                    ok = ana_admin:log(Who, <<"connector.smtp_test">>, Name, null, #{to => To, ok => element(1, R) =:= ok}),
                    case R of
                        {ok, Info} -> {ok, Info};
                        {error, #{<<"message">> := M}} -> {error, M}
                    end
            end;
        {ok, #{}} -> {error, <<"o conector não é de e-mail (SMTP)"/utf8>>};
        _ -> {error, not_found}
    end.
