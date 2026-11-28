%% SPDX-FileCopyrightText: 2026 André Luis Pereira dos Santos
%% SPDX-License-Identifier: AGPL-3.0-or-later
%% Technical actions over HTTP (spec 077, T-077-01, T-077-02). Any signed-in person reaches it; each action decides
%% who may run it (administrators, or the groups of its policy: the on-call team drains and pauses, only the technical
%% lead switches the primary). The ceremony of the risk holds here as on the screen.
%%
%%   GET  /api/tech/actions                       the catalog, with the effective risk and what this person may do
%%   POST /api/tech/actions/:code                 {params, confirmed, reason} → 200 done | 202 waiting for approval
%%   GET  /api/tech/requests                      pending requests and reviews
%%   POST /api/tech/requests/:id/approve|reject   a second person decides ({reason} to reject)
%%   GET  /api/tech/runs                          the record (administrators)
%%   PUT  /api/tech/policies/:code                {risk, groups, act_now} — stricter only (administrators)
%%   Parameters (T-077-04, administrators): GET parameters · GET parameters/:key/versions ·
%%   PUT parameters/:key {value|null, scope, node, minutes, reason, confirmed} · POST parameters/versions/:id/restore
%%   {reason} · GET parameters/export · POST parameters/compare {file} · POST parameters/import {file, reason}
-module(ana_http_tech).
-export([init/2, status/1]).

init(Req, tech) ->
    Method = cowboy_req:method(Req),
    Path = cowboy_req:path_info(Req),
    Req2 = try
               ana_http:require(Req, <<"user">>, fun(U) -> route(Method, Path, U, Req) end)
           catch Class:Reason:Stack ->
               logger:error("tech API error ~s ~0p: ~0p:~0p ~0p", [Method, Path, Class, Reason, Stack]),
               ana_http:reply_error(500, <<"INTERNAL">>, <<"erro interno">>, Req)
           end,
    {ok, Req2, tech}.

route(<<"GET">>, [<<"actions">>], U, Req) ->
    {ok, Rows} = ana_tech:catalog(U),
    ana_http:json(200, Rows, Req);
route(<<"POST">>, [<<"actions">>, Code], U, Req) ->
    body(Req, fun(B, R) ->
        Params = case maps:get(<<"params">>, B, #{}) of P when is_map(P) -> P; _ -> bad end,
        case Params of
            bad -> ana_http:reply_error(400, <<"INVALID">>, <<"params deve ser um objeto">>, R);
            _ ->
                Opts = #{confirmed => maps:get(<<"confirmed">>, B, false) =:= true,
                         reason => maps:get(<<"reason">>, B, null), origin => origin(R)},
                reply(ana_tech:run(Code, Params, U, Opts), R)
        end
    end);
route(<<"GET">>, [<<"requests">>], U, Req) ->
    {ok, Rows} = ana_tech:pending(U),
    ana_http:json(200, Rows, Req);
route(<<"POST">>, [<<"requests">>, Id, <<"approve">>], U, Req) ->
    with_int(Id, Req, fun(N) -> reply(ana_tech:approve(N, U, #{origin => origin(Req)}), Req) end);
route(<<"POST">>, [<<"requests">>, Id, <<"reject">>], U, Req) ->
    with_int(Id, Req, fun(N) ->
        body(Req, fun(B, R) ->
            case maps:get(<<"reason">>, B, null) of
                Reason when is_binary(Reason), byte_size(Reason) >= 3 -> reply(ana_tech:reject(N, U, Reason), R);
                _ -> ana_http:reply_error(400, <<"INVALID">>, <<"diga o motivo da recusa"/utf8>>, R)
            end
        end)
    end);
route(<<"GET">>, [<<"runs">>], U, Req) ->
    admin(U, Req, fun() ->
        {ok, Rows} = ana_tech:runs(#{limit => ana_http:qs_int(<<"limit">>, Req, 100)}),
        ana_http:json(200, Rows, Req)
    end);
route(<<"PUT">>, [<<"policies">>, Code], U, Req) ->
    admin(U, Req, fun() ->
        body(Req, fun(B, R) ->
            case ana_tech:save_policy(Code, B, U) of
                {ok, P} -> ana_http:json(200, P, R);
                {error, not_found} -> ana_http:reply_error(404, <<"NOT_FOUND">>, <<"ação técnica inexistente"/utf8>>, R);
                {error, M} -> ana_http:reply_error(400, <<"INVALID">>, M, R)
            end
        end)
    end);
route(<<"GET">>, [<<"parameters">>], U, Req) ->
    admin(U, Req, fun() -> {ok, L} = ana_params:list(U), ana_http:json(200, L, Req) end);
route(<<"GET">>, [<<"parameters">>, <<"export">>], U, Req) ->
    admin(U, Req, fun() -> {ok, E} = ana_params:export(), ana_http:json(200, E, Req) end);
route(<<"GET">>, [<<"parameters">>, Key, <<"versions">>], U, Req) ->
    admin(U, Req, fun() -> {ok, V} = ana_params:versions(Key), ana_http:json(200, V, Req) end);
route(<<"PUT">>, [<<"parameters">>, Key], U, Req) ->
    admin(U, Req, fun() ->
        body(Req, fun(B, R) ->
            Params = maps:merge(maps:with([<<"value">>, <<"scope">>, <<"node">>, <<"minutes">>, <<"reason">>], B),
                                #{<<"key">> => Key}),
            reply(ana_tech:run(<<"parameter.set">>, Params, U,
                               #{confirmed => maps:get(<<"confirmed">>, B, false) =:= true, origin => origin(R),
                                 reason => maps:get(<<"reason">>, B, null)}), R)
        end)
    end);
route(<<"PUT">>, [<<"parameters">>, Key, <<"risk">>], U, Req) ->
    admin(U, Req, fun() ->
        body(Req, fun(B, R) ->
            case ana_params:set_risk(Key, maps:get(<<"risk">>, B, null), U) of
                ok -> ana_http:json(200, #{key => Key, risk => ana_settings:risk_of(Key)}, R);
                {error, not_found} -> ana_http:reply_error(404, <<"NOT_FOUND">>, <<"parâmetro inexistente"/utf8>>, R);
                {error, M} -> ana_http:reply_error(400, <<"INVALID">>, M, R)
            end
        end)
    end);
route(<<"POST">>, [<<"parameters">>, <<"versions">>, Id, <<"restore">>], U, Req) ->
    admin(U, Req, fun() ->
        with_int(Id, Req, fun(N) ->
            body(Req, fun(B, R) ->
                case maps:get(<<"reason">>, B, null) of
                    Reason when is_binary(Reason), byte_size(Reason) >= 3 ->
                        case ana_params:restore(N, U, Reason) of
                            ok -> ana_http:json(200, #{ok => true}, R);
                            {error, not_found} -> ana_http:reply_error(404, <<"NOT_FOUND">>, <<"versão não encontrada"/utf8>>, R);
                            {error, E} -> ana_http:reply_error(400, <<"INVALID">>, unicode:characters_to_binary(io_lib:format("~0tp", [E])), R)
                        end;
                    _ -> ana_http:reply_error(400, <<"INVALID">>, <<"diga o motivo"/utf8>>, R)
                end
            end)
        end)
    end);
route(<<"POST">>, [<<"parameters">>, <<"compare">>], U, Req) ->
    admin(U, Req, fun() ->
        body(Req, fun(B, R) ->
            case ana_params:compare(maps:get(<<"file">>, B, #{})) of
                {ok, Diff} -> ana_http:json(200, Diff, R);
                {error, M} -> ana_http:reply_error(400, <<"INVALID">>, M, R)
            end
        end)
    end);
route(<<"POST">>, [<<"parameters">>, <<"import">>], U, Req) ->
    admin(U, Req, fun() ->
        body(Req, fun(B, R) ->
            case maps:get(<<"reason">>, B, null) of
                Reason when is_binary(Reason), byte_size(Reason) >= 3 ->
                    case ana_params:import(maps:get(<<"file">>, B, #{}), U, Reason) of
                        {ok, Res} -> ana_http:json(200, Res, R);
                        {error, M} -> ana_http:reply_error(400, <<"INVALID">>, M, R)
                    end;
                _ -> ana_http:reply_error(400, <<"INVALID">>, <<"diga o motivo"/utf8>>, R)
            end
        end)
    end);
%% The technical center's tabs (T-077-03): now, routine, capacity, changes, security, log.
route(<<"GET">>, [<<"central">>, Tab], U, Req) ->
    team(U, Req, fun() ->
        case ana_central:tab(Tab, U) of
            {ok, R} -> ana_http:json(200, R, Req);
            {error, M} -> ana_http:reply_error(404, <<"NOT_FOUND">>, M, Req)
        end
    end);

%% Guided runbooks (T-077-06): the technical team (administrators and the groups of the policies); each action inside
%% keeps its own permission and ceremony.
route(<<"GET">>, [<<"runbooks">>], U, Req) ->
    team(U, Req, fun() -> {ok, L} = ana_runbook:list(), ana_http:json(200, L, Req) end);
route(<<"GET">>, [<<"runbooks">>, <<"runs">>], U, Req) ->
    team(U, Req, fun() -> {ok, L} = ana_runbook:open_runs(), ana_http:json(200, L, Req) end);
route(<<"GET">>, [<<"runbooks">>, <<"runs">>, Id], U, Req) ->
    team(U, Req, fun() -> with_int(Id, Req, fun(N) -> runbook_reply(ana_runbook:run(N), Req) end) end);
route(<<"POST">>, [<<"runbooks">>, Code, <<"start">>], U, Req) ->
    team(U, Req, fun() -> runbook_reply(ana_runbook:start(Code, U, #{}), Req) end);
route(<<"POST">>, [<<"runbooks">>, <<"runs">>, Id, What], U, Req) ->
    team(U, Req, fun() ->
        with_int(Id, Req, fun(N) ->
            body(Req, fun(B, R) ->
                Result = case What of
                    <<"advance">> -> ana_runbook:advance(N, U, #{confirm => maps:get(<<"confirm">>, B, false) =:= true,
                                                                 step => maps:get(<<"step">>, B, false) =:= true});
                    <<"pause">> -> ana_runbook:pause(N, U);
                    <<"resume">> -> ana_runbook:resume(N, U);
                    <<"hand-over">> -> ana_runbook:hand_over(N, maps:get(<<"to">>, B, <<>>), U);
                    _ -> {error, <<"operação desconhecida"/utf8>>}
                end,
                runbook_reply(Result, R)
            end)
        end)
    end);

%% Diagnostic console (T-077-05, administrators).
route(<<"GET">>, [<<"console">>, <<"queries">>], U, Req) ->
    admin(U, Req, fun() -> {ok, Q} = ana_console:queries(), ana_http:json(200, Q, Req) end);
route(<<"POST">>, [<<"console">>, <<"queries">>], U, Req) ->
    admin(U, Req, fun() -> body(Req, fun(B, R) -> console_reply(ana_console:save_query(B, U), R) end) end);
route(<<"DELETE">>, [<<"console">>, <<"queries">>, Code], U, Req) ->
    admin(U, Req, fun() ->
        case ana_console:delete_query(Code, U) of
            ok -> ana_http:json(200, #{ok => true}, Req);
            {error, M} -> ana_http:reply_error(400, <<"INVALID">>, M, Req)
        end
    end);
route(<<"POST">>, [<<"console">>, <<"queries">>, Code, <<"run">>], U, Req) ->
    admin(U, Req, fun() ->
        body(Req, fun(B, R) ->
            P = case maps:get(<<"params">>, B, #{}) of M when is_map(M) -> M; _ -> #{} end,
            console_reply(ana_console:run_query(Code, P, U), R)
        end)
    end);
route(<<"POST">>, [<<"console">>, <<"sql">>], U, Req) ->
    admin(U, Req, fun() ->
        body(Req, fun(B, R) ->
            case maps:get(<<"sql">>, B, null) of
                Sql when is_binary(Sql), byte_size(Sql) > 0, byte_size(Sql) < 100000 ->
                    console_reply(ana_console:run_sql(Sql, U, #{explain => maps:get(<<"explain">>, B, false) =:= true}), R);
                _ -> ana_http:reply_error(400, <<"INVALID">>, <<"informe o SQL"/utf8>>, R)
            end
        end)
    end);
route(<<"GET">>, [<<"console">>, <<"core">>], U, Req) ->
    admin(U, Req, fun() ->
        {ok, S} = ana_core_view:snapshot(),
        ana_http:json(200, S, Req)
    end);
route(<<"GET">>, [<<"console">>, <<"logs">>], U, Req) ->
    admin(U, Req, fun() ->
        Q = ana_http:qs_map(Req),
        F = #{level => maps:get(<<"level">>, Q, <<"info">>), text => maps:get(<<"text">>, Q, <<>>),
              subsystem => maps:get(<<"subsystem">>, Q, <<>>), limit => ana_http:qs_int(<<"limit">>, Req, 200),
              since => ana_http:qs_int(<<"since">>, Req, 0)},
        ana_http:json(200, #{node => ana_config:node_id(), lines => ana_log_ring:list(F)}, Req)
    end);
route(_, _, _, Req) ->
    ana_http:reply_error(404, <<"NOT_FOUND">>, <<"rota inexistente"/utf8>>, Req).

runbook_reply({ok, R}, Req) -> ana_http:json(200, R, Req);
runbook_reply({error, not_found}, Req) -> ana_http:reply_error(404, <<"NOT_FOUND">>, <<"não encontrado"/utf8>>, Req);
runbook_reply({error, M}, Req) -> ana_http:reply_error(409, <<"RUNBOOK">>, M, Req).

team(U, Req, Fun) ->
    case ana_tech:technical(U) of
        true -> Fun();
        false -> ana_http:reply_error(403, <<"FORBIDDEN">>, <<"só a equipe técnica"/utf8>>, Req)
    end.

console_reply({ok, R}, Req) -> ana_http:json(200, R, Req);
console_reply({error, M}, Req) -> ana_http:reply_error(400, <<"CONSOLE">>, M, Req).

reply({ok, Run}, Req) -> ana_http:json(200, Run, Req);
reply({pending, Run}, Req) ->
    ana_http:json(202, #{pending_approval => true, request => Run,
                         message => <<"ação de risco alto: aguarda a aprovação de outra pessoa"/utf8>>}, Req);
reply({error, Code, Msg}, Req) -> ana_http:reply_error(status(Code), Code, Msg, Req).

-spec status(binary()) -> pos_integer().
status(<<"NOT_FOUND">>) -> 404;
status(<<"FORBIDDEN">>) -> 403;
status(<<"INVALID">>) -> 400;
status(<<"ACTION_FAILED">>) -> 422;
status(_) -> 409.                    % CONFIRMATION_REQUIRED, PRECONDITION, FOUR_EYES, ACTION_DECIDED

admin(#{role := <<"admin">>}, _Req, Fun) -> Fun();
admin(_, Req, _) -> ana_http:reply_error(403, <<"FORBIDDEN">>, <<"só administradores"/utf8>>, Req).

origin(Req) ->
    case cowboy_req:header(<<"x-ana-origin">>, Req) of
        undefined -> <<"studio">>;
        O -> binary:part(O, 0, min(20, byte_size(O)))
    end.

with_int(Id, Req, Fun) ->
    case catch binary_to_integer(Id) of
        N when is_integer(N), N > 0 -> Fun(N);
        _ -> ana_http:reply_error(400, <<"INVALID">>, <<"identificador inválido"/utf8>>, Req)
    end.

body(Req, Fun) ->
    case cowboy_req:has_body(Req) of
        false -> Fun(#{}, Req);
        true ->
            case ana_http:read_json(Req) of
                {ok, B, Req2} when is_map(B) -> Fun(B, Req2);
                {ok, _, Req2} -> ana_http:reply_error(400, <<"INVALID">>, <<"corpo inválido"/utf8>>, Req2);
                {too_large, Req2} -> ana_http:reply_error(413, <<"BODY_TOO_LARGE">>, <<"corpo grande demais"/utf8>>, Req2);
                {invalid, Req2} -> ana_http:reply_error(400, <<"INVALID">>, <<"corpo inválido"/utf8>>, Req2)
            end
    end.
