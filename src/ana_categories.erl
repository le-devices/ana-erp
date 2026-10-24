%% Categories of routines (spec 020, RF-020-20..23): personal ones (only their owner sees and changes them) and
%% the company's (made by an administrator, seen by everyone or by the chosen access groups). A category holds
%% shortcuts: the routine stays one (same version, permissions and history), optionally with its own name and
%% pre-filled parameters. Showing a shortcut never grants running the routine — the execution checks as always.
-module(ana_categories).
-export([list/1, create/2, update/3, delete/2, add_shortcuts/3, update_shortcut/3, delete_shortcut/2, reorder/2]).

-define(ADMIN, <<"admin">>).

-spec list(map()) -> {ok, [map()]}.
list(User = #{username := Who}) ->
    Groups = ana_access:groups(Who),
    Admin = ana_security:has_role(User, ?ADMIN),
    {ok, Cats} = ana_db:rows(
        "SELECT id, name, owner IS NOT NULL AS personal, groups, position FROM ana_system.routine_category "
        "WHERE owner = $1 OR (owner IS NULL AND ($2 OR cardinality(groups) = 0 OR groups && $3::text[])) "
        "ORDER BY owner IS NULL, position, lower(name)", [Who, Admin, Groups]),
    Ids = [Id || #{<<"id">> := Id} <- Cats],
    {ok, Shortcuts} = ana_db:rows(
        "SELECT s.id, s.category_id, s.program, s.label, s.params, s.position FROM ana_system.routine_shortcut s "
        "JOIN ana_system.program p ON p.name = s.program AND p.active "
        "WHERE s.category_id = ANY($1) ORDER BY s.category_id, s.position, s.id", [Ids]),
    {ok, [C#{<<"editable">> => editable(User, C), <<"shortcuts">> => [S || S = #{<<"category_id">> := Cid} <- Shortcuts, Cid =:= Id]}
          || C = #{<<"id">> := Id} <- Cats]}.

editable(User, #{<<"personal">> := true}) -> User =/= undefined;
editable(User, _) -> ana_security:has_role(User, ?ADMIN).

%% Fields: name, company (bool; administrators only), groups ([name]).
-spec create(map(), map()) -> {ok, map()} | {error, binary()}.
create(User = #{username := Who}, F) ->
    Company = maps:get(<<"company">>, F, false) =:= true,
    case Company andalso not ana_security:has_role(User, ?ADMIN) of
        true -> {error, <<"só o administrador cria categorias da empresa"/utf8>>};
        false ->
            Owner = case Company of true -> null; false -> Who end,
            Groups = [G || G <- maps:get(<<"groups">>, F, []), is_binary(G)],
            case ana_db:one("INSERT INTO ana_system.routine_category (name, owner, groups, position, created_by) "
                            "VALUES (btrim($1), $2, $3, COALESCE((SELECT max(position) + 1 FROM ana_system.routine_category "
                            "  WHERE owner IS NOT DISTINCT FROM $2), 0), $4) RETURNING id",
                            [maps:get(<<"name">>, F, <<>>), Owner, Groups, Who]) of
                {ok, #{<<"id">> := Id}} -> {ok, #{id => Id}};
                {error, #{sqlstate := <<"23505">>}} -> {error, <<"já existe uma categoria com esse nome"/utf8>>};
                {error, #{sqlstate := <<"23514">>}} -> {error, <<"o nome da categoria deve ter de 2 a 60 letras">>};
                {error, _} -> {error, <<"não foi possível criar a categoria"/utf8>>}
            end
    end.

-spec update(map(), integer(), map()) -> {ok, map()} | {error, term()}.
update(User, Id, F) ->
    with_category(User, Id, fun() ->
        case ana_db:exec("UPDATE ana_system.routine_category SET name = COALESCE(btrim($2), name), "
                         "groups = COALESCE($3, groups), position = COALESCE($4, position) WHERE id = $1",
                         [Id, maps:get(<<"name">>, F, null), maps:get(<<"groups">>, F, null), maps:get(<<"position">>, F, null)]) of
            {ok, _} -> {ok, #{id => Id}};
            {error, #{sqlstate := <<"23505">>}} -> {error, <<"já existe uma categoria com esse nome"/utf8>>};
            {error, _} -> {error, <<"dados inválidos"/utf8>>}
        end
    end).

-spec delete(map(), integer()) -> {ok, map()} | {error, term()}.
delete(User, Id) ->
    with_category(User, Id, fun() ->
        {ok, _} = ana_db:exec("DELETE FROM ana_system.routine_category WHERE id = $1", [Id]),   % shortcuts go with it, routines stay
        {ok, #{deleted => Id}}
    end).

%% Items: [{program, label?, params?}] — "Copiar para categoria…" with one or more routines.
-spec add_shortcuts(map(), integer(), [map()]) -> {ok, map()} | {error, term()}.
add_shortcuts(User = #{username := Who}, Id, Items) when is_list(Items) ->
    with_category(User, Id, fun() ->
        Rows = [[Id, P, maps:get(<<"label">>, I, null), maps:get(<<"params">>, I, #{}), Who]
                || I = #{<<"program">> := P} <- Items, is_binary(P)],
        case ana_db:transaction(fun(C) ->
                 lists:foreach(fun(R) ->
                     {ok, _} = ana_db:query(C, "INSERT INTO ana_system.routine_shortcut (category_id, program, label, params, position, created_by) "
                                               "SELECT $1, $2, NULLIF(btrim($3), ''), $4, COALESCE((SELECT max(position) + 1 FROM "
                                               "ana_system.routine_shortcut WHERE category_id = $1), 0), $5 "
                                               "WHERE NOT EXISTS (SELECT 1 FROM ana_system.routine_shortcut WHERE category_id = $1 "
                                               "  AND program = $2 AND params = $4 AND label IS NOT DISTINCT FROM NULLIF(btrim($3), ''))", R)
                 end, Rows),
                 {ok, length(Rows)}
             end) of
            {ok, N} -> {ok, #{added => N}};
            {error, _} -> {error, <<"rotina inexistente ou atalho inválido"/utf8>>}
        end
    end);
add_shortcuts(_, _, _) -> {error, <<"informe as rotinas">>}.

%% Fields: label, params, position, category_id (move to another category the user may change).
-spec update_shortcut(map(), integer(), map()) -> {ok, map()} | {error, term()}.
update_shortcut(User, Id, F) ->
    case ana_db:one("SELECT category_id FROM ana_system.routine_shortcut WHERE id = $1", [Id]) of
        {ok, #{<<"category_id">> := Cat}} ->
            Target = maps:get(<<"category_id">>, F, Cat),
            with_category(User, Cat, fun() ->
                with_category(User, Target, fun() ->
                    {ok, _} = ana_db:exec("UPDATE ana_system.routine_shortcut SET category_id = $2, label = CASE WHEN $3::bool "
                                          "THEN NULLIF(btrim($4), '') ELSE label END, params = COALESCE($5, params), "
                                          "position = COALESCE($6, position) WHERE id = $1",
                                          [Id, Target, maps:is_key(<<"label">>, F), maps:get(<<"label">>, F, null),
                                           maps:get(<<"params">>, F, null), maps:get(<<"position">>, F, null)]),
                    {ok, #{id => Id}}
                end)
            end);
        _ -> {error, not_found}
    end.

-spec delete_shortcut(map(), integer()) -> {ok, map()} | {error, term()}.
delete_shortcut(User, Id) ->
    case ana_db:one("SELECT category_id FROM ana_system.routine_shortcut WHERE id = $1", [Id]) of
        {ok, #{<<"category_id">> := Cat}} ->
            with_category(User, Cat, fun() ->
                {ok, _} = ana_db:exec("DELETE FROM ana_system.routine_shortcut WHERE id = $1", [Id]),
                {ok, #{deleted => Id}}
            end);
        _ -> {error, not_found}
    end.

%% Order of the categories the user may change (dragging on screen): [id] in the new order.
-spec reorder(map(), [integer()]) -> {ok, map()}.
reorder(User, Ids) ->
    Mine = [Id || Id <- Ids, is_integer(Id), may_change(User, Id)],
    {ok, _} = ana_db:exec("UPDATE ana_system.routine_category c SET position = x.pos FROM unnest($1::bigint[]) WITH ORDINALITY "
                          "AS x(id, pos) WHERE c.id = x.id", [Mine]),
    {ok, #{ordered => length(Mine)}}.

with_category(User, Id, Fun) ->
    case may_change(User, Id) of
        true -> Fun();
        false -> {error, <<"categoria inexistente ou sem permissão para alterá-la"/utf8>>}
    end.

may_change(User = #{username := Who}, Id) ->
    case ana_db:one("SELECT owner FROM ana_system.routine_category WHERE id = $1", [Id]) of
        {ok, #{<<"owner">> := null}} -> ana_security:has_role(User, ?ADMIN);
        {ok, #{<<"owner">> := Who}} -> true;
        _ -> false
    end.
