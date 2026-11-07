%% Event bus of the core (spec 062, D2; constitution P20): what happens is told by message instead of
%% being asked again and again. Process groups of OTP (pg, scope ana_events): subscribers join a topic;
%% publish/2 reaches every member in the cluster when the Erlang distribution is on (pg spans nodes).
%% Facts written in the database come by NOTIFY "ana_wake" (sent only after COMMIT) through the
%% listener of each node, so they reach every node even without the distribution. Events only wake
%% things up: the database stays the truth (P4) and every subscriber also has a slower safety timer.
-module(ana_events).
-export([start_link/0, subscribe/1, unsubscribe/1, publish/2, publish_local/2, on_notify/2]).

-define(SCOPE, ana_events).

start_link() -> pg:start_link(?SCOPE).

-spec subscribe(term()) -> ok.
subscribe(Topic) -> pg:join(?SCOPE, Topic, self()).

-spec unsubscribe(term()) -> ok | not_joined.
unsubscribe(Topic) -> pg:leave(?SCOPE, Topic, self()).

%% Every subscriber in the cluster (connected nodes).
-spec publish(term(), term()) -> ok.
publish(Topic, Msg) -> send(pg:get_members(?SCOPE, Topic), Topic, Msg).

%% Subscribers of this node only (the other nodes get the same fact by their own NOTIFY).
-spec publish_local(term(), term()) -> ok.
publish_local(Topic, Msg) -> send(pg:get_local_members(?SCOPE, Topic), Topic, Msg).

send(Pids, Topic, Msg) ->
    _ = [P ! {ana_event, Topic, Msg} || P <- Pids],
    ok.

%% ana_listener, channel "ana_wake": the payload is the topic ("integration", ...); `all` after a
%% reconnection (notifications may have been missed) wakes every known topic.
on_notify(_Channel, all) ->
    _ = [publish_local(T, all) || T <- [<<"integration">>, <<"notices">>]],
    ok;
on_notify(_Channel, Topic) when is_binary(Topic) ->
    publish_local(Topic, wake).
