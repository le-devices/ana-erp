%% SPDX-FileCopyrightText: 2026 André Luis Pereira dos Santos
%% SPDX-License-Identifier: AGPL-3.0-or-later
%% Spec 068 (D1, D6): whether a change passes a "changed" rule, and whether its firing is one per record or grouped.
%% Pure (eunit): the rule as stored (watch_fields, watch_filter, watch_key, watch_origins, watch_mode), a change as
%% #{key, changes => #{Ref => [Before, After]}}.
-module(ana_watch_match).

-export([item/2, origin_allowed/2, grouped/4, check_filter/2, default_origins/0]).

-define(GROUP, 20).

%% The change passes when one of the rule's fields changed in the way the filter asks, for the record asked.
-spec item(map(), map()) -> boolean().
item(R, #{key := Key, changes := Ch}) ->
    Fields = [F || F <- list(maps:get(<<"watch_fields">>, R, [])), maps:is_key(F, Ch)],
    key_ok(maps:get(<<"watch_key">>, R, null), Key) andalso
        lists:any(fun(F) -> value_ok(map(maps:get(<<"watch_filter">>, R, #{})), maps:get(F, Ch)) end, Fields).

key_ok(null, _) -> true;
key_ok(K, Key) -> to_text(K) =:= to_text(Key).

value_ok(Filter, [B, A]) ->
    lists:all(fun({K, V}) -> cond_ok(K, V, B, A) end, maps:to_list(Filter));
value_ok(_, _) -> false.

cond_ok(<<"from">>, V, B, _) -> same(V, B);
cond_ok(<<"to">>, V, _, A) -> same(V, A);
cond_ok(<<"became">>, <<"empty">>, B, A) -> not empty(B) andalso empty(A);
cond_ok(<<"became">>, <<"filled">>, B, A) -> empty(B) andalso not empty(A);
cond_ok(<<"min_change_pct">>, Pct, B, A) ->
    case {num(B), num(A)} of
        {X, Y} when is_number(X), is_number(Y), X =/= 0 -> abs(Y - X) * 100 / abs(X) >= Pct;
        {X, Y} when is_number(X), is_number(Y) -> Y =/= X;           % from zero: any change is "more than"
        _ -> false
    end;
cond_ok(<<"direction">>, <<"up">>, B, A) -> cmp_num(B, A, fun(X, Y) -> Y > X end);
cond_ok(<<"direction">>, <<"down">>, B, A) -> cmp_num(B, A, fun(X, Y) -> Y < X end);
cond_ok(_, _, _, _) -> false.

%% Numbers, or ISO dates and date-times ("a data de entrega foi adiada"), which order as text.
cmp_num(B, A, F) ->
    case {num(B), num(A)} of
        {X, Y} when is_number(X), is_number(Y) -> F(X, Y);
        _ ->
            case iso(B) andalso iso(A) of
                true -> F(B, A);
                false -> false
            end
    end.

iso(V) when is_binary(V) -> re:run(V, "^\\d{4}-\\d{2}-\\d{2}", [{capture, none}]) =:= match;
iso(_) -> false.

same(null, V) -> empty(V);
same(V, X) -> to_text(V) =:= to_text(X).

empty(null) -> true;
empty(<<>>) -> true;
empty(_) -> false.

num(V) when is_number(V) -> V;
num(V) when is_binary(V) ->
    case string:to_float(V) of
        {F, <<>>} -> F;
        _ -> case string:to_integer(V) of {I, <<>>} -> I; _ -> undefined end
    end;
num(_) -> undefined.

to_text(V) when is_binary(V) -> V;
to_text(V) when is_integer(V) -> integer_to_binary(V);
to_text(V) when is_float(V) -> float_to_binary(V, [short]);
to_text(true) -> <<"true">>;
to_text(false) -> <<"false">>;
to_text(null) -> null;
to_text(V) -> iolist_to_binary(io_lib:format("~0p", [V])).

%% D1: every origin but an import, unless the rule says.
-spec default_origins() -> [binary()].
default_origins() -> [<<"screen">>, <<"api">>, <<"rule">>, <<"integration">>, <<"routine">>, <<"other">>].

-spec origin_allowed([binary()] | null, binary()) -> boolean().
origin_allowed(null, Kind) -> lists:member(Kind, default_origins());
origin_allowed(L, Kind) when is_list(L) -> lists:member(Kind, L).

%% D6: grouped for an import or a routine, or a batch of more than ?GROUP records; never for one record watched.
-spec grouped(binary(), binary(), non_neg_integer(), term()) -> boolean().
grouped(_, _, _, Key) when Key =/= null -> false;
grouped(<<"record">>, _, _, _) -> false;
grouped(<<"grouped">>, _, _, _) -> true;
grouped(_, Kind, N, _) -> lists:member(Kind, [<<"import">>, <<"routine">>]) orelse N > ?GROUP.

%% The filter a rule may have (checked when it is saved): known keys, sensible values, never on a secret field.
-spec check_filter(map(), boolean()) -> ok | {error, binary()}.
check_filter(F, AnySecret) when is_map(F) ->
    Bad = [K || K <- maps:keys(F), not lists:member(K, [<<"from">>, <<"to">>, <<"became">>, <<"min_change_pct">>,
                                                          <<"direction">>])],
    if
        Bad =/= [] -> {error, <<"filtro desconhecido: "/utf8, (hd(Bad))/binary>>};
        AnySecret andalso map_size(F) > 0 ->
            {error, <<"um campo sigiloso só pode ser vigiado como \"alterado\": o valor dele nunca é comparado nem mostrado"/utf8>>};
        true ->
            case {maps:get(<<"became">>, F, null), maps:get(<<"min_change_pct">>, F, null), maps:get(<<"direction">>, F, null)} of
                {B, _, _} when B =/= null, B =/= <<"empty">>, B =/= <<"filled">> -> {error, <<"use esvaziado ou preenchido"/utf8>>};
                {_, P, _} when P =/= null, not (is_number(P) andalso P > 0 andalso P =< 100000) ->
                    {error, <<"variação mínima: um número maior que zero (%)"/utf8>>};
                {_, _, D} when D =/= null, D =/= <<"up">>, D =/= <<"down">> -> {error, <<"direção: subir ou descer"/utf8>>};
                _ -> ok
            end
    end;
check_filter(_, _) -> {error, <<"filtro inválido"/utf8>>}.

list(L) when is_list(L) -> L;
list(_) -> [].

map(M) when is_map(M) -> M;
map(_) -> #{}.
