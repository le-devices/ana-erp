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
route(_, _, _, Req) ->
    ana_http:reply_error(404, <<"NOT_FOUND">>, <<"rota inexistente"/utf8>>, Req).

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
