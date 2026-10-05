%% File repository (spec 016): folders, versions, grants, share links, uploads,
%% signed downloads, search, entity folders and audit. Every permission comes from
%% files.level() (one rule, in the database); what a user may not see is 404.
-module(ana_files).
-export([level/2, list/2, create_folder/4, detail/2, store/7, upload_single/6, upload_init/5, upload_chunk/4,
         upload_status/2, upload_complete/3, download_token/4, zip_token/2, check_token/1, version_for/2,
         grant/2, revoke/2, link_create/3, link_revoke/2, share_find/1, share_take/3, delete_file/2,
         update_file/3, search/2, entity_folder/2, resolve/3, put_binary/6, get_binary/3, event/7,
         verify_sample/1, program/2]).

-define(VIEW, 1).
-define(DOWNLOAD, 2).
-define(UPLOAD, 3).
-define(MANAGE, 4).
-define(TOKEN_TTL, 300).
-define(PROGRAM_MAX, 32 * 1024 * 1024).
-define(ZIP_MAX, 100 * 1024 * 1024).
-define(LEVELS, [{<<"view">>, ?VIEW}, {<<"download">>, ?DOWNLOAD}, {<<"upload">>, ?UPLOAD}, {<<"manage">>, ?MANAGE}]).

%% ---------------------------------------------------------------- permissions

-spec level(map(), {folder | file, integer()}) -> 0..4.
level(#{username := U}, {folder, Id}) -> q_level(U, Id, null);
level(#{username := U}, {file, Id}) -> q_level(U, null, Id).

q_level(U, Folder, File) ->
    case ana_db:one("SELECT files.level($1, $2, $3) AS l", [U, Folder, File]) of
        {ok, #{<<"l">> := L}} when is_integer(L) -> L;
        _ -> 0
    end.

internal(#{role := R}) -> ana_security:has_role(R, <<"user">>).

%% 404 for what the user cannot see; 403 only when seeing but not allowed.
need(User, Res, Min) ->
    case level(User, Res) of
        L when L >= Min -> {ok, L};
        L when L >= ?VIEW -> {error, forbidden};
        _ -> {error, not_found}
    end.

%% ---------------------------------------------------------------- browsing

list(User = #{username := U}, null) ->
    Rows = case internal(User) of
        true -> rows("SELECT id, name, inherit, entity_kind, files.level($1, id, NULL) AS level FROM files.folder "
                     "WHERE parent_id IS NULL ORDER BY lower(name)", [U]);
        false ->
            %% External accounts start at what was shared with them (their party or themselves).
            rows("SELECT DISTINCT f.id, f.name, f.inherit, f.entity_kind, files.level($1, f.id, NULL) AS level "
                 "FROM files.folder f JOIN files.\"grant\" g ON g.folder_id = f.id AND NOT g.deny "
                 "  AND ((g.subject_kind = 'party' AND g.subject = $2) OR (g.subject_kind = 'user' AND g.subject = $1)) "
                 "ORDER BY f.name", [U, to_text(maps:get(party_id, User, null))])
    end,
    {ok, #{folder => null, path => [], level => case internal(User) of true -> ?UPLOAD; false -> 0 end,
           folders => [R || R = #{<<"level">> := L} <- Rows, L > 0], files => []}};
list(User = #{username := U}, Id) ->
    case need(User, {folder, Id}, ?VIEW) of
        {ok, L} ->
            Folders = rows("SELECT id, name, inherit, entity_kind, files.level($1, id, NULL) AS level FROM files.folder "
                           "WHERE parent_id = $2 ORDER BY lower(name)", [U, Id]),
            Files = rows("SELECT f.id, f.name, f.version, f.tags, f.status, f.updated_at, v.size, v.mime, v.created_by, "
                         "  files.level($1, NULL, f.id) AS level FROM files.file f "
                         "JOIN files.file_version v ON v.file_id = f.id AND v.version = f.version "
                         "WHERE f.folder_id = $2 AND f.status = 'active' ORDER BY lower(f.name)", [U, Id]),
            {ok, #{folder => Id, level => L, path => path(User, Id),
                   folders => [R || R = #{<<"level">> := X} <- Folders, X > 0],
                   files => [R || R = #{<<"level">> := X} <- Files, X > 0]}};
        E -> E
    end.

%% Breadcrumbs, only as far up as the user can see.
path(#{username := U}, Id) ->
    Chain = rows("WITH RECURSIVE c AS (SELECT id, parent_id, name, 0 AS d FROM files.folder WHERE id = $2 "
                 "UNION ALL SELECT f.id, f.parent_id, f.name, c.d + 1 FROM files.folder f JOIN c ON f.id = c.parent_id "
                 "WHERE c.d < 64) SELECT id, name, files.level($1, id, NULL) AS level FROM c ORDER BY d DESC", [U, Id]),
    lists:reverse(lists:takewhile(fun(#{<<"level">> := L}) -> L > 0 end,
                                  lists:reverse(Chain))).

create_folder(User = #{username := U}, Parent, Name, Inherit) ->
    Allowed = case Parent of
        null -> case internal(User) of true -> ok; false -> {error, forbidden} end;
        _ -> case need(User, {folder, Parent}, ?UPLOAD) of {ok, _} -> ok; Denied -> Denied end
    end,
    case {Allowed, valid_name(Name)} of
        {ok, true} ->
            case ana_db:rows("INSERT INTO files.folder (parent_id, name, inherit, created_by) VALUES ($1, $2, $3, $4) "
                             "ON CONFLICT DO NOTHING RETURNING id", [Parent, Name, Inherit =/= false, U]) of
                {ok, [#{<<"id">> := Id}]} -> event(<<"folder.create">>, Id, null, null, User, null, #{name => Name}),
                                             {ok, #{id => Id}};
                {ok, []} -> {error, <<"já existe uma pasta com esse nome aqui"/utf8>>};
                {error, #{message := M}} -> {error, M}
            end;
        {ok, false} -> {error, <<"nome inválido"/utf8>>};
        {Refused, _} -> Refused
    end.

valid_name(N) when is_binary(N), byte_size(N) > 0, byte_size(N) =< 200 ->
    re:run(N, "[/\\\\\\x00-\\x1f]", [{capture, none}]) =:= nomatch andalso N =/= <<".">> andalso N =/= <<"..">>;
valid_name(_) -> false.

detail(User, FileId) ->
    case need(User, {file, FileId}, ?VIEW) of
        {ok, L} ->
            {ok, F} = ana_db:one("SELECT f.id, f.folder_id, f.name, f.version, f.tags, f.status, f.created_by, f.created_at, "
                                 "  f.updated_at FROM files.file f WHERE f.id = $1", [FileId]),
            Versions = rows("SELECT version, name, mime, size, comment, created_by, created_at, blob AS sha256 "
                            "FROM files.file_version WHERE file_id = $1 ORDER BY version DESC", [FileId]),
            Manage = case L >= ?MANAGE of
                true -> #{grants => rows("SELECT g.id, g.subject_kind, g.subject, g.level, g.deny, g.expires_at, "
                                         "  g.granted_by, g.granted_at, CASE WHEN g.file_id IS NULL THEN 'pasta' ELSE 'arquivo' END AS scope "
                                         "FROM files.\"grant\" g WHERE g.file_id = $1 OR g.folder_id = $2 ORDER BY g.id", [FileId, maps:get(<<"folder_id">>, F)]),
                          links => rows("SELECT id, version, expires_at, max_downloads, downloads, revoked, "
                                        "  password_hash IS NOT NULL AS has_password, created_by, created_at "
                                        "FROM files.share_link WHERE file_id = $1 ORDER BY id DESC", [FileId]),
                          events => rows("SELECT action, version, username, ip, detail, at FROM files.event "
                                         "WHERE file_id = $1 ORDER BY at DESC LIMIT 200", [FileId])};
                false -> #{}
            end,
            {ok, Manage#{file => F, versions => Versions, level => L, path => path(User, maps:get(<<"folder_id">>, F))}};
        E -> E
    end.

%% ---------------------------------------------------------------- storing

%% Common end of every upload: size, real type, dedup, new file or new version.
store(User = #{username := U}, Folder, Name, Comment, Tmp, IV, Ip) ->
    try
        case need(User, {folder, Folder}, ?UPLOAD) of
            {ok, _} -> ok;
            Denied -> throw(Denied)
        end,
        valid_name(Name) orelse throw({error, <<"nome de arquivo inválido"/utf8>>}),
        case ana_vault:enabled() of
            false -> throw({error, <<"armazenamento desligado: defina ANA_MASTER_KEY"/utf8>>});
            true -> ok
        end,
        {ok, Sha, Mac, Size} = ana_files_store:finalize(Tmp, IV),
        Max = ana_settings:get(files_max_file_mb) * 1024 * 1024,
        Size > Max andalso throw({error, unicode:characters_to_binary(
                                    io_lib:format("arquivo acima do limite de ~b MB", [Max div 1048576]))}),
        Mime = case ana_files_type:detect(Name, ana_files_store:head(Tmp, IV, 8192)) of
            {ok, M} -> M;
            {error, Why} ->
                event(<<"upload.refused">>, Folder, null, null, User, Ip, #{name => Name, reason => Why}),
                throw({error, Why})
        end,
        ok = quota(Folder, Size),
        ok = ana_files_store:commit(Tmp, IV, Sha, Mac, Size),
        R = ana_db:transaction(fun(C) ->
            Existing = q1(C, "SELECT id, version FROM files.file WHERE folder_id = $1 AND lower(name) = lower($2) "
                             "AND status <> 'deleted' FOR UPDATE", [Folder, Name]),
            case Existing of
                undefined ->
                    #{<<"id">> := Id} = q1(C, "INSERT INTO files.file (folder_id, name, version, created_by) "
                                              "VALUES ($1, $2, 1, $3) RETURNING id", [Folder, Name, U]),
                    version_row(C, Id, 1, Sha, Name, Mime, Size, Comment, U),
                    {ok, #{file => Id, version => 1, created => true}};
                #{<<"id">> := Id, <<"version">> := V} ->
                    case q_level(U, null, Id) >= ?UPLOAD of
                        false -> throw({error, forbidden});
                        true -> ok
                    end,
                    version_row(C, Id, V + 1, Sha, Name, Mime, Size, Comment, U),
                    _ = q1(C, "UPDATE files.file SET version = $2, status = 'active', updated_at = now() WHERE id = $1 "
                              "RETURNING id", [Id, V + 1]),
                    {ok, #{file => Id, version => V + 1, created => false}}
            end
        end),
        case R of
            {ok, #{file := FileId, version := Ver, created := New}} ->
                event(case New of true -> <<"upload">>; false -> <<"version">> end, Folder, FileId, Ver, User, Ip,
                      #{name => Name, size => Size, sha256 => Sha, mime => Mime}),
                {ok, #{file => FileId, version => Ver, size => Size, mime => Mime, sha256 => Sha}};
            Err -> Err
        end
    catch
        throw:{error, _} = E -> ana_files_store:temp_delete(Tmp), E
    end.

version_row(C, Id, V, Sha, Name, Mime, Size, Comment, U) ->
    _ = q1(C, "INSERT INTO files.file_version (file_id, version, blob, name, mime, size, comment, created_by) "
              "VALUES ($1, $2, $3, $4, $5, $6, $7, $8) RETURNING version",
           [Id, V, Sha, Name, Mime, Size, case Comment of null -> <<>>; _ -> Comment end, U]),
    ok.

q1(C, Sql, Params) ->
    case ana_db:query(C, Sql, Params) of
        {ok, #{columns := Cols, rows := [R | _]}} -> maps:from_list(lists:zip([N || #{name := N} <- Cols], R));
        {ok, _} -> undefined;
        {error, E} -> throw({error, maps:get(message, E, <<"falha no banco"/utf8>>)})
    end.

%% Nearest ancestor with a quota: everything under it must fit.
quota(Folder, Size) ->
    case ana_db:one(
        "WITH RECURSIVE up AS (SELECT id, parent_id, quota_mb, 0 AS d FROM files.folder WHERE id = $1 "
        "  UNION ALL SELECT f.id, f.parent_id, f.quota_mb, up.d + 1 FROM files.folder f JOIN up ON f.id = up.parent_id WHERE up.d < 64), "
        "q AS (SELECT id, quota_mb FROM up WHERE quota_mb IS NOT NULL ORDER BY d LIMIT 1), "
        "down AS (SELECT id FROM q UNION ALL SELECT f.id FROM files.folder f JOIN down ON f.parent_id = down.id) "
        "SELECT (SELECT quota_mb FROM q) AS quota_mb, (SELECT COALESCE(sum(v.size), 0) FROM files.file_version v "
        "  JOIN files.file fi ON fi.id = v.file_id WHERE fi.folder_id IN (SELECT id FROM down)) AS used", [Folder]) of
        {ok, #{<<"quota_mb">> := null}} -> ok;
        {ok, #{<<"quota_mb">> := Q, <<"used">> := Used}} when Used + Size > Q * 1048576 ->
            throw({error, unicode:characters_to_binary(io_lib:format("cota da pasta (~b MB) excedida", [Q]))});
        _ -> ok
    end.

upload_single(User, Folder, Name, Comment, Body, Ip) ->
    {Tmp, IV} = ana_files_store:temp_new(),
    ok = ana_files_store:temp_write(Tmp, IV, 0, Body),
    store(User, Folder, Name, Comment, Tmp, IV, Ip).

%% Resumable upload: init → chunks at the offset received so far → complete.
upload_init(User = #{username := U}, Folder, Name, Size, Comment) ->
    Max = ana_settings:get(files_max_file_mb) * 1024 * 1024,
    case {need(User, {folder, Folder}, ?UPLOAD), valid_name(Name)} of
        {{ok, _}, true} when is_integer(Size), Size >= 0, Size =< Max ->
            Id = binary:encode_hex(crypto:strong_rand_bytes(16), lowercase),
            IV = crypto:strong_rand_bytes(16),
            ok = file:write_file(upload_path(Id), <<>>),
            {ok, _} = ana_db:exec("INSERT INTO files.upload (id, folder_id, name, size, iv, comment, created_by) "
                                  "VALUES ($1, $2, $3, $4, $5, $6, $7)", [Id, Folder, Name, Size, IV, nz(Comment), U]),
            {ok, #{id => Id, received => 0, size => Size}};
        {{ok, _}, true} -> {error, <<"tamanho inválido ou acima do limite"/utf8>>};
        {{ok, _}, false} -> {error, <<"nome de arquivo inválido"/utf8>>};
        {E, _} -> E
    end.

upload_path(Id) ->
    P = unicode:characters_to_binary(filename:join([ana_config:text("ANA_FILES_DIR", "/var/lib/ana/files"), "tmp",
                                                    <<"up-", Id/binary>>])),
    ok = filelib:ensure_dir(P),
    P.

upload_row(#{username := U}, Id) ->
    case re:run(Id, "^[0-9a-f]{32}$", [{capture, none}]) of
        match -> ana_db:one("SELECT id, folder_id, name, size, received, iv, comment FROM files.upload "
                            "WHERE id = $1 AND created_by = $2", [Id, U]);
        nomatch -> {ok, undefined}
    end.

upload_status(User, Id) ->
    case upload_row(User, Id) of
        {ok, #{<<"received">> := R, <<"size">> := S}} -> {ok, #{received => R, size => S}};
        _ -> {error, not_found}
    end.

upload_chunk(User, Id, Offset, Body) ->
    case upload_row(User, Id) of
        {ok, #{<<"received">> := R, <<"size">> := S, <<"iv">> := IV64}} when R =:= Offset, R + byte_size(Body) =< S ->
            ok = ana_files_store:temp_write(upload_path(Id), base64:decode(IV64), Offset, Body),
            case ana_db:exec("UPDATE files.upload SET received = received + $3 WHERE id = $1 AND received = $2",
                             [Id, Offset, byte_size(Body)]) of
                {ok, 1} -> {ok, #{received => Offset + byte_size(Body), size => S}};
                _ -> {error, <<"envio concorrente; consulte o recebido e continue"/utf8>>}
            end;
        {ok, #{<<"received">> := R}} -> {error, #{code => <<"OFFSET_MISMATCH">>, message => <<"deslocamento inesperado"/utf8>>,
                                                   received => R}};
        _ -> {error, not_found}
    end.

upload_complete(User, Id, Ip) ->
    case upload_row(User, Id) of
        {ok, #{<<"received">> := S, <<"size">> := S, <<"folder_id">> := F, <<"name">> := N, <<"iv">> := IV64,
               <<"comment">> := C}} ->
            {ok, _} = ana_db:exec("DELETE FROM files.upload WHERE id = $1", [Id]),
            store(User, F, N, C, upload_path(Id), base64:decode(IV64), Ip);
        {ok, #{}} -> {error, <<"envio incompleto"/utf8>>};
        _ -> {error, not_found}
    end.

nz(null) -> <<>>;
nz(B) -> B.

%% ---------------------------------------------------------------- downloads (RNF-016-01)

download_token(User = #{username := U}, FileId, Version, Inline) ->
    case need(User, {file, FileId}, ?DOWNLOAD) of
        {ok, _} ->
            case version_for(FileId, Version) of
                {ok, #{<<"version">> := V, <<"mime">> := Mime}} ->
                    Disp = case Inline =:= true andalso ana_files_type:inline_safe(Mime) of
                        true -> <<"inline">>;
                        false -> <<"attachment">>
                    end,
                    {ok, #{url => <<"/files/d/", (sign([<<"v">>, int(FileId), int(V), U, Disp]))/binary>>,
                           expires_in => ?TOKEN_TTL}};
                E -> E
            end;
        E -> E
    end.

zip_token(User = #{username := U}, Folder) ->
    case need(User, {folder, Folder}, ?DOWNLOAD) of
        {ok, _} -> {ok, #{url => <<"/files/d/", (sign([<<"z">>, int(Folder), <<"0">>, U, <<"attachment">>]))/binary>>,
                          expires_in => ?TOKEN_TTL}};
        E -> E
    end.

version_for(FileId, Version) ->
    case ana_db:one("SELECT v.file_id, v.version, v.name, v.mime, v.size, b.sha256, b.iv, b.mac "
                    "FROM files.file f JOIN files.file_version v ON v.file_id = f.id "
                    "  AND v.version = COALESCE($2::int, f.version) JOIN files.blob b ON b.sha256 = v.blob "
                    "WHERE f.id = $1 AND f.status = 'active'", [FileId, Version]) of
        {ok, #{} = R} -> {ok, R};
        _ -> {error, not_found}
    end.

int(I) -> integer_to_binary(I).

url_key() -> crypto:mac(hmac, sha256, ana_vault:master_key(), <<"ana-files-url-v1">>).

sign(Parts) ->
    Exp = int(erlang:system_time(second) + ?TOKEN_TTL),
    Payload = iolist_to_binary(lists:join(<<"|">>, Parts ++ [Exp])),
    <<(b64(Payload))/binary, ".", (b64(crypto:mac(hmac, sha256, url_key(), Payload)))/binary>>.

check_token(Token) ->
    try
        [P64, S64] = binary:split(Token, <<".">>),
        Payload = d64(P64),
        true = crypto:hash_equals(crypto:mac(hmac, sha256, url_key(), Payload), d64(S64)),
        [Kind, Ref, Ver, User, Disp, Exp] = binary:split(Payload, <<"|">>, [global]),
        true = binary_to_integer(Exp) >= erlang:system_time(second),
        {ok, #{kind => Kind, ref => binary_to_integer(Ref), version => binary_to_integer(Ver), user => User,
               disposition => Disp}}
    catch _:_ -> error
    end.

b64(B) -> base64:encode(B, #{mode => urlsafe, padding => false}).
d64(B) -> base64:decode(B, #{mode => urlsafe, padding => false}).

%% ---------------------------------------------------------------- grants (RF-016-03)

grant(User = #{username := U}, B) ->
    Res = case B of
        #{<<"file_id">> := F} when is_integer(F) -> {file, F};
        #{<<"folder_id">> := F} when is_integer(F) -> {folder, F};
        _ -> undefined
    end,
    Kind = maps:get(<<"subject_kind">>, B, null),
    Subject = to_text(maps:get(<<"subject">>, B, null)),
    Level = maps:get(<<"level">>, B, <<"view">>),
    Deny = maps:get(<<"deny">>, B, false) =:= true,
    Checks = [{Res =/= undefined, <<"informe a pasta ou o arquivo"/utf8>>},
              {lists:keymember(Level, 1, ?LEVELS), <<"nível inválido"/utf8>>},
              {subject_exists(Kind, Subject), <<"sujeito inexistente"/utf8>>}],
    case [M || {false, M} <- Checks] of
        [M | _] -> {error, M};
        [] ->
            case need(User, Res, ?MANAGE) of
                {ok, _} ->
                    {Folder, File} = case Res of {folder, X} -> {X, null}; {file, X} -> {null, X} end,
                    {ok, [#{<<"id">> := Id}]} = ana_db:rows(
                        "INSERT INTO files.\"grant\" (subject_kind, subject, folder_id, file_id, level, deny, expires_at, granted_by) "
                        "VALUES ($1, $2, $3, $4, $5, $6, $7::text::timestamptz, $8) "
                        "ON CONFLICT (subject_kind, subject, COALESCE(folder_id, 0), COALESCE(file_id, 0), deny) "
                        "DO UPDATE SET level = EXCLUDED.level, expires_at = EXCLUDED.expires_at, granted_by = EXCLUDED.granted_by, "
                        "  granted_at = now() RETURNING id",
                        [Kind, Subject, Folder, File, Level, Deny, maps:get(<<"expires_at">>, B, null), U]),
                    event(<<"grant">>, Folder, File, null, User, null,
                          #{subject_kind => Kind, subject => Subject, level => Level, deny => Deny}),
                    {ok, #{id => Id}};
                E -> E
            end
    end.

subject_exists(<<"user">>, S) -> exists("SELECT 1 FROM ana_system.app_user WHERE username = $1", S);
subject_exists(<<"group">>, S) -> exists("SELECT 1 FROM ana_system.access_group WHERE name = $1", S);
subject_exists(<<"role">>, S) -> lists:member(S, [<<"admin">>, <<"developer">>, <<"user">>, <<"external">>]);
subject_exists(<<"party">>, S) -> exists("SELECT 1 FROM base.party WHERE id::text = $1", S);
subject_exists(_, _) -> false.

exists(Sql, V) ->
    case ana_db:rows(Sql, [V]) of {ok, [_ | _]} -> true; _ -> false end.

revoke(User, Id) ->
    case ana_db:one("SELECT folder_id, file_id, subject_kind, subject, level FROM files.\"grant\" WHERE id = $1", [Id]) of
        {ok, #{<<"folder_id">> := Fo, <<"file_id">> := Fi} = G} ->
            Res = case Fi of null -> {folder, Fo}; _ -> {file, Fi} end,
            case need(User, Res, ?MANAGE) of
                {ok, _} ->
                    {ok, _} = ana_db:exec("DELETE FROM files.\"grant\" WHERE id = $1", [Id]),
                    event(<<"revoke">>, Fo, Fi, null, User, null, maps:with([<<"subject_kind">>, <<"subject">>, <<"level">>], G)),
                    {ok, #{id => Id}};
                E -> E
            end;
        _ -> {error, not_found}
    end.

%% ---------------------------------------------------------------- share links (RF-016-05)

link_create(User = #{username := U}, FileId, B) ->
    case need(User, {file, FileId}, ?MANAGE) of
        {ok, _} ->
            Hours = max(1, min(720, maps:get(<<"hours">>, B, 24))),
            Max = case maps:get(<<"max_downloads">>, B, null) of N when is_integer(N), N > 0 -> N; _ -> null end,
            Pass = case maps:get(<<"password">>, B, null) of
                P when is_binary(P), byte_size(P) >= 4 -> ana_security:hash_password(P);
                _ -> null
            end,
            Version = case maps:get(<<"version">>, B, null) of V when is_integer(V) -> V; _ -> null end,
            Token = b64(crypto:strong_rand_bytes(24)),
            {ok, [#{<<"id">> := Id}]} = ana_db:rows(
                "INSERT INTO files.share_link (token_hash, file_id, version, expires_at, password_hash, max_downloads, created_by) "
                "VALUES ($1, $2, $3, now() + make_interval(hours => $4), $5, $6, $7) RETURNING id",
                [hash(Token), FileId, Version, Hours, Pass, Max, U]),
            event(<<"link.create">>, null, FileId, Version, User, null,
                  #{link => Id, hours => Hours, max_downloads => Max, password => Pass =/= null}),
            {ok, #{id => Id, token => Token, url => <<"/share/", Token/binary>>}};
        E -> E
    end.

link_revoke(User, Id) ->
    case ana_db:one("SELECT file_id FROM files.share_link WHERE id = $1", [Id]) of
        {ok, #{<<"file_id">> := F}} ->
            case need(User, {file, F}, ?MANAGE) of
                {ok, _} ->
                    {ok, _} = ana_db:exec("UPDATE files.share_link SET revoked = true WHERE id = $1", [Id]),
                    event(<<"link.revoke">>, null, F, null, User, null, #{link => Id}),
                    {ok, #{id => Id}};
                E -> E
            end;
        _ -> {error, not_found}
    end.

hash(Token) -> binary:encode_hex(crypto:hash(sha256, Token), lowercase).

share_find(Token) when is_binary(Token), byte_size(Token) < 100 ->
    case ana_db:one("SELECT id, file_id, version, password_hash IS NOT NULL AS has_password, "
                    "  (NOT revoked AND expires_at > now() AND (max_downloads IS NULL OR downloads < max_downloads)) AS usable "
                    "FROM files.share_link WHERE token_hash = $1", [hash(Token)]) of
        {ok, #{<<"usable">> := true} = L} -> {ok, L};
        _ -> {error, gone}
    end;
share_find(_) -> {error, gone}.

%% Counts one download atomically (limit and validity checked in the same UPDATE).
share_take(Token, Password, Ip) ->
    case ana_db:one("SELECT id, password_hash FROM files.share_link WHERE token_hash = $1", [hash(Token)]) of
        {ok, #{<<"id">> := Id, <<"password_hash">> := PH}} ->
            PassOk = PH =:= null orelse (is_binary(Password) andalso ana_security:verify_password(Password, PH)),
            case PassOk of
                false ->
                    event(<<"link.password_wrong">>, null, null, null, #{username => null}, Ip, #{link => Id}),
                    {error, password};
                true ->
                    case ana_db:rows("UPDATE files.share_link SET downloads = downloads + 1 WHERE id = $1 AND NOT revoked "
                                     "AND expires_at > now() AND (max_downloads IS NULL OR downloads < max_downloads) "
                                     "RETURNING file_id, version", [Id]) of
                        {ok, [#{<<"file_id">> := F, <<"version">> := V}]} ->
                            event(<<"link.download">>, null, F, V, #{username => null}, Ip, #{link => Id}),
                            version_for(F, V);
                        _ -> {error, gone}
                    end
            end;
        _ -> {error, gone}
    end.

%% ---------------------------------------------------------------- other operations

delete_file(User, FileId) ->
    case need(User, {file, FileId}, ?MANAGE) of
        {ok, _} ->
            {ok, _} = ana_db:exec("UPDATE files.file SET status = 'deleted', updated_at = now() WHERE id = $1", [FileId]),
            event(<<"delete">>, null, FileId, null, User, null, null),
            {ok, #{id => FileId}};
        E -> E
    end.

update_file(User, FileId, B) ->
    case need(User, {file, FileId}, ?MANAGE) of
        {ok, _} ->
            Name = maps:get(<<"name">>, B, null),
            Tags = case maps:get(<<"tags">>, B, null) of
                L when is_list(L) -> [T || T <- L, is_binary(T), byte_size(T) =< 50];
                _ -> null
            end,
            case Name =:= null orelse valid_name(Name) of
                false -> {error, <<"nome inválido"/utf8>>};
                true ->
                    case ana_db:exec("UPDATE files.file SET name = COALESCE($2, name), tags = COALESCE($3::text[], tags), "
                                     "updated_at = now() WHERE id = $1", [FileId, Name, Tags]) of
                        {ok, _} -> event(<<"update">>, null, FileId, null, User, null, #{name => Name, tags => Tags}),
                                   {ok, #{id => FileId}};
                        {error, _} -> {error, <<"já existe um arquivo com esse nome na pasta"/utf8>>}
                    end
            end;
        E -> E
    end.

%% RF-016-08: name, tag, linked entity and period; only what the user may see.
search(#{username := U}, Q) ->
    Text = maps:get(<<"q">>, Q, null),
    {ok, rows("SELECT f.id, f.name, f.folder_id, fo.name AS folder, f.version, f.tags, f.updated_at, v.size, v.mime "
              "FROM files.file f JOIN files.folder fo ON fo.id = f.folder_id "
              "JOIN files.file_version v ON v.file_id = f.id AND v.version = f.version "
              "WHERE f.status = 'active' AND ($2::text IS NULL OR f.name ILIKE '%' || $2 || '%') "
              "  AND ($3::text IS NULL OR $3 = ANY(f.tags)) "
              "  AND ($4::text IS NULL OR f.updated_at >= $4::text::date) AND ($5::text IS NULL OR f.updated_at < $5::text::date + 1) "
              "  AND files.level($1, NULL, f.id) > 0 ORDER BY f.updated_at DESC LIMIT 200",
              [U, Text, maps:get(<<"tag">>, Q, null), maps:get(<<"from">>, Q, null), maps:get(<<"to">>, Q, null)])}.

%% ---------------------------------------------------------------- entity folders (RF-016-02)

%% Standard folders, created on first use by the core: Clientes/<party> (staff upload,
%% Faturas shared with the customer) and Projetos/<code> (manager manages,
%% Entregáveis shared with the customer).
entity_folder(party, Id) ->
    case ana_db:one("SELECT id FROM files.folder WHERE entity_kind = 'party' AND entity_id = $1", [Id]) of
        {ok, #{<<"id">> := F}} -> {ok, F};
        _ ->
            case ana_db:one("SELECT name FROM base.party WHERE id = $1", [Id]) of
                {ok, #{<<"name">> := Name}} ->
                    Root = system_root(1, <<"Clientes">>),
                    F = ensure(Root, safe_name(<<Name/binary, " (", (int(Id))/binary, ")">>), <<"party">>, Id),
                    Inv = ensure(F, <<"Faturas">>, null, null),
                    ok = system_grant(<<"party">>, int(Id), Inv, <<"download">>),
                    {ok, F};
                _ -> {error, not_found}
            end
    end;
entity_folder(project, Id) ->
    case ana_db:one("SELECT id FROM files.folder WHERE entity_kind = 'project' AND entity_id = $1", [Id]) of
        {ok, #{<<"id">> := F}} -> {ok, F};
        _ ->
            case ana_db:one("SELECT code, name, manager, customer_id FROM projects.project WHERE id = $1", [Id]) of
                {ok, #{<<"code">> := Code, <<"name">> := Name, <<"manager">> := Mgr, <<"customer_id">> := Cust}} ->
                    Root = system_root(2, <<"Projetos">>),
                    F = ensure(Root, safe_name(<<Code/binary, " — "/utf8, Name/binary>>), <<"project">>, Id),
                    ok = system_grant(<<"user">>, Mgr, F, <<"manage">>),
                    Del = ensure(F, <<"Entregáveis"/utf8>>, null, null),
                    ok = system_grant(<<"party">>, int(Cust), Del, <<"download">>),
                    {ok, F};
                _ -> {error, not_found}
            end
    end.

system_root(N, Name) ->
    case ana_db:one("SELECT id FROM files.folder WHERE entity_kind = 'system' AND entity_id = $1", [N]) of
        {ok, #{<<"id">> := F}} -> F;
        _ ->
            F = ensure(null, Name, <<"system">>, N),
            ok = system_grant(<<"role">>, <<"user">>, F, <<"upload">>),     % staff works with it (admin may narrow)
            F
    end.

ensure(Parent, Name, Kind, EntityId) ->
    _ = ana_db:exec("INSERT INTO files.folder (parent_id, name, entity_kind, entity_id, created_by) "
                    "VALUES ($1, $2, $3, $4, 'system') ON CONFLICT DO NOTHING", [Parent, Name, Kind, EntityId]),
    {ok, #{<<"id">> := F}} = ana_db:one("SELECT id FROM files.folder WHERE COALESCE(parent_id, 0) = COALESCE($1::bigint, 0) "
                                        "AND lower(name) = lower($2)", [Parent, Name]),
    F.

system_grant(Kind, Subject, Folder, Level) ->
    _ = ana_db:exec("INSERT INTO files.\"grant\" (subject_kind, subject, folder_id, level, granted_by) "
                    "VALUES ($1, $2, $3, $4, 'system') ON CONFLICT DO NOTHING", [Kind, Subject, Folder, Level]),
    ok.

safe_name(N) ->
    C = re:replace(N, "[/\\\\\\x00-\\x1f]", "-", [global, {return, binary}, unicode]),
    string:slice(C, 0, 200).

%% ---------------------------------------------------------------- programs (RF-016-09)

%% "/A/B/C" → folder id; Create makes missing levels (with the user's permissions).
resolve(User, Path, Create) when is_binary(Path) ->
    Parts = [P || P <- binary:split(Path, <<"/">>, [global]), P =/= <<>>],
    walk(User, null, Parts, Create);
resolve(_, _, _) -> {error, not_found}.

walk(_User, Folder, [], _) when Folder =/= null -> {ok, Folder};
walk(_User, null, [], _) -> {error, not_found};
walk(User, Parent, [Name | Rest], Create) ->
    case ana_db:one("SELECT id FROM files.folder WHERE COALESCE(parent_id, 0) = COALESCE($1::bigint, 0) "
                    "AND lower(name) = lower($2)", [Parent, Name]) of
        {ok, #{<<"id">> := Id}} -> walk(User, Id, Rest, Create);
        _ when Create ->
            case create_folder(User, Parent, Name, true) of
                {ok, #{id := Id}} -> walk(User, Id, Rest, Create);
                E -> E
            end;
        _ -> {error, not_found}
    end.

put_binary(User, Folder, Name, Data, Comment, Ip) when byte_size(Data) =< ?PROGRAM_MAX ->
    {Tmp, IV} = ana_files_store:temp_new(),
    ok = ana_files_store:temp_write(Tmp, IV, 0, Data),
    store(User, Folder, Name, Comment, Tmp, IV, Ip);
put_binary(_, _, _, _, _, _) -> {error, <<"conteúdo acima de 32 MB para programas"/utf8>>}.

get_binary(User, FileId, Version) ->
    case need(User, {file, FileId}, ?DOWNLOAD) of
        {ok, _} ->
            case version_for(FileId, Version) of
                {ok, #{<<"sha256">> := Sha, <<"iv">> := IV, <<"mac">> := Mac, <<"name">> := N, <<"mime">> := M,
                       <<"version">> := V}} ->
                    case ana_files_store:read_all(Sha, base64:decode(IV), base64:decode(Mac), ?PROGRAM_MAX) of
                        {ok, Bin} ->
                            event(<<"download">>, null, FileId, V, User, <<"program">>, null),
                            {ok, #{name => N, mime => M, version => V, data => Bin}};
                        {error, too_large} -> {error, <<"arquivo acima de 32 MB para programas"/utf8>>};
                        {error, _} -> {error, <<"conteúdo indisponível ou corrompido"/utf8>>}
                    end;
                E -> E
            end;
        E -> E
    end.

%% Operations for programs (protocol op "files"), always as the execution's user.
program(User, #{<<"action">> := <<"put">>} = A) ->
    case target_folder(User, A) of
        {ok, Folder} ->
            case catch base64:decode(maps:get(<<"data">>, A, <<>>)) of
                Data when is_binary(Data) ->
                    put_binary(User, Folder, maps:get(<<"name">>, A, null), Data, maps:get(<<"comment">>, A, null),
                               <<"program">>);
                _ -> {error, <<"conteúdo inválido"/utf8>>}
            end;
        E -> E
    end;
program(User, #{<<"action">> := <<"get">>, <<"file">> := F} = A) when is_integer(F) ->
    case get_binary(User, F, maps:get(<<"version">>, A, null)) of
        {ok, R = #{data := D}} -> {ok, R#{data := base64:encode(D)}};
        E -> E
    end;
program(User, #{<<"action">> := <<"list">>} = A) ->
    case maps:get(<<"folder">>, A, null) of
        null -> list(User, null);
        P when is_binary(P) -> case resolve(User, P, false) of {ok, Id} -> list(User, Id); E -> E end;
        Id when is_integer(Id) -> list(User, Id)
    end;
program(User, #{<<"action">> := <<"folder">>} = A) ->
    target_folder(User, A#{<<"create">> => maps:get(<<"create">>, A, true)});
program(User, #{<<"action">> := <<"grant">>} = A) ->
    grant(User, A);
program(_, _) ->
    {error, <<"operação de arquivos desconhecida"/utf8>>}.

%% folder (path or id) or entity {kind, id} + optional subfolder.
target_folder(User, A) ->
    Create = maps:get(<<"create">>, A, true) =:= true,
    Base = case A of
        #{<<"entity">> := #{<<"kind">> := K, <<"id">> := Id}} when is_integer(Id) ->
            case K of
                <<"party">> -> entity_folder(party, Id);
                <<"project">> -> entity_folder(project, Id);
                _ -> {error, <<"vínculo deve ser party ou project"/utf8>>}
            end;
        #{<<"folder">> := P} when is_binary(P) -> resolve(User, P, Create);
        #{<<"folder">> := Id} when is_integer(Id) -> {ok, Id};
        _ -> {error, <<"informe a pasta (caminho ou id) ou o vínculo"/utf8>>}
    end,
    case {Base, maps:get(<<"subfolder">>, A, null)} of
        {{ok, F}, null} -> {ok, F};
        {{ok, F}, Sub} when is_binary(Sub) ->
            case ana_db:one("SELECT id FROM files.folder WHERE parent_id = $1 AND lower(name) = lower($2)", [F, Sub]) of
                {ok, #{<<"id">> := S}} -> {ok, S};
                _ when Create -> case create_folder(User, F, Sub, true) of {ok, #{id := S}} -> {ok, S}; E -> E end;
                _ -> {error, not_found}
            end;
        {E, _} -> E
    end.

%% ---------------------------------------------------------------- audit and integrity

event(Action, Folder, File, Version, User, Ip, Detail) ->
    _ = ana_db:exec("INSERT INTO files.event (action, folder_id, file_id, version, username, ip, detail) "
                    "VALUES ($1, $2, $3, $4, $5, $6, $7)",
                    [Action, Folder, File, Version, maps:get(username, User, null), Ip,
                     case Detail of null -> null; _ -> Detail end]),
    ok.

%% RNF-016-03: oldest-verified blobs first; returns the corrupted or missing ones.
verify_sample(N) ->
    case ana_vault:enabled() of
        false -> [];
        true ->
            Bad = [Sha || #{<<"sha256">> := Sha, <<"iv">> := IV, <<"mac">> := Mac}
                              <- rows("SELECT sha256, iv, mac FROM files.blob ORDER BY verified_at NULLS FIRST LIMIT $1", [N]),
                          not check_blob(Sha, IV, Mac)],
            Bad
    end.

check_blob(Sha, IV, Mac) ->
    case ana_files_store:verify(Sha, base64:decode(IV), base64:decode(Mac)) of
        true ->
            {ok, _} = ana_db:exec("UPDATE files.blob SET verified_at = now() WHERE sha256 = $1", [Sha]),
            true;
        false ->
            logger:error("files: blob ~ts failed the integrity check", [Sha]),
            false
    end.

rows(Sql, Params) ->
    case ana_db:rows(Sql, Params) of
        {ok, R} -> R;
        {error, E} -> logger:warning("files query failed: ~0p", [E]), []
    end.

to_text(null) -> null;
to_text(I) when is_integer(I) -> integer_to_binary(I);
to_text(B) -> B.
