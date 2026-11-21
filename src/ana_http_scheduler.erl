%% SPDX-FileCopyrightText: 2026 LE Devices
%% SPDX-License-Identifier: AGPL-3.0-or-later
%% Scheduler API (spec 018, RF-018-07/09). Managing jobs requires developer;
%% running as another user requires admin (checked in ana_schedule).
-module(ana_http_scheduler).
-export([init/2]).

init(Req, scheduler) ->
    Method = cowboy_req:method(Req),
    Path = cowboy_req:path_info(Req),
    Req2 = try
               case {Method, Path} of
                   {<<"GET">>, [<<"notifications">>]} ->
                       %% Every user sees warnings of the jobs they own (home page).
                       ana_http:require(Req, <<"user">>, fun(U) -> route(Method, Path, U, Req) end);
                   {<<"POST">>, [<<"notifications">>, _, <<"read">>]} ->
                       ana_http:require(Req, <<"user">>, fun(U) -> route(Method, Path, U, Req) end);
                   _ ->
                       ana_http:require(Req, <<"developer">>, fun(U) -> route(Method, Path, U, Req) end)
               end
           catch Class:Reason:Stack ->
               logger:error("scheduler API error ~s ~0p: ~0p:~0p ~0p", [Method, Path, Class, Reason, Stack]),
               ana_http:reply_error(500, <<"INTERNAL">>, <<"erro interno">>, Req)
           end,
    {ok, Req2, scheduler}.

route(<<"GET">>, [<<"jobs">>], _U, Req) ->
    reply(ana_schedule:list_jobs(ana_http:qs_map(Req)), Req);
route(<<"POST">>, [<<"jobs">>], U, Req) ->
    with_body(Req, fun(B, R) -> reply(ana_schedule:save_job(new, B, U), R) end);
route(<<"GET">>, [<<"jobs">>, Id], _U, Req) ->
    with_id(Id, Req, fun(N) -> reply(ana_schedule:get_job(N), Req) end);
route(<<"PUT">>, [<<"jobs">>, Id], U, Req) ->
    with_id(Id, Req, fun(N) -> with_body(Req, fun(B, R) -> reply(ana_schedule:save_job(N, B, U), R) end) end);
route(<<"DELETE">>, [<<"jobs">>, Id], U, Req) ->
    with_id(Id, Req, fun(N) -> reply(ana_schedule:delete_job(N, U), Req) end);
route(<<"POST">>, [<<"jobs">>, Id, <<"run">>], U, Req) ->
    with_id(Id, Req, fun(N) ->
        with_body(Req, fun(B, R) -> reply(ana_schedule:run_now(N, maps:get(<<"params">>, B, null), U), R) end)
    end);
route(<<"POST">>, [<<"jobs">>, Id, <<"pause">>], U, Req) ->
    with_id(Id, Req, fun(N) -> reply(ana_schedule:set_active(N, false, U), Req) end);
route(<<"POST">>, [<<"jobs">>, Id, <<"resume">>], U, Req) ->
    with_id(Id, Req, fun(N) -> reply(ana_schedule:set_active(N, true, U), Req) end);
route(<<"POST">>, [<<"jobs">>, Id, <<"skip-next">>], U, Req) ->
    with_id(Id, Req, fun(N) -> reply(ana_schedule:skip_next(N, U), Req) end);
route(<<"GET">>, [<<"jobs">>, Id, <<"preview">>], _U, Req) ->
    with_id(Id, Req, fun(N) -> reply(ana_schedule:preview(N, max(1, min(50, ana_http:qs_int(<<"n">>, Req, 10)))), Req) end);
route(<<"GET">>, [<<"jobs">>, Id, <<"occurrences">>], _U, Req) ->
    with_id(Id, Req, fun(N) ->
        reply(ana_schedule:occurrences(N, max(1, min(500, ana_http:qs_int(<<"limit">>, Req, 50)))), Req)
    end);
route(<<"GET">>, [<<"holidays">>], _U, Req) ->
    reply(ana_schedule:holidays(), Req);
route(<<"PUT">>, [<<"holidays">>, Day], U, Req) ->
    with_body(Req, fun(B, R) -> reply(ana_schedule:save_holiday(Day, maps:get(<<"description">>, B, <<>>), U), R) end);
route(<<"DELETE">>, [<<"holidays">>, Day], U, Req) ->
    reply(ana_schedule:delete_holiday(Day, U), Req);
route(<<"GET">>, [<<"notifications">>], U, Req) ->
    reply(ana_schedule:notifications(U, ana_http:qs_int(<<"unread">>, Req, 0) =:= 1), Req);
route(<<"POST">>, [<<"notifications">>, Id, <<"read">>], U, Req) ->
    with_id(Id, Req, fun(N) -> reply(ana_schedule:mark_read(N, U), Req) end);
route(<<"GET">>, [<<"status">>], _U, Req) ->
    ana_http:json(200, ana_scheduler:status(), Req);
route(_, _, _U, Req) ->
    ana_http:reply_error(404, <<"NOT_FOUND">>, <<"rota inexistente">>, Req).

reply({ok, V}, Req) -> ana_http:json(200, V, Req);
reply({error, not_found}, Req) -> ana_http:reply_error(404, <<"NOT_FOUND">>, <<"não encontrado"/utf8>>, Req);
reply({error, Msg}, Req) when is_binary(Msg) ->
    Status = case binary:match(Msg, <<"exige papel admin">>) of nomatch -> 400; _ -> 403 end,
    ana_http:reply_error(Status, case Status of 403 -> <<"FORBIDDEN">>; _ -> <<"INVALID">> end, Msg, Req);
reply({error, #{} = E}, Req) -> ana_http:json(400, #{error => E}, Req).

with_id(Bin, Req, Fun) ->
    try binary_to_integer(Bin) of N -> Fun(N)
    catch _:_ -> ana_http:reply_error(400, <<"INVALID">>, <<"identificador inválido"/utf8>>, Req)
    end.

with_body(Req, Fun) ->
    case ana_http:read_json(Req) of
        {ok, B, Req2} when is_map(B) -> Fun(B, Req2);
        {ok, _, Req2} -> ana_http:reply_error(400, <<"INVALID">>, <<"requisição inválida"/utf8>>, Req2);
        {too_large, Req2} -> ana_http:reply_error(413, <<"BODY_TOO_LARGE">>, <<"corpo grande demais">>, Req2);
        {invalid, Req2} -> ana_http:reply_error(400, <<"INVALID">>, <<"JSON inválido"/utf8>>, Req2)
    end.
