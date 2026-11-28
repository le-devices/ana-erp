%% SPDX-FileCopyrightText: 2026 André Luis Pereira dos Santos
%% SPDX-License-Identifier: AGPL-3.0-or-later
%% Operation modes (spec 077, T-077-07, D14, CA-077-08; plan §2.5): read-only, maintenance, the entry of integrations
%% paused, the scheduled routines suspended. The state lives in a persistent term on every node, reloaded on NOTIFY
%% "ana_mode": asking "may I write?" costs nothing per request. The database refuses the writes (execution
%% transactions opened READ ONLY), not only the screen.
-module(ana_mode).

-export([load/0, on_notify/2, current/0, read_only/0, maintenance/0, inbound_paused/0, routines_suspended/0,
         admits/1, message/0, set/3, normal/1]).

-define(KEY, {?MODULE, state}).
-define(NORMAL, #{mode => <<"normal">>, inbound_paused => false, routines_suspended => false, message => null,
                  until => null, until_label => null, technical_group => null, set_by => null}).

-spec load() -> ok.
load() ->
    S = case catch ana_db:one("SELECT mode, inbound_paused, routines_suspended, message, technical_group, set_by, "
                              "  to_char(until, 'YYYY-MM-DD\"T\"HH24:MI:SSOF') AS until, "
                              "  to_char(until AT TIME ZONE $1, 'HH24\"h\"MI') AS until_label "
                              "FROM technical.operation_mode WHERE id = 1", [ana_config:timezone()]) of
        {ok, #{<<"mode">> := M} = R} ->
            #{mode => M, inbound_paused => maps:get(<<"inbound_paused">>, R), routines_suspended => maps:get(<<"routines_suspended">>, R),
              message => maps:get(<<"message">>, R), until => maps:get(<<"until">>, R),
              until_label => maps:get(<<"until_label">>, R),
              technical_group => maps:get(<<"technical_group">>, R), set_by => maps:get(<<"set_by">>, R)};
        _ -> persistent_term:get(?KEY, ?NORMAL)          % the database is out: keep what was known
    end,
    persistent_term:put(?KEY, S),
    ok.

on_notify(_Channel, _Payload) -> load().

-spec current() -> map().
current() -> persistent_term:get(?KEY, ?NORMAL).

read_only() -> maps:get(mode, current()) =:= <<"read_only">>.
maintenance() -> maps:get(mode, current()) =:= <<"maintenance">>.
inbound_paused() -> maps:get(inbound_paused, current()).
routines_suspended() -> maps:get(routines_suspended, current()).

%% Maintenance: only administrators and the technical team get in.
-spec admits(map()) -> boolean().
admits(#{role := <<"admin">>}) -> true;
admits(#{username := U}) ->
    case maintenance() of
        false -> true;
        true ->
            case maps:get(technical_group, current()) of
                G when is_binary(G) -> lists:member(G, ana_access:groups(U));
                _ -> false
            end
    end;
admits(_) -> not maintenance().

%% The sentence the screens, the portal and the API show.
-spec message() -> binary() | null.
message() ->
    S = current(),
    Base = case maps:get(mode, S) of
        <<"read_only">> -> <<"O ERP está em modo somente leitura: consultas funcionam, gravações não"/utf8>>;
        <<"maintenance">> -> <<"O ERP está em manutenção"/utf8>>;
        _ when map_get(inbound_paused, S); map_get(routines_suspended, S) -> <<"Parte do ERP está pausada"/utf8>>;
        _ -> null
    end,
    case Base of
        null -> null;
        _ ->
            Until = case maps:get(until_label, S) of
                T when is_binary(T) -> <<" até "/utf8, T/binary>>;
                _ -> <<>>
            end,
            Extra = case maps:get(message, S) of
                M when is_binary(M), M =/= <<>> -> <<". ", M/binary>>;
                _ -> <<>>
            end,
            <<Base/binary, Until/binary, Extra/binary>>
    end.

%% Field → value (mode, inbound_paused, routines_suspended, message, minutes, technical_group).
-spec set(map(), binary(), map()) -> {ok, map()}.
set(Changes, Who, _Opts) ->
    Mode = maps:get(mode, Changes, null),
    In = maps:get(inbound_paused, Changes, null),
    Rt = maps:get(routines_suspended, Changes, null),
    Msg = maps:get(message, Changes, keep),
    Min = maps:get(minutes, Changes, null),
    Group = maps:get(technical_group, Changes, keep),
    {ok, _} = ana_db:exec(
        "UPDATE technical.operation_mode SET mode = COALESCE($1, mode), inbound_paused = COALESCE($2, inbound_paused), "
        "  routines_suspended = COALESCE($3, routines_suspended), "
        "  message = CASE WHEN $4::boolean THEN $5 ELSE message END, "
        "  until = CASE WHEN $1::text IS NULL THEN until WHEN $6::int IS NULL THEN NULL "
        "               ELSE now() + make_interval(mins => $6::int) END, "
        "  technical_group = CASE WHEN $7::boolean THEN $8 ELSE technical_group END, "
        "  set_by = $9, set_at = now() WHERE id = 1",
        [Mode, In, Rt, Msg =/= keep, case Msg of keep -> null; _ -> Msg end, Min, Group =/= keep,
         case Group of keep -> null; _ -> Group end, Who]),
    load(),
    {ok, current()}.

%% Back to normal, in order: writes first, then the entry of integrations, then the scheduled routines (D14).
-spec normal(binary()) -> {ok, map()}.
normal(Who) ->
    {ok, _} = set(#{mode => <<"normal">>, message => null}, Who, #{}),
    {ok, _} = set(#{inbound_paused => false}, Who, #{}),
    _ = (catch ana_integration:poke()),
    set(#{routines_suspended => false}, Who, #{}).
