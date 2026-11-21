%% SPDX-FileCopyrightText: 2026 André Luis Pereira dos Santos
%% SPDX-License-Identifier: AGPL-3.0-or-later
%% Analytics layer (spec 007): periodic and on-demand refresh.
-module(ana_analytics).
-behaviour(gen_server).

-export([start_link/0, refresh/0, refresh/2, status/0]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2]).

start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

%% RF-007-02/03; RNF-007-02: concurrency handled in the database (advisory lock).
%% P14: always recorded with an owner (the caller, or the robot "system").
-spec refresh() -> {ok, binary()} | {error, term()}.
refresh() ->
    refresh(ana_task:system_user(), <<"internal">>).

-spec refresh(map(), binary()) -> {ok, binary()} | {error, term()}.
refresh(Owner, Origin) ->
    R = ana_task:run(<<"analytics.refresh">>, Owner, Origin, fun() ->
        %% RF-025-01: periodic runs skip when sources did not change; asked by a person, always recalculates.
        Force = Origin =/= <<"internal">>,
        case ana_db:one("SELECT analytics.refresh($1) AS r", [Force]) of
            %% P15/spec 063: a periodic run that found nothing to do leaves no record.
            {ok, #{<<"r">> := Res}} when not Force, Res =/= <<"refreshed">> -> {skip, Res};
            {ok, #{<<"r">> := Res}} -> {ok, Res};
            {error, E} -> {error, E}
        end
    end),
    gen_server:cast(?MODULE, {result, R}),
    R.

%% RF-007-05
status() ->
    gen_server:call(?MODULE, status, 2000).

init([]) ->
    Columnar = case ana_db:one(
        "SELECT EXISTS (SELECT 1 FROM pg_class c JOIN pg_am am ON am.oid = c.relam "
        "JOIN pg_namespace n ON n.oid = c.relnamespace "
        "WHERE n.nspname = 'analytics' AND c.relname = 'sales_fact' "
        "AND am.amname = 'columnar') AS columnar", []) of
        {ok, #{<<"columnar">> := B}} -> B;
        _ -> false
    end,
    erlang:send_after(5000, self(), tick),
    {ok, #{columnar => Columnar, last => null, last_result => null}}.

handle_call(status, _, S = #{columnar := C, last := L, last_result := R}) ->
    {reply, #{columnar => C, last_refresh => L, last_result => R}, S}.

handle_cast({result, {ok, R}}, S) ->
    Now = list_to_binary(calendar:system_time_to_rfc3339(erlang:system_time(second), [{offset, "Z"}])),
    {noreply, S#{last => Now, last_result => R}};
handle_cast({result, {error, Error}}, S) ->
    logger:warning("analytics refresh failed: ~0p", [Error]),
    {noreply, S#{last_result => <<"failed">>}}.

handle_info(tick, S) ->
    _ = spawn(fun() -> catch refresh() end),
    erlang:send_after(ana_settings:get(analytics_interval_s) * 1000, self(), tick),
    {noreply, S};
handle_info(_, S) ->
    {noreply, S}.
