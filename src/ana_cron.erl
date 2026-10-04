%% Cron expressions and business-day calendars (spec 018, RF-018-02).
%%
%% Pure functions over *local* naive datetimes; time zone conversion happens
%% elsewhere (PostgreSQL holds the zone database). Granularity: one minute.
%%
%% Fields: minute hour day-of-month month day-of-week, each a list of `*`,
%% `N`, `A-B`, `*/S`, `A-B/S` or names (jan..dec, sun..sat). As in classic
%% cron, when both day-of-month and day-of-week are restricted, a day matches
%% if EITHER matches.
-module(ana_cron).
-export([parse/1, next/2, next_n/3, business_day/2, last_business_day/3, nth_business_day/4,
         next_calendar/5, next_business/3]).

-type cron() :: #{minute := [0..59], hour := [0..23], dom := [1..31], month := [1..12],
                  dow := [0..6], dom_any := boolean(), dow_any := boolean()}.
-type local() :: calendar:datetime().
-export_type([cron/0]).

-define(MAX_DAYS, 366 * 5).

%% ==========================================================================
%% Parsing
%% ==========================================================================

-spec parse(binary() | string()) -> {ok, cron()} | {error, binary()}.
parse(Expr) when is_list(Expr) -> parse(list_to_binary(Expr));
parse(Expr) when is_binary(Expr) ->
    case string:lexemes(string:lowercase(Expr), " \t") of
        [Mi, H, Dom, Mo, Dow] ->
            try
                {ok, #{minute => field(Mi, 0, 59, #{}),
                       hour => field(H, 0, 23, #{}),
                       dom => field(Dom, 1, 31, #{}),
                       month => field(Mo, 1, 12, months()),
                       dow => [D rem 7 || D <- field(Dow, 0, 7, days())],
                       dom_any => Dom =:= <<"*">>,
                       dow_any => Dow =:= <<"*">>}}
            catch throw:{bad, Part} ->
                {error, unicode:characters_to_binary(["expressão cron inválida em \"", Part, "\""])}
            end;
        _ -> {error, <<"a expressão cron deve ter 5 campos: minuto hora dia mês dia-da-semana"/utf8>>}
    end;
parse(_) -> {error, <<"expressão cron inválida"/utf8>>}.

months() ->
    maps:from_list(lists:zip([<<"jan">>, <<"feb">>, <<"mar">>, <<"apr">>, <<"may">>, <<"jun">>,
                              <<"jul">>, <<"aug">>, <<"sep">>, <<"oct">>, <<"nov">>, <<"dec">>],
                             lists:seq(1, 12))).

days() ->
    maps:from_list(lists:zip([<<"sun">>, <<"mon">>, <<"tue">>, <<"wed">>, <<"thu">>, <<"fri">>, <<"sat">>],
                             lists:seq(0, 6))).

field(Text, Min, Max, Names) ->
    Values = lists:append([part(P, Min, Max, Names) || P <- binary:split(Text, <<",">>, [global])]),
    case Values of
        [] -> throw({bad, Text});
        _ -> lists:usort(Values)
    end.

part(P, Min, Max, Names) ->
    {Range, Step} = case binary:split(P, <<"/">>) of
        [R, S] -> {R, int(S, 1, Max, #{}, P)};
        [R] -> {R, 1}
    end,
    {Lo, Hi} = case Range of
        <<"*">> -> {Min, Max};
        _ ->
            case binary:split(Range, <<"-">>) of
                [A, B] -> {int(A, Min, Max, Names, P), int(B, Min, Max, Names, P)};
                [A] when Step =:= 1 -> V = int(A, Min, Max, Names, P), {V, V};
                [A] -> {int(A, Min, Max, Names, P), Max}
            end
    end,
    Lo =< Hi orelse throw({bad, P}),
    lists:seq(Lo, Hi, Step).

int(Bin, Min, Max, Names, Part) ->
    V = case maps:find(Bin, Names) of
        {ok, N} -> N;
        error ->
            try binary_to_integer(Bin) catch error:badarg -> throw({bad, Part}) end
    end,
    (V >= Min andalso V =< Max) orelse throw({bad, Part}),
    V.

%% ==========================================================================
%% Next occurrence
%% ==========================================================================

%% First local datetime strictly after From that matches.
-spec next(cron(), local()) -> {ok, local()} | none.
next(Cron, {Date, {H, Mi, _}}) ->
    search(Cron, add_minutes({Date, {H, Mi, 0}}, 1), 0).

-spec next_n(cron(), local(), pos_integer()) -> [local()].
next_n(_Cron, _From, 0) -> [];
next_n(Cron, From, N) ->
    case next(Cron, From) of
        {ok, T} -> [T | next_n(Cron, T, N - 1)];
        none -> []
    end.

search(_Cron, _T, Days) when Days > ?MAX_DAYS -> none;
search(Cron = #{month := Months}, {{Y, M, D}, {H, Mi, _}} = T, Days) ->
    case lists:member(M, Months) of
        false ->
            {Y2, M2} = next_month(Y, M),
            search(Cron, {{Y2, M2, 1}, {0, 0, 0}}, Days + 28);
        true ->
            case day_matches(Cron, {Y, M, D}) of
                false -> search(Cron, next_day(T), Days + 1);
                true ->
                    case first_at_or_after(H, maps:get(hour, Cron)) of
                        none -> search(Cron, next_day(T), Days + 1);
                        H2 when H2 > H -> search(Cron, {{Y, M, D}, {H2, 0, 0}}, Days);
                        H ->
                            case first_at_or_after(Mi, maps:get(minute, Cron)) of
                                none when H < 23 -> search(Cron, {{Y, M, D}, {H + 1, 0, 0}}, Days);
                                none -> search(Cron, next_day(T), Days + 1);
                                Mi2 -> {ok, {{Y, M, D}, {H, Mi2, 0}}}
                            end
                    end
            end
    end.

day_matches(#{dom := Dom, dow := Dow, dom_any := DomAny, dow_any := DowAny}, Date) ->
    DomOk = lists:member(element(3, Date), Dom),
    DowOk = lists:member(calendar:day_of_the_week(Date) rem 7, Dow),
    case {DomAny, DowAny} of
        {true, true} -> true;
        {true, false} -> DowOk;
        {false, true} -> DomOk;
        {false, false} -> DomOk orelse DowOk
    end.

first_at_or_after(V, List) ->
    case [X || X <- List, X >= V] of
        [X | _] -> X;
        [] -> none
    end.

next_day({Date, _}) ->
    {calendar:gregorian_days_to_date(calendar:date_to_gregorian_days(Date) + 1), {0, 0, 0}}.

next_month(Y, 12) -> {Y + 1, 1};
next_month(Y, M) -> {Y, M + 1}.

add_minutes(T, N) ->
    calendar:gregorian_seconds_to_datetime(calendar:datetime_to_gregorian_seconds(T) + N * 60).

%% Cron restricted to business days: skips matches on weekends/holidays.
-spec next_business(cron(), local(), [calendar:date()]) -> {ok, local()} | none.
next_business(Cron, From, Holidays) -> next_business(Cron, From, Holidays, 0).

next_business(_, _, _, N) when N > 1000 -> none;
next_business(Cron, From, Holidays, N) ->
    case next(Cron, From) of
        {ok, {Date, _} = T} ->
            case business_day(Date, Holidays) of
                true -> {ok, T};
                false -> next_business(Cron, {Date, {23, 59, 0}}, Holidays, N + 1)
            end;
        none -> none
    end.

%% ==========================================================================
%% Business-day calendar
%% ==========================================================================

-spec business_day(calendar:date(), [calendar:date()]) -> boolean().
business_day(Date, Holidays) ->
    calendar:day_of_the_week(Date) =< 5 andalso not lists:member(Date, Holidays).

-spec last_business_day(integer(), 1..12, [calendar:date()]) -> calendar:date().
last_business_day(Y, M, Holidays) ->
    back(Y, M, calendar:last_day_of_the_month(Y, M), Holidays).

back(Y, M, D, Holidays) ->
    case business_day({Y, M, D}, Holidays) of
        true -> {Y, M, D};
        false when D > 1 -> back(Y, M, D - 1, Holidays);
        false -> {Y, M, 1}
    end.

-spec nth_business_day(integer(), 1..12, pos_integer(), [calendar:date()]) -> calendar:date() | none.
nth_business_day(Y, M, N, Holidays) ->
    Days = [{Y, M, D} || D <- lists:seq(1, calendar:last_day_of_the_month(Y, M)),
                         business_day({Y, M, D}, Holidays)],
    case length(Days) >= N of
        true -> lists:nth(N, Days);
        false -> none
    end.

%% Next local datetime of a monthly calendar rule at a given time.
-spec next_calendar(last_business_day | nth_business_day, pos_integer() | undefined,
                    {0..23, 0..59}, local(), [calendar:date()]) -> {ok, local()} | none.
next_calendar(Rule, Nth, At, {{Y, M, _}, _} = From, Holidays) ->
    next_calendar(Rule, Nth, At, From, Holidays, Y, M, 0).

next_calendar(_, _, _, _, _, _, _, N) when N > 36 -> none;
next_calendar(Rule, Nth, {H, Mi}, From, Holidays, Y, M, N) ->
    Day = case Rule of
        last_business_day -> last_business_day(Y, M, Holidays);
        nth_business_day -> nth_business_day(Y, M, Nth, Holidays)
    end,
    Candidate = case Day of none -> none; _ -> {Day, {H, Mi, 0}} end,
    case Candidate =/= none andalso Candidate > From of
        true -> {ok, Candidate};
        false ->
            {Y2, M2} = next_month(Y, M),
            next_calendar(Rule, Nth, {H, Mi}, From, Holidays, Y2, M2, N + 1)
    end.
