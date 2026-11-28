%% SPDX-FileCopyrightText: 2026 André Luis Pereira dos Santos
%% SPDX-License-Identifier: AGPL-3.0-or-later
%% The last log lines of this node, in memory only (spec 077, T-077-05, D7; plan §2.3): a `logger` handler keeping a
%% fixed-size ring in ETS — nothing written to disk (P15) — read by the diagnostic console and, in phase 2, by the
%% rescue mode (which then owns it, to outlive the main application).
-module(ana_log_ring).
-export([install/0, log/2, list/1]).

-define(TAB, ana_log_ring).
-define(SIZE, 5000).
-define(TEXT_MAX, 2000).

%% Called once by the top supervisor (the table's owner lives as long as the node).
-spec install() -> ok.
install() ->
    case ets:info(?TAB) of
        undefined ->
            _ = ets:new(?TAB, [named_table, public, ordered_set, {write_concurrency, true}]),
            ets:insert(?TAB, {seq, 0});
        _ -> ok
    end,
    _ = logger:remove_handler(?MODULE),
    ok = logger:add_handler(?MODULE, ?MODULE, #{level => info}),
    ok.

%% logger callback: never fails, never blocks.
log(#{level := Level, msg := Msg, meta := Meta}, _Config) ->
    try
        N = ets:update_counter(?TAB, seq, 1),
        Text = text(Msg),
        ets:insert(?TAB, {N, #{seq => N, level => Level, at => maps:get(time, Meta, erlang:system_time(microsecond)),
                               subsystem => subsystem(Meta), text => Text}}),
        ets:delete(?TAB, N - ?SIZE)
    catch _:_ -> ok
    end;
log(_, _) -> ok.

text({string, S}) -> cut(unicode:characters_to_binary(S));
text({report, R}) -> cut(unicode:characters_to_binary(io_lib:format("~0tp", [R])));
text({F, A}) -> cut(unicode:characters_to_binary(io_lib:format(F, A))).

cut(B) when byte_size(B) > ?TEXT_MAX -> <<(binary:part(B, 0, ?TEXT_MAX))/binary, "…"/utf8>>;
cut(B) -> B.

subsystem(#{mfa := {M, _, _}}) -> atom_to_binary(M);
subsystem(#{domain := [_ | _] = D}) -> iolist_to_binary(lists:join(".", [atom_to_binary(X) || X <- D]));
subsystem(_) -> <<"node">>.

%% Filters: level (minimum), text (contains), subsystem (prefix), since (seq), limit — newest first.
-spec list(map()) -> [map()].
list(F) ->
    Min = severity(maps:get(level, F, info)),
    Text = maps:get(text, F, <<>>),
    Sub = maps:get(subsystem, F, <<>>),
    Since = maps:get(since, F, 0),
    Limit = max(1, min(1000, maps:get(limit, F, 200))),
    case ets:info(?TAB) of
        undefined -> [];
        _ -> collect(ets:prev(?TAB, seq), Min, Text, Sub, Since, Limit, [])
    end.

collect(_, _, _, _, _, 0, Acc) -> lists:reverse(Acc);
collect('$end_of_table', _, _, _, _, _, Acc) -> lists:reverse(Acc);
collect(K, Min, Text, Sub, Since, N, Acc) when is_integer(K), K > Since ->
    case ets:lookup(?TAB, K) of
        [{_, E = #{level := L, text := T, subsystem := S}}] ->
            Keep = severity(L) >= Min andalso (Text =:= <<>> orelse binary:match(T, Text) =/= nomatch)
                   andalso binary:longest_common_prefix([S, Sub]) =:= byte_size(Sub),
            case Keep of
                true -> collect(ets:prev(?TAB, K), Min, Text, Sub, Since, N - 1, [E | Acc]);
                false -> collect(ets:prev(?TAB, K), Min, Text, Sub, Since, N, Acc)
            end;
        [] -> collect(ets:prev(?TAB, K), Min, Text, Sub, Since, N, Acc)
    end;
collect(_, _, _, _, _, _, Acc) -> lists:reverse(Acc).

severity(L) when is_binary(L) -> try severity(binary_to_existing_atom(L)) catch _:_ -> 1 end;
severity(debug) -> 0;
severity(info) -> 1;
severity(notice) -> 2;
severity(warning) -> 3;
severity(error) -> 4;
severity(critical) -> 5;
severity(alert) -> 6;
severity(emergency) -> 7;
severity(_) -> 1.
