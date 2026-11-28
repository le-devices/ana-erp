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
        [case re:run(Bin, "INSERT INTO technical\\.action \\(code.*?\\);[ \\t]*$", [dotall, multiline, global, {capture, first, binary}]) of
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

%% Spec 077 (T-077-04): every runtime parameter has what a person needs to change it (migration 090), and the
%% catalog lists no parameter the core does not know.
t_077_04_every_parameter_has_its_metadata_test() ->
    {ok, Bin} = file:read_file("priv/migrations/090_technical_parameters.sql"),
    {match, [[Block]]} = re:run(Bin, "INSERT INTO technical\\.parameter \\(key.*?\\);[ \\t]*$", [dotall, multiline, global, {capture, first, binary}]),
    {match, Rows} = re:run(Block, "^\\('([a-z_]+)'", [multiline, global, {capture, all_but_first, binary}]),
    Meta = lists:sort([K || [K] <- Rows]),
    Known = lists:sort([atom_to_binary(K) || {K, _, _, _, _, _, _} <- ana_settings:definitions()]),
    ?assertEqual(Known, Meta).
