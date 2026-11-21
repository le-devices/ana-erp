%% SPDX-FileCopyrightText: 2026 André Luis Pereira dos Santos
%% SPDX-License-Identifier: AGPL-3.0-or-later
%% Program execution: one execution transaction per run (specs 002 and 004).
%%
%% One supervised (temporary) process per execution. It:
%%  - borrows a connection from the restricted pool (ana_db_exec, role
%%    ana_exec) and opens the transaction (RF-002-08, RNF-002-02);
%%  - talks to the Python process(es) using the protocol in plan.md, serving
%%    SQL requests, nested calls (with SAVEPOINT), remote calls and libraries;
%%  - enforces deadlines (RNF-002-04), cancelling running SQL when needed;
%%  - keeps numbered events for the studio/debugger (RF-004-05);
%%  - writes the audit record outside the transaction (RF-002-09, P11).
-module(ana_execution).
-behaviour(gen_server).

-export([init_tables/0, start_link/1, run/4, events/4, command/3, status/2,
         counters/0, running/0, abort/1, can_run/2, new_id/0]).
-export([init/1, handle_continue/2, handle_call/3, handle_cast/2, handle_info/2,
         terminate/2]).

-define(TAB, ana_executions).
-define(START_RECORD_MS, 1000).
-define(POOL, ana_db_exec).
-define(MAX_DEPTH, 16).
-define(MAX_EVENTS, 5000).
-define(RETENTION_MS, 300000).
-define(LONG_POLL_MS, 25000).
-define(MAX_RESULT, 8 * 1024 * 1024).
-define(I_EXEC, 1).
-define(I_DEBUG, 2).
-define(INDICATOR_TIMEOUT_MS, 5000).

-record(frame, {
    port :: port(),
    ospid :: integer(),
    program :: binary(),
    version :: integer() | undefined,
    request_id :: integer() | undefined,   % parent's request waiting for us
    savepoint :: binary() | undefined      % SAVEPOINT of the nested call
}).

-record(st, {
    id :: binary(),
    program :: binary(),
    params :: map(),
    user :: map(),
    origin :: binary(),
    debug = false :: boolean(),
    commit = false :: boolean(),
    %% Spec 056: a rehearsal runs whole and is undone; external effects are held and listed.
    rehearse = false :: boolean(),
    held = [] :: [map()],
    rehearsal = #{} :: map(),               % effects of the parts, joined at the end
    stats_base = #{} :: map(),              % per-transaction statistics at the start of a rehearsal
    %% Spec 065 (RNF-065-02): the company values this execution read, kept in its record.
    values_read = #{} :: map(),
    %% Spec 065 (D4): company values the routine keeps (ana.set_value), written right after its COMMIT.
    value_sets = [] :: [map()],
    read_only = false :: boolean(),          % simulation or restricted license: nothing is kept after the run
    %% Spec 050 (D5): the undo the routine offers (ana.offer_undo), recorded after its COMMIT; then what was offered.
    undo = undefined :: map() | undefined,
    undo_offered = null :: map() | null,
    %% Spec 045 (RF-045-06): the variant this run used (id, name, version, warnings), or null.
    variant = null :: map() | null,
    breakpoints = [] :: list(),
    stop_on_entry = false :: boolean(),
    timeout_ms :: pos_integer(),
    caller :: {pid(), reference()} | undefined,
    admitted = true :: boolean(),
    conn :: pid() | undefined,
    in_tx = false :: boolean(),
    stack = [] :: [#frame{}],
    pending :: {reference(), pid(), integer()} | undefined,
    status = starting :: starting | running | paused | finished,
    events = [] :: [map()],
    seq = 0 :: non_neg_integer(),
    waiters = [] :: [{gen_server:from(), non_neg_integer(), reference()}],
    output = [] :: iolist(),
    output_size = 0 :: non_neg_integer(),
    output_max :: non_neg_integer(),
    version :: integer() | undefined,
    started :: integer(),
    exec_timer :: reference() | undefined,
    idle_timer :: reference() | undefined,
    last_pause :: map() | undefined,
    final :: map() | undefined,
    n_savepoints = 0 :: non_neg_integer(),
    requested = #{} :: map(),               % limits asked by the caller (may only lower)
    limits = #{} :: map(),                  % effective limits (spec 012)
    tokens = [] :: list(),                  % concurrency slots to release
    sql_count = 0 :: non_neg_integer(),
    rows_read = 0 :: non_neg_integer(),
    cpu_ms = 0 :: non_neg_integer(),
    max_rss_kb = 0 :: non_neg_integer(),
    internal_trace = null :: binary() | null,  % RF-024-05: admin-only, never returned
    %% Spec 022: as a part — main execution, its monitor, 2PC gid, imported snapshot;
    %% as a main execution — its parts (see "Parallel parts").
    parent_id :: binary() | undefined,
    parent_mon :: reference() | undefined,
    prepare :: binary() | undefined,
    snapshot_in :: binary() | undefined,
    par = #{} :: map(),
    %% Spec 019: SQL measured per statement; profile when asked.
    sql_cur :: {integer(), binary(), term()} | undefined,
    sql_events = [] :: [map()],
    sql_n = 0 :: non_neg_integer(),
    sql_by_hash = #{} :: map(),
    sql_us = 0 :: non_neg_integer(),
    profile_req = false :: boolean(),
    profile :: map() | null | undefined
}).

%% ==========================================================================
%% API
%% ==========================================================================

%% Called by the root supervisor: execution table and counters (RNF-002-05).
init_tables() ->
    _ = ets:new(?TAB, [named_table, public, set, {read_concurrency, true}]),
    persistent_term:put({?MODULE, counters}, atomics:new(2, [{signed, true}])),
    ok.

counters() ->
    A = persistent_term:get({?MODULE, counters}),
    #{executions => atomics:get(A, ?I_EXEC), debug_sessions => atomics:get(A, ?I_DEBUG)}.

%% RF-011-08: executions in progress (no calls to the processes).
running() ->
    [#{id => Id, username => Owner, program => Prog, debug => Debug,
       started_at => list_to_binary(calendar:system_time_to_rfc3339(Started, [{unit, millisecond}, {offset, "Z"}]))}
     || {Id, _Pid, Owner, Prog, Started, Debug} <- ets:tab2list(?TAB)].

start_link(Args) ->
    gen_server:start_link(?MODULE, Args, []).

%% Options: origin, async, debug, breakpoints, stop_on_entry, commit, timeout_ms.
%% Synchronous: {ok, #{id, result, events, duration_ms}} | {error, Error}
%% Async/debug: {ok, #{id}} | {error, Error}
-spec run(binary(), map(), map(), map()) -> {ok, map()} | {error, map()}.
%% Spec 022 (parts, set only by a main execution): id, parent, parent_pid, prepare, snapshot.
run(Program, Params, User, Options) ->
    Debug = maps:get(debug, Options, false) =:= true,
    Async = Debug orelse maps:get(async, Options, false) =:= true,
    Owner = ana_security:owner(User),
    case Owner =:= ok andalso admit(Debug) of
        false when Owner =:= {error, unavailable} ->
            {error, err(<<"DB_UNAVAILABLE">>, <<"banco de dados indisponível no momento: tente de novo em instantes"/utf8>>)};
        false ->
            {error, err(<<"NO_OWNER">>, <<"toda execução precisa de um usuário dono ativo (pessoa ou robô)"/utf8>>)};
        ok ->
            Id = case maps:get(id, Options, undefined) of
                Given when is_binary(Given), byte_size(Given) =:= 36 -> Given;   % part id chosen by its main
                _ -> uuid()
            end,
            Ref = make_ref(),
            Args = #{id => Id, program => Program, params => Params, user => User,
                     options => Options, debug => Debug,
                     caller => case Async of true -> undefined; false -> {self(), Ref} end},
            case supervisor:start_child(ana_execution_sup, [Args]) of
                {ok, _Pid} when Async ->
                    {ok, #{id => Id}};
                {ok, Pid} ->
                    await(Pid, Ref, Id);
                {error, Reason} ->
                    release(Debug),
                    logger:error("could not start execution: ~0p", [Reason]),
                    {error, err(<<"INTERNAL">>, <<"falha ao iniciar execução"/utf8>>)}
            end;
        {error, _} = E -> E
    end.

%% Stops a running execution (parts cancelled by their main execution).
-spec abort(binary()) -> ok.
abort(Id) ->
    case ets:lookup(?TAB, Id) of
        [{_, Pid, _, _, _, _}] -> gen_server:cast(Pid, abort);
        [] -> ok
    end.

events(Id, User, Since, Wait) ->
    with_execution(Id, User, fun(Pid) ->
        gen_server:call(Pid, {events, Since, Wait}, ?LONG_POLL_MS + 5000)
    end).

command(Id, User, Cmd) ->
    with_execution(Id, User, fun(Pid) -> gen_server:call(Pid, {command, Cmd}, 10000) end).

status(Id, User) ->
    case with_execution(Id, User, fun(Pid) -> gen_server:call(Pid, status, 10000) end) of
        {error, not_found} -> recorded_status(Id, User);
        R -> R
    end.

%% RNF-004-02: only the owner (or an admin) can access an execution.
with_execution(Id, #{username := U} = User, Fun) ->
    case ets:lookup(?TAB, Id) of
        [{_, Pid, Owner, _, _, _}] ->
            case Owner =:= U orelse ana_security:has_role(User, <<"admin">>) of
                true ->
                    try Fun(Pid)
                    catch exit:{noproc, _} -> {error, not_found};
                          exit:{normal, _} -> {error, not_found};
                          exit:{timeout, _} -> {error, timeout}
                    end;
                false -> {error, forbidden}
            end;
        [] -> {error, not_found}
    end.

recorded_status(Id, #{username := U} = User) ->
    case ana_db:one("SELECT id::text AS id, program, version, username, origin, status, "
                    "started_at, finished_at, duration_ms, params, result, error, output, debug, "
                    "cpu_ms, max_rss_kb, sql_count, rows_read, limits "
                    "FROM ana_system.execution WHERE id = $1::text::uuid", [Id]) of
        {ok, #{<<"username">> := Owner} = R} ->
            case Owner =:= U orelse ana_security:has_role(User, <<"admin">>) of
                true -> {ok, R};
                false -> {error, forbidden}
            end;
        {ok, undefined} -> {error, not_found};
        {error, _} -> {error, not_found}
    end.

admit(Debug) ->
    case ana_ha:refusing() of
        true -> {error, err(<<"DRAINING">>, <<"nó em desligamento; tente novamente (outro nó atende)"/utf8>>)};
        false -> admit2(Debug)
    end.

admit2(Debug) ->
    A = persistent_term:get({?MODULE, counters}),
    Max = ana_settings:get(exec_max),
    case atomics:add_get(A, ?I_EXEC, 1) of
        N when N > Max ->
            atomics:sub(A, ?I_EXEC, 1),
            {error, err(<<"OVERLOAD">>, <<"limite de execuções simultâneas atingido"/utf8>>)};
        _ when Debug ->
            MaxD = ana_settings:get(debug_max),
            case atomics:add_get(A, ?I_DEBUG, 1) of
                D when D > MaxD ->
                    atomics:sub(A, ?I_DEBUG, 1),
                    atomics:sub(A, ?I_EXEC, 1),
                    {error, err(<<"OVERLOAD">>, <<"limite de depurações simultâneas atingido"/utf8>>)};
                _ -> ok
            end;
        _ -> ok
    end.

release(Debug) ->
    A = persistent_term:get({?MODULE, counters}),
    atomics:sub(A, ?I_EXEC, 1),
    _ = Debug andalso atomics:sub(A, ?I_DEBUG, 1) =:= ok,
    ok.

await(Pid, Ref, Id) ->
    Mon = monitor(process, Pid),
    receive
        {ana_end, Ref, R} ->
            demonitor(Mon, [flush]),
            R;
        {'DOWN', Mon, process, Pid, Reason} ->
            logger:error("execution ~s ended without a result: ~0p", [Id, Reason]),
            {error, err(<<"INTERNAL">>, <<"execução interrompida"/utf8>>, Id)}
    end.

%% ==========================================================================
%% gen_server
%% ==========================================================================

init(#{id := Id, program := Program, params := Params, user := User,
       options := Op, debug := Debug, caller := Caller}) ->
    process_flag(trap_exit, true),
    ets:insert(?TAB, {Id, self(), maps:get(username, User), Program,
                      erlang:system_time(millisecond), Debug}),
    %% Limits asked by the caller (scheduler, studio): they may only lower.
    Asked = maps:filter(fun(_, V) -> is_integer(V) andalso V > 0 end, maps:get(limits, Op, #{})),
    Requested = case maps:get(timeout_ms, Op, undefined) of
        T when is_integer(T), T > 0 -> Asked#{<<"timeout_ms">> => T};
        _ -> Asked
    end,
    St = #st{id = Id, program = Program, params = Params, user = User,
             origin = maps:get(origin, Op, <<"api">>),
             debug = Debug,
             commit = maps:get(commit, Op, false) =:= true
                      andalso ana_security:has_role(User, <<"developer">>)
                      andalso maps:get(rehearse, Op, false) =/= true,
             rehearse = maps:get(rehearse, Op, false) =:= true,
             variant = maps:get(variant, Op, null),
             breakpoints = [L || L <- maps:get(breakpoints, Op, []), is_integer(L)],
             stop_on_entry = maps:get(stop_on_entry, Op, false) =:= true,
             timeout_ms = ana_settings:get(exec_timeout_ms),
             requested = Requested,
             caller = Caller,
             output_max = ana_settings:get(output_max_kb) * 1024,
             started = erlang:monotonic_time(millisecond),
             parent_id = maps:get(parent, Op, undefined),
             parent_mon = case maps:get(parent_pid, Op, undefined) of
                 P when is_pid(P) -> monitor(process, P);
                 _ -> undefined
             end,
             prepare = maps:get(prepare, Op, undefined),
             snapshot_in = case ana_parallel:valid_snapshot(maps:get(snapshot, Op, undefined)) of
                 true -> maps:get(snapshot, Op);
                 false -> undefined
             end,
             profile_req = maps:get(profile, Op, false) =:= true andalso ana_security:has_role(User, <<"developer">>)},
    %% RF-019-09: logs of this process carry the execution, program and user.
    logger:set_process_metadata(#{execution_id => Id, program => Program, user => maps:get(username, User)}),
    {ok, St, {continue, start}}.

handle_continue(start, St) ->
    try prepare(St) of
        {ok, St2} -> {noreply, St2};
        {error, Error, St2} -> {noreply, finish(<<"error">>, Error, St2)}
    catch Class:Reason:Stack ->
        logger:error("could not prepare execution: ~0p:~0p ~0p", [Class, Reason, Stack]),
        {noreply, finish(<<"error">>, err(<<"INTERNAL">>, <<"falha interna">>),
                         St#st{internal_trace = crash_trace(Class, Reason, Stack)})}
    end.

handle_call({events, Since, Wait}, From, St) ->
    case new_events(Since, St) of
        [] when Wait, St#st.status =/= finished ->
            T = erlang:send_after(?LONG_POLL_MS, self(), {long_poll, From}),
            {noreply, St#st{waiters = [{From, Since, T} | St#st.waiters]}};
        New ->
            {reply, {ok, events_reply(New, St)}, St}
    end;
handle_call({command, Cmd}, _From, St) ->
    {Resp, St2} = handle_command(Cmd, St),
    {reply, Resp, St2};
handle_call(status, _From, St) ->
    {reply, {ok, summary(St)}, St}.

handle_cast(abort, St = #st{status = S}) when S =/= finished ->
    {noreply, finish(<<"aborted">>, err(<<"ABORTED">>, <<"parte cancelada pela execução principal"/utf8>>), St)};
handle_cast(_, St) -> {noreply, St}.

%% Messages from the Python process at the top of the stack.
handle_info({Port, {data, Bin}}, St = #st{stack = [#frame{port = Port} | _]}) ->
    try handle_message(ana_py:decode(Bin), St) of
        St2 -> {noreply, St2}
    catch Class:Reason:Stack ->
        logger:error("execution ~s: failed to handle message: ~0p:~0p ~0p",
                     [St#st.id, Class, Reason, Stack]),
        {noreply, finish(<<"error">>, err(<<"INTERNAL">>, <<"falha interna">>),
                         St#st{internal_trace = crash_trace(Class, Reason, Stack)})}
    end;
handle_info({Port, {exit_status, S}}, St = #st{status = Status}) when Status =/= finished ->
    case lists:keymember(Port, #frame.port, St#st.stack) of
        true ->
            Msg = case S of
                137 -> <<"processo Python encerrado (memória ou sinal)"/utf8>>;
                _ -> unicode:characters_to_binary(io_lib:format("processo Python encerrou (status ~b)", [S]))
            end,
            {noreply, finish(<<"error">>, err(<<"PROCESS_EXITED">>, Msg), St)};
        false ->
            {noreply, St}
    end;
%% Result of an asynchronous operation (SQL, remote) — RNF-002-04
handle_info({pending, Ref, Res}, St = #st{pending = {Ref, _, RequestId}}) ->
    {Res2, St2} = count_rows(Res, St),
    respond(RequestId, Res2, St2),
    {noreply, note_sql(Res, St2#st{pending = undefined})};
handle_info(timeout, St = #st{status = running}) ->
    Msg = unicode:characters_to_binary(io_lib:format("tempo máximo de execução (~b ms) excedido",
                                                     [St#st.timeout_ms])),
    {noreply, finish(<<"timeout">>, err(<<"TIMEOUT">>, Msg), St)};
handle_info(idle, St = #st{status = paused}) ->
    {noreply, finish(<<"aborted">>, err(<<"ABORTED">>, <<"depuração ociosa encerrada"/utf8>>), St)};
handle_info({long_poll, From}, St) ->
    case lists:keytake(From, 1, St#st.waiters) of
        {value, _, Rest} ->
            gen_server:reply(From, {ok, events_reply([], St)}),
            {noreply, St#st{waiters = Rest}};
        false -> {noreply, St}
    end;
handle_info(audit_start, St = #st{status = Status}) when Status =/= finished ->
    ok = audit_start(St),
    {noreply, St};
handle_info({part_done, H, Res}, St) ->
    %% Spec 056: a rehearsed part brings its effects; they join the main execution's.
    St2 = case Res of
        {ok, #{rehearsal := E}} -> St#st{rehearsal = ana_rehearsal:merge(St#st.rehearsal, E)};
        _ -> St
    end,
    {noreply, part_done(H, simplify(Res), St2)};
handle_info({gather_timeout, Ref}, St = #st{par = #{gather := {_, _, _, Ref, _}}}) ->
    {noreply, gather_expired(St)};
handle_info({'DOWN', Mon, process, _, _}, St = #st{parent_mon = Mon, status = S}) when S =/= finished ->
    %% RNF-022-02: the main execution ended — this part is cancelled.
    {noreply, finish(<<"aborted">>, err(<<"ABORTED">>, <<"execução principal encerrada"/utf8>>), St)};
handle_info({'DOWN', Mon, process, _, Reason}, St) when Reason =/= normal ->
    {noreply, part_crashed(Mon, Reason, St)};
handle_info(shutdown, St) ->
    {stop, normal, St};
handle_info(_, St) ->
    {noreply, St}.

terminate(_Reason, St) ->
    _ = [ana_py:kill({F#frame.port, F#frame.ospid}) || F <- St#st.stack],
    _ = St#st.admitted andalso release(St#st.debug) =:= ok,
    ok = ana_limits:release(St#st.tokens),
    ets:delete(?TAB, St#st.id),
    ok.

%% ==========================================================================
%% Preparation
%% ==========================================================================

prepare(St0 = #st{program = Name, user = U}) ->
    case load(Name, U) of
        {ok, P} ->
            %% Spec 012: effective limits and concurrency/rate slots.
            L = ana_limits:effective(P, U, St0#st.requested),
            case ana_limits:acquire(Name, U, maps:get(<<"max_concurrent">>, L)) of
                {ok, Tokens} -> prepare_run(P, L, St0#st{tokens = Tokens});
                {error, Error} -> {error, Error, St0#st{limits = L}}
            end;
        {error, Error} ->
            {error, Error, St0}
    end.

prepare_run(P, L, St) ->
    St1 = St#st{version = maps:get(<<"version">>, P), limits = L,
                %% Spec 048 (D1): an indicator answers in a few seconds or the block says "indisponível".
                timeout_ms = case indicator(P) of
                    true -> min(?INDICATOR_TIMEOUT_MS, maps:get(<<"timeout_ms">>, L));
                    false -> maps:get(<<"timeout_ms">>, L)
                end,
                output_max = maps:get(<<"output_kb">>, L) * 1024},
    %% RF-025-04: short synchronous executions are written once, at the end.
    _ = case St1#st.debug orelse St1#st.caller =:= undefined of
        true -> audit_start(St1);
        false -> erlang:send_after(?START_RECORD_MS, self(), audit_start)
    end,
    case ana_db:checkout(?POOL, 15000) of
        {ok, C} ->
            St2 = St1#st{conn = C, read_only = ana_license:restricted() orelse simulating(P, St1#st.params)
                                                orelse indicator(P)},
            %% RF-022-05: a part may read the snapshot exported by its main execution.
            Snap = case St1#st.snapshot_in of
                undefined -> "BEGIN; ";
                S -> ["BEGIN ISOLATION LEVEL REPEATABLE READ; SET TRANSACTION SNAPSHOT '", S, "'; "]
            end,
            %% ana.username / ana.origin / ana.execution_id: informational (outbox created_by, spec 017;
            %% master data history, spec 040); never used for authorization.
            Q = fun(V) -> binary:replace(iolist_to_binary(V), <<"'">>, <<"''">>, [global]) end,
            %% Spec 009 (RF-009-05): restricted license → the database itself refuses every write.
            %% Spec 020 (RF-020-13): so does a simulation ("Simular" never saves, whatever the program does).
            %% Spec 048 (D1): so does an indicator — it only reads, whatever its code does.
            ReadOnly = case ana_license:restricted() orelse simulating(P, St1#st.params) orelse indicator(P) of
                true -> "SET TRANSACTION READ ONLY; ";
                false -> ""
            end,
            %% Spec 009 (D10): the user's data scope, applied by the database's row policies.
            Scope = iolist_to_binary(ana_access:scope_sql(St1#st.user)),
            Begin = io_lib:format(
                "~s~s~sSET LOCAL statement_timeout = ~b; SET LOCAL lock_timeout = ~b; SET LOCAL ana.username = '~ts'; "
                "SET LOCAL ana.origin = '~ts'; SET LOCAL ana.execution_id = '~ts'; SET LOCAL ana.instance = '~ts'; "
                "SET LOCAL ana.timezone = '~ts'",
                [Snap, ReadOnly, Scope, maps:get(<<"sql_timeout_ms">>, L), maps:get(<<"lock_timeout_ms">>, L),
                 Q(maps:get(username, St1#st.user)), Q(St1#st.origin), Q(St1#st.id),
                 ana_instance:role(), Q(ana_config:timezone())]),
            case lists:flatten([epgsql:squery(C, Begin)]) of
                [{ok, [], []} | _] = Rs ->
                    case [E || {error, E} <- Rs] of
                        [] when St2#st.rehearse ->
                            open_frame(P, undefined, undefined, St2#st{in_tx = true, stats_base = ana_rehearsal:baseline(C)});
                        [] -> open_frame(P, undefined, undefined, St2#st{in_tx = true});
                        [E | _] -> {error, sql_error(E), St2}
                    end;
                Other ->
                    {error, err(<<"INTERNAL">>, io_lib:format("~0p", [Other])), St2}
            end;
        {error, Error} ->
            {error, bin_keys(Error), St1}
    end.

%% RF-002-11, RF-001-10, RF-003-03, RF-011-04
load(Name, User) ->
    case ana_program:valid_name(Name) andalso ana_program:for_execution(Name) of
        {ok, #{<<"active">> := true, <<"kind">> := <<"program">>, <<"min_role">> := Min} = P} ->
            %% Spec 016: an external portal account runs only programs marked for the portal.
            Allowed = case User of
                #{role := <<"external">>} -> maps:get(<<"portal">>, P, false) =:= true;
                _ -> ana_security:has_role(User, Min) andalso ana_access:allowed(User, P)
            end,
            %% The public API and the portal are modules too: their callers need them in the license.
            Module = case User of
                #{api := _} -> first_missing([<<"public_api">>, ana_license:module_of(Name)]);
                #{role := <<"external">>} -> first_missing([<<"portal">>, ana_license:module_of(Name)]);
                _ -> ana_license:module_of(Name)
            end,
            case {Allowed, ana_license:allowed(Module)} of
                {false, _} -> {error, err(<<"FORBIDDEN">>, <<"sem permissão para o programa"/utf8>>)};
                {true, false} ->
                    %% Spec 009 (RF-009-03): a module not in the license; its tables stay readable.
                    {error, err(<<"NOT_LICENSED">>, <<"o módulo "/utf8, (module_label(Module))/binary,
                                                       " não está na licença desta instalação"/utf8>>)};
                {true, true} -> {ok, P}
            end;
        {ok, #{<<"kind">> := <<"library">>}} ->
            %% A library is imported by programs; running it by itself is a mistake worth explaining.
            {error, err(<<"NOT_EXECUTABLE">>, <<"é uma biblioteca: não executa sozinha, é usada pelos programas "
                                                "(from ana_lib.<módulo> import <nome>)"/utf8>>)};
        {ok, #{<<"active">> := false}} ->
            {error, err(<<"PROGRAM_INACTIVE">>, <<"programa inativo: reative-o em Propriedades para executar"/utf8>>)};
        _ ->
            {error, err(<<"PROGRAM_NOT_FOUND">>, <<"programa inexistente"/utf8>>)}
    end.

%% A parameter declared {"type": "bool", "simulate": true} and received true: the run only shows what the
%% definition would take (RF-020-13).
simulating(#{<<"params">> := Decl}, Params) when is_map(Decl), is_map(Params) ->
    lists:any(fun({K, #{<<"simulate">> := true}}) -> lists:member(maps:get(K, Params, false), [true, <<"true">>]);
                 (_) -> false
              end, maps:to_list(Decl));
simulating(_, _) -> false.

indicator(#{<<"indicator_refresh_s">> := S}) when is_integer(S) -> true;
indicator(_) -> false.

first_missing(Modules) ->
    case [M || M <- Modules, not ana_license:allowed(M)] of
        [M | _] -> M;
        [] -> lists:last(Modules)
    end.

module_label(M) ->
    case [L || #{module := X, label := L} <- ana_license:modules(), X =:= M] of
        [L | _] -> L;
        [] -> M
    end.

open_frame(P, RequestId, Savepoint, St = #st{stack = Stack}) ->
    case ana_py:checkout() of
        {ok, Port, OsPid} ->
            Root = Stack =:= [],
            Name = maps:get(<<"name">>, P),
            Params = case Root of
                true -> St#st.params;
                false -> maps:get(nested_params, P, #{})
            end,
            Msg = #{type => run, program => Name,
                    version => maps:get(<<"version">>, P),
                    source => maps:get(<<"source">>, P),
                    params => Params,
                    context => #{user => maps:get(username, St#st.user),
                                 role => maps:get(role, St#st.user),
                                 party => maps:get(party_id, St#st.user, null),
                                 %% Spec 037: absolute addresses in download links sent to partners.
                                 public_url => ana_instance:public_url(),
                                 execution_id => St#st.id,
                                 origin => St#st.origin,
                                 rehearsal => St#st.rehearse,
                                 depth => length(Stack)},
                    debug => Root andalso St#st.debug,
                    profile => Root andalso St#st.profile_req andalso not St#st.debug,
                    limits => maps:with([<<"cpu_ms">>, <<"memory_mb">>, <<"output_kb">>], St#st.limits),
                    breakpoints => St#st.breakpoints,
                    stop_on_entry => St#st.stop_on_entry},
            true = ana_py:send(Port, Msg),
            F = #frame{port = Port, ospid = OsPid, program = Name,
                       version = maps:get(<<"version">>, P), request_id = RequestId,
                       savepoint = Savepoint},
            St2 = St#st{stack = [F | Stack], status = running},
            {ok, case Root of true -> arm_timeout(St2); false -> St2 end};
        {error, Reason} ->
            logger:error("no Python process: ~0p", [Reason]),
            {error, err(<<"INTERNAL">>, <<"runtime Python indisponível"/utf8>>), St}
    end.

%% ==========================================================================
%% Protocol
%% ==========================================================================

handle_message(#{<<"type">> := <<"request">>, <<"id">> := Id, <<"op">> := Op} = M, St = #st{rehearse = true}) ->
    %% Spec 056 (D1): what would leave the transaction is held, answered as held and listed.
    A = maps:get(<<"args">>, M, #{}),
    case is_map(A) andalso ana_rehearsal:hold(Op, A) of
        {hold, What} ->
            respond(Id, {ok, ana_rehearsal:held_reply(What)}, St),
            St#st{held = [What | St#st.held]};
        {rewrite, A2} -> request(Op, Id, A2, St);
        _ -> request(Op, Id, A, St)
    end;
handle_message(#{<<"type">> := <<"request">>, <<"id">> := Id, <<"op">> := Op} = M, St) ->
    request(Op, Id, maps:get(<<"args">>, M, #{}), St);
handle_message(#{<<"type">> := <<"output">>} = M, St) ->
    record_output(M, event(maps:with([<<"kind">>, <<"data">>], M), <<"output">>, St));
handle_message(#{<<"type">> := <<"pause">>} = M, St) ->
    Ev = maps:without([<<"type">>], M),
    St2 = disarm_timeout(St),
    T = erlang:send_after(ana_settings:get(debug_idle_ms), self(), idle),
    event(Ev, <<"pause">>, St2#st{status = paused, idle_timer = T, last_pause = Ev});
handle_message(#{<<"type">> := Type} = M, St) when Type =:= <<"eval">>; Type =:= <<"breakpoints">> ->
    event(maps:without([<<"type">>], M), Type, St);
handle_message(#{<<"type">> := <<"end">>} = M, St = #st{stack = [_]}) ->
    root_end(M, St);
handle_message(#{<<"type">> := <<"end">>} = M, St = #st{stack = [F | Rest]}) ->
    nested_end(M, F, St#st{stack = Rest});
handle_message(Other, St) ->
    logger:warning("execution ~s: unexpected message ~0p", [St#st.id, Other]),
    finish(<<"error">>, err(<<"PROTOCOL">>, <<"mensagem inválida do runtime"/utf8>>), St).

request(Op, Id, _, St = #st{sql_count = N, limits = #{<<"max_sql">> := Max}})
  when (Op =:= <<"sql">> orelse Op =:= <<"sql_batch">>), Max > 0, N >= Max ->
    respond(Id, {error, err(<<"SQL_LIMIT">>, io_lib:format("limite de ~b comandos SQL por execução atingido", [Max]))}, St),
    St;
request(<<"sql">>, Id, #{<<"sql">> := Sql} = A, St) when is_binary(Sql) ->
    Params = maps:get(<<"params">>, A, []),
    async(Id, fun(C) -> ana_db:query(C, Sql, as_list(Params)) end,
          St#st{sql_count = St#st.sql_count + 1, sql_cur = {now_us(), Sql, maps:get(<<"at">>, A, null)}});
request(<<"sql_batch">>, Id, #{<<"sql">> := Sql, <<"batch">> := Batch} = A, St)
  when is_binary(Sql), is_list(Batch) ->
    async(Id, fun(C) -> ana_db:batch(C, Sql, [as_list(P) || P <- Batch]) end,
          St#st{sql_count = St#st.sql_count + length(Batch), sql_cur = {now_us(), Sql, maps:get(<<"at">>, A, null)}});
request(<<"remote">>, Id, #{<<"system">> := S, <<"function">> := F} = A, St) ->
    P = maps:get(<<"params">>, A, #{}),
    async(Id, fun(_C) -> ana_remote_system:call(S, F, P) end, St);
request(<<"http">>, Id, #{<<"connector">> := C, <<"method">> := M, <<"path">> := P} = A, St) ->
    ExecId = St#st.id,
    async(Id, fun(_C) -> ana_connector:http(C, M, P, maps:get(<<"options">>, A, #{}), ExecId) end, St);
request(<<"files">>, Id, A, St = #st{user = User}) when is_map(A) ->
    async(Id, fun(_C) -> files_reply(ana_files:program(User, A)) end, St);
request(<<"library_source">>, Id, #{<<"name">> := Name}, St) ->
    respond(Id, {ok, ana_program:library_source(Name)}, St),
    St;
request(<<"extensions">>, Id, #{<<"point">> := Point}, St) when is_binary(Point) ->
    %% Spec 009 (D9): the customer programs registered for a point of a product program.
    respond(Id, {ok, ana_extensions:programs(Point)}, St),
    St;
request(<<"schedule">>, Id, #{<<"name">> := Name} = A, St = #st{program = Prog, user = User}) when is_binary(Name) ->
    %% Spec 039 (T-039-17b): a program keeps scheduler jobs of its own module ("bpm.publish" → "bpm.*"), through the
    %% scheduler's own validation and as the user who runs it (never more than that user may do by hand).
    [Ns | _] = binary:split(Prog, <<".">>),
    Reply = case binary:longest_common_prefix([Name, <<Ns/binary, ".">>]) =:= byte_size(Ns) + 1 of
        false -> {error, err(<<"FORBIDDEN">>, <<"um programa só agenda rotinas do próprio módulo ("/utf8, Ns/binary, ".*)">>)};
        true -> schedule_job(Name, A, User)
    end,
    respond(Id, Reply, St),
    St;
request(<<"value">>, Id, #{<<"name">> := Name} = A, St = #st{user = User}) when is_binary(Name) ->
    %% Spec 065 (D6, D7): from the memory of this node; an expression is one read-only query. Nothing is written.
    Opts = #{at => maps:get(<<"at">>, A, null), company => maps:get(<<"company">>, A, null), user => maps:get(username, User, null)},
    case ana_values:read(Name, Opts) of
        {ok, R} ->
            respond(Id, {ok, R}, St),
            Key = case Opts of #{at := null, company := null} -> Name;
                               #{at := At, company := Co} -> iolist_to_binary([Name, "@", json:encode([At, Co])]) end,
            Read = St#st.values_read,
            case map_size(Read) < 200 orelse maps:is_key(Key, Read) of
                true -> St#st{values_read = Read#{Key => maps:with([value, version, valid_from, expression], R)}};
                false -> St
            end;
        {error, Code, M} ->
            respond(Id, {error, err(Code, M)}, St),
            St
    end;
request(<<"set_value">>, Id, #{<<"name">> := Name} = A, St = #st{user = User, stack = [#frame{program = Prog} | _]}) ->
    case ana_values:check_set(Name, A, Prog, User) of
        {ok, Set} ->
            respond(Id, {ok, #{name => Name, value => maps:get(value, Set), before => maps:get(before, Set),
                               valid_from => maps:get(from, Set)}}, St),
            St#st{value_sets = [Set | St#st.value_sets]};
        {error, Code, M} ->
            respond(Id, {error, err(Code, M)}, St),
            St
    end;
%% Spec 050 (D5): only the routine that was run offers its undo; nothing is offered when nothing will be kept.
request(<<"offer_undo">>, Id, A, St = #st{user = User, stack = [#frame{program = Prog}]}) ->
    case St#st.read_only orelse St#st.rehearse orelse (St#st.debug andalso not St#st.commit) of
        true ->
            respond(Id, {ok, #{offered => false}}, St),
            St;
        false ->
            case ana_undo:check_offer(A, Prog, User) of
                {ok, Offer} ->
                    respond(Id, {ok, #{offered => true}}, St),
                    St#st{undo = Offer};
                {error, Code, M} ->
                    respond(Id, {error, err(Code, M)}, St),
                    St
            end
    end;
request(<<"offer_undo">>, Id, _A, St) ->
    respond(Id, {ok, #{offered => false}}, St),
    St;
%% Spec 050: may this user run that program (role, groups, license)? — what a screen offers follows the answer.
request(<<"can_run">>, Id, #{<<"program">> := Name}, St = #st{user = User}) when is_binary(Name) ->
    respond(Id, {ok, can_run(Name, User)}, St),
    St;
request(<<"savepoint">>, Id, A, St) ->
    savepoint(Id, A, St);
request(<<"call">>, Id, #{<<"program">> := Name} = A, St) ->
    call(Id, Name, maps:get(<<"params">>, A, #{}), St);
request(<<"spawn">>, Id, A, St) ->
    part_spawn(Id, A, St);
request(<<"gather">>, Id, #{<<"handles">> := Hs} = A, St) when is_list(Hs) ->
    part_gather(Id, Hs, maps:get(<<"fail_fast">>, A, false) =:= true, maps:get(<<"timeout_ms">>, A, null), St);
request(<<"cancel">>, Id, #{<<"handles">> := Hs}, St) when is_list(Hs) ->
    St2 = part_cancel(Hs, <<"parte cancelada"/utf8>>, St),
    respond(Id, {ok, true}, St2),
    St2;
request(Op, Id, _, St) ->
    respond(Id, {error, err(<<"INVALID_OPERATION">>, Op)}, St),
    St.

schedule_job(Name, A, User = #{username := Who}) ->
    Existing = case ana_db:one("SELECT id FROM scheduler.job WHERE name = $1", [Name]) of
        {ok, #{<<"id">> := Found}} -> Found;
        _ -> new
    end,
    Cron = maps:get(<<"cron">>, A, null),
    Active = maps:get(<<"active">>, A, true) =:= true andalso is_binary(Cron),
    case {Existing, Active} of
        {new, false} -> {ok, #{<<"job">> => null}};                         % nothing scheduled, nothing to stop
        {JobId, false} -> reply_job(ana_schedule:set_active(JobId, false, User));
        _ ->
            Fields = #{<<"name">> => Name, <<"description">> => maps:get(<<"description">>, A, <<>>),
                       <<"program">> => maps:get(<<"program">>, A, null), <<"params">> => maps:get(<<"params">>, A, #{}),
                       <<"run_as">> => Who, <<"active">> => true,
                       <<"triggers">> => [#{<<"kind">> => <<"cron">>, <<"cron">> => Cron}]},
            reply_job(ana_schedule:save_job(Existing, Fields, User))
    end.

reply_job({ok, #{<<"id">> := JobId}}) -> {ok, #{<<"job">> => JobId}};
reply_job({ok, #{id := JobId}}) -> {ok, #{<<"job">> => JobId}};
reply_job({ok, _}) -> {ok, #{<<"job">> => true}};
reply_job({error, M}) when is_binary(M) -> {error, err(<<"SCHEDULE_REFUSED">>, M)};
reply_job({error, E}) -> {error, err(<<"SCHEDULE_REFUSED">>, unicode:characters_to_binary(io_lib:format("~0p", [E])))}.

files_reply({ok, V}) -> {ok, V};
files_reply({error, not_found}) -> {error, err(<<"FILE_NOT_FOUND">>, <<"arquivo ou pasta não encontrado"/utf8>>)};
files_reply({error, forbidden}) -> {error, err(<<"FORBIDDEN">>, <<"sem permissão no repositório"/utf8>>)};
files_reply({error, M}) when is_binary(M) -> {error, err(<<"FILES_REFUSED">>, M)};
files_reply({error, #{} = E}) -> {error, E}.

%% Runs outside this process so deadlines and commands are still served.
async(Id, Fun, St = #st{conn = C}) ->
    Self = self(),
    Ref = make_ref(),
    Pid = spawn_link(fun() ->
        R = try Fun(C)
            catch Class:Reason ->
                logger:error("operation failed: ~0p:~0p", [Class, Reason]),
                {error, err(<<"INTERNAL">>, <<"falha na operação"/utf8>>)}
            end,
        Self ! {pending, Ref, R}
    end),
    St#st{pending = {Ref, Pid, Id}}.

savepoint(Id, #{<<"action">> := <<"create">>}, St = #st{conn = C, n_savepoints = N}) ->
    Name = <<"ana_sp_", (integer_to_binary(N + 1))/binary>>,
    respond(Id, sq(C, ["SAVEPOINT ", Name], Name), St),
    St#st{n_savepoints = N + 1};
savepoint(Id, #{<<"action">> := Action, <<"name">> := Name}, St = #st{conn = C}) ->
    %% Only names we generated are accepted (no injection).
    case re:run(Name, "^ana_sp_[0-9]{1,9}$", [{capture, none}]) of
        match when Action =:= <<"release">> ->
            respond(Id, sq(C, ["RELEASE SAVEPOINT ", Name], true), St);
        match when Action =:= <<"rollback">> ->
            respond(Id, sq(C, ["ROLLBACK TO SAVEPOINT ", Name, "; RELEASE SAVEPOINT ", Name], true), St);
        _ ->
            respond(Id, {error, err(<<"INVALID_OPERATION">>, <<"savepoint">>)}, St)
    end,
    St.

%% RF-002-08: nested call in the same transaction, isolated by a SAVEPOINT.
call(Id, _Name, _P, St = #st{stack = Stack}) when length(Stack) >= ?MAX_DEPTH ->
    respond(Id, {error, err(<<"MAX_DEPTH">>, <<"limite de chamadas aninhadas excedido"/utf8>>)}, St),
    St;
call(Id, Name, Params, St = #st{conn = C, n_savepoints = N}) ->
    case load(Name, St#st.user) of
        {ok, P} ->
            Sp = <<"ana_call_", (integer_to_binary(N + 1))/binary>>,
            case sq(C, ["SAVEPOINT ", Sp], ok) of
                {ok, ok} ->
                    case open_frame(P#{nested_params => Params}, Id, Sp, St#st{n_savepoints = N + 1}) of
                        {ok, St2} -> St2;
                        {error, Error, St2} -> respond(Id, {error, Error}, St2), St2
                    end;
                {error, Error} ->
                    respond(Id, {error, Error}, St),
                    St
            end;
        {error, Error} ->
            respond(Id, {error, Error}, St),
            St
    end.

nested_end(M, F, St0) ->
    nested_end2(M, F, add_usage(M, St0)).

nested_end2(M, F = #frame{savepoint = Sp, request_id = RequestId}, St = #st{conn = C}) ->
    catch port_close(F#frame.port),
    Res = case M of
        #{<<"ok">> := true} ->
            case sq(C, ["RELEASE SAVEPOINT ", Sp], ok) of
                {ok, ok} -> {ok, maps:get(<<"result">>, M, null)};
                E -> E
            end;
        _ ->
            _ = sq(C, ["ROLLBACK TO SAVEPOINT ", Sp, "; RELEASE SAVEPOINT ", Sp], ok),
            {error, maps:without([<<"trace">>], maps:get(<<"error">>, M, #{}))}
    end,
    respond(RequestId, Res, St),
    St.

root_end(M, St0) ->
    root_end2(M, add_usage(M, St0#st{profile = maps:get(<<"profile">>, M, null)})).

root_end2(#{<<"ok">> := true} = M, St0 = #st{conn = C}) ->
    Result = maps:get(<<"result">>, M, null),
    %% Spec 022: parts not gathered are cancelled; atomic parts decide the commit.
    St = part_cancel(pending_parts(St0), <<"parte não aguardada: a execução principal terminou"/utf8>>, St0),
    AtomicFailed = [H || {H, #{mode := <<"atomic">>, result := {error, _}}} <- maps:to_list(parts(St))],
    case byte_size(iolist_to_binary(json:encode(Result))) > ?MAX_RESULT of
        true ->
            finish(<<"error">>, err(<<"RESULT_TOO_LARGE">>, <<"resultado excede 8 MiB">>), St);
        false when AtomicFailed =/= [] ->
            %% RF-022-04: all or nothing — the main execution is undone too.
            finish(<<"error">>, err(<<"PARALLEL_ATOMIC_FAILED">>,
                                    io_lib:format("~b parte(s) atômica(s) falharam: nada foi gravado",
                                                  [length(AtomicFailed)])), St);
        false when St#st.rehearse ->
            %% Spec 056 (RF-056-02): the effect is read from the transaction itself, then everything is undone.
            Effects = ana_rehearsal:merge(ana_rehearsal:effects(C, St#st.held, St#st.stats_base), St#st.rehearsal),
            _ = epgsql:squery(C, "ROLLBACK"),
            finish(<<"success">>, #{result => Result, rolled_back => true, rehearsal => Effects}, St#st{in_tx = false});
        false when St#st.debug, not St#st.commit ->
            %% RNF-004-01: debugging always rolls back unless explicitly committed.
            _ = epgsql:squery(C, "ROLLBACK"),
            finish(<<"success">>, #{result => Result, rolled_back => true}, St#st{in_tx = false});
        false when St#st.prepare =/= undefined ->
            %% Atomic part: prepared; its main execution commits or rolls it back.
            case sq(C, ["PREPARE TRANSACTION '", St#st.prepare, "'"], ok) of
                {ok, ok} -> finish(<<"success">>, #{result => Result}, St#st{in_tx = false});
                {error, E} -> finish(<<"error">>, E, St#st{in_tx = false})
            end;
        false ->
            case prepared_parts(St) of
                [] ->
                    case epgsql:squery(C, "COMMIT") of
                        {ok, [], []} ->
                            ok = ana_values:apply_sets([S || not St#st.read_only, S <- lists:reverse(St#st.value_sets)], St#st.user),
                            finish(<<"success">>, #{result => Result}, offer_undo(St#st{in_tx = false}));
                        {error, E} ->
                            %% E.g. a deferred constraint violated at COMMIT (RF-006-05).
                            finish(<<"error">>, sql_error(E), St#st{in_tx = false})
                    end;
                Gids ->
                    two_phase_commit(Result, Gids, St)
            end
    end;
root_end2(M, St) ->
    Error = maps:get(<<"error">>, M, #{}),
    Status = case Error of
        #{<<"code">> := <<"ABORTED">>} -> <<"aborted">>;
        _ -> <<"error">>
    end,
    finish(Status, Error, St).

respond(Id, Res, #st{stack = [#frame{port = Port} | _]}) ->
    Msg = case Res of
        {ok, V} -> #{type => response, id => Id, ok => true, value => V};
        {error, E} -> #{type => response, id => Id, ok => false, error => E}
    end,
    catch ana_py:send(Port, Msg),
    ok;
respond(_, _, _) -> ok.

sq(C, Sql, Value) ->
    Rs = lists:flatten([epgsql:squery(C, Sql)]),
    case [E || {error, E} <- Rs] of
        [] -> {ok, Value};
        [E | _] -> {error, sql_error(E)}
    end.

%% ==========================================================================
%% Debugger (spec 004)
%% ==========================================================================

handle_command(#{<<"action">> := <<"stop">>}, St = #st{status = paused}) ->
    send_top(#{type => debug, action => stop}, St),
    {ok, resume(St)};
handle_command(#{<<"action">> := <<"stop">>}, St = #st{status = S}) when S =:= running; S =:= starting ->
    {ok, finish(<<"aborted">>, err(<<"ABORTED">>, <<"execução parada"/utf8>>), St)};
handle_command(#{<<"action">> := Action}, St = #st{status = paused})
  when Action =:= <<"continue">>; Action =:= <<"over">>; Action =:= <<"into">>; Action =:= <<"out">> ->
    send_top(#{type => debug, action => Action}, St),
    {ok, resume(St)};
handle_command(#{<<"action">> := <<"eval">>, <<"expression">> := Ex}, St = #st{status = paused})
  when is_binary(Ex), byte_size(Ex) =< 4096 ->
    send_top(#{type => debug, action => eval, expression => Ex}, St),
    {ok, St};
handle_command(#{<<"action">> := <<"breakpoints">>, <<"lines">> := L}, St = #st{status = paused})
  when is_list(L) ->
    send_top(#{type => debug, action => breakpoints, lines => L}, St),
    {ok, St#st{breakpoints = L}};
handle_command(#{<<"action">> := <<"breakpoints">>, <<"lines">> := L}, St) when is_list(L) ->
    %% Outside a pause it is only recorded; it applies to the next stop.
    {ok, St#st{breakpoints = L}};
handle_command(_, St = #st{status = S}) when S =/= paused ->
    {{error, not_paused}, St};
handle_command(_, St) ->
    {{error, invalid_command}, St}.

send_top(Msg, #st{stack = [#frame{port = Port} | _]}) ->
    catch ana_py:send(Port, Msg);
send_top(_, _) -> ok.

resume(St) ->
    cancel(St#st.idle_timer),
    arm_timeout(St#st{status = running, idle_timer = undefined}).

arm_timeout(St = #st{timeout_ms = T}) ->
    cancel(St#st.exec_timer),
    St#st{exec_timer = erlang:send_after(T, self(), timeout)}.

disarm_timeout(St) ->
    cancel(St#st.exec_timer),
    St#st{exec_timer = undefined}.

cancel(undefined) -> ok;
cancel(T) -> _ = erlang:cancel_timer(T), ok.

%% ==========================================================================
%% Events (RF-004-05)
%% ==========================================================================

event(Data, Type, St = #st{seq = S, events = Evs, waiters = Ws}) ->
    Ev = Data#{<<"seq">> => S + 1, <<"type">> => Type},
    Evs2 = case length(Evs) >= ?MAX_EVENTS of
        true -> [Ev | lists:sublist(Evs, ?MAX_EVENTS - 1)];
        false -> [Ev | Evs]
    end,
    St2 = St#st{seq = S + 1, events = Evs2, waiters = []},
    _ = [begin
             cancel(T),
             gen_server:reply(From, {ok, events_reply(new_events(Since, St2), St2)})
         end || {From, Since, T} <- Ws],
    St2.

new_events(Since, #st{events = Evs}) ->
    lists:reverse([E || E = #{<<"seq">> := S} <- Evs, S > Since]).

events_reply(Evs, St) ->
    #{events => Evs, status => St#st.status, seq => St#st.seq}.

record_output(#{<<"kind">> := <<"text">>, <<"data">> := T}, St) when is_binary(T) ->
    accumulate(T, St);
record_output(#{<<"kind">> := <<"log">>, <<"data">> := #{<<"message">> := Msg} = D}, St) ->
    accumulate(iolist_to_binary(["[", maps:get(<<"level">>, D, <<"info">>), "] ", Msg, "\n"]), St);
record_output(_, St) -> St.

%% RNF-002-06: the audited output is also bounded.
accumulate(T, St = #st{output_size = Size, output_max = Max}) when Size < Max ->
    Part = binary:part(T, 0, min(byte_size(T), Max - Size)),
    St#st{output = [St#st.output, Part], output_size = Size + byte_size(Part)};
accumulate(_, St) -> St.

summary(St = #st{final = Final}) ->
    Base = #{id => St#st.id, program => St#st.program, version => St#st.version,
             status => St#st.status, debug => St#st.debug, seq => St#st.seq,
             pause => null_if_undefined(St#st.last_pause)},
    case Final of
        undefined -> Base;
        _ -> maps:merge(Base, Final)
    end.

null_if_undefined(undefined) -> null;
null_if_undefined(V) -> V.

%% ==========================================================================
%% Parallel parts (spec 022)
%% ==========================================================================
%% par = #{next, parts => #{H => Part}, groups => #{G => #{max, running, queue}},
%%         gather => {RequestId, [H], FailFast, TimerRef}, snapshot, committed}
%% Part = #{status => queued | running | done, program, params, mode, group,
%%          timeout, snapshot, id, mon, gid, result => {ok, R} | {error, E}}

parts(#st{par = Par}) -> maps:get(parts, Par, #{}).

pending_parts(St) -> [H || {H, #{status := S}} <- maps:to_list(parts(St)), S =/= done].

prepared_parts(St) ->
    [G || {_, #{mode := <<"atomic">>, result := {ok, _}, gid := G}} <- maps:to_list(parts(St)), is_binary(G)].

part_spawn(Id, A, St = #st{par = Par}) ->
    Program = maps:get(<<"program">>, A, null),
    Params = maps:get(<<"params">>, A, #{}),
    Mode0 = maps:get(<<"mode">>, A, <<"independent">>),
    Group = maps:get(<<"group">>, A, 0),
    case is_binary(Program) andalso is_map(Params) andalso is_integer(Group)
         andalso lists:member(Mode0, [<<"independent">>, <<"atomic">>]) of
        false ->
            respond(Id, {error, err(<<"INVALID_PARAMETER">>, <<"parte inválida: programa, parâmetros ou modo"/utf8>>)}, St),
            St;
        true ->
            %% RF-022-08: while debugging, parts run one at a time and are undone with the
            %% execution unless "commit" was asked (they follow it in atomic mode).
            Mode = case St#st.debug of true -> <<"atomic">>; false -> Mode0 end,
            St1 = case St#st.debug andalso not maps:get(debug_warned, Par, false) of
                true -> event(#{<<"kind">> => <<"log">>, <<"data">> => #{<<"level">> => <<"warning">>,
                                <<"message">> => <<"depuração: partes paralelas rodam uma por vez, junto com a transação da depuração"/utf8>>}},
                              <<"output">>, St#st{par = Par#{debug_warned => true}});
                false -> St
            end,
            case snapshot_for(maps:get(<<"snapshot">>, A, false) =:= true, St1) of
                {error, E, St2} ->
                    respond(Id, {error, E}, St2),
                    St2;
                {ok, Snap, St2 = #st{par = Par2}} ->
                    H = maps:get(next, Par2, 1),
                    Part = #{status => queued, program => Program, params => Params, mode => Mode,
                             group => Group, timeout => maps:get(<<"timeout_ms">>, A, null), snapshot => Snap},
                    Groups = maps:get(groups, Par2, #{}),
                    G0 = maps:get(Group, Groups, #{max => workers(maps:get(<<"max_workers">>, A, null), St2),
                                                   running => 0, queue => queue:new()}),
                    G1 = G0#{queue => queue:in(H, maps:get(queue, G0))},
                    Par3 = Par2#{next => H + 1, parts => (maps:get(parts, Par2, #{}))#{H => Part},
                                 groups => Groups#{Group => G1}},
                    St3 = try_start(Group, St2#st{par = Par3}),
                    respond(Id, {ok, H}, St3),
                    St3
            end
    end.

%% RF-022-06: max_workers never above max_parallel_parts nor the program pool (minus the main).
workers(_, #st{debug = true}) -> 1;
workers(Asked, #st{limits = L}) ->
    Limit = maps:get(<<"max_parallel_parts">>, L, 8),
    Pool = max(1, ana_config:integer("ANA_DB_POOL_EXEC", 20) - 2),
    Base = case Asked of N when is_integer(N), N > 0 -> N; _ -> Limit end,
    max(1, lists:min([Base, Limit, Pool])).

%% RF-022-05: exported once per main execution; the transaction stays open while parts run.
snapshot_for(false, St) -> {ok, undefined, St};
snapshot_for(true, St = #st{par = #{snapshot := S}}) -> {ok, S, St};
snapshot_for(true, St = #st{conn = C, par = Par}) ->
    case epgsql:squery(C, "SELECT pg_export_snapshot()") of
        {ok, _, [{S}]} -> {ok, S, St#st{par = Par#{snapshot => S}}};
        {error, E} -> {error, sql_error(E), St}
    end.

try_start(Group, St = #st{par = Par}) ->
    Groups = maps:get(groups, Par),
    G = #{max := Max, running := Running, queue := Q} = maps:get(Group, Groups),
    case Running < Max andalso queue:out(Q) of
        {{value, H}, Q2} ->
            St2 = start_part(H, St#st{par = Par#{groups => Groups#{Group => G#{running => Running + 1, queue => Q2}}}}),
            try_start(Group, St2);
        _ ->
            St
    end.

start_part(H, St = #st{par = Par}) ->
    Part = maps:get(H, maps:get(parts, Par)),
    Remaining = St#st.timeout_ms - (erlang:monotonic_time(millisecond) - St#st.started),
    case Remaining < 100 of
        true ->
            finish_part(H, {error, err(<<"TIMEOUT">>, <<"sem tempo restante na execução principal"/utf8>>)}, St);
        false ->
            Timeout = case maps:get(timeout, Part) of
                T when is_integer(T), T > 0 -> min(T, Remaining);
                _ -> Remaining
            end,
            ChildId = uuid(),
            Gid = case maps:get(mode, Part) of
                _ when St#st.rehearse -> undefined;      % spec 056: a rehearsed part is undone by itself
                <<"atomic">> -> ana_parallel:gid(St#st.id, H);
                _ -> undefined
            end,
            Opts0 = #{id => ChildId, origin => St#st.origin, parent => St#st.id, parent_pid => self(),
                      timeout_ms => Timeout, rehearse => St#st.rehearse},
            Opts1 = case Gid of undefined -> Opts0; _ -> Opts0#{prepare => Gid} end,
            Opts = case maps:get(snapshot, Part) of undefined -> Opts1; S -> Opts1#{snapshot => S} end,
            Self = self(),
            #{program := Program, params := Params} = Part,
            User = St#st.user,
            {_, Mon} = spawn_monitor(fun() ->
                Self ! {part_done, H, run(Program, Params, User, Opts)}
            end),
            Parts = maps:get(parts, Par),
            St#st{par = Par#{parts => Parts#{H => Part#{status => running, id => ChildId, mon => Mon, gid => Gid}}}}
    end.

simplify({ok, #{result := R}}) -> {ok, R};
simplify({ok, R}) -> {ok, R};
simplify({error, E}) -> {error, maps:without([<<"events">>], E)}.

part_done(H, Res, St) ->
    case maps:get(H, parts(St), undefined) of
        #{status := running, mon := Mon} ->
            demonitor(Mon, [flush]),
            finish_part(H, Res, St);
        #{status := done, mode := <<"atomic">>, gid := Gid} when is_binary(Gid) ->
            %% Cancelled while it was preparing: undo what it prepared.
            _ = element(1, Res) =:= ok andalso is_pid(spawn(fun() -> ana_parallel:resolve([Gid], rollback) end)),
            St;
        _ ->
            St
    end.

part_crashed(Mon, Reason, St) ->
    case [H || {H, #{status := running, mon := M}} <- maps:to_list(parts(St)), M =:= Mon] of
        [H] ->
            logger:error("execution ~s: part ~b ended without a result: ~0p", [St#st.id, H, Reason]),
            finish_part(H, {error, err(<<"INTERNAL">>, <<"parte encerrada inesperadamente"/utf8>>)}, St);
        [] -> St
    end.

%% A part ends (result, cancellation or error): frees its slot and serves gather.
finish_part(H, Res, St = #st{par = Par}) ->
    Parts = maps:get(parts, Par),
    Part = #{group := Group, status := Was} = maps:get(H, Parts),
    Groups = maps:get(groups, Par),
    G = maps:get(Group, Groups),
    G2 = case Was of
        running -> G#{running => maps:get(running, G) - 1};
        queued -> G#{queue => queue:filter(fun(X) -> X =/= H end, maps:get(queue, G))};
        done -> G
    end,
    St2 = St#st{par = Par#{parts => Parts#{H => Part#{status => done, result => Res}},
                           groups => Groups#{Group => G2}}},
    check_gather(try_start(Group, St2)).

part_cancel(Hs, Msg, St) ->
    lists:foldl(fun(H, Acc) ->
        case maps:get(H, parts(Acc), undefined) of
            #{status := running, id := Id, mon := Mon} ->
                demonitor(Mon, [flush]),
                abort(Id),
                finish_part(H, {error, err(<<"CANCELLED">>, Msg)}, Acc);
            #{status := queued} ->
                finish_part(H, {error, err(<<"CANCELLED">>, Msg)}, Acc);
            _ -> Acc
        end
    end, St, Hs).

part_gather(Id, Hs, FailFast, Timeout, St = #st{par = Par}) ->
    Known = parts(St),
    case maps:is_key(gather, Par) orelse not lists:all(fun(H) -> maps:is_key(H, Known) end, Hs) of
        true ->
            respond(Id, {error, err(<<"INVALID_PARAMETER">>, <<"partes desconhecidas ou espera já em andamento"/utf8>>)}, St),
            St;
        false ->
            Ref = make_ref(),
            T = case Timeout of
                N when is_integer(N), N > 0 -> erlang:send_after(N, self(), {gather_timeout, Ref});
                _ -> undefined
            end,
            check_gather(St#st{par = Par#{gather => {Id, Hs, FailFast, Ref, T}}})
    end.

check_gather(St = #st{par = #{gather := {Id, Hs, FailFast, _, T}} = Par}) ->
    Parts = maps:get(parts, Par),
    Done = [H || H <- Hs, maps:get(status, maps:get(H, Parts)) =:= done],
    Failed = [H || H <- Done, element(1, maps:get(result, maps:get(H, Parts))) =:= error],
    if
        FailFast, Failed =/= [], length(Done) < length(Hs) ->
            %% RF-022-01: first failure cancels the others.
            check_gather(part_cancel(Hs -- Done, <<"cancelada: outra parte falhou"/utf8>>, St));
        length(Done) =:= length(Hs) ->
            cancel(T),
            Reply = [case maps:get(result, maps:get(H, Parts)) of
                         {ok, R} -> #{ok => true, result => R};
                         {error, E} -> #{ok => false, error => E}
                     end || H <- Hs],
            St2 = St#st{par = maps:remove(gather, Par)},
            respond(Id, {ok, Reply}, St2),
            St2;
        true ->
            St
    end;
check_gather(St) ->
    St.

gather_expired(St = #st{par = #{gather := {_, Hs, _, _, _}}}) ->
    St2 = part_cancel([H || H <- Hs, maps:get(status, maps:get(H, parts(St))) =/= done],
                      <<"prazo de espera das partes esgotado"/utf8>>, St),
    check_gather(St2).

%% RF-022-04: PREPARE the main transaction, record the decision, COMMIT PREPARED all.
two_phase_commit(Result, Gids, St = #st{conn = C, par = Par}) ->
    Own = ana_parallel:gid(St#st.id, 0),
    case sq(C, ["PREPARE TRANSACTION '", Own, "'"], ok) of
        {ok, ok} ->
            All = [Own | Gids],
            case ana_parallel:decide(Own, All) of
                ok ->
                    Failed = [G || G <- All, {error, _} <- [epgsql:squery(C, ["COMMIT PREPARED '", G, "'"])]],
                    ok = ana_values:apply_sets([S || not St#st.read_only, S <- lists:reverse(St#st.value_sets)], St#st.user),
                    _ = case Failed of
                        [] -> ana_parallel:forget(Own);
                        _ -> logger:error("execution ~s: COMMIT PREPARED failed for ~p; recovery will finish it",
                                          [St#st.id, Failed])
                    end,
                    finish(<<"success">>, #{result => Result}, offer_undo(St#st{in_tx = false, par = Par#{committed => true}}));
                {error, E} ->
                    logger:error("execution ~s: commit decision not recorded: ~0p", [St#st.id, E]),
                    _ = ana_parallel:resolve([Own], rollback),
                    finish(<<"error">>, err(<<"INTERNAL">>, <<"falha ao confirmar as partes atômicas"/utf8>>),
                           St#st{in_tx = false})
            end;
        {error, E} ->
            finish(<<"error">>, E, St#st{in_tx = false})
    end.

%% When the main execution finishes: cancels parts still running and undoes
%% prepared ones unless they were committed.
parts_cleanup(St = #st{par = Par}) when map_size(Par) =:= 0 -> St;
parts_cleanup(St = #st{par = Par}) ->
    St2 = part_cancel(pending_parts(St), <<"execução principal encerrada"/utf8>>, St#st{par = maps:remove(gather, Par)}),
    _ = case maps:get(committed, Par, false) of
        false ->
            case prepared_parts(St2) of
                [] -> ok;
                Gids -> spawn(fun() -> ana_parallel:resolve(Gids, rollback) end)
            end;
        true -> ok
    end,
    St2#st{par = (St2#st.par)#{committed => true}}.

%% ==========================================================================
%% Finishing
%% ==========================================================================

finish(_Status, _Data, St = #st{status = finished}) ->
    St;
finish(Status, Data, St00) ->
    St0 = parts_cleanup(St00),
    St = disarm_timeout(St0),
    cancel(St#st.idle_timer),
    %% Ends Python processes and any pending operation.
    _ = [ana_py:kill({F#frame.port, F#frame.ospid}) || F <- St#st.stack],
    case St#st.pending of
        {_, Pid, _} ->
            unlink(Pid),
            exit(Pid, kill),
            catch epgsql:cancel(St#st.conn);
        undefined -> ok
    end,
    return_connection(St),
    Duration = erlang:monotonic_time(millisecond) - St#st.started,
    {Result, Error} = case Status of
        <<"success">> -> {maps:get(result, Data, null), null};
        _ -> {null, Data#{<<"execution_id">> => St#st.id}}
    end,
    RolledBack = maps:get(rolled_back, Data, false),
    %% Spec 056: a rehearsal that stopped on an error still says what it had held up to there.
    Rehearsal = case St#st.rehearse of
        true -> maps:get(rehearsal, Data, ana_rehearsal:merge(#{held => lists:reverse(St#st.held)}, St#st.rehearsal));
        false -> null
    end,
    audit_end(St, Status, Duration, Result, Error),
    _ = (catch observe(Status, Duration, St)),
    Final = #{final_status => Status, result => Result, error => Error,
              duration_ms => Duration, rolled_back => RolledBack, rehearsal => Rehearsal,
              usage => usage(St), limits => St#st.limits},
    St2 = event(#{<<"status">> => Status, <<"result">> => Result, <<"error">> => Error,
                  <<"duration_ms">> => Duration, <<"rolled_back">> => RolledBack orelse St#st.rehearse,
                  <<"rehearsal">> => Rehearsal, <<"usage">> => usage(St), <<"undo">> => St#st.undo_offered},
                <<"end">>,
                St#st{stack = [], pending = undefined, conn = undefined, in_tx = false, final = Final}),
    _ = St2#st.admitted andalso release(St2#st.debug) =:= ok,
    ok = ana_limits:release(St2#st.tokens),
    St3 = St2#st{status = finished, admitted = false, tokens = []},
    _ = case St3#st.caller of
        {Pid2, Ref} ->
            Pid2 ! {ana_end, Ref, sync_reply(Status, Result, Error, Duration, St3)},
            self() ! shutdown;
        undefined ->
            erlang:send_after(?RETENTION_MS, self(), shutdown)
    end,
    St3.

sync_reply(<<"success">>, Result, _, Duration, St) ->
    R = #{id => St#st.id, result => Result, duration_ms => Duration, usage => usage(St),
          events => lists:reverse(St#st.events)},
    {ok, with_undo(with_rehearsal(R, rehearsal, St), St)};
sync_reply(_, _, Error, _, St) ->
    {error, with_rehearsal(Error#{<<"events">> => lists:reverse(St#st.events)}, <<"rehearsal">>, St)}.

%% Spec 050 (D5): the answer carries the undo the routine offered (recorded after its COMMIT).
with_undo(M, #st{undo_offered = null}) -> M;
with_undo(M, #st{undo_offered = U}) -> M#{undo => U}.

offer_undo(St = #st{undo = undefined}) -> St;
offer_undo(St = #st{undo = Offer, id = Id, user = User}) ->
    case ana_undo:record(Id, User, Offer) of
        {ok, U} -> St#st{undo_offered = U};
        {error, E} ->
            logger:warning("execution ~s: undo offer not recorded: ~0p", [Id, E]),
            St
    end.

%% Spec 050: may this user run that program now (role, groups, portal, license)?
-spec can_run(binary(), map()) -> boolean().
can_run(Name, User) when is_binary(Name) ->
    element(1, load(Name, User)) =:= ok;
can_run(_, _) -> false.

new_id() -> uuid().

%% Spec 056: the answer of a rehearsal carries its effects (also when it stopped on an error).
with_rehearsal(M, K, #st{rehearse = true, final = #{rehearsal := E}}) when is_map(E) -> M#{K => E};
with_rehearsal(M, _, _) -> M.

%% Returns the connection clean to the pool; if that is not possible, drops it.
return_connection(#st{conn = undefined}) -> ok;
return_connection(#st{conn = C, in_tx = InTx}) ->
    Self = self(),
    Ref = make_ref(),
    Pid = spawn(fun() ->
        R = case InTx of
            true -> catch epgsql:squery(C, "ROLLBACK");
            false -> {ok, [], []}
        end,
        Self ! {cleanup, Ref, R}
    end),
    receive
        {cleanup, Ref, {ok, [], []}} -> ana_db:checkin(?POOL, C);
        {cleanup, Ref, _} -> exit(C, kill)
    after 5000 ->
        exit(Pid, kill),
        exit(C, kill)
    end,
    ok.

%% ==========================================================================
%% Audit (RF-002-09) — core connection, outside the execution transaction
%% ==========================================================================

%% RF-024-04: where the call came from (IP and API key) and which node ran it.
trace(#st{user = U}) ->
    T = maps:get(trace, U, #{}),
    [maps:get(ip, T, null), maps:get(key_id, T, null), ana_config:node_id()].

parent(#st{parent_id = undefined}) -> null;
parent(#st{parent_id = P}) -> P.

%% RF-024-05: Erlang stack trace of an internal failure, bounded.
crash_trace(Class, Reason, Stack) ->
    B = unicode:characters_to_binary(io_lib:format("~0tp:~0tp~n~tp", [Class, Reason, Stack])),
    case B of
        <<Head:16384/binary, _/binary>> -> <<Head/binary, "…"/utf8>>;
        _ -> B
    end.

audit_start(St) ->
    case ana_db:exec(
           "INSERT INTO ana_system.execution (id, program, version, username, origin, debug, status, params, "
           "  client_ip, api_key_id, node, parent_execution_id, rehearsal, variant) "
           "VALUES ($1::text::uuid, $2, $3, $4, $5, $6, 'running', $7::text::jsonb, $8, $9, $10, $11::text::uuid, $12, $13::text::jsonb)",
           [St#st.id, St#st.program, St#st.version, maps:get(username, St#st.user),
            St#st.origin, St#st.debug, json_text(St#st.params)] ++ trace(St) ++ [parent(St), St#st.rehearse,
                                                                                json_text(St#st.variant)]) of
        {ok, _} -> ok;
        {error, E} -> logger:error("audit (start) failed: ~0p", [E]), ok
    end.

audit_end(St, Status, Duration, Result, Error) ->
    Sql = "INSERT INTO ana_system.execution (id, program, version, username, origin, debug, "
          "  status, params, finished_at, duration_ms, result, error, output, "
          "  cpu_ms, max_rss_kb, sql_count, rows_read, limits, client_ip, api_key_id, node, internal_trace, "
          "  parent_execution_id, rehearsal, values_read, variant) "
          "VALUES ($1::text::uuid, $2, $3, $4, $5, $6, $7, $8::text::jsonb, now(), $9, "
          "        $10::text::jsonb, $11::text::jsonb, $12, $13, $14, $15, $16, $17::text::jsonb, "
          "        $18, $19, $20, $21, $22::text::uuid, $23, $24::text::jsonb, $25::text::jsonb) "
          "ON CONFLICT (id) DO UPDATE SET status = EXCLUDED.status, finished_at = now(), "
          "  duration_ms = EXCLUDED.duration_ms, result = EXCLUDED.result, "
          "  error = EXCLUDED.error, output = EXCLUDED.output, cpu_ms = EXCLUDED.cpu_ms, "
          "  max_rss_kb = EXCLUDED.max_rss_kb, sql_count = EXCLUDED.sql_count, "
          "  rows_read = EXCLUDED.rows_read, limits = EXCLUDED.limits, "
          "  internal_trace = EXCLUDED.internal_trace, values_read = EXCLUDED.values_read",
    Params = [St#st.id, St#st.program, St#st.version, maps:get(username, St#st.user),
              St#st.origin, St#st.debug, Status, json_text(St#st.params),
              Duration, json_text(Result), json_text(Error),
              unicode:characters_to_binary(St#st.output),
              St#st.cpu_ms, St#st.max_rss_kb, St#st.sql_count, St#st.rows_read,
              json_text(case St#st.limits of M when map_size(M) =:= 0 -> null; M -> M end)]
             ++ trace(St) ++ [St#st.internal_trace, parent(St), St#st.rehearse,
                              json_text(case St#st.values_read of R when map_size(R) =:= 0 -> null; R -> R end),
                              json_text(St#st.variant)],
    case ana_db:exec(Sql, Params) of
        {ok, _} -> ok;
        {error, E} -> logger:error("audit (end) failed: ~0p", [E])
    end.

json_text(null) -> null;
json_text(V) -> iolist_to_binary(json:encode(V)).

%% ==========================================================================
%% SQL performance (spec 019)
%% ==========================================================================

-define(MAX_SQL_EVENTS, 2000).

now_us() -> erlang:monotonic_time(microsecond).

note_sql(_Res, St = #st{sql_cur = undefined}) -> St;
note_sql(Res, St = #st{sql_cur = {T0, Sql, At}}) ->
    Us = now_us() - T0,
    Rows = case Res of
        {ok, #{rows := [_ | _] = R}} -> length(R);
        {ok, #{affected := N}} when is_integer(N) -> N;       % writes: rows changed (spec 063)
        _ -> 0
    end,
    Norm = ana_sql_stats:normalize(Sql),
    H = ana_sql_stats:hash(Norm),
    ByHash = case maps:find(H, St#st.sql_by_hash) of
        {ok, {Q, C, T, M, Rw, At0}} -> (St#st.sql_by_hash)#{H := {Q, C + 1, T + Us, max(M, Us), Rw + Rows, At0}};
        error -> (St#st.sql_by_hash)#{H => {Norm, 1, Us, Us, Rows, At}}
    end,
    Events = case St#st.sql_n < ?MAX_SQL_EVENTS of
        true -> [#{t_ms => (T0 div 1000) - St#st.started, ms => Us / 1000, rows => Rows, hash => H,
                   sql => binary:part(Norm, 0, min(byte_size(Norm), 2000)), at => At,
                   error => element(1, Res) =:= error} | St#st.sql_events];
        false -> St#st.sql_events
    end,
    St#st{sql_cur = undefined, sql_by_hash = ByHash, sql_events = Events, sql_n = St#st.sql_n + 1,
          sql_us = St#st.sql_us + Us}.

%% At the end: aggregates, N+1, metrics and (sampled) trace — never in the way of the result.
observe(Status, Duration, St = #st{program = Program}) ->
    Stats = [{H, Q, C, T, M, R} || {H, {Q, C, T, M, R, _}} <- maps:to_list(St#st.sql_by_hash)],
    ok = ana_sql_stats:record(Program, Stats),
    Threshold = ana_settings:get(n_plus_one_threshold),
    _ = [ana_sql_stats:n_plus_one(Program, H, Q, C, At, St#st.id)
         || {H, {Q, C, _, _, _, At}} <- maps:to_list(St#st.sql_by_hash), C >= Threshold],
    SqlMs = St#st.sql_us / 1000,
    ok = ana_metrics:observe(Program, Status, Duration, SqlMs),
    Reason = if
        Status =/= <<"success">> -> <<"error">>;
        is_map(St#st.profile) -> <<"profile">>;
        true ->
            case Duration >= ana_settings:get(trace_slow_ms) of
                true -> <<"slow">>;
                false ->
                    case rand:uniform(100) =< ana_settings:get(trace_sample_pct) of
                        true -> <<"sample">>;
                        false -> none
                    end
            end
    end,
    case Reason of
        none -> ok;
        _ ->
            Events = lists:reverse(St#st.sql_events),
            Profile = case St#st.profile of P when is_map(P) -> P; _ -> null end,
            Id = St#st.id,
            _ = spawn(fun() ->
                ana_db:exec("INSERT INTO ana_system.execution_trace (execution_id, program, reason, sql_ms, events, profile) "
                            "VALUES ($1::text::uuid, $2, $3, $4, $5, $6) ON CONFLICT (execution_id) DO NOTHING",
                            [Id, Program, Reason, SqlMs, Events, Profile])
            end),
            ok
    end.

%% ==========================================================================
%% Measurement and row limits (spec 012)
%% ==========================================================================

%% RF-012-06: ROW_LIMIT when a query returns more rows than allowed.
count_rows({ok, #{rows := Rows}} = Res, St = #st{limits = L}) ->
    N = length(Rows),
    St2 = St#st{rows_read = St#st.rows_read + N},
    case maps:get(<<"max_rows">>, L, 0) of
        Max when Max > 0, N > Max ->
            {{error, err(<<"ROW_LIMIT">>, io_lib:format("consulta devolveu ~b linhas; limite é ~b", [N, Max]))}, St2};
        _ -> {Res, St2}
    end;
count_rows(Res, St) -> {Res, St}.

%% RF-012-07: CPU and memory reported by each Python process at the end.
add_usage(#{<<"usage">> := #{<<"cpu_ms">> := Cpu, <<"max_rss_kb">> := Rss}}, St)
  when is_integer(Cpu), is_integer(Rss) ->
    St#st{cpu_ms = St#st.cpu_ms + Cpu, max_rss_kb = max(St#st.max_rss_kb, Rss)};
add_usage(_, St) -> St.

usage(St) ->
    #{cpu_ms => St#st.cpu_ms, max_rss_kb => St#st.max_rss_kb,
      sql_count => St#st.sql_count, rows_read => St#st.rows_read}.

%% ==========================================================================
%% Helpers
%% ==========================================================================

as_list(L) when is_list(L) -> L;
as_list(_) -> [].

err(Code, Msg) -> #{<<"code">> => Code, <<"message">> => unicode:characters_to_binary(Msg)}.
err(Code, Msg, Id) -> (err(Code, Msg))#{<<"execution_id">> => Id}.

sql_error(E) -> bin_keys(ana_db:sql_error(E)).

bin_keys(M) ->
    maps:fold(fun(K, V, Acc) when is_atom(K) -> Acc#{atom_to_binary(K) => V};
                 (K, V, Acc) -> Acc#{K => V}
              end, #{}, M).

%% UUID v4
uuid() ->
    <<A:48, _:4, B:12, _:2, C:62>> = crypto:strong_rand_bytes(16),
    <<U:128>> = <<A:48, 4:4, B:12, 2:2, C:62>>,
    <<P1:8/binary, P2:4/binary, P3:4/binary, P4:4/binary, P5:12/binary>> =
        list_to_binary(string:lowercase(io_lib:format("~32.16.0b", [U]))),
    <<P1/binary, "-", P2/binary, "-", P3/binary, "-", P4/binary, "-", P5/binary>>.
