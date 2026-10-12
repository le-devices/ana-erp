%% Spec 034: pure parts of transports and masked copies.
-module(ana_transport_tests).
-include_lib("eunit/include/eunit.hrl").

%% CA-034-03: a program changed here since the origin's base is a conflict.
classify_test_() ->
    C = fun ana_transport:classify/3,
    [?_assertEqual(<<"new">>, C(null, <<"n">>, null)),
     ?_assertEqual(<<"unchanged">>, C(<<"n">>, <<"n">>, <<"b">>)),
     ?_assertEqual(<<"update">>, C(<<"b">>, <<"n">>, <<"b">>)),
     ?_assertEqual(<<"conflict">>, C(<<"x">>, <<"n">>, <<"b">>)),
     ?_assertEqual(<<"conflict">>, C(<<"x">>, <<"n">>, null))].   % unknown base: never overwritten in silence

item_sha_test() ->
    P = #{<<"kind">> => <<"program">>, <<"name">> => <<"a.b">>, <<"source">> => <<"def main(): pass\n">>},
    ?assertEqual(binary:encode_hex(crypto:hash(sha256, <<"def main(): pass\n">>), lowercase), ana_transport:item_sha(P)),
    Cmd = #{<<"kind">> => <<"command">>, <<"name">> => <<"x">>, <<"program">> => <<"a.b">>, <<"description">> => <<"d">>},
    ?assertNotEqual(ana_transport:item_sha(Cmd), ana_transport:item_sha(Cmd#{<<"program">> => <<"a.c">>})).

dependencies_test() ->
    Src = <<"from ana_lib.finance import terms\nfrom ana_lib.util import validation as v, format\n"
            "x = ana.call(\"logistics.transfer\", action='ship')\ny = ana.call('sales.lookup')\n">>,
    ?assertEqual([<<"finance.terms">>, <<"logistics.transfer">>, <<"sales.lookup">>, <<"util.format">>, <<"util.validation">>],
                 ana_transport:dependencies(Src)).

%% CA-034-02: Ed25519 over the exact manifest bytes; one changed byte fails.
signature_test() ->
    {Pub, Priv} = crypto:generate_key(eddsa, ed25519),
    Bytes = <<"{\"items\":[]}">>,
    Sig = crypto:sign(eddsa, none, Bytes, [Priv, ed25519]),
    ?assert(crypto:verify(eddsa, none, Bytes, Sig, [Pub, ed25519])),
    ?assertNot(crypto:verify(eddsa, none, <<"{\"items\":[1]}">>, Sig, [Pub, ed25519])).

order_test() ->
    Order = ana_datacopy:order([<<"sales.item">>, <<"base.party">>, <<"sales.order">>, <<"base.product">>],
                               [{<<"sales.item">>, <<"sales.order">>}, {<<"sales.item">>, <<"base.product">>},
                                {<<"sales.order">>, <<"base.party">>}]),
    Pos = fun(T) -> length(lists:takewhile(fun(X) -> X =/= T end, Order)) end,
    ?assert(Pos(<<"base.party">>) < Pos(<<"sales.order">>)),
    ?assert(Pos(<<"sales.order">>) < Pos(<<"sales.item">>)),
    ?assert(Pos(<<"base.product">>) < Pos(<<"sales.item">>)),
    ?assertEqual(4, length(Order)).

%% A cycle is broken at the nullable reference.
cycle_test() ->
    {Order, Broken} = ana_datacopy:order_breaking([<<"p.baseline">>, <<"p.change">>, <<"p.project">>],
        [{<<"p.baseline">>, <<"p.change">>, <<"change_id">>, true}, {<<"p.change">>, <<"p.baseline">>, <<"baseline_id">>, false},
         {<<"p.baseline">>, <<"p.project">>, <<"project_id">>, false}, {<<"p.change">>, <<"p.project">>, <<"project_id">>, false}]),
    ?assertEqual([{<<"p.baseline">>, <<"change_id">>}], Broken),
    ?assertEqual([<<"p.project">>, <<"p.baseline">>, <<"p.change">>], Order).

%% CA-034-05: deterministic per key, different keys differ, format kept, nothing of the original.
mask_test_() ->
    K1 = <<1:256>>, K2 = <<2:256>>,
    M = fun ana_mask:value/3,
    [?_assertEqual(M(<<"company">>, <<"ACME Ltda">>, K1), M(<<"company">>, <<"ACME Ltda">>, K1)),
     ?_assertNotEqual(M(<<"company">>, <<"ACME Ltda">>, K1), M(<<"company">>, <<"ACME Ltda">>, K2)),
     ?_assertMatch(<<"Empresa ", _:6/binary>>, M(<<"company">>, <<"ACME Ltda">>, K1)),
     ?_assertEqual(M(<<"email">>, <<"Ana@Firma.com">>, K1), M(<<"email">>, <<"ana@firma.com">>, K1)),
     ?_assertMatch({match, _}, re:run(M(<<"email">>, <<"ana@firma.com">>, K1), <<"^u[0-9a-f]{10}@exemplo\\.test$">>)),
     ?_assertMatch({match, _}, re:run(M(<<"document">>, <<"123.456.789-09">>, K1), <<"^\\d{3}\\.\\d{3}\\.\\d{3}-\\d{2}$">>)),
     ?_assertNotEqual(<<"123.456.789-09">>, M(<<"document">>, <<"123.456.789-09">>, K1)),
     ?_assertMatch({match, _}, re:run(M(<<"phone">>, <<"+55 19 99999-1234">>, K1), <<"^\\(11\\) 9\\d{4}-\\d{4}$">>)),
     ?_assertEqual(null, M(<<"person">>, null, K1)),
     ?_assertEqual(<<>>, M(<<"text">>, <<>>, K1)),
     ?_assertEqual(42, M(<<"email">>, 42, K1)),
     ?_assert(abs(M(<<"geo">>, -22.9, K1) + 22.9) =< 0.0101),
     ?_assertEqual(<<"texto mascarado (5 caracteres)">>, M(<<"text">>, <<"olá !"/utf8>>, K1))].

kind_test_() ->
    K = fun(T, C, Ty) -> ana_mask:kind_for(T, C, Ty, #{}) end,
    [?_assertEqual(<<"company">>, K(<<"base.party">>, <<"name">>, <<"text">>)),
     ?_assertEqual(<<"keep">>, K(<<"projects.project">>, <<"name">>, <<"text">>)),
     ?_assertEqual(<<"email">>, K(<<"base.party">>, <<"email">>, <<"text">>)),
     ?_assertEqual(<<"document">>, K(<<"base.party">>, <<"tax_id">>, <<"text">>)),
     ?_assertEqual(<<"geo">>, K(<<"field.service_order">>, <<"latitude">>, <<"numeric">>)),
     ?_assertEqual(<<"keep">>, K(<<"sales.sales_order">>, <<"total">>, <<"numeric">>)),
     ?_assertEqual(<<"keep">>, K(<<"inventory.stock_movement">>, <<"reason">>, <<"text">>)),      % spec 038: a code
     ?_assertEqual(<<"text">>, K(<<"logistics.customer_return">>, <<"reason">>, <<"text">>)),     % a person's words
     ?_assertEqual(<<"keep">>, ana_mask:kind_for(<<"base.party">>, <<"email">>, <<"text">>, #{{<<"base.party">>, <<"email">>} => <<"keep">>}))].
