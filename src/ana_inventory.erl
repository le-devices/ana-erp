%% SPDX-FileCopyrightText: 2026 André Luis Pereira dos Santos
%% SPDX-License-Identifier: AGPL-3.0-or-later
%% Inventory of the installation's components and integrity of the shipped files (spec 033,
%% RF-033-01, RF-033-04).
%%
%% Components: ANA itself, OTP/ERTS and OTP applications, Hex libraries (rebar.lock copied to
%% priv by the Dockerfile), Python, PostgreSQL and its extensions, and the image's Debian
%% packages (by source package, as OSV advisories name them). The table is rewritten only
%% where something changed (P15).
%%
%% Files: priv/asset-manifest.txt (sha256sum format, written at image build) lists the
%% interface, programs, migrations and Python runtime; any change after the build is a finding.
-module(ana_inventory).

-export([collect/0, sync/0, list/0, verify_files/0, verify_files/2, parse_dpkg/1, parse_lock/1]).

-type component() :: {Ecosystem :: binary(), Name :: binary(), Version :: binary(), Source :: binary()}.

%% ---------------------------------------------------------------- collect

-spec collect() -> [component()].
collect() ->
    Hex = hex_names(),
    Apps = [{App, Vsn} || {App, _, Vsn} <- application:loaded_applications()],
    Erlang = [{<<"OTP">>, <<"erlang-otp">>, otp_version(), <<"runtime">>},
              {<<"OTP">>, <<"erts">>, list_to_binary(erlang:system_info(version)), <<"runtime">>}]
        ++ [{eco(App, Hex), atom_to_binary(App), list_to_binary(Vsn), <<"runtime">>} || {App, Vsn} <- Apps],
    dedupe(Erlang ++ python() ++ postgres() ++ debian()).

eco(ana, _) -> <<"ANA">>;
eco(App, Hex) ->
    case lists:member(atom_to_binary(App), Hex) of
        true -> <<"Hex">>;
        false -> <<"OTP">>
    end.

dedupe(L) ->
    maps:values(maps:from_list([{{E, N}, C} || {E, N, _, _} = C <- L])).

%% The release embeds ERTS without OTP's releases/<n>/OTP_VERSION: the Dockerfile copies it to priv.
otp_version() ->
    Rel = erlang:system_info(otp_release),
    Files = [filename:join(priv(), "OTP_VERSION"), filename:join([code:root_dir(), "releases", Rel, "OTP_VERSION"])],
    case [V || F <- Files, {ok, V} <- [file:read_file(F)]] of
        [V | _] -> string:trim(V);
        [] -> list_to_binary(Rel)
    end.

hex_names() ->
    Candidates = [filename:join(priv(), "rebar.lock"), "rebar.lock"],
    case [L || F <- Candidates, {ok, L} <- [file:consult(F)]] of
        [Lock | _] -> [N || {N, _} <- parse_lock(Lock)];
        [] -> [<<"cowboy">>, <<"cowlib">>, <<"ranch">>, <<"epgsql">>]
    end.

%% rebar.lock terms → [{Name, Version}] of Hex packages.
-spec parse_lock([term()]) -> [{binary(), binary()}].
parse_lock([{_LockVsn, Deps} | _]) when is_list(Deps) ->
    [{Name, Vsn} || {Name, {pkg, _, Vsn}, _Level} <- Deps];
parse_lock([Deps | _]) when is_list(Deps) ->
    [{Name, Vsn} || {Name, {pkg, _, Vsn}, _Level} <- Deps];
parse_lock(_) -> [].

python() ->
    case os:find_executable("python3") of
        false -> [];
        Exe ->
            Port = open_port({spawn_executable, Exe},
                             [{args, ["-c", "import sys; print(sys.version.split()[0])"]}, exit_status, stderr_to_stdout, binary]),
            case collect_port(Port, <<>>) of
                {0, Out} -> [{<<"Python">>, <<"cpython">>, string:trim(Out), <<"runtime">>}];
                _ -> []
            end
    end.

collect_port(Port, Acc) ->
    receive
        {Port, {data, D}} -> collect_port(Port, <<Acc/binary, D/binary>>);
        {Port, {exit_status, S}} -> {S, Acc}
    after 5000 -> catch port_close(Port), {timeout, Acc}
    end.

postgres() ->
    Server = case ana_db:one("SELECT split_part(current_setting('server_version'), ' ', 1) AS v", []) of
        {ok, #{<<"v">> := V}} -> [{<<"PostgreSQL">>, <<"postgresql">>, V, <<"database">>}];
        _ -> []
    end,
    Ext = case ana_db:rows("SELECT extname, extversion FROM pg_extension", []) of
        {ok, Rows} -> [{<<"PostgreSQL">>, N, V, <<"database">>} || #{<<"extname">> := N, <<"extversion">> := V} <- Rows];
        _ -> []
    end,
    Server ++ Ext.

debian() ->
    case file:read_file("/var/lib/dpkg/status") of
        {ok, Status} ->
            Eco = <<"Debian:", (os_version())/binary>>,
            [{Eco, N, V, <<"image">>} || {N, V} <- parse_dpkg(Status)];
        _ -> []
    end.

os_version() ->
    case file:read_file("/etc/os-release") of
        {ok, B} ->
            case re:run(B, <<"(?m)^VERSION_ID=\"?([0-9.]+)\"?">>, [{capture, all_but_first, binary}]) of
                {match, [V]} -> hd(binary:split(V, <<".">>));
                _ -> <<"unknown">>
            end;
        _ -> <<"unknown">>
    end.

%% dpkg status → [{SourcePackage, Version}] of installed packages. "Source: x (1.2)" names the
%% source package (and its version when it differs from the binary's).
-spec parse_dpkg(binary()) -> [{binary(), binary()}].
parse_dpkg(Status) ->
    Blocks = binary:split(Status, [<<"\n\n">>], [global, trim_all]),
    Pkgs = [P || B <- Blocks, P <- [dpkg_block(B)], P =/= skip],
    maps:to_list(maps:from_list(Pkgs)).

dpkg_block(B) ->
    F = maps:from_list([{K, string:trim(V)} || L <- binary:split(B, <<"\n">>, [global]), L =/= <<>>,
                                              binary:first(L) =/= $\s, [K, V] <- [binary:split(L, <<":">>)]]),
    case F of
        #{<<"Package">> := P, <<"Version">> := V, <<"Status">> := <<"install ok installed">>} ->
            case maps:get(<<"Source">>, F, undefined) of
                undefined -> {P, V};
                Src ->
                    case re:run(Src, <<"^(\\S+)(?:\\s+\\((\\S+)\\))?">>, [{capture, all_but_first, binary}]) of
                        {match, [S, SV]} -> {S, SV};
                        {match, [S]} -> {S, V};
                        _ -> {P, V}
                    end
            end;
        _ -> skip
    end.

%% ---------------------------------------------------------------- store

%% Writes only what changed; returns the current inventory.
-spec sync() -> {ok, [component()]}.
sync() ->
    Now = collect(),
    {ok, Rows} = ana_db:rows("SELECT ecosystem, name, version, source FROM ana_system.component", []),
    Old = maps:from_list([{{E, N}, {V, S}} || #{<<"ecosystem">> := E, <<"name">> := N, <<"version">> := V, <<"source">> := S} <- Rows]),
    New = maps:from_list([{{E, N}, {V, S}} || {E, N, V, S} <- Now]),
    Changed = [{E, N, V, S} || {{E, N}, {V, S}} <- maps:to_list(New), maps:get({E, N}, Old, undefined) =/= {V, S}],
    Gone = [K || K <- maps:keys(Old), not maps:is_key(K, New)],
    Node = atom_to_binary(node()),
    _ = Changed =/= [] andalso ana_db:exec(
        "INSERT INTO ana_system.component (ecosystem, name, version, source, node) "
        "SELECT e, n, v, s, $5 FROM unnest($1::text[], $2::text[], $3::text[], $4::text[]) AS x(e, n, v, s) "
        "ON CONFLICT (ecosystem, name) DO UPDATE SET version = EXCLUDED.version, source = EXCLUDED.source, "
        "  node = EXCLUDED.node, updated_at = now()",
        [[E || {E, _, _, _} <- Changed], [N || {_, N, _, _} <- Changed], [V || {_, _, V, _} <- Changed],
         [S || {_, _, _, S} <- Changed], Node]),
    _ = Gone =/= [] andalso ana_db:exec(
        "DELETE FROM ana_system.component c USING unnest($1::text[], $2::text[]) AS x(e, n) "
        "WHERE c.ecosystem = x.e AND c.name = x.n", [[E || {E, _} <- Gone], [N || {_, N} <- Gone]]),
    {ok, Now}.

list() ->
    ana_db:rows("SELECT ecosystem, name, version, source, node, updated_at FROM ana_system.component "
                "ORDER BY CASE source WHEN 'runtime' THEN 0 WHEN 'database' THEN 1 ELSE 2 END, ecosystem, name", []).

%% ---------------------------------------------------------------- files (RF-033-04)

-spec verify_files() -> {ok, non_neg_integer()} | {mismatch, [{binary(), changed | missing | added}]} | no_manifest.
verify_files() ->
    verify_files(priv(), filename:join(priv(), "asset-manifest.txt")).

-spec verify_files(file:filename(), file:filename()) ->
    {ok, non_neg_integer()} | {mismatch, [{binary(), changed | missing | added}]} | no_manifest.
verify_files(Root, Manifest) ->
    case file:read_file(Manifest) of
        {ok, Text} ->
            Listed = [{normalize(F), string:lowercase(H)}
                      || L <- binary:split(Text, <<"\n">>, [global, trim_all]),
                         [H, F] <- [binary:split(string:trim(L), <<"  ">>)]],
            Dirs = lists:usort([hd(filename:split(F)) || {F, _} <- Listed]),
            Present = lists:usort([normalize(list_to_binary(F)) || D <- Dirs,
                                   F <- filelib:wildcard(binary_to_list(D) ++ "/**", Root),
                                   filelib:is_regular(filename:join(Root, F))]),
            Bad = [{F, changed} || {F, H} <- Listed, lists:member(F, Present), sha256_file(filename:join(Root, F)) =/= H]
                ++ [{F, missing} || {F, _} <- Listed, not lists:member(F, Present)]
                ++ [{F, added} || F <- Present, not lists:keymember(F, 1, Listed)],
            case Bad of
                [] -> {ok, length(Listed)};
                _ -> {mismatch, Bad}
            end;
        _ -> no_manifest
    end.

normalize(<<"./", F/binary>>) -> F;
normalize(F) -> F.

sha256_file(Path) ->
    case file:read_file(Path) of
        {ok, B} -> binary:encode_hex(crypto:hash(sha256, B), lowercase);
        _ -> <<>>
    end.

priv() ->
    case code:priv_dir(ana) of
        {error, _} -> "priv";
        D -> D
    end.
