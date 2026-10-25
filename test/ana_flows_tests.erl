%% Spec 030: pure parts of the flows engine.
-module(ana_flows_tests).
-include_lib("eunit/include/eunit.hrl").

render_test_() ->
    F = #{<<"number">> => 12, <<"customer">> => <<"ACME">>, <<"items">> => [1, 2]},
    R = fun ana_flows:render/2,
    [?_assertEqual(#{<<"order">> => 12}, R(#{<<"order">> => <<"{{number}}">>}, F)),          % keeps the type
     ?_assertEqual(#{<<"document">> => <<"ORD-12">>}, R(#{<<"document">> => <<"ORD-{{number}}">>}, F)),
     ?_assertEqual(#{<<"orders">> => [12]}, R(#{<<"orders">> => [<<"{{number}}">>]}, F)),
     ?_assertEqual(#{<<"x">> => null}, R(#{<<"x">> => <<"{{nada}}">>}, F)),
     ?_assertEqual(<<"de ACME">>, R(<<"de {{customer}}">>, F))].

%% RF-030-02 / H1: "faturar sozinho só pedidos até R$ 5 mil".
condition_test_() ->
    C = fun ana_flows:condition/2,
    Upto5k = [#{<<"field">> => <<"total">>, <<"op">> => <<"<=">>, <<"value">> => <<"5000">>}],
    [?_assert(C([], #{})),
     ?_assert(C(Upto5k, #{<<"total">> => <<"4999.90">>})),          % numeric text from the database
     ?_assertNot(C(Upto5k, #{<<"total">> => <<"5000.01">>})),
     ?_assertNot(C(Upto5k, #{})),                                     % missing fact: not automatic
     ?_assert(C([#{<<"field">> => <<"payment_method">>, <<"op">> => <<"=">>, <<"value">> => <<"pix">>}], #{<<"payment_method">> => <<"pix">>})),
     ?_assert(C([#{<<"field">> => <<"warehouse">>, <<"op">> => <<"in">>, <<"value">> => [<<"CENTRAL">>, <<"LAB">>]}], #{<<"warehouse">> => <<"LAB">>})),
     ?_assertNot(C(Upto5k ++ [#{<<"field">> => <<"customer_id">>, <<"op">> => <<"!=">>, <<"value">> => 7}],
                   #{<<"total">> => 10, <<"customer_id">> => 7})),
     ?_assertNot(C([#{<<"bad">> => 1}], #{}))].

%% RF-020-14 / CA-020-09: criteria (E inside, OU between) and exceptions; the new operators.
condition_criteria_test_() ->
    C = fun ana_flows:condition/2,
    R = fun(F, Op, V) -> #{<<"field">> => F, <<"op">> => Op, <<"value">> => V} end,
    %% (filial AK01 e total > 1000) ou (filial AK02), exceto cliente bloqueado
    Rule = #{<<"any">> => [[R(<<"branch">>, <<"=">>, <<"AK01">>), R(<<"total">>, <<">">>, 1000)],
                           [R(<<"branch">>, <<"=">>, <<"AK02">>)]],
             <<"except">> => [R(<<"blocked">>, <<"=">>, true)]},
    F = fun(B, T, Bl) -> #{<<"branch">> => B, <<"total">> => T, <<"blocked">> => Bl} end,
    [?_assert(C(Rule, F(<<"AK01">>, <<"1500.00">>, false))),
     ?_assertNot(C(Rule, F(<<"AK01">>, <<"900">>, false))),          % criterion 1 needs both lines
     ?_assert(C(Rule, F(<<"AK02">>, 1, false))),                       % criterion 2 is enough
     ?_assertNot(C(Rule, F(<<"AK02">>, 1, true))),                     % the exception wins
     ?_assertNot(C(Rule, F(<<"AK03">>, 5000, false))),
     ?_assert(C(#{<<"any">> => [], <<"except">> => []}, #{})),          % no criterion: always
     ?_assertNot(C(#{<<"except">> => [R(<<"x">>, <<"not_empty">>, null)]}, #{<<"x">> => <<"a">>})),
     ?_assert(C([R(<<"total">>, <<"between">>, [100, <<"200">>])], #{<<"total">> => <<"150.5">>})),
     ?_assertNot(C([R(<<"total">>, <<"between">>, [100, 200])], #{<<"total">> => 201})),
     ?_assert(C([R(<<"due">>, <<"between">>, [<<"2026-10-01">>, <<"2026-10-31">>])], #{<<"due">> => <<"2026-10-15">>})),
     ?_assert(C([R(<<"due">>, <<">=">>, <<"2026-10-01">>)], #{<<"due">> => <<"2026-11-02">>})),
     ?_assert(C([R(<<"customer">>, <<"contains">>, <<"acme">>)], #{<<"customer">> => <<"ACME Ltda">>})),
     ?_assert(C([R(<<"customer">>, <<"not_contains">>, <<"beta">>)], #{<<"customer">> => <<"ACME Ltda">>})),
     ?_assert(C([R(<<"customer">>, <<"starts">>, <<"Ac">>)], #{<<"customer">> => <<"ACME">>})),
     ?_assert(C([R(<<"customer">>, <<"contains">>, <<>>)], #{<<"customer">> => <<"x">>})),
     ?_assert(C([R(<<"warehouse">>, <<"not_in">>, [<<"LAB">>])], #{<<"warehouse">> => <<"CENTRAL">>})),
     ?_assert(C([R(<<"po">>, <<"empty">>, null)], #{<<"po">> => null})),
     ?_assert(C([#{<<"field">> => <<"po">>, <<"op">> => <<"empty">>}], #{})),
     ?_assertNot(C([R(<<"po">>, <<"not_empty">>, null)], #{<<"po">> => <<>>})),
     ?_assertNot(C(<<"code">>, #{}))].
