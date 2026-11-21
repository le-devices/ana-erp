%% SPDX-FileCopyrightText: 2026 LE Devices
%% SPDX-License-Identifier: AGPL-3.0-or-later
%% Studio files served from memory with ETag (RF-005-01, RNF-005-03).
%% Allow-list: only files present in priv/www at startup.
-module(ana_http_static).
-export([load/0, init/2]).

-define(KEY, {?MODULE, files}).

load() ->
    Dir = filename:join(code:priv_dir(ana), "www"),
    Files = maps:from_list(
        [{list_to_binary(filename:basename(F)), entry(F)}
         || F <- filelib:wildcard(filename:join(Dir, "*")), filelib:is_regular(F)]),
    persistent_term:put(?KEY, Files),
    ok.

entry(F) ->
    {ok, Bin} = file:read_file(F),
    Hash = binary:part(binary:encode_hex(crypto:hash(sha256, Bin), lowercase), 0, 20),
    {Bin, <<"\"", Hash/binary, "\"">>, content_type(filename:extension(F))}.

content_type(".html") -> <<"text/html; charset=utf-8">>;
content_type(".css") -> <<"text/css; charset=utf-8">>;
content_type(".js") -> <<"text/javascript; charset=utf-8">>;
content_type(".svg") -> <<"image/svg+xml">>;
content_type(".png") -> <<"image/png">>;
content_type(_) -> <<"application/octet-stream">>.

init(Req, Fixed) ->
    Name = case Fixed of
        undefined -> cowboy_req:binding(file, Req);
        _ -> Fixed
    end,
    Files = persistent_term:get(?KEY, #{}),
    Req2 = case {cowboy_req:method(Req), maps:find(Name, Files)} of
        {M, {ok, {Bin, ETag, Type}}} when M =:= <<"GET">>; M =:= <<"HEAD">> ->
            Headers = #{<<"content-type">> => Type, <<"etag">> => ETag, <<"cache-control">> => <<"no-cache">>},
            case cowboy_req:header(<<"if-none-match">>, Req) of
                ETag -> cowboy_req:reply(304, Headers, Req);
                _ -> cowboy_req:reply(200, Headers, Bin, Req)
            end;
        {_, {ok, _}} ->
            cowboy_req:reply(405, Req);
        {_, error} ->
            cowboy_req:reply(404, #{<<"content-type">> => <<"text/plain">>}, <<"not found">>, Req)
    end,
    {ok, Req2, Fixed}.
