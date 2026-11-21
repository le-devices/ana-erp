%% SPDX-FileCopyrightText: 2026 André Luis Pereira dos Santos
%% SPDX-License-Identifier: AGPL-3.0-or-later
%% Deterministic masking of personal data for copies to test instances (spec 034, RF-034-06).
%%
%% Same value + same copy key → same mask in every table (joins and duplicates survive);
%% a new copy uses a new key. Nothing of the original is recoverable from the mask.
-module(ana_mask).

-export([kind_for/4, value/3]).

-define(PERSON_COLUMNS, [<<"contact">>, <<"contact_name">>, <<"received_by">>, <<"signed_by">>, <<"customer_approver">>,
                         <<"approver_name">>, <<"requester_name">>, <<"responsible">>]).

%% Kind for a column: installation rule first, then the product catalog. Text kinds only apply
%% to text columns and geo only to numeric ones.
-spec kind_for(binary(), binary(), binary(), map()) -> binary().
kind_for(Table, Column, Type, Rules) when is_map(Rules) ->
    case maps:get({Table, Column}, Rules, undefined) of
        undefined -> catalog(Table, Column, Type);
        K -> K
    end;
kind_for(Table, Column, Type, _) -> catalog(Table, Column, Type).

%% Spec 038: coded columns named like free text (a reason code, not a person's words) are kept.
catalog(Table, <<"reason">>, _) when Table =:= <<"inventory.stock_movement">>; Table =:= <<"inventory.posting_rule">> ->
    <<"keep">>;
catalog(Table, Column, Type) ->
    Text = lists:member(Type, [<<"text">>, <<"character varying">>, <<"character">>, <<"citext">>]),
    Num = lists:member(Type, [<<"numeric">>, <<"double precision">>, <<"real">>]),
    C = Column,
    if
        Text andalso Table =:= <<"base.party">> andalso (C =:= <<"name">> orelse C =:= <<"trade_name">>) -> <<"company">>;
        Text andalso C =:= <<"name">> andalso (Table =:= <<"projects.employee">> orelse Table =:= <<"field.technician">>) -> <<"person">>;
        Text -> text_kind(C);
        Num andalso (C =:= <<"latitude">> orelse C =:= <<"longitude">> orelse C =:= <<"lat">> orelse C =:= <<"lng">>) -> <<"geo">>;
        true -> <<"keep">>
    end.

text_kind(C) ->
    Has = fun(Parts) -> lists:any(fun(P) -> binary:match(C, P) =/= nomatch end, Parts) end,
    case lists:member(C, ?PERSON_COLUMNS) of
        true -> <<"person">>;
        false ->
            case {Has([<<"email">>, <<"e_mail">>]), Has([<<"phone">>, <<"mobile">>, <<"whatsapp">>, <<"telefone">>]),
                  Has([<<"document">>, <<"tax_id">>, <<"cpf">>, <<"cnpj">>, <<"zip">>, <<"cep">>, <<"postal">>]),
                  Has([<<"address">>, <<"street">>]),
                  lists:member(C, [<<"notes">>, <<"note">>, <<"observation">>, <<"comments">>, <<"comment">>, <<"reason">>])} of
                {true, _, _, _, _} -> <<"email">>;
                {_, true, _, _, _} -> <<"phone">>;
                {_, _, true, _, _} -> <<"document">>;
                {_, _, _, true, _} -> <<"address">>;
                {_, _, _, _, true} -> <<"text">>;
                _ -> <<"keep">>
            end
    end.

%% Masks one JSON value (binary or number); null and empty stay as they are.
-spec value(binary(), term(), binary()) -> term().
value(_, null, _) -> null;
value(<<"keep">>, V, _) -> V;
value(<<"null">>, _, _) -> null;
value(_, <<>>, _) -> <<>>;
value(<<"geo">>, V, Key) when is_number(V) ->
    <<N:32, _/binary>> = h(Key, <<"geo">>, float_to_binary(float(V), [{decimals, 6}])),
    round((V + ((N rem 2001) - 1000) / 100000) * 1000000) / 1000000;      % ± ~1 km, fixed per value
value(_, V, _) when not is_binary(V) -> V;
value(<<"person">>, V, Key) -> <<"Pessoa ", (hex(Key, <<"person">>, V, 6))/binary>>;
value(<<"company">>, V, Key) -> <<"Empresa ", (hex(Key, <<"company">>, V, 6))/binary>>;
value(<<"email">>, V, Key) -> <<"u", (string:lowercase(hex(Key, <<"email">>, string:lowercase(V), 10)))/binary, "@exemplo.test">>;
value(<<"phone">>, V, Key) ->
    D = digits(Key, <<"phone">>, V, 8),
    <<"(11) 9", (binary:part(D, 0, 4))/binary, "-", (binary:part(D, 4, 4))/binary>>;
value(<<"document">>, V, Key) ->
    %% Same length and punctuation, digits replaced (formats like 000.000.000-00 survive).
    D = digits(Key, <<"document">>, V, byte_size(V)),
    iolist_to_binary(lists:reverse(element(1, lists:foldl(
        fun(Ch, {Acc, I}) when Ch >= $0, Ch =< $9 -> {[binary:at(D, I) | Acc], I + 1};
           (Ch, {Acc, I}) when Ch >= $A, Ch =< $Z; Ch >= $a, Ch =< $z -> {[$X | Acc], I};
           (Ch, {Acc, I}) -> {[Ch | Acc], I}
        end, {[], 0}, binary_to_list(V)))));
value(<<"address">>, V, Key) ->
    D = digits(Key, <<"address">>, V, 4),
    <<"Rua Exemplo ", (hex(Key, <<"street">>, V, 4))/binary, ", ", (integer_to_binary(binary_to_integer(D) rem 2000 + 1))/binary>>;
value(<<"text">>, V, _) ->
    Len = case unicode:characters_to_list(V) of L when is_list(L) -> length(L); _ -> byte_size(V) end,
    <<"texto mascarado ("/utf8, (integer_to_binary(Len))/binary, " caracteres)">>;
value(_, V, _) -> V.

h(Key, Kind, V) -> crypto:mac(hmac, sha256, Key, <<Kind/binary, ":", V/binary>>).

hex(Key, Kind, V, N) -> binary:part(binary:encode_hex(h(Key, Kind, V)), 0, N).

digits(Key, Kind, V, N) ->
    Bytes = iolist_to_binary([h(Key, <<Kind/binary, (integer_to_binary(I))/binary>>, V) || I <- lists:seq(0, N div 32)]),
    list_to_binary([$0 + (B rem 10) || <<B>> <= binary:part(Bytes, 0, N)]).
