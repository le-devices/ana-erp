%% SPDX-FileCopyrightText: 2026 André Luis Pereira dos Santos
%% SPDX-License-Identifier: AGPL-3.0-or-later
%% Execution governance (spec 012): effective limits, limit profiles and quotas.
%%
%% Effective limit for each key (RF-012-02):
%%   min(program limit | default, profile limit, ceiling, requested)
%% where the profile limit is the largest among the user's groups or, when no
%% group defines it, the role profile (RF-012-04). For max_rows, max_sql and
%% max_concurrent, 0 means "unlimited". Nothing ever exceeds the ceiling
%% (RNF-012-03). Profiles and quotas are cached in ETS (RNF-012-02).
-module(ana_limits).
-export([init_cache/0, keys/0, effective/3, validate/1, describe/2,
         acquire/3, release/1, on_notify/2,
         list_profiles/0, save_profile/4, delete_profile/3,
         get_quota/1, save_quota/3, consumption/1]).

-define(PROFILES, ana_limit_profiles).
-define(COUNTERS, ana_limit_counters).

%% {Key, DefaultSetting, CeilingSetting, ZeroMeansUnlimited}
keys() ->
    [{<<"timeout_ms">>, exec_timeout_ms, ceiling_timeout_ms, false},
     {<<"cpu_ms">>, default_cpu_ms, ceiling_cpu_ms, false},
     {<<"memory_mb">>, default_memory_mb, ceiling_memory_mb, false},
     {<<"sql_timeout_ms">>, sql_timeout_ms, ceiling_sql_timeout_ms, false},
     {<<"lock_timeout_ms">>, lock_timeout_ms, ceiling_lock_timeout_ms, false},
     {<<"output_kb">>, output_max_kb, ceiling_output_kb, false},
     {<<"max_rows">>, default_max_rows, ceiling_max_rows, true},
     {<<"max_sql">>, default_max_sql, ceiling_max_sql, true},
     {<<"max_concurrent">>, default_max_concurrent, ceiling_max_concurrent, true},
     {<<"max_parallel_parts">>, default_max_parallel_parts, ceiling_max_parallel_parts, false}].

init_cache() ->
    _ = ets:new(?PROFILES, [named_table, public, set, {read_concurrency, true}]),
    _ = ets:new(?COUNTERS, [named_table, public, set, {write_concurrency, true}]),
    ok.

%% ==========================================================================
%% Effective limits
%% ==========================================================================

-spec effective(map(), map(), map()) -> map().
effective(Program, User, Requested) ->
    ProgLimits = maps:get(<<"limits">>, Program, #{}),
    Profile = profile_for(User),
    maps:from_list(
        [{K, compute(maps:get(K, ProgLimits, ana_settings:get(Def)),
                     maps:get(K, Profile, undefined),
                     ana_settings:get(Ceil),
                     maps:get(K, Requested, undefined), Zero)}
         || {K, Def, Ceil, Zero} <- keys()]).

compute(Base, Profile, Ceiling, Requested, ZeroUnlimited) ->
    Values = [V || V <- [Base, Profile, Ceiling, Requested], is_integer(V)],
    case ZeroUnlimited of
        true ->
            case [V || V <- Values, V > 0] of
                [] -> 0;
                Positive -> lists:min(Positive)
            end;
        false ->
            lists:min([V || V <- Values, V > 0])
    end.

%% Groups grant (largest value among groups); otherwise the role profile.
profile_for(#{username := U, role := Role}) ->
    Groups = [profile({group, G}) || G <- ana_access:groups(U)],
    RoleProfile = profile({role, Role}),
    lists:foldl(fun({K, _, _, Zero}, Acc) ->
        case [maps:get(K, G) || G <- Groups, is_integer(maps:get(K, G, undefined))] of
            [] ->
                case maps:find(K, RoleProfile) of
                    {ok, V} -> Acc#{K => V};
                    error -> Acc
                end;
            Vs when Zero ->
                Acc#{K => case lists:member(0, Vs) of true -> 0; false -> lists:max(Vs) end};
            Vs ->
                Acc#{K => lists:max(Vs)}
        end
    end, #{}, keys()).

profile(Key = {Kind, Target}) ->
    case ets:lookup(?PROFILES, Key) of
        [{_, L}] -> L;
        [] ->
            L = case ana_db:one("SELECT limits FROM ana_system.limit_profile "
                                "WHERE target_kind = $1 AND target = $2",
                                [atom_to_binary(Kind), Target]) of
                {ok, #{<<"limits">> := M}} when is_map(M) -> M;
                _ -> #{}
            end,
            ets:insert(?PROFILES, {Key, L}),
            L
    end.

on_notify(_, _) ->
    ets:match_delete(?PROFILES, {{'_', '_'}, '_'}),
    ets:match_delete(?PROFILES, {{quota, '_'}, '_', '_'}),
    ok.

%% Program limits as declared by a developer: known keys, non-negative
%% integers, never above the ceiling (RF-012-09, RNF-012-03).
-spec validate(term()) -> ok | {error, binary()}.
validate(Limits) when is_map(Limits) ->
    Known = [K || {K, _, _, _} <- keys()],
    Errors = lists:filtermap(fun({K, V}) ->
        case lists:keyfind(K, 1, keys()) of
            false -> {true, [K, " desconhecido"]};
            _ when not is_integer(V); V < 0 -> {true, [K, <<" deve ser inteiro ≥ 0"/utf8>>]};
            {_, _, Ceil, _} ->
                C = ana_settings:get(Ceil),
                case C > 0 andalso V > C of
                    true -> {true, io_lib:format("~ts acima do teto (~b)", [K, C])};
                    false -> false
                end
        end
    end, maps:to_list(Limits)),
    _ = Known,
    case Errors of
        [] -> ok;
        _ -> {error, unicode:characters_to_binary(lists:join("; ", Errors))}
    end;
validate(_) -> {error, <<"limits deve ser um objeto">>}.

%% For the studio: declared, default, ceiling and effective (for this user).
describe(Program, User) ->
    Eff = effective(Program, User, #{}),
    Declared = maps:get(<<"limits">>, Program, #{}),
    [#{key => K, declared => maps:get(K, Declared, null), default => ana_settings:get(Def),
       ceiling => ana_settings:get(Ceil), effective => maps:get(K, Eff), zero_unlimited => Z}
     || {K, Def, Ceil, Z} <- keys()].

%% ==========================================================================
%% Concurrency and rate (RF-012-05, RF-012-06)
%% ==========================================================================

%% Takes the slots of an execution; returns the tokens to release later.
-spec acquire(binary(), map(), non_neg_integer()) -> {ok, list()} | {error, map()}.
acquire(Program, #{username := U}, ProgramMax) ->
    {UserMax, PerMinute} = quota(U),
    Minute = erlang:system_time(second) div 60,
    RateKey = {rate, U, Minute},
    case PerMinute > 0 andalso ets:update_counter(?COUNTERS, RateKey, 1, {RateKey, 0}) > PerMinute of
        true ->
            {error, err(<<"QUOTA_EXCEEDED">>, <<"limite de execuções por minuto do usuário atingido"/utf8>>)};
        false ->
            case take({user, U}, UserMax) of
                ok ->
                    case take({program, Program}, ProgramMax) of
                        ok -> {ok, [{user, U}, {program, Program}]};
                        full ->
                            release([{user, U}]),
                            {error, err(<<"PROGRAM_BUSY">>,
                                        <<"limite de execuções simultâneas do programa atingido"/utf8>>)}
                    end;
                full ->
                    {error, err(<<"QUOTA_EXCEEDED">>,
                                <<"limite de execuções simultâneas do usuário atingido"/utf8>>)}
            end
    end.

take(Key, 0) ->
    _ = ets:update_counter(?COUNTERS, Key, 1, {Key, 0}),
    ok;
take(Key, Max) ->
    case ets:update_counter(?COUNTERS, Key, 1, {Key, 0}) of
        N when N > Max -> _ = ets:update_counter(?COUNTERS, Key, -1), full;
        _ -> ok
    end.

release(Tokens) ->
    _ = [ets:update_counter(?COUNTERS, K, -1, {K, 1}) || K <- Tokens],
    ok.

quota(U) ->
    Now = erlang:monotonic_time(millisecond),
    case ets:lookup(?PROFILES, {quota, U}) of
        [{_, Q, Until}] when Until > Now -> Q;
        _ ->
            Q0 = case ana_db:one("SELECT max_concurrent, runs_per_minute FROM ana_system.user_quota "
                                 "WHERE username = $1", [U]) of
                {ok, #{} = R} -> R;
                _ -> #{}
            end,
            Q = {or_default(maps:get(<<"max_concurrent">>, Q0, null), user_max_concurrent),
                 or_default(maps:get(<<"runs_per_minute">>, Q0, null), user_runs_per_minute)},
            ets:insert(?PROFILES, {{quota, U}, Q, Now + 30000}),
            Q
    end.

or_default(null, Setting) -> ana_settings:get(Setting);
or_default(V, _) -> V.

%% ==========================================================================
%% Administration (RF-012-08)
%% ==========================================================================

list_profiles() ->
    ana_db:rows("SELECT target_kind, target, limits FROM ana_system.limit_profile ORDER BY 1, 2", []).

save_profile(Kind, Target, Limits, #{username := Who}) when Kind =:= <<"role">>; Kind =:= <<"group">> ->
    case validate(Limits) of
        ok ->
            {ok, _} = ana_db:exec(
                "INSERT INTO ana_system.limit_profile (target_kind, target, limits) "
                "VALUES ($1, $2, $3) ON CONFLICT (target_kind, target) DO UPDATE SET limits = EXCLUDED.limits",
                [Kind, Target, Limits]),
            changed(),
            ana_admin:log(Who, <<"limit_profile.save">>, <<Kind/binary, ":", Target/binary>>, null, Limits),
            {ok, #{target_kind => Kind, target => Target}};
        E -> E
    end;
save_profile(_, _, _, _) -> {error, <<"tipo de alvo inválido (role ou group)"/utf8>>}.

delete_profile(Kind, Target, #{username := Who}) ->
    {ok, N} = ana_db:exec("DELETE FROM ana_system.limit_profile WHERE target_kind = $1 AND target = $2",
                          [Kind, Target]),
    changed(),
    ana_admin:log(Who, <<"limit_profile.delete">>, <<Kind/binary, ":", Target/binary>>, null, null),
    {ok, #{deleted => N}}.

get_quota(U) ->
    {Max, Rate} = quota(U),
    {ok, #{username => U, max_concurrent => Max, runs_per_minute => Rate}}.

save_quota(U, Fields, #{username := Who}) ->
    Max = maps:get(<<"max_concurrent">>, Fields, null),
    Rate = maps:get(<<"runs_per_minute">>, Fields, null),
    case [V || V <- [Max, Rate], V =/= null, not (is_integer(V) andalso V >= 0)] of
        [] ->
            {ok, _} = ana_db:exec(
                "INSERT INTO ana_system.user_quota (username, max_concurrent, runs_per_minute) "
                "VALUES ($1, $2, $3) ON CONFLICT (username) DO UPDATE SET "
                "max_concurrent = EXCLUDED.max_concurrent, runs_per_minute = EXCLUDED.runs_per_minute",
                [U, Max, Rate]),
            changed(),
            ana_admin:log(Who, <<"user_quota.save">>, U, null, Fields),
            get_quota(U);
        _ -> {error, <<"cotas devem ser inteiros ≥ 0"/utf8>>}
    end.

%% RF-012-07/08: consumption ranking per program in the last N days.
consumption(Days) ->
    ana_db:rows(
        "SELECT program, count(*) AS runs, "
        "  round(avg(duration_ms)) AS avg_ms, max(duration_ms) AS max_ms, "
        "  sum(cpu_ms) AS total_cpu_ms, max(max_rss_kb) AS max_rss_kb, "
        "  sum(sql_count) AS sql_count, "
        "  count(*) FILTER (WHERE status IN ('timeout', 'error')) AS failures "
        "FROM ana_system.execution WHERE started_at > now() - make_interval(days => $1) "
        "GROUP BY program ORDER BY total_cpu_ms DESC NULLS LAST LIMIT 50", [Days]).

changed() ->
    on_notify(ana_access, all),
    _ = ana_db:exec("SELECT pg_notify('ana_access', 'limits')", []),
    ok.

err(Code, Msg) -> #{<<"code">> => Code, <<"message">> => Msg}.
