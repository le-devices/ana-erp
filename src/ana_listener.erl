%% Cross-node cache invalidation via PostgreSQL LISTEN/NOTIFY.
%%
%% Channels and handlers: ana_program → ana_program, ana_setting → ana_settings,
%% ana_access → ana_access, ana_wake → ana_events (spec 062), ana_value → ana_values (spec 065). On (re)connection every handler gets `all`, since
%% notifications may have been missed while disconnected.
-module(ana_listener).
-behaviour(gen_server).
-export([start_link/0]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2]).

-define(CHANNELS, [{<<"ana_program">>, ana_program},
                   {<<"ana_setting">>, ana_settings},
                   {<<"ana_access">>, ana_access},
                   {<<"ana_flow">>, ana_bpm}, {<<"ana_bpm">>, ana_bpm},
                   {<<"ana_api">>, ana_api}, {<<"ana_license">>, ana_license},
                   {<<"ana_extension">>, ana_extensions},
                   {<<"ana_value">>, ana_values},                  % spec 065: company values
                   {<<"ana_wake">>, ana_events}]).                % spec 062: events instead of polling

start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

init([]) ->
    process_flag(trap_exit, true),
    self() ! connect,
    {ok, #{conn => undefined}}.

handle_call(_, _, S) -> {reply, ok, S}.
handle_cast(_, S) -> {noreply, S}.

handle_info(connect, S) ->
    case ana_db:connect((ana_config:db())#{async => self()}) of
        {ok, C} ->
            _ = [{ok, [], []} = epgsql:squery(C, ["LISTEN ", Ch]) || {Ch, _} <- ?CHANNELS],
            _ = [dispatch(Ch, all) || {Ch, _} <- ?CHANNELS],
            {noreply, S#{conn => C}};
        {error, Reason} ->
            logger:warning("LISTEN unavailable: ~0p", [Reason]),
            erlang:send_after(5000, self(), connect),
            {noreply, S}
    end;
handle_info({epgsql, _C, {notification, Channel, _Pid, Payload}}, S) ->
    dispatch(Channel, Payload),
    {noreply, S};
handle_info({'EXIT', C, _}, S = #{conn := C}) ->
    erlang:send_after(1000, self(), connect),
    {noreply, S#{conn => undefined}};
handle_info(_, S) ->
    {noreply, S}.

dispatch(Channel, Payload) ->
    case lists:keyfind(Channel, 1, ?CHANNELS) of
        {_, Mod} ->
            try Mod:on_notify(Channel, Payload)
            catch C:R -> logger:error("notify handler ~s failed: ~0p:~0p", [Mod, C, R])
            end;
        false -> ok
    end.
