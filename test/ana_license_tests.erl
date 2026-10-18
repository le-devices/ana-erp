%% Spec 009: license verification and state (pure functions).
-module(ana_license_tests).
-include_lib("eunit/include/eunit.hrl").

keypair() ->
    {Pub, Priv} = crypto:generate_key(eddsa, ed25519),
    {#{<<"k1">> => #{<<"public">> => base64:encode(Pub)}, <<"t1">> => #{<<"public">> => base64:encode(Pub), <<"test">> => true}},
     Priv}.

b64u(B) -> binary:replace(binary:replace(binary:replace(base64:encode(B), <<"+">>, <<"-">>, [global]),
                                         <<"/">>, <<"_">>, [global]), <<"=">>, <<>>, [global]).

text(Payload, Priv) ->
    Body = b64u(iolist_to_binary(json:encode(Payload))),
    Sig = b64u(crypto:sign(eddsa, none, Body, [Priv, ed25519])),
    <<"-----BEGIN ANA LICENSE-----\n", Body/binary, ".", Sig/binary, "\n-----END ANA LICENSE-----\n">>.

payload(Over) ->
    maps:merge(#{<<"id">> => <<"L1">>, <<"kid">> => <<"k1">>, <<"customer">> => <<"Cliente">>,
                 <<"valid_from">> => <<"2026-01-01">>, <<"valid_until">> => <<"2026-12-31">>,
                 <<"max_version">> => <<"0.9">>, <<"modules">> => [<<"sales">>, <<"projects">>],
                 <<"limits">> => #{<<"named_users">> => 5}, <<"environment">> => <<"production">>}, Over).

verify_test_() ->
    {Keys, Priv} = keypair(),
    Good = text(payload(#{}), Priv),
    [?_assertMatch({ok, #{<<"customer">> := <<"Cliente">>}, <<"k1">>, false}, ana_license:verify(Good, Keys)),
     %% one byte changed in the signed part
     ?_assertMatch({error, _}, ana_license:verify(binary:replace(Good, <<"-----\n">>, <<"-----\nA">>), Keys)),
     ?_assertMatch({error, <<"licença assinada por chave desconhecida"/utf8>>},
                   ana_license:verify(text(payload(#{<<"kid">> => <<"zz">>}), Priv), Keys)),
     ?_assertMatch({error, _}, ana_license:verify(text(maps:remove(<<"valid_until">>, payload(#{})), Priv), Keys)),
     ?_assertMatch({error, _}, ana_license:verify(<<"lixo">>, Keys)),
     %% a test key never grants production use
     ?_assertMatch({ok, #{<<"environment">> := <<"non_production">>}, <<"t1">>, true},
                   ana_license:verify(text(payload(#{<<"kid">> => <<"t1">>}), Priv), Keys))].

status_test_() ->
    L = payload(#{}),
    S = fun(Lic, Today) -> ana_license:status(Lic, {2026, 1, 1}, {2026, 1, 1}, Today, <<"0.1.0">>) end,
    [?_assertMatch(#{state := <<"valid">>, named_users := 5, modules := [<<"sales">>, <<"projects">>]}, S(L, {2026, 6, 1})),
     ?_assertMatch(#{state := <<"expiring">>, days_left := 30}, S(L, {2026, 12, 1})),
     ?_assertMatch(#{state := <<"grace">>, days_left := -15}, S(L, {2027, 1, 15})),
     ?_assertMatch(#{state := <<"restricted">>, reason := <<"expired">>}, S(L, {2027, 1, 16})),
     ?_assertMatch(#{state := <<"restricted">>, reason := <<"not_yet">>}, S(L#{<<"valid_from">> => <<"2026-07-01">>}, {2026, 6, 1})),
     ?_assertMatch(#{state := <<"restricted">>, reason := <<"version">>},
                   ana_license:status(L, {2026, 1, 1}, {2026, 1, 1}, {2026, 6, 1}, <<"1.0.0">>)),
     %% evaluation: 30 days from the first start, all modules, no limit
     ?_assertMatch(#{state := <<"trial">>, days_left := 30, named_users := unlimited}, S(none, {2026, 1, 1})),
     ?_assertMatch(#{state := <<"trial">>, days_left := 0}, S(none, {2026, 1, 31})),
     ?_assertMatch(#{state := <<"restricted">>, reason := <<"trial_over">>}, S(none, {2026, 2, 1})),
     %% a clock set back more than a day cannot extend anything
     ?_assertMatch(#{state := <<"restricted">>, reason := <<"clock">>},
                   ana_license:status(L, {2026, 1, 1}, {2026, 6, 10}, {2026, 6, 1}, <<"0.1.0">>)),
     ?_assertMatch(#{state := <<"valid">>}, ana_license:status(L, {2026, 1, 1}, {2026, 6, 2}, {2026, 6, 1}, <<"0.1.0">>))].

version_test_() ->
    [?_assert(ana_license:version_covered(<<"0.9">>, <<"0.1.0">>)),
     ?_assert(ana_license:version_covered(<<"0.1">>, <<"0.1.7">>)),
     ?_assertNot(ana_license:version_covered(<<"0.9">>, <<"1.0.0">>)),
     ?_assertNot(ana_license:version_covered(<<"x">>, <<"0.1.0">>))].

module_test_() ->
    [?_assertEqual(<<"projects">>, ana_license:module_of(<<"projects.invoice_project">>)),
     ?_assertEqual(<<"logistics_field">>, ana_license:module_of(<<"field.schedule">>)),
     ?_assertEqual(<<"core">>, ana_license:module_of(<<"finance.reconcile">>)),
     ?_assertEqual(<<"core">>, ana_license:module_of(<<"cli.meu_relatorio">>))].
