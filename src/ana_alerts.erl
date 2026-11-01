%% Alert rules and silences (spec 019, RF-019-08, T-019-08b): what the
%% administrator configures; ana_health evaluates them every 10 s.
-module(ana_alerts).
-export([overview/0, save_rule/2, delete_rule/2, create_silence/2, end_silence/2]).
-export([validate_rule/1]).

-define(EMAIL, "^[^@\\s]{1,64}@[^@\\s]{1,190}\\.[^@\\s]{2,}$").

overview() ->
    {ok, Rules} = ana_db:rows("SELECT id, name, source, target, level, op, threshold::float8 AS threshold, window_s, "
                              "  severity, notify_studio, connector, recipients, active, updated_by, updated_at, "
                              "  (SELECT count(*) FROM ana_system.incident i WHERE i.rule_id = r.id AND i.closed_at IS NULL) AS open "
                              "FROM ana_system.alert_rule r ORDER BY name", []),
    {ok, Silences} = ana_db:rows("SELECT s.id, s.rule_id, r.name AS rule, s.target, s.node, s.starts_at, s.ends_at, s.reason, "
                                 "  s.created_by, (s.starts_at <= now() AND s.ends_at > now()) AS in_force "
                                 "FROM ana_system.alert_silence s LEFT JOIN ana_system.alert_rule r ON r.id = s.rule_id "
                                 "WHERE s.ends_at > now() - interval '7 days' ORDER BY s.ends_at DESC LIMIT 200", []),
    {ok, Connectors} = ana_db:rows("SELECT name, description FROM integration.connector WHERE kind = 'http_api' "
                                   "AND outbound_program IS NOT NULL AND active ORDER BY name", []),
    {ok, #{rules => Rules, silences => Silences, connectors => Connectors,
           components => ana_health:components_names(), metrics => ana_health:metric_names()}}.

%% New when there is no id; every change is recorded in the administration log.
save_rule(Body, #{username := Who}) ->
    case validate_rule(Body) of
        {error, _} = E -> E;
        {ok, R} ->
            Args = [maps:get(K, R) || K <- [name, source, target, level, op, threshold, window_s, severity,
                                            notify_studio, connector, recipients, active]] ++ [Who],
            Result = case maps:get(<<"id">>, Body, null) of
                null ->
                    ana_db:one("INSERT INTO ana_system.alert_rule (name, source, target, level, op, threshold, window_s, "
                               "  severity, notify_studio, connector, recipients, active, updated_by) "
                               "VALUES ($1, $2, $3, $4, $5, $6::text::numeric, $7, $8, $9, $10, $11, $12, $13) "
                               "RETURNING id", Args);
                Id when is_integer(Id) ->
                    ana_db:one("UPDATE ana_system.alert_rule SET name = $1, source = $2, target = $3, level = $4, op = $5, "
                               "  threshold = $6::text::numeric, window_s = $7, severity = $8, notify_studio = $9, "
                               "  connector = $10, recipients = $11, active = $12, updated_by = $13, updated_at = now() "
                               "WHERE id = $14 RETURNING id", Args ++ [Id]);
                _ -> {error, <<"id inválido"/utf8>>}
            end,
            case Result of
                {ok, #{<<"id">> := NewId}} ->
                    ana_admin:log(Who, <<"alert.rule.save">>, integer_to_binary(NewId), null, R),
                    {ok, #{id => NewId}};
                {ok, undefined} -> {error, not_found};
                {error, #{sqlstate := <<"23505">>}} -> {error, <<"já existe uma regra com esse nome"/utf8>>};
                {error, _} -> {error, <<"não foi possível salvar a regra"/utf8>>}
            end
    end.

%% Incidents keep their history (rule_id becomes empty); open ones are closed first,
%% since nothing could match them afterwards.
delete_rule(Id, #{username := Who}) ->
    _ = ana_db:exec("UPDATE ana_system.incident SET closed_at = now() WHERE rule_id = $1 AND closed_at IS NULL", [Id]),
    case ana_db:one("DELETE FROM ana_system.alert_rule WHERE id = $1 RETURNING name", [Id]) of
        {ok, undefined} -> {error, not_found};
        {ok, #{<<"name">> := Name}} ->
            ana_admin:log(Who, <<"alert.rule.delete">>, integer_to_binary(Id), #{name => Name}, null),
            {ok, #{deleted => Id}}
    end.

validate_rule(B) ->
    Source = maps:get(<<"source">>, B, null),
    Target = maps:get(<<"target">>, B, null),
    Threshold = maps:get(<<"threshold">>, B, null),
    Recipients = maps:get(<<"recipients">>, B, []),
    Connector = case maps:get(<<"connector">>, B, null) of <<>> -> null; C -> C end,
    Checks = [
        {is_binary(maps:get(<<"name">>, B, null)) andalso string:length(string:trim(maps:get(<<"name">>, B))) >= 3
             andalso string:length(maps:get(<<"name">>, B)) =< 120,
         <<"informe um nome (3 a 120 caracteres)"/utf8>>},
        {lists:member(Source, [<<"health">>, <<"metric">>]), <<"origem deve ser saúde ou métrica"/utf8>>},
        {Source =/= <<"health">> orelse lists:member(Target, [<<"*">> | ana_health:components_names()]),
         <<"componente desconhecido"/utf8>>},
        {Source =/= <<"health">> orelse lists:member(maps:get(<<"level">>, B, null), [<<"yellow">>, <<"red">>]),
         <<"nível deve ser amarelo ou vermelho"/utf8>>},
        {Source =/= <<"metric">> orelse lists:member(Target, ana_health:metric_names()), <<"métrica desconhecida"/utf8>>},
        {Source =/= <<"metric">> orelse lists:member(maps:get(<<"op">>, B, null), [<<">">>, <<">=">>, <<"<">>, <<"<=">>]),
         <<"comparação inválida"/utf8>>},
        {Source =/= <<"metric">> orelse is_number(Threshold), <<"informe o limiar (número)"/utf8>>},
        {is_integer(maps:get(<<"window_s">>, B, 0)) andalso maps:get(<<"window_s">>, B, 0) >= 0
             andalso maps:get(<<"window_s">>, B, 0) =< 86400, <<"janela deve ficar entre 0 e 86400 s"/utf8>>},
        {lists:member(maps:get(<<"severity">>, B, <<"warning">>), [<<"info">>, <<"warning">>, <<"serious">>, <<"critical">>]),
         <<"gravidade inválida"/utf8>>},
        {is_list(Recipients) andalso length(Recipients) =< 50
             andalso lists:all(fun(E) -> is_binary(E) andalso re:run(E, ?EMAIL, [unicode]) =/= nomatch end, Recipients),
         <<"destinatários devem ser e-mails válidos (até 50)"/utf8>>},
        {Recipients =:= [] orelse Connector =/= null, <<"e-mails precisam de um conector que os entregue"/utf8>>},
        {Connector =:= null orelse delivers(Connector),
         <<"o conector precisa estar ativo, ser de API HTTP e ter programa de saída"/utf8>>}],
    case [Msg || {false, Msg} <- Checks] of
        [Msg | _] -> {error, Msg};
        [] ->
            Health = Source =:= <<"health">>,
            {ok, #{name => string:trim(maps:get(<<"name">>, B)), source => Source, target => Target,
                   level => case Health of true -> maps:get(<<"level">>, B); false -> null end,
                   op => case Health of true -> null; false -> maps:get(<<"op">>, B) end,
                   threshold => case Health of true -> null; false -> number_text(Threshold) end,
                   window_s => maps:get(<<"window_s">>, B, 0),
                   severity => maps:get(<<"severity">>, B, <<"warning">>),
                   notify_studio => maps:get(<<"notify_studio">>, B, true) =/= false,
                   connector => Connector, recipients => Recipients,
                   active => maps:get(<<"active">>, B, true) =/= false}}
    end.

delivers(Name) when is_binary(Name) ->
    case ana_db:one("SELECT 1 AS ok FROM integration.connector WHERE name = $1 AND kind = 'http_api' "
                    "AND outbound_program IS NOT NULL AND active", [Name]) of
        {ok, #{<<"ok">> := 1}} -> true;
        _ -> false
    end;
delivers(_) -> false.

number_text(N) when is_integer(N) -> integer_to_binary(N);
number_text(N) when is_float(N) -> float_to_binary(N, [short]).

%% A silence for a rule, a target, a node or any combination (empty = all); at most 30 days.
create_silence(B, #{username := Who}) ->
    Rule = maps:get(<<"rule_id">>, B, null),
    Opt = fun(K) -> case maps:get(K, B, null) of <<>> -> null; V -> V end end,
    Minutes = maps:get(<<"minutes">>, B, null),
    Reason = maps:get(<<"reason">>, B, <<>>),
    if
        not (Rule =:= null orelse is_integer(Rule)) -> {error, <<"regra inválida"/utf8>>};
        not (is_integer(Minutes) andalso Minutes >= 1 andalso Minutes =< 43200) ->
            {error, <<"duração deve ficar entre 1 minuto e 30 dias"/utf8>>};
        not is_binary(Reason) -> {error, <<"informe o motivo"/utf8>>};
        true ->
            case string:length(string:trim(Reason)) >= 3 of
                false -> {error, <<"informe o motivo (ao menos 3 caracteres)"/utf8>>};
                true ->
                    case ana_db:one("INSERT INTO ana_system.alert_silence (rule_id, target, node, ends_at, reason, created_by) "
                                    "VALUES ($1, $2, $3, now() + make_interval(mins => $4), $5, $6) RETURNING id, ends_at",
                                    [Rule, Opt(<<"target">>), Opt(<<"node">>), Minutes, string:trim(Reason), Who]) of
                        {ok, Row = #{<<"id">> := Id}} ->
                            ana_admin:log(Who, <<"alert.silence">>, integer_to_binary(Id), null,
                                          maps:with([<<"rule_id">>, <<"target">>, <<"node">>, <<"minutes">>, <<"reason">>], B)),
                            {ok, Row};
                        {error, #{sqlstate := <<"23503">>}} -> {error, not_found};
                        {error, #{sqlstate := <<"23514">>}} -> {error, <<"alvo inválido"/utf8>>};
                        {error, _} -> {error, <<"não foi possível criar o silêncio"/utf8>>}
                    end
            end
    end.

%% Ended, not deleted: the silence stays as history.
end_silence(Id, #{username := Who}) ->
    case ana_db:one("UPDATE ana_system.alert_silence SET ends_at = GREATEST(now(), starts_at + interval '1 second') "
                    "WHERE id = $1 AND ends_at > now() RETURNING id", [Id]) of
        {ok, undefined} -> {error, not_found};
        {ok, _} ->
            ana_admin:log(Who, <<"alert.silence.end">>, integer_to_binary(Id), null, null),
            {ok, #{ended => Id}}
    end.
