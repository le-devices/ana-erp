%% SPDX-FileCopyrightText: 2026 André Luis Pereira dos Santos
%% SPDX-License-Identifier: AGPL-3.0-or-later
%% Technical parameters (spec 077, T-077-04, D9; plan §2.2): the catalog seen by a person — what each parameter is,
%% when to change it, when it takes effect, its risk and scopes, the value in use and where it came from —, the
%% versions with reasons, temporary changes that go back by themselves, export, import and comparison between
%% environments. Values are kept by ana_settings (one source); this process only times the temporary changes:
%% a timer set exactly for the next expiry (nothing is polled while none is pending, P15), re-armed whenever a
%% parameter changes on any node.
-module(ana_params).
-behaviour(gen_server).

-export([start_link/0, changed/0, list/1, versions/1, restore/3, export/0, compare/1, import/3, set_risk/3]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2]).

start_link() -> gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

%% A parameter changed (here or, by NOTIFY, on another node): look again for the next expiry.
-spec changed() -> ok.
changed() -> gen_server:cast(?MODULE, arm).

init([]) ->
    self() ! arm,
    {ok, #{timer => undefined}}.

handle_call(_, _From, S) -> {reply, {error, unknown}, S}.

handle_cast(arm, S) -> {noreply, arm(S)}.

handle_info(arm, S) -> {noreply, arm(S)};
handle_info(expire, S) ->
    _ = (catch expire()),
    {noreply, arm(S#{timer := undefined})};
handle_info(_, S) -> {noreply, S}.

arm(S = #{timer := T}) ->
    _ = case T of undefined -> ok; _ -> erlang:cancel_timer(T) end,
    case catch ana_db:one("SELECT GREATEST(0, (extract(epoch FROM min(until) - now()) * 1000)::bigint) AS ms "
                          "FROM technical.parameter_version WHERE until IS NOT NULL AND reverted_at IS NULL", []) of
        {ok, #{<<"ms">> := Ms}} when is_integer(Ms) -> S#{timer := erlang:send_after(min(Ms + 50, 86400000), self(), expire)};
        _ -> S#{timer := undefined}
    end.

%% Each expired temporary change goes back to the value before it — once, whichever node gets there first.
expire() ->
    {ok, Due} = ana_db:rows("UPDATE technical.parameter_version SET reverted_at = now() "
                            "WHERE until IS NOT NULL AND reverted_at IS NULL AND until <= now() "
                            "RETURNING id, key, scope, node, before, set_by", []),
    _ = [ana_settings:set(K, decode(B), #{username => <<"system">>},
                      #{scope => binary_to_atom(Sc), node => N, kind => expired,
                        reason => <<"volta automática da mudança temporária "/utf8, (integer_to_binary(Id))/binary,
                                    " (de "/utf8, By/binary, ")">>})
     || #{<<"id">> := Id, <<"key">> := K, <<"scope">> := Sc, <<"node">> := N, <<"before">> := B, <<"set_by">> := By} <- Due],
    ok.

%% ------------------------------------------------------------------ what the screen shows
%% Every parameter with the value in use on this node and where it came from; changed ones first (D9); the server's.
-spec list(map()) -> {ok, map()}.
list(_User) ->
    {ok, Meta} = ana_db:rows("SELECT key, label, when_to_change, applies, risk, company_risk, area, scopes, sequence "
                             "FROM technical.parameter", []),
    ByKey = maps:from_list([{K, M} || M = #{<<"key">> := K} <- Meta]),
    {ok, Last} = ana_db:rows("SELECT DISTINCT ON (key) key, reason, set_by, set_at, until, reverted_at "
                             "FROM technical.parameter_version ORDER BY key, id DESC", []),
    LastBy = maps:from_list([{K, L} || L = #{<<"key">> := K} <- Last]),
    {ok, Nodes} = ana_db:rows("SELECT key, node, value FROM technical.parameter_node ORDER BY key, node", []),
    Items = [begin
                 KB = atom_to_binary(K),
                 M = maps:get(KB, ByKey, #{}),
                 Origin = ana_settings:origin(K),
                 L = maps:get(KB, LastBy, #{}),
                 Temporary = maps:get(<<"until">>, L, null) =/= null andalso maps:get(<<"reverted_at">>, L, null) =:= null,
                 #{key => KB, label => maps:get(<<"label">>, M, Desc), when_to_change => maps:get(<<"when_to_change">>, M, null),
                   applies => maps:get(<<"applies">>, M, <<"now">>), area => maps:get(<<"area">>, M, <<"outros">>),
                   risk => ana_settings:risk_of(KB), scopes => maps:get(<<"scopes">>, M, [<<"installation">>]),
                   type => T, min => Min, max => Max, default => ana_config:integer(Env, D), value => ana_settings:get(K),
                   origin => Origin, changed => Origin =:= installation orelse Origin =:= node,
                   env => list_to_binary(Env), last_change => L, temporary => Temporary,
                   nodes => [#{node => N, value => V} || #{<<"key">> := NK, <<"node">> := N, <<"value">> := V} <- Nodes, NK =:= KB],
                   sequence => maps:get(<<"sequence">>, M, 9999)}
             end || {K, T, Min, Max, Env, D, Desc} <- ana_settings:definitions()],
    Sorted = lists:sort(fun(A, B) -> {not maps:get(changed, A), maps:get(sequence, A)} =< {not maps:get(changed, B), maps:get(sequence, B)} end,
                        Items),
    {ok, Server} = ana_db:rows("SELECT env, label, secret FROM technical.server_parameter ORDER BY env", []),
    {ok, #{node => ana_config:node_id(), parameters => Sorted,
           server => [server_item(S) || S <- Server]}}.

server_item(#{<<"env">> := E, <<"label">> := L, <<"secret">> := Secret}) ->
    V = os:getenv(binary_to_list(E)),
    #{env => E, label => L, secret => Secret,
      value => case {Secret, V} of {_, false} -> null; {true, _} -> <<"(definido)">>; {false, _} -> unicode:characters_to_binary(V) end,
      defined => V =/= false,
      how => <<"no arquivo de configuração do servidor (variável "/utf8, E/binary,
               "), aplicado ao reiniciar o nó pelo ana-ctl"/utf8>>}.

-spec versions(binary()) -> {ok, [map()]}.
versions(Key) ->
    {ok, Rows} = ana_db:rows("SELECT id, key, scope, node, before, after, reason, kind, set_by, set_at, until, reverted_at "
                             "FROM technical.parameter_version WHERE key = $1 ORDER BY id DESC LIMIT 200", [Key]),
    {ok, [R#{<<"before">> => decode(B), <<"after">> => decode(A)} || R = #{<<"before">> := B, <<"after">> := A} <- Rows]}.

%% Back to the value a version set (a new change, with its own reason: the history only grows).
-spec restore(integer(), map(), binary()) -> ok | {error, term()}.
restore(Id, User, Reason) ->
    case ana_db:one("SELECT key, scope, node, after FROM technical.parameter_version WHERE id = $1", [Id]) of
        {ok, #{<<"key">> := K, <<"scope">> := Sc, <<"node">> := N, <<"after">> := A}} ->
            ana_settings:set(K, decode(A), User, #{scope => binary_to_atom(Sc), node => N, kind => restore,
                                                   reason => Reason});
        _ -> {error, not_found}
    end.

%% A readable file for the partner to review and for another environment to compare (D9).
-spec export() -> {ok, map()}.
export() ->
    {ok, #{format => <<"ana.parameters/1">>, instance => list_to_binary(ana_config:text("ANA_INSTANCE", "")),
           node => ana_config:node_id(), exported_at => calendar:system_time_to_rfc3339(erlang:system_time(second)),
           parameters => [#{key => atom_to_binary(K), value => ana_settings:get(K), origin => ana_settings:origin(K)}
                          || {K, _, _, _, _, _, _} <- ana_settings:definitions()]}}.

%% The other environment's export against this one: only what differs (CA-077-06).
-spec compare(map()) -> {ok, [map()]} | {error, binary()}.
compare(#{<<"format">> := <<"ana.parameters/1">>, <<"parameters">> := Theirs}) when is_list(Theirs) ->
    Mine = maps:from_list([{atom_to_binary(K), ana_settings:get(K)} || {K, _, _, _, _, _, _} <- ana_settings:definitions()]),
    {ok, [#{key => K, here => maps:get(K, Mine), there => V, risk => ana_settings:risk_of(K)}
          || #{<<"key">> := K, <<"value">> := V} <- Theirs, maps:is_key(K, Mine), maps:get(K, Mine) =/= V]};
compare(_) -> {error, <<"arquivo de parâmetros inválido (exporte pela Central técnica)"/utf8>>}.

%% Applies the parameters of a file through the parameter action — each with the ceremony of its risk.
-spec import(map(), map(), binary()) -> {ok, map()} | {error, binary()}.
import(File, User, Reason) ->
    case compare(File) of
        {error, _} = E -> E;
        {ok, Diff} ->
            Results = [{K, ana_tech:run(<<"parameter.set">>, #{<<"key">> => K, <<"value">> => V, <<"reason">> => Reason},
                                        User, #{confirmed => true, origin => <<"import">>})}
                       || #{key := K, there := V} <- Diff],
            {ok, #{applied => [K || {K, {ok, _}} <- Results],
                   pending => [K || {K, {pending, _}} <- Results],
                   refused => [#{key => K, error => M} || {K, {error, _, M}} <- Results]}}
    end.

%% The company makes a parameter stricter (never below the product's minimum).
-spec set_risk(binary(), binary(), map()) -> ok | {error, not_found | binary()}.
set_risk(Key, Risk, #{username := Who}) ->
    Order = [<<"low">>, <<"medium">>, <<"high">>],
    I = fun(X) -> length(lists:takewhile(fun(Y) -> Y =/= X end, Order)) end,
    case ana_db:one("SELECT risk FROM technical.parameter WHERE key = $1", [Key]) of
        {ok, #{<<"risk">> := Min}} ->
            case lists:member(Risk, Order) andalso I(Risk) >= I(Min) of
                false -> {error, <<"a empresa só torna o parâmetro mais rígido: o mínimo do produto é "/utf8, Min/binary>>};
                true ->
                    {ok, _} = ana_db:exec("UPDATE technical.parameter SET company_risk = NULLIF($2, risk) WHERE key = $1",
                                          [Key, Risk]),
                    ana_admin:log(Who, <<"parameter.risk">>, Key, Min, Risk),
                    ok
            end;
        _ -> {error, not_found}
    end.

decode(null) -> null;
decode(V) when is_binary(V) -> json:decode(V);
decode(V) -> V.
