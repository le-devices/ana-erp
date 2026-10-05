%% Spec 033: pure parts of the periodic checks (versions, OSV, CVSS, manifest, dpkg, regression).
-module(ana_checks_tests).
-include_lib("eunit/include/eunit.hrl").

compare_test_() ->
    C = fun ana_osv:compare/2,
    [?_assertEqual(-1, C(<<"2.10.0">>, <<"2.12.0">>)),
     ?_assertEqual(1, C(<<"2.12.0">>, <<"2.9.9">>)),          % numeric, not lexical
     ?_assertEqual(0, C(<<"1.8.0">>, <<"1.8.0">>)),
     ?_assertEqual(-1, C(<<"1.0.0-rc1">>, <<"1.0.0">>)),      % pre-release before the release
     ?_assertEqual(-1, C(<<"1.0">>, <<"1.0.1">>)),
     ?_assertEqual(1, C(<<"1:1.0">>, <<"9.9">>)),             % Debian epoch wins
     ?_assertEqual(-1, C(<<"3.0.11-1~deb12u1">>, <<"3.0.11-1">>)),   % "~" sorts before anything
     ?_assertEqual(-1, C(<<"3.0.11-1~deb12u1">>, <<"3.0.11-1~deb12u2">>)),
     ?_assertEqual(1, C(<<"1.2-3">>, <<"1.2">>))].

affected_test_() ->
    R = #{introduced => <<"0">>, fixed => <<"2.11.0">>, last_affected => null, versions => []},
    [?_assert(ana_osv:affected(<<"2.10.0">>, R)),
     ?_assertNot(ana_osv:affected(<<"2.11.0">>, R)),
     ?_assertNot(ana_osv:affected(<<"2.12.0">>, R)),
     ?_assert(ana_osv:affected(<<"1.5">>, #{introduced => <<"1.0">>, fixed => null, last_affected => <<"1.5">>, versions => []})),
     ?_assertNot(ana_osv:affected(<<"0.9">>, #{introduced => <<"1.0">>, fixed => null, last_affected => null, versions => []})),
     ?_assert(ana_osv:affected(<<"4.2">>, #{introduced => null, fixed => null, last_affected => null, versions => [<<"4.2">>]})),
     ?_assertNot(ana_osv:affected(<<"4.2">>, #{introduced => null, fixed => null, last_affected => null, versions => []}))].

parse_test() ->
    Adv = #{<<"id">> => <<"TEST-0001">>, <<"summary">> => <<"Falha de teste">>, <<"aliases">> => [<<"CVE-2099-1">>],
            <<"database_specific">> => #{<<"severity">> => <<"HIGH">>},
            <<"affected">> => [#{<<"package">> => #{<<"ecosystem">> => <<"Hex">>, <<"name">> => <<"cowboy">>},
                                 <<"ranges">> => [#{<<"type">> => <<"SEMVER">>,
                                                    <<"events">> => [#{<<"introduced">> => <<"0">>}, #{<<"fixed">> => <<"2.0.0">>},
                                                                     #{<<"introduced">> => <<"2.5.0">>}, #{<<"fixed">> => <<"2.13.0">>}]},
                                                  #{<<"type">> => <<"GIT">>, <<"events">> => [#{<<"introduced">> => <<"abc">>}]}]}]},
    Rows = ana_osv:parse(Adv),
    ?assertEqual(2, length(Rows)),                         % two SEMVER ranges, GIT ignored
    [A, B] = Rows,
    ?assertEqual({<<"0">>, <<"2.0.0">>}, {maps:get(introduced, A), maps:get(fixed, A)}),
    ?assertEqual({<<"2.5.0">>, <<"2.13.0">>}, {maps:get(introduced, B), maps:get(fixed, B)}),
    ?assertEqual(<<"serious">>, maps:get(severity, A)),
    ?assert(ana_osv:affected(<<"2.12.0">>, B)),
    ?assertEqual([], ana_osv:parse(#{<<"id">> => <<"x">>})),
    ?assertEqual([], ana_osv:parse(Adv#{<<"withdrawn">> => <<"2026-01-01T00:00:00Z">>})).

cvss_test_() ->
    [?_assertEqual(9.8, ana_osv:cvss3(<<"CVSS:3.1/AV:N/AC:L/PR:N/UI:N/S:U/C:H/I:H/A:H">>)),
     ?_assertEqual(6.1, ana_osv:cvss3(<<"CVSS:3.1/AV:N/AC:L/PR:N/UI:R/S:C/C:L/I:L/A:N">>)),
     ?_assertEqual(0.0, ana_osv:cvss3(<<"CVSS:3.1/AV:N/AC:L/PR:N/UI:N/S:U/C:N/I:N/A:N">>)),
     ?_assertEqual(undefined, ana_osv:cvss3(<<"lixo">>)),
     ?_assertEqual(<<"critical">>, ana_osv:severity(#{<<"severity">> => [#{<<"type">> => <<"CVSS_V3">>,
                                                    <<"score">> => <<"CVSS:3.1/AV:N/AC:L/PR:N/UI:N/S:U/C:H/I:H/A:H">>}]})),
     ?_assertEqual(undefined, ana_osv:severity(#{}))].

dpkg_test() ->
    Status = <<"Package: libssl3\nStatus: install ok installed\nSource: openssl (3.0.11-1~deb12u2)\nVersion: 3.0.11-1~deb12u2\n\n"
               "Package: openssl\nStatus: install ok installed\nVersion: 3.0.11-1~deb12u2\nDescription: x\n multi line\n\n"
               "Package: tini\nStatus: install ok installed\nVersion: 0.19.0-1\n\n"
               "Package: removed\nStatus: deinstall ok config-files\nVersion: 1.0\n">>,
    ?assertEqual([{<<"openssl">>, <<"3.0.11-1~deb12u2">>}, {<<"tini">>, <<"0.19.0-1">>}],
                 lists:sort(ana_inventory:parse_dpkg(Status))).

lock_test() ->
    Lock = [{"1.2.0", [{<<"cowboy">>, {pkg, <<"cowboy">>, <<"2.12.0">>}, 0}, {<<"ranch">>, {pkg, <<"ranch">>, <<"1.8.0">>}, 1}]}, []],
    ?assertEqual([{<<"cowboy">>, <<"2.12.0">>}, {<<"ranch">>, <<"1.8.0">>}], ana_inventory:parse_lock(Lock)).

%% CA-033-03: a file changed, removed or added after the build is reported.
manifest_test() ->
    Root = filename:join(os:getenv("TMPDIR", "/tmp"), "ana_manifest_" ++ integer_to_list(erlang:unique_integer([positive]))),
    ok = filelib:ensure_dir(filename:join([Root, "www", "x"])),
    ok = file:write_file(filename:join([Root, "www", "a.js"]), <<"a">>),
    ok = file:write_file(filename:join([Root, "www", "b.css"]), <<"b">>),
    H = fun(B) -> binary:encode_hex(crypto:hash(sha256, B), lowercase) end,
    Manifest = filename:join(Root, "asset-manifest.txt"),
    ok = file:write_file(Manifest, [H(<<"a">>), "  ./www/a.js\n", H(<<"b">>), "  ./www/b.css\n"]),
    ?assertEqual({ok, 2}, ana_inventory:verify_files(Root, Manifest)),
    ok = file:write_file(filename:join([Root, "www", "a.js"]), <<"alterado">>),
    ok = file:delete(filename:join([Root, "www", "b.css"])),
    ok = file:write_file(filename:join([Root, "www", "intruso.js"]), <<"x">>),
    {mismatch, Bad} = ana_inventory:verify_files(Root, Manifest),
    ?assertEqual([{<<"www/a.js">>, changed}, {<<"www/b.css">>, missing}, {<<"www/intruso.js">>, added}], lists:sort(Bad)),
    ?assertEqual(no_manifest, ana_inventory:verify_files(Root, filename:join(Root, "nada.txt"))).

%% CA-033-05: slower by the factor and by at least 50 ms.
regression_test_() ->
    [?_assert(ana_checks:regression(100, 250, 200)),
     ?_assertNot(ana_checks:regression(100, 180, 200)),     % within the factor
     ?_assertNot(ana_checks:regression(2, 30, 200)),        % 15× but only 28 ms: noise
     ?_assert(ana_checks:regression(2, 60, 200))].
