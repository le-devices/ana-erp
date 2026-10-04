%% Seed programs (RF-006-06, RF-006-08).
%%
%% Reads priv/programs/<name>.py with metadata in the header:
%%   # ana:description Creates a sales order
%%   # ana:exposed yes
%%   # ana:command order
%%   # ana:kind program|library
%%   # ana:role user|developer|admin
%% Only creates what does not exist: never overwrites studio changes.
-module(ana_seeds).
-export([apply/0]).


apply() ->
    Dir = filename:join(code:priv_dir(ana), "programs"),
    Files = lists:sort(filelib:wildcard(filename:join(Dir, "*.py"))),
    _ = ana_task:run(<<"seed.programs">>, ana_task:system_user(), <<"internal">>, fun() ->
        Created = [N || F <- Files, {created, N} <- [seed(F)]],
        _ = Created =/= [] andalso ok =:= logger:notice("seed programs created: ~p", [length(Created)]),
        {ok, unicode:characters_to_binary(io_lib:format("~b programa(s) criado(s)", [length(Created)]))}
    end),
    ok.

seed(File) ->
    Name = list_to_binary(filename:basename(File, ".py")),
    case ana_program:get(Name) of
        {ok, undefined} ->
            {ok, Source} = file:read_file(File),
            Meta = metadata(Source),
            Fields = #{<<"source">> => Source,
                       <<"description">> => maps:get(<<"description">>, Meta, <<>>),
                       <<"kind">> => maps:get(<<"kind">>, Meta, <<"program">>),
                       <<"exposed">> => maps:get(<<"exposed">>, Meta, <<"no">>) =:= <<"yes">>,
                       <<"min_role">> => maps:get(<<"role">>, Meta, <<"user">>),
                       <<"comment">> => <<"seed">>},
            case ana_program:save(Name, Fields, ana_task:system_user()) of
                {ok, _} ->
                    _ = case maps:find(<<"command">>, Meta) of
                        {ok, Cmd} ->
                            {ok, _} = ana_program:save_command(Cmd, Name, maps:get(<<"description">>, Meta, <<>>));
                        error -> ok
                    end,
                    {created, Name};
                {error, E} ->
                    logger:error("seed ~s failed: ~0p", [Name, E]),
                    error
            end;
        _ -> exists
    end.

metadata(Source) ->
    Lines = binary:split(Source, <<"\n">>, [global]),
    maps:from_list(
        [{K, string:trim(V)} || L <- Lines,
                                {match, [K, V]} <- [re:run(L, "^#\\s*ana:([a-z_]+)\\s+(.*)$",
                                                           [{capture, all_but_first, binary}, unicode])]]).
