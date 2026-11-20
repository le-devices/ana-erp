%% Day-to-day administration (spec 011).
%%
%% Users (RF-011-02), groups (RF-011-04), company (RF-011-06), default accounts
%% (RF-011-07), audit (RF-011-09). Every change is recorded in admin_log
%% (RNF-011-01) without secrets (RNF-011-02).
-module(ana_admin).
-export([scope_preview/1,
         log/5,
         list_users/1, get_user/1, create_user/2, update_user/3, reset_password/2,
         revoke_sessions/2, unlock_user/2, unlock_ip/2, list_keys/1, create_key/3, revoke_key/2,
         list_groups/0, save_group/3, delete_group/2,
         get_company/0, save_company/2, save_logo/2, logo/0,
         list_default_accounts/0, save_default_account/3,
         list_remote_systems/0, save_remote_system/3,
         audit_executions/1, audit_logins/1, audit_changes/1, audit_tasks/1,
         audit_access/1, audit_trail/1, audit_execution/1]).

-define(ROLES, [<<"admin">>, <<"developer">>, <<"user">>]).

%% ==========================================================================
%% Admin log
%% ==========================================================================

log(Who, Action, Target, Before, After) ->
    _ = ana_db:exec(
        "INSERT INTO ana_system.admin_log (username, action, target, before, after) "
        "VALUES ($1, $2, $3, $4::text::jsonb, $5::text::jsonb)",
        [Who, Action, Target, json_text(Before), json_text(After)]),
    ok.

json_text(null) -> null;
json_text(undefined) -> null;
json_text(V) -> iolist_to_binary(json:encode(V)).

%% ==========================================================================
%% Users
%% ==========================================================================

list_users(Filter) ->
    Search = case maps:get(<<"search">>, Filter, <<>>) of
        <<>> -> null;
        S -> <<"%", S/binary, "%">>
    end,
    ana_db:rows(
        "SELECT u.username, u.name, u.role, u.kind, u.builtin, u.active, u.must_change_password, u.created_at, "
        "       u.last_login_at, u.party_id, COALESCE(array_agg(ug.group_name ORDER BY ug.group_name) "
        "         FILTER (WHERE ug.group_name IS NOT NULL), '{}') AS groups "
        "FROM ana_system.app_user u LEFT JOIN ana_system.user_group ug USING (username) "
        "WHERE ($1::text IS NULL OR u.username ILIKE $1 OR u.name ILIKE $1) "
        "GROUP BY u.username ORDER BY u.username", [Search]).

get_user(Username) ->
    case list_users(#{<<"search">> => Username}) of
        {ok, Rows} ->
            case [R || R = #{<<"username">> := U} <- Rows, U =:= Username] of
                [R] -> {ok, R};
                [] -> {error, not_found}
            end;
        E -> E
    end.

%% Returns the generated password once when none was given (RNF-011-02).
create_user(Fields = #{<<"kind">> := <<"robot">>}, #{username := Who}) ->
    %% RF-011-12: no password (unusable random hash), never admin.
    Username = maps:get(<<"username">>, Fields, <<>>),
    Role = maps:get(<<"role">>, Fields, <<"user">>),
    case lists:member(Role, [<<"developer">>, <<"user">>]) of
        false -> {error, <<"robôs não podem ter papel admin"/utf8>>};
        true ->
            case ana_db:exec(
                   "INSERT INTO ana_system.app_user (username, name, password_hash, role, kind, must_change_password) "
                   "VALUES ($1, $2, $3, $4, 'robot', false)",
                   [Username, maps:get(<<"name">>, Fields, <<>>),
                    <<"robot$", (base64:encode(crypto:strong_rand_bytes(24)))/binary>>, Role]) of
                {ok, _} ->
                    ok = set_groups(Username, maps:get(<<"groups">>, Fields, [])),
                    log(Who, <<"user.create_robot">>, Username, null, maps:without([<<"password">>], Fields)),
                    {ok, #{username => Username, kind => <<"robot">>}};
                {error, #{sqlstate := <<"23505">>}} -> {error, <<"login já existe"/utf8>>};
                {error, #{sqlstate := <<"23514">>}} -> {error, <<"login inválido"/utf8>>};
                {error, E} -> {error, E}
            end
    end;
%% Spec 016 (RF-016-04): external portal account, tied to a customer/supplier.
create_user(Fields = #{<<"role">> := <<"external">>}, #{username := Who}) ->
    Username = maps:get(<<"username">>, Fields, <<>>),
    Party = maps:get(<<"party_id">>, Fields, null),
    {Password, Generated} = case maps:get(<<"password">>, Fields, null) of
        P when is_binary(P), P =/= <<>> -> {P, false};
        _ -> {generate_password(), true}
    end,
    case {is_integer(Party), ana_security:check_policy(Username, Password)} of
        {false, _} -> {error, <<"conta externa exige o cliente/fornecedor (party_id)"/utf8>>};
        {_, {error, _} = E} -> E;
        {true, ok} ->
            case ana_db:exec(
                   "INSERT INTO ana_system.app_user (username, name, password_hash, role, party_id, must_change_password) "
                   "SELECT $1, $2, $3, 'external', $4, true WHERE EXISTS (SELECT 1 FROM base.party WHERE id = $4 AND active)",
                   [Username, maps:get(<<"name">>, Fields, <<>>), ana_security:hash_password(Password), Party]) of
                {ok, 1} ->
                    log(Who, <<"user.create_external">>, Username, null, maps:without([<<"password">>], Fields)),
                    {ok, case Generated of
                             true -> #{username => Username, password => Password};
                             false -> #{username => Username}
                         end};
                {ok, 0} -> {error, <<"cliente/fornecedor inexistente ou inativo"/utf8>>};
                {error, #{sqlstate := <<"23505">>}} -> {error, <<"login já existe"/utf8>>};
                {error, #{sqlstate := <<"23514">>}} -> {error, <<"login inválido"/utf8>>};
                {error, E} -> {error, E}
            end
    end;
create_user(Fields, #{username := Who}) ->
    Username = maps:get(<<"username">>, Fields, <<>>),
    Role = maps:get(<<"role">>, Fields, <<"user">>),
    {Password, Generated} = case maps:get(<<"password">>, Fields, null) of
        P when is_binary(P), P =/= <<>> -> {P, false};
        _ -> {generate_password(), true}
    end,
    case lists:member(Role, ?ROLES) andalso ana_license:seat() of
        false -> {error, <<"papel inválido"/utf8>>};
        {error, _} = Full -> Full;
        ok ->
            case ana_security:check_policy(Username, Password) of
                {error, _} = E -> E;
                ok ->
                    MustChange = maps:get(<<"must_change_password">>, Fields, true) =/= false,
                    case ana_security:create_user(Username, maps:get(<<"name">>, Fields, <<>>),
                                                  Password, Role, MustChange) of
                        {ok, _} ->
                            ok = set_groups(Username, maps:get(<<"groups">>, Fields, [])),
                            log(Who, <<"user.create">>, Username, null,
                                maps:without([<<"password">>], Fields)),
                            {ok, case Generated of
                                     true -> #{username => Username, password => Password};
                                     false -> #{username => Username}
                                 end};
                        {error, #{sqlstate := <<"23505">>}} -> {error, <<"login já existe"/utf8>>};
                        {error, #{sqlstate := <<"23514">>}} -> {error, <<"login inválido"/utf8>>};
                        {error, E} -> {error, E}
                    end
            end
    end.

%% RF-011-02: name, role, active, groups. Never removes the last active admin.
update_user(Username, Fields, Admin) ->
    try do_update_user(Username, Fields, Admin)
    catch throw:{error, _} = E -> E
    end.

do_update_user(Username, Fields, #{username := Who}) ->
    case get_user(Username) of
        {error, _} = E -> E;
        {ok, Before} ->
            Role = maps:get(<<"role">>, Fields, maps:get(<<"role">>, Before)),
            %% An external account stays external (it belongs to a party), and vice versa.
            (Role =:= <<"external">>) =:= (maps:get(<<"role">>, Before) =:= <<"external">>)
                orelse throw({error, <<"conta externa não muda de papel; crie outra conta"/utf8>>}),
            Active = maps:get(<<"active">>, Fields, maps:get(<<"active">>, Before)),
            LosesAdmin = maps:get(<<"role">>, Before) =:= <<"admin">>
                         andalso maps:get(<<"active">>, Before) =:= true
                         andalso (Role =/= <<"admin">> orelse Active =/= true),
            %% Spec 009 (RF-009-04): reactivating a person takes a named-user seat.
            Reactivates = Active =:= true andalso maps:get(<<"active">>, Before) =/= true
                          andalso Role =/= <<"external">> andalso maps:get(<<"kind">>, Before) =/= <<"robot">>,
            _ = Reactivates andalso case ana_license:seat() of ok -> true; Full -> throw(Full) end,
            case (lists:member(Role, ?ROLES) orelse Role =:= <<"external">>) andalso is_boolean(Active) of
                false -> {error, <<"dados inválidos"/utf8>>};
                true when LosesAdmin ->
                    case other_active_admins(Username) of
                        0 -> {error, last_admin};
                        _ -> do_update(Username, Fields, Role, Active, Before, Who)
                    end;
                true -> do_update(Username, Fields, Role, Active, Before, Who)
            end
    end.

do_update(_Username, _Fields, Role, Active, #{<<"builtin">> := true, <<"role">> := R0}, _Who)
  when Role =/= R0; Active =/= true ->
    {error, <<"o robô interno do sistema não pode ser desativado nem mudar de papel"/utf8>>};
do_update(Username, _Fields, <<"admin">>, _Active, #{<<"kind">> := <<"robot">>}, _Who) ->
    _ = Username,
    {error, <<"robôs não podem ter papel admin"/utf8>>};
do_update(Username, Fields, Role, Active, Before, Who) ->
    {ok, _} = ana_db:exec(
        "UPDATE ana_system.app_user SET name = COALESCE($2, name), role = $3, active = $4 "
        "WHERE username = $1", [Username, maps:get(<<"name">>, Fields, null), Role, Active]),
    case maps:find(<<"groups">>, Fields) of
        {ok, Groups} -> ok = set_groups(Username, Groups);
        error -> ok
    end,
    Active =:= false andalso ana_security:revoke_sessions(Username),
    ana_security:clear_cache(),
    {ok, After} = get_user(Username),
    log(Who, <<"user.update">>, Username, Before, After),
    {ok, After}.

other_active_admins(Username) ->
    {ok, #{<<"n">> := N}} = ana_db:one(
        "SELECT count(*) AS n FROM ana_system.app_user "
        "WHERE role = 'admin' AND active AND username <> $1", [Username]),
    N.

set_groups(Username, Groups) when is_list(Groups) ->
    {ok, _} = ana_db:transaction(fun(C) ->
        {ok, _} = ana_db:query(C, "DELETE FROM ana_system.user_group WHERE username = $1", [Username]),
        _ = [{ok, _} = ana_db:query(C, "INSERT INTO ana_system.user_group (username, group_name) "
                                       "VALUES ($1, $2)", [Username, G]) || G <- Groups, is_binary(G)],
        {ok, done}
    end),
    ana_access:invalidate();
set_groups(_, _) -> ok.

reset_password(Username, #{username := Who}) ->
    case get_user(Username) of
        {error, _} = E -> E;
        {ok, #{<<"kind">> := <<"robot">>}} -> {error, <<"robôs não têm senha; use chaves de API"/utf8>>};
        {ok, _} ->
            Password = generate_password(),
            {ok, _} = ana_security:set_password(Username, Password, true),
            log(Who, <<"user.reset_password">>, Username, null, null),
            {ok, #{username => Username, password => Password}}
    end.

revoke_sessions(Username, #{username := Who}) ->
    {ok, N} = ana_security:revoke_sessions(Username),
    log(Who, <<"user.revoke_sessions">>, Username, null, #{sessions => N}),
    {ok, #{sessions => N}}.

%% RF-011 (operation): unblock an address after legitimate failures (spec 001 brute-force protection).
unlock_ip(Ip, #{username := Who}) ->
    ok = ana_security:unlock_ip(Ip),
    log(Who, <<"security.unlock_ip">>, Ip, null, null),
    {ok, #{ip => Ip}}.

unlock_user(Username, #{username := Who}) ->
    ok = ana_security:unlock(Username),
    log(Who, <<"user.unlock">>, Username, null, null),
    {ok, #{}}.

%% ==========================================================================
%% Robot API keys (RF-011-13, RF-011-15)
%% ==========================================================================

list_keys(Username) ->
    ana_db:rows(
        "SELECT id, name, prefix, ip_allow::text[] AS ip_allow, expires_at, last_used_at, revoked_at, "
        "  created_by, created_at, "
        "  (revoked_at IS NULL AND (expires_at IS NULL OR expires_at > now())) AS valid "
        "FROM ana_system.api_key WHERE username = $1 ORDER BY created_at DESC", [Username]).

create_key(Username, Fields, #{username := Who}) ->
    case ana_db:one("SELECT kind, builtin FROM ana_system.app_user WHERE username = $1", [Username]) of
        {ok, #{<<"builtin">> := true}} ->
            {error, <<"o robô interno do sistema não recebe chaves de API; crie um robô próprio para a integração"/utf8>>};
        {ok, #{<<"kind">> := <<"robot">>}} ->
            {Secret, Prefix, Hash} = ana_security:new_api_key(),
            Ips = maps:get(<<"ip_allow">>, Fields, []),
            Days = maps:get(<<"expires_in_days">>, Fields, null),
            case ana_db:one(
                   "INSERT INTO ana_system.api_key (username, name, prefix, key_hash, ip_allow, expires_at, created_by) "
                   "VALUES ($1, $2, $3, $4, $5::text[]::cidr[], "
                   "        CASE WHEN $6::int IS NULL THEN NULL ELSE now() + make_interval(days => $6::int) END, $7) "
                   "RETURNING id",
                   [Username, maps:get(<<"name">>, Fields, <<"chave">>), Prefix, Hash, Ips, Days, Who]) of
                {ok, #{<<"id">> := Id}} ->
                    log(Who, <<"api_key.create">>, Username, null, #{id => Id, name => maps:get(<<"name">>, Fields, null),
                                                                       ip_allow => Ips, expires_in_days => Days}),
                    {ok, #{id => Id, key => Secret, prefix => Prefix}};
                {error, #{sqlstate := <<"22P02">>}} -> {error, <<"IP ou rede inválidos"/utf8>>};
                {error, E} -> {error, E}
            end;
        {ok, #{}} -> {error, <<"chaves de API são só para usuários robô"/utf8>>};
        _ -> {error, not_found}
    end.

revoke_key(Id, #{username := Who}) ->
    {ok, N} = ana_db:exec("UPDATE ana_system.api_key SET revoked_at = now() WHERE id = $1 AND revoked_at IS NULL",
                          [Id]),
    ana_security:clear_cache(),
    log(Who, <<"api_key.revoke">>, integer_to_binary(Id), null, null),
    {ok, #{revoked => N}}.

%% 16 characters, letters and digits without look-alikes.
generate_password() ->
    Alphabet = <<"abcdefghjkmnpqrstuvwxyzABCDEFGHJKMNPQRSTUVWXYZ23456789">>,
    N = byte_size(Alphabet),
    << <<(binary:at(Alphabet, B rem N))>> || <<B>> <= crypto:strong_rand_bytes(16) >>.

%% ==========================================================================
%% Groups (RF-011-04)
%% ==========================================================================

list_groups() ->
    ana_db:rows(
        "SELECT g.name, g.description, g.program_patterns, g.data_cost_centers, g.data_portfolio, g.data_own_projects, "
        "       g.value_patterns, g.variant_patterns, (SELECT count(*) FROM ana_system.user_group ug WHERE ug.group_name = g.name) AS members "
        "FROM ana_system.access_group g ORDER BY g.name", []).

save_group(Name, Fields, #{username := Who}) ->
    Patterns = maps:get(<<"program_patterns">>, Fields, []),
    %% Spec 065 (D9): company values the members may change (names or "area.*").
    Values = maps:get(<<"value_patterns">>, Fields, []),
    %% Spec 045 (RF-045-02): programs whose company variants the members publish.
    Variants = maps:get(<<"variant_patterns">>, Fields, []),
    %% Spec 009 (D10): data scope of the group (null/empty centers = no restriction by center).
    Centers = case maps:get(<<"data_cost_centers">>, Fields, null) of
        L when is_list(L), L =/= [] -> L;
        _ -> null
    end,
    case is_list(Patterns) andalso lists:all(fun valid_pattern/1, Patterns)
         andalso is_list(Values) andalso lists:all(fun valid_pattern/1, Values)
         andalso is_list(Variants) andalso lists:all(fun valid_pattern/1, Variants)
         andalso (Centers =:= null orelse lists:all(fun is_binary/1, Centers)) of
        false -> {error, <<"padrões inválidos: use nomes de programa ou prefixo.*"/utf8>>};
        true ->
            case ana_db:exec(
                   "INSERT INTO ana_system.access_group (name, description, program_patterns, data_cost_centers, "
                   "  data_portfolio, data_own_projects, value_patterns, variant_patterns) "
                   "SELECT $1, $2, $3, $4, $5, $6, $7, $8 WHERE $4::text[] IS NULL OR NOT EXISTS ("
                   "  SELECT 1 FROM unnest($4::text[]) c WHERE NOT EXISTS (SELECT 1 FROM finance.cost_center WHERE code = c)) "
                   "ON CONFLICT (name) DO UPDATE SET "
                   "description = EXCLUDED.description, program_patterns = EXCLUDED.program_patterns, "
                   "data_cost_centers = EXCLUDED.data_cost_centers, data_portfolio = EXCLUDED.data_portfolio, "
                   "data_own_projects = EXCLUDED.data_own_projects, value_patterns = EXCLUDED.value_patterns, "
                   "variant_patterns = EXCLUDED.variant_patterns",
                   [Name, maps:get(<<"description">>, Fields, <<>>), Patterns, Centers,
                    maps:get(<<"data_portfolio">>, Fields, false) =:= true,
                    maps:get(<<"data_own_projects">>, Fields, false) =:= true, Values, Variants]) of
                {ok, 0} -> {error, <<"centro de custo inexistente no escopo de dados"/utf8>>};
                {ok, _} ->
                    ok = ana_access:invalidate(),
                    log(Who, <<"group.save">>, Name, null, Fields),
                    {ok, #{name => Name}};
                {error, #{sqlstate := <<"23514">>}} -> {error, <<"nome de grupo inválido"/utf8>>};
                {error, E} -> {error, E}
            end
    end.

valid_pattern(P) when is_binary(P) ->
    re:run(P, "^[a-z][a-z0-9_]*(\\.[a-z][a-z0-9_]*)*(\\.\\*)?$", [{capture, none}]) =:= match;
valid_pattern(_) -> false.

delete_group(Name, #{username := Who}) ->
    {ok, N} = ana_db:exec("DELETE FROM ana_system.access_group WHERE name = $1", [Name]),
    ok = ana_access:invalidate(),
    log(Who, <<"group.delete">>, Name, null, null),
    {ok, #{deleted => N}}.

%% ==========================================================================
%% Company (RF-011-06)
%% ==========================================================================

get_company() ->
    ana_db:one("SELECT id, legal_name, tax_id, address, city, state, email, phone, latitude, longitude, public_url, "
               "  display_name, logo IS NOT NULL AS has_logo, person_kind, state_registration, icms_taxpayer, "
               "  municipal_registration, tax_regime "
               "FROM base.company ORDER BY id LIMIT 1", []).

%% Spec 009 (D11): the customer's logo (JPEG in base64, converted and shrunk by the browser), or null to remove.
save_logo(Logo, #{username := Who}) when Logo =:= null; is_binary(Logo) ->
    Valid = Logo =:= null orelse (byte_size(Logo) =< 400000 andalso binary:part(Logo, 0, min(4, byte_size(Logo))) =:= <<"/9j/">>),
    case Valid andalso ana_db:exec("UPDATE base.company SET logo = $1", [Logo]) of
        false -> {error, <<"envie o logotipo como JPEG de até 300 KB"/utf8>>};
        {ok, 0} -> {error, <<"cadastre a empresa antes do logotipo">>};
        {ok, _} ->
            log(Who, <<"company.logo">>, <<"company">>, null, #{removed => Logo =:= null}),
            {ok, #{logo => Logo =/= null}};
        {error, _} -> {error, <<"logotipo inválido: use JPEG de até 300 KB"/utf8>>}
    end;
save_logo(_, _) -> {error, <<"logotipo inválido"/utf8>>}.

logo() ->
    case ana_db:one("SELECT logo FROM base.company WHERE logo IS NOT NULL ORDER BY id LIMIT 1", []) of
        {ok, #{<<"logo">> := L}} -> {ok, base64:decode(L)};
        _ -> none
    end.

save_company(Fields, #{username := Who}) ->
    Cols = [<<"legal_name">>, <<"tax_id">>, <<"address">>, <<"city">>, <<"state">>,
            <<"email">>, <<"phone">>],
    %% Spec 043 (D4): the company's fiscal data; the database checks them (same rule as the partners).
    Fiscal = [<<"state_registration">>, <<"icms_taxpayer">>, <<"municipal_registration">>, <<"tax_regime">>],
    Text = fun(K) -> case maps:get(K, Fields, null) of
                         B when is_binary(B) -> case string:trim(B) of <<>> -> null; T -> T end;
                         _ -> null
                     end end,
    %% Spec 032: coordinates typed with a decimal comma or point ("-23,5505").
    Coord = fun(K) ->
        case maps:get(K, Fields, null) of
            N when is_number(N) -> N;
            B when is_binary(B), B =/= <<>> -> binary:replace(string:trim(B), <<",">>, <<".">>);
            _ -> null
        end
    end,
    %% Spec 037: public address for links sent to customers ("https://erp.empresa.com.br").
    Url = case maps:get(<<"public_url">>, Fields, null) of
        U0 when is_binary(U0) -> case string:trim(U0) of <<>> -> null; T -> string:trim(T, trailing, "/") end;
        _ -> null
    end,
    %% Spec 009 (D11): short name shown beside ANA's brand and on the documents (empty = the legal name).
    Display = case maps:get(<<"display_name">>, Fields, null) of
        D0 when is_binary(D0) -> case string:trim(D0) of <<>> -> null; D -> D end;
        _ -> null
    end,
    Values = [maps:get(C, Fields, null) || C <- Cols] ++ [Coord(<<"latitude">>), Coord(<<"longitude">>), Url, Display]
             ++ [Text(F) || F <- Fiscal],
    {ok, Before} = get_company(),
    R = case Before of
        undefined ->
            ana_db:exec("INSERT INTO base.company (legal_name, tax_id, address, city, state, email, phone, latitude, longitude, public_url, "
                        "  display_name, state_registration, icms_taxpayer, municipal_registration, tax_regime) "
                        "VALUES ($1, $2, $3, $4, $5, $6, $7, $8::text::numeric, $9::text::numeric, $10, $11, $12, $13, $14, $15)",
                        [case V of N when is_number(N) -> list_to_binary(io_lib:format("~p", [N])); _ -> V end || V <- Values]);
        #{<<"id">> := Id} ->
            ana_db:exec("UPDATE base.company SET legal_name = $2, tax_id = $3, address = $4, city = $5, "
                        "state = $6, email = $7, phone = $8, latitude = $9::text::numeric, longitude = $10::text::numeric, "
                        "public_url = $11, display_name = $12, state_registration = $13, icms_taxpayer = $14, "
                        "municipal_registration = $15, tax_regime = $16 WHERE id = $1",
                        [Id | [case V of N when is_number(N) -> list_to_binary(io_lib:format("~p", [N])); _ -> V end || V <- Values]])
    end,
    case R of
        {ok, _} ->
            {ok, After} = get_company(),
            ana_instance:forget_public_url(),
            log(Who, <<"company.save">>, <<"company">>, Before, After),
            {ok, After};
        {error, #{sqlstate := <<"23514">>, message := Msg}} when is_binary(Msg) ->
            %% Rules of the database say "CODE: message" (spec 043); other checks are the URL and the name.
            case re:run(Msg, "^[A-Z][A-Z0-9_]{2,40}: (.+)$", [{capture, all_but_first, binary}, unicode, dotall]) of
                {match, [Text0]} -> {error, Text0};
                nomatch -> {error, <<"endereço público inválido (https://nome[:porta], sem caminho) ou nome de exibição fora de 2 a 60 letras"/utf8>>}
            end;
        {error, #{sqlstate := <<"23514">>}} ->
            {error, <<"endereço público inválido (https://nome[:porta], sem caminho) ou nome de exibição fora de 2 a 60 letras"/utf8>>};
        {error, E} -> {error, E}
    end.

%% ==========================================================================
%% Default accounts and remote systems (RF-011-07)
%% ==========================================================================

list_default_accounts() ->
    ana_db:rows(
        "SELECT d.key, d.account, d.description, a.description AS account_description "
        "FROM finance.default_account d JOIN finance.account a ON a.code = d.account ORDER BY d.key", []).

save_default_account(Key, Account, #{username := Who}) ->
    case ana_db:one("SELECT postable FROM finance.account WHERE code = $1", [Account]) of
        {ok, #{<<"postable">> := true}} ->
            {ok, Before} = ana_db:one("SELECT account FROM finance.default_account WHERE key = $1", [Key]),
            case Before of
                undefined -> {error, not_found};
                _ ->
                    {ok, _} = ana_db:exec("UPDATE finance.default_account SET account = $2 WHERE key = $1",
                                          [Key, Account]),
                    log(Who, <<"default_account.save">>, Key, Before, #{account => Account}),
                    {ok, #{key => Key, account => Account}}
            end;
        {ok, #{}} -> {error, <<"a conta não aceita lançamentos (sintética)"/utf8>>};
        _ -> {error, <<"conta inexistente"/utf8>>}
    end.

list_remote_systems() ->
    ana_db:rows("SELECT name, url, username, timeout_ms, active, (password IS NOT NULL) AS has_password "
                "FROM ana_system.remote_system ORDER BY name", []).

%% The password is write-only: omitted keeps the current one (RNF-011-02).
save_remote_system(Name, Fields, #{username := Who}) ->
    R = ana_db:exec(
        "INSERT INTO ana_system.remote_system (name, url, username, password, timeout_ms, active) "
        "VALUES ($1, $2, $3, $4, $5, $6) ON CONFLICT (name) DO UPDATE SET "
        "url = EXCLUDED.url, username = EXCLUDED.username, "
        "password = COALESCE(EXCLUDED.password, ana_system.remote_system.password), "
        "timeout_ms = EXCLUDED.timeout_ms, active = EXCLUDED.active",
        [Name, maps:get(<<"url">>, Fields, null), maps:get(<<"username">>, Fields, null),
         maps:get(<<"password">>, Fields, null), maps:get(<<"timeout_ms">>, Fields, 15000),
         maps:get(<<"active">>, Fields, true)]),
    case R of
        {ok, _} ->
            ana_remote_system:forget(Name),
            log(Who, <<"remote_system.save">>, Name, null, maps:without([<<"password">>], Fields)),
            {ok, #{name => Name}};
        {error, E} -> {error, E}
    end.

%% ==========================================================================
%% Audit (RF-011-09)
%% ==========================================================================

audit_executions(F) ->
    ana_db:rows(
        "SELECT id::text AS id, program, version, username, origin, debug, status, started_at, "
        "       duration_ms, cpu_ms, client_ip, node, error->>'code' AS error "
        "FROM ana_system.execution "
        "WHERE ($1::text IS NULL OR username = $1) AND ($2::text IS NULL OR program LIKE $2 || '%') "
        "  AND ($3::text IS NULL OR status = $3) "
        "  AND ($4::text IS NULL OR started_at >= $4::text::timestamptz) "
        "  AND ($5::text IS NULL OR started_at < $5::text::timestamptz) "
        "ORDER BY started_at DESC LIMIT $6",
        [filter(<<"username">>, F), filter(<<"program">>, F), filter(<<"status">>, F),
         filter(<<"from">>, F), filter(<<"to">>, F), limit(F)]).

audit_logins(F) ->
    ana_db:rows(
        "SELECT username, ip, success, reason, at FROM ana_system.login_event "
        "WHERE ($1::text IS NULL OR username = $1) AND ($2::boolean IS NULL OR success = $2) "
        "ORDER BY at DESC LIMIT $3",
        [filter(<<"username">>, F),
         case filter(<<"success">>, F) of
             <<"true">> -> true; <<"false">> -> false; _ -> null
         end, limit(F)]).

audit_changes(F) ->
    ana_db:rows(
        "SELECT username, action, target, before, after, at FROM ana_system.admin_log "
        "WHERE ($1::text IS NULL OR username = $1) AND ($2::text IS NULL OR action LIKE $2 || '%') "
        "ORDER BY at DESC LIMIT $3",
        [filter(<<"username">>, F), filter(<<"action">>, F), limit(F)]).

%% RF-024-01..03
audit_access(F) ->
    ana_db:rows(
        "SELECT at, username, auth, api_key_id, ip, method, path, status, duration_ms, node, detail "
        "FROM ana_system.access_event "
        "WHERE ($1::text IS NULL OR username = $1) AND ($2::text IS NULL OR path LIKE $2 || '%') "
        "  AND ($3::int IS NULL OR status = $3) "
        "  AND ($4::text IS NULL OR at >= $4::text::timestamptz) "
        "  AND ($5::text IS NULL OR at < $5::text::timestamptz) "
        "ORDER BY at DESC LIMIT $6",
        [filter(<<"username">>, F), filter(<<"path">>, F),
         case filter(<<"status">>, F) of null -> null; S -> try binary_to_integer(S) catch _:_ -> null end end,
         filter(<<"from">>, F), filter(<<"to">>, F), limit(F)]).

%% RF-024-06: everything one user did, on a single timeline.
audit_trail(F) ->
    case filter(<<"username">>, F) of
        null -> {error, <<"informe o usuário"/utf8>>};
        U ->
            ana_db:rows(unicode:characters_to_binary(
                "SELECT * FROM ("
                "  SELECT at, 'access' AS kind, method || ' ' || path AS what, status::text AS status, "
                "         COALESCE(detail, ip) AS detail, NULL AS ref, duration_ms FROM ana_system.access_event "
                "   WHERE username = $1 AND at >= $2::text::timestamptz AND at < $3::text::timestamptz "
                "  UNION ALL "
                "  SELECT at, 'login', 'login', CASE WHEN success THEN 'success' ELSE COALESCE(reason, 'error') END, "
                "         ip, NULL, NULL FROM ana_system.login_event "
                "   WHERE username = $1 AND at >= $2::text::timestamptz AND at < $3::text::timestamptz "
                "  UNION ALL "
                "  SELECT started_at, 'execution', program || ' v' || COALESCE(version::text, '?'), status, "
                "         origin || COALESCE(' · CPU ' || cpu_ms || ' ms', '') || COALESCE(' · ' || (error->>'code'), ''), "
                "         id::text, duration_ms FROM ana_system.execution "
                "   WHERE username = $1 AND started_at >= $2::text::timestamptz AND started_at < $3::text::timestamptz "
                "  UNION ALL "
                "  SELECT started_at, 'task', task, status, detail, NULL, "
                "         (extract(epoch FROM finished_at - started_at) * 1000)::int FROM ana_system.task_run "
                "   WHERE username = $1 AND started_at >= $2::text::timestamptz AND started_at < $3::text::timestamptz "
                "  UNION ALL "
                "  SELECT at, 'change', action, NULL, target, NULL, NULL FROM ana_system.admin_log "
                "   WHERE username = $1 AND at >= $2::text::timestamptz AND at < $3::text::timestamptz "
                ") t ORDER BY at DESC LIMIT $4"),
                [U, case filter(<<"from">>, F) of null -> <<"-infinity">>; X -> X end,
                 case filter(<<"to">>, F) of null -> <<"infinity">>; Y -> Y end, limit(F)])
    end.

%% RF-024-07: full record, including the internal trace (admins only).
audit_execution(Id) ->
    case ana_db:one(
           "SELECT id::text AS id, program, version, username, origin, debug, status, started_at, finished_at, "
           "  duration_ms, params, result, error, output, cpu_ms, max_rss_kb, sql_count, rows_read, limits, "
           "  client_ip, api_key_id, node, internal_trace, payload_purged_at, parent_execution_id::text AS parent "
           "FROM ana_system.execution WHERE id = $1::text::uuid", [Id]) of
        {ok, undefined} -> {error, not_found};
        {ok, R} ->
            %% RF-022-07: the parts of a main execution and the consumption summed.
            {ok, Parts} = ana_db:rows(
                "SELECT id::text AS id, program, status, duration_ms, cpu_ms, max_rss_kb, sql_count, "
                "  error->>'code' AS error FROM ana_system.execution "
                "WHERE parent_execution_id = $1::text::uuid ORDER BY started_at", [Id]),
            Sum = fun(K) -> lists:sum([V || #{K := V} <- [R | Parts], is_integer(V)]) end,
            {ok, R#{<<"trace">> => case ana_observability:trace(Id) of undefined -> null; T -> T end,
                    <<"parts">> => Parts,
                    <<"total">> => #{cpu_ms => Sum(<<"cpu_ms">>), sql_count => Sum(<<"sql_count">>),
                                     parts => length(Parts)}}};
        {error, _} -> {error, not_found}
    end.

audit_tasks(F) ->
    ana_task:list(#{username => filter(<<"username">>, F), task => filter(<<"task">>, F), limit => limit(F)}).

filter(K, F) ->
    case maps:get(K, F, <<>>) of
        <<>> -> null;
        V -> V
    end.

limit(F) ->
    try binary_to_integer(maps:get(<<"limit">>, F, <<"100">>)) of
        N -> max(1, min(N, 1000))
    catch _:_ -> 100
    end.

%% Spec 020 (RF-020-13): what a member of a group would see with this data scope, before saving it —
%% visible and total records per scoped entity, counted by the database's own row policies (same role
%% and settings as an execution), in a read-only transaction. "member" = whose portfolio and projects.
-define(SCOPED, [{<<"base.party">>, <<"Clientes e fornecedores"/utf8>>}, {<<"sales.sales_order">>, <<"Pedidos de venda">>},
                 {<<"finance.bill">>, <<"Títulos a receber e a pagar"/utf8>>}, {<<"projects.project">>, <<"Projetos">>},
                 {<<"production.work_order">>, <<"Ordens de produção"/utf8>>},
                 {<<"supply.purchase_request">>, <<"Solicitações de compra"/utf8>>}]).
-define(PREVIEW_CAP, 100000).

-spec scope_preview(map()) -> {ok, map()} | {error, binary()}.
scope_preview(F) ->
    Scope = ana_access:scope_of(F),
    Member = case maps:get(<<"member">>, F, <<>>) of M when is_binary(M) -> M; _ -> <<>> end,
    Count = iolist_to_binary(["SELECT ", lists:join(", ",
        [io_lib:format("(SELECT count(*) FROM (SELECT 1 FROM ~s LIMIT ~b) x) AS \"~s\"", [T, ?PREVIEW_CAP, T]) || {T, _} <- ?SCOPED])]),
    Q = fun(V) -> binary:replace(V, <<"'">>, <<"''">>, [global]) end,
    case ana_db:checkout(ana_db_exec, 5000) of
        {ok, C} ->
            try
                {ok, [], []} = epgsql:squery(C, "BEGIN READ ONLY"),
                _ = epgsql:squery(C, "SET LOCAL statement_timeout = 5000"),
                {ok, #{rows := [Total]}} = ana_db:query(C, Count, []),
                Set = epgsql:squery(C, iolist_to_binary([ana_access:scope_sql_of(Scope),
                                                         "SET LOCAL ana.username = '", Q(Member), "'"])),
                [] = [E || {error, E} <- lists:flatten([Set])],      % never count with the scope half applied
                {ok, #{rows := [Seen]}} = ana_db:query(C, Count, []),
                Rows = [#{entity => T, label => L, visible => V, total => N}
                        || {{T, L}, V, N} <- lists:zip3(?SCOPED, Seen, Total)],
                {ok, #{entities => Rows, cost_centers => case maps:get(cost_centers, Scope) of all -> all; Cs -> Cs end,
                       restricted => iolist_size(ana_access:scope_sql_of(Scope)) > 0, cap => ?PREVIEW_CAP}}
            catch _:_ -> {error, <<"não foi possível simular o escopo agora"/utf8>>}
            after
                _ = epgsql:squery(C, "ROLLBACK"),
                ana_db:checkin(ana_db_exec, C)
            end;
        {error, _} -> {error, <<"banco indisponível"/utf8>>}
    end.
