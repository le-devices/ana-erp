%% SPDX-FileCopyrightText: 2026 André Luis Pereira dos Santos
%% SPDX-License-Identifier: AGPL-3.0-or-later
%% What each person leaves on a screen (spec 020, RF-020-17/18): table variants (columns, order, sorting,
%% filters; named, one default per screen) and screen settings (dividers, collapsed panels, pinned header).
%% Only the owner reads and changes them; sizes and counts are bounded so a client cannot fill the database.
-module(ana_ui_state).
-export([variants/2, save_variant/2, delete_variant/2, settings/1, put_setting/3]).

-define(MAX_VARIANTS, 30).     % per user and screen
-define(MAX_SETTINGS, 500).    % per user

-spec variants(map(), binary()) -> {ok, [map()]}.
variants(#{username := Who}, Screen) ->
    ana_db:rows("SELECT id, name, is_default, state, updated_at FROM ana_system.ui_variant "
                "WHERE username = $1 AND screen = $2 ORDER BY is_default DESC, lower(name)", [Who, Screen]).

%% Fields: screen, name, state (object), default (bool). Same name = replaces that variant.
-spec save_variant(map(), map()) -> {ok, map()} | {error, binary()}.
save_variant(#{username := Who}, #{<<"screen">> := Screen, <<"name">> := Name, <<"state">> := State} = F)
  when is_binary(Screen), is_binary(Name), is_map(State) ->
    Default = maps:get(<<"default">>, F, false) =:= true,
    Result = ana_db:transaction(fun(C) ->
        {ok, [#{<<"n">> := N}]} = ana_db:rows(C, "SELECT count(*) AS n FROM ana_system.ui_variant WHERE username = $1 "
                                                  "AND screen = $2 AND lower(btrim(name)) <> lower(btrim($3))", [Who, Screen, Name]),
        case N >= ?MAX_VARIANTS of
            true -> {error, too_many};
            false ->
                Default andalso ana_db:rows(C, "UPDATE ana_system.ui_variant SET is_default = false "
                                                "WHERE username = $1 AND screen = $2 AND is_default", [Who, Screen]),
                case ana_db:rows(C, "INSERT INTO ana_system.ui_variant AS v (username, screen, name, is_default, state) "
                                    "VALUES ($1, $2, btrim($3), $4, $5) "
                                    "ON CONFLICT (username, screen, lower(btrim(name))) DO UPDATE SET state = EXCLUDED.state, "
                                    "is_default = EXCLUDED.is_default OR v.is_default, updated_at = now() RETURNING v.id",
                                 [Who, Screen, Name, Default, State]) of
                    {ok, [#{<<"id">> := Id}]} -> {ok, Id};
                    {error, _} = E -> E          % name or size out of bounds: rolled back
                end
        end
    end),
    case Result of
        {ok, Id} -> {ok, #{id => Id}};
        {error, too_many} -> {error, <<"limite de variantes nesta tela atingido; exclua uma antes"/utf8>>};
        {error, _} -> {error, <<"variante inválida (nome de 1 a 60 letras, até 16 KB)"/utf8>>}
    end;
save_variant(_, _) -> {error, <<"informe tela, nome e estado"/utf8>>}.

-spec delete_variant(map(), integer()) -> {ok, map()} | {error, not_found}.
delete_variant(#{username := Who}, Id) ->
    case ana_db:exec("DELETE FROM ana_system.ui_variant WHERE id = $1 AND username = $2", [Id, Who]) of
        {ok, 1} -> {ok, #{deleted => Id}};
        _ -> {error, not_found}
    end.

%% All settings of the user as one object (loaded once when the Studio opens).
-spec settings(map()) -> {ok, map()}.
settings(#{username := Who}) ->
    {ok, Rows} = ana_db:rows("SELECT key, value FROM ana_system.ui_setting WHERE username = $1", [Who]),
    {ok, maps:from_list([{K, V} || #{<<"key">> := K, <<"value">> := V} <- Rows])}.

%% value null = forget the setting.
-spec put_setting(map(), binary(), term()) -> {ok, map()} | {error, binary()}.
put_setting(#{username := Who}, Key, null) when is_binary(Key) ->
    {ok, _} = ana_db:exec("DELETE FROM ana_system.ui_setting WHERE username = $1 AND key = $2", [Who, Key]),
    {ok, #{key => Key}};
put_setting(#{username := Who}, Key, Value) when is_binary(Key) ->
    case ana_db:exec("INSERT INTO ana_system.ui_setting (username, key, value) "
                     "SELECT $1, $2, $3 WHERE (SELECT count(*) FROM ana_system.ui_setting WHERE username = $1 AND key <> $2) < $4 "
                     "ON CONFLICT (username, key) DO UPDATE SET value = EXCLUDED.value, updated_at = now()",
                     [Who, Key, iolist_to_binary(json:encode(Value)), ?MAX_SETTINGS]) of
        {ok, 1} -> {ok, #{key => Key}};
        {ok, 0} -> {error, <<"limite de preferências de tela atingido"/utf8>>};
        {error, _} -> {error, <<"preferência inválida (chave até 200 letras, valor até 4 KB)"/utf8>>}
    end;
put_setting(_, _, _) -> {error, <<"informe a chave"/utf8>>}.
