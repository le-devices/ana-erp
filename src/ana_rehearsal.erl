%% SPDX-FileCopyrightText: 2026 LE Devices
%% SPDX-License-Identifier: AGPL-3.0-or-later
%% Universal rehearsal (spec 056, T-056-01/02).
%%
%% A rehearsal runs the routine whole in its own transaction and undoes it at the end. Before the ROLLBACK, the
%% effect is read from what the transaction itself left (RF-056-02, D2): the database's per-transaction statistics
%% say which tables were written and how; rehearsal.table_rows/2 gives the rows (only this transaction's) for
%% the names of business and the documents to open (spec 035). Nothing here knows any routine.
%% External effects (connectors, remote systems, files, scheduler) are held by the execution and listed (D1).
-module(ana_rehearsal).

-export([baseline/1, effects/3, merge/2, hold/2, held_reply/1]).

-define(MAX_TABLES, 40).
-define(SAMPLE, 5).
-define(TABLE_TIMEOUT_MS, 3000).

%% The per-transaction statistics of a pooled connection may still carry counts of earlier transactions not yet
%% flushed; they do not move while a transaction runs, so the rehearsal takes them at its start and subtracts.
-spec baseline(pid()) -> map().
baseline(C) ->
    maps:from_list([{N, S} || S = #{<<"name">> := N} <- stats(C)]).

%% Read inside the execution's transaction (connection C), right before it is rolled back.
-spec effects(pid(), [map()], map()) -> map().
effects(C, Held, Base) ->
    Stats = [S || S0 = #{<<"name">> := N} <- stats(C),
                  S <- [minus(S0, maps:get(N, Base, #{}))],
                  maps:get(<<"inserted">>, S) + maps:get(<<"updated">>, S) + maps:get(<<"deleted">>, S) > 0],
    Names = names(),
    Tables = [table(C, S, Names) || S <- lists:sublist(Stats, ?MAX_TABLES)],
    Visible = [T || T = #{rows := N, deleted := D} <- Tables, N + D > 0],
    sorted(#{tables => Visible, messages => messages(Visible), held => lists:reverse(Held),
             documents => lists:append([Ds || #{documents := Ds} <- Visible])}).

minus(S, B) ->
    maps:map(fun(K, V) when K =:= <<"inserted">>; K =:= <<"updated">>; K =:= <<"deleted">> -> V - maps:get(K, B, 0);
                (_, V) -> V
             end, S).

stats(C) ->
    case ana_db:query(C,
                "SELECT format('%I.%I', schemaname, relname) AS name, relid::bigint AS oid, n_tup_ins AS inserted, "
                "       n_tup_upd AS updated, n_tup_del AS deleted "
                "FROM pg_stat_xact_user_tables "
                "WHERE n_tup_ins + n_tup_upd + n_tup_del > 0 AND schemaname <> 'ana_system' AND schemaname NOT LIKE 'pg\\_temp%' "
                "ORDER BY schemaname, relname", []) of
        {ok, R} -> as_maps(R);
        {error, _} -> []
    end.

table(C, #{<<"name">> := Name, <<"oid">> := Oid, <<"inserted">> := I, <<"updated">> := U, <<"deleted">> := D}, Names) ->
    {Label, Kind, Order} = maps:get(Name, Names, {humanize(Name), null, 1000}),
    {Rows, Sample, Partial} = rows(C, Oid),
    Docs = case Kind of
        null -> [];
        _ -> [#{kind => Kind, key => integer_to_binary(Id), label => Label}
              || #{<<"id">> := Id} <- Sample, is_integer(Id)]
    end,
    #{table => Name, label => Label, doc_kind => Kind, order => Order,
      %% What is left: rows found (new or changed), and the deleted ones from the statistics.
      rows => case Partial of true -> I + U; false -> Rows end, deleted => D,
      change => change(I, U, case Partial of true -> I + U; false -> Rows end), sample => Sample,
      documents => Docs, partial => Partial}.

%% "created", "changed" or both. A row created and then changed in the same transaction (a total filled after the
%% items) is still a creation: when no more rows are left than were inserted, every one of them is new.
change(0, 0, _) -> <<"deleted">>;
change(I, _, Rows) when I > 0, Rows =< I -> <<"created">>;
change(0, _, _) -> <<"changed">>;
change(_, _, _) -> <<"created_or_changed">>.

%% A big table could take long: each read has its own savepoint and time limit, so a slow or refused one only
%% leaves that table with the counts.
rows(C, Oid) ->
    _ = epgsql:squery(C, ["SAVEPOINT ana_rehearsal; SET LOCAL statement_timeout = ", integer_to_list(?TABLE_TIMEOUT_MS)]),
    case ana_db:query(C, "SELECT total, sample FROM rehearsal.table_rows($1::bigint::oid::regclass, $2)", [Oid, ?SAMPLE]) of
        {ok, #{rows := [[Total, Sample]]}} ->
            _ = epgsql:squery(C, "RELEASE SAVEPOINT ana_rehearsal"),
            {Total, decode(Sample), false};
        _ ->
            _ = epgsql:squery(C, "ROLLBACK TO SAVEPOINT ana_rehearsal; RELEASE SAVEPOINT ana_rehearsal"),
            {0, [], true}
    end.

decode(B) when is_binary(B) -> try json:decode(B) catch _:_ -> [] end;
decode(L) when is_list(L) -> L;
decode(_) -> [].

%% Messages that would leave (the outbox, spec 044): to whom and about what.
messages(Tables) ->
    [maps:filter(fun(_, V) -> V =/= null end,
                 #{kind => K, connector => maps:get(<<"connector">>, R, null),
                   to => pick(P, [<<"to">>]), subject => pick(P, [<<"subject">>])})
     || #{table := <<"integration.outbox">>, sample := S} <- Tables, R <- S,
        K <- [maps:get(<<"kind">>, R, null)], P <- [payload(maps:get(<<"payload">>, R, #{}))]].

payload(M) when is_map(M) -> M;
payload(B) when is_binary(B) -> try json:decode(B) catch _:_ -> #{} end;
payload(_) -> #{}.

pick(P, [K | _]) -> maps:get(K, P, null).

sorted(E = #{tables := T}) ->
    E#{tables => [maps:remove(order, X) || X <- lists:sort(fun(#{order := A, table := Na}, #{order := B, table := Nb}) ->
                                                                {A, Na} =< {B, Nb} end, T)]}.

names() ->
    case ana_db:rows("SELECT table_name, label, doc_kind, show_order FROM ana_system.business_table", []) of
        {ok, Rows} -> maps:from_list([{T, {L, K, O}} || #{<<"table_name">> := T, <<"label">> := L,
                                                         <<"doc_kind">> := K, <<"show_order">> := O} <- Rows]);
        _ -> #{}
    end.

%% "finance.bank_match" → "bank match (finance)": a table without a business name still reads.
humanize(Name) ->
    case binary:split(Name, <<".">>) of
        [S, T] -> iolist_to_binary([binary:replace(T, <<"_">>, <<" ">>, [global]), " (", S, ")"]);
        _ -> Name
    end.

%% Effects of the parts (spec 022) join the main execution's.
-spec merge(map(), map()) -> map().
merge(A, B) ->
    ByName = lists:foldl(fun(T = #{table := N}, Acc) ->
                             case maps:find(N, Acc) of
                                 {ok, X} -> Acc#{N => X#{rows => maps:get(rows, X) + maps:get(rows, T),
                                                         deleted => maps:get(deleted, X) + maps:get(deleted, T),
                                                         sample => lists:sublist(maps:get(sample, X) ++ maps:get(sample, T), ?SAMPLE),
                                                         documents => maps:get(documents, X) ++ maps:get(documents, T)}};
                                 error -> Acc#{N => T}
                             end
                         end, #{}, maps:get(tables, A, []) ++ maps:get(tables, B, [])),
    #{tables => [T || {_, T} <- lists:sort(maps:to_list(ByName))],
      messages => maps:get(messages, A, []) ++ maps:get(messages, B, []),
      held => maps:get(held, A, []) ++ maps:get(held, B, []),
      documents => maps:get(documents, A, []) ++ maps:get(documents, B, [])}.

%% Does this request leave the transaction? Then a rehearsal holds it (D1): {hold, What} | {rewrite, Args} | pass.
-spec hold(binary(), map()) -> {hold, map()} | {rewrite, map()} | pass.
hold(<<"http">>, #{<<"connector">> := C, <<"method">> := M, <<"path">> := P}) ->
    %% Reading through a connector changes nothing: it runs, so the rehearsal stays close to the real thing.
    case string:uppercase(M) of
        R when R =:= <<"GET">>; R =:= <<"HEAD">> -> pass;
        R -> {hold, #{kind => <<"http">>, connector => C, method => R, path => P}}
    end;
hold(<<"remote">>, #{<<"system">> := S, <<"function">> := F}) ->
    {hold, #{kind => <<"remote">>, system => S, function => F}};
hold(<<"files">>, #{<<"action">> := <<"folder">>} = Req) ->
    %% Finding a folder is a read; creating one is not: a rehearsal only finds.
    {rewrite, Req#{<<"create">> => false}};
hold(<<"files">>, #{<<"action">> := A} = Req) when A =/= <<"get">>, A =/= <<"list">> ->
    {hold, maps:filter(fun(_, V) -> V =/= null end,
                       #{kind => <<"files">>, action => A, name => maps:get(<<"name">>, Req, null),
                         folder => maps:get(<<"folder">>, Req, null), file => maps:get(<<"file">>, Req, null)})};
hold(<<"schedule">>, #{<<"name">> := N} = Req) ->
    {hold, #{kind => <<"schedule">>, name => N, program => maps:get(<<"program">>, Req, null),
             cron => maps:get(<<"cron">>, Req, null), active => maps:get(<<"active">>, Req, true)}};
hold(<<"set_value">>, #{<<"name">> := N} = Req) ->
    %% Spec 065 (D4): a company value the routine would keep.
    {hold, #{kind => <<"value">>, name => N, value => maps:get(<<"value">>, Req, null)}};
hold(_, _) -> pass.

%% What the program receives for a held request: an answer saying it was held, in the shape it expects.
-spec held_reply(map()) -> map().
held_reply(#{kind := <<"http">>}) -> #{<<"status">> => 202, <<"headers">> => #{}, <<"text">> => <<>>, <<"held">> => true};
held_reply(#{kind := <<"schedule">>}) -> #{<<"job">> => null, <<"held">> => true};
held_reply(#{kind := <<"value">>, name := N, value := V}) -> #{<<"name">> => N, <<"value">> => V, <<"held">> => true};
held_reply(#{kind := <<"files">>}) -> #{<<"file">> => null, <<"version">> => null, <<"id">> => null, <<"held">> => true};
held_reply(_) -> #{<<"held">> => true}.

as_maps(#{columns := Cols, rows := Rows}) ->
    Names = [N || #{name := N} <- Cols],
    [maps:from_list(lists:zip(Names, R)) || R <- Rows].
