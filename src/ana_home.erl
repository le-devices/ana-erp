%% SPDX-FileCopyrightText: 2026 André Luis Pereira dos Santos
%% SPDX-License-Identifier: AGPL-3.0-or-later
%% Home panel (spec 048): the company's spaces of blocks, published by access group, and the indicators on them.
%%
%% - A user sees the spaces of their groups (a space without groups is everyone's); a block only when they may run
%%   the routine it opens, and its number only when they may run its indicator (D2).
%% - An indicator (a program marked "# ana:indicator <seconds>") runs as the user, read-only and for a few seconds
%%   (ana_execution); its answer is cached in memory on this node, per user and block, for those seconds — nothing
%%   is written to disk (P15). One that fails says "indisponível" and the panel goes on (CA-048-05).
%% - Administrators edit the spaces and see "how user X sees it" with the same rules applied to X.
-module(ana_home).

-export([init_cache/0, spaces/1, preview/1, indicator/3, all/0,
         save_space/3, delete_space/2, save_block/4, delete_block/2, ensure_product_blocks/0]).

-define(TAB, ana_home_cache).
-define(MIN_FRESH_MS, 10000).          % "Atualizar" asks again at most once every 10 s per user and block
-define(FAILED_TTL_MS, 30000).         % a failure is remembered for 30 s (the panel does not hammer a broken program)
-define(SIZES, [<<"small">>, <<"medium">>, <<"wide">>]).
-define(STATUSES, [<<"ok">>, <<"warning">>, <<"critical">>]).

-spec init_cache() -> ok.
init_cache() ->
    _ = ets:new(?TAB, [named_table, public, set, {read_concurrency, true}]),
    ok.

%% ------------------------------------------------------------------ what a user sees

-spec spaces(map()) -> {ok, [map()]} | {error, integer(), binary(), binary()}.
spaces(User = #{username := Who}) ->
    case {space_rows(), block_rows()} of
        {{ok, Spaces}, {ok, Blocks}} ->
            Groups = ana_access:groups(Who),
            {ok, [S#{<<"blocks">> => [view(B, User) || B <- Blocks, maps:get(<<"space_id">>, B) =:= maps:get(<<"id">>, S),
                                                      ana_execution:can_run(maps:get(<<"program">>, B), User)]}
                  || S <- Spaces, sees(S, Groups)]};
        _ -> {error, 503, <<"DB_UNAVAILABLE">>, <<"banco de dados indisponível"/utf8>>}
    end.

%% RF-048-02: "como o usuário X vê" — the same rules, applied to X.
-spec preview(binary()) -> {ok, map()} | {error, integer(), binary(), binary()}.
preview(As) ->
    case ana_db:one("SELECT username, role, name FROM ana_system.app_user WHERE username = $1 AND active", [As]) of
        {ok, #{<<"username">> := U, <<"role">> := R} = Row} ->
            User = #{username => U, role => R, name => maps:get(<<"name">>, Row, <<>>)},
            case spaces(User) of
                {ok, S} -> {ok, #{user => U, spaces => S}};
                E -> E
            end;
        _ -> {error, 404, <<"USER_NOT_FOUND">>, <<"usuário inexistente ou inativo"/utf8>>}
    end.

sees(#{<<"access_groups">> := []}, _) -> true;
sees(#{<<"access_groups">> := Gs}, Mine) -> lists:any(fun(G) -> lists:member(G, Mine) end, Gs).

view(B, User) ->
    Ind = maps:get(<<"indicator">>, B),
    Shown = Ind =/= null andalso ana_execution:can_run(Ind, User),
    maps:without([<<"indicator_params">>], B#{<<"indicator">> => case Shown of true -> Ind; false -> null end,
                                              <<"refresh_s">> => case Shown of true -> maps:get(<<"refresh_s">>, B); false -> null end}).

space_rows() ->
    ana_db:rows("SELECT id, name, description, position, access_groups FROM ana_system.home_space "
                "ORDER BY position, lower(name)", []).

block_rows() ->
    ana_db:rows("SELECT b.id, b.space_id, b.position, b.title, b.program, b.variant_id, v.name AS variant_name, b.params, "
                "       b.indicator, b.indicator_params, b.size, p.indicator_refresh_s AS refresh_s "
                "FROM ana_system.home_block b "
                "LEFT JOIN ana_system.program p ON p.name = b.indicator "
                "LEFT JOIN ana_system.run_variant v ON v.id = b.variant_id "
                "ORDER BY b.space_id, b.position, b.id", []).

%% ------------------------------------------------------------------ indicators

%% The block's indicator, as this user — cached for the indicator's seconds; Fresh asks again (at most every 10 s).
-spec indicator(map(), integer(), boolean()) -> {ok, map()} | {error, integer(), binary(), binary()}.
indicator(User = #{username := Who}, BlockId, Fresh) ->
    case visible_block(User, BlockId) of
        {ok, #{<<"indicator">> := Ind, <<"indicator_params">> := Params, <<"refresh_s">> := Refresh}} when Ind =/= null ->
            Now = erlang:system_time(millisecond),
            Key = {Who, BlockId},
            case ets:lookup(?TAB, Key) of
                [{_, Answer, At, Until}] when Now < Until, not Fresh; Now - At < ?MIN_FRESH_MS ->
                    {ok, Answer#{cached => true}};
                _ ->
                    {Answer, Ttl} = run_indicator(Ind, Params, User, Refresh),
                    true = ets:insert(?TAB, {Key, Answer, Now, Now + Ttl}),
                    {ok, Answer#{cached => false}}
            end;
        {ok, _} -> {error, 404, <<"NO_INDICATOR">>, <<"este bloco não tem indicador"/utf8>>};
        E -> E
    end.

visible_block(User = #{username := Who}, BlockId) ->
    case ana_db:one("SELECT b.space_id, b.program, b.indicator, b.indicator_params, p.indicator_refresh_s AS refresh_s, "
                    "       s.access_groups FROM ana_system.home_block b "
                    "JOIN ana_system.home_space s ON s.id = b.space_id "
                    "LEFT JOIN ana_system.program p ON p.name = b.indicator WHERE b.id = $1", [BlockId]) of
        {ok, #{<<"program">> := Prog, <<"indicator">> := Ind} = B} ->
            Ok = sees(B, ana_access:groups(Who)) andalso ana_execution:can_run(Prog, User)
                 andalso (Ind =:= null orelse ana_execution:can_run(Ind, User)),
            case Ok of
                true -> {ok, B};
                false -> not_found()
            end;
        {ok, _} -> not_found();
        {error, _} -> {error, 503, <<"DB_UNAVAILABLE">>, <<"banco de dados indisponível"/utf8>>}
    end.

not_found() -> {error, 404, <<"BLOCK_NOT_FOUND">>, <<"bloco não encontrado"/utf8>>}.

run_indicator(Ind, Params, User, Refresh) ->
    At = iso_now(),
    case ana_execution:run(Ind, Params, User, #{origin => <<"studio">>}) of
        {ok, #{result := R}} ->
            case answer(R) of
                {ok, A} -> {A#{at => At, refresh_s => Refresh}, Refresh * 1000};
                error -> {unavailable(<<"o indicador não respondeu no formato {value, status, text}"/utf8>>, At), ?FAILED_TTL_MS}
            end;
        {error, E} when is_map(E) ->
            {unavailable(maps:get(<<"message">>, E, <<"falhou"/utf8>>), At), ?FAILED_TTL_MS};
        _ ->
            {unavailable(<<"falhou"/utf8>>, At), ?FAILED_TTL_MS}
    end.

answer(#{<<"value">> := V} = R) when is_number(V); is_binary(V) ->
    Status = case maps:get(<<"status">>, R, <<"ok">>) of
        S when is_binary(S) -> case lists:member(S, ?STATUSES) of true -> S; false -> <<"ok">> end;
        _ -> <<"ok">>
    end,
    Text = case maps:get(<<"text">>, R, <<>>) of
        T when is_binary(T) -> unicode:characters_to_binary(string:slice(T, 0, 140));
        _ -> <<>>
    end,
    {ok, #{value => V, status => Status, text => Text}};
answer(_) -> error.

unavailable(Why, At) ->
    #{value => null, status => <<"unavailable">>, text => <<"indisponível"/utf8>>,
      reason => unicode:characters_to_binary(string:slice(Why, 0, 200)), at => At}.

iso_now() ->
    list_to_binary(calendar:system_time_to_rfc3339(erlang:system_time(second), [{offset, "Z"}])).

%% ------------------------------------------------------------------ editor (administrators)

-spec all() -> {ok, map()} | {error, integer(), binary(), binary()}.
all() ->
    case {space_rows(), block_rows(),
          ana_db:rows("SELECT name, description, indicator_refresh_s AS refresh_s FROM ana_system.program "
                      "WHERE indicator_refresh_s IS NOT NULL AND active ORDER BY name", []),
          ana_db:rows("SELECT name, description FROM ana_system.access_group ORDER BY name", [])} of
        {{ok, S}, {ok, B}, {ok, I}, {ok, G}} ->
            {ok, #{spaces => [X#{<<"blocks">> => [Y || Y <- B, maps:get(<<"space_id">>, Y) =:= maps:get(<<"id">>, X)]} || X <- S],
                   indicators => I, groups => G}};
        _ -> {error, 503, <<"DB_UNAVAILABLE">>, <<"banco de dados indisponível"/utf8>>}
    end.

-spec save_space(new | integer(), map(), map()) -> {ok, map()} | {error, integer(), binary(), binary()}.
save_space(Id, Body, #{username := Who}) ->
    Name = trim(maps:get(<<"name">>, Body, <<>>)),
    Desc = trim(maps:get(<<"description">>, Body, <<>>)),
    Pos = int(maps:get(<<"position">>, Body, 0)),
    Groups = maps:get(<<"access_groups">>, Body, []),
    if
        byte_size(Name) < 2 -> invalid(<<"dê um nome ao espaço"/utf8>>);
        not is_list(Groups) -> invalid(<<"grupos: uma lista de nomes"/utf8>>);
        true ->
            case unknown_groups(Groups) of
                [] ->
                    Sql = case Id of
                        new -> "INSERT INTO ana_system.home_space (name, description, position, access_groups, updated_by) "
                               "VALUES ($1, $2, $3, $4, $5) RETURNING id";
                        _ -> "UPDATE ana_system.home_space SET name = $1, description = $2, position = $3, "
                             "access_groups = $4, updated_by = $5, updated_at = now() WHERE id = $6 RETURNING id"
                    end,
                    Args = [Name, Desc, Pos, Groups, Who] ++ case Id of new -> []; _ -> [Id] end,
                    case ana_db:rows(Sql, Args) of
                        {ok, [#{<<"id">> := NewId}]} ->
                            ok = ana_admin:log(Who, <<"home.space.save">>, integer_to_binary(NewId), null, Body),
                            {ok, #{id => NewId}};
                        {ok, []} -> {error, 404, <<"SPACE_NOT_FOUND">>, <<"espaço não encontrado"/utf8>>};
                        {error, #{<<"code">> := <<"23505">>}} -> invalid(<<"já existe um espaço com esse nome"/utf8>>);
                        {error, _} -> invalid(<<"espaço inválido"/utf8>>)
                    end;
                Bad -> invalid(<<"grupos inexistentes: "/utf8, (join(Bad))/binary>>)
            end
    end.

-spec delete_space(integer(), map()) -> {ok, map()} | {error, integer(), binary(), binary()}.
delete_space(Id, #{username := Who}) ->
    case ana_db:exec("DELETE FROM ana_system.home_space WHERE id = $1", [Id]) of
        {ok, 1} ->
            ok = ana_admin:log(Who, <<"home.space.delete">>, integer_to_binary(Id), null, null),
            {ok, #{deleted => Id}};
        _ -> {error, 404, <<"SPACE_NOT_FOUND">>, <<"espaço não encontrado"/utf8>>}
    end.

-spec save_block(integer(), new | integer(), map(), map()) -> {ok, map()} | {error, integer(), binary(), binary()}.
save_block(SpaceId, Id, Body, #{username := Who}) ->
    Title = trim(maps:get(<<"title">>, Body, <<>>)),
    Prog = maps:get(<<"program">>, Body, null),
    Variant = maps:get(<<"variant_id">>, Body, null),
    Params = maps:get(<<"params">>, Body, #{}),
    Ind = case maps:get(<<"indicator">>, Body, null) of <<>> -> null; X -> X end,
    IndParams = maps:get(<<"indicator_params">>, Body, #{}),
    Size = maps:get(<<"size">>, Body, <<"medium">>),
    Pos = int(maps:get(<<"position">>, Body, 0)),
    Check = [{byte_size(Title) >= 2, <<"dê um título ao bloco"/utf8>>},
             {is_binary(Prog) andalso routine(Prog), <<"escolha a rotina que o bloco abre"/utf8>>},
             {Variant =:= null orelse company_variant(Variant, Prog),
              <<"a variante precisa ser da empresa, publicada, e da mesma rotina"/utf8>>},
             {Ind =:= null orelse (is_binary(Ind) andalso is_indicator(Ind)),
              <<"o indicador precisa ser um programa marcado com # ana:indicator"/utf8>>},
             {is_map(Params) andalso is_map(IndParams), <<"parâmetros: um objeto"/utf8>>},
             {lists:member(Size, ?SIZES), <<"tamanho: pequeno, médio ou largo"/utf8>>}],
    case [M || {false, M} <- Check] of
        [Msg | _] -> invalid(Msg);
        [] ->
            P = iolist_to_binary(json:encode(Params)),
            IP = iolist_to_binary(json:encode(IndParams)),
            {Sql, Args} = case Id of
                new -> {"INSERT INTO ana_system.home_block (space_id, position, title, program, variant_id, params, indicator, "
                        "indicator_params, size) VALUES ($1, $2, $3, $4, $5, $6::text::jsonb, $7, $8::text::jsonb, $9) RETURNING id",
                        [SpaceId, Pos, Title, Prog, Variant, P, Ind, IP, Size]};
                _ -> {"UPDATE ana_system.home_block SET position = $2, title = $3, program = $4, variant_id = $5, "
                      "params = $6::text::jsonb, indicator = $7, indicator_params = $8::text::jsonb, size = $9 "
                      "WHERE id = $10 AND space_id = $1 RETURNING id",
                      [SpaceId, Pos, Title, Prog, Variant, P, Ind, IP, Size, Id]}
            end,
            case ana_db:rows(Sql, Args) of
                {ok, [#{<<"id">> := NewId}]} ->
                    forget(NewId),
                    ok = ana_admin:log(Who, <<"home.block.save">>, integer_to_binary(NewId), null, Body),
                    {ok, #{id => NewId}};
                {ok, []} -> {error, 404, <<"BLOCK_NOT_FOUND">>, <<"bloco não encontrado"/utf8>>};
                {error, _} -> invalid(<<"bloco inválido (o espaço existe?)"/utf8>>)
            end
    end.

-spec delete_block(integer(), map()) -> {ok, map()} | {error, integer(), binary(), binary()}.
delete_block(Id, #{username := Who}) ->
    case ana_db:exec("DELETE FROM ana_system.home_block WHERE id = $1", [Id]) of
        {ok, 1} ->
            forget(Id),
            ok = ana_admin:log(Who, <<"home.block.delete">>, integer_to_binary(Id), null, null),
            {ok, #{deleted => Id}};
        _ -> {error, 404, <<"BLOCK_NOT_FOUND">>, <<"bloco não encontrado"/utf8>>}
    end.

forget(BlockId) ->
    _ = ets:match_delete(?TAB, {{'_', BlockId}, '_', '_', '_'}),
    ok.

routine(Name) ->
    case ana_db:one("SELECT 1 AS ok FROM ana_system.program WHERE name = $1 AND kind = 'program' AND active", [Name]) of
        {ok, #{<<"ok">> := 1}} -> true;
        _ -> false
    end.

is_indicator(Name) ->
    case ana_db:one("SELECT 1 AS ok FROM ana_system.program WHERE name = $1 AND indicator_refresh_s IS NOT NULL AND active",
                    [Name]) of
        {ok, #{<<"ok">> := 1}} -> true;
        _ -> false
    end.

company_variant(Id, Prog) when is_integer(Id) ->
    case ana_db:one("SELECT 1 AS ok FROM ana_system.run_variant WHERE id = $1 AND program = $2 AND owner IS NULL "
                    "AND published", [Id, Prog]) of
        {ok, #{<<"ok">> := 1}} -> true;
        _ -> false
    end;
company_variant(_, _) -> false.

unknown_groups(Gs) ->
    case lists:all(fun is_binary/1, Gs) of
        false -> [<<"?">>];
        true ->
            {ok, Rows} = ana_db:rows("SELECT g FROM unnest($1::text[]) g WHERE NOT EXISTS "
                                     "(SELECT 1 FROM ana_system.access_group a WHERE a.name = g)", [Gs]),
            [G || #{<<"g">> := G} <- Rows]
    end.

invalid(Msg) -> {error, 422, <<"INVALID">>, Msg}.
trim(B) when is_binary(B) -> string:trim(B);
trim(_) -> <<>>.
int(N) when is_integer(N) -> N;
int(_) -> 0.
join(Bs) -> iolist_to_binary(lists:join(<<", ">>, Bs)).

%% ------------------------------------------------------------------ the product's space

%% The product's blocks of "Visão geral", added once — never again if the company removes them.
-spec ensure_product_blocks() -> {ok, binary()}.
ensure_product_blocks() ->
    case ana_db:one("SELECT id FROM ana_system.home_space WHERE name = $1 AND NOT product_blocks", [<<"Visão geral"/utf8>>]) of
        {ok, #{<<"id">> := Space}} ->
            Blocks = [{1, <<"Pedidos com falta">>, <<"sales.shortages">>, <<"sales.indicator_shortages">>},
                      {2, <<"Títulos vencidos"/utf8>>, <<"finance.credit_report">>, <<"finance.indicator_overdue">>},
                      {3, <<"Compras a aprovar">>, <<"supply.workbench">>, <<"supply.indicator_approvals">>}],
            N = length([ok || {Pos, Title, Prog, Ind} <- Blocks, routine(Prog), is_indicator(Ind),
                              {ok, 1} =:= ana_db:exec("INSERT INTO ana_system.home_block (space_id, position, title, program, "
                                                      "indicator) VALUES ($1, $2, $3, $4, $5)", [Space, Pos, Title, Prog, Ind])]),
            _ = ana_db:exec("UPDATE ana_system.home_space SET product_blocks = true WHERE id = $1", [Space]),
            {ok, unicode:characters_to_binary(io_lib:format("~b bloco(s) do produto no painel", [N]))};
        _ -> {ok, <<"nada a fazer">>}
    end.
