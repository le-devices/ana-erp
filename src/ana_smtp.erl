%% SPDX-FileCopyrightText: 2026 LE Devices
%% SPDX-License-Identifier: AGPL-3.0-or-later
%% Outbound e-mail over SMTP (spec 044). A small client of our own (no dependency):
%% EHLO, STARTTLS, AUTH PLAIN/LOGIN, MAIL/RCPT/DATA, QUIT; MIME with text, HTML and
%% attachments; TLS always verified (system chain or the connector's own CA). Credentials
%% come from the vault and never reach programs or logs. A 5xx answer is permanent
%% (no retry); anything else may be retried by the outbox.
-module(ana_smtp).
-export([deliver/3, test/1, send_test/3, config/1, valid_address/1, mime/2, max_attachments/0]).
-ifdef(TEST).
-export([chunks/2, encode_word/1]).
-endif.

-define(MAX_ATTACH, 10 * 1024 * 1024).
-define(EMAIL, "^[^@\\s<>\"(),;:\\\\\\[\\]]{1,64}@[A-Za-z0-9.-]{1,190}\\.[A-Za-z]{2,}\\z").

%% The connector's SMTP settings (options) with defaults; {error, Msg} when incomplete.
-spec config(map()) -> {ok, map()} | {error, binary()}.
config(#{<<"name">> := Name, <<"options">> := O, <<"timeout_ms">> := T} = C) when is_map(O) ->
    Security = maps:get(<<"security">>, O, <<"starttls">>),
    Port = maps:get(<<"port">>, O, case Security of <<"tls">> -> 465; _ -> 587 end),
    Host = maps:get(<<"host">>, O, null),
    From = maps:get(<<"from">>, O, null),
    if
        not is_binary(Host) -> {error, <<"informe o servidor SMTP (host)"/utf8>>};
        not (is_integer(Port) andalso Port > 0 andalso Port < 65536) -> {error, <<"porta SMTP inválida"/utf8>>};
        not is_binary(From) -> {error, <<"informe o remetente (from)"/utf8>>};
        true ->
            AllowPlain = maps:get(<<"allow_plain">>, O, false) =:= true,
            case {lists:member(Security, [<<"tls">>, <<"starttls">>, <<"none">>]), valid_address(From)} of
                {false, _} -> {error, <<"segurança deve ser tls, starttls ou none"/utf8>>};
                {_, false} -> {error, <<"remetente inválido"/utf8>>};
                _ when Security =:= <<"none">>, not AllowPlain ->
                    {error, <<"sem criptografia só com a opção allow_plain (e aparece nas Verificações)"/utf8>>};
                _ ->
                    {ok, #{name => Name, host => Host, port => Port, security => Security, from => From,
                           from_name => maps:get(<<"from_name">>, O, null), reply_to => maps:get(<<"reply_to">>, O, null),
                           ca_cert => maps:get(<<"ca_cert">>, O, null), allow_plain => AllowPlain,
                           auth => maps:get(<<"auth">>, C, <<"none">>), timeout => T}}
            end
    end;
config(_) -> {error, <<"conector SMTP sem opções"/utf8>>}.

-spec valid_address(term()) -> boolean().
valid_address(A) when is_binary(A), byte_size(A) =< 254 -> re:run(A, ?EMAIL, [{capture, none}, unicode]) =:= match;
valid_address(_) -> false.

%% One message of the outbox: #{to, cc, bcc, subject, text, html, reply_to, attachments: [#{name, mime, data}]}.
-spec deliver(map(), map(), [map()]) -> {ok, map()} | {error, map()}.
deliver(Cfg, Msg, Attachments) ->
    To = list(Msg, <<"to">>), Cc = list(Msg, <<"cc">>), Bcc = list(Msg, <<"bcc">>),
    Rcpt = To ++ Cc ++ Bcc,
    case {Rcpt, lists:all(fun valid_address/1, Rcpt)} of
        {[], _} -> perm(<<"INVALID_RECIPIENT">>, <<"mensagem sem destinatário"/utf8>>);
        {_, false} -> perm(<<"INVALID_RECIPIENT">>, <<"destinatário inválido"/utf8>>);
        _ ->
            Data = mime(Cfg, Msg#{<<"attachments">> => Attachments}),
            session(Cfg, fun(S) ->
                ok_or(command(S, ["MAIL FROM:<", maps:get(from, Cfg), ">"], 250), fun() ->
                ok_or(rcpt(S, Rcpt), fun() ->
                ok_or(command(S, "DATA", 354), fun() ->
                    case send_data(S, Data) of
                        {ok, Reply} -> {ok, #{server_reply => Reply, recipients => length(Rcpt)}};
                        E -> E
                    end end) end) end)
            end)
    end.

%% "Testar conexão": connect, secure, authenticate, quit.
-spec test(map()) -> {ok, map()} | {error, map()}.
test(Cfg) -> session(Cfg, fun(_) -> {ok, #{connected => true}} end).

%% "Enviar e-mail de teste" (synchronous: the administrator sees the answer).
-spec send_test(map(), binary(), binary()) -> {ok, map()} | {error, map()}.
send_test(Cfg, To, Who) ->
    deliver(Cfg, #{<<"to">> => [To], <<"subject">> => <<"Teste de e-mail do ANA"/utf8>>,
                   <<"text">> => <<"Mensagem de teste enviada pelo ANA (conector ", (maps:get(name, Cfg))/binary,
                                   ", pedido por ", Who/binary, ").\r\nSe chegou, o envio de e-mail está funcionando."/utf8>>},
            []).

list(M, K) ->
    case maps:get(K, M, []) of
        L when is_list(L) -> [A || A <- L, is_binary(A)];
        A when is_binary(A) -> [A];
        _ -> []
    end.

rcpt(_, []) -> ok;
rcpt(S, [A | Rest]) -> ok_or(command(S, ["RCPT TO:<", A, ">"], 250), fun() -> rcpt(S, Rest) end).

ok_or(ok, Next) -> Next();
ok_or({ok, _}, Next) -> Next();
ok_or(E, _) -> E.

%% ---------------------------------------------------------------- session

session(Cfg = #{host := Host, port := Port, security := Sec, timeout := T}, Fun) ->
    H = binary_to_list(Host),
    Opened = case Sec of
        <<"tls">> -> ssl:connect(H, Port, [binary, {packet, line}, {active, false} | tls_options(Cfg)], T);
        _ -> gen_tcp:connect(H, Port, [binary, {packet, line}, {active, false}], T)
    end,
    case Opened of
        {error, R} -> temp(<<"SMTP_CONNECT">>, fmt("não foi possível conectar a ~ts:~b (~0p)", [Host, Port, R]));
        {ok, Sock} ->
            S0 = #{sock => Sock, tls => Sec =:= <<"tls">>, timeout => T},
            try
                case reply(S0) of
                    {ok, 220, _} ->
                        case hello(S0) of
                            {ok, Ext} ->
                                case secure(S0, Cfg, Ext) of
                                    {ok, S1, Ext1} ->
                                        case authenticate(S1, Cfg, Ext1) of
                                            ok ->
                                                R1 = Fun(S1),
                                                _ = catch command(S1, "QUIT", 221),
                                                R1;
                                            E -> E
                                        end;
                                    E -> E
                                end;
                            E -> E
                        end;
                    {ok, Code, Text} -> answer(Code, Text);
                    E -> E
                end
            after
                close(S0)
            end
    end.

close(#{sock := S, tls := true}) -> catch ssl:close(S);
close(#{sock := S}) -> catch gen_tcp:close(S).

hello(S) ->
    case command(S, ["EHLO ", ehlo_name()], 250) of
        {ok, Lines} -> {ok, [string:uppercase(L) || L <- Lines]};
        E -> E
    end.

ehlo_name() ->
    {ok, N} = inet:gethostname(),
    N.

secure(S, _Cfg, Ext) when map_get(tls, S) -> {ok, S, Ext};
secure(S = #{sock := Sock, timeout := T}, Cfg = #{security := <<"starttls">>}, Ext) ->
    case lists:any(fun(L) -> string:prefix(L, <<"STARTTLS">>) =/= nomatch end, Ext) of
        false -> temp(<<"SMTP_NO_STARTTLS">>, <<"o servidor não oferece STARTTLS (exigido pelo conector)"/utf8>>);
        true ->
            case command(S, "STARTTLS", 220) of
                {ok, _} ->
                    case ssl:connect(Sock, [binary, {packet, line}, {active, false} | tls_options(Cfg)], T) of
                        {ok, TlsSock} ->
                            S1 = S#{sock := TlsSock, tls := true},
                            case hello(S1) of
                                {ok, Ext1} -> {ok, S1, Ext1};
                                E -> E
                            end;
                        {error, R} -> temp(<<"SMTP_TLS">>, fmt("falha no TLS com o servidor: ~0p", [R]))
                    end;
                E -> E
            end
    end;
secure(S, _Cfg, Ext) -> {ok, S, Ext}.

authenticate(_S, #{auth := <<"none">>}, _Ext) -> ok;
authenticate(S, Cfg = #{name := Name}, Ext) ->
    case {maps:get(tls, S), maps:get(allow_plain, Cfg)} of
        {false, false} -> temp(<<"SMTP_PLAIN_AUTH">>, <<"senha nunca vai sem criptografia"/utf8>>);
        _ ->
            case {ana_vault:fetch(Name, <<"username">>), ana_vault:fetch(Name, <<"password">>)} of
                {{ok, U}, {ok, P}} ->
                    Mechs = lists:append([string:split(string:trim(Rest), <<" ">>, all)
                                          || L <- Ext, {match, [Rest]} <- [re:run(L, "^AUTH[ =](.*)$", [{capture, all_but_first, binary}])]]),
                    case lists:member(<<"PLAIN">>, Mechs) orelse not lists:member(<<"LOGIN">>, Mechs) of
                        true ->
                            Token = base64:encode(<<0, U/binary, 0, P/binary>>),
                            secret_result(command(S, ["AUTH PLAIN ", Token], 235));
                        false ->
                            ok_or(command(S, "AUTH LOGIN", 334), fun() ->
                            ok_or(command(S, base64:encode(U), 334), fun() ->
                            secret_result(command(S, base64:encode(P), 235)) end) end)
                    end;
                _ -> temp(<<"SMTP_AUTH">>, <<"usuário e senha do conector não estão no cofre"/utf8>>)
            end
    end.

secret_result({ok, _}) -> ok;
secret_result({error, #{<<"code">> := <<"SMTP_REJECTED">>}}) ->
    perm(<<"SMTP_AUTH">>, <<"usuário ou senha recusados pelo servidor SMTP"/utf8>>);
secret_result(E) -> E.

%% TLS verified against the system chain, or against the connector's own CA (PEM).
tls_options(#{host := Host, ca_cert := Ca}) ->
    CAs = case Ca of
        Pem when is_binary(Pem), Pem =/= <<>> -> [Der || {'Certificate', Der, _} <- public_key:pem_decode(Pem)];
        _ -> try public_key:cacerts_get() catch _:_ -> [] end
    end,
    [{verify, verify_peer}, {cacerts, CAs}, {server_name_indication, binary_to_list(Host)},
     {customize_hostname_check, [{match_fun, public_key:pkix_verify_hostname_match_fun(https)}]}].

%% ---------------------------------------------------------------- protocol

command(S, Line, Expect) ->
    case send(S, [Line, "\r\n"]) of
        ok ->
            case reply(S) of
                {ok, Expect, Lines} -> {ok, Lines};
                {ok, Code, Lines} -> answer(Code, Lines);
                E -> E
            end;
        E -> E
    end.

answer(Code, Lines) when Code >= 500 ->
    perm(<<"SMTP_REJECTED">>, fmt("servidor SMTP recusou (~b): ~ts", [Code, iolist_to_binary(lists:join(" ", Lines))]));
answer(Code, Lines) ->
    temp(<<"SMTP_TEMPORARY">>, fmt("servidor SMTP respondeu ~b: ~ts", [Code, iolist_to_binary(lists:join(" ", Lines))])).

%% Multi-line reply: "250-..." lines up to "250 ...".
reply(S) -> reply(S, []).
reply(S = #{timeout := T}, Acc) ->
    case recv(S, T) of
        {ok, <<C1, C2, C3, Sep, Rest/binary>>} when C1 >= $0, C1 =< $9 ->
            Code = list_to_integer([C1, C2, C3]),
            Text = string:trim(Rest, trailing, "\r\n"),
            case Sep of
                $- -> reply(S, [Text | Acc]);
                _ -> {ok, Code, lists:reverse([Text | Acc])}
            end;
        {ok, <<C1, C2, C3, "\r\n">>} -> {ok, list_to_integer([C1, C2, C3]), lists:reverse(Acc)};
        {ok, Other} -> temp(<<"SMTP_PROTOCOL">>, fmt("resposta inesperada do servidor: ~ts", [Other]));
        {error, R} -> temp(<<"SMTP_TIMEOUT">>, fmt("servidor SMTP não respondeu (~0p)", [R]))
    end.

recv(#{sock := S, tls := true}, T) -> ssl:recv(S, 0, T);
recv(#{sock := S}, T) -> gen_tcp:recv(S, 0, T).

send(#{sock := S, tls := true}, Data) -> ssl:send(S, Data);
send(#{sock := S}, Data) -> gen_tcp:send(S, Data).

%% Lines starting with "." get another one (RFC 5321 4.5.2); the end is "<CRLF>.<CRLF>".
send_data(S, Data) ->
    Lines = case binary:split(Data, <<"\r\n">>, [global]) of
        L0 when L0 =/= [] -> case lists:last(L0) of <<>> -> lists:droplast(L0); _ -> L0 end;
        L0 -> L0
    end,
    Stuffed = [[case L of <<".", _/binary>> -> [".", L]; _ -> L end, "\r\n"] || L <- Lines],
    case send(S, [Stuffed, ".\r\n"]) of
        ok ->
            case reply(S) of
                {ok, 250, Text} -> {ok, iolist_to_binary(lists:join(" ", Text))};
                {ok, Code, Text} -> answer(Code, Text);
                E -> E
            end;
        E -> E
    end.

%% ---------------------------------------------------------------- MIME

-spec mime(map(), map()) -> binary().
mime(Cfg, Msg) ->
    From = maps:get(from, Cfg),
    Domain = lists:last(binary:split(From, <<"@">>)),
    Boundary = fun(Tag) -> <<"=_ana_", Tag/binary, "_", (binary:encode_hex(crypto:strong_rand_bytes(12), lowercase))/binary>> end,
    ReplyTo = case maps:get(<<"reply_to">>, Msg, null) of
        R when is_binary(R) -> R;
        _ -> maps:get(reply_to, Cfg)
    end,
    Headers = [
        {<<"From">>, mailbox(maps:get(from_name, Cfg), From)},
        {<<"To">>, iolist_to_binary(lists:join(", ", list(Msg, <<"to">>)))}] ++
        [{<<"Cc">>, iolist_to_binary(lists:join(", ", list(Msg, <<"cc">>)))} || list(Msg, <<"cc">>) =/= []] ++
        [{<<"Reply-To">>, ReplyTo} || is_binary(ReplyTo), valid_address(ReplyTo)] ++
        [{<<"Subject">>, encode_word(maps:get(<<"subject">>, Msg, <<>>))},
         {<<"Date">>, list_to_binary(httpd_util:rfc1123_date())},
         {<<"Message-ID">>, <<"<", (binary:encode_hex(crypto:strong_rand_bytes(16), lowercase))/binary, "@", Domain/binary, ">">>},
         {<<"MIME-Version">>, <<"1.0">>}],
    Text = maps:get(<<"text">>, Msg, null),
    Html = maps:get(<<"html">>, Msg, null),
    Body = case {Text, Html} of
        {T, null} when is_binary(T) -> part(<<"text/plain; charset=UTF-8">>, T);
        {null, H} when is_binary(H) -> part(<<"text/html; charset=UTF-8">>, H);
        {T, H} when is_binary(T), is_binary(H) ->
            B = Boundary(<<"alt">>),
            multipart(<<"alternative">>, B, [part(<<"text/plain; charset=UTF-8">>, T), part(<<"text/html; charset=UTF-8">>, H)]);
        _ -> part(<<"text/plain; charset=UTF-8">>, <<>>)
    end,
    Full = case maps:get(<<"attachments">>, Msg, []) of
        [] -> Body;
        Atts ->
            B2 = Boundary(<<"mix">>),
            multipart(<<"mixed">>, B2, [Body | [attachment(A) || A <- Atts]])
    end,
    iolist_to_binary([[[K, ": ", V, "\r\n"] || {K, V} <- Headers], Full]).

mailbox(null, Addr) -> Addr;
mailbox(Name, Addr) when is_binary(Name) -> <<(encode_word(Name))/binary, " <", Addr/binary, ">">>.

%% RFC 2047: non-ASCII text in headers as UTF-8 base64 words; line breaks never reach a header.
encode_word(T0) ->
    T = binary:replace(binary:replace(T0, <<"\r">>, <<>>, [global]), <<"\n">>, <<" ">>, [global]),
    case lists:all(fun(C) -> C >= 32 andalso C < 127 end, binary_to_list(T)) of
        true -> T;
        false -> iolist_to_binary(lists:join(" ", [["=?UTF-8?B?", base64:encode(Chunk), "?="] || Chunk <- chunks(T, 45)]))
    end.

%% Pieces of at most N bytes that never split a UTF-8 character.
chunks(<<>>, _) -> [];
chunks(B, N) when byte_size(B) =< N -> [B];
chunks(B, N) ->
    Cut = cut(B, N),
    <<H:Cut/binary, Rest/binary>> = B,
    [H | chunks(Rest, N)].

cut(B, N) ->
    case binary:at(B, N) band 16#C0 of
        16#80 -> cut(B, N - 1);
        _ -> N
    end.

part(Type, Content) ->
    [<<"Content-Type: ">>, Type, <<"\r\nContent-Transfer-Encoding: base64\r\n\r\n">>, b64_lines(Content)].

attachment(#{name := Name, mime := Mime, data := Data}) ->
    N = encode_word(binary:replace(Name, [<<"\"">>, <<"\\">>], <<"_">>, [global])),
    %% Text from programs is stored as UTF-8: say so when the type does not.
    Type = case {Mime, binary:match(Mime, <<"charset">>)} of
        {<<"text/", _/binary>>, nomatch} -> <<Mime/binary, "; charset=UTF-8">>;
        _ -> Mime
    end,
    [<<"Content-Type: ">>, Type, <<"; name=\"">>, N, <<"\"\r\nContent-Disposition: attachment; filename=\"">>, N,
     <<"\"\r\nContent-Transfer-Encoding: base64\r\n\r\n">>, b64_lines(Data)].

multipart(Kind, Boundary, Parts) ->
    [<<"Content-Type: multipart/">>, Kind, <<"; boundary=\"">>, Boundary, <<"\"\r\n\r\n">>,
     [[<<"--">>, Boundary, <<"\r\n">>, P, <<"\r\n">>] || P <- Parts], <<"--">>, Boundary, <<"--\r\n">>].

b64_lines(Data) ->
    B = base64:encode(Data),
    [[L, "\r\n"] || L <- lines76(B)].

lines76(<<L:76/binary, Rest/binary>>) -> [L | lines76(Rest)];
lines76(<<>>) -> [];
lines76(L) -> [L].

%% ---------------------------------------------------------------- helpers

%% Total size of the attachments of one message (the outbox refuses more, permanently).
-spec max_attachments() -> pos_integer().
max_attachments() -> ?MAX_ATTACH.

perm(Code, Msg) -> {error, #{<<"code">> => Code, <<"message">> => Msg, <<"permanent">> => true}}.
temp(Code, Msg) -> {error, #{<<"code">> => Code, <<"message">> => Msg, <<"permanent">> => false}}.

fmt(F, A) -> unicode:characters_to_binary(io_lib:format(F, A)).


