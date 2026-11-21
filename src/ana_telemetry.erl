%% SPDX-FileCopyrightText: 2026 LE Devices
%% SPDX-License-Identifier: AGPL-3.0-or-later
%% Optional, consented telemetry for the vendor's support (spec 009, D13).
%%
%% Off by default. When an administrator turns it on, the leader sends once a day, through the connector
%% "telemetry" (spec 017: allowed hosts, credentials, breaker), only: an anonymous instance id, product and
%% platform versions, license state, health states and counts of executions and error codes in the last
%% 24 h. Never business data, names, messages or users. The screen shows exactly what is sent.
-module(ana_telemetry).
-behaviour(gen_server).

-export([start_link/0, status/0, set/2, send_now/1, payload/0]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2]).

-define(CONNECTOR, <<"telemetry">>).
-define(TICK_MS, 3600000).
-define(EVERY_S, 86400).

start_link() -> gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

%% ---------------------------------------------------------------- administration

-spec status() -> {ok, map()}.
status() ->
    {ok, Row} = ana_db:one("SELECT enabled, instance_id::text, changed_by, changed_at, last_sent_at, last_status "
                           "FROM ana_system.telemetry WHERE id = 1", []),
    Connector = case ana_connector:lookup(?CONNECTOR) of
        {ok, #{<<"active">> := true, <<"kind">> := <<"http_api">>}} -> <<"ready">>;
        {ok, #{}} -> <<"inactive">>;
        _ -> <<"missing">>
    end,
    {ok, Row#{<<"preview">> => payload(), <<"connector">> => Connector}}.

-spec set(boolean(), map()) -> {ok, map()}.
set(Enabled, #{username := Who}) when is_boolean(Enabled) ->
    {ok, _} = ana_db:exec("UPDATE ana_system.telemetry SET enabled = $1, changed_by = $2, changed_at = now() WHERE id = 1",
                          [Enabled, Who]),
    ana_admin:log(Who, <<"telemetry.set">>, <<"telemetry">>, null, #{enabled => Enabled}),
    status().

-spec send_now(map()) -> {ok, map()} | {error, binary()}.
send_now(#{username := _}) ->
    case enabled() of
        true -> send(), status();
        false -> {error, <<"ligue a telemetria antes de enviar">>}
    end.

%% ---------------------------------------------------------------- what is sent

-spec payload() -> map().
payload() ->
    {ok, #{<<"instance_id">> := Inst}} = ana_db:one("SELECT instance_id::text FROM ana_system.telemetry WHERE id = 1", []),
    {ok, #{<<"v">> := Pg}} = ana_db:one("SELECT current_setting('server_version') AS v", []),
    {ok, Counts} = ana_db:rows("SELECT status, count(*) AS n FROM ana_system.execution "
                               "WHERE started_at > now() - interval '24 hours' GROUP BY status ORDER BY status", []),
    {ok, Codes} = ana_db:rows("SELECT error->>'code' AS code, count(*) AS n FROM ana_system.execution "
                              "WHERE started_at > now() - interval '24 hours' AND status <> 'success' AND error ? 'code' "
                              "GROUP BY 1 ORDER BY 2 DESC, 1 LIMIT 10", []),
    L = ana_license:current(),
    Health = try maps:map(fun(_, V) -> maps:get(state, V, unknown) end, ana_health:state()) catch _:_ -> #{} end,
    {Up, _} = erlang:statistics(wall_clock),
    #{instance => Inst,
      product_version => ana_instance:product_version(),
      otp => list_to_binary(erlang:system_info(otp_release)),
      postgres => Pg,
      nodes => length(nodes()) + 1,
      license => #{state => maps:get(state, L), environment => maps:get(environment, L),
                   license_id => maps:get(license_id, L, null)},
      health => Health,
      executions_24h => maps:from_list([{S, N} || #{<<"status">> := S, <<"n">> := N} <- Counts]),
      error_codes_24h => maps:from_list([{C, N} || #{<<"code">> := C, <<"n">> := N} <- Codes]),
      uptime_s => Up div 1000}.

%% ---------------------------------------------------------------- server

init([]) ->
    erlang:send_after(60000, self(), tick),
    {ok, #{}}.

handle_call(_, _, S) -> {reply, ok, S}.
handle_cast(_, S) -> {noreply, S}.

handle_info(tick, S) ->
    _ = (catch maybe_send()),
    erlang:send_after(?TICK_MS, self(), tick),
    {noreply, S};
handle_info(_, S) -> {noreply, S}.

maybe_send() ->
    Leader = case catch ana_scheduler:status() of #{leader := true} -> true; _ -> false end,
    {ok, #{<<"due">> := Due}} = ana_db:one(
        "SELECT enabled AND (last_sent_at IS NULL OR last_sent_at < now() - make_interval(secs => $1)) AS due "
        "FROM ana_system.telemetry WHERE id = 1", [?EVERY_S]),
    _ = Leader andalso Due =:= true andalso send(),
    ok.

enabled() ->
    {ok, #{<<"enabled">> := E}} = ana_db:one("SELECT enabled FROM ana_system.telemetry WHERE id = 1", []),
    E =:= true.

send() ->
    P = payload(),
    Status = case ana_connector:http(?CONNECTOR, <<"POST">>, <<>>, #{json => P}, null) of
        {ok, #{<<"status">> := Code}} when Code >= 200, Code < 300 -> <<"enviado">>;
        {ok, #{<<"status">> := Code}} -> iolist_to_binary(io_lib:format("HTTP ~b", [Code]));
        {error, #{<<"code">> := C}} -> C;
        {error, _} -> <<"erro">>
    end,
    {ok, _} = ana_db:exec("UPDATE ana_system.telemetry SET last_sent_at = now(), last_status = $1, last_payload = $2::text::jsonb "
                          "WHERE id = 1", [Status, iolist_to_binary(json:encode(P))]),
    ok.
