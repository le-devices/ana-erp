%% Delivery worker of one connector (spec 062, D4; spec 017): claims only this connector's messages, with
%% its own concurrency, so a slow or stuck connector never holds the others back. Woken by
%% ana_integration (event, timer or safety tick); stops after a while without work.
-module(ana_connector_worker).
-behaviour(gen_server).
-export([start_link/1, poke/1]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2]).

-define(MAX_RUNNING, 4).
-define(BATCH, 10).
-define(IDLE_MS, 300000).

start_link(Connector) -> gen_server:start_link(?MODULE, Connector, []).

poke(Pid) -> gen_server:cast(Pid, poke).

init(Connector) ->
    {ok, #{connector => Connector, running => 0}, ?IDLE_MS}.

handle_call(_, _, S) -> {reply, ok, S, ?IDLE_MS}.

handle_cast(poke, S) -> {noreply, claim(S), ?IDLE_MS};
handle_cast(_, S) -> {noreply, S, ?IDLE_MS}.

handle_info({done, More}, S = #{running := N}) ->
    S1 = S#{running := max(0, N - 1)},
    {noreply, case More of true -> claim(S1); false -> S1 end, ?IDLE_MS};
handle_info(timeout, S = #{running := 0}) -> {stop, normal, S};
handle_info(_, S) -> {noreply, S, ?IDLE_MS}.

claim(S = #{running := Running}) when Running >= ?MAX_RUNNING -> S;
claim(S = #{connector := C, running := Running}) ->
    case ana_ha:refusing() of
        true -> S;                                       % draining (spec 023): take nothing new
        false ->
            Free = ?MAX_RUNNING - Running,
            Out = ana_integration:claim(outbox, C, min(Free, ?BATCH)),
            In = ana_integration:claim(inbox, C, min(Free - length(Out), ?BATCH)),
            Got = [{outbox, M} || M <- Out] ++ [{inbox, M} || M <- In],
            Full = length(Got) =:= Free,                 % there may be more: claim again when one finishes
            Self = self(),
            _ = [spawn(fun() ->
                         try ana_integration:run(Kind, M)
                         catch Cl:R:St -> logger:error("integration ~p failed: ~0p:~0p ~0p", [Kind, Cl, R, St])
                         after Self ! {done, Full}
                         end
                     end) || {Kind, M} <- Got],
            S#{running := Running + length(Got)}
    end.
