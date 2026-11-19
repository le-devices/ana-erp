%% SQL performance (spec 019, RF-019-06/07a): per-statement aggregates.
%%
%% Executions cast their measured statements here; aggregates live in memory
%% and are written once a minute (one upsert per distinct statement — P15).
%% Slow statements get a plan with EXPLAIN (GENERIC_PLAN): never executed,
%% at most once per statement per hour, on a program connection (ana_exec,
%% the same privileges the program had). Repeated statements in one
%% execution (N+1) become advice right away.
-module(ana_sql_stats).
-behaviour(gen_server).

-export([start_link/0, record/2, n_plus_one/6, flush/0, normalize/1, hash/1, summarize_plan/1]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2]).

-define(FLUSH_MS, 60000).
-define(MAX_KEYS, 20000).
-define(PLAN_EVERY_S, 3600).

start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

-spec normalize(binary()) -> binary().
normalize(Sql) ->
    S = re:replace(Sql, "\\s+", " ", [global, unicode, {return, binary}]),
    string:trim(S).

-spec hash(binary()) -> binary().
hash(Norm) ->
    binary:part(string:lowercase(binary:encode_hex(crypto:hash(sha, Norm))), 0, 16).

%% [{Hash, Sql, Calls, TotalUs, MaxUs, Rows}] of one execution of Program.
record(_Program, []) -> ok;
record(Program, Stats) ->
    ana_disk:note_writes(Program, Stats),                                                   % spec 063 (D4)
    ana_bounded:cast(?MODULE, {record, Program, Stats}, 50000).   % spec 062 (D7)

n_plus_one(Program, Hash, Sql, Calls, At, ExecId) ->
    gen_server:cast(?MODULE, {n_plus_one, Program, Hash, Sql, Calls, At, ExecId}).

flush() -> gen_server:call(?MODULE, flush, 30000).

%% ---------------------------------------------------------------- server

init([]) ->
    process_flag(trap_exit, true),
    erlang:send_after(?FLUSH_MS, self(), flush),
    {ok, #{aggs => #{}, dropped => 0, planned => #{}}}.

handle_call(flush, _From, S) ->
    {reply, ok, write(S)}.

handle_cast({record, Program, Stats}, S = #{aggs := A0, dropped := D}) ->
    {A, Dropped} = lists:foldl(fun({H, Sql, C, T, M, R}, {Acc, Dr}) ->
        case maps:find(H, Acc) of
            {ok, #{calls := C0, total_us := T0, max_us := M0, rows := R0, programs := P0, slow := Sl0} = E} ->
                {Acc#{H => E#{calls := C0 + C, total_us := T0 + T, max_us := max(M0, M), rows := R0 + R,
                              programs := add_program(Program, P0), slow := Sl0 + slow(M)}}, Dr};
            error when map_size(Acc) >= ?MAX_KEYS ->
                {Acc, Dr + 1};                                  % bounded memory (RNF-019-03)
            error ->
                {Acc#{H => #{sql => Sql, calls => C, total_us => T, max_us => M, rows => R,
                             programs => [Program], slow => slow(M)}}, Dr}
        end
    end, {A0, D}, Stats),
    {noreply, S#{aggs := A, dropped := Dropped}};
handle_cast({n_plus_one, Program, Hash, Sql, Calls, At, ExecId}, S) ->
    _ = spawn(fun() -> advise_n_plus_one(Program, Hash, Sql, Calls, At, ExecId) end),
    {noreply, S}.

handle_info(flush, S) ->
    S2 = write(S),
    erlang:send_after(?FLUSH_MS, self(), flush),
    {noreply, S2};
handle_info(_, S) ->
    {noreply, S}.

terminate(_, S) ->
    _ = write(S),
    ok.

slow(MaxUs) ->
    case MaxUs >= ana_settings:get(slow_sql_ms) * 1000 of true -> 1; false -> 0 end.

add_program(P, Ps) ->
    case lists:member(P, Ps) orelse length(Ps) >= 20 of true -> Ps; false -> [P | Ps] end.

write(S = #{aggs := A}) when map_size(A) =:= 0 -> S;
write(S = #{aggs := A, planned := Planned}) ->
    Rows = maps:to_list(A),
    Col = fun(F) -> [F(H, E) || {H, E} <- Rows] end,
    R = ana_db:exec(
        "INSERT INTO ana_system.sql_stat AS s (hash, sql, calls, total_ms, max_ms, rows, slow_calls, programs) "
        "SELECT h, q, c, t / 1000.0, m / 1000.0, r, sl, string_to_array(p, ',') FROM unnest("
        "  $1::text[], $2::text[], $3::bigint[], $4::bigint[], $5::bigint[], $6::bigint[], $7::bigint[], $8::text[]) "
        "  AS x(h, q, c, t, m, r, sl, p) "
        "ON CONFLICT (hash) DO UPDATE SET calls = s.calls + EXCLUDED.calls, total_ms = s.total_ms + EXCLUDED.total_ms, "
        "  max_ms = GREATEST(s.max_ms, EXCLUDED.max_ms), rows = s.rows + EXCLUDED.rows, "
        "  slow_calls = s.slow_calls + EXCLUDED.slow_calls, last_seen = now(), "
        "  programs = (SELECT array_agg(DISTINCT x) FROM unnest(s.programs || EXCLUDED.programs) x)",
        [Col(fun(H, _) -> H end), Col(fun(_, E) -> maps:get(sql, E) end), Col(fun(_, E) -> maps:get(calls, E) end),
         Col(fun(_, E) -> maps:get(total_us, E) end), Col(fun(_, E) -> maps:get(max_us, E) end),
         Col(fun(_, E) -> maps:get(rows, E) end), Col(fun(_, E) -> maps:get(slow, E) end),
         Col(fun(_, E) -> iolist_to_binary(lists:join(",", maps:get(programs, E))) end)]),
    case R of
        {ok, _} ->
            Now = erlang:system_time(second),
            Slow = [{H, maps:get(sql, E)} || {H, E} <- Rows, maps:get(slow, E) > 0,
                                             Now - maps:get(H, Planned, 0) > ?PLAN_EVERY_S],
            _ = Slow =/= [] andalso is_pid(spawn(fun() -> [explain(H, Q) || {H, Q} <- Slow] end)),
            Planned2 = maps:merge(maps:filter(fun(_, T) -> Now - T =< ?PLAN_EVERY_S end, Planned),
                                  maps:from_list([{H, Now} || {H, _} <- Slow])),
            S#{aggs := #{}, planned := Planned2};
        {error, E} ->
            logger:warning("sql stats not written (kept for the next minute): ~0p", [E]),
            S
    end.

%% ---------------------------------------------------------------- plans

explain(Hash, Sql) ->
    case ana_db:checkout(ana_db_exec, 5000) of
        {ok, C} ->
            R = try
                {ok, [], []} = epgsql:squery(C, "SET statement_timeout = 5000"),
                epgsql:squery(C, ["EXPLAIN (GENERIC_PLAN, VERBOSE, FORMAT JSON) ", Sql])
            after
                _ = epgsql:squery(C, "RESET statement_timeout"),
                ana_db:checkin(ana_db_exec, C)
            end,
            case R of
                {ok, _, [{Json} | _]} ->
                    Plan = json:decode(Json),
                    Summary = summarize_plan(Plan),
                    _ = ana_db:exec("UPDATE ana_system.sql_stat SET plan = $2::text::jsonb, plan_summary = $3, "
                                    "plan_at = now() WHERE hash = $1", [Hash, Json, Summary]),
                    ok;
                Other ->
                    logger:info("no plan for ~s: ~0p", [Hash, Other])
            end;
        _ -> ok
    end.

%% Sequential scans (table, estimated rows, filter and its columns), sorts and total cost.
-spec summarize_plan(term()) -> map().
summarize_plan([#{<<"Plan">> := Root} | _]) ->
    Nodes = walk(Root, []),
    Scans = [#{table => table(N), rows => maps:get(<<"Plan Rows">>, N, 0),
               filter => maps:get(<<"Filter">>, N, null), columns => columns(maps:get(<<"Filter">>, N, <<>>))}
             || N = #{<<"Node Type">> := <<"Seq Scan">>} <- Nodes],
    Tables = lists:usort([T || #{table := T} <- Scans, T =/= null]),
    Sizes = sizes(Tables),
    #{cost => maps:get(<<"Total Cost">>, Root, 0),
      node_types => lists:usort([T || #{<<"Node Type">> := T} <- Nodes]),
      seq_scans => [Sc#{table_rows => maps:get(T, Sizes, null)} || Sc = #{table := T} <- Scans],
      sorts => length([N || N = #{<<"Node Type">> := <<"Sort">>} <- Nodes])};
summarize_plan(_) -> #{}.

walk(N, Acc) ->
    lists:foldl(fun walk/2, [N | Acc], maps:get(<<"Plans">>, N, [])).

table(#{<<"Relation Name">> := R} = N) ->
    case maps:get(<<"Schema">>, N, undefined) of
        undefined -> R;
        Sch -> <<Sch/binary, ".", R/binary>>
    end;
table(_) -> null.

%% Column names compared in the filter: "(name = $1)", "(lower(name) ~~ ...)". The conditions the database
%% adds for permission by data (row security, spec 009 D10: base.scope_*() and the ana.* settings) are not
%% the statement's own filter: their columns would turn the index tip into a wrong one.
columns(null) -> [];
columns(F0) when is_binary(F0) ->
    F = iolist_to_binary(lists:join(<<" AND ">>, [C || C <- conjuncts(F0), not row_security(C)])),
    {ok, Re} = re:compile("\\(?([a-z_][a-z0-9_]*)\\)?\\s*(=|<>|<=|>=|<|>|~~\\*?|!~~|IS\\b|= ANY)", [caseless]),
    Found = case re:run(F, Re, [global, {capture, [1], binary}]) of
        {match, Ms} -> [M || [M] <- Ms];
        nomatch -> []
    end,
    Skip = [<<"lower">>, <<"upper">>, <<"coalesce">>, <<"text">>, <<"date">>, <<"numeric">>, <<"integer">>],
    lists:usort([C || C <- Found, not lists:member(string:lowercase(C), Skip)]);
columns(_) -> [].

row_security(C) ->
    binary:match(C, [<<"scope_cc(">>, <<"scope_portfolio(">>, <<"scope_projects(">>, <<"current_setting('ana.">>]) =/= nomatch.

%% The top-level AND terms of a plan filter: "((a = $1) AND ((x) OR (y)))" -> ["(a = $1)", "((x) OR (y))"].
conjuncts(F) ->
    B = unwrap(string:trim(F)),
    [string:trim(T) || T <- split_and(B, 0, <<>>, []), T =/= <<>>].

unwrap(<<"(", _/binary>> = B) when byte_size(B) >= 2 ->
    Inner = binary:part(B, 1, byte_size(B) - 2),
    case binary:last(B) =:= $) andalso balanced(Inner, 0) of
        true -> unwrap(string:trim(Inner));
        false -> B
    end;
unwrap(B) -> B.

balanced(<<>>, D) -> D =:= 0;
balanced(<<"(", R/binary>>, D) -> balanced(R, D + 1);
balanced(<<")", _/binary>>, 0) -> false;
balanced(<<")", R/binary>>, D) -> balanced(R, D - 1);
balanced(<<"'", R/binary>>, D) -> balanced(skip_quoted(R), D);
balanced(<<_, R/binary>>, D) -> balanced(R, D).

skip_quoted(<<"''", R/binary>>) -> skip_quoted(R);
skip_quoted(<<"'", R/binary>>) -> R;
skip_quoted(<<_, R/binary>>) -> skip_quoted(R);
skip_quoted(<<>>) -> <<>>.

split_and(<<>>, _, Cur, Acc) -> lists:reverse([Cur | Acc]);
split_and(<<" AND ", R/binary>>, 0, Cur, Acc) -> split_and(R, 0, <<>>, [Cur | Acc]);
split_and(<<"(", R/binary>>, D, Cur, Acc) -> split_and(R, D + 1, <<Cur/binary, "(">>, Acc);
split_and(<<")", R/binary>>, D, Cur, Acc) -> split_and(R, D - 1, <<Cur/binary, ")">>, Acc);
split_and(<<"'", R/binary>>, D, Cur, Acc) ->
    Rest = skip_quoted(R),
    Quoted = binary:part(R, 0, byte_size(R) - byte_size(Rest)),
    split_and(Rest, D, <<Cur/binary, "'", Quoted/binary>>, Acc);
split_and(<<C, R/binary>>, D, Cur, Acc) -> split_and(R, D, <<Cur/binary, C>>, Acc).

sizes([]) -> #{};
sizes(Tables) ->
    case catch ana_db:rows("SELECT n.nspname || '.' || c.relname AS t, GREATEST(c.reltuples, 0)::bigint AS rows "
                     "FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace "
                     "WHERE (n.nspname || '.' || c.relname) = ANY($1::text[])", [Tables]) of
        {ok, Rows} -> maps:from_list([{T, R} || #{<<"t">> := T, <<"rows">> := R} <- Rows]);
        _ -> #{}
    end.

%% ---------------------------------------------------------------- N+1

advise_n_plus_one(Program, Hash, Sql, Calls, At, ExecId) ->
    {Where, Line} = case At of
        [W, L] -> {W, L};
        _ -> {Program, null}
    end,
    Batch = case re:run(Sql, "^\\s*(INSERT|UPDATE|DELETE)", [caseless, {capture, none}]) of
        match -> <<"Grave em lote com ana.sql_batch(…) — um comando, uma ida ao banco."/utf8>>;
        nomatch -> <<"Leia tudo de uma vez: WHERE id = ANY($1) com a lista, ou um JOIN; depois agrupe em Python."/utf8>>
    end,
    Evidence = #{program => Program, where => Where, line => Line, calls => Calls,
                 execution_id => ExecId, sql => Sql, hash => Hash},
    ana_advisor:upsert(<<"n_plus_one">>, <<Where/binary, ":", Hash/binary>>, <<"warning">>,
        unicode:characters_to_binary(io_lib:format("Mesma consulta ~b vezes numa execução (N+1) em ~ts~ts",
                                                   [Calls, Where, case Line of null -> ""; _ -> io_lib:format(", linha ~b", [Line]) end])),
        <<"Cada repetição é uma ida ao banco; com mais dados, a execução fica proporcionalmente mais lenta."/utf8>>,
        Batch, Evidence).
