%% SPDX-FileCopyrightText: 2026 André Luis Pereira dos Santos
%% SPDX-License-Identifier: AGPL-3.0-or-later
%% Diagnostic console (spec 077, T-077-05, D7, CA-077-09; plan §2.3): to investigate what no panel foresaw, without
%% opening a door to change anything.
%%   - Ready-made queries of the product: fixed SQL with typed parameters, run by the core in a read-only transaction
%%     with a short time limit (they see the database's statistics).
%%   - Free SQL and the queries the team saves: run as ana_read (no write privilege) in a READ ONLY transaction, 5 s,
%%     500 rows; only SELECT, WITH, TABLE, VALUES or EXPLAIN (never ANALYZE); sensitive columns masked — the ones the
%%     catalog of spec 068 classifies as personal or secret, and secrets by name.
%% Every run is recorded in the audit (who and what), never its rows.
-module(ana_console).
-include_lib("epgsql/include/epgsql.hrl").

-export([queries/0, run_query/3, run_sql/3, save_query/2, delete_query/2]).

-define(TIMEOUT_MS, 5000).
-define(MAX_ROWS, 500).
-define(SECRET_NAMES, "password|secret|token|hash|ciphertext|private|salt|nonce|api_key").

-spec queries() -> {ok, [map()]}.
queries() ->
    {ok, Rows} = ana_db:rows("SELECT code, name, description, sql, params, product, created_by, created_at "
                             "FROM technical.diagnostic_query ORDER BY product DESC, name", []),
    {ok, [R#{<<"params">> => decode(P)} || R = #{<<"params">> := P} <- Rows]}.

%% A ready-made query (the product's: by the core) or a saved one (the team's: as free SQL).
-spec run_query(binary(), map(), map()) -> {ok, map()} | {error, binary()}.
run_query(Code, Params, User = #{username := Who}) ->
    case ana_db:one("SELECT code, sql, params, product FROM technical.diagnostic_query WHERE code = $1", [Code]) of
        {ok, #{<<"product">> := true, <<"sql">> := Sql, <<"params">> := Spec}} ->
            case values(decode(Spec), Params) of
                {error, _} = E -> E;
                {ok, Values} ->
                    ana_admin:log(Who, <<"console.query">>, Code, null, Params),
                    product_query(Sql, Values)
            end;
        {ok, #{<<"product">> := false, <<"sql">> := Sql}} -> run_sql(Sql, User, #{saved => Code});
        _ -> {error, <<"consulta de diagnóstico inexistente"/utf8>>}
    end.

values(Spec, In) ->
    lists:foldr(fun(_, {error, _} = E) -> E;
                   (P = #{<<"name">> := N}, {ok, Acc}) ->
                       V = maps:get(N, In, maps:get(<<"default">>, P, null)),
                       case {maps:get(<<"type">>, P), V} of
                           {<<"integer">>, I} when is_integer(I), I >= 0, I =< 100000 -> {ok, [I | Acc]};
                           {<<"integer">>, B} when is_binary(B) ->
                               try binary_to_integer(B) of I2 when I2 >= 0 -> {ok, [I2 | Acc]}
                               catch _:_ -> {error, <<(maps:get(<<"label">>, P, N))/binary, " inválido"/utf8>>} end;
                           {<<"text">>, T} when is_binary(T), byte_size(T) =< 200 -> {ok, [T | Acc]};
                           _ -> {error, <<(maps:get(<<"label">>, P, N))/binary, " inválido"/utf8>>}
                       end
                end, {ok, []}, Spec).

product_query(Sql, Values) ->
    R = ana_db:transaction(fun(C) ->
            {ok, [], []} = epgsql:squery(C, "SET TRANSACTION READ ONLY"),
            {ok, [], []} = epgsql:squery(C, "SET LOCAL statement_timeout = " ++ integer_to_list(?TIMEOUT_MS)),
            case epgsql:equery(C, Sql, Values) of
                {ok, Cols, Rows} -> {ok, result(Cols, Rows, [])};
                {error, E} -> {error, E}
            end
        end),
    case R of
        {ok, Res} -> {ok, Res};
        {error, E} -> {error, pg_message(E)}
    end.

%% Free SQL (and saved queries): only reads, as ana_read, limited and masked.
-spec run_sql(binary(), map(), map()) -> {ok, map()} | {error, binary()}.
run_sql(Sql0, #{username := Who}, Opts) ->
    case reads_only(Sql0) of
        {error, _} = E -> E;
        ok ->
            Sql = case maps:get(explain, Opts, false) of
                true -> <<"EXPLAIN ", Sql0/binary>>;
                false -> Sql0
            end,
            ana_admin:log(Who, <<"console.sql">>, maps:get(saved, Opts, <<"livre">>), null, Sql),
            case ana_db:connect(ana_config:db_role(read)) of
                {ok, C} ->
                    try
                        [{ok, [], []}, {ok, [], []}] = epgsql:squery(C, "BEGIN READ ONLY; SET LOCAL statement_timeout = "
                                                                        ++ integer_to_list(?TIMEOUT_MS)),
                        limited(C, Sql)
                    after
                        epgsql:close(C)
                    end;
                {error, _} -> {error, <<"console indisponível: o banco não aceitou a conexão de leitura"/utf8>>}
            end
    end.

%% The first word decides; comments and blank lines before it are skipped. The role and the transaction refuse any
%% write anyway: this is the clear message before.
reads_only(Sql) ->
    Clean = re:replace(Sql, "^(\\s|--[^\\n]*\\n|/\\*.*?\\*/)*", "", [dotall, {return, binary}]),
    First = case re:run(Clean, "^([A-Za-z]+)", [{capture, all_but_first, binary}]) of
        {match, [W]} -> string:uppercase(W);
        nomatch -> <<>>
    end,
    Analyze = re:run(Clean, "^EXPLAIN\\s*(\\(.*ANALY[SZ]E|ANALY[SZ]E)", [caseless, dotall, {capture, none}]) =:= match,
    case lists:member(First, [<<"SELECT">>, <<"WITH">>, <<"TABLE">>, <<"VALUES">>, <<"EXPLAIN">>]) of
        _ when Analyze -> {error, <<"o console só lê: EXPLAIN ANALYZE executa a consulta (use o plano sem ANALYZE)"/utf8>>};
        true -> ok;
        false -> {error, <<"o console só lê: comece por SELECT, WITH, TABLE, VALUES ou EXPLAIN. "
                           "Corrigir dado passa pelo acesso emergencial."/utf8>>}
    end.

limited(C, Sql) ->
    case epgsql:parse(C, "", Sql, []) of
        {ok, #statement{types = [], columns = Cols} = St} ->
            case epgsql:bind(C, St, "", []) of
                ok ->
                    R = epgsql:execute(C, St, "", ?MAX_ROWS + 1),
                    _ = epgsql:sync(C),
                    Masked = masked(C, Cols),
                    case R of
                        {partial, Rows} -> {ok, (result(Cols, lists:sublist(Rows, ?MAX_ROWS), Masked))#{truncated => true}};
                        {ok, Rows} when is_list(Rows) -> {ok, (result(Cols, Rows, Masked))#{truncated => false}};
                        {ok, _N, Rows} -> {ok, (result(Cols, Rows, Masked))#{truncated => false}};
                        {ok, _} -> {error, <<"o console só lê"/utf8>>};
                        {error, E} -> {error, pg_message(E)}
                    end;
                {error, E} -> _ = epgsql:sync(C), {error, pg_message(E)}
            end;
        {ok, _} -> _ = epgsql:sync(C), {error, <<"parâmetros não são suportados no console"/utf8>>};
        {error, E} -> _ = epgsql:sync(C), {error, pg_message(E)}
    end.

%% Positions of the columns to mask: classified personal or secret (spec 068's catalog), or a secret by name.
masked(C, Cols) ->
    Refs = [{I, Oid, Att} || {I, #column{table_oid = Oid, table_attr_number = Att}} <- lists:enumerate(Cols), Oid > 0],
    Names = case Refs of
        [] -> #{};
        _ ->
            Pairs = iolist_to_binary(lists:join(",", [io_lib:format("(~b,~b)", [O, A]) || {_, O, A} <- Refs])),
            case epgsql:squery(C, ["SELECT c.oid::int AS oid, a.attnum::int AS att, n.nspname || '.' || c.relname AS t, a.attname AS col "
                                   "FROM pg_attribute a JOIN pg_class c ON c.oid = a.attrelid JOIN pg_namespace n ON n.oid = c.relnamespace "
                                   "WHERE (c.oid::int, a.attnum::int) IN (", Pairs, ")"]) of
                {ok, _, Rs} -> maps:from_list([{{binary_to_integer(O), binary_to_integer(A)}, {T, Col}} || {O, A, T, Col} <- Rs]);
                _ -> #{}
            end
    end,
    Classified = case ana_db:rows("SELECT table_name, column_name FROM automation.watch_field "
                                  "WHERE classification IN ('personal', 'secret')", []) of
        {ok, Ws} -> sets:from_list([{T, Col} || #{<<"table_name">> := T, <<"column_name">> := Col} <- Ws]);
        _ -> sets:new()
    end,
    [I || {I, #column{name = Name, table_oid = Oid, table_attr_number = Att}} <- lists:enumerate(Cols),
          re:run(Name, ?SECRET_NAMES, [caseless, {capture, none}]) =:= match
          orelse sets:is_element(maps:get({Oid, Att}, Names, none), Classified)].

result(Cols, Rows, Masked) ->
    Types = [T || #column{type = T} <- Cols],
    #{columns => [#{name => N, type => ana_types:type_name(T), masked => lists:member(I, Masked)}
                  || {I, #column{name = N, type = T}} <- lists:enumerate(Cols)],
      rows => [[case lists:member(I, Masked) of
                    true when V =/= null -> <<"***">>;
                    _ -> ana_types:to_json(V, T)
                end || {I, {V, T}} <- lists:enumerate(lists:zip(tuple_to_list(R), Types))] || R <- Rows]}.

%% A useful query saved for the team (only what the console itself would run).
-spec save_query(map(), map()) -> {ok, map()} | {error, binary()}.
save_query(#{<<"code">> := Code, <<"name">> := Name, <<"sql">> := Sql} = In, #{username := Who})
  when is_binary(Code), is_binary(Name), is_binary(Sql) ->
    case {re:run(Code, "^[a-z][a-z0-9_]{2,40}$", [{capture, none}]), reads_only(Sql)} of
        {nomatch, _} -> {error, <<"código: letras minúsculas, números e _ (3 a 41)"/utf8>>};
        {_, {error, _} = E} -> E;
        {match, ok} ->
            case ana_db:one("INSERT INTO technical.diagnostic_query (code, name, description, sql, product, created_by) "
                            "VALUES ($1, $2, $3, $4, false, $5) ON CONFLICT (code) DO UPDATE SET name = EXCLUDED.name, "
                            "description = EXCLUDED.description, sql = EXCLUDED.sql WHERE NOT technical.diagnostic_query.product "
                            "RETURNING code", [Code, Name, maps:get(<<"description">>, In, <<>>), Sql, Who]) of
                {ok, #{<<"code">> := _}} -> ana_admin:log(Who, <<"console.save">>, Code, null, Sql), {ok, #{code => Code}};
                _ -> {error, <<"já existe uma consulta do produto com esse código"/utf8>>}
            end
    end;
save_query(_, _) -> {error, <<"informe código, nome e SQL"/utf8>>}.

-spec delete_query(binary(), map()) -> ok | {error, binary()}.
delete_query(Code, #{username := Who}) ->
    case ana_db:exec("DELETE FROM technical.diagnostic_query WHERE code = $1 AND NOT product", [Code]) of
        {ok, 1} -> ana_admin:log(Who, <<"console.delete">>, Code, null, null), ok;
        _ -> {error, <<"só as consultas salvas pela equipe podem ser apagadas"/utf8>>}
    end.

pg_message(#error{code = <<"57014">>}) -> <<"a consulta passou de 5 s e foi interrompida"/utf8>>;
pg_message(#error{code = <<"25006">>}) -> <<"o console só lê"/utf8>>;
pg_message(#error{code = <<"42501">>}) -> <<"sem permissão de leitura nesse objeto"/utf8>>;
pg_message(#error{message = M}) -> M;
pg_message(E) -> unicode:characters_to_binary(io_lib:format("~0tp", [E])).

decode(V) when is_binary(V) -> json:decode(V);
decode(V) -> V.
