%% Automated flows (spec 030, RF-030-02..05), executed by the single process engine (ana_bpm, spec
%% 039): the engine's loop claims ready steps (claim/1), runs them (step/1) and sweeps waiting ones
%% (sweep/0), sharing capacity, leader and execution policy with the BPM cases.
%%
%% A flow instance follows one document through its steps (flow schema, migration 031). A ready step
%% is claimed with a lease (FOR UPDATE SKIP LOCKED: a crashed node's step is taken again after the
%% lease); before running anything the engine reads the document's facts and asks the product SQL
%% whether the document was cancelled or the step is already done (someone did it outside the flow).
%% An automatic step whose condition holds runs its program as the flow's robot (P14) — or as the
%% person who asked to run it now; a manual step, a false condition or a "wait" step waits.
%% Technical failures are retried with backoff; business refusals (customer blocked, no stock…) stop
%% the instance with the reason until someone acts. Waiting and failed steps are swept, so work done
%% by hand moves the flow on.
-module(ana_flows).

-export([claim/1, step/1, sweep/0, user/1, check/2, code/1, small/1]).
-export([render/2, condition/2]).

-define(LEASE, "interval '15 minutes'").

claim(N) ->
    case ana_db:rows(
            "UPDATE flow.instance_step x SET status = 'running', lease_until = now() + " ?LEASE ", "
            "  started_at = now(), attempts = x.attempts + 1 "
            "FROM (SELECT instance_id, seq FROM flow.instance_step "
            "      WHERE (status = 'ready' AND next_at <= now()) OR (status = 'running' AND lease_until < now()) "
            "      ORDER BY next_at NULLS FIRST LIMIT $1 FOR UPDATE SKIP LOCKED) c "
            "WHERE x.instance_id = c.instance_id AND x.seq = c.seq "
            "RETURNING x.instance_id, x.seq, x.attempts, x.force, x.requested_by", [N]) of
        {ok, Rows} -> Rows;
        {error, E} -> logger:warning("flows: claim failed: ~0p", [E]), []
    end.

%% ---------------------------------------------------------------- one step

step(#{<<"instance_id">> := I, <<"seq">> := Seq} = Claim) ->
    try do_step(Claim)
    catch C:R:St ->
        logger:error("flow step ~p/~p crashed: ~0p:~0p ~0p", [I, Seq, C, R, St]),
        fail(I, Seq, #{<<"code">> => <<"INTERNAL">>, <<"message">> => <<"falha interna do motor (veja o log)"/utf8>>}, null)
    end.

do_step(#{<<"instance_id">> := I, <<"seq">> := Seq, <<"attempts">> := Attempts, <<"force">> := Force,
          <<"requested_by">> := Requested}) ->
    {ok, Ctx} = ana_db:one(
        "SELECT i.doc_key, d.facts_sql, d.cancel_sql, d.run_as, s.name, s.program, s.params, s.done_sql, s.mode, "
        "  s.condition, s.max_attempts "
        "FROM flow.instance i JOIN flow.definition d ON d.code = i.flow_code "
        "JOIN flow.step s ON s.flow_code = i.flow_code AND s.seq = $2 WHERE i.id = $1", [I, Seq]),
    #{<<"doc_key">> := Key, <<"name">> := Name, <<"mode">> := Mode, <<"program">> := Program} = Ctx,
    Facts = facts(Ctx, I),
    case {Facts, check(maps:get(<<"cancel_sql">>, Ctx), Key), check(maps:get(<<"done_sql">>, Ctx), Key)} of
        {undefined, _, _} -> cancel(I, <<"documento não encontrado"/utf8>>);
        {_, true, _} -> cancel(I, <<"documento cancelado"/utf8>>);
        {_, _, true} -> done(I, Seq, <<"outside">>, null, null, null);
        _ when Mode =:= <<"wait">> ->
            wait(I, Seq, <<"aguardando: "/utf8, Name/binary>>);
        _ when not Force, Mode =:= <<"manual">> ->
            wait(I, Seq, <<"etapa manual: aguarda uma pessoa"/utf8>>);
        _ ->
            Cond = maps:get(<<"condition">>, Ctx),
            case Force orelse condition(Cond, Facts) of
                false -> wait(I, Seq, <<"condição da etapa automática não atendida: aguarda uma pessoa"/utf8>>);
                true ->
                    User = case Force of
                        true -> user(Requested);
                        false -> user(maps:get(<<"run_as">>, Ctx))
                    end,
                    Params = render(maps:get(<<"params">>, Ctx), Facts),
                    case ana_execution:run(Program, Params, User, #{origin => <<"internal">>}) of
                        {ok, #{id := Exec, result := Res}} ->
                            How = case Force of true -> <<"manual">>; false -> <<"auto">> end,
                            case check(maps:get(<<"done_sql">>, Ctx), Key) of
                                true -> done(I, Seq, How, maps:get(username, User), Exec, Res);
                                false ->
                                    %% e.g. a partial shipment: the program ran, the step is not over yet.
                                    {ok, _} = ana_db:exec("UPDATE flow.instance_step SET execution_id = $3::text::uuid, result = $4 "
                                                          "WHERE instance_id = $1 AND seq = $2", [I, Seq, Exec, small(Res)]),
                                    %% The program may say what the step is waiting for (e.g. the payment in the statement).
                                    wait(I, Seq, case Res of
                                                     #{<<"waiting">> := W} when is_binary(W), W =/= <<>> -> W;
                                                     _ -> <<"o programa rodou, mas a etapa ainda não terminou"/utf8>>
                                                 end)
                            end;
                        {error, E} ->
                            Code = code(E),
                            Exec = maps:get(<<"execution_id">>, E, null),
                            case lists:member(Code, ana_checks:technical_codes()) andalso Attempts < maps:get(<<"max_attempts">>, Ctx) of
                                true -> retry(I, Seq, Attempts, E, Exec);
                                false -> fail(I, Seq, E, Exec)
                            end
                    end
            end
    end.

facts(#{<<"facts_sql">> := Sql, <<"doc_key">> := Key}, I) ->
    case ana_db:rows(Sql, [Key]) of
        {ok, [Row | _]} ->
            F = Row#{<<"key">> => Key},
            {ok, _} = ana_db:exec("UPDATE flow.instance SET facts = $2 WHERE id = $1 AND facts IS DISTINCT FROM $2", [I, F]),
            F;
        {ok, []} -> undefined;
        {error, E} -> error({facts_sql, E})
    end.

check(null, _) -> false;
check(Sql, Key) ->
    case ana_db:rows(Sql, [Key]) of
        {ok, [Row | _]} -> lists:member(true, maps:values(Row));
        {ok, []} -> false;
        {error, E} -> error({check_sql, E})
    end.

user(Name) ->
    case ana_db:one("SELECT username, role FROM ana_system.app_user WHERE username = $1 AND active", [Name]) of
        {ok, #{<<"username">> := U, <<"role">> := R}} -> #{username => U, role => R};
        _ -> #{username => Name, role => <<"user">>}         % ana_execution refuses an inactive owner (NO_OWNER)
    end.

code(#{<<"code">> := C}) when is_binary(C) -> C;
code(#{code := C}) when is_binary(C) -> C;
code(_) -> <<"ERROR">>.

small(R) ->
    case byte_size(iolist_to_binary(json:encode(R))) of
        N when N =< 8000 -> R;
        _ -> #{<<"truncated">> => true}
    end.

%% ---------------------------------------------------------------- transitions

done(I, Seq, How, By, Exec, Res) ->
    {ok, _} = ana_db:transaction(fun(C) ->
        {ok, _} = ana_db:query(C, "UPDATE flow.instance_step SET status = 'done', how = $3, done_by = $4, "
                                  "  execution_id = COALESCE($5::text::uuid, execution_id), result = COALESCE($6, result), "
                                  "  error = NULL, lease_until = NULL, finished_at = now() WHERE instance_id = $1 AND seq = $2",
                               [I, Seq, How, By, Exec, case Res of null -> null; _ -> small(Res) end]),
        {ok, _} = ana_db:query(C, "SELECT flow.advance($1, $2)", [I, Seq]),
        {ok, done}
    end),
    ok.

%% From the sweep: only a step still waiting (or failed) is closed as done outside — never one that
%% the engine is running at this very moment (its own result wins).
done_waiting(I, Seq) ->
    {ok, _} = ana_db:transaction(fun(C) ->
        case ana_db:query(C, "UPDATE flow.instance_step SET status = 'done', how = 'outside', error = NULL, lease_until = NULL, "
                             "  finished_at = now() WHERE instance_id = $1 AND seq = $2 AND status IN ('waiting', 'failed')", [I, Seq]) of
            {ok, #{affected := 1}} -> {ok, _} = ana_db:query(C, "SELECT flow.advance($1, $2)", [I, Seq]), {ok, done};
            {ok, _} -> {ok, skipped}
        end
    end),
    ok.

%% Step and instance change together (nobody sees one without the other).
both(Sql1, P1, Sql2, P2) ->
    {ok, _} = ana_db:transaction(fun(C) ->
        {ok, _} = ana_db:query(C, Sql1, P1),
        {ok, _} = ana_db:query(C, Sql2, P2),
        {ok, done}
    end),
    ok.

wait(I, Seq, Reason) ->
    both("UPDATE flow.instance_step SET status = 'waiting', reason = $3, lease_until = NULL, force = false "
         "WHERE instance_id = $1 AND seq = $2", [I, Seq, Reason],
         "UPDATE flow.instance SET status = 'waiting', updated_at = now() WHERE id = $1 AND status = 'running'", [I]).

retry(I, Seq, Attempts, E, Exec) ->
    Delay = min(3600, 30 * (1 bsl min(Attempts - 1, 7))),
    {ok, _} = ana_db:exec("UPDATE flow.instance_step SET status = 'ready', next_at = now() + make_interval(secs => $3), "
                          "  error = $4, execution_id = $5::text::uuid, lease_until = NULL WHERE instance_id = $1 AND seq = $2",
                          [I, Seq, Delay, clean(E), Exec]),
    ok.

fail(I, Seq, E, Exec) ->
    both("UPDATE flow.instance_step SET status = 'failed', error = $3, execution_id = COALESCE($4::text::uuid, execution_id), "
         "  lease_until = NULL, force = false, finished_at = now() WHERE instance_id = $1 AND seq = $2", [I, Seq, clean(E), Exec],
         "UPDATE flow.instance SET status = 'failed', updated_at = now() WHERE id = $1", [I]).

cancel(I, Reason) ->
    both("UPDATE flow.instance_step SET status = 'cancelled', reason = $2, lease_until = NULL, finished_at = now() "
         "WHERE instance_id = $1 AND status IN ('pending', 'ready', 'running', 'waiting', 'failed')", [I, Reason],
         "UPDATE flow.instance SET status = 'cancelled', updated_at = now(), finished_at = now() WHERE id = $1", [I]).

clean(E) ->
    maps:with([<<"code">>, <<"message">>, <<"data">>, code, message], E).

%% ---------------------------------------------------------------- sweep

%% Waiting and failed steps: done by hand (or cancelled) meanwhile? Then the flow moves on.
sweep() ->
    {ok, Rows} = ana_db:rows(
        "SELECT x.instance_id, x.seq, i.doc_key, d.cancel_sql, s.done_sql FROM flow.instance_step x "
        "JOIN flow.instance i ON i.id = x.instance_id JOIN flow.definition d ON d.code = i.flow_code "
        "JOIN flow.step s ON s.flow_code = i.flow_code AND s.seq = x.seq "
        "WHERE x.status IN ('waiting', 'failed') ORDER BY x.instance_id LIMIT 2000", []),
    lists:foreach(fun(#{<<"instance_id">> := I, <<"seq">> := Seq, <<"doc_key">> := Key, <<"cancel_sql">> := Cancel,
                        <<"done_sql">> := Done}) ->
        try
            case check(Cancel, Key) of
                true -> cancel(I, <<"documento cancelado"/utf8>>);
                false ->
                    case check(Done, Key) of
                        true -> done_waiting(I, Seq);
                        false -> ok
                    end
            end
        catch C:R -> logger:warning("flow sweep ~p/~p: ~0p:~0p", [I, Seq, C, R])
        end
    end, Rows).

%% ---------------------------------------------------------------- pure helpers

%% Parameters from the step template: "{{field}}" alone keeps the fact's type (number, list…);
%% inside a text it is interpolated.
-spec render(term(), map()) -> term().
render(B, Facts) when is_binary(B) ->
    case re:run(B, <<"^\\{\\{([a-z_][a-z0-9_]*)\\}\\}$">>, [{capture, all_but_first, binary}]) of
        {match, [K]} -> maps:get(K, Facts, null);
        nomatch ->
            iolist_to_binary(re:replace(B, <<"\\{\\{([a-z_][a-z0-9_]*)\\}\\}">>,
                                        fun(_, [K]) -> text(maps:get(K, Facts, <<>>)) end, [global, {return, binary}]))
    end;
render(L, Facts) when is_list(L) -> [render(X, Facts) || X <- L];
render(M, Facts) when is_map(M) -> maps:map(fun(_, V) -> render(V, Facts) end, M);
render(X, _) -> X.

text(B) when is_binary(B) -> B;
text(I) when is_integer(I) -> integer_to_binary(I);
text(F) when is_float(F) -> float_to_binary(F, [short]);
text(null) -> <<>>;
text(X) -> iolist_to_binary(io_lib:format("~p", [X])).

%% RF-030-02: every rule must hold. Rule: {"field", "op": = != < <= > >= in, "value"}.
-spec condition(list(), map()) -> boolean().
condition(Rules, Facts) when is_list(Rules) ->
    lists:all(fun(R) -> rule(R, Facts) end, Rules);
condition(_, _) -> false.

rule(#{<<"field">> := F, <<"op">> := Op, <<"value">> := V}, Facts) ->
    A = maps:get(F, Facts, null),
    case Op of
        <<"in">> when is_list(V) -> lists:any(fun(X) -> same(A, X) end, V);
        <<"=">> -> same(A, V);
        <<"!=">> -> not same(A, V);
        _ ->
            case {num(A), num(V)} of
                {X, Y} when is_number(X), is_number(Y) ->
                    case Op of
                        <<"<">> -> X < Y; <<"<=">> -> X =< Y; <<">">> -> X > Y; <<">=">> -> X >= Y; _ -> false
                    end;
                _ -> false
            end
    end;
rule(_, _) -> false.

same(A, B) ->
    case {num(A), num(B)} of
        {X, Y} when is_number(X), is_number(Y) -> X == Y;
        _ -> text(A) =:= text(B)
    end.

num(N) when is_number(N) -> N;
num(B) when is_binary(B) ->
    try binary_to_integer(B) catch _:_ -> try binary_to_float(B) catch _:_ -> undefined end end;
num(_) -> undefined.
