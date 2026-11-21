%% SPDX-FileCopyrightText: 2026 André Luis Pereira dos Santos
%% SPDX-License-Identifier: AGPL-3.0-or-later
%% Bounded fire-and-forget messages (spec 062, D7): a record sent to a process that is behind (a slow
%% database, a burst) is dropped and counted instead of growing its mailbox — and the memory — without
%% end. Only for records whose loss is tolerable (statistics, access log batches): never for business facts.
-module(ana_bounded).
-export([cast/3, dropped/0]).

-define(TAB, ana_metrics).

-spec cast(atom(), term(), pos_integer()) -> ok.
cast(Name, Msg, Limit) ->
    case whereis(Name) of
        undefined -> ok;
        Pid ->
            case process_info(Pid, message_queue_len) of
                {message_queue_len, N} when N >= Limit ->
                    _ = catch ets:update_counter(?TAB, {dropped, Name}, 1, {{dropped, Name}, 0}),
                    ok;
                _ -> gen_server:cast(Pid, Msg)
            end
    end.

%% #{process => dropped records} since the node started.
-spec dropped() -> map().
dropped() -> maps:from_list([{N, V} || {{dropped, N}, V} <- catch ets:tab2list(?TAB)]).
