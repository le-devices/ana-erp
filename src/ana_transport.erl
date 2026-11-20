%% Transport packages between instances (spec 034, RF-034-02..05).
%%
%% A package carries definitions — programs (source and properties), commands and parameters —
%% never business data. It is signed with this instance's Ed25519 key (private part in the
%% vault, spec 017); the destination accepts only registered origins, checks the signature
%% over the exact manifest bytes and every item's hash, runs a preflight (conflicts, missing
%% dependencies) and imports everything in one transaction. Undo restores the previous state.
-module(ana_transport).

-export([public_key/1, origins/0, save_origin/3, delete_origin/2, export/2, receive_package/2,
         import/3, revert/2, refuse/3, list/0, get/1]).
-export([classify/3, item_sha/1, dependencies/1]).

-define(FORMAT, <<"ana-transport/1">>).
-define(MAX_ITEMS, 500).

%% ---------------------------------------------------------------- instance key

-spec public_key(map()) -> {ok, map()} | {error, binary()}.
public_key(User) ->
    case key(User) of
        {ok, Pub, _} -> {ok, (ana_instance:info())#{public_key => base64:encode(Pub), fingerprint => fingerprint(Pub)}};
        E -> E
    end.

fingerprint(Pub) -> binary:part(binary:encode_hex(crypto:hash(sha256, Pub), lowercase), 0, 16).

key(#{username := Who}) ->
    case ana_db:one("SELECT public_key, ciphertext, nonce, tag FROM ana_system.instance_key WHERE id = 1", []) of
        {ok, #{<<"public_key">> := P, <<"ciphertext">> := C, <<"nonce">> := N, <<"tag">> := T}} ->
            case ana_vault:master_key() of
                undefined -> {error, <<"cofre desligado: defina ANA_MASTER_KEY"/utf8>>};
                MK ->
                    case ana_vault:decrypt(<<"instance">>, <<"ed25519">>, {base64:decode(C), base64:decode(N), base64:decode(T)}, MK) of
                        {ok, Priv} -> {ok, base64:decode(P), Priv};
                        error -> {error, <<"a chave da instância não confere com a chave mestra"/utf8>>}
                    end
            end;
        {ok, undefined} ->
            case ana_vault:enabled() of
                false -> {error, <<"cofre desligado: defina ANA_MASTER_KEY para assinar pacotes"/utf8>>};
                true ->
                    {Pub, Priv} = crypto:generate_key(eddsa, ed25519),
                    {C, N, T} = ana_vault:encrypt(<<"instance">>, <<"ed25519">>, Priv),
                    {ok, _} = ana_db:exec("INSERT INTO ana_system.instance_key (public_key, ciphertext, nonce, tag, created_by) "
                                          "VALUES ($1, $2, $3, $4, $5) ON CONFLICT (id) DO NOTHING", [Pub, C, N, T, Who]),
                    ana_admin:log(Who, <<"transport.key.create">>, ana_instance:name(), null, #{fingerprint => fingerprint(Pub)}),
                    key(#{username => Who})        % another node may have won the race
            end;
        _ -> {error, <<"banco indisponível"/utf8>>}
    end.

%% ---------------------------------------------------------------- origins

origins() ->
    case ana_db:rows("SELECT name, public_key, active, created_by, created_at FROM ana_system.transport_origin ORDER BY name", []) of
        {ok, Rows} -> {ok, [R#{<<"fingerprint">> => fingerprint(base64:decode(P))} || R = #{<<"public_key">> := P} <- Rows]};
        E -> E
    end.

save_origin(Name, #{<<"public_key">> := B64} = B, #{username := Who}) when is_binary(B64) ->
    Active = maps:get(<<"active">>, B, true) =/= false,
    case {re:run(Name, <<"^[a-z][a-z0-9_-]{1,62}$">>), catch base64:decode(B64)} of
        {nomatch, _} -> {error, <<"nome de origem inválido (minúsculas, números, - e _)"/utf8>>};
        {_, Pub} when is_binary(Pub), byte_size(Pub) =:= 32 ->
            {ok, _} = ana_db:exec("INSERT INTO ana_system.transport_origin (name, public_key, active, created_by) VALUES ($1, $2, $3, $4) "
                                  "ON CONFLICT (name) DO UPDATE SET public_key = EXCLUDED.public_key, active = EXCLUDED.active",
                                  [Name, Pub, Active, Who]),
            ana_admin:log(Who, <<"transport.origin.save">>, Name, null, #{fingerprint => fingerprint(Pub), active => Active}),
            {ok, #{name => Name, fingerprint => fingerprint(Pub), active => Active}};
        _ -> {error, <<"chave pública inválida (32 bytes em base64)"/utf8>>}
    end;
save_origin(_, _, _) -> {error, <<"informe a chave pública da origem"/utf8>>}.

delete_origin(Name, #{username := Who}) ->
    case ana_db:exec("DELETE FROM ana_system.transport_origin WHERE name = $1", [Name]) of
        {ok, 1} -> ana_admin:log(Who, <<"transport.origin.delete">>, Name, null, null), {ok, #{deleted => Name}};
        {ok, 0} -> {error, not_found};
        E -> E
    end.

%% ---------------------------------------------------------------- export (origin)

-spec export(map(), map()) -> {ok, map()} | {error, binary()}.
export(B, User = #{username := Who}) ->
    Title = string:trim(text(maps:get(<<"title">>, B, <<>>))),
    Programs = names(maps:get(<<"programs">>, B, [])),
    Commands = names(maps:get(<<"commands">>, B, [])),
    Settings = names(maps:get(<<"settings">>, B, [])),
    N = length(Programs) + length(Commands) + length(Settings),
    if
        byte_size(Title) < 3 -> {error, <<"dê um título ao pacote (3 caracteres ou mais)"/utf8>>};
        N =:= 0 -> {error, <<"escolha ao menos um programa, comando ou parâmetro"/utf8>>};
        N > ?MAX_ITEMS -> {error, <<"pacote grande demais: divida em partes"/utf8>>};
        true ->
            case {program_items(Programs), command_items(Commands), setting_items(Settings)} of
                {{error, E}, _, _} -> {error, E};
                {_, {error, E}, _} -> {error, E};
                {_, _, {error, E}} -> {error, E};
                {{ok, P}, {ok, C}, {ok, S}} ->
                    %% Spec 064 (D7, CA-064-01): every program of the package through the quality gate; the report
                    %% travels inside the signed manifest.
                    {ok, Gate} = ana_quality:gate(Programs),
                    case {maps:get(ok, Gate), key(User)} of
                        {false, _} -> {error, #{code => <<"QUALITY_GATE">>, report => Gate,
                                                message => <<"portão de qualidade: há achados que bloqueiam o transporte "
                                                             "(corrija, ou peça isenção a outra pessoa)"/utf8>>}};
                        {true, {ok, _Pub, Priv}} -> sign_and_store(Title, B#{quality_gate => Gate}, P ++ C ++ S, Priv, Who);
                        {true, E} -> E
                    end
            end
    end.

sign_and_store(Title, B, Items, Priv, Who) ->
    Manifest = #{<<"format">> => ?FORMAT, <<"title">> => Title,
                 <<"description">> => text(maps:get(<<"description">>, B, <<>>)),
                 <<"tests">> => text(maps:get(<<"tests">>, B, <<>>)),
                 <<"author">> => Who, <<"origin">> => ana_instance:name(), <<"instance">> => ana_instance:role(),
                 <<"product_version">> => ana_instance:product_version(),
                 <<"created_at">> => list_to_binary(calendar:system_time_to_rfc3339(erlang:system_time(second), [{offset, "Z"}])),
                 <<"quality_gate">> => maps:get(quality_gate, B, null),
                 <<"items">> => Items},
    Bytes = iolist_to_binary(json:encode(Manifest)),
    Sig = crypto:sign(eddsa, none, Bytes, [Priv, ed25519]),
    Sha = sha(Bytes),
    {ok, #{<<"id">> := Id}} = ana_db:one(
        "INSERT INTO ana_system.transport (direction, title, description, author, origin, status, manifest, manifest_sha256) "
        "VALUES ('out', $1, $2, $3, $4, 'exported', $5, $6) RETURNING id",
        [Title, maps:get(<<"description">>, Manifest), Who, ana_instance:name(), Manifest, Sha]),
    ok = store_items(Id, Items),
    ana_admin:log(Who, <<"transport.export">>, Title, null, #{id => Id, items => length(Items), sha256 => Sha}),
    {ok, #{id => Id, sha256 => Sha,
           file_name => iolist_to_binary(["transporte-", integer_to_binary(Id), "-", ana_instance:name(), ".json"]),
           package => #{<<"format">> => ?FORMAT, <<"origin">> => ana_instance:name(),
                        <<"manifest_b64">> => base64:encode(Bytes), <<"signature">> => base64:encode(Sig)}}}.

program_items([]) -> {ok, []};
program_items(Names) ->
    {ok, Rows} = ana_db:rows(
        "SELECT p.name, p.kind, p.description, p.exposed, p.restricted, p.min_role, p.in_menu, p.portal, p.limits, p.active, p.source, "
        "  (SELECT encode(sha256(convert_to(v.source, 'UTF8')), 'hex') FROM ana_system.program_version v WHERE v.name = p.name "
        "     AND (v.comment = ANY($2::text[]) OR v.comment LIKE 'transporte%' OR v.comment LIKE 'desfaz transporte%') "
        "     ORDER BY v.version DESC LIMIT 1) AS base "
        "FROM ana_system.program p WHERE p.name = ANY($1::text[])",
        [Names, [<<"seed">>, <<"atualização do produto"/utf8>>]]),
    case Names -- [N || #{<<"name">> := N} <- Rows] of
        [] -> {ok, [#{<<"kind">> => <<"program">>, <<"name">> => N, <<"program_kind">> => K, <<"description">> => D,
                      <<"exposed">> => E, <<"restricted">> => R, <<"min_role">> => M, <<"in_menu">> => Me, <<"portal">> => Po,
                      <<"limits">> => L, <<"active">> => A, <<"source">> => S, <<"sha256">> => sha(S), <<"base_sha256">> => Base}
                    || #{<<"name">> := N, <<"kind">> := K, <<"description">> := D, <<"exposed">> := E, <<"restricted">> := R,
                         <<"min_role">> := M, <<"in_menu">> := Me, <<"portal">> := Po, <<"limits">> := L, <<"active">> := A,
                         <<"source">> := S, <<"base">> := Base} <- Rows, is_binary(S)]};
        Missing -> {error, iolist_to_binary([<<"programas inexistentes: "/utf8>>, lists:join(<<", ">>, Missing)])}
    end.

command_items([]) -> {ok, []};
command_items(Codes) ->
    {ok, Rows} = ana_db:rows("SELECT code, program, description FROM ana_system.command WHERE code = ANY($1::text[])", [Codes]),
    case Codes -- [C || #{<<"code">> := C} <- Rows] of
        [] -> {ok, [item_with_sha(#{<<"kind">> => <<"command">>, <<"name">> => C, <<"program">> => P, <<"description">> => D})
                    || #{<<"code">> := C, <<"program">> := P, <<"description">> := D} <- Rows]};
        Missing -> {error, iolist_to_binary([<<"comandos inexistentes: "/utf8>>, lists:join(<<", ">>, Missing)])}
    end.

setting_items(Keys) ->
    Known = [atom_to_binary(K) || {K, _, _, _, _, _, _} <- ana_settings:definitions()],
    case Keys -- Known of
        [] -> {ok, [item_with_sha(#{<<"kind">> => <<"setting">>, <<"name">> => K, <<"value">> => ana_settings:get(binary_to_atom(K))})
                    || K <- Keys]};
        Unknown -> {error, iolist_to_binary([<<"parâmetros inexistentes: "/utf8>>, lists:join(<<", ">>, Unknown)])}
    end.

item_with_sha(I) -> I#{<<"sha256">> => item_sha(I)}.

%% What each item's hash covers (recomputed by the destination).
-spec item_sha(map()) -> binary().
item_sha(#{<<"kind">> := <<"program">>, <<"source">> := S}) -> sha(S);
item_sha(#{<<"kind">> := <<"command">>, <<"name">> := C, <<"program">> := P, <<"description">> := D}) ->
    sha([C, 0, P, 0, text(D)]);
item_sha(#{<<"kind">> := <<"setting">>, <<"name">> := K, <<"value">> := V}) ->
    sha([K, 0, iolist_to_binary(json:encode(V))]);
item_sha(_) -> <<>>.

store_items(Id, Items) ->
    {ok, _} = ana_db:exec(
        "INSERT INTO ana_system.transport_item (transport_id, seq, kind, name, new_sha256, base_sha256) "
        "SELECT $1, s, k, n, h, b FROM unnest($2::int[], $3::text[], $4::text[], $5::text[], $6::text[]) AS x(s, k, n, h, b)",
        [Id, lists:seq(1, length(Items)), [K || #{<<"kind">> := K} <- Items], [N || #{<<"name">> := N} <- Items],
         [H || #{<<"sha256">> := H} <- Items], [maps:get(<<"base_sha256">>, I, null) || I <- Items]]),
    ok.

%% ---------------------------------------------------------------- receive (destination)

-spec receive_package(binary(), map()) -> {ok, map()} | {error, binary()}.
receive_package(Body, #{username := Who}) ->
    case decode_package(Body) of
        {ok, Manifest, Sha} ->
            Pre = preflight(Manifest),
            Items = maps:get(<<"items">>, Manifest),
            case ana_db:one(
                    "INSERT INTO ana_system.transport (direction, title, description, author, origin, status, manifest, manifest_sha256, "
                    "  preflight, received_by, received_at) VALUES ('in', $1, $2, $3, $4, 'received', $5, $6, $7, $8, now()) RETURNING id",
                    [maps:get(<<"title">>, Manifest), text(maps:get(<<"description">>, Manifest, <<>>)), maps:get(<<"author">>, Manifest),
                     maps:get(<<"origin">>, Manifest), Manifest, Sha, Pre, Who]) of
                {ok, #{<<"id">> := Id}} ->
                    ok = store_items(Id, Items),
                    ana_admin:log(Who, <<"transport.receive">>, maps:get(<<"title">>, Manifest), null,
                                  #{id => Id, origin => maps:get(<<"origin">>, Manifest), sha256 => Sha}),
                    {ok, #{id => Id, preflight => Pre}};
                {error, #{sqlstate := <<"23505">>}} -> {error, <<"este pacote já foi recebido"/utf8>>};
                {error, #{message := M}} -> {error, M}
            end;
        E -> E
    end.

decode_package(Body) ->
    try json:decode(Body) of
        #{<<"format">> := ?FORMAT, <<"origin">> := Origin, <<"manifest_b64">> := MB64, <<"signature">> := SB64}
          when is_binary(Origin), is_binary(MB64), is_binary(SB64) ->
            case ana_db:one("SELECT public_key FROM ana_system.transport_origin WHERE name = $1 AND active", [Origin]) of
                {ok, #{<<"public_key">> := P}} ->
                    Bytes = base64:decode(MB64),
                    Sig = base64:decode(SB64),
                    case crypto:verify(eddsa, none, Bytes, Sig, [base64:decode(P), ed25519]) of
                        true -> check_manifest(json:decode(Bytes), Origin, sha(Bytes));
                        false -> {error, <<"assinatura inválida: o pacote foi alterado ou não é desta origem"/utf8>>}
                    end;
                {ok, undefined} -> {error, <<"origem não cadastrada ou inativa: "/utf8, Origin/binary>>};
                _ -> {error, <<"banco indisponível"/utf8>>}
            end;
        _ -> {error, <<"arquivo não é um pacote de transporte do ANA"/utf8>>}
    catch _:_ -> {error, <<"arquivo não é um pacote de transporte do ANA"/utf8>>}
    end.

check_manifest(#{<<"origin">> := Origin, <<"items">> := Items, <<"title">> := T, <<"author">> := A,
                 <<"product_version">> := PV} = M, Origin, Sha) when is_list(Items), is_binary(T), is_binary(A), is_binary(PV) ->
    Major = fun(V) -> hd(binary:split(V, <<".">>)) end,
    Bad = [maps:get(<<"name">>, I, <<"?">>) || I <- Items, not valid_item(I)],
    if
        Items =:= [] orelse length(Items) > ?MAX_ITEMS -> {error, <<"pacote sem itens ou grande demais"/utf8>>};
        Bad =/= [] -> {error, iolist_to_binary([<<"itens com conteúdo que não confere com o hash: "/utf8>>, lists:join(<<", ">>, Bad)])};
        true ->
            case Major(PV) =:= Major(ana_instance:product_version()) of
                true ->
                    case ana_quality:check_manifest(M) of
                        ok -> {ok, M, Sha};
                        Refused -> Refused
                    end;
                false -> {error, <<"pacote de outra versão maior do produto ("/utf8, PV/binary, ")">>}
            end
    end;
check_manifest(_, _, _) -> {error, <<"manifesto incompleto ou de outra origem"/utf8>>}.

valid_item(#{<<"kind">> := <<"program">>, <<"name">> := N, <<"source">> := S, <<"sha256">> := H} = I)
  when is_binary(N), is_binary(S), is_binary(H) ->
    ana_program:valid_name(N) andalso item_sha(I) =:= H;
valid_item(#{<<"kind">> := <<"command">>, <<"name">> := C, <<"program">> := P, <<"sha256">> := H} = I)
  when is_binary(C), is_binary(P), is_binary(H) ->
    item_sha(I) =:= H;
valid_item(#{<<"kind">> := <<"setting">>, <<"name">> := K, <<"value">> := V, <<"sha256">> := H} = I) when is_binary(K) ->
    item_sha(I) =:= H andalso ana_settings:valid(K, V);
valid_item(_) -> false.

%% ---------------------------------------------------------------- preflight

%% new | unchanged | update | conflict (changed here since the origin's base).
-spec classify(binary() | null, binary(), binary() | null) -> binary().
classify(null, _New, _Base) -> <<"new">>;
classify(New, New, _) -> <<"unchanged">>;
classify(Target, _New, Target) -> <<"update">>;
classify(_, _, _) -> <<"conflict">>.

preflight(#{<<"items">> := Items}) ->
    Programs = [I || I = #{<<"kind">> := <<"program">>} <- Items],
    {ok, Rows} = ana_db:rows("SELECT name, active, encode(sha256(convert_to(source, 'UTF8')), 'hex') AS sha "
                             "FROM ana_system.program WHERE name = ANY($1::text[])", [[N || #{<<"name">> := N} <- Programs]]),
    Here = maps:from_list([{N, S} || #{<<"name">> := N, <<"sha">> := S} <- Rows]),
    PStatus = [#{kind => <<"program">>, name => N,
                 status => classify(maps:get(N, Here, null), H, maps:get(<<"base_sha256">>, I, null))}
               || I = #{<<"name">> := N, <<"sha256">> := H} <- Programs],
    Others = [#{kind => K, name => N, status => other_status(I)} || I = #{<<"kind">> := K, <<"name">> := N} <- Items, K =/= <<"program">>],
    Deps = lists:usort(lists:append([dependencies(S) || #{<<"source">> := S} <- Programs])),
    InPackage = [N || #{<<"name">> := N} <- Programs],
    {ok, Existing} = ana_db:rows("SELECT name FROM ana_system.program WHERE active AND name = ANY($1::text[])", [Deps]),
    Missing = Deps -- (InPackage ++ [N || #{<<"name">> := N} <- Existing]),
    All = PStatus ++ Others,
    Conflicts = [N || #{name := N, status := <<"conflict">>} <- All],
    #{items => All, conflicts => Conflicts, missing => Missing, ok => Conflicts =:= [] andalso Missing =:= []}.

other_status(#{<<"kind">> := <<"command">>, <<"name">> := C} = I) ->
    case ana_db:one("SELECT code, program, description FROM ana_system.command WHERE code = $1", [C]) of
        {ok, undefined} -> <<"new">>;
        {ok, #{<<"program">> := P, <<"description">> := D}} ->
            case item_sha(#{<<"kind">> => <<"command">>, <<"name">> => C, <<"program">> => P, <<"description">> => D}) =:= maps:get(<<"sha256">>, I) of
                true -> <<"unchanged">>;
                false -> <<"update">>
            end
    end;
other_status(#{<<"kind">> := <<"setting">>, <<"name">> := K, <<"value">> := V}) ->
    case ana_settings:get(binary_to_existing_atom(K)) =:= V of
        true -> <<"unchanged">>;
        false -> <<"update">>
    end.

%% Programs a source depends on: ana.call("x.y") and from ana_lib.<ns> import <name>.
-spec dependencies(binary()) -> [binary()].
dependencies(Source) ->
    Calls = case re:run(Source, <<"ana\\.call\\(\\s*[\"']([a-z][a-z0-9_]*\\.[a-z][a-z0-9_]*)[\"']">>,
                        [global, {capture, all_but_first, binary}]) of
        {match, L} -> [N || [N] <- L];
        nomatch -> []
    end,
    Libs = case re:run(Source, <<"from\\s+ana_lib\\.([a-z][a-z0-9_]*)\\s+import\\s+([^\\n#]+)">>,
                       [global, {capture, all_but_first, binary}]) of
        {match, M} -> [<<Ns/binary, ".", Name/binary>> || [Ns, Names] <- M, X <- binary:split(Names, <<",">>, [global]),
                                                           [Name | _] <- [string:lexemes(string:trim(X), " ()")],
                                                           re:run(Name, <<"^[a-z][a-z0-9_]*$">>) =/= nomatch];
        nomatch -> []
    end,
    lists:usort(Calls ++ Libs).

%% ---------------------------------------------------------------- import / undo

-spec import(integer(), map(), map()) -> {ok, map()} | {error, term()}.
import(Id, B, User = #{username := Who}) ->
    case load(Id) of
        {ok, #{<<"direction">> := <<"in">>, <<"status">> := <<"received">>, <<"manifest">> := M, <<"received_by">> := Rcv}} ->
            Accepted = names(maps:get(<<"accept_conflicts">>, B, [])),
            AcceptMissing = maps:get(<<"accept_missing">>, B, false) =:= true,
            Pre = preflight(M),
            FourEyes = ana_settings:get(transport_four_eyes) =:= 1,
            if
                FourEyes andalso Rcv =:= Who ->
                    {error, <<"quatro olhos: quem recebeu o pacote não pode importá-lo"/utf8>>};
                true ->
                    case {maps:get(conflicts, Pre) -- Accepted, maps:get(missing, Pre)} of
                        {[], Missing} when Missing =:= []; AcceptMissing -> apply_items(Id, M, Pre, User);
                        {[], Missing} -> {error, #{code => <<"MISSING_DEPENDENCIES">>, message =>
                                                   <<"o pacote chama programas que não existem aqui"/utf8>>, missing => Missing}};
                        {Open, _} -> {error, #{code => <<"CONFLICTS">>, message =>
                                               <<"programas alterados aqui depois da origem: aceite explicitamente cada um"/utf8>>,
                                               conflicts => Open}}
                    end
            end;
        {ok, #{<<"status">> := S}} -> {error, <<"pacote em estado "/utf8, S/binary, ": não pode ser importado"/utf8>>};
        {ok, undefined} -> {error, not_found};
        E -> E
    end.

apply_items(Id, #{<<"items">> := Items, <<"title">> := Title}, Pre, #{username := Who}) ->
    Comment = iolist_to_binary(["transporte #", integer_to_binary(Id), ": ", Title]),
    %% Inspection (Python) before the transaction: a program with a syntax error is not imported.
    Insp = [{N, ana_program:inspect_fields(#{<<"source">> => S, <<"kind">> => maps:get(<<"program_kind">>, I, <<"program">>)})}
            || I = #{<<"kind">> := <<"program">>, <<"name">> := N, <<"source">> := S} <- Items],
    case [N || {N, #{params := null, warning := W}} <- Insp, W =/= null] of
        [_ | _] = Broken -> {error, iolist_to_binary([<<"programas com erro de sintaxe: "/utf8>>, lists:join(<<", ">>, Broken)])};
        [] ->
            R = try ana_db:transaction(fun(C) ->
                    {ok, #{rows := [[<<"received">>]]}} =
                        ana_db:query(C, "SELECT status FROM ana_system.transport WHERE id = $1 FOR UPDATE", [Id]),
                    Done = [apply_item(C, Seq, I, maps:from_list(Insp), Comment, Who) || {Seq, I} <- lists:zip(lists:seq(1, length(Items)), Items)],
                    _ = [{ok, _} = ana_db:query(C, "UPDATE ana_system.transport_item SET previous = $3, created_version = $4 "
                                               "WHERE transport_id = $1 AND seq = $2", [Id, Seq, Prev, V]) || {Seq, Prev, V} <- Done],
                    {ok, _} = ana_db:query(C, "UPDATE ana_system.transport SET status = 'imported', imported_by = $2, imported_at = now(), "
                                              "preflight = $3 WHERE id = $1", [Id, Who, Pre]),
                    {ok, length(Done)}
                end)
            catch throw:{abort, Why} -> {error, Why}
            end,
            case R of
                {ok, N} ->
                    _ = [ana_program:invalidate(Nm) || #{<<"kind">> := <<"program">>, <<"name">> := Nm} <- Items],
                    %% Spec 045 (D6): the variants of the programs that arrived follow their parameters.
                    _ = [catch ana_variants:validate_program(Nm) || #{<<"kind">> := <<"program">>, <<"name">> := Nm} <- Items],
                    ana_admin:log(Who, <<"transport.import">>, Title, null, #{id => Id, items => N}),
                    {ok, #{id => Id, imported => N}};
                E -> E
            end
    end.

apply_item(C, Seq, #{<<"kind">> := <<"program">>, <<"name">> := N, <<"source">> := S} = I, Insp, Comment, Who) ->
    Prev = row(C, "SELECT version, source, kind, description, exposed, restricted, min_role, in_menu, portal, limits, active "
                  "FROM ana_system.program WHERE name = $1 FOR UPDATE", [N]),
    Fields0 = #{<<"source">> => S, <<"kind">> => maps:get(<<"program_kind">>, I, <<"program">>), <<"comment">> => Comment,
                <<"description">> => text(maps:get(<<"description">>, I, <<>>)), <<"exposed">> => maps:get(<<"exposed">>, I, false),
                <<"restricted">> => maps:get(<<"restricted">>, I, false), <<"min_role">> => maps:get(<<"min_role">>, I, <<"user">>),
                <<"in_menu">> => maps:get(<<"in_menu">>, I, true), <<"portal">> => maps:get(<<"portal">>, I, false),
                <<"limits">> => maps:get(<<"limits">>, I, #{}), <<"active">> => maps:get(<<"active">>, I, true)},
    Fields = case Prev of undefined -> Fields0; #{<<"version">> := V} -> Fields0#{<<"base_version">> => V} end,
    case ana_program:write_in(C, N, Fields, maps:get(N, Insp, undefined), Who) of
        {ok, #{version := NV}} -> {Seq, Prev, NV};
        {error, E} -> throw({abort, iolist_to_binary(io_lib:format("~ts: ~0tp", [N, E]))})
    end;
apply_item(C, Seq, #{<<"kind">> := <<"command">>, <<"name">> := Code, <<"program">> := P, <<"description">> := D}, _, _, _) ->
    Prev = row(C, "SELECT program, description FROM ana_system.command WHERE code = $1", [Code]),
    case ana_db:query(C, "INSERT INTO ana_system.command (code, program, description) VALUES ($1, $2, $3) "
                         "ON CONFLICT (code) DO UPDATE SET program = EXCLUDED.program, description = EXCLUDED.description",
                      [Code, P, text(D)]) of
        {ok, _} -> {Seq, Prev, null};
        {error, #{message := M}} -> throw({abort, <<"comando "/utf8, Code/binary, ": ", M/binary>>})
    end;
apply_item(C, Seq, #{<<"kind">> := <<"setting">>, <<"name">> := K, <<"value">> := V}, _, _, Who) ->
    Prev = #{<<"value">> => ana_settings:get(binary_to_existing_atom(K))},
    ok = set_setting(C, K, V, Who),
    {Seq, Prev, null}.

set_setting(C, K, V, Who) ->
    {ok, _} = ana_db:query(C, "INSERT INTO ana_system.setting (key, value, updated_by) VALUES ($1, $2::text::jsonb, $3) "
                              "ON CONFLICT (key) DO UPDATE SET value = EXCLUDED.value, updated_at = now(), updated_by = EXCLUDED.updated_by",
                           [K, iolist_to_binary(json:encode(V)), Who]),
    {ok, _} = ana_db:query(C, "SELECT pg_notify('ana_setting', $1)", [K]),      % every node reloads after COMMIT
    ok.

-spec revert(integer(), map()) -> {ok, map()} | {error, term()}.
revert(Id, #{username := Who}) ->
    case load(Id) of
        {ok, #{<<"direction">> := <<"in">>, <<"status">> := <<"imported">>, <<"title">> := Title}} ->
            Comment = iolist_to_binary(["desfaz transporte #", integer_to_binary(Id)]),
            {ok, Items} = ana_db:rows("SELECT seq, kind, name, previous FROM ana_system.transport_item WHERE transport_id = $1 "
                                      "ORDER BY seq DESC", [Id]),
            R = try ana_db:transaction(fun(C) ->
                    {ok, #{rows := [[<<"imported">>]]}} =
                        ana_db:query(C, "SELECT status FROM ana_system.transport WHERE id = $1 FOR UPDATE", [Id]),
                    _ = [undo_item(C, I, Comment, Who) || I <- Items],
                    {ok, _} = ana_db:query(C, "UPDATE ana_system.transport SET status = 'reverted', reverted_by = $2, reverted_at = now() "
                                              "WHERE id = $1", [Id, Who]),
                    {ok, length(Items)}
                end)
            catch throw:{abort, Why} -> {error, Why}
            end,
            case R of
                {ok, N} ->
                    _ = [ana_program:invalidate(Nm) || #{<<"kind">> := <<"program">>, <<"name">> := Nm} <- Items],
                    %% Spec 045 (D6): the variants of the programs that arrived follow their parameters.
                    _ = [catch ana_variants:validate_program(Nm) || #{<<"kind">> := <<"program">>, <<"name">> := Nm} <- Items],
                    ana_admin:log(Who, <<"transport.revert">>, Title, null, #{id => Id, items => N}),
                    {ok, #{id => Id, reverted => N}};
                E -> E
            end;
        {ok, #{<<"status">> := S}} -> {error, <<"pacote em estado "/utf8, S/binary, ": não há o que desfazer"/utf8>>};
        {ok, undefined} -> {error, not_found};
        E -> E
    end.

undo_item(C, #{<<"kind">> := <<"program">>, <<"name">> := N, <<"previous">> := Prev}, Comment, Who) ->
    Fields = case Prev of
        null -> #{<<"active">> => false};             % did not exist before: deactivated (history kept)
        #{<<"source">> := S} = P ->
            Props = maps:with([<<"kind">>, <<"description">>, <<"exposed">>, <<"restricted">>, <<"min_role">>, <<"in_menu">>,
                               <<"portal">>, <<"limits">>, <<"active">>], P),
            Props#{<<"source">> => S, <<"comment">> => Comment}
    end,
    Insp = case Fields of #{<<"source">> := Src} -> ana_program:inspect_fields(#{<<"source">> => Src, <<"kind">> => maps:get(<<"kind">>, Fields, undefined)}); _ -> undefined end,
    case ana_program:write_in(C, N, Fields, Insp, Who) of
        {ok, _} -> ok;
        {error, E} -> throw({abort, iolist_to_binary(io_lib:format("~ts: ~0tp", [N, E]))})
    end;
undo_item(C, #{<<"kind">> := <<"command">>, <<"name">> := Code, <<"previous">> := null}, _, _) ->
    {ok, _} = ana_db:query(C, "DELETE FROM ana_system.command WHERE code = $1", [Code]), ok;
undo_item(C, #{<<"kind">> := <<"command">>, <<"name">> := Code, <<"previous">> := #{<<"program">> := P, <<"description">> := D}}, _, _) ->
    {ok, _} = ana_db:query(C, "UPDATE ana_system.command SET program = $2, description = $3 WHERE code = $1", [Code, P, D]), ok;
undo_item(C, #{<<"kind">> := <<"setting">>, <<"name">> := K, <<"previous">> := #{<<"value">> := V}}, _, Who) ->
    set_setting(C, K, V, Who).

refuse(Id, B, #{username := Who}) ->
    Reason = string:trim(text(maps:get(<<"reason">>, B, <<>>))),
    case byte_size(Reason) >= 3 of
        false -> {error, <<"informe o motivo da recusa"/utf8>>};
        true ->
            case ana_db:exec("UPDATE ana_system.transport SET status = 'refused', refused_by = $2, refused_reason = $3 "
                             "WHERE id = $1 AND direction = 'in' AND status = 'received'", [Id, Who, Reason]) of
                {ok, 1} -> ana_admin:log(Who, <<"transport.refuse">>, integer_to_binary(Id), null, #{reason => Reason}),
                           {ok, #{id => Id, status => <<"refused">>}};
                {ok, 0} -> {error, <<"só pacotes recebidos e não importados podem ser recusados"/utf8>>};
                E -> E
            end
    end.

%% ---------------------------------------------------------------- reading

list() ->
    ana_db:rows("SELECT id, direction, title, author, origin, status, manifest_sha256, jsonb_array_length(manifest->'items') AS items, "
                "  preflight->'conflicts' AS conflicts, preflight->'missing' AS missing, received_by, received_at, imported_by, "
                "  imported_at, reverted_by, reverted_at, refused_by, refused_reason, created_at "
                "FROM ana_system.transport ORDER BY id DESC LIMIT 200", []).

get(Id) ->
    case load(Id) of
        {ok, undefined} -> {error, not_found};
        {ok, T} ->
            {ok, Items} = ana_db:rows("SELECT seq, kind, name, new_sha256, base_sha256, created_version, previous IS NOT NULL AS existed "
                                      "FROM ana_system.transport_item WHERE transport_id = $1 ORDER BY seq", [Id]),
            M = maps:get(<<"manifest">>, T),
            %% Side-by-side comparison: current source here for each program of the package.
            Programs = [N || #{<<"kind">> := <<"program">>, <<"name">> := N} <- maps:get(<<"items">>, M)],
            {ok, Here} = ana_db:rows("SELECT name, source FROM ana_system.program WHERE name = ANY($1::text[])", [Programs]),
            {ok, T#{<<"items">> => Items, <<"current">> => maps:from_list([{N, S} || #{<<"name">> := N, <<"source">> := S} <- Here])}};
        E -> E
    end.

load(Id) ->
    ana_db:one("SELECT id, direction, title, description, author, origin, status, manifest, manifest_sha256, preflight, "
               "  received_by, received_at, imported_by, imported_at, reverted_by, reverted_at, refused_by, refused_reason, created_at "
               "FROM ana_system.transport WHERE id = $1", [Id]).

%% ---------------------------------------------------------------- helpers

row(C, Sql, Params) ->
    case ana_db:query(C, Sql, Params) of
        {ok, #{columns := Cols, rows := [R | _]}} -> maps:from_list(lists:zip([N || #{name := N} <- Cols], R));
        {ok, _} -> undefined;
        {error, E} -> throw({abort, E})
    end.

names(L) when is_list(L) -> lists:usort([N || N <- L, is_binary(N), N =/= <<>>]);
names(_) -> [].

text(B) when is_binary(B) -> B;
text(_) -> <<>>.

sha(Data) -> binary:encode_hex(crypto:hash(sha256, Data), lowercase).
