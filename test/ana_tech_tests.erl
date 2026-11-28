%% SPDX-FileCopyrightText: 2026 André Luis Pereira dos Santos
%% SPDX-License-Identifier: AGPL-3.0-or-later
%% Spec 077 (T-077-01): every action of the catalog has its function in the core, and every function its action —
%% the catalog never points to code that does not exist, and no function runs outside the catalog.
-module(ana_tech_tests).
-include_lib("eunit/include/eunit.hrl").

catalog_codes() ->
    Dir = filename:join([filename:dirname(code:which(?MODULE)), "..", "..", "..", "..", "priv", "migrations"]),
    Files = filelib:wildcard(filename:join(Dir, "*.sql")) ++ filelib:wildcard("priv/migrations/*.sql"),
    lists:usort(lists:append(
        [case re:run(Bin, "INSERT INTO technical\\.action \\(code[^;]*?;", [dotall, global, {capture, first, binary}]) of
             {match, Blocks} ->
                 [C || [Block] <- Blocks,
                       {match, Cs} <- [re:run(Block, "^\\('([a-z_]+\\.[a-z_]+)'", [multiline, global, {capture, all_but_first, binary}])],
                       [C] <- Cs];
             nomatch -> []
         end || F <- lists:usort(Files), {ok, Bin} <- [file:read_file(F)]])).

t_077_01_catalog_and_functions_match_test() ->
    Codes = catalog_codes(),
    ?assert(length(Codes) >= 10),
    Funs = lists:sort(maps:keys(ana_tech:handlers())),
    ?assertEqual([], Codes -- Funs),        % an action of the catalog without a function
    ?assertEqual([], Funs -- Codes).        % a function outside the catalog
