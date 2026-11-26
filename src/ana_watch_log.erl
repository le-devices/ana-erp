%% SPDX-FileCopyrightText: 2026 André Luis Pereira dos Santos
%% SPDX-License-Identifier: AGPL-3.0-or-later
%% Change watch on master data (spec 068, T-068-03, D4): the changes are read from the history that already exists
%% (master.change_log), so watching a master adds no write per change.
%%
%% Only the leader reads, and only while an active "changed" rule watches some master: once a second
%% (p95 of 2 s, RNF-068-02) by the primary key, never without a rule. A smaller id may be committed after a bigger one
%% (a longer transaction): the ids missing below the highest one read are kept in memory and looked for again, and
%% forgotten after ?GAP_MS (the idle-transaction limit of the executions) or when they never come (a rollback).
%%
%% What some rule watches is claimed by ana_rules (a firing 'running', unique per rule and event) in the same
%% transaction that records the point; the point alone is written at most every ?SAVE_MS. After a restart or a
%% leader change the history is read again from the point: the unique claim keeps it from firing twice
%% (RNF-068-04, CA-068-11).
-module(ana_watch_log).
-behaviour(gen_server).

-export([start_link/0, status/0]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2]).
-export([advance/5]).

-define(READ_MS, 1000).
-define(CHECK_MS, 30000).
-define(GAP_MS, 900000).
-define(SAVE_MS, 300000).
-define(BATCH, 500).
-define(MARK, <<"change_log">>).

start_link() -> gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

-spec status() -> map().
status() -> gen_server:call(?MODULE, status).

init([]) ->
    ok = ana_events:subscribe(<<"watch">>),
    erlang:send_after(4000, self(), check),
    {ok, #{active => false, point => undefined, high => undefined, missing => #{}, saved => undefined,
           saved_at => 0, timer => undefined}}.

handle_call(status, _From, S = #{active := A, point := P, high := H, missing := M}) ->
    {reply, #{active => A, point => P, high => H, missing => maps:size(M)}, S};
handle_call(_, _From, S) -> {reply, {error, unknown}, S}.

handle_cast(_, S) -> {noreply, S}.

handle_info({ana_event, <<"watch">>, _}, S) -> {noreply, check(S)};
handle_info(check, S) ->
    erlang:send_after(?CHECK_MS, self(), check),
    {noreply, check(S)};
handle_info(read, S) -> {noreply, read(S#{timer := undefined})};
handle_info(_, S) -> {noreply, S}.

%% ---------------------------------------------------------------- active or not

check(S = #{active := Was}) ->
    case {Was, leader(), leader() andalso watching()} of
        {false, true, true} -> start(S);
        {true, false, _} -> stop_local(S);                    % another node leads now: it resumes from the point
        {true, true, false} -> stop(S);
        _ -> S
    end.

watching() ->
    case ana_db:one("SELECT EXISTS (SELECT 1 FROM automation.rule r JOIN automation.watch_entity e ON e.entity = r.entity "
                    "WHERE r.active AND r.trigger_kind = 'changed' AND e.source = 'master') AS w", []) of
        {ok, #{<<"w">> := W}} -> W;
        _ -> false
    end.

%% Resumes from the point recorded (a restart, a new leader), or starts now: a rule never fires for the past.
start(S) ->
    Point = case ana_db:one("SELECT value FROM automation.mark WHERE name = $1", [?MARK]) of
        {ok, #{<<"value">> := V}} when is_integer(V) -> V;
        _ ->
            {ok, #{<<"m">> := M}} = ana_db:one("SELECT COALESCE(max(id), 0) AS m FROM master.change_log", []),
            save_point(M),
            M
    end,
    schedule(S#{active := true, point := Point, high := Point, missing := #{}, saved := Point,
                saved_at := erlang:monotonic_time(millisecond)}, 0).

%% No rule watches a master any more: the point is forgotten, so the next rule starts from its own moment.
stop(S) ->
    _ = ana_db:exec("DELETE FROM automation.mark WHERE name = $1", [?MARK]),
    S#{active := false, point := undefined, high := undefined, missing := #{}, saved := undefined}.

%% ---------------------------------------------------------------- reading

read(S = #{active := false}) -> S;
read(S = #{high := High, missing := Missing}) ->
    case leader() of
        false -> stop_local(S);
        true ->
            case ana_db:rows("SELECT * FROM automation.read_log($1, $2::bigint[], $3)", [High, maps:keys(Missing), ?BATCH]) of
                {ok, Rows} ->
                    Now = erlang:monotonic_time(millisecond),
                    {Deliver, Point2, High2, Missing2} = advance(S, [Id || #{<<"id">> := Id} <- Rows], Now, ?GAP_MS, ?BATCH),
                    Events = [R || R = #{<<"id">> := Id, <<"changes">> := C} <- Rows, is_map(C), lists:member(Id, Deliver)],
                    S2 = deliver(Events, Point2, S),
                    S3 = S2#{point := Point2, high := High2, missing := Missing2},
                    schedule(S3, case length(Rows) >= ?BATCH of true -> 0; false -> ?READ_MS end);
                {error, E} ->
                    logger:warning("watch log: not read: ~0p", [E]),
                    schedule(S, ?READ_MS * 5)
            end
    end.

%% A follower keeps nothing: the new leader resumes from the point recorded.
stop_local(S) -> S#{active := false, point := undefined, high := undefined, missing := #{}}.

%% The events some rule watches are claimed with the point, in one transaction; otherwise only the point, now and then.
deliver([], Point, S = #{saved := Saved, saved_at := At}) ->
    Now = erlang:monotonic_time(millisecond),
    case Point =/= Saved andalso Now - At >= ?SAVE_MS of
        true -> save_point(Point), S#{saved := Point, saved_at := Now};
        false -> S
    end;
deliver(Events, Point, S) ->
    R = ana_db:transaction(fun(C) ->
        N = ana_rules:claim_log(C, Events),
        {ok, _} = ana_db:rows(C, "INSERT INTO automation.mark (name, at, value) VALUES ($1, now(), $2) "
                                 "ON CONFLICT (name) DO UPDATE SET at = now(), value = EXCLUDED.value", [?MARK, Point]),
        {ok, N}
    end),
    case R of
        {ok, N} ->
            _ = N > 0 andalso ok =:= ana_events:publish_local(<<"rules">>, changed),
            S#{saved := Point, saved_at := erlang:monotonic_time(millisecond)};
        {error, E} ->
            %% nothing claimed, nothing recorded: the same rows come again (claims are unique)
            logger:warning("watch log: not claimed: ~0p", [E]),
            S
    end.

save_point(P) ->
    _ = ana_db:exec("INSERT INTO automation.mark (name, at, value) VALUES ($1, now(), $2) "
                    "ON CONFLICT (name) DO UPDATE SET at = now(), value = EXCLUDED.value", [?MARK, P]),
    ok.

%% Pure (eunit): from the ids read, what to deliver and where the point goes.
%%   - delivered: ids above the highest read, and the missing ones that came;
%%   - missing: holes between the ids read, kept until they come or ?GAP_MS passes;
%%   - point: one below the smallest missing id still open, else the highest read.
-spec advance(map(), [integer()], integer(), pos_integer(), pos_integer()) ->
    {[integer()], integer(), integer(), #{integer() => integer()}}.
advance(#{high := High, missing := Missing}, Ids, Now, GapMs, _Batch) ->
    New = lists:usort([I || I <- Ids, I > High]),
    Found = [I || I <- Ids, maps:is_key(I, Missing)],
    High2 = lists:max([High | New]),
    Holes = holes(High, New),
    M1 = maps:without(Found, Missing),
    M2 = lists:foldl(fun(I, M) -> M#{I => Now} end, M1, Holes),
    M3 = maps:filter(fun(_, Seen) -> Now - Seen < GapMs end, M2),
    Point = case maps:size(M3) of
        0 -> High2;
        _ -> lists:min(maps:keys(M3)) - 1
    end,
    {lists:usort(New ++ Found), Point, High2, M3}.

holes(_, []) -> [];
holes(From, [I | Rest]) -> lists:seq(From + 1, I - 1) ++ holes(I, Rest).

schedule(S = #{timer := undefined}, Ms) -> S#{timer := erlang:send_after(Ms, self(), read)};
schedule(S, _) -> S.

leader() ->
    case catch ana_scheduler:status() of
        #{leader := true} -> true;
        _ -> false
    end.
