%% Real content type of an upload (spec 016, RF-016-07, CA-016-04).
%%
%% The extension says what the file claims to be; the first bytes say what it is.
%% Known extensions must match their signature (a renamed .exe is refused);
%% executables for Windows are refused under any name; blocked extensions
%% (ANA_FILES_BLOCKED, comma separated) never enter. Firmware images (.bin,
%% .hex, .elf…) are normal files in an electronics company and are accepted.
-module(ana_files_type).
-export([detect/2, inline_safe/1]).

-define(BLOCKED, "exe,dll,msi,bat,cmd,com,scr,pif,cpl,ps1,psm1,vbs,vbe,wsf,wsh,hta,jar,apk,app,lnk,reg,gadget,msc").

%% {Extension, Mime, Signature check}
-define(RULES, [
    {<<"pdf">>, <<"application/pdf">>, fun(H) -> prefix(H, <<"%PDF-">>) end},
    {<<"png">>, <<"image/png">>, fun(H) -> prefix(H, <<137, "PNG", 13, 10, 26, 10>>) end},
    {<<"jpg">>, <<"image/jpeg">>, fun(H) -> prefix(H, <<255, 216, 255>>) end},
    {<<"jpeg">>, <<"image/jpeg">>, fun(H) -> prefix(H, <<255, 216, 255>>) end},
    {<<"gif">>, <<"image/gif">>, fun(H) -> prefix(H, <<"GIF87a">>) orelse prefix(H, <<"GIF89a">>) end},
    {<<"webp">>, <<"image/webp">>, fun(H) -> byte_size(H) >= 12 andalso prefix(H, <<"RIFF">>) andalso binary_part(H, 8, 4) =:= <<"WEBP">> end},
    {<<"zip">>, <<"application/zip">>, fun zip/1},
    {<<"docx">>, <<"application/vnd.openxmlformats-officedocument.wordprocessingml.document">>, fun zip/1},
    {<<"xlsx">>, <<"application/vnd.openxmlformats-officedocument.spreadsheetml.sheet">>, fun zip/1},
    {<<"pptx">>, <<"application/vnd.openxmlformats-officedocument.presentationml.presentation">>, fun zip/1},
    {<<"odt">>, <<"application/vnd.oasis.opendocument.text">>, fun zip/1},
    {<<"ods">>, <<"application/vnd.oasis.opendocument.spreadsheet">>, fun zip/1},
    {<<"gz">>, <<"application/gzip">>, fun(H) -> prefix(H, <<31, 139>>) end},
    {<<"tgz">>, <<"application/gzip">>, fun(H) -> prefix(H, <<31, 139>>) end},
    {<<"7z">>, <<"application/x-7z-compressed">>, fun(H) -> prefix(H, <<"7z", 188, 175, 39, 28>>) end},
    {<<"elf">>, <<"application/x-elf">>, fun(H) -> prefix(H, <<127, "ELF">>) end},
    {<<"axf">>, <<"application/x-elf">>, fun(H) -> prefix(H, <<127, "ELF">>) end}]).

-define(TEXT, [<<"txt">>, <<"csv">>, <<"md">>, <<"json">>, <<"xml">>, <<"yaml">>, <<"yml">>, <<"toml">>, <<"ini">>,
               <<"log">>, <<"c">>, <<"h">>, <<"cpp">>, <<"hpp">>, <<"py">>, <<"rs">>, <<"go">>, <<"ld">>, <<"s">>,
               <<"hex">>, <<"ihex">>, <<"s19">>, <<"srec">>, <<"gbr">>, <<"ger">>, <<"drl">>, <<"kicad_pcb">>,
               <<"kicad_sch">>, <<"kicad_pro">>, <<"sch">>, <<"net">>, <<"svg">>, <<"html">>, <<"sh">>, <<"ofx">>]).

-spec detect(binary(), binary()) -> {ok, binary()} | {error, binary()}.
detect(Name, Head) ->
    Ext = ext(Name),
    Blocked = [list_to_binary(string:trim(E)) || E <- string:split(ana_config:text("ANA_FILES_BLOCKED", ?BLOCKED), ",", all)],
    case {lists:member(Ext, Blocked), windows_exe(Head)} of
        {true, _} -> {error, <<"extensão não permitida: ."/utf8, Ext/binary>>};
        {_, true} -> {error, <<"o conteúdo é um executável do Windows, não importa o nome"/utf8>>};
        _ ->
            case lists:keyfind(Ext, 1, ?RULES) of
                {_, Mime, Check} ->
                    case Check(Head) of
                        true -> {ok, Mime};
                        false -> {error, <<"o conteúdo não é um ."/utf8, Ext/binary, " de verdade"/utf8>>}
                    end;
                false ->
                    case lists:member(Ext, ?TEXT) of
                        true ->
                            case text(Head) of
                                true -> {ok, text_mime(Ext)};
                                false -> {error, <<"o conteúdo não é texto, como .", Ext/binary, " exige"/utf8>>}
                            end;
                        false -> {ok, <<"application/octet-stream">>}   % firmware images, CAD and the like
                    end
            end
    end.

%% Types the browser may show inline (sandboxed); everything else is a download.
-spec inline_safe(binary()) -> boolean().
inline_safe(Mime) ->
    lists:member(Mime, [<<"application/pdf">>, <<"image/png">>, <<"image/jpeg">>, <<"image/gif">>, <<"image/webp">>,
                        <<"text/plain">>]).

ext(Name) ->
    case string:split(Name, ".", trailing) of
        [_, E] when E =/= <<>> -> string:lowercase(E);
        _ -> <<>>
    end.

prefix(H, P) -> byte_size(H) >= byte_size(P) andalso binary_part(H, 0, byte_size(P)) =:= P.
zip(H) -> prefix(H, <<"PK", 3, 4>>) orelse prefix(H, <<"PK", 5, 6>>).
windows_exe(H) -> prefix(H, <<"MZ">>).

%% Text (UTF-8 or Latin-1) never has NUL bytes; binaries almost always do.
text(H) -> binary:match(H, <<0>>) =:= nomatch.

text_mime(<<"csv">>) -> <<"text/csv">>;
text_mime(<<"json">>) -> <<"application/json">>;
text_mime(<<"xml">>) -> <<"application/xml">>;
text_mime(<<"svg">>) -> <<"image/svg+xml">>;
text_mime(<<"html">>) -> <<"text/html">>;
text_mime(<<"md">>) -> <<"text/markdown">>;
text_mime(_) -> <<"text/plain">>.
