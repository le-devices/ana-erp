%% Spec 016: real content type and the encrypted store (round trip, Range at any
%% offset, tamper detection).
-module(ana_files_tests).
-include_lib("eunit/include/eunit.hrl").

-define(T(N, H), ana_files_type:detect(N, H)).

renamed_executable_is_refused_test() ->                      % CA-016-04
    ?assertMatch({error, _}, ?T(<<"fatura.pdf">>, <<"MZ", 0, 0, 0>>)),
    ?assertMatch({error, _}, ?T(<<"sem_extensao">>, <<"MZ", 144, 0>>)),
    ?assertMatch({error, _}, ?T(<<"setup.EXE">>, <<"qualquer">>)).

signature_must_match_extension_test() ->
    ?assertEqual({ok, <<"application/pdf">>}, ?T(<<"a.pdf">>, <<"%PDF-1.7 ...">>)),
    ?assertMatch({error, _}, ?T(<<"a.pdf">>, <<"<html>">>)),
    ?assertEqual({ok, <<"image/png">>}, ?T(<<"a.PNG">>, <<137, "PNG", 13, 10, 26, 10, 0>>)),
    ?assertEqual({ok, <<"application/vnd.openxmlformats-officedocument.wordprocessingml.document">>},
                 ?T(<<"a.docx">>, <<"PK", 3, 4, 0>>)).

text_and_firmware_test() ->
    ?assertEqual({ok, <<"text/plain">>}, ?T(<<"fw.hex">>, <<":10010000214601360121470136007EFE09D2190140\n">>)),
    ?assertMatch({error, _}, ?T(<<"fw.hex">>, <<0, 1, 2, 3>>)),
    ?assertEqual({ok, <<"application/octet-stream">>}, ?T(<<"fw.bin">>, <<0, 1, 2, 255>>)),
    ?assertEqual({ok, <<"application/x-elf">>}, ?T(<<"app.elf">>, <<127, "ELF", 1>>)).

store_test_() ->
    {setup,
     fun() ->
         Dir = filename:join("/tmp", "ana_files_test_" ++ integer_to_list(erlang:unique_integer([positive]))),
         os:putenv("ANA_FILES_DIR", Dir),
         persistent_term:put({ana_vault, key}, crypto:strong_rand_bytes(32)),
         Dir
     end,
     fun(Dir) ->
         os:unsetenv("ANA_FILES_DIR"),
         persistent_term:erase({ana_vault, key}),
         _ = file:del_dir_r(Dir)
     end,
     fun(_) -> [fun round_trip_and_range/0, fun tamper_is_detected/0] end}.

write(Data) ->
    {Tmp, IV} = ana_files_store:temp_new(),
    %% Appended in odd-sized pieces, as a resumable upload would.
    lists:foldl(fun(Piece, Off) -> ok = ana_files_store:temp_write(Tmp, IV, Off, Piece), Off + byte_size(Piece) end,
                0, pieces(Data, 37)),
    {Tmp, IV}.

pieces(<<>>, _) -> [];
pieces(B, N) when byte_size(B) =< N -> [B];
pieces(B, N) -> <<P:N/binary, R/binary>> = B, [P | pieces(R, N)].

round_trip_and_range() ->
    Data = crypto:strong_rand_bytes(5000),
    {Tmp, IV} = write(Data),
    {ok, Sha, _Mac, 5000} = ana_files_store:finalize(Tmp, IV),
    ?assertEqual(binary:encode_hex(crypto:hash(sha256, Data), lowercase), Sha),
    {ok, Raw} = file:read_file(Tmp),
    ?assertNotEqual(Data, Raw),                                   % encrypted at rest
    ?assertEqual(binary:part(Data, 0, 100), ana_files_store:head(Tmp, IV, 100)),
    %% Range at an offset that is not a block boundary.
    {Enc, _} = keys(),
    <<N:128>> = IV,
    Start = 1234,
    S = crypto:crypto_init(aes_256_ctr, Enc, <<(N + Start div 16):128>>, false),
    <<_:(Start rem 16)/binary, Plain/binary>> = crypto:crypto_update(S, binary:part(Raw, Start - Start rem 16, 300 + Start rem 16)),
    ?assertEqual(binary:part(Data, Start, 300), Plain).

keys() ->
    MK = persistent_term:get({ana_vault, key}),
    {crypto:mac(hmac, sha256, MK, <<"ana-files-enc-v1">>), crypto:mac(hmac, sha256, MK, <<"ana-files-mac-v1">>)}.

tamper_is_detected() ->
    {Tmp, IV} = write(<<"conteúdo importante"/utf8>>),
    {ok, _Sha, Mac, _} = ana_files_store:finalize(Tmp, IV),
    {ok, Raw} = file:read_file(Tmp),
    <<First, Rest/binary>> = Raw,
    ok = file:write_file(Tmp, <<(First bxor 1), Rest/binary>>),
    {ok, _, Mac2, _} = ana_files_store:finalize(Tmp, IV),
    ?assertNotEqual(Mac, Mac2),
    %% And a different IV with the same ciphertext also changes the MAC (IV is authenticated).
    ok = file:write_file(Tmp, Raw),
    {ok, _, Mac3, _} = ana_files_store:finalize(Tmp, crypto:strong_rand_bytes(16)),
    ?assertNotEqual(Mac, Mac3).
