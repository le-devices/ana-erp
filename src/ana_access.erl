%% Business access groups (spec 011, RF-011-04).
%%
%% A program with `restricted = true` runs only for users in a group whose
%% patterns cover it (exact name or "prefix.*"), besides `min_role`.
%% `admin` always passes. Group membership is cached per user (RNF-011-04) and
%% invalidated through NOTIFY "ana_access".
-module(ana_access).
-export([init_cache/0, allowed/2, matches/2, groups/1, on_notify/2, invalidate/0]).

-define(TAB, ana_access_cache).

init_cache() ->
    _ = ets:new(?TAB, [named_table, public, set, {read_concurrency, true}]),
    ok.

-spec allowed(map(), map()) -> boolean().
allowed(_User, #{<<"restricted">> := false}) -> true;
allowed(#{role := <<"admin">>}, _Program) -> true;
allowed(#{username := U}, #{<<"name">> := Name}) ->
    lists:any(fun(P) -> matches(P, Name) end, element(1, membership(U)));
allowed(_, _) -> false.

-spec matches(binary(), binary()) -> boolean().
matches(Pattern, Name) ->
    case binary:split(Pattern, <<"*">>) of
        [Name] -> true;
        [Prefix, <<>>] -> binary:longest_common_prefix([Prefix, Name]) =:= byte_size(Prefix);
        _ -> false
    end.

-spec groups(binary()) -> [binary()].
groups(U) -> element(2, membership(U)).

%% {Patterns, Groups} of a user, cached.
membership(U) ->
    case ets:lookup(?TAB, U) of
        [{_, M}] -> M;
        [] ->
            M = case ana_db:rows(
                       "SELECT g.name, g.program_patterns FROM ana_system.user_group ug "
                       "JOIN ana_system.access_group g ON g.name = ug.group_name WHERE ug.username = $1",
                       [U]) of
                {ok, Rows} ->
                    {lists:append([Ps || #{<<"program_patterns">> := Ps} <- Rows]),
                     [N || #{<<"name">> := N} <- Rows]};
                _ -> {[], []}
            end,
            ets:insert(?TAB, {U, M}),
            M
    end.

invalidate() ->
    ets:delete_all_objects(?TAB),
    _ = ana_db:exec("SELECT pg_notify('ana_access', '')", []),
    ok.

on_notify(Channel, Payload) ->
    ets:delete_all_objects(?TAB),
    ana_limits:on_notify(Channel, Payload).
