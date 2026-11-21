%% SPDX-FileCopyrightText: 2026 André Luis Pereira dos Santos
%% SPDX-License-Identifier: AGPL-3.0-or-later
%% Spec 050 (D5, RF-050-05): the standard undo of reversible routines.
%%
%% A routine offers its undo with ana.offer_undo(program, params, label, seconds). The offer is written only once
%% what it undoes is committed (never an offer of something that was not kept) and comes back in the answer of the
%% run. POST /api/undo/:id takes it — only its user, once, within its time — and runs the routine that undoes as an
%% ordinary execution (permission, license, audit and validation as always). The parameters come from the offer kept
%% on the server, never from the screen. The offer is written right after the COMMIT of what it undoes.
-module(ana_undo).

-export([check_offer/3, record/3, run/2]).

-define(MIN_S, 5).
-define(MAX_S, 600).
-define(DEFAULT_S, 30).
-define(MAX_PARAMS, 65536).

%% The arguments of ana.offer_undo, checked while the routine runs (a mistake is the routine's, said right away).
-spec check_offer(map(), binary(), map()) -> {ok, map()} | {error, binary(), binary()}.
check_offer(A, Prog, User) ->
    Undo = maps:get(<<"program">>, A, null),
    Params = case maps:get(<<"params">>, A, null) of null -> #{}; P -> P end,
    Label = case maps:get(<<"label">>, A, null) of
        null -> null;
        L when is_binary(L) -> string:trim(L);
        _ -> bad
    end,
    Seconds = maps:get(<<"seconds">>, A, ?DEFAULT_S),
    if
        not is_binary(Undo) ->
            {error, <<"INVALID_UNDO">>, <<"offer_undo: informe a rotina que desfaz"/utf8>>};
        not is_map(Params) ->
            {error, <<"INVALID_UNDO">>, <<"offer_undo: os parâmetros devem ser um dicionário"/utf8>>};
        Label =:= bad ->
            {error, <<"INVALID_UNDO">>, <<"offer_undo: o texto deve ser uma frase"/utf8>>};
        not is_integer(Seconds); Seconds < ?MIN_S; Seconds > ?MAX_S ->
            {error, <<"INVALID_UNDO">>, <<"offer_undo: o prazo vai de 5 a 600 segundos"/utf8>>};
        true ->
            Encoded = iolist_to_binary(json:encode(Params)),
            Text = case Label of
                null -> <<"Desfazer"/utf8>>;
                <<>> -> <<"Desfazer"/utf8>>;
                _ -> unicode:characters_to_binary(string:slice(Label, 0, 200))
            end,
            case byte_size(Encoded) =< ?MAX_PARAMS of
                false -> {error, <<"INVALID_UNDO">>, <<"offer_undo: parâmetros grandes demais"/utf8>>};
                true ->
                    %% The routine that undoes must exist and be runnable by this user now (else the button would lie).
                    case ana_execution:can_run(Undo, User) of
                        true -> {ok, #{program => Prog, undo => Undo, params => Encoded, label => Text, seconds => Seconds}};
                        false -> {error, <<"INVALID_UNDO">>,
                                  <<"offer_undo: a rotina que desfaz não existe ou este usuário não pode executá-la"/utf8>>}
                    end
            end
    end.

%% Written right after the routine's COMMIT, on the core's own pool (programs never write ana_system): an offer exists
%% only for what was kept. Should it fail, the routine stays done and simply offers no undo.
-spec record(binary(), map(), map()) -> {ok, map()} | {error, term()}.
record(ExecId, #{username := Who}, #{program := Prog, undo := Undo, params := Params, label := Label, seconds := S}) ->
    Id = ana_execution:new_id(),
    case ana_db:exec("INSERT INTO ana_system.undo_offer (id, execution_id, username, program, undo_program, params, "
                     "label, expires_at) VALUES ($1::text::uuid, $2::text::uuid, $3, $4, $5, $6::text::jsonb, $7, "
                     "now() + make_interval(secs => $8::int))",
                     [Id, ExecId, Who, Prog, Undo, Params, Label, S]) of
        {ok, 1} -> {ok, #{id => Id, label => Label, seconds => S}};
        Other -> {error, Other}
    end.

%% POST /api/undo/:id — taken before running (two clicks never undo twice), given back if the undo fails.
-spec run(binary(), map()) -> {ok, map()} | {error, integer(), binary(), binary()} | {error, map()}.
run(Id, User = #{username := Who}) ->
    case is_uuid(Id) of
        false -> {error, 404, <<"UNDO_NOT_FOUND">>, <<"nada a desfazer"/utf8>>};
        true ->
            case ana_db:rows("UPDATE ana_system.undo_offer SET used_at = now() "
                             "WHERE id = $1::text::uuid AND username = $2 AND used_at IS NULL AND expires_at > now() "
                             "RETURNING undo_program, params::text AS params, label", [Id, Who]) of
                {ok, [#{<<"undo_program">> := Prog, <<"params">> := P, <<"label">> := Label}]} ->
                    Params = json:decode(P),
                    case ana_execution:run(Prog, Params, User, #{origin => <<"studio">>}) of
                        {ok, Res} ->
                            ExecId = maps:get(id, Res, null),
                            _ = ana_db:exec("UPDATE ana_system.undo_offer SET undo_execution = $2::text::uuid "
                                            "WHERE id = $1::text::uuid", [Id, ExecId]),
                            {ok, Res#{undone => Label}};
                        {error, E} ->
                            _ = ana_db:exec("UPDATE ana_system.undo_offer SET used_at = NULL WHERE id = $1::text::uuid",
                                            [Id]),
                            {error, E}
                    end;
                {ok, []} -> why_not(Id, Who);
                {error, _} -> {error, 503, <<"DB_UNAVAILABLE">>, <<"banco de dados indisponível"/utf8>>}
            end
    end.

why_not(Id, Who) ->
    case ana_db:rows("SELECT used_at IS NOT NULL AS used FROM ana_system.undo_offer "
                     "WHERE id = $1::text::uuid AND username = $2", [Id, Who]) of
        {ok, [#{<<"used">> := true}]} -> {error, 409, <<"UNDO_USED">>, <<"isto já foi desfeito"/utf8>>};
        {ok, [_]} -> {error, 410, <<"UNDO_EXPIRED">>, <<"o prazo para desfazer terminou"/utf8>>};
        _ -> {error, 404, <<"UNDO_NOT_FOUND">>, <<"nada a desfazer"/utf8>>}
    end.

is_uuid(B) when is_binary(B), byte_size(B) =:= 36 ->
    re:run(B, "^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$") =/= nomatch;
is_uuid(_) -> false.
