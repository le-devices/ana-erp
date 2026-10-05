%% Encrypted, deduplicated content store of the file repository (spec 016,
%% RNF-016-02..04).
%%
%% Content lives in ANA_FILES_DIR (shared by all nodes), at aa/bb/<sha256 of the
%% plain text>; file names never become paths. Each blob is AES-256-CTR with its
%% own random IV (CTR lets a Range be served without decrypting the whole file)
%% and an HMAC-SHA256 of IV || ciphertext (encrypt-then-MAC), checked when stored,
%% on full reads and by the periodic integrity check. Keys derive from
%% ANA_MASTER_KEY. Writes are atomic: encrypted temp file → hash → rename.
-module(ana_files_store).
-export([enabled/0, temp_new/0, temp_write/4, temp_delete/1, finalize/2, commit/5, put_binary/1,
         stream/5, read_all/4, verify/3, head/3]).

-define(CHUNK, 65536).

enabled() -> master() =/= undefined.

master() -> ana_vault:master_key().

keys() ->
    MK = master(),
    {crypto:mac(hmac, sha256, MK, <<"ana-files-enc-v1">>), crypto:mac(hmac, sha256, MK, <<"ana-files-mac-v1">>)}.

dir() -> ana_config:text("ANA_FILES_DIR", "/var/lib/ana/files").

path(Sha) ->
    <<A:2/binary, B:2/binary, _/binary>> = Sha,
    filename:join([dir(), A, B, Sha]).

%% New encrypted temp file: {Path, IV}.
temp_new() ->
    Tmp = filename:join([dir(), "tmp", binary_to_list(binary:encode_hex(crypto:strong_rand_bytes(16), lowercase))]),
    ok = filelib:ensure_dir(Tmp),
    ok = file:write_file(Tmp, <<>>),
    {list_to_binary(Tmp), crypto:strong_rand_bytes(16)}.

temp_delete(Tmp) -> _ = file:delete(Tmp), ok.

%% Encrypts Chunk at byte Offset of the plain text (resumable uploads append in order).
temp_write(Tmp, IV, Offset, Chunk) ->
    {Enc, _} = keys(),
    Enc1 = ctr_at(Enc, IV, Offset, Chunk),
    {ok, F} = file:open(Tmp, [read, write, raw, binary]),
    try ok = file:pwrite(F, Offset, Enc1) after ok = file:close(F) end.

ctr_at(Key, IV, Offset, Data) ->
    <<N:128>> = IV,
    Block = Offset div 16,
    Skip = Offset rem 16,
    S = crypto:crypto_init(aes_256_ctr, Key, <<((N + Block) band ((1 bsl 128) - 1)):128>>, true),
    case Skip of
        0 -> crypto:crypto_update(S, Data);
        _ -> <<_:Skip/binary, Out/binary>> = crypto:crypto_update(S, <<0:(Skip * 8), Data/binary>>), Out
    end.

%% Hash of the plain text and MAC of the ciphertext, in one pass: {ok, Sha, Mac, Size}.
finalize(Tmp, IV) ->
    {Enc, MacKey} = keys(),
    {ok, F} = file:open(Tmp, [read, raw, binary, read_ahead]),
    Dec = crypto:crypto_init(aes_256_ctr, Enc, IV, false),
    %% The MAC covers IV || ciphertext: neither can be swapped unnoticed.
    try fold(F, Dec, crypto:hash_init(sha256), crypto:mac_update(crypto:mac_init(hmac, sha256, MacKey), IV), 0)
    after file:close(F)
    end.

fold(F, Dec, H, M, Size) ->
    case file:read(F, ?CHUNK) of
        {ok, C} -> fold(F, Dec, crypto:hash_update(H, crypto:crypto_update(Dec, C)), crypto:mac_update(M, C), Size + byte_size(C));
        eof -> {ok, binary:encode_hex(crypto:hash_final(H), lowercase), crypto:mac_final(M), Size}
    end.

%% Moves the temp file into place unless the content already exists (dedup).
%% The blob row is written first: only the winner of a race renames its file.
commit(Tmp, IV, Sha, Mac, Size) ->
    Final = path(Sha),
    case ana_db:rows("INSERT INTO files.blob (sha256, size, iv, mac) VALUES ($1, $2, $3, $4) "
                     "ON CONFLICT (sha256) DO NOTHING RETURNING sha256", [Sha, Size, IV, Mac]) of
        {ok, [_]} -> place(Tmp, Final);
        {ok, []} ->
            case filelib:is_regular(Final) of
                true -> temp_delete(Tmp);
                false ->                                % row without content (crash before rename): repair
                    {ok, _} = ana_db:exec("UPDATE files.blob SET iv = $2, mac = $3 WHERE sha256 = $1", [Sha, IV, Mac]),
                    place(Tmp, Final)
            end
    end.

place(Tmp, Final) ->
    ok = filelib:ensure_dir(Final),
    ok = file:rename(Tmp, Final).

%% Whole binary in, blob sha out (programs, generated documents).
put_binary(Bin) when is_binary(Bin) ->
    {Tmp, IV} = temp_new(),
    try
        ok = temp_write(Tmp, IV, 0, Bin),
        {ok, Sha, Mac, Size} = finalize(Tmp, IV),
        ok = commit(Tmp, IV, Sha, Mac, Size),
        {ok, Sha, Size}
    catch C:R:St -> temp_delete(Tmp), erlang:raise(C, R, St)
    end.

%% Plain bytes [Start, Start + Len) to Send(Chunk) (Range downloads).
stream(Sha, IV, Start, Len, Send) ->
    {Enc, _} = keys(),
    {ok, F} = file:open(path(Sha), [read, raw, binary]),
    try
        {ok, _} = file:position(F, Start),
        stream_loop(F, Enc, IV, Start, Len, Send)
    after file:close(F)
    end.

stream_loop(_F, _K, _IV, _Pos, 0, _Send) -> ok;
stream_loop(F, K, IV, Pos, Left, Send) ->
    case file:read(F, min(?CHUNK, Left)) of
        {ok, C} ->
            ok = Send(ctr_at(K, IV, Pos, C)),
            stream_loop(F, K, IV, Pos + byte_size(C), Left - byte_size(C), Send);
        eof -> ok
    end.

%% Whole content, MAC checked; refused above Max bytes.
read_all(Sha, IV, Mac, Max) ->
    {Enc, MacKey} = keys(),
    case file:read_file(path(Sha)) of
        {ok, C} when byte_size(C) > Max -> {error, too_large};
        {ok, C} ->
            case crypto:hash_equals(crypto:mac(hmac, sha256, MacKey, <<IV/binary, C/binary>>), Mac) of
                true -> {ok, ctr_at(Enc, IV, 0, C)};
                false -> {error, corrupted}
            end;
        {error, _} -> {error, missing}
    end.

%% First N plain bytes (content type detection).
head(Tmp, IV, N) ->
    {Enc, _} = keys(),
    {ok, F} = file:open(Tmp, [read, raw, binary]),
    try
        case file:read(F, N) of
            {ok, C} -> ctr_at(Enc, IV, 0, C);
            eof -> <<>>
        end
    after file:close(F)
    end.

verify(Sha, IV, Mac) ->
    {_, MacKey} = keys(),
    case file:open(path(Sha), [read, raw, binary, read_ahead]) of
        {ok, F} ->
            try crypto:hash_equals(mac_file(F, crypto:mac_update(crypto:mac_init(hmac, sha256, MacKey), IV)), Mac)
            after file:close(F)
            end;
        {error, _} -> false
    end.

mac_file(F, M) ->
    case file:read(F, ?CHUNK) of
        {ok, C} -> mac_file(F, crypto:mac_update(M, C));
        eof -> crypto:mac_final(M)
    end.
