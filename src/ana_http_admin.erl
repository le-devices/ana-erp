%% Administration API (spec 011). Every route requires the admin role
%% (RNF-011-01); destructive actions are confirmed by the studio and logged.
-module(ana_http_admin).
-export([init/2]).

init(Req, admin) ->
    Method = cowboy_req:method(Req),
    Path = cowboy_req:path_info(Req),
    Req2 = try
               ana_http:require(Req, <<"admin">>, fun(U) -> route(Method, Path, U, Req) end)
           catch Class:Reason:Stack ->
               logger:error("admin API error ~s ~0p: ~0p:~0p ~0p", [Method, Path, Class, Reason, Stack]),
               ana_http:reply_error(500, <<"INTERNAL">>, <<"erro interno">>, Req)
           end,
    {ok, Req2, admin}.

%% --- Users (RF-011-02) ----------------------------------------------------
route(<<"GET">>, [<<"users">>], _U, Req) ->
    reply(ana_admin:list_users(ana_http:qs_map(Req)), Req);
route(<<"POST">>, [<<"users">>], U, Req) ->
    with_body(Req, fun(B, R) -> reply(ana_admin:create_user(B, U), R) end);
route(<<"PUT">>, [<<"users">>, Name], U, Req) ->
    with_body(Req, fun(B, R) -> reply(ana_admin:update_user(Name, B, U), R) end);
route(<<"POST">>, [<<"users">>, Name, <<"password">>], U, Req) ->
    reply(ana_admin:reset_password(Name, U), Req);
route(<<"POST">>, [<<"users">>, Name, <<"sessions">>, <<"revoke">>], U, Req) ->
    reply(ana_admin:revoke_sessions(Name, U), Req);
route(<<"POST">>, [<<"security">>, <<"unlock-ip">>], U, Req) ->
    with_body(Req, fun(B, R) ->
        Ip = case maps:get(<<"ip">>, B, <<"self">>) of <<"self">> -> ana_http:ip(R); V -> V end,
        reply(ana_admin:unlock_ip(Ip, U), R)
    end);
route(<<"POST">>, [<<"users">>, Name, <<"unlock">>], U, Req) ->
    reply(ana_admin:unlock_user(Name, U), Req);

route(<<"GET">>, [<<"users">>, Name, <<"keys">>], _U, Req) ->
    reply(ana_admin:list_keys(Name), Req);
route(<<"POST">>, [<<"users">>, Name, <<"keys">>], U, Req) ->
    with_body(Req, fun(B, R) -> reply(ana_admin:create_key(Name, B, U), R) end);
route(<<"DELETE">>, [<<"keys">>, Id], U, Req) ->
    try binary_to_integer(Id) of N -> reply(ana_admin:revoke_key(N, U), Req)
    catch _:_ -> invalid(Req)
    end;

%% --- Groups (RF-011-04) ---------------------------------------------------
route(<<"GET">>, [<<"groups">>], _U, Req) ->
    reply(ana_admin:list_groups(), Req);
route(<<"PUT">>, [<<"groups">>, Name], U, Req) ->
    with_body(Req, fun(B, R) -> reply(ana_admin:save_group(Name, B, U), R) end);
route(<<"DELETE">>, [<<"groups">>, Name], U, Req) ->
    reply(ana_admin:delete_group(Name, U), Req);

%% --- Settings (RF-011-05) -------------------------------------------------
route(<<"GET">>, [<<"settings">>], _U, Req) ->
    ana_http:json(200, ana_settings:list(), Req);
route(<<"PUT">>, [<<"settings">>, Key], U, Req) ->
    with_body(Req, fun(#{<<"value">> := V}, R) ->
        case ana_settings:set(Key, V, U) of
            ok -> ana_http:json(200, #{ok => true}, R);
            {error, unknown_setting} ->
                ana_http:reply_error(404, <<"NOT_FOUND">>, <<"parâmetro inexistente"/utf8>>, R);
            {error, {range, Min, Max}} ->
                ana_http:reply_error(400, <<"OUT_OF_RANGE">>,
                    io_lib:format("valor deve ser inteiro entre ~b e ~b", [Min, Max]), R)
        end;
        (_, R) -> invalid(R)
    end);

%% --- Company (RF-011-06) --------------------------------------------------
route(<<"GET">>, [<<"company">>], _U, Req) ->
    case ana_admin:get_company() of
        {ok, undefined} -> ana_http:json(200, #{}, Req);
        Other -> reply(Other, Req)
    end;
route(<<"PUT">>, [<<"company">>], U, Req) ->
    with_body(Req, fun(B, R) -> reply(ana_admin:save_company(B, U), R) end);

%% --- Default accounts and remote systems (RF-011-07) ----------------------
route(<<"GET">>, [<<"default-accounts">>], _U, Req) ->
    reply(ana_admin:list_default_accounts(), Req);
route(<<"PUT">>, [<<"default-accounts">>, Key], U, Req) ->
    with_body(Req, fun(#{<<"account">> := A}, R) when is_binary(A) ->
        reply(ana_admin:save_default_account(Key, A, U), R);
        (_, R) -> invalid(R)
    end);
route(<<"GET">>, [<<"remote-systems">>], _U, Req) ->
    reply(ana_admin:list_remote_systems(), Req);
route(<<"PUT">>, [<<"remote-systems">>, Name], U, Req) ->
    with_body(Req, fun(#{<<"url">> := Url} = B, R) when is_binary(Url) ->
        reply(ana_admin:save_remote_system(Name, B, U), R);
        (_, R) -> invalid(R)
    end);

%% --- Limits and quotas (spec 012, RF-012-08) ------------------------------
route(<<"GET">>, [<<"limit-profiles">>], _U, Req) ->
    reply(ana_limits:list_profiles(), Req);
route(<<"PUT">>, [<<"limit-profiles">>, Kind, Target], U, Req) ->
    with_body(Req, fun(#{<<"limits">> := L}, R) -> reply(ana_limits:save_profile(Kind, Target, L, U), R);
                      (_, R) -> invalid(R)
              end);
route(<<"DELETE">>, [<<"limit-profiles">>, Kind, Target], U, Req) ->
    reply(ana_limits:delete_profile(Kind, Target, U), Req);
route(<<"GET">>, [<<"quotas">>, Name], _U, Req) ->
    reply(ana_limits:get_quota(Name), Req);
route(<<"PUT">>, [<<"quotas">>, Name], U, Req) ->
    with_body(Req, fun(B, R) -> reply(ana_limits:save_quota(Name, B, U), R) end);
route(<<"GET">>, [<<"consumption">>], _U, Req) ->
    reply(ana_limits:consumption(max(1, min(365, ana_http:qs_int(<<"days">>, Req, 7)))), Req);

%% --- Monitor (RF-011-08) --------------------------------------------------
route(<<"GET">>, [<<"monitor">>], _U, Req) ->
    {ok, V} = application:get_key(ana, vsn),
    ana_http:json(200, #{version => list_to_binary(V),
                         running => ana_execution:running(),
                         counters => ana_execution:counters(),
                         database => ana_db:status(ana_db),
                         database_programs => ana_db:status(ana_db_exec),
                         python => ana_py_pool:status(),
                         database_settings => case ana_db:rows(
                             "SELECT name, setting, unit FROM pg_settings WHERE name = ANY($1::text[]) ORDER BY name",
                             [[<<"shared_buffers">>, <<"effective_cache_size">>, <<"work_mem">>, <<"jit">>,
                               <<"shared_preload_libraries">>, <<"pg_prewarm.autoprewarm">>, <<"max_connections">>,
                               <<"TimeZone">>]]) of {ok, S} -> S; _ -> [] end,
                         memory_mb => erlang:memory(total) div (1024 * 1024),
                         processes => erlang:system_info(process_count),
                         uptime_s => element(1, erlang:statistics(wall_clock)) div 1000,
                         analytics => try ana_analytics:status() catch _:_ -> #{} end}, Req);
route(<<"POST">>, [<<"executions">>, Id, <<"stop">>], U = #{username := Who}, Req) ->
    case ana_execution:command(Id, U, #{<<"action">> => <<"stop">>}) of
        ok ->
            ana_admin:log(Who, <<"execution.stop">>, Id, null, null),
            ana_http:json(200, #{ok => true}, Req);
        {error, not_found} -> ana_http:reply_error(404, <<"NOT_FOUND">>, <<"execução não encontrada"/utf8>>, Req);
        {error, _} -> ana_http:reply_error(409, <<"NOT_STOPPABLE">>, <<"não foi possível parar"/utf8>>, Req)
    end;

%% --- Audit (RF-011-09) ----------------------------------------------------
route(<<"GET">>, [<<"audit">>, <<"executions">>], _U, Req) ->
    reply(ana_admin:audit_executions(ana_http:qs_map(Req)), Req);
route(<<"GET">>, [<<"audit">>, <<"logins">>], _U, Req) ->
    reply(ana_admin:audit_logins(ana_http:qs_map(Req)), Req);
route(<<"GET">>, [<<"audit">>, <<"executions">>, Id], _U, Req) ->
    reply(ana_admin:audit_execution(Id), Req);
route(<<"GET">>, [<<"audit">>, <<"access">>], _U, Req) ->
    reply(ana_admin:audit_access(ana_http:qs_map(Req)), Req);
route(<<"GET">>, [<<"audit">>, <<"trail">>], _U, Req) ->
    reply(ana_admin:audit_trail(ana_http:qs_map(Req)), Req);

%% --- Retention (spec 024, RF-024-08..10) ----------------------------------
route(<<"GET">>, [<<"retention">>], _U, Req) ->
    reply(ana_retention:overview(), Req);
route(<<"POST">>, [<<"retention">>, <<"purge">>], U = #{username := Who}, Req) ->
    ana_admin:log(Who, <<"retention.purge">>, <<"manual">>, null, null),
    case ana_retention:purge_now(U) of
        {ok, Detail} -> ana_http:json(200, #{counts => json:decode(Detail)}, Req);
        {error, E} -> ana_http:reply_error(500, <<"PURGE_FAILED">>,
                                           unicode:characters_to_binary(io_lib:format("~0tp", [E])), Req)
    end;
route(<<"GET">>, [<<"audit">>, <<"tasks">>], _U, Req) ->
    reply(ana_admin:audit_tasks(ana_http:qs_map(Req)), Req);
route(<<"GET">>, [<<"audit">>, <<"changes">>], _U, Req) ->
    reply(ana_admin:audit_changes(ana_http:qs_map(Req)), Req);

route(_, _, _U, Req) ->
    ana_http:reply_error(404, <<"NOT_FOUND">>, <<"rota inexistente">>, Req).

%% ==========================================================================
%% Helpers
%% ==========================================================================

reply({ok, V}, Req) -> ana_http:json(200, V, Req);
reply({error, not_found}, Req) -> ana_http:reply_error(404, <<"NOT_FOUND">>, <<"não encontrado"/utf8>>, Req);
reply({error, last_admin}, Req) ->
    ana_http:reply_error(409, <<"LAST_ADMIN">>,
        <<"não é possível remover ou rebaixar o último administrador ativo"/utf8>>, Req);
reply({error, Msg}, Req) when is_binary(Msg) -> ana_http:reply_error(400, <<"INVALID">>, Msg, Req);
reply({error, #{} = E}, Req) -> ana_http:json(400, #{error => E}, Req).

with_body(Req, Fun) ->
    case ana_http:read_json(Req) of
        {ok, B, Req2} when is_map(B) -> Fun(B, Req2);
        {ok, _, Req2} -> invalid(Req2);
        {too_large, Req2} ->
            ana_http:reply_error(413, <<"BODY_TOO_LARGE">>, <<"corpo da requisição grande demais"/utf8>>, Req2);
        {invalid, Req2} -> invalid(Req2)
    end.

invalid(Req) -> ana_http:reply_error(400, <<"INVALID">>, <<"requisição inválida"/utf8>>, Req).
