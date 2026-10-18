%% PostgreSQL connection pools and query helpers (spec 001).
%%
%% - RF-001-02: pool size configurable (ANA_DB_POOL / ANA_DB_POOL_EXEC).
%% - RNF-001-07: waits for the database at startup with exponential backoff.
%% - RNF-001-08: a connection whose client died returns only after ROLLBACK.
%% - RNF-001-09: prepared statements reused per connection.
-module(ana_db).
-behaviour(gen_server).

-include_lib("epgsql/include/epgsql.hrl").

-export([start_link/3, wait_for_database/0, connect/1, connect/2, connect_read/2, hosts/1]).
-export([with_connection/1, with_connection/3, checkout/2, checkin/2, transaction/1,
         query/3, batch/3, squery/2, query_limited/3,
         rows/2, rows/3, one/2, exec/2, status/1, sql_error/1]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2]).

-define(CACHE, ana_stmt_cache).
-define(CACHE_MAX_PER_CONNECTION, 400).
-define(CHECKOUT_TIMEOUT, 15000).

-record(st, {
    name :: atom(),
    config :: fun(() -> map()),
    free = [] :: [pid()],
    busy = #{} :: #{reference() => {pid(), pid(), reference()}}, % Mon => {Conn, Client, Ref}
    queue = queue:new() :: queue:queue(),
    size :: pos_integer(),
    open = 0 :: non_neg_integer(),
    refill :: reference() | undefined,      % single reconnection timer
    backoff = 500 :: pos_integer()          % exponential backoff (ms)
}).

%% ==========================================================================
%% API
%% ==========================================================================

%% Name: registered pool (ana_db = core; ana_db_exec = programs, restricted role).
start_link(Name, Config, Size) ->
    gen_server:start_link({local, Name}, ?MODULE, {Name, Config, Size}, []).

%% RNF-001-07
-spec wait_for_database() -> ok | {error, term()}.
wait_for_database() ->
    wait_for_database(500, erlang:monotonic_time(millisecond) + 60000).

wait_for_database(Wait, Deadline) ->
    case connect(ana_config:db()) of
        {ok, C} ->
            ok = epgsql:close(C);
        {error, Reason} ->
            case erlang:monotonic_time(millisecond) + Wait > Deadline of
                true -> {error, Reason};
                false ->
                    logger:warning("database unavailable (~0p); retrying in ~b ms", [Reason, Wait]),
                    timer:sleep(Wait),
                    wait_for_database(min(Wait * 2, 8000), Deadline)
            end
    end.

%% RF-023-05: ANA_DB_HOST may list several addresses ("pg1,pg2"). With more
%% than one, only the primary is accepted (pg_is_in_recovery() = false), so a
%% promoted replica is found after a failover; the last address that worked
%% is tried first. Mode `any` accepts replicas (read-only use).
-spec connect(map()) -> {ok, pid()} | {error, term()}.
connect(Config) -> connect(Config, primary).

-spec connect(map(), primary | any) -> {ok, pid()} | {error, term()}.
connect(Config = #{host := Host}, Mode) ->
    case hosts(Host) of
        [Single] -> safe_connect(Config#{host => Single});
        Hosts -> try_hosts(prefer(Hosts), Config, Mode, no_hosts)
    end.

%% A failed epgsql:connect stops the connection process with the error as exit
%% reason, and the caller is linked to it: a caller that does not trap exits (an
%% HTTP request, for instance) would die instead of getting {error, Reason}.
safe_connect(Config) ->
    case process_flag(trap_exit, true) of
        true -> normalize(catch epgsql:connect(Config));          % already trapping (pools)
        false ->
            R = normalize(catch epgsql:connect(Config)),
            flush_exits(),
            process_flag(trap_exit, false),
            R
    end.

normalize({ok, C}) -> {ok, C};
normalize({error, R}) -> {error, R};
normalize({'EXIT', R}) -> {error, R};
normalize(Other) -> {error, Other}.

flush_exits() ->
    receive {'EXIT', _, _} -> flush_exits()
    after 0 -> ok
    end.

%% Read-only connections (SQL console): replicas first with a short connect
%% timeout; then the primary the pools are using (no new probing), then any.
-spec connect_read(map(), string()) -> {ok, pid()} | {error, term()}.
connect_read(Config, Replicas) ->
    Fast = Config#{timeout => 3000},
    case Replicas =/= "" andalso first_ok(hosts(Replicas), Fast, no_hosts) of
        {ok, C} -> {ok, C};
        _ ->
            Primary = persistent_term:get({?MODULE, last_primary}, undefined),
            All = hosts(maps:get(host, Config)),
            Order = case lists:member(Primary, All) of
                true -> [Primary | lists:delete(Primary, All)];
                false -> All
            end,
            first_ok(Order -- hosts(Replicas), Config, no_hosts)
    end.

-spec hosts(string()) -> [string()].
hosts(Host) ->
    [H || H0 <- string:split(Host, ",", all), H <- [string:trim(H0)], H =/= ""].

prefer(Hosts) ->
    Last = persistent_term:get({?MODULE, last_primary}, undefined),
    case lists:member(Last, Hosts) of
        true -> [Last | lists:delete(Last, Hosts)];
        false -> Hosts
    end.

%% Every address is probed; among the primaries the one with the newest WAL
%% timeline wins. A promoted replica always has a newer timeline than the old
%% primary, so an old primary that comes back without being demoted (split
%% brain) is never chosen — not even after the core restarts (CA T-023-09).
try_hosts(Hosts, Config, any, _) ->
    first_ok(Hosts, Config, no_hosts);
try_hosts(Hosts, Config, primary, _) ->
    %% An address that failed in the last 15 s is skipped (unless all did), so a dead
    %% host costs one connect timeout per window, not one per connection.
    Now = erlang:monotonic_time(millisecond),
    {Alive, Skipped} = lists:partition(fun(H) -> Now - persistent_term:get({?MODULE, down, H}, -100000) > 15000 end, Hosts),
    First = [{H, probe(H, Config)} || H <- Alive],
    %% No primary among the "alive" ones: the skipped addresses get their chance right away
    %% (a replica that was down a moment ago may be the new primary).
    Probes = case [x || {_, {primary, _, _}} <- First] of
        [] -> First ++ [{H, probe(H, Config)} || H <- Skipped];
        _ -> First
    end,
    _ = [persistent_term:put({?MODULE, down, H}, Now) || {H, {error, _}} <- Probes],
    _ = [persistent_term:erase({?MODULE, down, H}) || {H, {primary, _, _}} <- Probes],
    Primaries = [{TL, H, C} || {H, {primary, TL, C}} <- Probes],
    Last = case [R || {_, {error, R}} <- Probes] ++ [{not_primary, H} || {H, replica} <- Probes] of
        [] -> no_hosts;
        [R | _] -> R
    end,
    case lists:reverse(lists:keysort(1, Primaries)) of
        [] -> {error, Last};
        [{TL, H, C} | Others] ->
            _ = [catch epgsql:close(O) || {_, _, O} <- Others],
            _ = Others =/= [] andalso ok =:= logger:warning(
                  "more than one primary answered (~p); using ~s (timeline ~b)", [[X || {_, X, _} <- Primaries], H, TL]),
            persistent_term:put({?MODULE, last_primary}, H),
            {ok, C}
    end.

first_ok([], _, Last) -> {error, Last};
first_ok([H | Rest], Config, _) ->
    case safe_connect(Config#{host => H}) of
        {ok, C} -> {ok, C};
        {error, Reason} -> first_ok(Rest, Config, {H, Reason})
    end.

probe(H, Config) ->
    case safe_connect(Config#{host => H}) of
        {ok, C} ->
            case epgsql:squery(C, "SELECT pg_is_in_recovery(), CASE WHEN pg_is_in_recovery() THEN 0 ELSE "
                                  "('x' || substring(pg_walfile_name(pg_current_wal_lsn()) from 1 for 8))::bit(32)::int END") of
                {ok, _, [{<<"f">>, TL}]} -> {primary, binary_to_integer(TL), C};
                _ -> catch epgsql:close(C), replica
            end;
        {error, Reason} -> {error, {H, Reason}}
    end.

%% Runs Fun(Conn) with a connection borrowed from the pool.
-spec with_connection(fun((pid()) -> T)) -> T | {error, map()}.
with_connection(Fun) -> with_connection(?MODULE, Fun, ?CHECKOUT_TIMEOUT).

with_connection(Pool, Fun, Timeout) ->
    case checkout(Pool, Timeout) of
        {ok, C} ->
            try Fun(C)
            after checkin(Pool, C)
            end;
        {error, _} = E -> E
    end.

%% Generic transaction for internal core code.
-spec transaction(fun((pid()) -> {ok, T} | {error, term()})) -> {ok, T} | {error, term()}.
transaction(Fun) ->
    with_connection(fun(C) ->
        {ok, [], []} = epgsql:squery(C, "BEGIN"),
        try Fun(C) of
            {ok, _} = Ok ->
                case epgsql:squery(C, "COMMIT") of
                    {ok, [], []} -> Ok;
                    {error, E} -> {error, sql_error(E)}
                end;
            Other ->
                _ = epgsql:squery(C, "ROLLBACK"),
                Other
        catch Class:Reason:Stack ->
            _ = epgsql:squery(C, "ROLLBACK"),
            erlang:raise(Class, Reason, Stack)
        end
    end).

%% Parameterized query. Returns a compact, JSON-ready shape:
%%   {ok, #{columns => [#{name, type}], rows => [[V]], affected => N}}
-spec query(pid(), iodata(), [term()]) -> {ok, map()} | {error, map()}.
query(C, Sql, Params) ->
    case prepare(C, Sql) of
        {ok, #statement{types = Types} = St} ->
            case ana_types:coerce_params(Types, Params) of
                {ok, Values} -> result(epgsql:prepared_query(C, St, Values));
                {error, Msg} -> {error, #{code => <<"SQL_PARAMETER">>, message => Msg}}
            end;
        {error, _} = E -> E
    end.

%% Same statement with many parameter lists, in a single round trip.
-spec batch(pid(), iodata(), [[term()]]) -> {ok, map()} | {error, map()}.
batch(C, Sql, Batch) ->
    case prepare(C, Sql) of
        {ok, #statement{types = Types} = St} ->
            Coerced = [ana_types:coerce_params(Types, P) || P <- Batch],
            case [M || {error, M} <- Coerced] of
                [Msg | _] -> {error, #{code => <<"SQL_PARAMETER">>, message => Msg}};
                [] ->
                    {_Cols, Resps} = epgsql:execute_batch(C, St, [V || {ok, V} <- Coerced]),
                    sum_batch(Resps, 0)
            end;
        {error, _} = E -> E
    end.

%% Ad hoc query, no cache, reading at most Max rows from the server (portal
%% with a limit: huge results are never materialized). SQL console.
-spec query_limited(pid(), binary(), pos_integer()) -> {ok, map()} | {error, map()}.
query_limited(C, Sql, Max) ->
    case epgsql:parse(C, "", Sql, []) of
        {ok, #statement{types = [], columns = Cols} = St} ->
            case epgsql:bind(C, St, "", []) of
                ok ->
                    R = epgsql:execute(C, St, "", Max + 1),
                    _ = epgsql:sync(C),
                    case R of
                        {partial, Rows} ->
                            {ok, (compact(Cols, lists:sublist(Rows, Max), Max))#{truncated => true}};
                        {ok, Rows} when is_list(Rows) ->
                            {ok, (compact(Cols, Rows, length(Rows)))#{truncated => false}};
                        {ok, N} when is_integer(N) ->
                            {ok, #{columns => [], rows => [], affected => N, truncated => false}};
                        {ok, N, Rows} ->
                            {ok, (compact(Cols, Rows, N))#{truncated => false}};
                        {error, E} -> {error, sql_error(E)}
                    end;
                {error, E} -> {error, sql_error(E)}
            end;
        {ok, _} ->
            {error, #{code => <<"SQL_PARAMETER">>,
                      message => <<"parâmetros não são suportados no console"/utf8>>}};
        {error, E} -> {error, sql_error(E)}
    end.

squery(C, Sql) ->
    case epgsql:squery(C, Sql) of
        {error, E} -> {error, sql_error(E)};
        R -> R
    end.

%% Conveniences for core code: rows as maps with binary keys.
-spec rows(iodata(), [term()]) -> {ok, [map()]} | {error, map()}.
rows(Sql, Params) ->
    with_connection(fun(C) ->
        case query(C, Sql, Params) of
            {ok, R} -> {ok, as_maps(R)};
            E -> E
        end
    end).

%% The same inside a transaction (spec 039: the BPM engine moves a case under its lock).
-spec rows(pid(), iodata(), [term()]) -> {ok, [map()]} | {error, map()}.
rows(C, Sql, Params) ->
    case query(C, Sql, Params) of
        {ok, R} -> {ok, as_maps(R)};
        E -> E
    end.

-spec one(iodata(), [term()]) -> {ok, map() | undefined} | {error, map()}.
one(Sql, Params) ->
    case rows(Sql, Params) of
        {ok, [R | _]} -> {ok, R};
        {ok, []} -> {ok, undefined};
        E -> E
    end.

-spec exec(iodata(), [term()]) -> {ok, non_neg_integer()} | {error, map()}.
exec(Sql, Params) ->
    with_connection(fun(C) ->
        case query(C, Sql, Params) of
            {ok, #{affected := N}} -> {ok, N};
            E -> E
        end
    end).

status(Pool) -> gen_server:call(Pool, status).

%% ==========================================================================
%% Checkout / checkin
%% ==========================================================================

-spec checkout(atom(), timeout()) -> {ok, pid()} | {error, map()}.
checkout(Pool, Timeout) ->
    Ref = make_ref(),
    try gen_server:call(Pool, {checkout, self(), Ref}, Timeout)
    catch exit:{timeout, _} ->
        %% Give up; if the connection was lent meanwhile, the pool takes it back.
        gen_server:cast(Pool, {give_up, self(), Ref}),
        {error, #{code => <<"OVERLOAD">>,
                  message => <<"nenhuma conexão de banco disponível"/utf8>>}}
    end.

checkin(Pool, C) ->
    gen_server:cast(Pool, {checkin, C, self()}).

%% ==========================================================================
%% gen_server
%% ==========================================================================

init({Name, Config, Size}) ->
    process_flag(trap_exit, true),
    _ = case ets:whereis(?CACHE) of
        undefined -> ets:new(?CACHE, [named_table, public, set, {read_concurrency, true}]);
        _ -> ok
    end,
    {ok, open_up_to(#st{name = Name, config = Config, size = max(1, Size)})}.

handle_call({checkout, Client, Ref}, _From, St = #st{free = [C | Rest]}) ->
    {reply, {ok, C}, lend(C, Client, Ref, St#st{free = Rest})};
handle_call({checkout, _, _}, _From, St = #st{free = [], open = 0, refill = T}) when T =/= undefined ->
    %% CA-023-02: database down and no connection left — fail fast, don't queue.
    {reply, {error, #{code => <<"DB_UNAVAILABLE">>,
                      message => <<"banco de dados indisponível; tente novamente em instantes"/utf8>>}}, St};
handle_call({checkout, Client, Ref}, From, St = #st{queue = Q}) ->
    {noreply, open_up_to(St#st{queue = queue:in({From, Client, Ref}, Q)})};
handle_call(status, _From, St) ->
    {reply, #{free => length(St#st.free), busy => maps:size(St#st.busy),
              waiting => queue:len(St#st.queue), size => St#st.size}, St}.

handle_cast({checkin, C, Client}, St) ->
    case find(C, Client, St#st.busy) of
        {Mon, _} ->
            demonitor(Mon, [flush]),
            {noreply, release(C, St#st{busy = maps:remove(Mon, St#st.busy)})};
        none ->
            {noreply, St}
    end;
handle_cast({give_up, Client, Ref}, St = #st{queue = Q, busy = Busy}) ->
    Q2 = queue:filter(fun({_, Cl, R}) -> not (Cl =:= Client andalso R =:= Ref) end, Q),
    Late = [{Mon, C} || Mon := {C, Cl, R} <- Busy, Cl =:= Client, R =:= Ref],
    St2 = lists:foldl(fun({Mon, C}, S) ->
                          demonitor(Mon, [flush]),
                          release(C, S#st{busy = maps:remove(Mon, S#st.busy)})
                      end, St#st{queue = Q2}, Late),
    {noreply, St2};
handle_cast({clean, C}, St) ->
    {noreply, release(C, St)};
handle_cast({discard, C}, St) ->
    discard(C),
    {noreply, open_up_to(St#st{open = St#st.open - 1})}.

handle_info({'DOWN', Mon, process, _Client, _}, St) ->
    case maps:take(Mon, St#st.busy) of
        {{C, _, _}, Busy} ->
            %% RNF-001-08: clean outside the pool process (may take a while).
            Pool = self(),
            spawn(fun() -> clean(Pool, C) end),
            {noreply, St#st{busy = Busy}};
        error ->
            {noreply, St}
    end;
handle_info({'EXIT', C, Reason}, St) ->
    Free = lists:delete(C, St#st.free),
    Busy = maps:filter(fun(_, {Cx, _, _}) -> Cx =/= C end, St#st.busy),
    Ours = length(Free) =/= length(St#st.free) orelse maps:size(Busy) =/= maps:size(St#st.busy),
    case Ours of
        true ->
            %% A pool connection died (database restart, network...): replace it.
            logger:warning("pool ~s: connection closed: ~0p", [St#st.name, Reason]),
            clear_cache(C),
            {noreply, schedule_refill(St#st{free = Free, busy = Busy, open = St#st.open - 1})};
        false ->
            %% Helper process (e.g. a failed connection attempt): ignore.
            {noreply, St}
    end;
handle_info(refill, St) ->
    {noreply, open_up_to(St#st{refill = undefined})};
handle_info(_, St) ->
    {noreply, St}.

terminate(_, St) ->
    _ = [catch epgsql:close(C) || C <- St#st.free],
    ok.

%% ==========================================================================
%% Pool internals
%% ==========================================================================

lend(C, Client, Ref, St) ->
    Mon = monitor(process, Client),
    St#st{busy = (St#st.busy)#{Mon => {C, Client, Ref}}}.

find(C, Client, Busy) ->
    maps:fold(fun(Mon, {Cx, Cl, _}, none) when Cx =:= C, Cl =:= Client -> {Mon, C};
                 (_, _, Acc) -> Acc
              end, none, Busy).

%% Hands the connection to the next waiter (if still alive) or keeps it.
release(C, St = #st{queue = Q}) ->
    case queue:out(Q) of
        {{value, {From, Client, Ref}}, Q2} ->
            case is_process_alive(Client) of
                true ->
                    gen_server:reply(From, {ok, C}),
                    lend(C, Client, Ref, St#st{queue = Q2});
                false ->
                    release(C, St#st{queue = Q2})
            end;
        {empty, _} ->
            St#st{free = [C | St#st.free]}
    end.

clean(Pool, C) ->
    Ok = try
        {ok, [], []} = epgsql:squery(C, "ROLLBACK"),
        {ok, [], []} = epgsql:squery(C, "RESET ALL"),
        true
    catch _:_ -> false
    end,
    case Ok of
        true -> gen_server:cast(Pool, {clean, C});
        false -> gen_server:cast(Pool, {discard, C})
    end.

discard(C) ->
    clear_cache(C),
    unlink(C),
    catch epgsql:close(C).

open_up_to(St = #st{open = O, size = S}) when O >= S -> St#st{backoff = 500};
open_up_to(St = #st{open = O, config = Config, name = Name}) ->
    case connect(Config()) of
        {ok, C} ->
            open_up_to(release(C, St#st{open = O + 1}));
        {error, Reason} ->
            logger:error("pool ~s: cannot open connection (retry in ~b ms): ~0p",
                         [Name, St#st.backoff, Reason]),
            schedule_refill(St)
    end.

%% A single pending timer, exponential backoff up to 5 s (RNF-023-02: the core
%% is back within seconds after the database returns).
schedule_refill(St = #st{refill = undefined, backoff = B}) ->
    St#st{refill = erlang:send_after(B, self(), refill), backoff = min(B * 2, 5000)};
schedule_refill(St) ->
    St.

%% ==========================================================================
%% Prepared statements (RNF-001-09)
%% ==========================================================================

prepare(C, Sql0) ->
    Sql = iolist_to_binary(Sql0),
    case ets:lookup(?CACHE, {C, Sql}) of
        [{_, St}] -> {ok, St};
        [] ->
            limit_cache(C),
            Name = "ana_" ++ integer_to_list(erlang:unique_integer([positive])),
            case epgsql:parse(C, Name, Sql, []) of
                {ok, St} ->
                    ets:insert(?CACHE, {{C, Sql}, St}),
                    _ = ets:update_counter(?CACHE, {C, '$n'}, 1, {{C, '$n'}, 0}),
                    {ok, St};
                {error, E} ->
                    {error, sql_error(E)}
            end
    end.

limit_cache(C) ->
    case ets:lookup(?CACHE, {C, '$n'}) of
        [{_, N}] when N >= ?CACHE_MAX_PER_CONNECTION ->
            %% Avoids unbounded growth on the server with dynamic SQL.
            _ = epgsql:squery(C, "DEALLOCATE ALL"),
            clear_cache(C);
        _ -> ok
    end.

clear_cache(C) ->
    ets:match_delete(?CACHE, {{C, '_'}, '_'}).

%% ==========================================================================
%% Results
%% ==========================================================================

result({ok, Cols, Rows}) -> {ok, compact(Cols, Rows, length(Rows))};
result({ok, N, Cols, Rows}) -> {ok, compact(Cols, Rows, N)};
result({ok, N}) when is_integer(N) -> {ok, #{columns => [], rows => [], affected => N}};
result({error, E}) -> {error, sql_error(E)}.

compact(Cols, Rows, N) ->
    Types = [T || #column{type = T} <- Cols],
    #{columns => [#{name => Name, type => ana_types:type_name(T)}
                  || #column{name = Name, type = T} <- Cols],
      rows => [lists:zipwith(fun ana_types:to_json/2, tuple_to_list(R), Types) || R <- Rows],
      affected => N}.

sum_batch([], Total) -> {ok, #{columns => [], rows => [], affected => Total}};
sum_batch([{ok, N} | R], T) when is_integer(N) -> sum_batch(R, T + N);
sum_batch([{ok, N, _} | R], T) when is_integer(N) -> sum_batch(R, T + N);
sum_batch([{ok, Rows} | R], T) when is_list(Rows) -> sum_batch(R, T + length(Rows));
sum_batch([{error, E} | _], _) -> {error, sql_error(E)}.

as_maps(#{columns := Cols, rows := Rows}) ->
    Names = [N || #{name := N} <- Cols],
    [maps:from_list(lists:zip(Names, R)) || R <- Rows].

sql_error(#error{code = <<"25006">>}) ->
    %% Spec 009 (RF-009-05): only the license's restricted mode opens read-only execution transactions.
    #{code => <<"LICENSE_RESTRICTED">>, sqlstate => <<"25006">>,
      message => <<"licença vencida ou inválida: o ERP está somente para consulta (peça ao administrador para instalar a licença)"/utf8>>};
sql_error(#error{code = Code, message = Msg, extra = Extra}) ->
    Base = #{code => <<"SQL">>, sqlstate => Code, message => Msg},
    case proplists:get_value(detail, Extra) of
        undefined -> Base;
        D -> Base#{detail => D}
    end;
sql_error(Other) ->
    #{code => <<"SQL">>, message => unicode:characters_to_binary(io_lib:format("~0p", [Other]))}.
