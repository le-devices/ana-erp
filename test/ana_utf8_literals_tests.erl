-module(ana_utf8_literals_tests).
-include_lib("eunit/include/eunit.hrl").

%% RNF-001-03 (texts in UTF-8): an accented string literal in the core either is a /utf8 binary or goes straight
%% into a call that encodes it (unicode:characters_to_binary, io_lib:format, the modules' fmt/2, logger).
%% Anything else reaches PostgreSQL, JSON or e-mail as Latin-1 bytes: the database refuses the statement
%% ("invalid byte sequence for encoding UTF8") and messages show broken characters.
accented_literals_are_utf8_test() ->
    Files = filelib:wildcard(filename:join(src_dir(), "*.erl")),
    ?assert(length(Files) > 50),
    Bad = lists:append([offenders(F) || F <- Files]),
    ?assertEqual([], Bad).

src_dir() ->
    case filelib:is_dir("src") of
        true -> "src";
        false -> filename:join(code:lib_dir(ana), "src")
    end.

offenders(File) ->
    {ok, Bin} = file:read_file(File),
    offenders_in(filename:basename(File), unicode:characters_to_list(Bin)).

offenders_in(Name, Chars) ->
    {ok, Tokens, _} = erl_scan:string(Chars),
    scan(Tokens, [], Name, []).

%% The guard itself: it catches the forms that broke on CI and accepts the encoded ones.
guard_detects_unmarked_literals_test() ->
    Bad = "f() -> ana_db:exec(\"UPDATE t SET e = 'nó'\", []), <<\"a \", X/binary, \" — \">>, {error, <<\"não\">>}.",
    ?assertMatch([{"m", 1, _}, {"m", 1, " — "}, {"m", 1, "não"}], offenders_in("m", Bad)),
    Good = "f() -> <<\"nó\"/utf8>>, fmt(\"~b à\", [1]), unicode:characters_to_binary([\"é \", X]),"
           " io_lib:format(\"ç\", []), logger:notice(\"ã ~p\", [x]), \"ascii\".",
    ?assertEqual([], offenders_in("m", Good)).

%% Prev holds the tokens already seen, most recent first.
scan([], _, _, Acc) -> lists:reverse(Acc);
scan([{string, Anno, _} | _] = Ts, Prev, File, Acc) ->
    {Strs, Rest} = lists:splitwith(fun(T) -> element(1, T) =:= string end, Ts),
    Text = lists:append([S || {string, _, S} <- Strs]),
    Acc2 = case lists:any(fun(C) -> C > 127 end, Text) andalso not utf8_segment(Rest) andalso not encoded(Prev) of
        true -> [{File, erl_anno:line(Anno), Text} | Acc];
        false -> Acc
    end,
    scan(Rest, lists:reverse(Strs, Prev), File, Acc2);
scan([T | Rest], Prev, File, Acc) -> scan(Rest, [T | Prev], File, Acc).

utf8_segment([{'/', _}, {atom, _, utf8} | _]) -> true;
utf8_segment(_) -> false.

%% The literal is (inside a list that is) the first argument of an encoding call: look back over "(" and "[".
encoded(Prev) ->
    case lists:dropwhile(fun(T) -> lists:member(element(1, T), ['(', '[']) end, Prev) of
        Prev -> false;
        [{atom, _, F} | Before] -> encoding_call(F, Before);
        _ -> false
    end.

encoding_call(F, _) when F =:= fmt; F =:= characters_to_binary; F =:= format -> true;
encoding_call(F, [{':', _}, {atom, _, logger} | _]) ->
    lists:member(F, [debug, info, notice, warning, error, critical, alert, emergency]);
encoding_call(_, _) -> false.
