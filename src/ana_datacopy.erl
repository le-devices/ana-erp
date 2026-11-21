%% SPDX-FileCopyrightText: 2026 LE Devices
%% SPDX-License-Identifier: AGPL-3.0-or-later
%% Masked copy of business data from production to a test/development instance (spec 034,
%% RF-034-06, RF-034-07).
%%
%% Export (any instance, admin): one consistent snapshot (REPEATABLE READ) of the business
%% schemas, table by table with a cursor, masked AT THE ORIGIN (personal data never leaves
%% unmasked), JSON lines compressed and encrypted in 1 MiB chunks (AES-256-GCM, chunk index and
%% "last" flag authenticated: reordering or truncation is detected). The key is shown once.
%%
%% Import (test/development only): one transaction — user triggers off (the core owns the
%% tables), business tables emptied (rows referenced by system tables are kept and updated),
%% each table loaded by dependency order in a single statement from a staging table, sequences
%% adjusted, counts and totals checked; a dry run does everything and rolls back. After a
%% real import connectors are switched off and outbound calls blocked.
-module(ana_datacopy).

-export([export/1, upload_path/1, uploaded/3, import/3, list/0, file/1, purge/0, masking/0, save_rule/2]).
-export([business_schemas/0, order/2, order_breaking/2]).

-define(SCHEMAS, [<<"base">>, <<"sales">>, <<"inventory">>, <<"finance">>, <<"projects">>, <<"supply">>,
                  <<"production">>, <<"logistics">>, <<"field">>]).
-define(MAGIC, <<"ANADC1\n">>).
-define(CHUNK, 1048576).
-define(FETCH, 1000).
-define(BATCH, 500).
-define(SUM_COLUMNS, [<<"amount">>, <<"total">>, <<"quantity">>, <<"debit">>, <<"credit">>, <<"price">>, <<"hours">>]).

business_schemas() -> ?SCHEMAS.

dir() -> filename:join(ana_config:text("ANA_FILES_DIR", "/var/lib/ana/files"), "datacopy").

%% ---------------------------------------------------------------- export

-spec export(map()) -> {ok, map()}.
export(User = #{username := Who}) ->
    Key = crypto:strong_rand_bytes(32),
    {ok, #{<<"id">> := Id}} = ana_db:one(
        "INSERT INTO ana_system.datacopy (direction, status, created_by) VALUES ('out', 'running', $1) RETURNING id", [Who]),
    ana_admin:log(Who, <<"datacopy.export">>, integer_to_binary(Id), null, null),
    _ = proc_lib:spawn(fun() -> run_task(Id, <<"datacopy.export">>, User, fun() -> do_export(Id, Key) end) end),
    {ok, #{id => Id, key => base64:encode(Key), status => <<"running">>}}.

finish(Id, {ok, #{} = Res}) ->
    {ok, _} = ana_db:exec("UPDATE ana_system.datacopy SET status = $2, result = $3, file_path = COALESCE($4, file_path), "
                          "size_bytes = COALESCE($5, size_bytes), manifest = COALESCE($6, manifest), finished_at = now() WHERE id = $1",
                          [Id, maps:get(status, Res), maps:get(result, Res, null), maps:get(path, Res, null),
                           maps:get(size, Res, null), maps:get(manifest, Res, null)]);
finish(Id, {error, E}) ->
    Msg = case E of
        B when is_binary(B) -> B;
        #{message := M} when is_binary(M) -> M;
        {abort, B} when is_binary(B) -> B;
        {throw, {abort, B}} when is_binary(B) -> B;
        _ -> iolist_to_binary(io_lib:format("~0P", [E, 30]))
    end,
    {ok, _} = ana_db:exec("UPDATE ana_system.datacopy SET status = 'failed', error = $2, finished_at = now() WHERE id = $1",
                          [Id, clip(Msg, 2000)]).

%% Valid UTF-8, at most N bytes.
clip(B, N) when byte_size(B) =< N -> valid(B);
clip(B, N) -> valid(binary:part(B, 0, N)).

valid(B) ->
    case unicode:characters_to_binary(B) of
        Good when is_binary(Good) -> Good;
        {_, Good, _} -> Good
    end.

%% The record never stays "running" because of a crash (P14: every task ends with a status).
run_task(Id, Name, User, Fun) ->
    try finish(Id, ana_task:run(Name, User, <<"studio">>, Fun))
    catch C:R ->
        logger:error("datacopy ~p: ~0p:~0P", [Id, C, R, 20]),
        _ = ana_db:exec("UPDATE ana_system.datacopy SET status = 'failed', error = 'falha interna (veja o log)', "
                        "finished_at = now() WHERE id = $1 AND status = 'running'", [Id])
    end.

do_export(Id, Key) ->
    ok = filelib:ensure_dir(filename:join(dir(), "x")),
    Path = filename:join(dir(), integer_to_list(Id) ++ ".anadc"),
    Prefix = crypto:strong_rand_bytes(4),
    Header = #{<<"format">> => <<"ana-datacopy/1">>, <<"origin">> => ana_instance:name(), <<"instance">> => ana_instance:role(),
               <<"product_version">> => ana_instance:product_version(), <<"created_at">> => now_text(),
               <<"key_check">> => key_check(Key), <<"nonce_prefix">> => base64:encode(Prefix)},
    {ok, F} = file:open(Path, [write, raw, binary]),
    try
        ok = file:write(F, [?MAGIC, json:encode(Header), "\n"]),
        W0 = #{f => F, key => Key, prefix => Prefix, idx => 0, buf => [], size => 0},
        {ok, Tables} = ana_db:transaction(fun(C) ->
            {ok, [], []} = epgsql:squery(C, "SET TRANSACTION ISOLATION LEVEL REPEATABLE READ, READ ONLY"),
            Ts = tables(C),
            Rules = rules(C),
            {W1, Done} = lists:foldl(fun(T, {W, Acc}) -> {W2, Info} = export_table(C, T, Rules, W), {W2, [Info | Acc]} end,
                                     {W0, []}, Ts),
            Manifest = #{<<"tables">> => lists:reverse(Done), <<"origin">> => ana_instance:name(), <<"created_at">> => now_text()},
            W3 = line(W1, #{<<"manifest">> => Manifest}),
            ok = flush(W3, true),
            {ok, Manifest}
        end),
        ok = file:close(F),
        Size = filelib:file_size(Path),
        {ok, #{status => <<"ready">>, path => list_to_binary(Path), size => Size, manifest => Tables,
               result => #{tables => length(maps:get(<<"tables">>, Tables)),
                           rows => lists:sum([maps:get(<<"rows">>, T) || T <- maps:get(<<"tables">>, Tables)])}}}
    catch C:R:St ->
        _ = file:close(F),
        _ = file:delete(Path),
        erlang:raise(C, R, St)
    end.

export_table(C, Table = #{name := T, columns := Cols}, Rules, W0) ->
    Kinds = maps:from_list([{N, K} || #{name := N, type := Ty} <- Cols,
                                      K <- [ana_mask:kind_for(T, N, Ty, Rules)], K =/= <<"keep">>]),
    Names = [N || #{name := N} <- Cols],
    W1 = line(W0, #{<<"table">> => T, <<"columns">> => Names, <<"masked">> => Kinds}),
    Q = quote(T),
    %% A table pointing to itself leaves in key order: parents usually come before their rows, so
    %% the load keeps almost nothing aside (spec 063).
    Order = case Table of
        #{self := [_ | _], pk := [_ | _] = Pk} -> [" ORDER BY ", lists:join(", ", [["t.", qi(K)] || K <- Pk])];
        _ -> []
    end,
    {ok, [], []} = epgsql:squery(C, ["DECLARE ana_copy NO SCROLL CURSOR FOR SELECT to_jsonb(t)::text FROM ", Q, " t", Order]),
    Key = maps:get(key, W1),
    {W2, N} = fetch_loop(C, Names, Kinds, Key, W1, 0),
    _ = epgsql:squery(C, "CLOSE ana_copy"),
    Sums = sums(C, T, Cols),
    W3 = line(W2, #{<<"end">> => T, <<"rows">> => N, <<"sums">> => Sums}),
    {W3, #{<<"table">> => T, <<"rows">> => N, <<"sums">> => Sums}}.

%% Generated columns are left out (the destination computes them).
fetch_loop(C, Names, Kinds, Key, W, N) ->
    Rows = case epgsql:squery(C, "FETCH " ++ integer_to_list(?FETCH) ++ " FROM ana_copy") of
        {ok, _, _, Rs} -> Rs;            % FETCH answers {ok, Count, Columns, Rows}
        {ok, _, Rs} -> Rs;
        {error, E} -> throw({abort, maps:get(message, ana_db:sql_error(E))})
    end,
    case Rows of
        [] -> {W, N};
        _ ->
            W2 = lists:foldl(fun({J}, Acc) -> line(Acc, mask_row(maps:with(Names, json:decode(J)), Kinds, Key)) end, W, Rows),
            fetch_loop(C, Names, Kinds, Key, W2, N + length(Rows))
    end.

mask_row(Row, Kinds, _Key) when map_size(Kinds) =:= 0 -> #{<<"r">> => Row};
mask_row(Row, Kinds, Key) ->
    #{<<"r">> => maps:map(fun(Col, V) -> case Kinds of #{Col := K} -> ana_mask:value(K, V, Key); _ -> V end end, Row)}.

sums(C, T, Cols) ->
    Num = [N || #{name := N, type := Ty} <- Cols, lists:member(N, ?SUM_COLUMNS),
                lists:member(Ty, [<<"numeric">>, <<"integer">>, <<"bigint">>, <<"smallint">>, <<"double precision">>, <<"real">>])],
    case Num of
        [] -> #{};
        _ ->
            {ok, _, [Row]} = epgsql:squery(C, ["SELECT ", lists:join(", ", [["COALESCE(sum(", qi(N), "), 0)::text"] || N <- Num]),
                                              " FROM ", quote(T)]),
            maps:from_list(lists:zip(Num, tuple_to_list(Row)))
    end.

%% ---------------------------------------------------------------- writer (chunks)

line(W = #{buf := B, size := S}, Term) ->
    L = [json:encode(Term), "\n"],
    Sz = S + iolist_size(L),
    W2 = W#{buf := [B | L], size := Sz},
    case Sz >= ?CHUNK of
        true -> ok = flush(W2, false), W2#{buf := [], size := 0, idx := maps:get(idx, W2) + 1};
        false -> W2
    end.

flush(#{f := F, key := K, prefix := P, idx := I, buf := B}, Last) ->
    Plain = zlib:compress(iolist_to_binary(B)),
    Aad = <<I:64, (case Last of true -> 1; false -> 0 end):8>>,
    {Ct, Tag} = crypto:crypto_one_time_aead(aes_256_gcm, K, <<P/binary, I:64>>, Plain, Aad, true),
    file:write(F, [<<(byte_size(Ct)):32>>, Ct, Tag]).

%% ---------------------------------------------------------------- reader

open_copy(Path, Key) ->
    case file:open(Path, [read, raw, binary, read_ahead]) of
        {ok, F} ->
            case file:read_line(F) of
                {ok, ?MAGIC} ->
                    case file:read_line(F) of
                        {ok, HLine} ->
                            H = json:decode(HLine),
                            case maps:get(<<"key_check">>, H, null) =:= key_check(Key) of
                                true -> {ok, #{f => F, key => Key, prefix => base64:decode(maps:get(<<"nonce_prefix">>, H)), idx => 0,
                                               pending => [], done => false}, H};
                                false -> _ = file:close(F), {error, <<"chave da cópia incorreta"/utf8>>}
                            end;
                        _ -> _ = file:close(F), {error, <<"arquivo de cópia incompleto"/utf8>>}
                    end;
                _ -> _ = file:close(F), {error, <<"arquivo não é uma cópia de dados do ANA"/utf8>>}
            end;
        _ -> {error, <<"arquivo da cópia não encontrado"/utf8>>}
    end.

%% Next decoded line, or eof.
next(R = #{pending := [L | Rest]}) -> {json:decode(L), R#{pending := Rest}};
next(#{done := true}) -> eof;
next(R = #{f := F, key := K, prefix := P, idx := I}) ->
    case file:read(F, 4) of
        {ok, <<Len:32>>} ->
            {ok, Ct} = file:read(F, Len),
            {ok, Tag} = file:read(F, 16),
            Plain = case crypto:crypto_one_time_aead(aes_256_gcm, K, <<P/binary, I:64>>, Ct, <<I:64, 0:8>>, Tag, false) of
                error ->
                    case crypto:crypto_one_time_aead(aes_256_gcm, K, <<P/binary, I:64>>, Ct, <<I:64, 1:8>>, Tag, false) of
                        error -> throw({abort, <<"arquivo da cópia corrompido ou alterado"/utf8>>});
                        Pl -> {last, Pl}
                    end;
                Pl -> {more, Pl}
            end,
            {Done, Bin} = case Plain of {last, B} -> {true, B}; {more, B} -> {false, B} end,
            Lines = binary:split(zlib:uncompress(Bin), <<"\n">>, [global, trim_all]),
            next(R#{pending := Lines, idx := I + 1, done := Done});
        eof -> throw({abort, <<"arquivo da cópia truncado"/utf8>>});
        _ -> throw({abort, <<"arquivo da cópia ilegível"/utf8>>})
    end.

%% ---------------------------------------------------------------- import

upload_path(Id) -> filename:join(dir(), "in-" ++ integer_to_list(Id) ++ ".anadc").

%% The HTTP layer streams the body to upload_path/1 of a fresh record.
-spec uploaded(binary(), non_neg_integer(), map()) -> {ok, map()}.
uploaded(Path, Size, #{username := Who}) ->
    {ok, #{<<"id">> := Id}} = ana_db:one(
        "INSERT INTO ana_system.datacopy (direction, status, file_path, size_bytes, created_by, finished_at) "
        "VALUES ('in', 'uploaded', $1, $2, $3, now()) RETURNING id", [Path, Size, Who]),
    ana_admin:log(Who, <<"datacopy.upload">>, integer_to_binary(Id), null, #{size => Size}),
    {ok, #{id => Id, status => <<"uploaded">>}}.

-spec import(integer(), map(), map()) -> {ok, map()} | {error, term()}.
import(Id, B, User = #{username := Who}) ->
    DryRun = maps:get(<<"dry_run">>, B, false) =:= true,
    case {ana_instance:role(), catch base64:decode(maps:get(<<"key">>, B, <<>>))} of
        {<<"production">>, _} -> {error, <<"a produção não recebe cópias de dados: use numa instância de testes ou desenvolvimento"/utf8>>};
        {_, Key} when is_binary(Key), byte_size(Key) =:= 32 ->
            case ana_db:exec("UPDATE ana_system.datacopy SET status = 'running', error = NULL WHERE id = $1 AND direction = 'in' "
                             "AND status IN ('uploaded', 'checked', 'failed')", [Id]) of
                {ok, 1} ->
                    {ok, #{<<"file_path">> := Path}} = ana_db:one("SELECT file_path FROM ana_system.datacopy WHERE id = $1", [Id]),
                    ana_admin:log(Who, <<"datacopy.import">>, integer_to_binary(Id), null, #{dry_run => DryRun}),
                    Opts = #{dry_run => DryRun, probes => [P || P <- maps:get(<<"probes">>, B, []), is_binary(P), byte_size(P) >= 3],
                             inspect => [X || X <- maps:get(<<"inspect_parties">>, B, []), is_integer(X)]},
                    _ = proc_lib:spawn(fun() ->
                        run_task(Id, <<"datacopy.import">>, User, fun() -> do_import(binary_to_list(Path), Key, Opts, User) end)
                    end),
                    {ok, #{id => Id, status => <<"running">>, dry_run => DryRun}};
                {ok, 0} -> {error, <<"cópia inexistente, já importada ou em andamento"/utf8>>};
                E -> E
            end;
        _ -> {error, <<"informe a chave da cópia (mostrada na exportação)"/utf8>>}
    end.

do_import(Path, Key, Opts, User) ->
    case open_copy(Path, Key) of
        {error, E} -> {error, E};
        {ok, R0, Header} ->
            T0 = erlang:monotonic_time(millisecond),
            Result = try ana_db:transaction(fun(C) -> load(C, R0, Header, Opts) end)
                     catch throw:{abort, Why} -> {error, Why}
                     after file:close(maps:get(f, R0))
                     end,
            Ms = erlang:monotonic_time(millisecond) - T0,
            case Result of
                {error, {dry_run, Res}} -> {ok, #{status => <<"checked">>, result => Res#{dry_run => true, ms => Ms}}};
                {ok, Res} ->
                    %% RF-034-07: nothing leaves a test instance holding copied data.
                    {ok, Off} = ana_db:exec("UPDATE integration.connector SET active = false WHERE active", []),
                    ok = ana_settings:set(<<"outbound_blocked">>, 1, User),
                    {ok, #{status => <<"imported">>, result => Res#{connectors_disabled => Off, outbound_blocked => true, ms => Ms}}};
                {error, E} -> {error, E}
            end
    end.

load(C, R0, Header, Opts) ->
    Tables = tables(C),
    ByName = maps:from_list([{N, T} || T = #{name := N} <- Tables]),
    Kept = kept_tables(C),
    Names = [N || #{name := N} <- Tables],
    _ = [ok = sq(C, ["ALTER TABLE ", quote(N), " DISABLE TRIGGER USER"]) || N <- Names],
    Truncate = [quote(N) || N <- Names, not lists:member(N, Kept)],
    _ = Truncate =/= [] andalso ok =:= sq(C, ["TRUNCATE ", lists:join(", ", Truncate)]),
    _ = [ok = sq(C, ["DELETE FROM ", quote(N), " t WHERE NOT EXISTS (SELECT 1 FROM ana_system.app_user u WHERE u.party_id = t.id)"])
         || N <- Kept, N =:= <<"base.party">>],
    {Loaded, Manifest} = load_sections(C, R0, ByName, Kept, [], undefined),
    _ = [fill(C, F) || #{fixes := Fs} <- Loaded, F <- Fs],
    _ = [setval(C, T) || T <- Tables],
    _ = [ok = sq(C, ["ALTER TABLE ", quote(N), " ENABLE TRIGGER USER"]) || N <- Names],
    Check = verify(C, Loaded, Manifest, ByName),
    Res = #{origin => maps:get(<<"origin">>, Header), copied_at => maps:get(<<"created_at">>, Header),
            tables => length(Loaded), rows => lists:sum([maps:get(rows, L) || L <- Loaded]),
            skipped => lists:sum([maps:get(skipped, L) || L <- Loaded]), mismatches => Check,
            probes_found => probes(C, maps:get(probes, Opts), Names),
            parties => inspect(C, maps:get(inspect, Opts))},
    case {Check, maps:get(dry_run, Opts)} of
        {[_ | _], _} -> throw({abort, unicode:characters_to_binary(["contagens ou totais não conferem: ",
                                                                    json:encode(Check)])});
        {[], true} -> {error, {dry_run, Res}};
        {[], false} -> {ok, Res}
    end.

%% Disk endurance (spec 063, finding b): rows go straight from the file into their table, 500 at a
%% time; there is no staging table (it spilled ~440 MB of temporary writes per copy). Only the few
%% values that must wait (a cycle, a row pointing to a row not loaded yet) are kept aside.
load_sections(C, R, ByName, Kept, Acc, Cur) ->
    case next(R) of
        eof -> throw({abort, <<"arquivo da cópia sem manifesto"/utf8>>});
        {#{<<"manifest">> := M}, _} -> {lists:reverse(Acc), M};
        {#{<<"table">> := T, <<"columns">> := Cols}, R2} ->
            case maps:get(T, ByName, undefined) of
                undefined -> throw({abort, <<"tabela da cópia não existe aqui (versões diferentes?): "/utf8, T/binary>>});
                Info -> load_sections(C, R2, ByName, Kept, Acc, {plan(Info, Cols, lists:member(T, Kept)), [], [], 0, #{}})
            end;
        {#{<<"r">> := Row}, R2} ->
            {Plan, Batch, Keys, Len, Got} = Cur,
            Batch2 = [iolist_to_binary(json:encode(Row)) | Batch],
            Keys2 = case Plan of
                #{batch_key := undefined} -> Keys;
                #{batch_key := K} -> [key_text(maps:get(K, Row, null)) | Keys]
            end,
            case Len + 1 >= ?BATCH of
                true -> load_sections(C, R2, ByName, Kept, Acc,
                                      {Plan, [], [], 0, insert_batch(C, Plan, Batch2, Keys2, Len + 1, Got)});
                false -> load_sections(C, R2, ByName, Kept, Acc, {Plan, Batch2, Keys2, Len + 1, Got})
            end;
        {#{<<"end">> := T, <<"rows">> := Rows}, R2} ->
            {Plan = #{pk := Pk}, Batch, Keys, Len, Got0} = Cur,
            Got = insert_batch(C, Plan, Batch, Keys, Len, Got0),
            Info = #{table => T, rows => maps:get(rows, Got, 0), skipped => maps:get(skipped, Got, 0),
                     fixes => [{T, Col, Pk} || Col <- maps:get(fixes, Got, [])], expected => Rows},
            load_sections(C, R2, ByName, Kept, [Info | Acc], undefined);
        {_, R2} -> load_sections(C, R2, ByName, Kept, Acc, Cur)
    end.

%% The statements for one table, built once.
%% - a column breaking a cycle is loaded empty and filled at the end (fill/2);
%% - a reference to the same table is loaded only when that row is already in, else filled at the end;
%% - a reference to a system table missing here is emptied when allowed, else the row is skipped (counted).
plan(#{name := T, columns := TCols, external := Ext, self := Self, pk := Pk, deferred := Deferred}, FileCols, Upsert) ->
    Here = [N || #{name := N} <- TCols],
    Cols = [N || N <- FileCols, lists:member(N, Here)],
    %% A row pointing to a row of the same batch is fine: PostgreSQL checks references at the end of
    %% the statement, when the whole batch is in. The batch's keys go along as $2.
    BatchKey = case lists:usort([RC || {Col, RC} <- Self, lists:member(Col, Cols), not lists:member(Col, Deferred)]) of
        [K] when Pk =/= [] -> K;
        _ -> undefined
    end,
    BatchCheck = fun(Col) ->
        case BatchKey of
            undefined -> [];
            _ -> [" AND NOT (p.", qi(Col), "::text = ANY($2::text[]))"]
        end
    end,
    Later = case Pk of
        [] -> [];
        _ -> [{Col, always} || Col <- Deferred, lists:member(Col, Cols)] ++
             [{Col, [missing(Col, quote(T), RC), BatchCheck(Col)]}
              || {Col, RC} <- Self, lists:member(Col, Cols), not lists:member(Col, Deferred)]
    end,
    ExtIn = [X || X = #{column := Col} <- Ext, lists:member(Col, Cols), not lists:keymember(Col, 1, Later)],
    Expr = fun(Col) ->
        case {lists:keyfind(Col, 1, Later), [X || X = #{column := Cx, nullable := true} <- ExtIn, Cx =:= Col]} of
            {{_, always}, _} -> "NULL";
            {{_, Missing}, _} -> ["CASE WHEN NOT (", Missing, ") THEN p.", qi(Col), " END"];
            {false, [#{ref_table := RT, ref_column := RC}]} -> ["CASE WHEN NOT (", missing(Col, RT, RC), ") THEN p.", qi(Col), " END"];
            {false, []} -> ["p.", qi(Col)]
        end
    end,
    Strict = [["NOT (", missing(Col, RT, RC), ")"] || #{column := Col, ref_table := RT, ref_column := RC, nullable := false} <- ExtIn],
    Conflict = case {Upsert, Pk} of
        {true, [_ | _]} -> [" ON CONFLICT (", lists:join(", ", [qi(K) || K <- Pk]), ") DO UPDATE SET ",
                            lists:join(", ", [[qi(N), " = EXCLUDED.", qi(N)] || N <- Cols, not lists:member(N, Pk)])];
        _ -> []
    end,
    From = [" FROM unnest($1::text[]) u(t), LATERAL (SELECT u.t::jsonb AS r) s, jsonb_populate_record(NULL::", quote(T), ", s.r) p"],
    Insert = iolist_to_binary(
        ["INSERT INTO ", quote(T), " (", lists:join(", ", [qi(N) || N <- Cols]), ") OVERRIDING SYSTEM VALUE ",
         "SELECT ", lists:join(", ", [Expr(N) || N <- Cols]), From,
         case Strict of [] -> []; _ -> [" WHERE ", lists:join(" AND ", Strict)] end, Conflict]),
    Aside = [{Col, iolist_to_binary(
                ["INSERT INTO ana_fix (tbl, col, r) SELECT ", lit(T), ", ", lit(Col), ", s.r",
                 From, " WHERE ",
                 case How of always -> ["p.", qi(Col), " IS NOT NULL"]; _ -> How end])}
             || {Col, How} <- Later],
    #{table => T, pk => Pk, insert => Insert, aside => Aside, batch_key => BatchKey}.

key_text(null) -> null;
key_text(B) when is_binary(B) -> B;
key_text(N) when is_integer(N) -> integer_to_binary(N);
key_text(V) -> iolist_to_binary(json:encode(V)).

%% True when the row points (through Col) to a row that is not in RefTable. Compared in the
%% column's own type, so the referenced key's index is used.
missing(Col, RefTable, RefCol) ->
    ["p.", qi(Col), " IS NOT NULL AND NOT EXISTS (SELECT 1 FROM ", RefTable, " x WHERE x.", qi(RefCol), " = p.", qi(Col), ")"].

insert_batch(_, _, [], _, _, Got) -> Got;
insert_batch(C, #{table := T, insert := Insert, aside := Aside, batch_key := BatchKey}, Batch, Keys, Len, Got) ->
    Params = case BatchKey of undefined -> [Batch]; _ -> [Batch, Keys] end,
    Fixes = lists:foldl(fun({Col, Sql}, Acc) ->
        ok = sq(C, "CREATE TEMP TABLE IF NOT EXISTS ana_fix (tbl text, col text, r jsonb) ON COMMIT DROP"),
        case ana_db:query(C, Sql, Params) of
            {ok, #{affected := 0}} -> Acc;
            {ok, _} -> lists:usort([Col | Acc]);
            {error, E} -> throw({abort, iolist_to_binary(["falha ao carregar ", T, ": ", maps:get(message, ana_db:sql_error(E))])})
        end
    end, maps:get(fixes, Got, []), Aside),
    replan(C, maps:get(batches, Got, 0) + 1),
    case ana_db:query(C, Insert, Params) of
        {ok, Res} ->
            N = maps:get(affected, Res),
            Got#{rows => maps:get(rows, Got, 0) + N, skipped => maps:get(skipped, Got, 0) + Len - N, fixes => Fixes,
                 batches => maps:get(batches, Got, 0) + 1};
        {error, E} -> throw({abort, iolist_to_binary(["falha ao carregar ", T, ": ", maps:get(message, ana_db:sql_error(E))])})
    end.

%% The table was just emptied and grows batch after batch. PostgreSQL keeps a plan made while it was
%% small (its own reference checks included) and would then scan the whole table for every row.
%% Plans are dropped each time the table doubles, so they are remade for its size (~10 per table).
replan(C, Batches) when Batches >= 4, Batches band (Batches - 1) =:= 0 -> ok = sq(C, "DISCARD PLANS");
replan(_, _) -> ok.

%% Values kept aside, put in once every table is loaded.
fill(C, {T, Col, Pk}) ->
    ok = sq(C, ["UPDATE ", quote(T), " t SET ", qi(Col), " = p.", qi(Col), " FROM ana_fix f, jsonb_populate_record(NULL::",
                quote(T), ", f.r) p WHERE f.tbl = ", lit(T), " AND f.col = ", lit(Col), " AND ",
                lists:join(" AND ", [["t.", qi(K), " = p.", qi(K)] || K <- Pk])]).

setval(C, #{name := T, serials := Serials}) ->
    [ok = sq(C, ["SELECT setval(", lit(Seq), ", GREATEST(COALESCE((SELECT max(", qi(Col), ") FROM ", quote(T), "), 0), 1), ",
                 "(SELECT max(", qi(Col), ") IS NOT NULL FROM ", quote(T), "))"]) || {Col, Seq} <- Serials].

verify(C, Loaded, #{<<"tables">> := Expected}, ByName) ->
    Exp = maps:from_list([{T, X} || X = #{<<"table">> := T} <- Expected]),
    Counts = [#{table => T, expected => E, loaded => N + S}
              || #{table := T, rows := N, skipped := S, expected := E} <- Loaded, N + S =/= E],
    Sums = lists:append([sum_mismatch(C, T, maps:get(<<"sums">>, X, #{}), ByName)
                         || {T, X} <- maps:to_list(Exp), T =/= <<"base.party">>, maps:is_key(T, ByName)]),
    Counts ++ Sums.

sum_mismatch(_, _, Sums, _) when map_size(Sums) =:= 0 -> [];
sum_mismatch(C, T, Sums, _) ->
    Cols = maps:keys(Sums),
    {ok, _, [Row]} = epgsql:squery(C, ["SELECT ", lists:join(", ", [["COALESCE(sum(", qi(N), "), 0)::text"] || N <- Cols]),
                                      " FROM ", quote(T)]),
    [#{table => T, column => N, expected => E, loaded => G}
     || {N, G} <- lists:zip(Cols, tuple_to_list(Row)), E <- [maps:get(N, Sums)], not same_number(E, G)].

same_number(A, B) ->
    try binary_to_float(norm(A)) == binary_to_float(norm(B)) catch _:_ -> A =:= B end.

norm(B) -> case binary:match(B, <<".">>) of nomatch -> <<B/binary, ".0">>; _ -> B end.

%% CA-034-05 (dry run): does any original value still appear in the loaded tables?
probes(_, [], _) -> #{};
probes(C, Probes, Names) ->
    maps:from_list([{P, lists:sum([count_like(C, T, P) || T <- Names])} || P <- Probes]).

count_like(C, T, P) ->
    {ok, #{rows := [[N]]}} = ana_db:query(C, iolist_to_binary(["SELECT count(*) FROM ", quote(T), " t WHERE strpos(to_jsonb(t)::text, $1) > 0"]), [P]),
    N.

inspect(_, []) -> [];
inspect(C, Ids) ->
    {ok, #{rows := Rows}} = ana_db:query(C, "SELECT to_jsonb(p)::text FROM base.party p WHERE id = ANY($1::int[]) ORDER BY id", [Ids]),
    [json:decode(J) || [J] <- Rows].

%% ---------------------------------------------------------------- catalog

%% Business tables (no partitions) in dependency order, with insertable columns, references to
%% system tables, primary key and sequences.
tables(C) ->
    {ok, #{rows := TRows}} = ana_db:query(C,
        "SELECT n.nspname || '.' || c.relname, c.oid::int FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace "
        "WHERE c.relkind IN ('r', 'p') AND NOT c.relispartition AND n.nspname = ANY($1::text[]) ORDER BY 1", [?SCHEMAS]),
    {ok, #{rows := CRows}} = ana_db:query(C,
        "SELECT a.attrelid::int, a.attname::text, format_type(a.atttypid, NULL), NOT a.attnotnull, "
        "  pg_get_serial_sequence(a.attrelid::regclass::text, a.attname) "
        "FROM pg_attribute a WHERE a.attrelid = ANY($1::int[]) AND a.attnum > 0 AND NOT a.attisdropped AND a.attgenerated = '' "
        "ORDER BY a.attrelid, a.attnum", [[O || [_, O] <- TRows]]),
    {ok, #{rows := FRows}} = ana_db:query(C,
        "SELECT c.conrelid::int, c.confrelid::int, (SELECT n.nspname || '.' || r.relname FROM pg_class r "
        "  JOIN pg_namespace n ON n.oid = r.relnamespace WHERE r.oid = c.confrelid), "
        "  (SELECT attname::text FROM pg_attribute WHERE attrelid = c.conrelid AND attnum = c.conkey[1]), "
        "  (SELECT attname::text FROM pg_attribute WHERE attrelid = c.confrelid AND attnum = c.confkey[1]), "
        "  cardinality(c.conkey) "
        "FROM pg_constraint c WHERE c.contype = 'f' AND c.conrelid = ANY($1::int[])", [[O || [_, O] <- TRows]]),
    {ok, #{rows := PRows}} = ana_db:query(C,
        "SELECT c.conrelid::int, a.attname::text FROM pg_constraint c JOIN pg_attribute a ON a.attrelid = c.conrelid "
        "AND a.attnum = ANY(c.conkey) WHERE c.contype = 'p' AND c.conrelid = ANY($1::int[])", [[O || [_, O] <- TRows]]),
    Oids = [O || [_, O] <- TRows],
    Name = maps:from_list([{O, N} || [N, O] <- TRows]),
    Info = [#{name => N, oid => O,
              columns => [#{name => Col, type => base_type(Ty), nullable => Nl} || [Rel, Col, Ty, Nl, _] <- CRows, Rel =:= O],
              serials => [{Col, Seq} || [Rel, Col, _, _, Seq] <- CRows, Rel =:= O, Seq =/= null],
              pk => [Col || [Rel, Col] <- PRows, Rel =:= O],
              external => [#{column => Col, ref_table => quote(RT), ref_column => RC,
                             nullable => lists:member(true, [Nl || [Rel2, Cn, _, Nl, _] <- CRows, Rel2 =:= O, Cn =:= Col])}
                           || [Rel, To, RT, Col, RC, 1] <- FRows, Rel =:= O, not lists:member(To, Oids)],
              self => [{Col, RC} || [Rel, To, _, Col, RC, 1] <- FRows, Rel =:= O, To =:= O,
                                    lists:member(true, [Nl || [Rel2, Cn, _, Nl, _] <- CRows, Rel2 =:= O, Cn =:= Col])]}
            || [N, O] <- TRows],
    Nullable = fun(O, Col) -> lists:member(true, [Nl || [Rel2, Cn, _, Nl, _] <- CRows, Rel2 =:= O, Cn =:= Col]) end,
    Edges = [{maps:get(Rel, Name), maps:get(To, Name), Col, Nullable(Rel, Col) andalso Card =:= 1}
             || [Rel, To, _, Col, _, Card] <- FRows, lists:member(To, Oids), Rel =/= To],
    {Order, Broken} = order_breaking([N || [N, _] <- TRows], Edges),
    ByName = maps:from_list([{N, I#{deferred => [Cl || {Tb, Cl} <- Broken, Tb =:= N]}} || I = #{name := N} <- Info]),
    [maps:get(N, ByName) || N <- Order].

base_type(Ty) ->
    case binary:split(Ty, <<"(">>) of [B | _] -> B; _ -> Ty end.

%% Kahn's order: a table after the tables it references.
-spec order([binary()], [{binary(), binary()}]) -> [binary()].
order(Nodes, Edges) ->
    element(1, order_breaking(Nodes, [{F, T, <<>>, false} || {F, T} <- Edges])).

%% A cycle (A → B → A) is broken at a nullable reference: that column is loaded empty and
%% filled after every table is in ({Table, Column} in the second element).
-spec order_breaking([binary()], [{binary(), binary(), binary(), boolean()}]) -> {[binary()], [{binary(), binary()}]}.
order_breaking(Nodes, Edges) -> order_breaking(Nodes, lists:usort(Edges), [], []).
order_breaking([], _, Acc, Broken) -> {lists:reverse(Acc), Broken};
order_breaking(Nodes, Edges, Acc, Broken) ->
    Live = [E || E = {F, T, _, _} <- Edges, F =/= T, lists:member(F, Nodes), lists:member(T, Nodes)],
    Ready = [N || N <- Nodes, not lists:any(fun({F, _, _, _}) -> F =:= N end, Live)],
    case Ready of
        [] ->
            case [E || E = {_, _, _, true} <- Live] of
                [{F, _, C, _} = E | _] -> order_breaking(Nodes, Edges -- [E], Acc, [{F, C} | Broken]);
                [] -> {lists:reverse(Acc) ++ lists:sort(Nodes), Broken}
            end;
        _ -> order_breaking(Nodes -- Ready, Edges, lists:reverse(lists:sort(Ready)) ++ Acc, Broken)
    end.

%% Business tables referenced by system tables: their referenced rows are kept and updated.
kept_tables(C) ->
    {ok, #{rows := Rows}} = ana_db:query(C,
        "SELECT DISTINCT tn.nspname || '.' || t.relname FROM pg_constraint c "
        "JOIN pg_class f ON f.oid = c.conrelid JOIN pg_namespace fn ON fn.oid = f.relnamespace "
        "JOIN pg_class t ON t.oid = c.confrelid JOIN pg_namespace tn ON tn.oid = t.relnamespace "
        "WHERE c.contype = 'f' AND tn.nspname = ANY($1::text[]) AND NOT fn.nspname = ANY($1::text[])", [?SCHEMAS]),
    [N || [N] <- Rows].

rules(C) ->
    {ok, #{rows := Rows}} = ana_db:query(C, "SELECT schema_name || '.' || table_name, column_name, kind FROM ana_system.mask_rule", []),
    maps:from_list([{{T, Col}, K} || [T, Col, K] <- Rows]).

%% ---------------------------------------------------------------- masking catalog

%% What leaves masked: every business column whose kind is not "keep" (catalog or rule).
masking() ->
    ana_db:with_connection(fun(C) ->
        Rules = rules(C),
        Cols = [#{table => T, column => N, type => Ty, kind => K, rule => maps:is_key({T, N}, Rules)}
                || #{name := T, columns := Cs} <- tables(C), #{name := N, type := Ty} <- Cs,
                   K <- [ana_mask:kind_for(T, N, Ty, Rules)], K =/= <<"keep">> orelse maps:is_key({T, N}, Rules)],
        {ok, #{columns => Cols, kinds => [<<"keep">>, <<"person">>, <<"company">>, <<"email">>, <<"phone">>, <<"document">>,
                                          <<"address">>, <<"geo">>, <<"text">>, <<"null">>]}}
    end).

save_rule(#{<<"table">> := T, <<"column">> := Col, <<"kind">> := K}, #{username := Who}) when is_binary(T), is_binary(Col), is_binary(K) ->
    case binary:split(T, <<".">>) of
        [S, Tb] ->
            case lists:member(S, ?SCHEMAS) andalso
                 {ok, #{<<"n">> => 1}} =:= ana_db:one("SELECT count(*)::int AS n FROM information_schema.columns "
                                                      "WHERE table_schema = $1 AND table_name = $2 AND column_name = $3", [S, Tb, Col]) of
                false -> {error, <<"coluna inexistente nos esquemas de negócio"/utf8>>};
                true when K =:= <<"catalog">> ->
                    {ok, _} = ana_db:exec("DELETE FROM ana_system.mask_rule WHERE schema_name = $1 AND table_name = $2 AND column_name = $3",
                                          [S, Tb, Col]),
                    ana_admin:log(Who, <<"datacopy.mask_rule">>, <<T/binary, ".", Col/binary>>, null, #{kind => K}),
                    {ok, #{table => T, column => Col, kind => K}};
                true ->
                    case ana_db:exec("INSERT INTO ana_system.mask_rule (schema_name, table_name, column_name, kind, updated_by) "
                                     "VALUES ($1, $2, $3, $4, $5) ON CONFLICT (schema_name, table_name, column_name) DO UPDATE "
                                     "SET kind = EXCLUDED.kind, updated_by = EXCLUDED.updated_by, updated_at = now()", [S, Tb, Col, K, Who]) of
                        {ok, _} -> ana_admin:log(Who, <<"datacopy.mask_rule">>, <<T/binary, ".", Col/binary>>, null, #{kind => K}),
                                   {ok, #{table => T, column => Col, kind => K}};
                        {error, _} -> {error, <<"tipo de máscara inválido"/utf8>>}
                    end
            end;
        _ -> {error, <<"tabela no formato esquema.tabela"/utf8>>}
    end;
save_rule(_, _) -> {error, <<"informe tabela, coluna e tipo"/utf8>>}.

%% ---------------------------------------------------------------- reading / housekeeping

list() ->
    ana_db:rows("SELECT id, direction, status, size_bytes, result, error, created_by, created_at, finished_at, "
                "  manifest->'tables' IS NOT NULL AS has_manifest FROM ana_system.datacopy ORDER BY id DESC LIMIT 100", []).

file(Id) ->
    case ana_db:one("SELECT file_path FROM ana_system.datacopy WHERE id = $1 AND direction = 'out' AND status = 'ready'", [Id]) of
        {ok, #{<<"file_path">> := P}} when is_binary(P) -> {ok, P};
        _ -> {error, not_found}
    end.

%% Files older than 48 h are removed (they hold a copy of the whole business data, masked).
purge() ->
    _ = ana_db:exec(<<"UPDATE ana_system.datacopy SET status = 'failed', error = 'interrompida (nó reiniciado?)', finished_at = now() "
                      "WHERE status = 'running' AND created_at < now() - interval '12 hours'"/utf8>>, []),
    {ok, Rows} = ana_db:rows("UPDATE ana_system.datacopy SET status = 'expired' WHERE created_at < now() - interval '48 hours' "
                             "AND status IN ('ready', 'uploaded', 'checked', 'failed') AND file_path IS NOT NULL RETURNING file_path", []),
    _ = [file:delete(binary_to_list(P)) || #{<<"file_path">> := P} <- Rows],
    ok.

%% ---------------------------------------------------------------- helpers

key_check(Key) -> binary:encode_hex(crypto:mac(hmac, sha256, Key, <<"ana-datacopy-check">>), lowercase).

sq(C, Sql) ->
    case epgsql:squery(C, Sql) of
        {ok, _} -> ok;
        {ok, _, _} -> ok;
        {error, E} -> throw({abort, maps:get(message, ana_db:sql_error(E))})
    end.

quote(SchemaTable) ->
    [S, T] = binary:split(SchemaTable, <<".">>),
    [qi(S), ".", qi(T)].

qi(Ident) -> [$", binary:replace(Ident, <<"\"">>, <<"\"\"">>, [global]), $"].

lit(S) -> [$', binary:replace(S, <<"'">>, <<"''">>, [global]), $'].

now_text() -> list_to_binary(calendar:system_time_to_rfc3339(erlang:system_time(second), [{offset, "Z"}])).
