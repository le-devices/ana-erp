%% Component health and incidents (spec 019, RF-019-01, RF-019-08).
%%
%% Every 10 s each component is checked; only state changes are written
%% (health_event, P15). Red opens an incident (and calls ANA_ALERT_WEBHOOK when
%% set); green closes it. Every 5 min a metrics sample is stored for charts.
-module(ana_health).
-behaviour(gen_server).

-export([start_link/0, state/0, history/1, incidents/1, check_now/0]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2]).

-define(EVERY_MS, 10000).
-define(SAMPLE_EVERY, 30).                    % ticks (5 min)

start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

state() -> gen_server:call(?MODULE, state, 5000).
check_now() -> gen_server:call(?MODULE, check, 15000).

history(Hours) ->
    ana_db:rows("SELECT component, state, message, node, at FROM ana_system.health_event "
                "WHERE at > now() - make_interval(hours => $1) ORDER BY at DESC LIMIT 500", [Hours]).

incidents(Open) ->
    ana_db:rows("SELECT id, component, node, message, opened_at, closed_at, "
                "  (extract(epoch FROM COALESCE(closed_at, now()) - opened_at))::int AS seconds "
                "FROM ana_system.incident WHERE ($1 = false OR closed_at IS NULL) "
                "ORDER BY opened_at DESC LIMIT 200", [Open]).

init([]) ->
    erlang:send_after(3000, self(), tick),
    {ok, #{states => #{}, ticks => 0, pending => []}}.

handle_call(state, _From, S = #{states := St}) -> {reply, St, S};
handle_call(check, _From, S) ->
    S2 = check(S),
    {reply, maps:get(states, S2), S2}.

handle_cast(_, S) -> {noreply, S}.

handle_info(tick, S = #{ticks := T}) ->
    erlang:send_after(?EVERY_MS, self(), tick),
    S2 = try check(S) catch C:R:St -> logger:warning("health check failed: ~0p:~0p ~0p", [C, R, St]), S end,
    _ = T rem ?SAMPLE_EVERY =:= 0 andalso is_pid(spawn(fun sample/0)),
    {noreply, S2#{ticks := T + 1}};
handle_info(_, S) -> {noreply, S}.

check(S = #{states := Old, pending := Pending}) ->
    New = maps:from_list([{C, timed(F)} || {C, F} <- components()]),
    Node = ana_config:node_id(),
    Ops = lists:append([transition(C, maps:get(state, maps:get(C, Old, #{state => unknown})), V, Node)
                        || {C, V} <- maps:to_list(New),
                           maps:get(state, V) =/= maps:get(state, maps:get(C, Old, #{state => unknown}))]),
    %% Writes wait in memory, in order, while the database itself is the one down.
    S#{states := New, pending := flush(Pending ++ Ops)}.

flush([]) -> [];
flush([Op | Rest] = All) ->
    case catch write(Op) of
        ok -> flush(Rest);
        _ when length(All) > 1000 -> logger:warning("health: dropping ~b pending writes", [length(All) - 1000]),
                                     lists:sublist(All, 1000);
        _ -> All
    end.

write({event, Component, State, Msg, Node, At}) ->
    ok_or_error(ana_db:exec("INSERT INTO ana_system.health_event (component, state, message, node, at) "
                            "VALUES ($1, $2, $3, $4, to_timestamp($5))", [Component, State, Msg, Node, At]));
write({open, Component, Msg, Node, At}) ->
    ok_or_error(ana_db:exec("INSERT INTO ana_system.incident (component, node, message, opened_at) "
                            "SELECT $1, $2, $3, to_timestamp($4) WHERE NOT EXISTS (SELECT 1 FROM ana_system.incident "
                            "WHERE component = $1 AND node = $2 AND closed_at IS NULL)", [Component, Node, Msg, At]));
write({close, Component, Node, At}) ->
    ok_or_error(ana_db:exec("UPDATE ana_system.incident SET closed_at = to_timestamp($3) WHERE component = $1 "
                            "AND node = $2 AND closed_at IS NULL", [Component, Node, At])).

ok_or_error({ok, _}) -> ok;
ok_or_error(E) -> E.

timed(F) ->
    T0 = erlang:monotonic_time(microsecond),
    R = try F() catch _:E -> {red, unicode:characters_to_binary(io_lib:format("falha na verificação: ~0p", [E]))} end,
    {State, Msg} = R,
    #{state => State, message => Msg, latency_ms => (erlang:monotonic_time(microsecond) - T0) / 1000,
      at => erlang:system_time(second)}.

components() ->
    [{<<"database">>, fun database/0},
     {<<"pool_core">>, fun() -> pool(ana_db) end},
     {<<"pool_programs">>, fun() -> pool(ana_db_exec) end},
     {<<"python">>, fun python/0},
     {<<"scheduler">>, fun scheduler/0},
     {<<"access_log">>, fun access_log/0},
     {<<"remote_systems">>, fun breakers/0}].

database() ->
    T0 = erlang:monotonic_time(millisecond),
    case catch ana_db:one("SELECT 1 AS ok", []) of
        {ok, #{<<"ok">> := 1}} ->
            Ms = erlang:monotonic_time(millisecond) - T0,
            if Ms > 1000 -> {yellow, fmt("banco lento: ~b ms para responder", [Ms])};
               true -> {green, fmt("responde em ~b ms", [Ms])}
            end;
        _ -> {red, <<"banco de dados não responde"/utf8>>}
    end.

pool(P) ->
    case catch ana_db:status(P) of
        #{free := F, busy := B, waiting := W, size := Size} ->
            if F + B =:= 0 -> {red, <<"nenhuma conexão aberta"/utf8>>};
               W > 0 -> {yellow, fmt("~b esperando conexão (~b em uso de ~b)", [W, B, Size])};
               true -> {green, fmt("~b em uso, ~b livres", [B, F])}
            end;
        _ -> {red, <<"pool indisponível"/utf8>>}
    end.

python() ->
    case catch ana_py_pool:status() of
        #{ready := R, warming := W, target := T} ->
            if T > 0, R + W =:= 0 -> {red, <<"nenhum processo Python disponível"/utf8>>};
               T > 0, R =:= 0 -> {yellow, <<"processos Python aquecendo (sob carga)"/utf8>>};
               true -> {green, fmt("~b pronto(s)", [R])}
            end;
        _ -> {red, <<"pool de Python indisponível"/utf8>>}
    end.

%% Somebody in the cluster must lead the scheduler (advisory lock held).
scheduler() ->
    case catch ana_db:one("SELECT count(*) AS n FROM pg_locks WHERE locktype = 'advisory' AND objid = 7741018 "
                          "AND granted", []) of
        {ok, #{<<"n">> := N}} when N > 0 -> {green, <<"há um líder no cluster"/utf8>>};
        {ok, _} -> {yellow, <<"nenhum nó lidera o agendamento agora"/utf8>>};
        _ -> {red, <<"não foi possível verificar"/utf8>>}
    end.

access_log() ->
    case catch ana_access_log:dropped() of
        0 -> {green, <<"sem descartes"/utf8>>};
        N when is_integer(N) -> {yellow, fmt("~b registro(s) de acesso descartado(s) por sobrecarga", [N])};
        _ -> {yellow, <<"registro de acessos indisponível"/utf8>>}
    end.

breakers() ->
    Open = [K || {K, _, _, _} = E <- (catch ets:tab2list(ana_breakers)), is_tuple(E), element(2, E) =/= closed],
    case Open of
        [] -> {green, <<"todos disponíveis"/utf8>>};
        _ -> {yellow, fmt("disjuntor aberto: ~ts", [lists:join(", ", [name(K) || K <- Open])])}
    end.

name({remote, S}) -> S;
name(K) -> io_lib:format("~0p", [K]).

transition(Component, Before, #{state := State, message := Msg, at := At}, Node) ->
    S = atom_to_binary(State),
    logger:notice("health: ~ts → ~ts (~ts)", [Component, S, Msg]),
    Event = {event, Component, S, Msg, Node, At},
    case State of
        red ->
            alert(<<"open">>, Component, Node, Msg),
            [Event, {open, Component, Msg, Node, At}];
        _ when Before =:= red ->
            alert(<<"closed">>, Component, Node, Msg),
            [Event, {close, Component, Node, At}];
        _ ->
            [Event]
    end.

%% Optional webhook (ANA_ALERT_WEBHOOK): JSON POST, never blocks the checks.
alert(Event, Component, Node, Msg) ->
    case ana_config:text("ANA_ALERT_WEBHOOK", "") of
        "" -> ok;
        Url ->
            Body = iolist_to_binary(json:encode(#{event => Event, component => Component, node => Node,
                                                  message => Msg, at => erlang:system_time(second)})),
            _ = spawn(fun() -> catch httpc:request(post, {Url, [], "application/json", Body},
                                                   [{timeout, 5000}], []) end),
            ok
    end.

sample() ->
    _ = ana_db:exec("INSERT INTO ana_system.metric_sample (node, metrics) VALUES ($1, $2) ON CONFLICT DO NOTHING",
                    [ana_config:node_id(), ana_metrics:snapshot()]),
    ok.

fmt(F, A) -> unicode:characters_to_binary(io_lib:format(F, A)).
