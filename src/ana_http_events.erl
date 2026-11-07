%% Live screens (spec 062, D3; constitution P18/P20): one server-sent event stream per signed-in screen.
%% The connection is a light process subscribed to the event bus (ana_events): its user's topic
%% ("user:<login>": tasks and process notices) and "notices" (bells). Events only say "something
%% changed": the screen reads again what it may see, so permissions stay where they are. Limits per user
%% and per node; a heartbeat every 25 s; the browser reconnects by itself when the stream ends.
-module(ana_http_events).
-export([init/2, info/3, terminate/3]).

-define(PER_USER, 5).
-define(PER_NODE, 10000).
-define(HEARTBEAT_MS, 25000).
-define(TAB, ana_metrics).

init(Req, _) ->
    case ana_http:authenticate(Req) of
        {ok, #{username := U, role := Role}} when Role =/= <<"external">> ->
            case admit(U) of
                false ->
                    {ok, ana_http:reply_error(429, <<"TOO_MANY_STREAMS">>, <<"conexões ao vivo demais abertas"/utf8>>, Req), done};
                true ->
                    ok = ana_events:subscribe(<<"user:", U/binary>>),
                    ok = ana_events:subscribe(<<"notices">>),
                    Req2 = cowboy_req:stream_reply(200, #{<<"content-type">> => <<"text/event-stream">>,
                                                          <<"cache-control">> => <<"no-store">>,
                                                          <<"x-accel-buffering">> => <<"no">>}, Req),
                    ok = cowboy_req:stream_events(#{event => <<"ready">>, data => <<"{}">>}, nofin, Req2),
                    erlang:send_after(?HEARTBEAT_MS, self(), heartbeat),
                    {cowboy_loop, Req2, #{user => U}, hibernate}
            end;
        {ok, _} -> {ok, ana_http:reply_error(403, <<"FORBIDDEN">>, <<"papel insuficiente">>, Req), done};
        _ -> {ok, ana_http:reply_error(401, <<"NOT_AUTHENTICATED">>, <<"credencial ausente ou inválida"/utf8>>, Req), done}
    end.

info({ana_event, <<"notices">>, _}, Req, S) ->
    ok = cowboy_req:stream_events(#{event => <<"notices">>, data => <<"{}">>}, nofin, Req),
    {ok, Req, S, hibernate};
info({ana_event, <<"user:", _/binary>>, _}, Req, S) ->
    ok = cowboy_req:stream_events(#{event => <<"tasks">>, data => <<"{}">>}, nofin, Req),
    {ok, Req, S, hibernate};
info(heartbeat, Req, S) ->
    erlang:send_after(?HEARTBEAT_MS, self(), heartbeat),
    ok = cowboy_req:stream_events(#{comment => <<"ping">>}, nofin, Req),
    {ok, Req, S, hibernate};
info(_, Req, S) -> {ok, Req, S, hibernate}.

terminate(_, _, #{user := U}) ->
    _ = catch ets:update_counter(?TAB, {sse, U}, -1),
    _ = catch ets:update_counter(?TAB, sse_total, -1),
    ok;
terminate(_, _, _) -> ok.

%% Counted in the shared metrics table (no extra process): at most PER_USER and PER_NODE streams.
admit(U) ->
    Total = ets:update_counter(?TAB, sse_total, 1, {sse_total, 0}),
    Mine = ets:update_counter(?TAB, {sse, U}, 1, {{sse, U}, 0}),
    case Total =< ?PER_NODE andalso Mine =< ?PER_USER of
        true -> true;
        false ->
            _ = ets:update_counter(?TAB, sse_total, -1),
            _ = ets:update_counter(?TAB, {sse, U}, -1),
            false
    end.
