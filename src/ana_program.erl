%% Program repository (spec 002: RF-002-01, RF-002-02, RNF-002-08; spec 011:
%% RF-011-10).
%%
%% The source cache (ETS) is invalidated locally on save and on other nodes via
%% NOTIFY "ana_program" (ana_listener).
-module(ana_program).
-compile({no_auto_import, [get/1]}).
-export([refresh_params/0, init_cache/0, valid_name/1,
         list/1, get/1, save/3, deactivate/2, purge/2, versions/1, version/2, restore/3,
         for_execution/1, library_source/1,
         commands/0, save_command/3, delete_command/1, on_notify/2,
         inspect_fields/1, write_in/5, invalidate/1]).

-define(CACHE, ana_program_cache).
-define(CHANNEL, "ana_program").
-define(NAME_RE, "^[a-z][a-z0-9_]*(\\.[a-z][a-z0-9_]*)*$").

init_cache() ->
    _ = ets:new(?CACHE, [named_table, public, set, {read_concurrency, true}]),
    ok.

%% ==========================================================================
%% Queries
%% ==========================================================================

-spec valid_name(term()) -> boolean().
valid_name(Name) when is_binary(Name), byte_size(Name) =< 128 ->
    re:run(Name, ?NAME_RE, [{capture, none}]) =:= match;
valid_name(_) -> false.

list(IncludeInactive) ->
    ana_db:rows(
        "SELECT name, description, kind, exposed, public, restricted, min_role, active, version, warning, "
        "       updated_at, updated_by, "
        %% Spec 009 (D8): a product program edited here is "customized — outside standard support".
        "       (seed_hash IS NOT NULL AND seed_hash <> encode(sha256(convert_to(source, 'UTF8')), 'hex')) AS customized "
        "FROM ana_system.program WHERE active OR $1 ORDER BY name", [IncludeInactive]).

get(Name) ->
    ana_db:one(
        "SELECT name, description, kind, exposed, public, restricted, min_role, active, in_menu, version, source, "
        "       params, docs, warning, limits, lint, updated_at, updated_by, "
        "       (seed_hash IS NOT NULL AND seed_hash <> encode(sha256(convert_to(source, 'UTF8')), 'hex')) AS customized "
        "FROM ana_system.program WHERE name = $1", [Name]).

versions(Name) ->
    ana_db:rows(
        "SELECT version, comment, created_at, created_by, length(source) AS size "
        "FROM ana_system.program_version WHERE name = $1 ORDER BY version DESC LIMIT 200", [Name]).

version(Name, V) ->
    ana_db:one(
        "SELECT version, source, comment, created_at, created_by "
        "FROM ana_system.program_version WHERE name = $1 AND version = $2", [Name, V]).

%% Metadata + source for running, cached (RNF-002-08).
-spec for_execution(binary()) -> {ok, map()} | {error, not_found}.
for_execution(Name) ->
    case ets:lookup(?CACHE, Name) of
        [{_, P}] -> {ok, P};
        [] ->
            case ana_db:one(
                   "SELECT name, version, source, kind, exposed, restricted, min_role, active, params, "
                   "       description, docs, limits, portal, public "
                   "FROM ana_system.program WHERE name = $1", [Name]) of
                {ok, #{} = P} ->
                    ets:insert(?CACHE, {Name, P}),
                    {ok, P};
                _ ->
                    {error, not_found}
            end
    end.

%% RF-002-07: library source, or a package marker (name prefix).
-spec library_source(binary()) -> map().
library_source(Name) ->
    case valid_name(Name) andalso for_execution(Name) of
        {ok, #{<<"kind">> := <<"library">>, <<"active">> := true, <<"source">> := S}} ->
            #{source => S};
        false ->
            #{source => null, package => false};
        _ ->
            {ok, #{<<"n">> := N}} = ana_db:one(
                "SELECT count(*) AS n FROM ana_system.program "
                "WHERE kind = 'library' AND active AND starts_with(name, $1 || '.')", [Name]),
            #{source => null, package => N > 0}
    end.

%% ==========================================================================
%% Saving (RF-002-02)
%% ==========================================================================

%% Fields: source, description, kind, exposed, restricted, min_role, active,
%% comment, base_version (optimistic control against concurrent edits).
-spec save(binary(), map(), map()) -> {ok, map()} | {error, term()}.
save(Name, Fields, #{username := Who}) ->
    case valid_name(Name) of
        false -> {error, invalid_name};
        true ->
            Source = maps:get(<<"source">>, Fields, undefined),
            Insp = inspection(Source, maps:get(<<"kind">>, Fields, undefined)),
            R = try ana_db:transaction(fun(C) -> write(C, Name, Fields, Source, Insp, Who) end)
                catch throw:{error, E} -> {error, E}
                end,
            invalidate(Name),
            R
    end.

%% Spec 034: several programs in one transaction (transport import). Inspection (Python) runs
%% before the transaction; the caller invalidates the caches after COMMIT.
-spec inspect_fields(map()) -> map() | undefined.
inspect_fields(Fields) ->
    inspection(maps:get(<<"source">>, Fields, undefined), maps:get(<<"kind">>, Fields, undefined)).

-spec write_in(epgsql:connection(), binary(), map(), map() | undefined, binary()) -> {ok, map()} | {error, term()}.
write_in(C, Name, Fields, Insp, Who) ->
    try write(C, Name, Fields, maps:get(<<"source">>, Fields, undefined), Insp, Who)
    catch throw:{error, E} -> {error, E}
    end.

write(C, Name, Fields, Source, Insp, Who) ->
    {ok, Current} = query_one(C,
        "SELECT version, source FROM ana_system.program WHERE name = $1 FOR UPDATE", [Name]),
    Comment = maps:get(<<"comment">>, Fields, <<>>),
    case Current of
        undefined when Source =:= undefined ->
            {error, source_required};
        undefined ->
            ok = exec(C,
                "INSERT INTO ana_system.program (name, description, kind, exposed, restricted, min_role, "
                "  active, version, source, params, docs, warning, updated_by, limits, in_menu, lint, portal, public) "
                "VALUES ($1, $2, $3, $4, $5, $6, $7, 1, $8, $9, $10, $11, $12, $13, $14, $15, $16, $17)",
                [Name, maps:get(<<"description">>, Fields, <<>>),
                 maps:get(<<"kind">>, Fields, <<"program">>),
                 maps:get(<<"exposed">>, Fields, false),
                 maps:get(<<"restricted">>, Fields, false),
                 maps:get(<<"min_role">>, Fields, <<"user">>),
                 maps:get(<<"active">>, Fields, true),
                 Source, field(params, Insp), field(docs, Insp), field(warning, Insp), Who,
                 maps:get(<<"limits">>, Fields, #{}), maps:get(<<"in_menu">>, Fields, true), field(lint, Insp),
                 maps:get(<<"portal">>, Fields, false) =:= true,
                 maps:get(<<"public">>, Fields, false) =:= true andalso maps:get(<<"exposed">>, Fields, false) =:= true]),
            ok = new_version(C, Name, 1, Source, Comment, Who),
            notify(C, Name),
            {ok, #{version => 1, created => true, warning => field(warning, Insp)}};
        #{<<"version">> := V, <<"source">> := CurrentSource} ->
            case maps:get(<<"base_version">>, Fields, V) of
                V ->
                    Changed = Source =/= undefined andalso Source =/= CurrentSource,
                    NV = case Changed of true -> V + 1; false -> V end,
                    ok = exec(C,
                        "UPDATE ana_system.program SET "
                        "  description = COALESCE($2, description), kind = COALESCE($3, kind), "
                        "  exposed = COALESCE($4, exposed), restricted = COALESCE($5, restricted), "
                        "  min_role = COALESCE($6, min_role), active = COALESCE($7, active), version = $8, "
                        "  source = COALESCE($9, source), "
                        "  params = CASE WHEN $9 IS NULL THEN params ELSE $10 END, "
                        "  docs = CASE WHEN $9 IS NULL THEN docs ELSE $11 END, "
                        "  warning = CASE WHEN $9 IS NULL THEN warning ELSE $12 END, "
                        "  updated_at = now(), updated_by = $13, limits = COALESCE($14, limits), "
                        "  in_menu = COALESCE($15, in_menu), "
                        "  lint = CASE WHEN $9 IS NULL THEN lint ELSE $16 END, "
                        "  portal = COALESCE($17, portal), "
                        "  public = CASE WHEN COALESCE($4, exposed) THEN COALESCE($18, public) ELSE false END "
                        "WHERE name = $1",
                        [Name, maps:get(<<"description">>, Fields, null),
                         maps:get(<<"kind">>, Fields, null),
                         maps:get(<<"exposed">>, Fields, null),
                         maps:get(<<"restricted">>, Fields, null),
                         maps:get(<<"min_role">>, Fields, null),
                         maps:get(<<"active">>, Fields, null), NV,
                         null_if_undefined(Source), field(params, Insp), field(docs, Insp),
                         field(warning, Insp), Who, maps:get(<<"limits">>, Fields, null),
                         maps:get(<<"in_menu">>, Fields, null), field(lint, Insp),
                         maps:get(<<"portal">>, Fields, null), maps:get(<<"public">>, Fields, null)]),
                    _ = Changed andalso (ok =:= new_version(C, Name, NV, Source, Comment, Who)),
                    notify(C, Name),
                    {ok, #{version => NV, created => false, warning => field(warning, Insp)}};
                _Other ->
                    {error, {conflict, V}}
            end
    end.

new_version(C, Name, V, Source, Comment, Who) ->
    exec(C, "INSERT INTO ana_system.program_version (name, version, source, comment, created_by) "
            "VALUES ($1, $2, $3, $4, $5)", [Name, V, Source, Comment, Who]).

deactivate(Name, User) ->
    save(Name, #{<<"active">> => false}, User).

%% RF-011-10: removes program and versions; execution history stays.
purge(Name, #{username := Who}) ->
    case ana_db:exec("DELETE FROM ana_system.program WHERE name = $1", [Name]) of
        {ok, 0} -> {error, not_found};
        {ok, 1} ->
            invalidate(Name),
            _ = ana_db:exec("SELECT pg_notify('" ?CHANNEL "', $1)", [Name]),
            ana_admin:log(Who, <<"program.purge">>, Name, null, null),
            {ok, #{purged => Name}};
        E -> E
    end.

restore(Name, V, User) ->
    case version(Name, V) of
        {ok, #{<<"source">> := S}} ->
            save(Name, #{<<"source">> => S,
                         <<"comment">> => unicode:characters_to_binary(
                             ["restaurado da versão ", integer_to_binary(V)])}, User);
        {ok, undefined} -> {error, not_found};
        E -> E
    end.

%% Programs saved before parameters carried their declared order ("order")
%% are inspected again, without a new version, so forms follow the source.
-spec refresh_params() -> {ok, non_neg_integer()}.
refresh_params() ->
    {ok, Rows} = ana_db:rows(
        "SELECT name, source, kind FROM ana_system.program", []),
    %% Also refreshes the static SQL findings (spec 019): the rules evolve with the product.
    %% Written only when something changed (P15).
    N = length([ok || #{<<"name">> := Name, <<"source">> := Source, <<"kind">> := Kind} <- Rows,
                      #{params := P, lint := L} <- [inspection(Source, Kind)],
                      {ok, 1} <- [ana_db:exec("UPDATE ana_system.program SET params = COALESCE($2, params), "
                                              "lint = COALESCE($3, '[]'::jsonb) WHERE name = $1 "
                                              "AND (params IS DISTINCT FROM COALESCE($2, params) "
                                              "     OR lint IS DISTINCT FROM COALESCE($3, '[]'::jsonb))",
                                              [Name, P, L])],
                      _ <- [invalidate(Name)]]),
    {ok, N}.

%% RF-005-08: inspection (syntax, PARAMS, docs) without running.
inspection(undefined, _) -> undefined;
inspection(Source, Kind) ->
    case ana_py:inspect(Source) of
        {ok, #{<<"ok">> := false, <<"error">> := #{<<"line">> := L, <<"message">> := M}}} ->
            #{warning => unicode:characters_to_binary(io_lib:format("linha ~p: ~ts", [L, M])),
              params => null, docs => null, lint => null};
        {ok, #{<<"ok">> := true} = R} ->
            Warning = case R of
                #{<<"error">> := #{<<"line">> := L, <<"message">> := M}} ->
                    unicode:characters_to_binary(io_lib:format("linha ~p: ~ts", [L, M]));
                #{<<"has_main">> := false} when Kind =/= <<"library">> ->
                    <<"o programa não define main(**params)"/utf8>>;
                _ -> null
            end,
            #{warning => Warning,
              params => maps:get(<<"params">>, R, null),
              docs => maps:get(<<"docs">>, R, null),
              lint => maps:get(<<"lint">>, R, null)};
        {error, Reason} ->
            logger:warning("inspection unavailable: ~0p", [Reason]),
            #{warning => null, params => null, docs => null, lint => null}
    end.

field(_, undefined) -> null;
field(K, M) -> maps:get(K, M, null).

null_if_undefined(undefined) -> null;
null_if_undefined(V) -> V.

%% ==========================================================================
%% Commands (RF-005-06)
%% ==========================================================================

commands() ->
    ana_db:rows(
        "SELECT c.code, c.program, c.description, p.params, p.min_role, p.restricted, p.docs "
        "FROM ana_system.command c JOIN ana_system.program p ON p.name = c.program "
        "WHERE p.active ORDER BY c.code", []).

save_command(Code, Program, Description) ->
    ana_db:exec(
        "INSERT INTO ana_system.command (code, program, description) VALUES ($1, $2, $3) "
        "ON CONFLICT (code) DO UPDATE SET program = EXCLUDED.program, "
        "  description = EXCLUDED.description", [Code, Program, Description]).

delete_command(Code) ->
    ana_db:exec("DELETE FROM ana_system.command WHERE code = $1", [Code]).

%% ==========================================================================
%% SQL helpers
%% ==========================================================================

query_one(C, Sql, Params) ->
    case ana_db:query(C, Sql, Params) of
        {ok, #{columns := Cols, rows := [R | _]}} ->
            {ok, maps:from_list(lists:zip([N || #{name := N} <- Cols], R))};
        {ok, _} -> {ok, undefined};
        E -> E
    end.

exec(C, Sql, Params) ->
    case ana_db:query(C, Sql, Params) of
        {ok, _} -> ok;
        {error, E} -> throw({error, E})
    end.

notify(C, Name) ->
    ok = exec(C, "SELECT pg_notify('" ?CHANNEL "', $1)", [Name]).

invalidate(Name) ->
    ets:delete(?CACHE, Name).

on_notify(_, all) -> ets:delete_all_objects(?CACHE);
on_notify(_, Name) -> invalidate(Name).
