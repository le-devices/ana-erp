%% SPDX-FileCopyrightText: 2026 André Luis Pereira dos Santos
%% SPDX-License-Identifier: AGPL-3.0-or-later
%% "Núcleo" (spec 062, D6; constitution P20): a read-only look inside the running core for administrators —
%% the processes that use the most memory, work (reductions) and have the longest message queues, the
%% supervisors of each area with their children and recent restarts, ETS tables and run queues.
-module(ana_core_view).
-behaviour(gen_server).
-export([start_link/0, snapshot/0, max_queue/0]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2]).

-define(TOP, 15).
-define(EVERY_MS, 10000).

start_link() -> gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

-spec snapshot() -> {ok, map()}.
snapshot() ->
    Procs = [I || P <- processes(), I <- [info(P)], I =/= undefined],
    Top = fun(K) -> lists:sublist(lists:reverse(lists:keysort(1, [{maps:get(K, I), I} || I <- Procs])), ?TOP) end,
    Mem = maps:from_list([{K, V div 1048576} || {K, V} <- erlang:memory(), lists:member(K, [total, processes, binary, ets, code, atom])]),
    Restarts = try gen_server:call(?MODULE, restarts, 2000) catch _:_ -> [] end,
    {ok, #{memory_mb => Mem, processes => length(Procs), run_queue => erlang:statistics(total_run_queue_lengths),
           schedulers => erlang:system_info(schedulers_online), nodes => [node() | nodes()],
           top_memory => [I || {_, I} <- Top(memory_kb)], top_reductions => [I || {_, I} <- Top(reductions)],
           top_queue => [I || {Q, I} <- Top(queue), Q > 0],
           areas => [area(A) || A <- ana_area_sup:areas()], restarts => Restarts, dropped => ana_bounded:dropped(),
           ets => [#{table => T, kb => Kb} || {T, Kb} <- lists:sublist(lists:reverse(lists:keysort(2,
                       [{T, ets:info(T, memory) * erlang:system_info(wordsize) div 1024} || T <- ets:all(), is_atom(T)])), ?TOP)]}}.

%% The longest message queue now (an alert rule can watch it: spec 019).
-spec max_queue() -> non_neg_integer().
max_queue() ->
    lists:max([0 | [Q || P <- processes(), {message_queue_len, Q} <- [process_info(P, message_queue_len)]]]).

info(P) ->
    case process_info(P, [registered_name, initial_call, memory, reductions, message_queue_len, current_function]) of
        undefined -> undefined;
        L ->
            Name = case proplists:get_value(registered_name, L) of
                [] -> label(P, proplists:get_value(initial_call, L));
                N -> atom_to_binary(N)
            end,
            #{name => Name, memory_kb => proplists:get_value(memory, L) div 1024,
              reductions => proplists:get_value(reductions, L), queue => proplists:get_value(message_queue_len, L),
              current => mfa(proplists:get_value(current_function, L))}
    end.

%% Unnamed processes: the module that started them (proc_lib knows the real one).
label(P, Initial) ->
    case catch proc_lib:translate_initial_call(P) of
        {M, F, A} when M =/= proc_lib -> mfa({M, F, A});
        _ -> mfa(Initial)
    end.

mfa({M, F, A}) -> iolist_to_binary(io_lib:format("~s:~s/~b", [M, F, A]));
mfa(_) -> <<"?">>.

area(Sup) ->
    Children = try supervisor:which_children(Sup) catch _:_ -> [] end,
    #{area => Sup, children => [#{id => iolist_to_binary(io_lib:format("~0p", [Id])), alive => is_pid(Pid)}
                                || {Id, Pid, _, _} <- Children]}.

%% Restarts: a child whose pid changed between two looks (every 10 s), kept for the last hour.
init([]) ->
    erlang:send_after(?EVERY_MS, self(), look),
    {ok, #{pids => #{}, restarts => []}}.

handle_call(restarts, _, S = #{restarts := R}) -> {reply, R, S};
handle_call(_, _, S) -> {reply, ok, S}.
handle_cast(_, S) -> {noreply, S}.

handle_info(look, S = #{pids := Old, restarts := R}) ->
    erlang:send_after(?EVERY_MS, self(), look),
    Now = erlang:system_time(second),
    New = maps:from_list([{{A, Id}, Pid} || A <- ana_area_sup:areas(), {Id, Pid, _, _} <- (catch supervisor:which_children(A)),
                                            is_pid(Pid)] ++ [{{ana_sup, A}, whereis(A)} || A <- ana_area_sup:areas()]),
    Changed = [#{area => A, child => iolist_to_binary(io_lib:format("~0p", [Id])), at => Now}
               || {{A, Id}, Pid} <- maps:to_list(New), maps:is_key({A, Id}, Old), maps:get({A, Id}, Old) =/= Pid],
    Keep = [X || X = #{at := At} <- Changed ++ R, Now - At < 3600],
    {noreply, S#{pids := New, restarts := lists:sublist(Keep, 100)}};
handle_info(_, S) -> {noreply, S}.
