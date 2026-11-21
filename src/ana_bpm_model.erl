%% SPDX-FileCopyrightText: 2026 André Luis Pereira dos Santos
%% SPDX-License-Identifier: AGPL-3.0-or-later
%% Navigation in a BPM model (spec 039, RF-039-11) — pure functions, no database.
%%
%% Model (canonical JSON, BPMN meaning): nodes [{id, type, name, lane, props}], edges [{id, from, to,
%% name, condition: [rules], default: bool, on: "error" | "timeout"}]. Types: start, end, task_human,
%% task_approval, task_auto, task_send, task_rule, timer, event_fact, subprocess, gw_xor, gw_and, gw_or,
%% annotation. Conditions are the restricted rules of the esteiras (never code): every rule must hold.
-module(ana_bpm_model).

-export([node/2, outgoing/2, incoming/2, next/4, is_join/2, kind/1, rule_assign/2]).

-spec node(map(), binary()) -> map() | undefined.
node(#{<<"nodes">> := Nodes}, Id) ->
    case [N || N = #{<<"id">> := I} <- Nodes, I =:= Id] of
        [N | _] -> N;
        [] -> undefined
    end.

-spec outgoing(map(), binary()) -> [map()].
outgoing(#{<<"edges">> := Edges}, Id) -> [E || E = #{<<"from">> := F} <- Edges, F =:= Id].

-spec incoming(map(), binary()) -> [map()].
incoming(#{<<"edges">> := Edges}, Id) -> [E || E = #{<<"to">> := T} <- Edges, T =:= Id].

%% A gateway with two or more incoming flows waits for the branches that can still reach it.
-spec is_join(map(), binary()) -> boolean().
is_join(Model, Id) ->
    case node(Model, Id) of
        #{<<"type">> := <<"gw_", _/binary>>} -> length(incoming(Model, Id)) >= 2;
        _ -> false
    end.

%% Task kind (bpm.task.kind) of a node type; undefined for nodes that are not work.
-spec kind(binary()) -> binary() | undefined.
kind(<<"task_human">>) -> <<"human">>;
kind(<<"task_approval">>) -> <<"approval">>;
kind(<<"task_auto">>) -> <<"auto">>;
kind(<<"task_send">>) -> <<"send">>;
kind(<<"task_rule">>) -> <<"rule">>;
kind(<<"timer">>) -> <<"timer">>;
kind(<<"event_fact">>) -> <<"fact">>;
kind(<<"subprocess">>) -> <<"subprocess">>;
kind(_) -> undefined.

%% Where a token goes after Node finished with Outcome (done | error | timeout | approved | rejected…).
%% {ok, [NodeId]} or {error, Message} when no path applies (the case stops with the reason).
-spec next(map(), binary(), map(), binary()) -> {ok, [binary()]} | {error, binary()}.
next(Model, Node, Data, Outcome) ->
    Out = outgoing(Model, Node),
    Special = [E || E <- Out, maps:get(<<"on">>, E, null) =:= Outcome],
    Normal = [E || E <- Out, not is_binary(maps:get(<<"on">>, E, null))],
    Type = case node(Model, Node) of #{<<"type">> := T} -> T; _ -> <<>> end,
    case {Outcome, Special} of
        {_, [_ | _]} -> {ok, targets(Special)};
        {<<"error">>, []} -> {error, <<"erro sem caminho de erro no modelo">>};
        {<<"timeout">>, []} -> {ok, []};                         % escalation without a path: the task stays
        _ -> route(Type, Normal, Data)
    end.

route(_, [], _) -> {ok, []};
route(<<"gw_xor">>, Edges, Data) ->
    {Defaults, Conditional} = lists:partition(fun is_default/1, Edges),
    case [E || E <- Conditional, holds(E, Data)] of
        [E | _] -> {ok, targets([E])};
        [] when Defaults =/= [] -> {ok, targets([hd(Defaults)])};
        [] -> {error, <<"nenhuma condição do gateway foi atendida e não há caminho padrão"/utf8>>}
    end;
route(<<"gw_and">>, Edges, _) -> {ok, targets(Edges)};
route(_, Edges, Data) ->
    %% Inclusive gateway and plain elements: every flow whose condition holds (default when none).
    {Defaults, Others} = lists:partition(fun is_default/1, Edges),
    case [E || E <- Others, holds(E, Data)] of
        [] when Defaults =/= [] -> {ok, targets(Defaults)};
        [] -> {error, <<"nenhum caminho de saída atende às condições"/utf8>>};
        Taken -> {ok, targets(Taken)}
    end.

is_default(E) -> maps:get(<<"default">>, E, false) =:= true.

holds(E, Data) ->
    case maps:get(<<"condition">>, E, []) of
        [] -> true;
        null -> true;
        Rules -> ana_flows:condition(Rules, Data)
    end.

targets(Edges) -> [T || #{<<"to">> := T} <- Edges].

%% Rule task (RF-039-04): [{"var", "value", "when": [rules]}] → the assignments whose rules hold.
-spec rule_assign(list(), map()) -> map().
rule_assign(Assign, Data) when is_list(Assign) ->
    lists:foldl(fun(#{<<"var">> := V} = A, Acc) ->
                        case ana_flows:condition(maps:get(<<"when">>, A, []), Data) of
                            true -> Acc#{V => ana_flows:render(maps:get(<<"value">>, A, null), Data)};
                            false -> Acc
                        end;
                   (_, Acc) -> Acc
                end, #{}, Assign);
rule_assign(_, _) -> #{}.
