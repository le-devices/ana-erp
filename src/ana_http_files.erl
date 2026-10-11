%% HTTP of the file repository (spec 016).
%%
%% /api/files/...   session (internal users and external portal accounts; what one
%%                  may not see is 404)
%% /files/d/<token> signed URL (5 min) issued after the permission check: streams the
%%                  content with Range, attachment and a sandbox CSP (RNF-016-01)
%% /share/<token>   public share link (optional password, validity, download limit)
-module(ana_http_files).
-export([init/2]).

-define(READ_CHUNK, 1048576).

init(Req, api = S) ->
    {ok, guarded(Req, fun() -> api(cowboy_req:method(Req), cowboy_req:path_info(Req), Req) end), S};
init(Req, download = S) ->
    {ok, guarded(Req, fun() -> download(cowboy_req:binding(token, Req), Req) end), S};
init(Req, share = S) ->
    {ok, guarded(Req, fun() -> share(cowboy_req:method(Req), cowboy_req:binding(token, Req), Req) end), S}.

guarded(Req, Fun) ->
    try Fun()
    catch C:R:St ->
        logger:error("files HTTP error: ~0p:~0p ~0p", [C, R, St]),
        ana_http:reply_error(500, <<"INTERNAL">>, <<"erro interno">>, Req)
    end.

%% ---------------------------------------------------------------- API

api(Method, Path, Req) ->
    ana_http:require_any(Req, fun
        (#{must_change_password := true}) ->
            ana_http:reply_error(403, <<"PASSWORD_CHANGE_REQUIRED">>, <<"troque sua senha para continuar">>, Req);
        (U) -> route(Method, Path, U, Req)
    end).

route(<<"GET">>, [<<"folders">>], U, Req) ->
    reply(ana_files:list(U, qs_id(<<"parent">>, Req)), Req);
route(<<"POST">>, [<<"folders">>], U, Req) ->
    body(Req, fun(B, R) -> reply(ana_files:create_folder(U, id_or_null(maps:get(<<"parent">>, B, null)),
                                                         maps:get(<<"name">>, B, null), maps:get(<<"inherit">>, B, true)), R) end);
route(<<"GET">>, [<<"search">>], U, Req) ->
    reply(ana_files:search(U, ana_http:qs_map(Req)), Req);
route(<<"GET">>, [<<"files">>, Id], U, Req) ->
    with_int(Id, Req, fun(N) -> reply(ana_files:detail(U, N), Req) end);
route(<<"PUT">>, [<<"files">>, Id], U, Req) ->
    with_int(Id, Req, fun(N) -> body(Req, fun(B, R) -> reply(ana_files:update_file(U, N, B), R) end) end);
route(<<"DELETE">>, [<<"files">>, Id], U, Req) ->
    with_int(Id, Req, fun(N) -> reply(ana_files:delete_file(U, N), Req) end);
route(<<"POST">>, [<<"files">>, Id, <<"download">>], U, Req) ->
    with_int(Id, Req, fun(N) -> body(Req, fun(B, R) ->
        reply(ana_files:download_token(U, N, int_or_null(maps:get(<<"version">>, B, null)),
                                       maps:get(<<"inline">>, B, false)), R) end) end);
route(<<"POST">>, [<<"files">>, Id, <<"links">>], U, Req) ->
    with_int(Id, Req, fun(N) -> body(Req, fun(B, R) -> reply(ana_files:link_create(U, N, B), R) end) end);
route(<<"DELETE">>, [<<"links">>, Id], U, Req) ->
    with_int(Id, Req, fun(N) -> reply(ana_files:link_revoke(U, N), Req) end);
route(<<"PUT">>, [<<"folders">>, Id, <<"external">>], U, Req) ->
    with_int(Id, Req, fun(N) -> body(Req, fun(B, R) -> reply(ana_files:set_external(U, N, maps:get(<<"external">>, B, false) =:= true), R) end) end);
route(<<"POST">>, [<<"folders">>, Id, <<"zip">>], U, Req) ->
    with_int(Id, Req, fun(N) -> reply(ana_files:zip_token(U, N), Req) end);
route(<<"POST">>, [<<"grants">>], U, Req) ->
    body(Req, fun(B, R) -> reply(ana_files:grant(U, B), R) end);
route(<<"DELETE">>, [<<"grants">>, Id], U, Req) ->
    with_int(Id, Req, fun(N) -> reply(ana_files:revoke(U, N), Req) end);
%% Single upload: the body streams into the encrypted temp file (never whole in memory).
route(<<"POST">>, [<<"upload">>], U, Req) ->
    case {qs_id(<<"folder">>, Req), qs(<<"name">>, Req)} of
        {F, N} when is_integer(F), is_binary(N) ->
            {Tmp, IV} = ana_files_store:temp_new(),
            Max = ana_settings:get(files_max_file_mb) * 1048576,
            case receive_body(Req, Tmp, IV, 0, Max) of
                {ok, Req2} -> reply(ana_files:store(U, F, N, qs(<<"comment">>, Req), Tmp, IV, ana_http:ip(Req)), Req2);
                {too_large, Req2} ->
                    ana_files_store:temp_delete(Tmp),
                    ana_http:reply_error(413, <<"BODY_TOO_LARGE">>, <<"arquivo acima do limite"/utf8>>, Req2)
            end;
        _ -> invalid(Req)
    end;
route(<<"POST">>, [<<"uploads">>], U, Req) ->
    body(Req, fun(B, R) -> reply(ana_files:upload_init(U, id_or_null(maps:get(<<"folder">>, B, null)),
                                                       maps:get(<<"name">>, B, null), maps:get(<<"size">>, B, null),
                                                       maps:get(<<"comment">>, B, null)), R) end);
route(<<"GET">>, [<<"uploads">>, Id], U, Req) ->
    reply(ana_files:upload_status(U, Id), Req);
route(<<"PUT">>, [<<"uploads">>, Id], U, Req) ->
    case cowboy_req:read_body(Req, #{length => 16 * 1048576, period => 30000}) of
        {ok, Chunk, Req2} -> reply(ana_files:upload_chunk(U, Id, ana_http:qs_int(<<"offset">>, Req, -1), Chunk), Req2);
        {more, _, Req2} -> ana_http:reply_error(413, <<"CHUNK_TOO_LARGE">>, <<"parte acima de 16 MB"/utf8>>, Req2)
    end;
route(<<"POST">>, [<<"uploads">>, Id, <<"complete">>], U, Req) ->
    reply(ana_files:upload_complete(U, Id, ana_http:ip(Req)), Req);
route(_, _, _, Req) ->
    ana_http:reply_error(404, <<"NOT_FOUND">>, <<"rota inexistente">>, Req).

receive_body(Req, Tmp, IV, Offset, Max) ->
    case cowboy_req:read_body(Req, #{length => ?READ_CHUNK, period => 30000}) of
        {_, Data, Req2} when Offset + byte_size(Data) > Max -> {too_large, Req2};
        {ok, Data, Req2} -> ok = ana_files_store:temp_write(Tmp, IV, Offset, Data), {ok, Req2};
        {more, Data, Req2} ->
            ok = ana_files_store:temp_write(Tmp, IV, Offset, Data),
            receive_body(Req2, Tmp, IV, Offset + byte_size(Data), Max)
    end.

reply({ok, V}, Req) -> ana_http:json(200, V, Req);
reply({error, not_found}, Req) -> ana_http:reply_error(404, <<"NOT_FOUND">>, <<"não encontrado"/utf8>>, Req);
reply({error, forbidden}, Req) -> ana_http:reply_error(403, <<"FORBIDDEN">>, <<"sem permissão"/utf8>>, Req);
reply({error, Msg}, Req) when is_binary(Msg) -> ana_http:reply_error(400, <<"INVALID">>, Msg, Req);
reply({error, #{} = E}, Req) -> ana_http:json(400, #{error => E}, Req).

body(Req, Fun) ->
    case ana_http:read_json(Req) of
        {ok, B, Req2} when is_map(B) -> Fun(B, Req2);
        {_, Req2} -> invalid(Req2);
        {ok, _, Req2} -> invalid(Req2)
    end.

invalid(Req) -> ana_http:reply_error(400, <<"INVALID">>, <<"requisição inválida"/utf8>>, Req).

with_int(Id, Req, Fun) ->
    case catch binary_to_integer(Id) of
        N when is_integer(N), N > 0 -> Fun(N);
        _ -> ana_http:reply_error(404, <<"NOT_FOUND">>, <<"não encontrado"/utf8>>, Req)
    end.

qs(Name, Req) ->
    case lists:keyfind(Name, 1, cowboy_req:parse_qs(Req)) of
        {_, V} when is_binary(V), V =/= <<>> -> V;
        _ -> null
    end.

qs_id(Name, Req) -> id_or_null(qs(Name, Req)).

id_or_null(null) -> null;
id_or_null(N) when is_integer(N), N > 0 -> N;
id_or_null(B) when is_binary(B) -> case catch binary_to_integer(B) of N when is_integer(N), N > 0 -> N; _ -> null end;
id_or_null(_) -> null.

int_or_null(N) when is_integer(N) -> N;
int_or_null(_) -> null.

%% ---------------------------------------------------------------- signed download

download(Token, Req) ->
    case is_binary(Token) andalso ana_files:check_token(Token) of
        {ok, #{kind := <<"v">>, ref := File, version := V, user := U, disposition := Disp}} ->
            case ana_files:version_for(File, V) of
                {ok, Ver} ->
                    ana_files:event(<<"download">>, null, File, V, #{username => U}, ana_http:ip(Req), null),
                    send(Ver, Disp, Req, true);
                _ -> gone(Req)
            end;
        {ok, #{kind := <<"z">>, ref := Folder, user := U}} -> zip(Folder, U, Req);
        _ -> gone(Req)
    end.

gone(Req) -> ana_http:reply_error(410, <<"LINK_EXPIRED">>, <<"endereço expirado ou inválido"/utf8>>, Req).

%% Streams one version; Range when allowed (signed URLs, not share links that count).
send(#{<<"sha256">> := Sha, <<"iv">> := IV64, <<"mac">> := Mac64, <<"size">> := Size, <<"name">> := Name,
       <<"mime">> := Mime}, Disp, Req, RangeOk) ->
    IV = base64:decode(IV64),
    Range = case RangeOk of true -> range(cowboy_req:header(<<"range">>, Req), Size); false -> full end,
    Base = #{<<"content-type">> => case Disp of <<"inline">> -> Mime; _ -> <<"application/octet-stream">> end,
             <<"content-disposition">> => <<Disp/binary, "; filename*=UTF-8''", (encode(Name))/binary>>,
             <<"x-content-type-options">> => <<"nosniff">>,
             <<"content-security-policy">> => <<"sandbox; default-src 'none'; img-src 'self' data:; style-src 'unsafe-inline'">>,
             <<"accept-ranges">> => <<"bytes">>, <<"cache-control">> => <<"private, no-store">>},
    case Range of
        invalid ->
            cowboy_req:reply(416, #{<<"content-range">> => <<"bytes */", (integer_to_binary(Size))/binary>>}, Req);
        full ->
            %% Small files are checked before sending; big ones by the periodic integrity check.
            case Size =< 64 * 1048576 andalso not ana_files_store:verify(Sha, IV, base64:decode(Mac64)) of
                true -> ana_http:reply_error(500, <<"CORRUPTED">>, <<"conteúdo não confere; avise o administrador"/utf8>>, Req);
                false ->
                    Req2 = cowboy_req:stream_reply(200, Base#{<<"content-length">> => integer_to_binary(Size)}, Req),
                    stream(Sha, IV, 0, Size, Req2)
            end;
        {S, E} ->
            Len = E - S + 1,
            Req2 = cowboy_req:stream_reply(206, Base#{<<"content-length">> => integer_to_binary(Len),
                <<"content-range">> => iolist_to_binary(["bytes ", integer_to_binary(S), "-", integer_to_binary(E), "/",
                                                         integer_to_binary(Size)])}, Req),
            stream(Sha, IV, S, Len, Req2)
    end.

stream(Sha, IV, Start, Len, Req) ->
    ok = ana_files_store:stream(Sha, IV, Start, Len, fun(C) -> cowboy_req:stream_body(C, nofin, Req) end),
    ok = cowboy_req:stream_body(<<>>, fin, Req),
    Req.

range(undefined, _) -> full;
range(<<"bytes=", Spec/binary>>, Size) ->
    case binary:split(Spec, <<"-">>) of
        [<<>>, N] -> clamp(Size - to_int(N), Size - 1, Size);                 % last N bytes
        [S, <<>>] -> clamp(to_int(S), Size - 1, Size);
        [S, E] -> clamp(to_int(S), min(to_int(E), Size - 1), Size);
        _ -> full
    end;
range(_, _) -> full.

clamp(S, E, Size) when is_integer(S), is_integer(E), S >= 0, S =< E, S < Size -> {S, E};
clamp(_, _, 0) -> full;
clamp(_, _, _) -> invalid.

to_int(B) -> try binary_to_integer(B) catch _:_ -> -1 end.

encode(Name) -> list_to_binary(uri_string:quote(binary_to_list(unicode:characters_to_binary(Name)), "")).

%% ---------------------------------------------------------------- folder as ZIP (RF-016-08)

zip(Folder, U, Req) ->
    User = #{username => U},
    Files = rows("WITH RECURSIVE t AS (SELECT id, ''::text AS prefix FROM files.folder WHERE id = $1 "
                 "UNION ALL SELECT f.id, t.prefix || f.name || '/' FROM files.folder f JOIN t ON f.parent_id = t.id) "
                 "SELECT fi.id, t.prefix || fi.name AS path, v.size FROM t JOIN files.file fi ON fi.folder_id = t.id "
                 "JOIN files.file_version v ON v.file_id = fi.id AND v.version = fi.version "
                 "WHERE fi.status = 'active' AND files.level($2, NULL, fi.id) >= 2 ORDER BY path", [Folder, U]),
    case lists:sum([S || #{<<"size">> := S} <- Files]) of
        Total when Total > 100 * 1048576 ->
            ana_http:reply_error(413, <<"ZIP_TOO_LARGE">>, <<"pasta acima de 100 MB: baixe os arquivos separadamente"/utf8>>, Req);
        _ ->
            Entries = [{binary_to_list(unicode:characters_to_binary(P)), Data}
                       || #{<<"id">> := Id, <<"path">> := P} <- Files,
                          {ok, #{data := Data}} <- [ana_files:get_binary(User, Id, null)]],
            {ok, {_, Zip}} = zip:create("pasta.zip", Entries, [memory]),
            ana_files:event(<<"download.zip">>, Folder, null, null, User, ana_http:ip(Req), #{files => length(Entries)}),
            cowboy_req:reply(200, #{<<"content-type">> => <<"application/zip">>,
                                    <<"content-disposition">> => <<"attachment; filename=\"pasta.zip\"">>,
                                    <<"x-content-type-options">> => <<"nosniff">>}, Zip, Req)
    end.

rows(Sql, P) -> case ana_db:rows(Sql, P) of {ok, R} -> R; _ -> [] end.

%% ---------------------------------------------------------------- share links

share(<<"GET">>, Token, Req) ->
    case ana_files:share_find(Token) of
        {ok, #{<<"has_password">> := true}} -> password_page(Req, false);
        {ok, _} -> take(Token, null, Req);
        {error, _} -> gone_page(Req)
    end;
share(<<"POST">>, Token, Req) ->
    %% The form is tiny; anything bigger (or malformed) is refused like an unusable link.
    try cowboy_req:read_urlencoded_body(Req, #{length => 4096}) of
        {ok, Form, Req2} -> take(Token, proplists:get_value(<<"password">>, Form), Req2)
    catch _:_ -> gone_page(Req)
    end;
share(_, _, Req) -> gone_page(Req).

take(Token, Password, Req) ->
    case ana_files:share_take(Token, Password, ana_http:ip(Req)) of
        {ok, Ver} -> send(Ver, <<"attachment">>, Req, false);
        {error, password} -> password_page(Req, true);
        {error, _} -> gone_page(Req)
    end.

page(Status, Body, Req) ->
    cowboy_req:reply(Status, #{<<"content-type">> => <<"text/html; charset=utf-8">>},
                     [<<"<!doctype html><html lang=\"pt-BR\"><head><meta charset=\"utf-8\"><meta name=\"viewport\" "
                        "content=\"width=device-width\"><title>Arquivo compartilhado</title></head><body style=\"font-family:"
                        "system-ui,sans-serif;max-width:28rem;margin:4rem auto;padding:0 1rem\">">>, Body, <<"</body></html>">>], Req).

password_page(Req, Wrong) ->
    page(case Wrong of true -> 401; false -> 200 end,
         [<<"<h1>Arquivo protegido</h1>"/utf8>>,
          case Wrong of true -> <<"<p>Senha incorreta.</p>">>; false -> <<>> end,
          <<"<form method=\"post\"><label>Senha <input type=\"password\" name=\"password\" required autofocus></label> "
            "<button type=\"submit\">Baixar</button></form>">>], Req).

gone_page(Req) ->
    page(410, <<"<h1>Link indisponível</h1><p>O link expirou, foi revogado ou atingiu o limite de downloads.</p>"/utf8>>, Req).
