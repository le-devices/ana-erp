%% SPDX-FileCopyrightText: 2026 André Luis Pereira dos Santos
%% SPDX-License-Identifier: AGPL-3.0-or-later
%% REST API for the studio (specs 001, 002, 004, 005, 007, 011).
-module(ana_http_api).
-export([init/2]).

-define(DEV, <<"developer">>).
-define(ADMIN, <<"admin">>).
-define(USER, <<"user">>).
-define(BUSINESS_SCHEMAS, [<<"base">>, <<"inventory">>, <<"sales">>, <<"finance">>,
                           <<"projects">>, <<"supply">>, <<"production">>, <<"logistics">>, <<"field">>, <<"analytics">>]).

init(Req, health) ->
    {ok, health(Req), health};
%% RF-023-01
init(Req, live) ->
    {ok, ana_http:json(200, ana_ha:live(), Req), live};
%% RF-019-02, CA-019-06: Prometheus text; admin/developer session or a robot key.
init(Req, metrics) ->
    Req2 = ana_http:require(Req, ?DEV, fun(_) ->
        cowboy_req:reply(200, #{<<"content-type">> => <<"text/plain; version=0.0.4; charset=utf-8">>},
                         ana_metrics:prometheus(), Req)
    end),
    {ok, Req2, metrics};
init(Req, ready) ->
    {Ok, Body} = ana_ha:ready(),
    {ok, ana_http:json(case Ok of true -> 200; false -> 503 end, Body, Req), ready};
init(Req, api) ->
    Method = cowboy_req:method(Req),
    Path = cowboy_req:path_info(Req),
    Req2 = try route(Method, Path, Req)
           catch Class:Reason:Stack ->
               logger:error("API error ~s ~0p: ~0p:~0p ~0p", [Method, Path, Class, Reason, Stack]),
               ana_http:reply_error(500, <<"INTERNAL">>, <<"erro interno">>, Req)
           end,
    {ok, Req2, api}.

%% ==========================================================================
%% Health (RF-001-07, RF-007-05)
%% ==========================================================================

health(Req) ->
    Db = case catch ana_db:one("SELECT 1 AS ok", []) of
        {ok, #{<<"ok">> := 1}} -> <<"ok">>;
        _ -> <<"failed">>
    end,
    Status = case Db of <<"ok">> -> 200; _ -> 503 end,
    ana_http:json(Status, #{status => case Status of 200 -> ok; _ -> degraded end,
                            database => Db,
                            version => version(),
                            analytics => try ana_analytics:status() catch _:_ -> #{} end}, Req).

version() ->
    {ok, V} = application:get_key(ana, vsn),
    list_to_binary(V).

%% ==========================================================================
%% Routes
%% ==========================================================================

%% --- Session (RF-001-05, RF-011-03) ---------------------------------------
route(<<"POST">>, [<<"session">>], Req) ->
    with_body(Req, fun
        (#{<<"username">> := U, <<"password">> := P}, R) when is_binary(U), is_binary(P), byte_size(P) < 1024 ->
            %% RF-024-02: the attempted login is recorded, never the password.
            ok = ana_access_log:tag(#{username => binary:part(U, 0, min(byte_size(U), 64)),
                                      auth => <<"password">>}, R),
            case ana_security:login(U, P, ana_http:ip(R)) of
                {ok, Token, User} -> ana_http:json(200, #{token => Token, user => User}, R);
                {error, locked} ->
                    ana_http:reply_error(429, <<"LOCKED">>, <<"muitas tentativas; aguarde alguns minutos">>, R);
                {error, credentials} ->
                    ana_http:reply_error(401, <<"CREDENTIALS">>, <<"login ou senha inválidos"/utf8>>, R);
                {error, unavailable} ->
                    ana_http:reply_error(503, <<"DB_UNAVAILABLE">>, <<"banco de dados indisponível no momento: tente de novo em instantes"/utf8>>,
                                         cowboy_req:set_resp_header(<<"retry-after">>, <<"2">>, R))
            end;
        (_, R) -> invalid(R)
    end);
route(<<"DELETE">>, [<<"session">>], Req) ->
    _ = case cowboy_req:header(<<"authorization">>, Req) of
        <<"Bearer ", T/binary>> -> ana_security:logout(T);
        _ -> ok
    end,
    cowboy_req:reply(204, Req);
%% Spec 009 (D11): the customer's logo, public (shown on the sign-in screen too); cached briefly.
route(<<"GET">>, [<<"company">>, <<"logo">>], Req) ->
    case ana_admin:logo() of
        {ok, Jpeg} -> cowboy_req:reply(200, #{<<"content-type">> => <<"image/jpeg">>, <<"cache-control">> => <<"max-age=300">>},
                                       Jpeg, Req);
        none -> ana_http:reply_error(404, <<"NOT_FOUND">>, <<"sem logotipo">>, Req)
    end;
%% Spec 009 (RF-009-08): what the banner needs, for anyone signed in (no customer data, no limits).
route(<<"GET">>, [<<"license">>], Req) ->
    ana_http:require_any(Req, fun(_U) ->
        L = ana_license:current(),
        ana_http:json(200, maps:with([state, reason, days_left, environment, valid_until], L), Req)
    end);
route(<<"GET">>, [<<"me">>], Req) ->
    ana_http:require_any(Req, fun(U) ->
        {Company, Logo} = case ana_admin:get_company() of
            {ok, #{<<"legal_name">> := N, <<"display_name">> := D, <<"has_logo">> := L}} ->
                {case D of null -> N; _ -> D end, L =:= true};
            _ -> {null, false}
        end,
        %% Spec 034: the screen marks development/test instances. Spec 009 (D11): the customer's brand.
        ana_http:json(200, (maps:without([trace, key_id], U))#{company => Company, company_logo => Logo,
                                                               instance => ana_instance:info()}, Req)
    end);
route(<<"POST">>, [<<"me">>, <<"password">>], Req) ->
    ana_http:require_any(Req, fun(U) ->
        with_body(Req, fun(#{<<"current">> := Cur, <<"new">> := New}, R) when is_binary(Cur), is_binary(New) ->
            case ana_security:change_password(U, Cur, New) of
                ok -> ana_http:json(200, #{ok => true}, R);
                {error, credentials} ->
                    ana_http:reply_error(400, <<"CREDENTIALS">>, <<"senha atual incorreta">>, R);
                {error, Msg} -> ana_http:reply_error(400, <<"WEAK_PASSWORD">>, Msg, R)
            end;
            (_, R) -> invalid(R)
        end)
    end);

%% --- Routines and favorites (spec 020) -----------------------------------
%% RF-020-03: runnable programs for this user (role, groups), with command codes.
route(<<"GET">>, [<<"routines">>], Req) ->
    ana_http:require(Req, ?USER, fun(U = #{username := Who}) ->
        {ok, Rows} = ana_db:rows(
            "SELECT p.name, p.description, p.docs, p.params, p.min_role, p.restricted, p.exposed, p.category, p.confirm, "
            "  (SELECT c.code FROM ana_system.command c WHERE c.program = p.name ORDER BY c.code LIMIT 1) AS command, "
            "  EXISTS (SELECT 1 FROM ana_system.user_favorite f WHERE f.program = p.name AND f.username = $1) AS favorite, "
            %% Spec 056 (RF-056-03): routines that write offer "Ensaiar".
            "  (w.name IS NOT NULL) AS writes "
            "FROM ana_system.program p LEFT JOIN (SELECT ana_system.writing_programs() AS name) w ON w.name = p.name "
            "WHERE p.active AND p.kind = 'program' AND p.in_menu ORDER BY p.name", [Who]),
        ana_http:json(200, [maps:without([<<"min_role">>, <<"restricted">>], R)
                            || R = #{<<"min_role">> := M, <<"name">> := N} <- Rows,
                               ana_security:has_role(U, M), ana_access:allowed(U, R),
                               %% RF-020-23: a module outside the license is not offered (spec 009).
                               ana_license:allowed(ana_license:module_of(N))], Req)
    end);

%% --- Categories of routines (spec 020, RF-020-20..23) ---------------------
route(<<"GET">>, [<<"categories">>], Req) ->
    ana_http:require(Req, ?USER, fun(U) -> ok_json(ana_categories:list(U), Req) end);
route(<<"POST">>, [<<"categories">>], Req) ->
    ana_http:require(Req, ?USER, fun(U) -> with_body(Req, fun(B, R) -> category_reply(ana_categories:create(U, B), R) end) end);
route(<<"PUT">>, [<<"categories">>, <<"order">>], Req) ->
    ana_http:require(Req, ?USER, fun(U) -> with_body(Req, fun(B, R) ->
        category_reply(ana_categories:reorder(U, maps:get(<<"ids">>, B, [])), R) end) end);
route(<<"PUT">>, [<<"categories">>, Id], Req) ->
    ana_http:require(Req, ?USER, fun(U) -> with_id(Id, Req, fun(N) ->
        with_body(Req, fun(B, R) -> category_reply(ana_categories:update(U, N, B), R) end) end) end);
route(<<"DELETE">>, [<<"categories">>, Id], Req) ->
    ana_http:require(Req, ?USER, fun(U) -> with_id(Id, Req, fun(N) -> category_reply(ana_categories:delete(U, N), Req) end) end);
route(<<"POST">>, [<<"categories">>, Id, <<"shortcuts">>], Req) ->
    ana_http:require(Req, ?USER, fun(U) -> with_id(Id, Req, fun(N) ->
        with_body(Req, fun(B, R) -> category_reply(ana_categories:add_shortcuts(U, N, maps:get(<<"items">>, B, [])), R) end) end) end);
route(<<"PUT">>, [<<"shortcuts">>, Id], Req) ->
    ana_http:require(Req, ?USER, fun(U) -> with_id(Id, Req, fun(N) ->
        with_body(Req, fun(B, R) -> category_reply(ana_categories:update_shortcut(U, N, B), R) end) end) end);
route(<<"DELETE">>, [<<"shortcuts">>, Id], Req) ->
    ana_http:require(Req, ?USER, fun(U) -> with_id(Id, Req, fun(N) -> category_reply(ana_categories:delete_shortcut(U, N), Req) end) end);
%% Spec 051 (D3, RF-051-03): the person's suggestions from usage — accept does it at once, declined never comes back.
route(<<"GET">>, [<<"suggestions">>], Req) ->
    ana_http:require(Req, ?USER, fun(#{username := Who}) -> {ok, L} = ana_suggestions:mine(Who), ana_http:json(200, L, Req) end);
route(<<"POST">>, [<<"suggestions">>, Id, <<"accept">>], Req) ->
    ana_http:require(Req, ?USER, fun(U) -> with_id(Id, Req, fun(N) -> with_body(Req, fun(B, R) ->
        suggestion_reply(ana_suggestions:accept(N, B, U), R) end) end) end);
route(<<"POST">>, [<<"suggestions">>, Id, <<"decline">>], Req) ->
    ana_http:require(Req, ?USER, fun(U) -> with_id(Id, Req, fun(N) -> suggestion_reply(ana_suggestions:decline(N, U), Req) end) end);
%% Table variants and screen state per user (RF-020-17/18).
route(<<"GET">>, [<<"ui">>, <<"variants">>], Req) ->
    ana_http:require(Req, ?USER, fun(U) ->
        ok_json(ana_ui_state:variants(U, maps:get(<<"screen">>, ana_http:qs_map(Req), <<>>)), Req) end);
route(<<"POST">>, [<<"ui">>, <<"variants">>], Req) ->
    ana_http:require(Req, ?USER, fun(U) -> with_body(Req, fun(B, R) -> category_reply(ana_ui_state:save_variant(U, B), R) end) end);
route(<<"DELETE">>, [<<"ui">>, <<"variants">>, Id], Req) ->
    ana_http:require(Req, ?USER, fun(U) -> with_id(Id, Req, fun(N) -> category_reply(ana_ui_state:delete_variant(U, N), Req) end) end);
%% Spec 050 (T-050-03): how long screens and calls took in the browser (batched, aggregated in memory).
route(<<"POST">>, [<<"ui">>, <<"perf">>], Req) ->
    ana_http:require(Req, ?USER, fun(#{username := Who}) -> with_body(Req, fun(B, R) ->
        ok_json(ana_ui_perf:record(maps:get(<<"samples">>, B, []), Who), R) end) end);
route(<<"GET">>, [<<"ui">>, <<"settings">>], Req) ->
    ana_http:require(Req, ?USER, fun(U) -> ok_json(ana_ui_state:settings(U), Req) end);
route(<<"PUT">>, [<<"ui">>, <<"settings">>], Req) ->
    ana_http:require(Req, ?USER, fun(U) -> with_body(Req, fun(B, R) ->
        category_reply(ana_ui_state:put_setting(U, maps:get(<<"key">>, B, null), maps:get(<<"value">>, B, null)), R) end) end);
route(<<"GET">>, [<<"me">>, <<"favorites">>], Req) ->
    ana_http:require(Req, ?USER, fun(#{username := Who}) ->
        ok_json(ana_db:rows("SELECT f.program, p.description FROM ana_system.user_favorite f "
                            "JOIN ana_system.program p ON p.name = f.program "
                            "WHERE f.username = $1 AND p.active ORDER BY f.position, f.created_at", [Who]), Req)
    end);
route(<<"PUT">>, [<<"me">>, <<"favorites">>, Program], Req) ->
    ana_http:require(Req, ?USER, fun(#{username := Who}) ->
        simple_reply(ana_db:exec("INSERT INTO ana_system.user_favorite (username, program) VALUES ($1, $2) "
                                 "ON CONFLICT DO NOTHING", [Who, Program]), Req)
    end);
route(<<"DELETE">>, [<<"me">>, <<"favorites">>, Program], Req) ->
    ana_http:require(Req, ?USER, fun(#{username := Who}) ->
        simple_reply(ana_db:exec("DELETE FROM ana_system.user_favorite WHERE username = $1 AND program = $2",
                                 [Who, Program]), Req)
    end);

%% --- Company values (spec 065) ---------------------------------------------
%% Everyone in the company sees them; who changes is decided per value (administrators and groups, D9).
route(<<"GET">>, [<<"values">>], Req) ->
    ana_http:require(Req, ?USER, fun(U) -> values_reply(ana_values:list(ana_http:qs_map(Req), U), Req) end);
route(<<"GET">>, [<<"values">>, <<"meta">>], Req) ->
    ana_http:require(Req, ?USER, fun(_) -> values_reply(ana_values:meta(), Req) end);
route(<<"POST">>, [<<"values">>, <<"preview">>], Req) ->
    ana_http:require(Req, ?USER, fun(U) ->
        with_body(Req, fun(B, R) when is_map(B) -> values_reply(ana_values:preview(B, U), R); (_, R) -> invalid(R) end)
    end);
route(<<"POST">>, [<<"values">>], Req) ->
    ana_http:require(Req, ?USER, fun(U) ->
        with_body(Req, fun(B, R) when is_map(B) -> values_reply(ana_values:define(B, U), R); (_, R) -> invalid(R) end)
    end);
route(<<"GET">>, [<<"values">>, Name], Req) ->
    ana_http:require(Req, ?USER, fun(U) -> values_reply(ana_values:detail(Name, U), Req) end);
route(<<"PUT">>, [<<"values">>, Name], Req) ->
    ana_http:require(Req, ?USER, fun(U) ->
        with_body(Req, fun(B, R) when is_map(B) -> values_reply(ana_values:redefine(Name, B, U), R); (_, R) -> invalid(R) end)
    end);
route(<<"POST">>, [<<"values">>, Name, <<"versions">>], Req) ->
    ana_http:require(Req, ?USER, fun(U) ->
        with_body(Req, fun(B, R) when is_map(B) -> values_reply(ana_values:propose(Name, B, U), R); (_, R) -> invalid(R) end)
    end);
route(<<"POST">>, [<<"values">>, Name, <<"versions">>, Id, Action], Req)
  when Action =:= <<"approve">>; Action =:= <<"refuse">>; Action =:= <<"withdraw">> ->
    ana_http:require(Req, ?USER, fun(U) ->
        with_body(Req, fun(B, R) ->
            Note = case B of #{<<"note">> := N} when is_binary(N), N =/= <<>> -> N; _ -> null end,
            with_integer(Id, R, fun(I) ->
                values_reply(case Action of
                                 <<"withdraw">> -> ana_values:withdraw(Name, I, U);
                                 _ -> ana_values:decide(Name, I, Action, Note, U)
                             end, R)
            end)
        end)
    end);

%% --- Programs (spec 002, RF-011-10) ---------------------------------------
%% --- Quality gate (spec 064) ------------------------------------------------
route(<<"POST">>, [<<"programs">>, <<"inspect">>], Req) ->
    ana_http:require(Req, ?DEV, fun(_) ->
        with_body(Req, fun(#{<<"source">> := S}, R) when is_binary(S) -> quality_reply(ana_quality:inspect(S), R);
                          (_, R) -> invalid(R)
                       end)
    end);
route(<<"GET">>, [<<"quality">>, <<"gate">>], Req) ->
    ana_http:require(Req, ?DEV, fun(_) ->
        Names = [N || N <- binary:split(maps:get(<<"programs">>, ana_http:qs_map(Req), <<>>), <<",">>, [global]), N =/= <<>>],
        quality_reply(ana_quality:gate(Names), Req)
    end);
route(<<"GET">>, [<<"quality">>, <<"exemptions">>], Req) ->
    ana_http:require(Req, ?DEV, fun(_) ->
        F = maps:with([<<"program">>, <<"status">>], ana_http:qs_map(Req)),
        quality_reply(ana_quality:exemptions(F), Req)
    end);
route(<<"POST">>, [<<"quality">>, <<"exemptions">>], Req) ->
    ana_http:require(Req, ?DEV, fun(U) ->
        with_body(Req, fun(B, R) when is_map(B) -> quality_reply(ana_quality:request_exemption(B, U), R); (_, R) -> invalid(R) end)
    end);
route(<<"POST">>, [<<"quality">>, <<"exemptions">>, Id, Decision], Req) when Decision =:= <<"approve">>; Decision =:= <<"refuse">> ->
    ana_http:require(Req, ?DEV, fun(U) ->
        with_body(Req, fun(B, R) ->
            Note = case B of #{<<"note">> := N} when is_binary(N) -> N; _ -> null end,
            case catch binary_to_integer(Id) of
                I when is_integer(I) ->
                    quality_reply(ana_quality:decide_exemption(I, case Decision of <<"approve">> -> <<"approved">>;
                                                                                      _ -> <<"refused">> end, Note, U), R);
                _ -> invalid(R)
            end
        end)
    end);

route(<<"GET">>, [<<"programs">>], Req) ->
    ana_http:require(Req, ?DEV, fun(_) ->
        ok_json(ana_program:list(ana_http:qs_int(<<"inactive">>, Req, 0) =:= 1), Req)
    end);
route(<<"GET">>, [<<"programs">>, Name, <<"performance">>], Req) ->
    ana_http:require(Req, ?DEV, fun(_) ->
        case ana_observability:program_performance(Name) of
            {ok, R} -> ana_http:json(200, R, Req);
            {error, not_found} -> ana_http:reply_error(404, <<"NOT_FOUND">>, <<"programa não encontrado"/utf8>>, Req)
        end
    end);
route(<<"GET">>, [<<"programs">>, Name], Req) ->
    ana_http:require(Req, ?DEV, fun(_) -> one_json(ana_program:get(Name), Req) end);
route(<<"PUT">>, [<<"programs">>, Name], Req) ->
    ana_http:require(Req, ?DEV, fun(U) -> transported(Req, fun() ->
        with_body(Req, fun(Fields, R) when is_map(Fields) ->
            New = ana_program:get(Name) =:= {ok, undefined},
            case validate_program(Fields) of
                ok when New ->
                    case ana_seeds:reserved(Name) of
                        true -> ana_http:reply_error(400, <<"PRODUCT_NAMESPACE">>,
                                    <<"esse namespace é do produto: crie seus programas em outro, por exemplo cli."/utf8,
                                      Name/binary>>, R);
                        false -> save_reply(ana_program:save(Name, Fields, U), R)
                    end;
                ok -> save_reply(ana_program:save(Name, Fields, U), R);
                {error, Msg} -> ana_http:reply_error(400, <<"INVALID">>, Msg, R)
            end;
            (_, R) -> invalid(R)
        end)
    end) end);
route(<<"DELETE">>, [<<"programs">>, Name], Req) ->
    transported(Req, fun() -> delete_program(Name, Req) end);
route(<<"GET">>, [<<"programs">>, Name, <<"limits">>], Req) ->
    ana_http:require(Req, ?DEV, fun(U) ->
        case ana_program:get(Name) of
            {ok, #{} = P} -> ana_http:json(200, ana_limits:describe(P, U), Req);
            _ -> one_json({ok, undefined}, Req)
        end
    end);
route(<<"GET">>, [<<"programs">>, Name, <<"versions">>], Req) ->
    ana_http:require(Req, ?DEV, fun(_) -> ok_json(ana_program:versions(Name), Req) end);
route(<<"GET">>, [<<"programs">>, Name, <<"versions">>, V], Req) ->
    ana_http:require(Req, ?DEV, fun(_) ->
        with_integer(V, Req, fun(N) -> one_json(ana_program:version(Name, N), Req) end)
    end);
route(<<"POST">>, [<<"programs">>, Name, <<"versions">>, V, <<"restore">>], Req) ->
    ana_http:require(Req, ?DEV, fun(U) -> transported(Req, fun() ->
        with_integer(V, Req, fun(N) -> save_reply(ana_program:restore(Name, N, U), Req) end)
    end) end);
%% --- Execution variants (spec 045) -------------------------------------------
route(<<"GET">>, [<<"variants">>], Req) ->
    ana_http:require(Req, ?USER, fun(U) -> values_reply(ana_variants:visible(U), Req) end);
route(<<"GET">>, [<<"programs">>, Name, <<"variants">>], Req) ->
    ana_http:require(Req, ?USER, fun(U) -> values_reply(ana_variants:list(Name, U), Req) end);
route(<<"POST">>, [<<"programs">>, Name, <<"variants">>], Req) ->
    ana_http:require(Req, ?USER, fun(U) ->
        with_body(Req, fun(B, R) when is_map(B) -> values_reply(ana_variants:save(Name, B, U), R); (_, R) -> invalid(R) end)
    end);
route(<<"DELETE">>, [<<"programs">>, Name, <<"variants">>, Id], Req) ->
    ana_http:require(Req, ?USER, fun(U) -> with_integer(Id, Req, fun(I) -> values_reply(ana_variants:delete(Name, I, U), Req) end) end);
route(<<"GET">>, [<<"programs">>, Name, <<"variants">>, Id, <<"preview">>], Req) ->
    ana_http:require(Req, ?USER, fun(U) -> with_integer(Id, Req, fun(I) -> values_reply(ana_variants:preview(Name, I, U), Req) end) end);
route(<<"POST">>, [<<"programs">>, Name, <<"variants">>, <<"clear_default">>], Req) ->
    ana_http:require(Req, ?USER, fun(U) -> values_reply(ana_variants:act(Name, null, <<"clear_default">>, U), Req) end);
route(<<"POST">>, [<<"programs">>, Name, <<"variants">>, Id, Action], Req)
  when Action =:= <<"publish">>; Action =:= <<"unpublish">>; Action =:= <<"company_default">>; Action =:= <<"restore">>;
       Action =:= <<"default">> ->
    ana_http:require(Req, ?USER, fun(U) -> with_integer(Id, Req, fun(I) -> values_reply(ana_variants:act(Name, I, Action, U), Req) end) end);

route(<<"POST">>, [<<"programs">>, Name, <<"run">>], Req) ->
    %% Spec 016: external portal accounts reach this route too; the execution only lets
    %% them run programs marked for the portal (ana_execution:load/2).
    ana_http:require_any(Req, fun
        (#{must_change_password := true}) ->
            ana_http:reply_error(403, <<"PASSWORD_CHANGE_REQUIRED">>, <<"troque sua senha para continuar">>, Req);
        (U = #{role := <<"external">>}) -> run(Name, U, Req);
        (U) ->
            case ana_security:has_role(U, ?USER) of
                true -> run(Name, U, Req);
                false -> ana_http:reply_error(403, <<"FORBIDDEN">>, <<"papel insuficiente">>, Req)
            end
    end);
route(<<"GET">>, [<<"portal">>, <<"programs">>], Req) ->
    ana_http:require_any(Req, fun(_) ->
        ok_json(ana_db:rows("SELECT name, description, params, docs FROM ana_system.program "
                            "WHERE portal AND active AND kind = 'program' ORDER BY description, name", []), Req)
    end);

%% --- Executions and debugger (specs 002, 004) -----------------------------
route(<<"GET">>, [<<"executions">>], Req) ->
    ana_http:require(Req, ?USER, fun(U) -> list_executions(U, Req) end);
route(<<"GET">>, [<<"executions">>, Id], Req) ->
    ana_http:require(Req, ?USER, fun(U) -> execution_reply(ana_execution:status(Id, U), Req) end);
route(<<"GET">>, [<<"executions">>, Id, <<"events">>], Req) ->
    ana_http:require(Req, ?USER, fun(U) ->
        Since = ana_http:qs_int(<<"since">>, Req, 0),
        Wait = ana_http:qs_int(<<"wait">>, Req, 0) =:= 1,
        execution_reply(ana_execution:events(Id, U, Since, Wait), Req)
    end);
route(<<"POST">>, [<<"executions">>, Id, <<"command">>], Req) ->
    ana_http:require(Req, ?USER, fun(U) ->
        with_body(Req, fun(Cmd, R) when is_map(Cmd) ->
            case ana_execution:command(Id, U, Cmd) of
                ok -> ana_http:json(200, #{ok => true}, R);
                {error, not_paused} ->
                    ana_http:reply_error(409, <<"NOT_PAUSED">>, <<"a execução não está pausada"/utf8>>, R);
                Other -> execution_reply(Other, R)
            end;
            (_, R) -> invalid(R)
        end)
    end);

%% --- Home panel (spec 048) -------------------------------------------------
route(<<"GET">>, [<<"home">>, <<"spaces">>], Req) ->
    ana_http:require(Req, ?USER, fun(U) -> home_reply(ana_home:spaces(U), Req) end);
route(<<"GET">>, [<<"home">>, <<"blocks">>, Id, <<"indicator">>], Req) ->
    ana_http:require(Req, ?USER, fun(U) ->
        with_integer(Id, Req, fun(N) ->
            home_reply(ana_home:indicator(U, N, ana_http:qs_int(<<"fresh">>, Req, 0) =:= 1), Req)
        end)
    end);

%% --- Quality of a program: tests, coverage, performance, failures (spec 064, phase 2) ---
route(<<"POST">>, [<<"programs">>, Name, <<"tests">>, <<"run">>], Req) ->
    ana_http:require(Req, ?DEV, fun(U) -> home_reply(ana_program_tests:run(Name, U), Req) end);
route(<<"GET">>, [<<"programs">>, Name, <<"quality">>], Req) ->
    ana_http:require(Req, ?DEV, fun(U) -> home_reply(ana_program_tests:overview(Name, U), Req) end);

%% --- Assistant (spec 052) --------------------------------------------------
route(<<"GET">>, [<<"assistant">>], Req) ->
    ana_http:require(Req, ?USER, fun(U) -> home_reply(ana_assistant:config(U), Req) end);
route(<<"POST">>, [<<"assistant">>, <<"ask">>], Req) ->
    ana_http:require(Req, ?USER, fun(U) ->
        with_body(Req, fun(#{<<"text">> := T} = B, R) when is_binary(T) ->
            home_reply(ana_assistant:ask(U, maps:get(<<"conversation">>, B, null), string:trim(T)), R);
            (_, R) -> invalid(R)
        end)
    end);
route(<<"GET">>, [<<"assistant">>, <<"conversations">>, Id], Req) ->
    ana_http:require(Req, ?USER, fun(U) -> home_reply(ana_assistant:conversation(U, Id), Req) end);
route(<<"POST">>, [<<"assistant">>, <<"actions">>, Id, Decision], Req) when Decision =:= <<"confirm">>; Decision =:= <<"decline">> ->
    ana_http:require(Req, ?USER, fun(U) -> home_reply(ana_assistant:decide(U, Id, Decision), Req) end);

%% --- Undo (spec 050, D5) ---------------------------------------------------
%% The routine that undoes runs as an ordinary execution of this user; the offer is theirs, once, within its time.
route(<<"POST">>, [<<"undo">>, Id], Req) ->
    ana_http:require(Req, ?USER, fun(U) ->
        case developer_view(U, ana_undo:run(Id, U)) of
            {ok, Res} -> ana_http:json(200, Res, Req);
            {error, Status, Code, Msg} -> ana_http:reply_error(Status, Code, Msg, Req);
            {error, #{<<"code">> := <<"FORBIDDEN">>} = E} -> ana_http:json(403, #{error => E}, Req);
            {error, E} -> ana_http:json(422, #{error => E}, Req)
        end
    end);

%% --- Commands (RF-005-06) -------------------------------------------------
route(<<"GET">>, [<<"commands">>], Req) ->
    ana_http:require(Req, ?USER, fun(U) ->
        {ok, Cs} = ana_program:commands(),
        ana_http:json(200, [maps:without([<<"restricted">>], C)
                            || C = #{<<"min_role">> := M, <<"program">> := P} <- Cs,
                               ana_security:has_role(U, M),
                               ana_access:allowed(U, C#{<<"name">> => P})], Req)
    end);
route(<<"PUT">>, [<<"commands">>, Code], Req) ->
    ana_http:require(Req, ?DEV, fun(_) ->
        with_body(Req, fun(#{<<"program">> := P} = C, R) when is_binary(P) ->
            simple_reply(ana_program:save_command(Code, P, maps:get(<<"description">>, C, <<>>)), R);
            (_, R) -> invalid(R)
        end)
    end);
route(<<"DELETE">>, [<<"commands">>, Code], Req) ->
    ana_http:require(Req, ?DEV, fun(_) -> simple_reply(ana_program:delete_command(Code), Req) end);

%% --- Catalog and SQL (RF-005-04, RF-005-05) -------------------------------
route(<<"GET">>, [<<"catalog">>], Req) ->
    ana_http:require(Req, ?DEV, fun(_) -> ok_json(catalog(), Req) end);
route(<<"GET">>, [<<"catalog">>, Schema, Table], Req) ->
    ana_http:require(Req, ?DEV, fun(_) ->
        case lists:member(Schema, ?BUSINESS_SCHEMAS) of
            true -> table(Schema, Table, Req);
            false -> ana_http:reply_error(404, <<"NOT_FOUND">>, <<"esquema fora do catálogo"/utf8>>, Req)
        end
    end);
route(<<"POST">>, [<<"sql">>], Req) ->
    ana_http:require(Req, ?DEV, fun(_) ->
        with_body(Req, fun(#{<<"sql">> := Sql}, R) when is_binary(Sql), byte_size(Sql) < 100000 ->
            ok = ana_access_log:tag(#{detail => Sql}, R),     % RF-024-03
            sql_console(Sql, R);
            (_, R) -> invalid(R)
        end)
    end);

%% --- Analytics (RF-007-03) ------------------------------------------------
route(<<"POST">>, [<<"analytics">>, <<"refresh">>], Req) ->
    ana_http:require(Req, ?DEV, fun(U) ->
        case ana_analytics:refresh(U, <<"studio">>) of
            {ok, R} -> ana_http:json(200, #{result => R}, Req);
            {error, E} -> ana_http:json(500, #{error => E}, Req)
        end
    end);

route(_, _, Req) ->
    ana_http:reply_error(404, <<"NOT_FOUND">>, <<"rota inexistente">>, Req).

%% ==========================================================================
%% Running (RF-002-10, RF-004-01)
%% ==========================================================================

run(Name, U, Req) ->
    with_body(Req, fun(B, R) when is_map(B) ->
        Debug = maps:get(<<"debug">>, B, false) =:= true,
        case Debug andalso not ana_security:has_role(U, ?DEV) of
            true -> ana_http:reply_error(403, <<"FORBIDDEN">>, <<"depuração exige papel developer"/utf8>>, R);
            false ->
                Given = case maps:get(<<"params">>, B, #{}) of
                    P when is_map(P) -> P;
                    _ -> #{}
                end,
                %% Spec 045 (D5): "variant" (id or name) — its values resolved now, the given ones over the free fields.
                case with_variant(Name, maps:get(<<"variant">>, B, null), Given, U) of
                    {error, Code, Msg} -> ana_http:reply_error(case Code of <<"VARIANT_NOT_FOUND">> -> 404; _ -> 422 end, Code, Msg, R);
                    {ok, Params, Variant} ->
                External = maps:get(role, U) =:= <<"external">>,
                Options = #{origin => <<"studio">>,
                            debug => Debug,
                            async => not External andalso maps:get(<<"async">>, B, false) =:= true,
                            breakpoints => as_list(maps:get(<<"breakpoints">>, B, [])),
                            stop_on_entry => maps:get(<<"stop_on_entry">>, B, false) =:= true,
                            commit => maps:get(<<"commit">>, B, false) =:= true,
                            %% Spec 056: rehearsal — runs whole, undone at the end, effects listed (any user who may run it).
                            rehearse => maps:get(<<"rehearse">>, B, false) =:= true,
                            timeout_ms => case External of true -> undefined; false -> maps:get(<<"timeout_ms">>, B, undefined) end,
                            profile => not External andalso maps:get(<<"profile">>, B, false) =:= true,
                            variant => Variant},
                case developer_view(U, ana_execution:run(Name, Params, U, Options)) of
                    {ok, Res} when Variant =/= null -> ana_http:json(200, Res#{variant => Variant}, R);
                    {ok, Res} -> ana_http:json(200, Res, R);
                    {error, #{<<"code">> := C} = E} when C =:= <<"OVERLOAD">>; C =:= <<"DRAINING">>;
                                                         C =:= <<"DB_UNAVAILABLE">> ->
                        ana_http:json(503, #{error => E}, R);
                    {error, #{<<"code">> := C} = E} when C =:= <<"QUOTA_EXCEEDED">>; C =:= <<"PROGRAM_BUSY">> ->
                        ana_http:json(429, #{error => E}, R);
                    {error, #{<<"code">> := C} = E} when C =:= <<"PROGRAM_NOT_FOUND">>; C =:= <<"PROGRAM_INACTIVE">>;
                                                         C =:= <<"NOT_EXECUTABLE">> ->
                        ana_http:json(404, #{error => E}, R);
                    {error, #{<<"code">> := <<"FORBIDDEN">>} = E} -> ana_http:json(403, #{error => E}, R);
                    {error, E} -> ana_http:json(422, #{error => E}, R)
                end
                end
        end;
        (_, R) -> invalid(R)
    end).

home_reply({ok, V}, Req) -> ana_http:json(200, V, Req);
home_reply({error, Status, Code, Msg}, Req) -> ana_http:reply_error(Status, Code, Msg, Req).

with_variant(_, null, Given, _) -> {ok, Given, null};
with_variant(Program, Ref, Given, U) when is_integer(Ref); is_binary(Ref) ->
    case ana_variants:apply(Program, Ref, Given, U) of
        {ok, Params, Info} -> {ok, Params, Info};
        E -> E
    end;
with_variant(_, _, _, _) -> {error, <<"INVALID">>, <<"variant: informe o id ou o nome da variante"/utf8>>}.

list_executions(U = #{username := Username}, Req) ->
    Limit = max(1, min(200, ana_http:qs_int(<<"limit">>, Req, 50))),
    Program = maps:get(<<"program">>, ana_http:qs_map(Req), null),
    All = ana_security:has_role(U, ?ADMIN) andalso ana_http:qs_int(<<"mine">>, Req, 0) =/= 1,
    ok_json(ana_db:rows(
        "SELECT id::text AS id, program, version, username, origin, debug, status, started_at, "
        "       duration_ms, error->>'code' AS error "
        "FROM ana_system.execution "
        "WHERE ($1 OR username = $2) AND ($3::text IS NULL OR program = $3) "
        "ORDER BY started_at DESC LIMIT $4", [All, Username, Program, Limit]), Req).

execution_reply({ok, R}, Req) -> ana_http:json(200, R, Req);
execution_reply({error, not_found}, Req) ->
    ana_http:reply_error(404, <<"NOT_FOUND">>, <<"execução não encontrada"/utf8>>, Req);
execution_reply({error, forbidden}, Req) ->
    ana_http:reply_error(403, <<"FORBIDDEN">>, <<"execução de outro usuário"/utf8>>, Req);
execution_reply({error, invalid_command}, Req) ->
    ana_http:reply_error(400, <<"INVALID">>, <<"comando inválido"/utf8>>, Req);
execution_reply({error, timeout}, Req) ->
    ana_http:reply_error(504, <<"TIMEOUT">>, <<"a execução não respondeu"/utf8>>, Req).

%% ==========================================================================
%% Catalog (RF-005-04)
%% ==========================================================================

catalog() ->
    ana_db:rows(
        "SELECT n.nspname AS schema, c.relname AS name, "
        "  CASE c.relkind WHEN 'r' THEN 'table' WHEN 'p' THEN 'table' WHEN 'v' THEN 'view' "
        "       WHEN 'm' THEN 'materialized_view' END AS kind, "
        "  obj_description(c.oid, 'pg_class') AS comment, "
        "  GREATEST(c.reltuples, 0)::bigint AS estimated_rows "
        "FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace "
        "WHERE n.nspname::text = ANY($1::text[]) AND c.relkind IN ('r', 'p', 'v', 'm') "
        "ORDER BY 1, 2", [?BUSINESS_SCHEMAS]).

table(Schema, Table, Req) ->
    {ok, Columns} = ana_db:rows(
        "SELECT a.attname AS name, format_type(a.atttypid, a.atttypmod) AS type, "
        "  NOT a.attnotnull AS nullable, pg_get_expr(d.adbin, d.adrelid) AS default_value, "
        "  col_description(c.oid, a.attnum) AS comment "
        "FROM pg_attribute a JOIN pg_class c ON c.oid = a.attrelid "
        "JOIN pg_namespace n ON n.oid = c.relnamespace "
        "LEFT JOIN pg_attrdef d ON d.adrelid = a.attrelid AND d.adnum = a.attnum "
        "WHERE n.nspname = $1 AND c.relname = $2 AND a.attnum > 0 AND NOT a.attisdropped "
        "ORDER BY a.attnum", [Schema, Table]),
    {ok, Indexes} = ana_db:rows(
        "SELECT indexname AS name, indexdef AS definition FROM pg_indexes "
        "WHERE schemaname = $1 AND tablename = $2 ORDER BY 1", [Schema, Table]),
    {ok, Constraints} = ana_db:rows(
        "SELECT con.conname AS name, pg_get_constraintdef(con.oid) AS definition "
        "FROM pg_constraint con JOIN pg_class c ON c.oid = con.conrelid "
        "JOIN pg_namespace n ON n.oid = c.relnamespace "
        "WHERE n.nspname = $1 AND c.relname = $2 ORDER BY 1", [Schema, Table]),
    case Columns of
        [] -> ana_http:reply_error(404, <<"NOT_FOUND">>, <<"tabela não encontrada"/utf8>>, Req);
        _ -> ana_http:json(200, #{schema => Schema, table => Table, columns => Columns,
                                  indexes => Indexes, constraints => Constraints}, Req)
    end.

%% RF-005-05: own connection as ana_read, read-only transaction.
sql_console(Sql, Req) ->
    %% RF-023-05: replicas for reading when ANA_DB_READ_HOSTS is set.
    Conn = case ana_config:text("ANA_DB_READ_HOSTS", "") of
        "" -> ana_db:connect(ana_config:db_role(read));
        Replicas -> ana_db:connect_read(ana_config:db_role(read), Replicas)   % replicas down: the primary answers
    end,
    case Conn of
        {ok, C} ->
            try
                [{ok, [], []}, {ok, [], []}] =
                    epgsql:squery(C, "BEGIN READ ONLY; SET LOCAL statement_timeout = 10000"),
                case ana_db:query_limited(C, Sql, 1000) of
                    {ok, R} -> ana_http:json(200, R, Req);
                    {error, E} -> ana_http:json(400, #{error => E}, Req)
                end
            after
                epgsql:close(C)
            end;
        {error, _} ->
            ana_http:reply_error(503, <<"UNAVAILABLE">>, <<"console SQL indisponível"/utf8>>, Req)
    end.

%% ==========================================================================
%% Helpers
%% ==========================================================================

%% RF-019-04: frames and local variables of an error are for developers only.
developer_view(U, R) ->
    case ana_security:has_role(U, ?DEV) of
        true -> R;
        false -> strip(R)
    end.

strip({error, E}) when is_map(E) ->
    E2 = maps:without([<<"frames">>, <<"locals">>, <<"trace">>], E),
    {error, case maps:find(<<"events">>, E2) of
        {ok, Evs} when is_list(Evs) -> E2#{<<"events">> => [strip_event(Ev) || Ev <- Evs]};
        _ -> E2
    end};
strip({ok, #{events := Evs} = Res}) when is_list(Evs) -> {ok, Res#{events => [strip_event(Ev) || Ev <- Evs]}};
strip(R) -> R.

strip_event(#{<<"error">> := E} = Ev) when is_map(E) ->
    Ev#{<<"error">> => maps:without([<<"frames">>, <<"locals">>, <<"trace">>], E)};
strip_event(Ev) -> Ev.


%% Spec 034 (RF-034-01): production with "transport_required" changes programs only by package.
transported(Req, Fun) ->
    case ana_instance:transport_required() of
        true -> ana_http:reply_error(409, <<"TRANSPORT_REQUIRED">>,
                                     <<"nesta produção programas só mudam por pacote de transporte (Administração → Transportes)"/utf8>>, Req);
        false -> Fun()
    end.

delete_program(Name, Req) ->
    case ana_http:qs_int(<<"purge">>, Req, 0) of
        1 -> ana_http:require(Req, ?ADMIN, fun(U) -> save_reply(ana_program:purge(Name, U), Req) end);
        _ -> ana_http:require(Req, ?DEV, fun(U) -> save_reply(ana_program:deactivate(Name, U), Req) end)
    end.

validate_program(F) ->
    Checks = [
        {<<"source">>, fun(V) -> is_binary(V) andalso byte_size(V) =< 1024 * 1024 end},
        {<<"description">>, fun(V) -> is_binary(V) andalso byte_size(V) =< 500 end},
        {<<"kind">>, fun(V) -> lists:member(V, [<<"program">>, <<"library">>]) end},
        {<<"exposed">>, fun is_boolean/1},
        {<<"in_menu">>, fun is_boolean/1},
        {<<"portal">>, fun is_boolean/1},
        {<<"public">>, fun is_boolean/1},
        {<<"restricted">>, fun is_boolean/1},
        {<<"active">>, fun is_boolean/1},
        {<<"min_role">>, fun(V) -> lists:member(V, [?ADMIN, ?DEV, ?USER]) end},
        {<<"comment">>, fun(V) -> is_binary(V) andalso byte_size(V) =< 500 end},
        {<<"base_version">>, fun is_integer/1}],
    case [K || {K, Ok} <- Checks, maps:is_key(K, F), not Ok(maps:get(K, F))] of
        [] when is_map_key(<<"limits">>, F) -> ana_limits:validate(maps:get(<<"limits">>, F));
        [] -> ok;
        Bad -> {error, unicode:characters_to_binary(["campos inválidos: ", lists:join(", ", Bad)])}
    end.

save_reply({ok, R}, Req) -> ana_http:json(200, R, Req);
save_reply({error, invalid_name}, Req) ->
    ana_http:reply_error(400, <<"INVALID_NAME">>, <<"nome de programa inválido"/utf8>>, Req);
save_reply({error, source_required}, Req) ->
    ana_http:reply_error(400, <<"SOURCE_REQUIRED">>, <<"programa novo exige fonte">>, Req);
save_reply({error, not_found}, Req) ->
    ana_http:reply_error(404, <<"NOT_FOUND">>, <<"não encontrado"/utf8>>, Req);
save_reply({error, {conflict, V}}, Req) ->
    ana_http:json(409, #{error => #{code => <<"CONFLICT">>, current_version => V,
                                    message => <<"o programa foi alterado por outra pessoa">>}}, Req);
save_reply({error, #{} = E}, Req) ->
    ana_http:json(400, #{error => E}, Req).

simple_reply({ok, _}, Req) -> ana_http:json(200, #{ok => true}, Req);
simple_reply({error, E}, Req) -> ana_http:json(400, #{error => E}, Req).

category_reply({ok, V}, Req) -> ana_http:json(200, V, Req);
category_reply({error, not_found}, Req) -> ana_http:reply_error(404, <<"NOT_FOUND">>, <<"não encontrado"/utf8>>, Req);
category_reply({error, Msg}, Req) when is_binary(Msg) -> ana_http:reply_error(400, <<"INVALID">>, Msg, Req).

with_id(Id, Req, Fun) ->
    case catch binary_to_integer(Id) of
        N when is_integer(N) -> Fun(N);
        _ -> ana_http:reply_error(400, <<"INVALID">>, <<"identificador inválido"/utf8>>, Req)
    end.

ok_json({ok, V}, Req) -> ana_http:json(200, V, Req);
ok_json({error, E}, Req) -> ana_http:json(500, #{error => E}, Req).

one_json({ok, undefined}, Req) -> ana_http:reply_error(404, <<"NOT_FOUND">>, <<"não encontrado"/utf8>>, Req);
one_json(R, Req) -> ok_json(R, Req).

with_body(Req, Fun) ->
    case ana_http:read_json(Req) of
        {ok, Body, Req2} -> Fun(Body, Req2);
        {too_large, Req2} ->
            ana_http:reply_error(413, <<"BODY_TOO_LARGE">>, <<"corpo da requisição grande demais"/utf8>>, Req2);
        {invalid, Req2} -> invalid(Req2)
    end.

with_integer(Bin, Req, Fun) ->
    try binary_to_integer(Bin) of N -> Fun(N)
    catch _:_ -> invalid(Req)
    end.

invalid(Req) -> ana_http:reply_error(400, <<"INVALID">>, <<"requisição inválida"/utf8>>, Req).

as_list(L) when is_list(L) -> L;
as_list(_) -> [].

values_reply({ok, V}, Req) -> ana_http:json(200, V, Req);
values_reply({error, Code, M}, Req) ->
    Status = case Code of
        <<"NOT_FOUND">> -> 404;
        <<"VALUE_NOT_FOUND">> -> 404;
        <<"FORBIDDEN">> -> 403;
        <<"FOUR_EYES">> -> 403;
        <<"CONFLICT">> -> 409;
        _ -> 400
    end,
    ana_http:reply_error(Status, Code, M, Req).

quality_reply({ok, V}, Req) -> ana_http:json(200, V, Req);
quality_reply({error, M}, Req) when is_binary(M) -> ana_http:reply_error(400, <<"INVALID">>, M, Req).

suggestion_reply({ok, V}, Req) -> ana_http:json(200, V, Req);
suggestion_reply({error, Status, Code, Msg}, Req) -> ana_http:reply_error(Status, Code, Msg, Req).
