%% SPDX-FileCopyrightText: 2026 André Luis Pereira dos Santos
%% SPDX-License-Identifier: AGPL-3.0-or-later
%% Execution variants (spec 045): named parameters of a routine, kept on the server.
%%
%% Personal (only the owner sees) or the company's (published by who may, read-only for the others, D1). Each
%% parameter is a fixed value, an expression of the closed list or a company value (spec 065), resolved at the
%% moment of the run (D2). Fields may be locked or hidden — the user does not change them on screen, through the
%% API or in a schedule (D3, RNF-045-01: the run still has only the user's permissions). A default per user, and the
%% company's otherwise (D4). The program changed? A parameter that no longer exists is left out with a warning; one
%% whose type no longer fits makes the variant invalid with the reason — it never runs with a wrong value (D6).
-module(ana_variants).

-export([list/2, save/3, delete/3, act/4, preview/3, apply/4, validate_program/1, can_publish/2]).

-define(MAX_PER_ROUTINE, 200).

%% ======================================================================= reading

-spec list(binary(), map()) -> {ok, map()} | {error, binary(), binary()}.
list(Program, User = #{username := Who}) ->
    case decl(Program) of
        {error, _, _} = E -> E;
        {ok, _} ->
            Pub = can_publish(User, Program),
            {ok, Rows} = ana_db:rows(
                "SELECT id, name, owner, published, company_default, entries, locked, hidden, status, status_reason, version, "
                "previous IS NOT NULL AS has_previous, updated_by, updated_at FROM ana_system.run_variant "
                "WHERE program = $1 AND (owner = $2 OR (owner IS NULL AND (published OR $3))) "
                "ORDER BY owner IS NULL, lower(name)", [Program, Who, Pub]),
            Mine = case ana_db:one("SELECT variant_id FROM ana_system.run_variant_default WHERE username = $1 AND program = $2",
                                   [Who, Program]) of
                {ok, #{<<"variant_id">> := V}} -> V;
                _ -> null
            end,
            Visible = [maps:get(<<"id">>, R) || R <- Rows],
            Company = case [I || #{<<"id">> := I, <<"company_default">> := true} <- Rows] of [C | _] -> C; [] -> null end,
            Default = case lists:member(Mine, Visible) of true -> Mine; false -> Company end,
            {ok, #{variants => [shown(R) || R <- Rows], default_id => Default, my_default_id => Mine,
                   company_default_id => Company, can_publish => Pub}}
    end.

shown(R) ->
    maps:map(fun(K, V) when K =:= <<"entries">> -> j(V); (_, V) -> V end, R).

%% Resolved values for the screen (the form is filled with them; locked and hidden come along).
-spec preview(binary(), integer(), map()) -> {ok, map()} | {error, binary(), binary()}.
preview(Program, Id, User) ->
    case apply(Program, Id, #{}, User) of
        {ok, Params, Info} -> {ok, Info#{params => Params}};
        E -> E
    end.

%% ======================================================================= running (D2, D3, D6)

%% The parameters of a run with a variant: the variant's values resolved now, the given ones over the free fields.
%% A given value for a locked field must be the variant's own. Ref = id or name (personal first).
-spec apply(binary(), integer() | binary(), map(), map()) -> {ok, map(), map()} | {error, binary(), binary()}.
apply(Program, Ref, Given, #{username := Who}) ->
    case find(Program, Ref, Who) of
        {error, _, _} = E -> E;
        {ok, V = #{<<"status">> := <<"invalid">>}} ->
            {error, <<"VARIANT_INVALID">>, iolist_to_binary([<<"a variante \""/utf8>>, maps:get(<<"name">>, V), <<"\" está inválida: "/utf8>>,
                                                            maps:get(<<"status_reason">>, V, <<>>)])};
        {ok, V} ->
            {ok, Decl} = decl(Program),
            Entries = j(maps:get(<<"entries">>, V)),
            case check(Decl, Entries) of
                {invalid, Why} ->
                    {error, <<"VARIANT_INVALID">>, iolist_to_binary([<<"a variante \""/utf8>>, maps:get(<<"name">>, V), <<"\" não serve mais: "/utf8>>, Why])};
                {ok, Gone} ->
                    Locked = maps:get(<<"locked">>, V) -- Gone,
                    case resolve(maps:without(Gone, Entries), Who) of
                        {error, _, _} = E -> E;
                        {ok, Resolved} ->
                            Conflict = [K || K <- Locked, maps:is_key(K, Given), maps:is_key(K, Resolved),
                                             not same(maps:get(K, Given), maps:get(K, Resolved))],
                            case Conflict of
                                [K | _] ->
                                    {error, <<"VARIANT_LOCKED">>, iolist_to_binary([<<"o campo "/utf8>>, label(Decl, K),
                                                                                   <<" é travado pela variante \""/utf8>>, maps:get(<<"name">>, V), <<"\""/utf8>>])};
                                [] ->
                                    Warnings = [iolist_to_binary([<<"o parâmetro "/utf8>>, G, <<" não existe mais na rotina e foi ignorado"/utf8>>]) || G <- Gone],
                                    Info = #{id => maps:get(<<"id">>, V), name => maps:get(<<"name">>, V), version => maps:get(<<"version">>, V),
                                             scope => case maps:get(<<"owner">>, V) of null -> <<"company">>; _ -> <<"personal">> end,
                                             locked => Locked, hidden => maps:get(<<"hidden">>, V) -- Gone, warnings => Warnings},
                                    {ok, maps:merge(Resolved, maps:without(Locked, Given)), Info}
                            end
                    end
            end
    end.

find(Program, Ref, Who) ->
    {Where, Arg} = case Ref of
        I when is_integer(I) -> {"id = $3", I};
        N when is_binary(N) -> {"lower(btrim(name)) = lower(btrim($3))", N};
        _ -> {"false AND $3::text IS NULL", null}
    end,
    case ana_db:rows(["SELECT id, name, owner, entries, locked, hidden, status, status_reason, version FROM ana_system.run_variant "
                      "WHERE program = $1 AND (owner = $2 OR (owner IS NULL AND published)) AND ", Where,
                      " ORDER BY owner IS NULL LIMIT 1"], [Program, Who, Arg]) of
        {ok, [V]} -> {ok, V};
        {ok, []} -> {error, <<"VARIANT_NOT_FOUND">>, <<"variante não encontrada para esta rotina"/utf8>>};
        {error, #{message := M}} -> {error, <<"INVALID">>, M}
    end.

resolve(Entries, Who) ->
    maps:fold(fun(_, _, {error, _, _} = E) -> E;
                 (K, #{<<"value">> := X}, {ok, Acc}) -> {ok, Acc#{K => X}};
                 (K, #{<<"expr">> := X}, {ok, Acc}) ->
                     case ana_db:one("SELECT ana_system.value_expression($1, NULL, $2, true, $3) AS v",
                                     [X, list_to_binary(ana_config:timezone()), Who]) of
                         {ok, #{<<"v">> := R}} -> {ok, Acc#{K => R}};
                         _ -> {error, <<"VARIANT_INVALID">>, <<"expressão da variante não resolvida: "/utf8, X/binary>>}
                     end;
                 (K, #{<<"company_value">> := N}, {ok, Acc}) ->
                     case ana_values:read(N, #{user => Who}) of
                         {ok, #{value := R}} -> {ok, Acc#{K => R}};
                         {error, Code, M} -> {error, Code, M}
                     end;
                 (_, _, Acc) -> Acc
              end, {ok, #{}}, Entries).

same(A, A) -> true;
same(A, B) -> text(A) =:= text(B).

text(B) when is_binary(B) -> string:trim(B);
text(I) when is_integer(I) -> integer_to_binary(I);
text(F) when is_float(F) -> float_to_binary(F, [short]);
text(true) -> <<"true">>;
text(false) -> <<"false">>;
text(null) -> <<>>;
text(V) -> iolist_to_binary(json:encode(V)).

%% ======================================================================= checking against the program (D6)

decl(Program) ->
    case ana_program:for_execution(Program) of
        {ok, #{<<"kind">> := <<"program">>} = P} -> {ok, j(maps:get(<<"params">>, P, null))};
        {ok, _} -> {error, <<"NOT_EXECUTABLE">>, <<"só rotinas têm variantes"/utf8>>};
        _ -> {error, <<"PROGRAM_NOT_FOUND">>, <<"rotina não encontrada"/utf8>>}
    end.

%% {ok, ParamsThatNoLongerExist} | {invalid, Why}
check(Decl, Entries) when is_map(Decl) ->
    Gone = [K || K <- maps:keys(Entries), not maps:is_key(K, Decl)],
    Bad = [{K, W} || {K, E} <- maps:to_list(maps:without(Gone, Entries)),
                     W <- [fits(param_type(maps:get(K, Decl)), E)], W =/= ok],
    case Bad of
        [] -> {ok, Gone};
        [{K, W} | _] -> {invalid, iolist_to_binary([label(Decl, K), <<": "/utf8>>, W])}
    end;
check(_, _) -> {ok, []}.                                       % a program without PARAMS takes anything

param_type(Spec) when is_map(Spec) -> maps:get(<<"type">>, Spec, <<"str">>);
param_type(_) -> <<"str">>.

label(Decl, K) when is_map(Decl) ->
    case maps:get(K, Decl, null) of
        #{<<"label">> := L} when is_binary(L) -> L;
        _ -> K
    end;
label(_, K) -> K.

fits(T, #{<<"value">> := V}) ->
    case value_fits(T, V) of
        true -> ok;
        false -> <<"o valor guardado não é do tipo "/utf8, (type_name(T))/binary>>
    end;
fits(T, #{<<"expr">> := X}) ->
    Tok = hd(binary:split(X, [<<"+">>, <<"-">>])),
    case ana_db:one("SELECT result_type FROM base.value_expressions() WHERE token = $1", [Tok]) of
        {ok, #{<<"result_type">> := R}} ->
            Ok = case R of
                <<"date">> -> [<<"date">>, <<"str">>];
                <<"datetime">> -> [<<"datetime">>, <<"str">>];
                _ -> [<<"str">>]
            end,
            case lists:member(T, Ok) of
                true -> ok;
                false -> <<"a expressão não dá um valor do tipo "/utf8, (type_name(T))/binary>>
            end;
        _ -> <<"expressão fora da lista"/utf8>>
    end;
fits(T, #{<<"company_value">> := N}) ->
    case ana_db:one("SELECT value_type, shape FROM ana_system.company_value WHERE name = $1", [N]) of
        {ok, #{<<"value_type">> := VT, <<"shape">> := S}} ->
            Ok = case {S, VT} of
                {<<"list">>, _} -> [<<"list">>];
                {<<"selection">>, _} -> [<<"dict">>];
                {_, <<"integer">>} -> [<<"int">>, <<"decimal">>, <<"float">>, <<"str">>];
                {_, <<"decimal">>} -> [<<"decimal">>, <<"float">>, <<"str">>];
                {_, <<"date">>} -> [<<"date">>, <<"str">>];
                {_, <<"boolean">>} -> [<<"bool">>];
                _ -> [<<"str">>]
            end,
            case lists:member(T, Ok) of
                true -> ok;
                false -> <<"o valor da empresa "/utf8, N/binary, <<" não é do tipo "/utf8>>/binary, (type_name(T))/binary>>
            end;
        _ -> <<"valor da empresa inexistente: "/utf8, N/binary>>
    end;
fits(_, _) -> <<"entrada inválida"/utf8>>.

value_fits(_, null) -> true;
value_fits(<<"int">>, V) -> is_integer(V) orelse (is_binary(V) andalso re:run(V, <<"^\\s*-?[0-9]+\\s*$">>, [{capture, none}]) =:= match);
value_fits(T, V) when T =:= <<"float">>; T =:= <<"decimal">> ->
    is_number(V) orelse (is_binary(V) andalso re:run(V, <<"^\\s*-?[0-9.]*[0-9](,[0-9]+)?\\s*$">>, [{capture, none}]) =:= match);
value_fits(<<"bool">>, V) -> is_boolean(V);
value_fits(<<"date">>, V) -> is_binary(V) andalso re:run(V, <<"^[0-9]{4}-[0-9]{2}-[0-9]{2}$">>, [{capture, none}]) =:= match;
value_fits(T, V) when T =:= <<"datetime">>; T =:= <<"time">> -> is_binary(V);
value_fits(<<"list">>, V) -> is_list(V);
value_fits(<<"dict">>, V) -> is_map(V);
value_fits(<<"condition">>, V) -> is_list(V) orelse is_map(V);
value_fits(<<"str">>, V) -> is_binary(V) orelse is_number(V);
value_fits(_, _) -> true.

type_name(T) ->
    maps:get(T, #{<<"int">> => <<"número inteiro"/utf8>>, <<"float">> => <<"número"/utf8>>, <<"decimal">> => <<"decimal">>,
                  <<"str">> => <<"texto">>, <<"bool">> => <<"sim/não"/utf8>>, <<"date">> => <<"data">>,
                  <<"datetime">> => <<"data e hora">>, <<"time">> => <<"hora">>, <<"list">> => <<"lista">>,
                  <<"dict">> => <<"objeto">>, <<"condition">> => <<"condição"/utf8>>}, T).

%% After a program is saved or the product updated (RF-045-07): each variant is marked valid or invalid, with the
%% reason. Written only when it changes (P15).
-spec validate_program(binary()) -> ok.
validate_program(Program) ->
    case decl(Program) of
        {ok, Decl} ->
            case ana_db:rows("SELECT id, entries, status, status_reason FROM ana_system.run_variant WHERE program = $1", [Program]) of
                {ok, Rows} ->
                    _ = [ana_db:exec("UPDATE ana_system.run_variant SET status = $2, status_reason = $3 WHERE id = $1", [Id, S, W])
                         || #{<<"id">> := Id, <<"entries">> := E, <<"status">> := S0, <<"status_reason">> := W0} <- Rows,
                            {S, W} <- [case check(Decl, j(E)) of
                                           {ok, []} -> {<<"valid">>, null};
                                           {ok, Gone} -> {<<"valid">>, iolist_to_binary([<<"ignora: "/utf8>>, lists:join(<<", ">>, Gone)])};
                                           {invalid, Why} -> {<<"invalid">>, Why}
                                       end],
                            {S, W} =/= {S0, W0}],
                    ok;
                _ -> ok
            end;
        _ -> ok
    end.

%% ======================================================================= keeping (D1, D4)

%% Administrators, and groups with the program or "prefix.*" among "Variantes da empresa que publicam".
-spec can_publish(map(), binary()) -> boolean().
can_publish(#{role := <<"admin">>}, _) -> true;
can_publish(#{username := U}, Program) ->
    case ana_db:rows("SELECT DISTINCT p FROM ana_system.user_group ug JOIN ana_system.access_group g ON g.name = ug.group_name, "
                     "unnest(g.variant_patterns) p WHERE ug.username = $1", [U]) of
        {ok, Rows} -> lists:any(fun(#{<<"p">> := P}) -> ana_access:matches(P, Program) end, Rows);
        _ -> false
    end;
can_publish(_, _) -> false.

%% Create (no id) or change a variant. Scope "company" needs the permission to publish; a change to a company
%% variant keeps the version before (RF-045-02).
-spec save(binary(), map(), map()) -> {ok, map()} | {error, binary(), binary()}.
save(Program, B, User = #{username := Who}) ->
    Name = string:trim(maps:get(<<"name">>, B, <<>>)),
    Company = maps:get(<<"scope">>, B, <<"personal">>) =:= <<"company">>,
    Entries = maps:get(<<"entries">>, B, #{}),
    Hidden = maps:get(<<"hidden">>, B, []),
    Locked = lists:usort(maps:get(<<"locked">>, B, []) ++ (if is_list(Hidden) -> Hidden; true -> [] end)),
    Id = maps:get(<<"id">>, B, null),
    case decl(Program) of
        {error, _, _} = E -> E;
        {ok, Decl} ->
            Pre = [{string:length(Name) >= 2 andalso string:length(Name) =< 80, <<"dê um nome à variante (2 a 80 caracteres)"/utf8>>},
                   {is_map(Entries) andalso maps:size(Entries) > 0 andalso
                    lists:all(fun(E) -> is_map(E) andalso maps:size(E) =:= 1 andalso
                                        lists:member(hd(maps:keys(E)), [<<"value">>, <<"expr">>, <<"company_value">>]) end,
                              maps:values(Entries)),
                    <<"a variante guarda pelo menos um campo, cada um com valor fixo, expressão ou valor da empresa"/utf8>>},
                   {is_list(Hidden) andalso lists:all(fun(K) -> is_map(Entries) andalso maps:is_key(K, Entries) end, Locked),
                    <<"só se trava ou oculta um campo que a variante preenche"/utf8>>},
                   {not Company orelse can_publish(User, Program), forbidden}],
            case [M || {false, M} <- Pre] of
                [forbidden | _] -> {error, <<"FORBIDDEN">>, <<"você não pode publicar variantes da empresa desta rotina"/utf8>>};
                [M | _] -> {error, <<"INVALID">>, M};
                [] ->
                    case check(Decl, Entries) of
                        {invalid, Why} -> {error, <<"INVALID">>, Why};
                        {ok, [G | _]} -> {error, <<"INVALID">>, <<"parâmetro desconhecido nesta rotina: "/utf8, G/binary>>};
                        {ok, []} ->
                            case resolve(Entries, Who) of                % every dynamic value resolves today
                                {error, _, M} -> {error, <<"INVALID">>, M};
                                {ok, _} -> write(Program, Id, Name, Company, Entries, Locked, lists:usort(Hidden), User)
                            end
                    end
            end
    end.

write(Program, null, Name, Company, Entries, Locked, Hidden, #{username := Who}) ->
    {ok, [#{<<"n">> := N}]} = ana_db:rows("SELECT count(*)::int AS n FROM ana_system.run_variant WHERE program = $1", [Program]),
    case N >= ?MAX_PER_ROUTINE of
        true -> {error, <<"INVALID">>, <<"limite de 200 variantes por rotina"/utf8>>};
        false ->
            Res = ana_db:one("INSERT INTO ana_system.run_variant (program, name, owner, entries, locked, hidden, created_by, updated_by) "
                             "VALUES ($1, $2, $3, $4::text::jsonb, $5, $6, $7, $7) RETURNING id",
                             [Program, Name, case Company of true -> null; false -> Who end, json_text(Entries), Locked, Hidden, Who]),
            done(Res, Who, Program, <<"variant.create">>)
    end;
write(Program, Id, Name, _Company, Entries, Locked, Hidden, User = #{username := Who}) when is_integer(Id) ->
    case editable(Program, Id, User) of
        {error, _, _} = E -> E;
        {ok, Old} ->
            Prev = case maps:get(<<"owner">>, Old) of
                null -> json_text(maps:with([<<"name">>, <<"entries">>, <<"locked">>, <<"hidden">>, <<"version">>], Old#{<<"entries">> => j(maps:get(<<"entries">>, Old))}));
                _ -> null
            end,
            Res = ana_db:one("UPDATE ana_system.run_variant SET name = $2, entries = $3::text::jsonb, locked = $4, hidden = $5, "
                             "status = 'valid', status_reason = NULL, version = version + 1, "
                             "previous = COALESCE($6::text::jsonb, previous), updated_by = $7, updated_at = now() WHERE id = $1 RETURNING id",
                             [Id, Name, json_text(Entries), Locked, Hidden, Prev, Who]),
            done(Res, Who, Program, <<"variant.change">>)
    end;
write(_, _, _, _, _, _, _, _) -> {error, <<"INVALID">>, <<"variante inválida"/utf8>>}.

done({ok, #{<<"id">> := Id}}, Who, Program, Action) ->
    ana_admin:log(Who, Action, Program, null, #{id => Id}),
    {ok, #{id => Id}};
done({ok, undefined}, _, _, _) -> {error, <<"NOT_FOUND">>, <<"variante não encontrada"/utf8>>};
done({error, #{sqlstate := <<"23505">>}}, _, _, _) -> {error, <<"CONFLICT">>, <<"já existe uma variante com esse nome"/utf8>>};
done({error, #{message := M}}, _, _, _) -> {error, <<"INVALID">>, M}.

%% Personal variants: their owner. Company variants: who may publish them.
editable(Program, Id, User = #{username := Who}) ->
    case ana_db:one("SELECT id, name, owner, entries, locked, hidden, version, published, previous FROM ana_system.run_variant "
                    "WHERE id = $1 AND program = $2", [Id, Program]) of
        {ok, undefined} -> {error, <<"NOT_FOUND">>, <<"variante não encontrada"/utf8>>};
        {ok, #{<<"owner">> := Who} = V} -> {ok, V};
        {ok, #{<<"owner">> := null} = V} ->
            case can_publish(User, Program) of
                true -> {ok, V};
                false -> {error, <<"FORBIDDEN">>, <<"variante da empresa: só quem publica pode mudar"/utf8>>}
            end;
        {ok, _} -> {error, <<"NOT_FOUND">>, <<"variante não encontrada"/utf8>>};
        {error, #{message := M}} -> {error, <<"INVALID">>, M}
    end.

-spec delete(binary(), integer(), map()) -> {ok, map()} | {error, binary(), binary()}.
delete(Program, Id, User = #{username := Who}) ->
    case editable(Program, Id, User) of
        {error, _, _} = E -> E;
        {ok, _} ->
            case ana_db:exec("DELETE FROM ana_system.run_variant WHERE id = $1", [Id]) of
                {ok, _} -> ana_admin:log(Who, <<"variant.delete">>, Program, null, #{id => Id}), {ok, #{id => Id}};
                {error, #{sqlstate := <<"23503">>}} ->
                    {error, <<"CONFLICT">>, <<"um agendamento usa esta variante: troque a variante do agendamento antes"/utf8>>};
                {error, #{message := M}} -> {error, <<"INVALID">>, M}
            end
    end.

%% publish | unpublish | company_default | restore (company) ; default | clear_default (each user's own).
-spec act(binary(), integer() | null, binary(), map()) -> {ok, map()} | {error, binary(), binary()}.
act(Program, Id, <<"default">>, #{username := Who}) ->
    case find(Program, Id, Who) of
        {ok, _} ->
            {ok, _} = ana_db:exec("INSERT INTO ana_system.run_variant_default (username, program, variant_id) VALUES ($1, $2, $3) "
                                  "ON CONFLICT (username, program) DO UPDATE SET variant_id = EXCLUDED.variant_id", [Who, Program, Id]),
            {ok, #{default_id => Id}};
        E -> E
    end;
act(Program, _, <<"clear_default">>, #{username := Who}) ->
    {ok, _} = ana_db:exec("DELETE FROM ana_system.run_variant_default WHERE username = $1 AND program = $2", [Who, Program]),
    {ok, #{default_id => null}};
act(Program, Id, Action, User = #{username := Who}) ->
    case editable(Program, Id, User) of
        {error, _, _} = E -> E;
        {ok, #{<<"owner">> := O}} when O =/= null -> {error, <<"INVALID">>, <<"só variantes da empresa são publicadas"/utf8>>};
        {ok, V} ->
            Sql = case Action of
                <<"publish">> -> {"UPDATE ana_system.run_variant SET published = true, updated_by = $2, updated_at = now() WHERE id = $1", [Id, Who]};
                <<"unpublish">> -> {"UPDATE ana_system.run_variant SET published = false, company_default = false, updated_by = $2, updated_at = now() WHERE id = $1", [Id, Who]};
                <<"company_default">> ->
                    case maps:get(<<"published">>, V) of
                        true -> {tx, Id};
                        false -> {error, <<"publique a variante antes de torná-la a padrão da empresa"/utf8>>}
                    end;
                <<"restore">> ->
                    case j(maps:get(<<"previous">>, V)) of
                        #{<<"entries">> := E, <<"locked">> := L, <<"hidden">> := H, <<"name">> := N} ->
                            {"UPDATE ana_system.run_variant SET name = $3, entries = $4::text::jsonb, locked = $5, hidden = $6, "
                             "previous = $7::text::jsonb, version = version + 1, updated_by = $2, updated_at = now() WHERE id = $1",
                             [Id, Who, N, json_text(E), L, H,
                              json_text(#{<<"name">> => maps:get(<<"name">>, V), <<"entries">> => j(maps:get(<<"entries">>, V)),
                                          <<"locked">> => maps:get(<<"locked">>, V), <<"hidden">> => maps:get(<<"hidden">>, V),
                                          <<"version">> => maps:get(<<"version">>, V)})]};
                        _ -> {error, <<"não há versão anterior desta variante"/utf8>>}
                    end;
                _ -> {error, <<"ação desconhecida"/utf8>>}
            end,
            R = case Sql of
                {error, M} -> {error, <<"INVALID">>, M};
                {tx, I} ->
                    ana_db:transaction(fun(C) ->
                        {ok, _} = ana_db:query(C, "UPDATE ana_system.run_variant SET company_default = false WHERE program = $1 AND company_default", [Program]),
                        {ok, _} = ana_db:query(C, "UPDATE ana_system.run_variant SET company_default = true WHERE id = $1", [I]),
                        {ok, I}
                    end);
                {Q, P} -> ana_db:exec(Q, P)
            end,
            case R of
                {error, _, _} -> R;
                {ok, _} ->
                    ana_admin:log(Who, <<"variant.", Action/binary>>, Program, null, #{id => Id}),
                    validate_program(Program),
                    {ok, #{id => Id, action => Action}};
                {error, #{message := M2}} -> {error, <<"INVALID">>, M2}
            end
    end.

%% ======================================================================= helpers

j(B) when is_binary(B) -> try json:decode(B) catch _:_ -> B end;
j(V) -> V.

json_text(null) -> null;
json_text(V) -> iolist_to_binary(json:encode(V)).
