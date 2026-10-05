%% Secrets vault for connectors (spec 017, RF-017-02).
%%
%% AES-256-GCM with the master key ANA_MASTER_KEY (32 bytes, base64, the same on
%% every node). Plain text exists only inside the core, at call time: it never
%% reaches Python, the API or the logs. The connector name is authenticated data,
%% so a ciphertext copied to another connector does not decrypt.
-module(ana_vault).
-export([enabled/0, master_key/0, store/5, fetch/2, keys/1, delete/2, encrypt/3, decrypt/4]).

-define(AAD(Connector, Key), <<"ana-vault:", Connector/binary, ":", Key/binary>>).

-spec enabled() -> boolean().
enabled() -> master_key() =/= undefined.

-spec master_key() -> binary() | undefined.
master_key() ->
    case persistent_term:get({?MODULE, key}, unset) of
        unset ->
            K = case ana_config:text("ANA_MASTER_KEY", "") of
                "" -> undefined;
                B64 ->
                    case catch base64:decode(B64) of
                        Bin when is_binary(Bin), byte_size(Bin) =:= 32 -> Bin;
                        _ -> logger:error("ANA_MASTER_KEY inválida: são necessários 32 bytes em base64; cofre desligado"),
                             undefined
                    end
            end,
            persistent_term:put({?MODULE, key}, K),
            K;
        K -> K
    end.

-spec encrypt(binary(), binary(), binary()) -> {binary(), binary(), binary()}.
encrypt(Connector, Key, Plain) ->
    MK = master_key(),
    Nonce = crypto:strong_rand_bytes(12),
    {Cipher, Tag} = crypto:crypto_one_time_aead(aes_256_gcm, MK, Nonce, Plain, ?AAD(Connector, Key), 16, true),
    {Cipher, Nonce, Tag}.

-spec decrypt(binary(), binary(), {binary(), binary(), binary()}, binary()) -> {ok, binary()} | error.
decrypt(Connector, Key, {Cipher, Nonce, Tag}, MK) ->
    case crypto:crypto_one_time_aead(aes_256_gcm, MK, Nonce, Cipher, ?AAD(Connector, Key), Tag, false) of
        error -> error;
        Plain -> {ok, Plain}
    end.

-spec store(binary(), binary(), binary(), binary() | null, binary()) -> ok | {error, binary()}.
store(Connector, Key, Plain, ExpiresAt, Who) when is_binary(Plain), byte_size(Plain) > 0, byte_size(Plain) =< 16384 ->
    case enabled() of
        false -> {error, <<"cofre desligado: defina ANA_MASTER_KEY (32 bytes em base64) em todos os nós"/utf8>>};
        true ->
            {C, N, T} = encrypt(Connector, Key, Plain),
            case ana_db:exec("INSERT INTO integration.secret (connector, key, ciphertext, nonce, tag, expires_at, updated_by) "
                             "VALUES ($1, $2, $3, $4, $5, $6::text::date, $7) ON CONFLICT (connector, key) DO UPDATE SET "
                             "ciphertext = EXCLUDED.ciphertext, nonce = EXCLUDED.nonce, tag = EXCLUDED.tag, "
                             "expires_at = EXCLUDED.expires_at, updated_at = now(), updated_by = EXCLUDED.updated_by",
                             [Connector, Key, C, N, T, ExpiresAt, Who]) of
                {ok, _} -> ok;
                {error, #{message := M}} -> {error, M};
                {error, _} -> {error, <<"não foi possível gravar o segredo"/utf8>>}
            end
    end;
store(_, _, _, _, _) ->
    {error, <<"segredo vazio ou grande demais"/utf8>>}.

%% Plain text of one secret, for the core only.
-spec fetch(binary(), binary()) -> {ok, binary()} | {error, binary()}.
fetch(Connector, Key) ->
    case master_key() of
        undefined -> {error, <<"cofre desligado"/utf8>>};
        MK ->
            case ana_db:one("SELECT ciphertext, nonce, tag, expires_at < current_date AS expired "
                            "FROM integration.secret WHERE connector = $1 AND key = $2", [Connector, Key]) of
                {ok, #{<<"ciphertext">> := C, <<"nonce">> := N, <<"tag">> := T, <<"expired">> := Exp}} ->
                    %% ana_db returns bytea in base64 (its results are JSON-ready).
                    case decrypt(Connector, Key, {base64:decode(C), base64:decode(N), base64:decode(T)}, MK) of
                        {ok, P} when Exp =:= true ->
                            logger:warning("vault: secret ~ts/~ts expired; still used", [Connector, Key]),
                            {ok, P};
                        {ok, P} -> {ok, P};
                        error -> {error, <<"segredo não confere com a chave mestra"/utf8>>}
                    end;
                {ok, undefined} -> {error, <<"segredo não cadastrado: "/utf8, Key/binary>>};
                _ -> {error, <<"cofre indisponível"/utf8>>}
            end
    end.

%% What exists (never the values).
keys(Connector) ->
    ana_db:rows("SELECT key, expires_at, updated_at, updated_by, expires_at < current_date + 30 AS expiring "
                "FROM integration.secret WHERE connector = $1 ORDER BY key", [Connector]).

delete(Connector, Key) ->
    {ok, _} = ana_db:exec("DELETE FROM integration.secret WHERE connector = $1 AND key = $2", [Connector, Key]),
    ok.
