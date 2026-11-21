%% SPDX-FileCopyrightText: 2026 LE Devices
%% SPDX-License-Identifier: AGPL-3.0-or-later
%% Circuit breakers for external dependencies (spec 023, RF-023-07).
%%
%% closed  → calls pass; consecutive failures are counted.
%% open    → after ?THRESHOLD failures, calls fail at once for ANA_BREAKER_OPEN_MS (30 s).
%% half    → after the interval, one trial call decides: success closes,
%%           failure opens again. State lives in ETS (per node).
-module(ana_breaker).
-export([init_table/0, call/2, call/3, state/1, reset/1, open_keys/0]).

-define(TAB, ana_breakers).
-define(THRESHOLD, 5).

init_table() ->
    _ = ets:new(?TAB, [named_table, public, set, {write_concurrency, true}]),
    ok.

%% Fun() -> {ok, _} | {error, _}. IsFailure(Error) tells an unavailable dependency
%% (counts) from an answer that merely says no (does not). Exceptions count.
-spec call(term(), fun(() -> {ok, term()} | {error, term()})) -> {ok, term()} | {error, term()}.
call(Key, Fun) -> call(Key, Fun, fun(_) -> true end).

-spec call(term(), fun(() -> {ok, term()} | {error, term()}), fun((term()) -> boolean())) ->
    {ok, term()} | {error, term()}.
call(Key, Fun, IsFailure) ->
    Now = erlang:monotonic_time(millisecond),
    case allow(Key, Now) of
        false ->
            {error, #{<<"code">> => <<"REMOTE_UNAVAILABLE">>,
                      <<"message">> => <<"sistema remoto indisponível (disjuntor aberto); tente mais tarde"/utf8>>}};
        true ->
            try Fun() of
                {ok, _} = Ok -> success(Key), Ok;
                {error, E} = Err ->
                    _ = case IsFailure(E) of true -> failure(Key, E, Now); false -> success(Key) end,
                    Err
            catch Class:Reason:Stack ->
                failure(Key, Reason, Now),
                erlang:raise(Class, Reason, Stack)
            end
    end.

allow(Key, Now) ->
    case ets:lookup(?TAB, Key) of
        [{_, open, _, Until}] when Now < Until -> false;
        [{_, open, N, _}] ->
            %% Half-open: only the caller that flips the state makes the trial call.
            ets:select_replace(?TAB, [{{Key, open, N, '$1'}, [{'=<', '$1', Now}], [{{Key, half, N, Now}}]}]) =:= 1;
        [{_, half, _, _}] -> false;
        _ -> true
    end.

success(Key) ->
    ets:delete(?TAB, Key),
    ok.

failure(Key, Reason, Now) ->
    case ets:lookup(?TAB, Key) of
        [{_, half, N, _}] -> open(Key, N + 1, Now, Reason);
        [{_, closed, N, _}] when N + 1 >= ?THRESHOLD -> open(Key, N + 1, Now, Reason);
        [{_, closed, N, _}] -> ets:insert(?TAB, {Key, closed, N + 1, Now});
        [{_, open, _, _}] -> ok;
        [] -> ets:insert(?TAB, {Key, closed, 1, Now})
    end,
    ok.

open(Key, N, Now, Reason) ->
    logger:warning("circuit breaker ~0p open after ~b failures: ~0p", [Key, N, Reason]),
    ets:insert(?TAB, {Key, open, N, Now + ana_config:integer("ANA_BREAKER_OPEN_MS", 30000)}).

-spec state(term()) -> closed | open | half.
state(Key) ->
    case ets:lookup(?TAB, Key) of
        [{_, S, _, _}] -> S;
        [] -> closed
    end.

reset(Key) -> success(Key).

%% Spec 033 (robustness checks): breakers currently open on this node.
-spec open_keys() -> [term()].
open_keys() ->
    try [K || {K, S, _, _} <- ets:tab2list(?TAB), S =/= closed]
    catch error:badarg -> []
    end.
