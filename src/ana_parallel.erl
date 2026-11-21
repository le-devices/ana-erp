%% SPDX-FileCopyrightText: 2026 André Luis Pereira dos Santos
%% SPDX-License-Identifier: AGPL-3.0-or-later
%% Parallel execution support (spec 022): two-phase commit helpers and the
%% recovery of orphan prepared transactions (RF-022-04).
%%
%% Prepared transactions are created, committed and rolled back with ana_exec
%% connections: only the same role (or a superuser) may finish them.
-module(ana_parallel).
-export([gid/2, resolve/2, decide/2, forget/1, recover/1, valid_snapshot/1]).

-define(POOL, ana_db_exec).

%% "ana_<node>_<execution>_<part>" — part 0 is the main execution itself.
-spec gid(binary(), non_neg_integer()) -> binary().
gid(ExecId, Part) ->
    Node = integer_to_binary(erlang:phash2(ana_config:node_id()), 16),
    Exec = binary:replace(ExecId, <<"-">>, <<>>, [global]),
    <<"ana_", Node/binary, "_", Exec/binary, "_", (integer_to_binary(Part))/binary>>.

valid_gid(G) ->
    re:run(G, "^ana_[0-9A-F]{1,8}_[0-9a-f]{32}_[0-9]{1,6}$", [{capture, none}]) =:= match.

-spec valid_snapshot(term()) -> boolean().
valid_snapshot(S) when is_binary(S), byte_size(S) < 64 ->
    re:run(S, "^[0-9A-F]+-[0-9A-F]+(-[0-9]+)?$", [{capture, none}]) =:= match;
valid_snapshot(_) -> false.

%% COMMIT PREPARED / ROLLBACK PREPARED each gid; already finished ones are ignored.
-spec resolve([binary()], commit | rollback) -> ok | {error, term()}.
resolve([], _) -> ok;
resolve(Gids, Action) ->
    Verb = case Action of commit -> "COMMIT PREPARED '"; rollback -> "ROLLBACK PREPARED '" end,
    case ana_db:checkout(?POOL, 15000) of
        {ok, C} ->
            Errors = [{G, E} || G <- Gids, valid_gid(G),
                                {error, E} <- [epgsql:squery(C, [Verb, G, "'"])],
                                not missing(E)],
            ana_db:checkin(?POOL, C),
            case Errors of
                [] -> ok;
                _ -> logger:error("prepared transactions not resolved (~p): ~0p", [Action, Errors]),
                     {error, Errors}
            end;
        {error, E} ->
            logger:error("no connection to resolve prepared transactions: ~0p", [E]),
            {error, E}
    end.

missing(E) -> maps:get(sqlstate, ana_db:sql_error(E), undefined) =:= <<"42704">>.   % undefined_object

%% Durable decision written before the first COMMIT PREPARED.
-spec decide(binary(), [binary()]) -> ok | {error, term()}.
decide(Main, Gids) ->
    case ana_db:exec("INSERT INTO ana_system.parallel_decision (main_gid, gids, decision, node) "
                     "VALUES ($1, $2, 'commit', $3)", [Main, Gids, ana_config:node_id()]) of
        {ok, _} -> ok;
        E -> E
    end.

forget(Main) ->
    _ = ana_db:exec("DELETE FROM ana_system.parallel_decision WHERE main_gid = $1", [Main]),
    ok.

%% startup: every "ana_" transaction of this node is an orphan (no execution
%% survives a restart). periodic: any node's, when older than twice the
%% ceiling of execution time. Decided ones are committed; the rest rolled back.
-spec recover(startup | periodic) -> {ok, map()} | {error, term()}.
recover(Mode) ->
    try
        MaxAge = 2 * ana_settings:get(ceiling_timeout_ms) div 1000,
        Mine = <<"ana_", (integer_to_binary(erlang:phash2(ana_config:node_id()), 16))/binary, "_">>,
        {ok, Prepared} = ana_db:rows(
            "SELECT gid, extract(epoch FROM now() - prepared)::bigint AS age FROM pg_prepared_xacts "
            "WHERE gid LIKE 'ana\\_%' AND database = current_database()", []),
        {ok, Decisions} = ana_db:rows("SELECT main_gid, gids FROM ana_system.parallel_decision", []),
        Commit = lists:usort(lists:append([G || #{<<"gids">> := G} <- Decisions])),
        {ToCommit, Rest} = lists:partition(fun(#{<<"gid">> := G}) -> lists:member(G, Commit) end, Prepared),
        ToRollback = [R || R = #{<<"gid">> := G, <<"age">> := Age} <- Rest,
                           (Mode =:= startup andalso binary:match(G, Mine) =:= {0, byte_size(Mine)})
                           orelse Age > MaxAge],
        ok = ok_or_log(resolve([G || #{<<"gid">> := G} <- ToCommit], commit)),
        ok = ok_or_log(resolve([G || #{<<"gid">> := G} <- ToRollback], rollback)),
        %% Decisions whose transactions are all finished are no longer needed.
        Still = [G || #{<<"gid">> := G} <- Prepared] -- [G || #{<<"gid">> := G} <- ToCommit],
        _ = [forget(M) || #{<<"main_gid">> := M, <<"gids">> := Gs} <- Decisions,
                          not lists:any(fun(G) -> lists:member(G, Still) end, Gs)],
        N = #{committed => length(ToCommit), rolled_back => length(ToRollback)},
        _ = (length(ToCommit) + length(ToRollback)) > 0
            andalso ok =:= logger:notice("prepared transactions recovered: ~0p", [N]),
        {ok, N}
    catch Class:Reason:Stack ->
        logger:error("recovery of prepared transactions failed: ~0p:~0p ~0p", [Class, Reason, Stack]),
        {error, Reason}
    end.

ok_or_log(ok) -> ok;
ok_or_log({error, _}) -> ok.
