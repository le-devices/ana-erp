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
