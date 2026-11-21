%% SPDX-FileCopyrightText: 2026 LE Devices
%% SPDX-License-Identifier: AGPL-3.0-or-later
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

%% --- License (spec 009) -----------------------------------------------------
route(<<"GET">>, [<<"license">>], _U, Req) ->
    reply({ok, ana_license:detail()}, Req);
route(<<"POST">>, [<<"license">>], #{username := Who}, Req) ->
    with_body(Req, fun(B, R) ->
        case maps:get(<<"text">>, B, null) of
            T when is_binary(T), T =/= <<>> -> reply(ana_license:install(T, <<"screen">>, Who), R);
            _ -> reply({error, <<"cole o texto da licença"/utf8>>}, R)
        end
    end);

%% --- Telemetry (spec 009, D13) ----------------------------------------------
route(<<"GET">>, [<<"telemetry">>], _U, Req) ->
    reply(ana_telemetry:status(), Req);
route(<<"PUT">>, [<<"telemetry">>], U, Req) ->
    with_body(Req, fun(B, R) ->
        case maps:get(<<"enabled">>, B, null) of
            E when is_boolean(E) -> reply(ana_telemetry:set(E, U), R);
            _ -> reply({error, <<"informe enabled (true/false)">>}, R)
        end
    end);
route(<<"POST">>, [<<"telemetry">>, <<"send">>], U, Req) ->
    reply(ana_telemetry:send_now(U), Req);

%% --- Extension points (spec 009, D9) ---------------------------------------
route(<<"GET">>, [<<"extensions">>], _U, Req) ->
    reply(ana_extensions:list(), Req);
route(<<"POST">>, [<<"extensions">>], U, Req) ->
    with_body(Req, fun(B, R) -> reply(ana_extensions:save(B, U), R) end);
route(<<"DELETE">>, [<<"extensions">>, Id], U, Req) ->
    with_int(Id, Req, fun(N) -> reply(ana_extensions:delete(N, U), Req) end);

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
route(<<"POST">>, [<<"groups">>, <<"scope-preview">>], _U, Req) ->
    with_body(Req, fun(B, R) -> reply(ana_admin:scope_preview(B), R) end);
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
route(<<"PUT">>, [<<"company">>, <<"logo">>], U, Req) ->
    with_body(Req, fun(B, R) -> reply(ana_admin:save_logo(maps:get(<<"logo">>, B, null), U), R) end);
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

%% --- Integrations (spec 017) ----------------------------------------------
route(<<"GET">>, [<<"connectors">>], _U, Req) ->
    reply(ana_connectors:list(), Req);
route(<<"PUT">>, [<<"connectors">>, Name], U, Req) ->
    with_body(Req, fun(B, R) -> reply(ana_connectors:save(Name, B, U), R) end);
route(<<"POST">>, [<<"connectors">>, Name, <<"smtp-test">>], U, Req) ->
    with_body(Req, fun(B, R) -> reply(ana_connectors:smtp_test(Name, B, U), R) end);
route(<<"DELETE">>, [<<"connectors">>, Name], U, Req) ->
    reply(ana_connectors:remove(Name, U), Req);
route(<<"PUT">>, [<<"connectors">>, Name, <<"secrets">>, Key], U, Req) ->
    with_body(Req, fun(B, R) -> reply(ana_connectors:put_secret(Name, Key, B, U), R) end);
route(<<"DELETE">>, [<<"connectors">>, Name, <<"secrets">>, Key], U, Req) ->
    reply(ana_connectors:delete_secret(Name, Key, U), Req);
route(<<"GET">>, [<<"integrations">>, <<"stats">>], _U, Req) ->
    reply(ana_integration:stats(), Req);
route(<<"GET">>, [<<"integrations">>, <<"messages">>], _U, Req) ->
    reply(ana_integration:messages(ana_http:qs_map(Req)), Req);
route(<<"POST">>, [<<"integrations">>, Kind, Id, <<"reprocess">>], U, Req) ->
    with_id(Id, Req, fun(N) -> reply(ana_integration:reprocess(Kind, N, U), Req) end);
route(<<"POST">>, [<<"integrations">>, Kind, Id, <<"discard">>], U, Req) ->
    with_id(Id, Req, fun(N) -> reply(ana_integration:discard(Kind, N, U), Req) end);

%% --- Product updates (spec 028) -------------------------------------------
route(<<"GET">>, [<<"product-updates">>], _U, Req) ->
    {ok, Rows} = ana_product_updates:list(),
    ana_http:json(200, #{updates => Rows, available => ana_product_updates:pending_count()}, Req);
route(<<"POST">>, [<<"product-updates">>, <<"check">>], _U, Req) ->
    reply(ana_product_updates:check(), Req);
route(<<"POST">>, [<<"product-updates">>, <<"accept-unmodified">>], U, Req) ->
    reply(ana_product_updates:accept_unmodified(U), Req);
route(<<"GET">>, [<<"product-updates">>, Name], _U, Req) ->
    reply(ana_product_updates:detail(Name), Req);
route(<<"POST">>, [<<"product-updates">>, Name, <<"accept">>], U, Req) ->
    with_body(Req, fun(B, R) ->
        reply(ana_product_updates:accept(Name, maps:get(<<"overwrite">>, B, false) =:= true, U), R)
    end);
route(<<"POST">>, [<<"product-updates">>, Name, <<"dismiss">>], U, Req) ->
    reply(ana_product_updates:dismiss(Name, U), Req);

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

%% --- Observability (spec 019) ---------------------------------------------
route(<<"GET">>, [<<"observability">>, <<"health">>], _U, Req) ->
    reply(ana_observability:health(), Req);
route(<<"POST">>, [<<"observability">>, <<"health">>, <<"check">>], _U, Req) ->
    _ = ana_health:check_now(),
    reply(ana_observability:health(), Req);
route(<<"GET">>, [<<"observability">>, <<"disk">>], _U, Req) ->
    reply(ana_disk:overview(), Req);
route(<<"POST">>, [<<"observability">>, <<"disk">>, <<"sample">>], _U, Req) ->
    ok = ana_disk:sample_now(),
    reply({ok, #{rates => ana_disk:rates()}}, Req);
route(<<"GET">>, [<<"observability">>, <<"core">>], _U, Req) ->
    reply(ana_core_view:snapshot(), Req);
route(<<"GET">>, [<<"observability">>, <<"ui">>], _U, Req) ->
    reply(ana_ui_perf:report(max(1, min(90, ana_http:qs_int(<<"days">>, Req, 7)))), Req);
route(<<"GET">>, [<<"observability">>, <<"alerts">>], _U, Req) ->
    reply(ana_alerts:overview(), Req);
route(<<"POST">>, [<<"observability">>, <<"alerts">>, <<"rules">>], U, Req) ->
    with_body(Req, fun(B, R) -> reply(ana_alerts:save_rule(B, U), R) end);
route(<<"DELETE">>, [<<"observability">>, <<"alerts">>, <<"rules">>, Id], U, Req) ->
    with_int(Id, Req, fun(N) -> reply(ana_alerts:delete_rule(N, U), Req) end);
route(<<"POST">>, [<<"observability">>, <<"alerts">>, <<"silences">>], U, Req) ->
    with_body(Req, fun(B, R) -> reply(ana_alerts:create_silence(B, U), R) end);
route(<<"POST">>, [<<"observability">>, <<"alerts">>, <<"silences">>, Id, <<"end">>], U, Req) ->
    with_int(Id, Req, fun(N) -> reply(ana_alerts:end_silence(N, U), Req) end);
route(<<"GET">>, [<<"observability">>, <<"sql">>], _U, Req) ->
    reply(ana_observability:sql_top(ana_http:qs_map(Req)), Req);
route(<<"GET">>, [<<"observability">>, <<"sql">>, Hash], _U, Req) ->
    reply(ana_observability:sql_detail(Hash), Req);
route(<<"POST">>, [<<"observability">>, <<"sql">>, <<"flush">>], _U, Req) ->
    ok = ana_sql_stats:flush(),
    reply({ok, #{flushed => true}}, Req);
route(<<"GET">>, [<<"observability">>, <<"samples">>], _U, Req) ->
    reply(ana_observability:samples(ana_http:qs_int(<<"hours">>, Req, 24)), Req);
route(<<"GET">>, [<<"observability">>, <<"advice">>], _U, Req) ->
    Status = case ana_http:qs_map(Req) of #{<<"status">> := S} when S =/= <<>> -> S; _ -> null end,
    reply(ana_advisor:list(#{status => Status}), Req);
route(<<"POST">>, [<<"observability">>, <<"advice">>, <<"run">>], U = #{username := Who}, Req) ->
    _ = U,
    ok = ana_sql_stats:flush(),
    R = ana_advisor:run(),
    ana_admin:log(Who, <<"advice.run">>, <<"manual">>, null, null),
    reply(R, Req);
route(<<"POST">>, [<<"observability">>, <<"advice">>, Id, <<"dismiss">>], U, Req) ->
    with_body(Req, fun(B, R) ->
        Days = case maps:get(<<"days">>, B, 30) of D when is_integer(D), D >= 0 -> D; _ -> 30 end,
        reply(ana_advisor:dismiss(binary_to_integer(Id), Days, U), R)
    end);

%% --- Periodic checks (spec 033) -------------------------------------------
route(<<"GET">>, [<<"checks">>], _U, Req) ->
    Q = ana_http:qs_map(Req),
    Pick = fun(K) -> case Q of #{K := V} when V =/= <<>> -> V; _ -> null end end,
    {ok, Summary} = ana_checks:summary(),
    {ok, Findings} = ana_advisor:list(#{status => Pick(<<"status">>), category => Pick(<<"category">>)}),
    reply({ok, Summary#{findings => Findings}}, Req);
route(<<"POST">>, [<<"checks">>, <<"run">>], U = #{username := Who}, Req) ->
    with_body(Req, fun(B, R) ->
        Cat = case maps:get(<<"category">>, B, <<"all">>) of C when is_binary(C) -> C; _ -> <<"all">> end,
        ana_admin:log(Who, <<"checks.run">>, Cat, null, null),
        case ana_checks:run(Cat, U) of
            {error, unknown_category} -> ana_http:reply_error(400, <<"INVALID">>, <<"categoria inexistente">>, R);
            {error, E} -> ana_http:reply_error(500, <<"CHECK_FAILED">>, unicode:characters_to_binary(io_lib:format("~0tp", [E])), R);
            Ok -> reply(Ok, R)
        end
    end);
route(<<"GET">>, [<<"checks">>, <<"config">>], _U, Req) ->
    reply(ana_checks:config(), Req);
route(<<"PUT">>, [<<"checks">>, <<"config">>], U, Req) ->
    with_body(Req, fun(B, R) -> reply(ana_checks:save_config(B, U), R) end);
route(<<"POST">>, [<<"checks">>, <<"feed">>, <<"refresh">>], U, Req) ->
    reply(ana_checks:refresh_feed(U), Req);
route(<<"GET">>, [<<"checks">>, <<"notices">>], _U, Req) ->
    reply(ana_checks:notices(ana_http:qs_int(<<"unread">>, Req, 0) =:= 1), Req);
route(<<"POST">>, [<<"checks">>, <<"notices">>, Id, <<"read">>], _U, Req) ->
    case catch binary_to_integer(Id) of
        N when is_integer(N) -> {ok, _} = ana_checks:mark_notice(N), reply({ok, #{id => N}}, Req);
        _ -> invalid(Req)
    end;
route(<<"GET">>, [<<"checks">>, <<"inventory">>], _U, Req) ->
    {ok, Components} = ana_inventory:list(),
    {ok, Vulns} = ana_db:rows("SELECT count(DISTINCT osv_id) AS advisories, max(imported_at) AS imported_at "
                              "FROM ana_system.vulnerability", []),
    reply({ok, #{components => Components, feed => hd(Vulns)}}, Req);
route(<<"POST">>, [<<"checks">>, <<"vulnerabilities">>], U, Req) ->
    %% RF-033-02: OSV file sent by hand (installations without internet are the default path).
    case read_raw(Req, 20 * 1048576, <<>>) of
        {ok, Body, Req2} -> reply(ana_checks:import_vulnerabilities(Body, U), Req2);
        {too_large, Req2} -> ana_http:reply_error(413, <<"BODY_TOO_LARGE">>, <<"base acima de 20 MiB: envie por ecossistema"/utf8>>, Req2)
    end;

%% --- Transports and data copies (spec 034) --------------------------------
route(<<"GET">>, [<<"instance">>], _U, Req) ->
    reply({ok, ana_instance:info()}, Req);
route(<<"POST">>, [<<"quality">>, <<"baseline">>], U, Req) ->              %% spec 064 (D3)
    with_body(Req, fun(B, R) ->
        Which = case B of #{<<"programs">> := L} when is_list(L), L =/= [] -> L; _ -> all end,
        reply(ana_quality:set_baseline(Which, U), R)
    end);
route(<<"GET">>, [<<"transports">>], _U, Req) ->
    reply(ana_transport:list(), Req);
route(<<"GET">>, [<<"transports">>, <<"key">>], U, Req) ->
    reply(ana_transport:public_key(U), Req);
route(<<"GET">>, [<<"transports">>, <<"origins">>], _U, Req) ->
    reply(ana_transport:origins(), Req);
route(<<"PUT">>, [<<"transports">>, <<"origins">>, Name], U, Req) ->
    with_body(Req, fun(B, R) -> reply(ana_transport:save_origin(Name, B, U), R) end);
route(<<"DELETE">>, [<<"transports">>, <<"origins">>, Name], U, Req) ->
    reply(ana_transport:delete_origin(Name, U), Req);
route(<<"POST">>, [<<"transports">>, <<"export">>], U, Req) ->
    with_body(Req, fun(B, R) -> reply(ana_transport:export(B, U), R) end);
route(<<"POST">>, [<<"transports">>, <<"receive">>], U, Req) ->
    case read_raw(Req, 20 * 1048576, <<>>) of
        {ok, Body, Req2} -> reply(ana_transport:receive_package(Body, U), Req2);
        {too_large, Req2} -> ana_http:reply_error(413, <<"BODY_TOO_LARGE">>, <<"pacote acima de 20 MiB: divida em partes"/utf8>>, Req2)
    end;
route(<<"GET">>, [<<"transports">>, Id], _U, Req) ->
    with_int(Id, Req, fun(N) -> reply(ana_transport:get(N), Req) end);
route(<<"POST">>, [<<"transports">>, Id, <<"import">>], U, Req) ->
    with_int(Id, Req, fun(N) -> with_body(Req, fun(B, R) -> transport_reply(ana_transport:import(N, B, U), R) end) end);
route(<<"POST">>, [<<"transports">>, Id, <<"revert">>], U, Req) ->
    with_int(Id, Req, fun(N) -> transport_reply(ana_transport:revert(N, U), Req) end);
route(<<"POST">>, [<<"transports">>, Id, <<"refuse">>], U, Req) ->
    with_int(Id, Req, fun(N) -> with_body(Req, fun(B, R) -> reply(ana_transport:refuse(N, B, U), R) end) end);

route(<<"GET">>, [<<"datacopy">>], _U, Req) ->
    reply(ana_datacopy:list(), Req);
route(<<"POST">>, [<<"datacopy">>, <<"export">>], U, Req) ->
    reply(ana_datacopy:export(U), Req);
route(<<"GET">>, [<<"datacopy">>, <<"masking">>], _U, Req) ->
    reply(ana_datacopy:masking(), Req);
route(<<"PUT">>, [<<"datacopy">>, <<"masking">>], U, Req) ->
    with_body(Req, fun(B, R) -> reply(ana_datacopy:save_rule(B, U), R) end);
route(<<"GET">>, [<<"datacopy">>, Id, <<"download">>], #{username := Who}, Req) ->
    with_int(Id, Req, fun(N) ->
        case ana_datacopy:file(N) of
            {ok, Path} ->
                ana_admin:log(Who, <<"datacopy.download">>, Id, null, null),
                Size = filelib:file_size(Path),
                cowboy_req:reply(200, #{<<"content-type">> => <<"application/octet-stream">>,
                                        <<"content-disposition">> => <<"attachment; filename=\"copia-", Id/binary, ".anadc\"">>,
                                        <<"cache-control">> => <<"no-store">>, <<"x-content-type-options">> => <<"nosniff">>},
                                 {sendfile, 0, Size, Path}, Req);
            E -> reply(E, Req)
        end
    end);
route(<<"POST">>, [<<"datacopy">>, <<"upload">>], U, Req) ->
    case ana_instance:role() of
        <<"production">> ->
            ana_http:reply_error(403, <<"INSTANCE_IS_PRODUCTION">>, <<"a produção não recebe cópias de dados"/utf8>>, Req);
        _ ->
            Path = ana_datacopy:upload_path(erlang:unique_integer([positive])),
            ok = filelib:ensure_dir(Path),
            {ok, F} = file:open(Path, [write, raw, binary]),
            case receive_file(Req, F, 0, 8 * 1073741824) of
                {ok, Size, Req2} -> ok = file:close(F), reply(ana_datacopy:uploaded(list_to_binary(Path), Size, U), Req2);
                {too_large, Req2} -> _ = file:close(F), _ = file:delete(Path),
                                     ana_http:reply_error(413, <<"BODY_TOO_LARGE">>, <<"cópia acima de 8 GiB"/utf8>>, Req2)
            end
    end;
route(<<"POST">>, [<<"datacopy">>, Id, <<"import">>], U, Req) ->
    with_int(Id, Req, fun(N) -> with_body(Req, fun(B, R) -> reply(ana_datacopy:import(N, B, U), R) end) end);

%% --- Public API (spec 010) -------------------------------------------------
route(<<"GET">>, [<<"api-clients">>], _U, Req) ->
    reply(ana_api:clients(), Req);
route(<<"POST">>, [<<"api-clients">>], U, Req) ->
    with_body(Req, fun(B, R) -> reply(ana_api:create_client(B, U), R) end);
route(<<"PUT">>, [<<"api-clients">>, Id], U, Req) ->
    with_body(Req, fun(B, R) -> reply(ana_api:update_client(Id, B, U), R) end);
route(<<"POST">>, [<<"api-clients">>, Id, <<"rotate-secret">>], U, Req) ->
    reply(ana_api:rotate_secret(Id, U), Req);
route(<<"POST">>, [<<"api-clients">>, Id, <<"drop-old-secret">>], U, Req) ->
    reply(ana_api:drop_secret(Id, true, U), Req);
route(<<"POST">>, [<<"api-clients">>, Id, <<"release-breaker">>], U, Req) ->
    reply(ana_api:release_breaker(Id, U), Req);
route(<<"POST">>, [<<"api-clients">>, Id, <<"signing-secret">>], U, Req) ->
    reply(ana_api:new_signing_secret(Id, U), Req);
route(<<"GET">>, [<<"api-calls">>], _U, Req) ->
    Q = ana_http:qs_map(Req),
    reply(ana_api:calls(#{client => case Q of #{<<"client">> := C} when C =/= <<>> -> C; _ -> null end}), Req);
route(<<"POST">>, [<<"api-keys">>, <<"rotate">>], U, Req) ->
    reply(ana_api:rotate_keys(U), Req);

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

with_int(Id, Req, Fun) ->
    case catch binary_to_integer(Id) of
        N when is_integer(N) -> Fun(N);
        _ -> invalid(Req)
    end.

transport_reply({error, #{code := Code} = E}, Req) when is_binary(Code) -> ana_http:json(409, #{error => E}, Req);
transport_reply(R, Req) -> reply(R, Req).

receive_file(Req, F, Size, Max) ->
    case cowboy_req:read_body(Req, #{length => 4 * 1048576, period => 60000}) of
        {_, Data, Req2} when Size + byte_size(Data) > Max -> {too_large, Req2};
        {ok, Data, Req2} -> ok = file:write(F, Data), {ok, Size + byte_size(Data), Req2};
        {more, Data, Req2} -> ok = file:write(F, Data), receive_file(Req2, F, Size + byte_size(Data), Max)
    end.

read_raw(Req, Max, Acc) ->
    case cowboy_req:read_body(Req, #{length => 1048576, period => 30000}) of
        {_, Data, Req2} when byte_size(Acc) + byte_size(Data) > Max -> {too_large, Req2};
        {ok, Data, Req2} -> {ok, <<Acc/binary, Data/binary>>, Req2};
        {more, Data, Req2} -> read_raw(Req2, Max, <<Acc/binary, Data/binary>>)
    end.

with_body(Req, Fun) ->
    case ana_http:read_json(Req) of
        {ok, B, Req2} when is_map(B) -> Fun(B, Req2);
        {ok, _, Req2} -> invalid(Req2);
        {too_large, Req2} ->
            ana_http:reply_error(413, <<"BODY_TOO_LARGE">>, <<"corpo da requisição grande demais"/utf8>>, Req2);
        {invalid, Req2} -> invalid(Req2)
    end.

invalid(Req) -> ana_http:reply_error(400, <<"INVALID">>, <<"requisição inválida"/utf8>>, Req).

with_id(Id, Req, Fun) ->
    case catch binary_to_integer(Id) of
        N when is_integer(N), N > 0 -> Fun(N);
        _ -> invalid(Req)
    end.
