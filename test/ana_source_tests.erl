%% Source checks that catch a mistake made more than once: a binary literal with accents and no /utf8
%% (<<"ação">>) is stored as Latin-1 and breaks the JSON answer (500) the first time it is shown.
-module(ana_source_tests).
-include_lib("eunit/include/eunit.hrl").

utf8_literals_test() ->
    Dir = filename:join(filename:dirname(filename:dirname(code:which(?MODULE))), "src"),
    Files = filelib:wildcard(filename:join(src_dir(Dir), "*.erl")),
    ?assertNotEqual([], Files),
    Bad = [{filename:basename(F), N, string:trim(Line)}
           || F <- Files,
              {N, Line} <- lists:zip(lists:seq(1, length(lines(F))), lines(F)),
              Lit <- literals(Line), not utf8_ok(Lit)],
    ?assertEqual([], Bad).

src_dir(Dir) ->
    case filelib:is_dir(Dir) of
        true -> Dir;
        false -> filename:join(element(2, file:get_cwd()), "src")      % rebar3 eunit runs from the project root
    end.

lines(F) ->
    {ok, B} = file:read_file(F),
    string:split(unicode:characters_to_list(B), "\n", all).

%% <<"…">> literals of a line, with whatever follows the closing quote ("/utf8>>" or ">>").
literals(Line) ->
    case re:run(Line, "<<\"((?:[^\"\\\\]|\\\\.)*)\"(/utf8)?>>", [global, unicode, {capture, all, list}]) of
        {match, Ms} -> Ms;
        nomatch -> []
    end.

utf8_ok([_Whole, Text]) -> lists:all(fun(C) -> C < 128 end, Text);
utf8_ok([_Whole, _Text, "/utf8"]) -> true.
