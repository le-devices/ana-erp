%% Business access groups (spec 011, RF-011-04).
%%
%% A program with `restricted = true` runs only for users in a group whose
%% patterns cover it (exact name or "prefix.*"), besides `min_role`.
%% `admin` always passes. Group membership is cached per user (RNF-011-04) and
%% invalidated through NOTIFY "ana_access".
-module(ana_access).
-export([init_cache/0, allowed/2, matches/2, groups/1, scope/1, scope_sql/1, on_notify/2, invalidate/0]).

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

%% Spec 009 (D10): the data a user may see, from the groups that restrict it (administrators: everything).
%% #{cost_centers => all | [Code] (children included, <<>> = rows without center), portfolio, own_projects}.
-spec scope(map()) -> map().
scope(#{role := <<"admin">>}) -> #{cost_centers => all, portfolio => false, own_projects => false};
scope(#{username := U}) -> element(3, membership(U));
scope(_) -> #{cost_centers => all, portfolio => false, own_projects => false}.

%% SET LOCAL statements for the execution transaction ("" when nothing is restricted).
-spec scope_sql(map()) -> iodata().
scope_sql(User) ->
    #{cost_centers := Cc, portfolio := Pf, own_projects := Pr} = scope(User),
    Restricted = Cc =/= all orelse Pf orelse Pr,
    [case Restricted of true -> "SET LOCAL ROLE ana_scoped; "; false -> [] end,      % only this role meets the policies
     case Cc of
         all -> [];
         Codes -> ["SET LOCAL ana.scope_cc = '", escape(iolist_to_binary([",", lists:join(",", Codes), ","])), "'; "]
     end,
     case Pf of true -> "SET LOCAL ana.scope_portfolio = 'on'; "; false -> [] end,
     case Pr of true -> "SET LOCAL ana.scope_projects = 'on'; "; false -> [] end].

escape(B) -> binary:replace(B, <<"'">>, <<"''">>, [global]).

%% {Patterns, Groups, Scope} of a user, cached.
membership(U) ->
    case ets:lookup(?TAB, U) of
        [{_, M}] -> M;
        [] ->
            M = case ana_db:rows(
                       "SELECT g.name, g.program_patterns, g.data_cost_centers, g.data_portfolio, g.data_own_projects "
                       "FROM ana_system.user_group ug "
                       "JOIN ana_system.access_group g ON g.name = ug.group_name WHERE ug.username = $1",
                       [U]) of
                {ok, Rows} ->
                    {lists:append([Ps || #{<<"program_patterns">> := Ps} <- Rows]),
                     [N || #{<<"name">> := N} <- Rows],
                     #{cost_centers => cost_centers([C || #{<<"data_cost_centers">> := C} <- Rows, is_list(C)]),
                       portfolio => lists:any(fun(#{<<"data_portfolio">> := P}) -> P =:= true end, Rows),
                       own_projects => lists:any(fun(#{<<"data_own_projects">> := P}) -> P =:= true end, Rows)}};
                _ -> {[], [], #{cost_centers => [], portfolio => true, own_projects => true}}   % fail closed
            end,
            ets:insert(?TAB, {U, M}),
            M
    end.

%% Union of the groups' centers with their children; documents without a center count as the company's.
cost_centers([]) -> all;
cost_centers(Lists) ->
    Roots = lists:usort(lists:append(Lists)),
    {ok, Rows} = ana_db:rows(
        "WITH RECURSIVE t AS (SELECT code FROM finance.cost_center WHERE code = ANY($1::text[]) "
        "  UNION SELECT c.code FROM finance.cost_center c JOIN t ON c.parent_code = t.code) "
        "SELECT code, code = (SELECT cost_center FROM finance.default_cost_center WHERE key = 'company') AS company FROM t", [Roots]),
    Codes = [C || #{<<"code">> := C} <- Rows],
    case lists:any(fun(#{<<"company">> := X}) -> X =:= true end, Rows) of
        true -> [<<>> | Codes];
        false -> Codes
    end.

invalidate() ->
    ets:delete_all_objects(?TAB),
    _ = ana_db:exec("SELECT pg_notify('ana_access', '')", []),
    ok.

on_notify(Channel, Payload) ->
    ets:delete_all_objects(?TAB),
    ana_limits:on_notify(Channel, Payload).
