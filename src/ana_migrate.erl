%% Versioned SQL migrations (RF-001-01, CA-001-02) and optional demo data
%% (RF-006-07: only with ANA_DEMO=true — never in a real deployment by default).
%%
%% priv/migrations/NNN_name.sql and priv/demo/NNN_name.sql are applied in order,
%% each in its own transaction, exactly once. An advisory lock prevents two
%% nodes from migrating at the same time.
-module(ana_migrate).
-export([run/0, files/1, known/0]).

-define(LOCK, 7_741_001).

-spec run() -> {ok, [binary()]} | {error, term()}.
run() ->
    {ok, C} = ana_db:connect(ana_config:db()),
    try
        {ok, _, _} = epgsql:squery(C, io_lib:format("SELECT pg_advisory_lock(~b)", [?LOCK])),
        prepare(C),
        {ok, _, Rows} = epgsql:squery(C, "SELECT name FROM ana_system.migration"),
        Applied = [N || {N} <- Rows],
        Wanted = [{<<>>, F} || F <- files("migrations")] ++
                 case ana_config:boolean("ANA_DEMO", false) of
                     true -> [{<<"demo/">>, F} || F <- files("demo")];
                     false -> []
                 end,
        apply_all(C, [{name(P, F), F} || {P, F} <- Wanted, not lists:member(name(P, F), Applied)], [])
    after
        epgsql:close(C)
    end.

prepare(C) ->
    Rs = epgsql:squery(C,
        "CREATE SCHEMA IF NOT EXISTS ana_system;"
        "CREATE TABLE IF NOT EXISTS ana_system.migration ("
        "  name text PRIMARY KEY,"
        "  applied_at timestamptz NOT NULL DEFAULT now());"
        %% RF-023-03: migrations that break the previous version ("-- ana:breaking").
        "CREATE TABLE IF NOT EXISTS ana_system.migration_flag ("
        "  name text NOT NULL, flag text NOT NULL, PRIMARY KEY (name, flag))"),
    [] = [E || {error, E} <- lists:flatten([Rs])],
    ok.

files(Dir) ->
    Path = filename:join(code:priv_dir(ana), Dir),
    lists:sort(filelib:wildcard(filename:join(Path, "*.sql"))).

%% Migrations this version of the code knows (RF-023-03).
-spec known() -> [{binary(), string()}].
known() -> [{name(<<>>, F), F} || F <- files("migrations")].

breaking(Sql) ->
    case binary:split(Sql, <<"\n">>) of
        [First | _] -> binary:match(First, <<"ana:breaking">>) =/= nomatch;
        _ -> false
    end.

name(Prefix, File) -> <<Prefix/binary, (list_to_binary(filename:basename(File, ".sql")))/binary>>.

apply_all(_C, [], Done) ->
    {ok, lists:reverse(Done)};
apply_all(C, [{Name, File} | Rest], Done) ->
    {ok, Sql} = file:read_file(File),
    logger:info("applying migration ~s", [Name]),
    Rs = epgsql:squery(C, ["BEGIN;", Sql, ";",
                           "INSERT INTO ana_system.migration (name) VALUES ('", Name, "');",
                           case breaking(Sql) of
                               true -> ["INSERT INTO ana_system.migration_flag (name, flag) VALUES ('", Name, "', 'breaking');"];
                               false -> []
                           end,
                           "COMMIT;"]),
    case [E || {error, E} <- lists:flatten([Rs])] of
        [] ->
            apply_all(C, Rest, [Name | Done]);
        [Error | _] ->
            _ = epgsql:squery(C, "ROLLBACK"),
            logger:error("migration ~s failed: ~0p", [Name, Error]),
            {error, {migration, Name, Error}}
    end.
