%% SPDX-FileCopyrightText: 2026 André Luis Pereira dos Santos
%% SPDX-License-Identifier: AGPL-3.0-or-later
%% Interface performance (spec 050, T-050-03; P18): browsers send how long each screen took to open
%% and how long its calls to the server took. Samples are aggregated in memory (ETS counters) and
%% written once a minute, only for what changed (P15): one row per day, screen and kind, with a
%% histogram, so the p95 of any period comes from a few rows.
-module(ana_ui_perf).
-behaviour(gen_server).
-export([start_link/0, record/2, report/1, slow_screens/0]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2]).

-define(TAB, ana_ui_perf).
-define(BUCKETS, [50, 100, 200, 500, 1000, 2000, 5000]).
-define(FLUSH_MS, 60000).
-define(MAX_SAMPLES, 200).
-define(BUDGET_MS, 1000).

start_link() -> gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

%% One batch from a browser: [{"screen", "kind": "open"|"api", "ms", "long_tasks"?}]; bad items are skipped.
-spec record([map()], binary()) -> {ok, map()}.
record(Samples, _Who) when is_list(Samples) ->
    Day = date_key(),
    N = length([ok || S <- lists:sublist(Samples, ?MAX_SAMPLES), add(Day, S)]),
    {ok, #{accepted => N}};
record(_, _) -> {ok, #{accepted => 0}}.

add(Day, #{<<"screen">> := Screen, <<"kind">> := Kind, <<"ms">> := Ms} = S)
  when is_binary(Screen), byte_size(Screen) > 0, byte_size(Screen) =< 120, is_number(Ms), Ms >= 0, Ms =< 600000,
       (Kind =:= <<"open">> orelse Kind =:= <<"api">>) ->
    case re:run(Screen, "^[A-Za-z0-9_./:#-]+$", [{capture, none}]) of
        match ->
            Key = {Day, Screen, Kind},
            Bucket = length([B || B <- ?BUCKETS, Ms > B]) + 1,
            Long = case maps:get(<<"long_tasks">>, S, 0) of L when is_integer(L), L >= 0, L < 1000 -> L; _ -> 0 end,
            Init = {Key, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0},
            _ = ets:update_counter(?TAB, Key, [{2, 1}, {3, round(Ms)}, {3 + Bucket, 1}, {12, Long}], Init),
            true;
        nomatch -> false
    end;
add(_, _) -> false.

date_key() ->
    {{Y, M, D}, _} = calendar:universal_time(),
    unicode:characters_to_binary(io_lib:format("~4..0b-~2..0b-~2..0b", [Y, M, D])).

init([]) ->
    _ = ets:new(?TAB, [named_table, public, set, {write_concurrency, true}]),
    erlang:send_after(?FLUSH_MS, self(), flush),
    {ok, #{}}.

handle_call(flush_now, _, S) -> {reply, catch flush(), S};
handle_call(_, _, S) -> {reply, ok, S}.
handle_cast(_, S) -> {noreply, S}.

handle_info(flush, S) ->
    erlang:send_after(?FLUSH_MS, self(), flush),
    _ = catch flush(),
    {noreply, S};
handle_info(_, S) -> {noreply, S}.

%% Only keys with new samples are written; ets:take reads and removes atomically, so a sample that
%% arrives meanwhile starts a new counter and goes in the next minute (never counted twice).
flush() ->
    Keys = ets:select(?TAB, [{{'$1', '_', '_', '_', '_', '_', '_', '_', '_', '_', '_', '_'}, [], ['$1']}]),
    lists:foreach(fun(Key) ->
        case ets:take(?TAB, Key) of
            [{{Day, Screen, Kind}, N, Sum, B1, B2, B3, B4, B5, B6, B7, B8, Long} = Row] ->
                R = ana_db:exec("INSERT INTO ana_system.ui_perf (day, screen, kind, samples, total_ms, buckets, long_tasks) "
                                "VALUES ($1::date, $2, $3, $4, $5, $6, $7) ON CONFLICT (day, screen, kind) DO UPDATE SET "
                                "samples = ui_perf.samples + EXCLUDED.samples, total_ms = ui_perf.total_ms + EXCLUDED.total_ms, "
                                "buckets = ARRAY(SELECT a + b FROM unnest(ui_perf.buckets, EXCLUDED.buckets) AS x(a, b)), "
                                "long_tasks = ui_perf.long_tasks + EXCLUDED.long_tasks",
                                [Day, Screen, Kind, N, Sum, [B1, B2, B3, B4, B5, B6, B7, B8], Long]),
                case R of
                    {ok, _} -> ok;
                    _ -> merge_back(Row)                % the database did not answer: next minute
                end;
            [] -> ok
        end
    end, Keys),
    _ = ana_db:exec("DELETE FROM ana_system.ui_perf WHERE day < current_date - 90", []),
    ok.

merge_back({Key, N, Sum, B1, B2, B3, B4, B5, B6, B7, B8, Long}) ->
    Init = {Key, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0},
    _ = ets:update_counter(?TAB, Key, [{2, N}, {3, Sum}, {4, B1}, {5, B2}, {6, B3}, {7, B4}, {8, B5}, {9, B6},
                                       {10, B7}, {11, B8}, {12, Long}], Init),
    ok.

%% Per screen and kind over the last Days: samples, average, p50/p95 (upper bound of the bucket), long tasks.
-spec report(pos_integer()) -> {ok, [map()]}.
report(Days) ->
    _ = catch gen_server:call(?MODULE, flush_now, 5000),          % what the browsers sent this minute counts too
    {ok, Rows} = ana_db:rows(
        "SELECT screen, kind, sum(samples)::bigint AS samples, (sum(total_ms) / GREATEST(sum(samples), 1))::int AS avg_ms, "
        "  ARRAY(SELECT sum(b)::bigint FROM ana_system.ui_perf p2, unnest(p2.buckets) WITH ORDINALITY AS u(b, i) "
        "        WHERE p2.screen = p.screen AND p2.kind = p.kind AND p2.day > current_date - $1::int GROUP BY i ORDER BY i) AS buckets, "
        "  sum(long_tasks)::bigint AS long_tasks "
        "FROM ana_system.ui_perf p WHERE day > current_date - $1::int GROUP BY screen, kind ORDER BY screen, kind", [Days]),
    {ok, [R#{<<"p50_ms">> => pct(B, 0.5), <<"p95_ms">> => pct(B, 0.95), <<"budget_ms">> => ?BUDGET_MS}
          || R = #{<<"buckets">> := B} <- Rows]}.

pct(Buckets, P) ->
    Total = lists:sum(Buckets),
    pct(Buckets, ?BUCKETS ++ [null], P * Total, 0).
pct([], _, _, _) -> null;
pct([N | Rest], [Limit | Limits], Target, Acc) ->
    case Acc + N >= Target andalso Acc + N > 0 of
        true -> Limit;
        false -> pct(Rest, Limits, Target, Acc + N)
    end.

%% Screens whose opening p95 broke the budget in the last 7 days (with enough samples to mean it).
-spec slow_screens() -> [map()].
slow_screens() ->
    {ok, Rows} = report(7),
    [R || R = #{<<"kind">> := <<"open">>, <<"samples">> := N, <<"p95_ms">> := P} <- Rows,
          N >= 20, P =:= null orelse P > ?BUDGET_MS].
