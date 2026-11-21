%% SPDX-FileCopyrightText: 2026 André Luis Pereira dos Santos
%% SPDX-License-Identifier: AGPL-3.0-or-later
%% Access log (spec 024, RF-024-01..03, RNF-024-01).
%%
%% Requests are recorded through cowboy_metrics_h: the HTTP handlers attach
%% who the caller is (metrics_user_data) and the metrics callback casts one
%% entry here. Entries are buffered and written in batches; auditing never
%% delays or fails a request — beyond MAX_BUFFER entries new ones are dropped
%% and counted.
-module(ana_access_log).
-behaviour(gen_server).

-export([start_link/0, record/1, metrics_callback/1, tag/2, flush/0, dropped/0]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2]).

-define(FLUSH_MS, 1000).
-define(BATCH, 500).
-define(MAX_BUFFER, 50000).
-define(DETAIL_MAX, 4096).

start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

%% Entry: #{username, auth, api_key_id, ip, method, path, status, duration_ms, detail}
-spec record(map()) -> ok.
record(Entry) ->
    ana_bounded:cast(?MODULE, {record, Entry#{at => erlang:system_time(microsecond)}}, 50000).   % spec 062 (D7)

%% Attaches caller data to the current request (merged by cowboy_metrics_h).
-spec tag(map(), cowboy_req:req()) -> ok.
tag(Data, Req) ->
    cowboy_req:cast({set_options, #{metrics_user_data => Data}}, Req).

%% Runs in the connection process: must be cheap and never crash.
metrics_callback(#{req := #{path := Path, method := Method} = Req} = M) ->
    case audited(Path) of
        true ->
            try
                U = maps:get(user_data, M, #{}),
                Start = maps:get(req_start, M, undefined),
                End = maps:get(resp_end, M, undefined),
                Duration = case is_integer(Start) andalso is_integer(End) of
                    true -> erlang:convert_time_unit(End - Start, native, millisecond);
                    false -> null
                end,
                Ip = case maps:get(ip, U, undefined) of
                    undefined -> peer(Req);
                    I -> I
                end,
                record(#{username => maps:get(username, U, null),
                         auth => maps:get(auth, U, <<"anonymous">>),
                         api_key_id => maps:get(key_id, U, null),
                         ip => Ip, method => Method, path => Path,
                         status => status(maps:get(resp_status, M, undefined)),
                         duration_ms => Duration,
                         detail => maps:get(detail, U, null)})
            catch _:_ -> ok
            end;
        false -> ok
    end;
metrics_callback(_) -> ok.

audited(<<"/api/", _/binary>>) -> true;
audited(<<"/rpc", _/binary>>) -> true;
audited(_) -> false.

peer(#{peer := {Ip, _}}) -> list_to_binary(inet:ntoa(Ip));
peer(_) -> null.

status(S) when is_integer(S) -> S;
status(<<S:3/binary, _/binary>>) -> binary_to_integer(S);
status(_) -> null.

flush() -> gen_server:call(?MODULE, flush, 15000).

dropped() -> gen_server:call(?MODULE, dropped, 5000).

%% ---------------------------------------------------------------- server

init([]) ->
    process_flag(trap_exit, true),
    erlang:send_after(?FLUSH_MS, self(), flush),
    {ok, #{buffer => [], size => 0, dropped => 0}}.

handle_call(flush, _From, S) ->
    {reply, ok, write_all(S)};
handle_call(dropped, _From, S = #{dropped := D}) ->
    {reply, D, S}.

handle_cast({record, _}, S = #{size := N, dropped := D}) when N >= ?MAX_BUFFER ->
    _ = D rem 1000 =:= 0 andalso logger:warning("access log buffer full; ~b entries dropped", [D + 1]),
    {noreply, S#{dropped := D + 1}};
handle_cast({record, E}, S = #{buffer := B, size := N}) ->
    S2 = S#{buffer := [E | B], size := N + 1},
    case N + 1 >= ?BATCH of
        true -> {noreply, write_all(S2)};
        false -> {noreply, S2}
    end.

handle_info(flush, S) ->
    S2 = write_all(S),
    erlang:send_after(?FLUSH_MS, self(), flush),
    {noreply, S2};
handle_info(_, S) ->
    {noreply, S}.

terminate(_, S) ->
    _ = write_all(S),
    ok.

write_all(S = #{buffer := []}) -> S;
write_all(S = #{buffer := B}) ->
    case write(lists:reverse(B)) of
        ok -> S#{buffer := [], size := 0};
        error -> S       % kept; retried on the next tick (bounded by MAX_BUFFER)
    end.

write(Entries) ->
    write_batches(Entries).

write_batches([]) -> ok;
write_batches(Entries) ->
    {Batch, Rest} = case length(Entries) > ?BATCH of
        true -> lists:split(?BATCH, Entries);
        false -> {Entries, []}
    end,
    Col = fun(K) -> [v(maps:get(K, E, null)) || E <- Batch] end,
    Node = ana_config:node_id(),
    Insert = fun(C) ->
        {ok, [], []} = epgsql:squery(C, "SET LOCAL synchronous_commit TO off"),   % RF-025-03
        ana_db:query(C,
           "INSERT INTO ana_system.access_event (at, username, auth, api_key_id, ip, method, path, "
           "  status, duration_ms, node, detail) "
           "SELECT to_timestamp(a / 1000000.0), u, au, k, i, m, p, s, d, $10, de FROM unnest("
           "  $1::bigint[], $2::text[], $3::text[], $4::int[], $5::text[], $6::text[], $7::text[], "
           "  $8::int[], $9::int[], $11::text[]) AS t(a, u, au, k, i, m, p, s, d, de)",
           [Col(at), Col(username), Col(auth), Col(api_key_id), Col(ip), Col(method), Col(path),
            Col(status), Col(duration_ms), Node, [detail(D) || D <- Col(detail)]])
    end,
    case catch ana_db:transaction(Insert) of
        {ok, _} -> write_batches(Rest);
        {error, #{sqlstate := <<"2", C, _/binary>>} = E} when (C =:= $2 orelse C =:= $3), length(Batch) > 1 ->
            %% Data error (class 22/23): one bad entry must not hold back the others forever.
            logger:warning("access log batch refused, writing one by one: ~0p", [E]),
            _ = [write_batches([One]) || One <- Batch],
            write_batches(Rest);
        {error, #{sqlstate := <<"2", C, _/binary>>} = E} when C =:= $2; C =:= $3 ->
            logger:warning("access log entry dropped: ~0p", [E]),
            write_batches(Rest);
        {error, E} ->
            logger:warning("access log write failed: ~0p", [E]),
            error
    end.

v(undefined) -> null;
v(V) -> V.

detail(null) -> null;
detail(D) when is_binary(D), byte_size(D) > ?DETAIL_MAX ->
    unicode:characters_to_binary(string:slice(D, 0, ?DETAIL_MAX));
detail(D) when is_binary(D) -> D;
detail(_) -> null.
