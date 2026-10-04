%% Pool of prewarmed Python processes (RNF-002-07, P12).
%%
%% Keeps N processes that already loaded the runtime and sent "ready". Each one
%% is handed to a single execution (isolation) and replaced in the background.
-module(ana_py_pool).
-behaviour(gen_server).

-export([start_link/0, checkout/0, status/0]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2]).

-record(st, {
    target :: non_neg_integer(),
    ready = [] :: [{port(), integer()}],
    warming = 0 :: non_neg_integer()
}).

start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

-spec checkout() -> {ok, port(), integer()} | empty.
checkout() ->
    gen_server:call(?MODULE, {checkout, self()}, 5000).

status() ->
    gen_server:call(?MODULE, status).

init([]) ->
    process_flag(trap_exit, true),
    self() ! refill,
    {ok, #st{target = max(0, ana_config:integer("ANA_PY_PREWARM", 4))}}.

handle_call({checkout, Client}, From, St = #st{ready = [{Port, Pid} | Rest]}) ->
    %% Transfers port ownership to the client: messages now go to it.
    case catch erlang:port_connect(Port, Client) of
        true ->
            unlink(Port),
            self() ! refill,
            {reply, {ok, Port, Pid}, St#st{ready = Rest}};
        _ ->
            ana_py:kill({Port, Pid}),
            self() ! refill,
            handle_call({checkout, Client}, From, St#st{ready = Rest})
    end;
handle_call({checkout, _}, _From, St) ->
    self() ! refill,
    {reply, empty, St};
handle_call(status, _From, St) ->
    {reply, #{ready => length(St#st.ready), target => St#st.target, warming => St#st.warming}, St}.

handle_cast(_, St) -> {noreply, St}.

handle_info(refill, St = #st{target = T, ready = R, warming = W}) when length(R) + W < T ->
    Pool = self(),
    %% Opens outside the pool process so it is never blocked (~30-80 ms each).
    _ = spawn_link(fun() ->
        case ana_py:open() of
            {ok, Port, Pid} ->
                true = erlang:port_connect(Port, Pool),
                unlink(Port),
                Pool ! {warmed, Port, Pid};
            {error, Reason} ->
                Pool ! {failed, Reason}
        end
    end),
    handle_info(refill, St#st{warming = W + 1});
handle_info(refill, St) ->
    {noreply, St};
handle_info({warmed, Port, Pid}, St) ->
    link(Port),
    {noreply, St#st{ready = [{Port, Pid} | St#st.ready], warming = St#st.warming - 1}};
handle_info({failed, Reason}, St) ->
    logger:error("could not warm a Python process: ~0p", [Reason]),
    erlang:send_after(5000, self(), refill),
    {noreply, St#st{warming = St#st.warming - 1}};
handle_info({Port, {exit_status, _}}, St) ->
    self() ! refill,
    {noreply, St#st{ready = lists:keydelete(Port, 1, St#st.ready)}};
handle_info({'EXIT', _, normal}, St) ->
    {noreply, St};
handle_info({'EXIT', Port, _}, St) when is_port(Port) ->
    self() ! refill,
    {noreply, St#st{ready = lists:keydelete(Port, 1, St#st.ready)}};
handle_info({'EXIT', _Warmer, Reason}, St) ->
    handle_info({failed, Reason}, St);
handle_info(_, St) ->
    {noreply, St}.

terminate(_, St) ->
    _ = [ana_py:kill(P) || P <- St#st.ready],
    ok.
