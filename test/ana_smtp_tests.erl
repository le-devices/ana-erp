%% SPDX-FileCopyrightText: 2026 LE Devices
%% SPDX-License-Identifier: AGPL-3.0-or-later
%% Spec 044: MIME pieces of the SMTP client.
-module(ana_smtp_tests).
-include_lib("eunit/include/eunit.hrl").

t_044_04_headers_never_break_lines_test() ->
    ?assertEqual(<<"Pedido 12">>, ana_smtp:encode_word(<<"Pedido 12">>)),
    W = ana_smtp:encode_word(<<"Linha 1\r\nBcc: x@y.com"/utf8>>),
    ?assertEqual(nomatch, binary:match(W, [<<"\r">>, <<"\n">>])).

t_044_utf8_words_never_split_a_character_test() ->
    T = binary:copy(<<"ção"/utf8>>, 40),
    Chunks = ana_smtp:chunks(T, 45),
    ?assertEqual(T, iolist_to_binary(Chunks)),
    [?assert(unicode:characters_to_binary(C) =:= C) || C <- Chunks],
    W = ana_smtp:encode_word(<<"Relatório"/utf8>>),
    ?assertMatch({match, _}, re:run(W, "^=\\?UTF-8\\?B\\?")).

t_044_addresses_test() ->
    ?assert(ana_smtp:valid_address(<<"a.b+c@exemplo.com.br">>)),
    [?assertNot(ana_smtp:valid_address(A)) || A <- [<<"a@b">>, <<"x y@z.com">>, <<"a@b.com\n">>, <<"a@b.com\r\nBcc: c@d.com">>,
                                                   <<"<a@b.com>">>, 7]].

t_044_config_requires_safety_test() ->
    Base = #{<<"name">> => <<"m">>, <<"timeout_ms">> => 1000},
    ?assertMatch({error, _}, ana_smtp:config(Base#{<<"options">> => #{<<"host">> => <<"h">>, <<"from">> => <<"a@b.com">>,
                                                                      <<"security">> => <<"none">>}})),
    ?assertMatch({ok, #{port := 587}}, ana_smtp:config(Base#{<<"options">> => #{<<"host">> => <<"h">>, <<"from">> => <<"a@b.com">>}})),
    ?assertMatch({ok, #{port := 465}}, ana_smtp:config(Base#{<<"options">> => #{<<"host">> => <<"h">>, <<"from">> => <<"a@b.com">>,
                                                                                <<"security">> => <<"tls">>}})).
