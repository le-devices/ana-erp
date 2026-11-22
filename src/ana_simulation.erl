%% SPDX-FileCopyrightText: 2026 André Luis Pereira dos Santos
%% SPDX-License-Identifier: AGPL-3.0-or-later
%% Continuous usage simulation (spec 067, phase 1): personas running whole pipelines, every night, outside production.
%%
%% - Personas (D1) are robot users "sim_<name>" with a real role and groups: they meet the same permissions as people.
%% - The scenarios (D2) are decided by the program simulation.scenario, step by step, from the run's seed; each step runs
%%   here as its own execution of the persona — its own COMMIT, so the pipelines' automation runs as in real use.
%% - Oracles (D4): a step a person should have done that failed, a technical error where a business message was due, a
%%   human mistake accepted, a pipeline that did not go on by itself (probes), and at the end the accounts and queues
%%   (simulation.oracles). Each finding has a fingerprint: the same furo in the next run is "persistent", not new.
%% - Never in production (D5); one run at a time; the flows the run turns on are restored at the end.
-module(ana_simulation).

-export([start/2, runs/0, report/1, stop/1]).

-define(MAX_STEPS, 80).                 % per scenario
-define(MAX_LOG, 3000).                 % steps kept in the run's record
-define(PROBE_EVERY_MS, 2000).
-define(TECHNICAL, [<<"EXCEPTION">>, <<"INTERNAL">>, <<"SQL">>, <<"SQL_PARAMETER">>, <<"PROCESS_EXITED">>, <<"PROTOCOL">>,
                    <<"TIMEOUT">>, <<"CPU_LIMIT">>, <<"MEMORY">>, <<"INVALID_RESULT">>, <<"SYNTAX">>, <<"NO_MAIN">>]).
-define(MIX, [{<<"venda">>, 4}, {<<"compra">>, 2}, {<<"campo">>, 1}, {<<"producao">>, 1}, {<<"projeto">>, 1}, {<<"estoque">>, 1}]).
-define(FLOWS, [{<<"purchase">>, [{1, <<"auto">>}, {2, <<"auto">>}]}, {<<"field">>, [{3, <<"auto">>}]},
                {<<"production">>, [{1, <<"auto">>}, {2, <<"auto">>}, {4, <<"auto">>}]}]).

%% ------------------------------------------------------------------ start, stop, read

-spec start(map(), map()) -> {ok, map()} | {error, integer(), binary(), binary()}.
start(Opts, User = #{username := Who}) ->
    case ana_instance:role() of
        <<"production">> ->
            {error, 409, <<"NOT_IN_PRODUCTION">>, <<"o uso simulado roda na instância de testes ou de desenvolvimento, nunca na produção"/utf8>>};
        _ ->
            Seed = case maps:get(<<"seed">>, Opts, null) of S when is_integer(S), S >= 0 -> S; _ -> rand:uniform(1000000000) end,
            Days = bounded(maps:get(<<"days">>, Opts, 1), 1, 60),
            PerDay = bounded(maps:get(<<"per_day">>, Opts, 6), 1, 200),
            Flows = maps:get(<<"flows">>, Opts, false) =:= true,
            case ana_db:rows("INSERT INTO ana_system.sim_run (seed, days, per_day, options, started_by) "
                             "VALUES ($1, $2, $3, $4::text::jsonb, $5) RETURNING id",
                             [Seed, Days, PerDay, iolist_to_binary(json:encode(#{flows => Flows})), Who]) of
                {ok, [#{<<"id">> := Id}]} ->
                    _ = proc_lib:spawn(fun() -> guarded(Id, #{seed => Seed, days => Days, per_day => PerDay, flows => Flows}, User) end),
                    {ok, #{id => Id, seed => Seed, days => Days, per_day => PerDay, flows => Flows}};
                {error, #{sqlstate := <<"23505">>}} ->
                    {error, 409, <<"SIMULATION_RUNNING">>, <<"já há uma simulação em andamento"/utf8>>};
                _ -> {error, 503, <<"DB_UNAVAILABLE">>, <<"banco de dados indisponível"/utf8>>}
            end
    end.

bounded(N, Lo, Hi) when is_integer(N) -> max(Lo, min(Hi, N));
bounded(_, Lo, _) -> Lo.

-spec stop(integer()) -> {ok, map()} | {error, integer(), binary(), binary()}.
stop(Id) ->
    case ana_db:exec("UPDATE ana_system.sim_run SET status = 'stopped', finished_at = now(), reason = 'parada a pedido' "
                     "WHERE id = $1 AND status = 'running'", [Id]) of
        {ok, 1} -> {ok, #{stopped => Id}};
        _ -> {error, 409, <<"NOT_RUNNING">>, <<"esta simulação não está em andamento"/utf8>>}
    end.

-spec runs() -> {ok, map()}.
runs() ->
    {ok, Runs} = ana_db:rows("SELECT r.id, r.seed, r.days, r.per_day, r.options, r.status, r.started_by, r.started_at, r.finished_at, "
                             "r.stats, r.reason, (SELECT count(*) FROM ana_system.sim_finding f WHERE f.run_id = r.id)::int AS findings, "
                             "(SELECT count(*) FROM ana_system.sim_finding f WHERE f.run_id = r.id AND f.trend = 'new')::int AS new "
                             "FROM ana_system.sim_run r ORDER BY r.id DESC LIMIT 30", []),
    {ok, Personas} = ana_db:rows("SELECT name, label, role, groups, error_rate, active FROM ana_system.sim_persona ORDER BY name", []),
    {ok, #{runs => Runs, personas => Personas}}.

-spec report(integer()) -> {ok, map()} | {error, integer(), binary(), binary()}.
report(Id) ->
    case ana_db:one("SELECT id, seed, days, per_day, options, status, started_by, started_at, finished_at, stats, steps, reason "
                    "FROM ana_system.sim_run WHERE id = $1", [Id]) of
        {ok, #{} = R} ->
            {ok, F} = ana_db:rows("SELECT fingerprint, category, severity, title, detail, scenario, persona, seed, steps, trend "
                                  "FROM ana_system.sim_finding WHERE run_id = $1 ORDER BY category, severity DESC, id", [Id]),
            Prev = previous(Id),
            {ok, Gone} = ana_db:rows("SELECT fingerprint, category, title FROM ana_system.sim_finding WHERE run_id = $1 "
                                     "AND fingerprint <> ALL($2::text[])", [Prev, [maps:get(<<"fingerprint">>, X) || X <- F]]),
            {ok, R#{<<"findings">> => F, <<"resolved">> => Gone}};
        _ -> {error, 404, <<"RUN_NOT_FOUND">>, <<"simulação não encontrada"/utf8>>}
    end.

previous(Id) ->
    case ana_db:one("SELECT max(id) AS p FROM ana_system.sim_run WHERE id < $1 AND status = 'done'", [Id]) of
        {ok, #{<<"p">> := P}} when is_integer(P) -> P;
        _ -> 0
    end.

%% ------------------------------------------------------------------ the run

guarded(Id, Opts, User) ->
    try run(Id, Opts, User)
    catch Class:Reason:Stack ->
        logger:error("simulation ~b failed: ~0p:~0p ~0p", [Id, Class, Reason, Stack]),
        _ = ana_db:exec("UPDATE ana_system.sim_run SET status = 'failed', finished_at = now(), reason = $2 "
                        "WHERE id = $1 AND status = 'running'",
                        [Id, unicode:characters_to_binary(io_lib:format("~0p", [Reason]))])
    end.

run(Id, Opts = #{seed := Seed, days := Days, per_day := PerDay, flows := Flows}, User) ->
    Personas = personas(),
    Started = iso_now(),
    Base = #{run => Id, seed => Seed, tag => tag(Id), user => User, personas => Personas, flows_on => Flows,
             log => [], findings => #{}},
    Recon = case call(<<"finance.reconciliations">>, #{}, User, false) of
        {ok, #{<<"items">> := Items}} -> Items;
        _ -> #{}
    end,
    LastEntry = case ana_db:one("SELECT COALESCE(max(id), 0) AS m FROM finance.journal_entry", []) of
        {ok, #{<<"m">> := M}} -> M;
        _ -> 0
    end,
    Saved = case Flows of true -> flows_on(User); false -> [] end,
    try
        {SetupCtx, St1} = scenario(<<"setup">>, 0, #{}, Base),
        St2 = case maps:size(maps:get(findings, St1)) of
            0 -> days(1, Days, PerDay, SetupCtx, St1, Opts);
            _ -> St1                                                % the setup failed: no scenario can run
        end,
        St3 = oracles(Started, Recon, LastEntry, St2),
        finish(Id, St3)
    after
        flows_restore(Saved, User)
    end.

tag(Id) -> integer_to_binary(Id rem 100000).

days(D, Days, _, _, St, _) when D > Days -> St;
days(D, Days, PerDay, Setup, St, Opts = #{seed := Seed}) ->
    St2 = lists:foldl(fun(K, Acc) ->
                          case running(maps:get(run, Acc)) of
                              false -> Acc;
                              true ->
                                  {Name, _} = pick(Seed, D, K),
                                  {_, Acc2} = scenario(Name, D * 1000 + K, Setup, Acc),
                                  Acc2
                          end
                      end, St, lists:seq(1, PerDay)),
    days(D + 1, Days, PerDay, Setup, St2, Opts).

%% D2: which scenario, drawn from the seed — the same seed draws the same day.
pick(Seed, D, K) ->
    Total = lists:sum([W || {_, W} <- ?MIX]),
    {N, _} = rand:uniform_s(Total, rand:seed_s(exsss, {Seed, D, K})),
    walk(N, ?MIX).

walk(N, [{Name, W} | _]) when N =< W -> {Name, W};
walk(N, [{_, W} | Rest]) -> walk(N - W, Rest).

running(Id) ->
    case ana_db:one("SELECT status FROM ana_system.sim_run WHERE id = $1", [Id]) of
        {ok, #{<<"status">> := <<"running">>}} -> true;
        _ -> false
    end.

%% ------------------------------------------------------------------ one scenario, step by step

scenario(Name, Instance, Setup, St = #{seed := Seed, tag := Tag, personas := Personas, flows_on := Flows}) ->
    State = #{<<"scenario">> => Name, <<"seed">> => Seed, <<"instance">> => Instance, <<"tag">> => Tag,
              <<"setup">> => Setup, <<"ctx">> => #{}, <<"step">> => 0, <<"mistakes">> => [], <<"flows_on">> => Flows,
              <<"personas">> => maps:map(fun(_, #{username := U, error_rate := E}) -> #{<<"username">> => U, <<"error_rate">> => E} end,
                                         Personas)},
    steps(0, State, St).

steps(N, #{<<"ctx">> := Ctx}, St) when N >= ?MAX_STEPS -> {Ctx, St};
steps(N, State = #{<<"ctx">> := Ctx, <<"scenario">> := Name}, St = #{user := Coord}) ->
    case call(<<"simulation.scenario">>, #{<<"state">> => State}, Coord, true) of
        {ok, #{<<"action">> := <<"done">>}} -> {Ctx, St};
        {ok, #{<<"action">> := <<"run">>} = A} -> act(A, N, State, St);
        {ok, #{<<"action">> := <<"probe">>} = A} -> wait(A, N, State, St);
        {ok, Other} -> {Ctx, add(robustness, <<"warning">>, <<"scenario:", Name/binary>>, <<"Cenário respondeu algo inesperado"/utf8>>,
                                 #{answer => Other}, Name, null, St)};
        {error, E} -> {Ctx, add(robustness, <<"serious">>, <<"scenario:", Name/binary, ":", (code(E))/binary>>,
                                iolist_to_binary([<<"O cenário "/utf8>>, Name, <<" não conseguiu decidir o próximo passo: "/utf8>>, message(E)]),
                                #{error => E}, Name, null, St)}
    end.

act(A = #{<<"persona">> := P, <<"program">> := Prog, <<"step">> := I}, N, State = #{<<"ctx">> := Ctx, <<"scenario">> := Name}, St0) ->
    Params = case maps:get(<<"params">>, A, #{}) of M when is_map(M) -> M; _ -> #{} end,
    Mistake = maps:get(<<"mistake">>, A, false) =:= true,
    MayFail = maps:get(<<"may_fail">>, A, false) =:= true,
    User = persona_user(P, St0),
    Res = ana_execution:run(Prog, Params, User, #{origin => <<"internal">>}),
    {Ok, Code, Msg, Exec, Result} = case Res of
        {ok, #{id := X} = R} -> {true, null, null, X, maps:get(result, R, null)};
        {error, E} -> {false, code(E), message(E), maps:get(<<"execution_id">>, E, null), null}
    end,
    Entry = #{scenario => Name, instance => maps:get(<<"instance">>, State), step => I, persona => P, program => Prog, params => cut(Params), ok => Ok, code => Code,
              message => Msg, execution => Exec, mistake => Mistake},
    St = log(Entry, St0),
    Next = State#{<<"step">> => case Mistake of true -> I; false -> I + 1 end,
                  <<"mistakes">> => case Mistake of true -> [I | maps:get(<<"mistakes">>, State)]; false -> maps:get(<<"mistakes">>, State) end,
                  <<"ctx">> => case maps:get(<<"save">>, A, null) of
                      K when is_binary(K), Ok -> Ctx#{K => Result};
                      _ -> Ctx
                  end},
    Steps = scenario_log(Name, St),
    case {Ok, Mistake, MayFail, lists:member(Code, ?TECHNICAL)} of
        {true, true, _, _} ->
            %% A person's mistake (negative quantity, an order without items) was accepted: validation is missing.
            steps(N + 1, Next, add(robustness, <<"serious">>, <<"accepted:", Prog/binary>>,
                                   <<Prog/binary, " aceitou um erro humano: "/utf8, (mistake_text(Params))/binary>>,
                                   #{params => cut(Params), execution => Exec}, Name, P, St, Steps));
        {false, true, _, true} ->
            steps(N + 1, Next, add(robustness, <<"serious">>, <<"technical_on_mistake:", Prog/binary, ":", Code/binary>>,
                                   <<Prog/binary, " respondeu a um erro humano com erro técnico ("/utf8, Code/binary, "), sem dizer o que fazer"/utf8>>,
                                   #{params => cut(Params), message => Msg, execution => Exec}, Name, P, St, Steps));
        {false, true, _, false} -> steps(N + 1, Next, St);       % refused with a business message: as it should
        {true, false, _, _} -> steps(N + 1, Next, St);
        {false, false, true, _} -> steps(N + 1, Next, St);
        {false, false, false, Technical} ->
            %% The step a person does in this pipeline failed: the scenario cannot go on.
            {Category, Severity, Title} = case {Technical, Code} of
                {true, _} -> {robustness, <<"critical">>, <<"Erro técnico em "/utf8, Prog/binary, ": "/utf8, Code/binary>>};
                {_, <<"FORBIDDEN">>} -> {access, <<"warning">>, iolist_to_binary([<<"A persona "/utf8>>, P, <<" não tem acesso a "/utf8>>, Prog])};
                _ -> {robustness, <<"serious">>, <<"Passo da esteira "/utf8, Name/binary, " recusado: "/utf8, Prog/binary, " (", Code/binary, ")">>}
            end,
            {Ctx, add(Category, Severity, <<"step:", Name/binary, ":", Prog/binary, ":", Code/binary>>, Title,
                      #{params => cut(Params), message => Msg, execution => Exec}, Name, P, St, Steps)}
    end.

wait(A = #{<<"probe">> := Probe, <<"step">> := I}, N, State = #{<<"scenario">> := Name}, St0 = #{user := Coord}) ->
    Timeout = bounded(maps:get(<<"timeout_s">>, A, 90), 5, 900) * 1000,
    Until = erlang:monotonic_time(millisecond) + Timeout,
    Last = poll(Probe, Coord, Until),
    Ok = maps:get(<<"ok">>, Last, false) =:= true,
    St = log(#{scenario => Name, instance => maps:get(<<"instance">>, State), step => I, persona => <<"esteira">>, program => <<"simulation.probe">>, params => Probe,
               ok => Ok, code => case Ok of true -> null; false -> <<"PIPELINE_STOPPED">> end, message => maps:get(<<"title">>, A, null)},
             St0),
    Next = State#{<<"step">> => I + 1},
    case Ok of
        true -> steps(N + 1, Next, St);
        false ->
            Flow = maps:get(<<"flow">>, Probe, <<"?">>),
            Stage = maps:get(<<"code">>, Probe, <<"?">>),
            steps(N + 1, Next, add(automation, <<"serious">>, <<"stopped:", Flow/binary, ":", Stage/binary>>,
                                   <<"Esteira parada: "/utf8, (maps:get(<<"title">>, A, <<>>))/binary>>,
                                   #{probe => Probe, seen => maps:get(<<"steps">>, Last, #{})}, Name, null, St, scenario_log(Name, St)))
    end.

poll(Probe, Coord, Until) ->
    Last = case call(<<"simulation.probe">>, #{<<"probe">> => Probe}, Coord, true) of
        {ok, #{} = R} -> R;
        _ -> #{}
    end,
    case maps:get(<<"ok">>, Last, false) =:= true orelse erlang:monotonic_time(millisecond) >= Until of
        true -> Last;
        false -> timer:sleep(?PROBE_EVERY_MS), poll(Probe, Coord, Until)
    end.

%% ------------------------------------------------------------------ oracles, findings, end

oracles(Since, Recon, LastEntry, St0 = #{user := Coord}) ->
    St = queues(Since, St0),
    case call(<<"simulation.oracles">>, #{<<"since">> => Since, <<"reconciliations">> => Recon, <<"last_entry">> => LastEntry},
              Coord, true) of
        {ok, #{<<"findings">> := Fs}} ->
            lists:foldl(fun(#{<<"category">> := C, <<"severity">> := S, <<"key">> := K, <<"title">> := T} = F, Acc) ->
                            add(category(C), S, K, T, maps:get(<<"detail">>, F, #{}), null, null, Acc)
                        end, St, Fs);
        {error, E} -> add(robustness, <<"serious">>, <<"oracles">>, <<"Os oráculos da simulação falharam: "/utf8, (message(E))/binary>>,
                          #{error => E}, null, null, St)
    end.

%% Automation the programs cannot see: messages to connectors given up, scheduled routines in error, since the start.
queues(Since, St) ->
    {ok, Dead} = ana_db:rows("SELECT connector, kind, count(*)::int AS n, max(last_error) AS error FROM integration.outbox "
                             "WHERE status = 'dead' AND created_at >= $1::timestamptz GROUP BY connector, kind", [Since]),
    {ok, Jobs} = ana_db:rows("SELECT j.name, count(*)::int AS n, max(o.error->>'message') AS error FROM scheduler.occurrence o "
                             "JOIN scheduler.job j ON j.id = o.job_id WHERE o.status = 'error' AND o.scheduled_at >= $1::timestamptz "
                             "GROUP BY j.name", [Since]),
    St1 = lists:foldl(fun(#{<<"connector">> := C, <<"kind">> := K, <<"n">> := N, <<"error">> := E}, Acc) ->
                          add(automation, <<"serious">>, <<"outbox:", C/binary, ":", K/binary>>,
                              iolist_to_binary([integer_to_binary(N), <<" mensagem(ns) ao conector "/utf8>>, C, <<" esgotaram as tentativas"/utf8>>]),
                              #{error => E}, null, null, Acc)
                      end, St, Dead),
    lists:foldl(fun(#{<<"name">> := J, <<"n">> := N, <<"error">> := E}, Acc) ->
                    add(automation, <<"warning">>, <<"job:", J/binary>>,
                        iolist_to_binary([<<"Rotina agendada "/utf8>>, J, <<" falhou "/utf8>>, integer_to_binary(N), <<" vez(es)"/utf8>>]),
                        #{error => E}, null, null, Acc)
                end, St1, Jobs).

add(Category, Severity, Key, Title, Detail, Scenario, Persona, St) ->
    add(Category, Severity, Key, Title, Detail, Scenario, Persona, St, []).
add(Category, Severity, Key, Title, Detail, Scenario, Persona, St = #{findings := Fs, seed := Seed}, Steps) ->
    Fp = binary:part(binary:encode_hex(crypto:hash(sha256, [atom_to_binary(Category), "|", Key]), lowercase), 0, 16),
    case maps:is_key(Fp, Fs) of
        true -> St;                                                 % the first occurrence of the run is enough
        false ->
            St#{findings => Fs#{Fp => #{category => Category, severity => Severity,
                                        title => unicode:characters_to_binary(string:slice(Title, 0, 300)),
                                        detail => Detail, scenario => Scenario, persona => Persona, seed => Seed,
                                        steps => lists:sublist(Steps, 40)}}}
    end.

finish(Id, St = #{findings := Fs, log := Log}) ->
    Prev = previous(Id),
    {ok, Old} = ana_db:rows("SELECT fingerprint FROM ana_system.sim_finding WHERE run_id = $1", [Prev]),
    Known = [F || #{<<"fingerprint">> := F} <- Old],
    New = [Fp || Fp <- maps:keys(Fs), not lists:member(Fp, Known)],
    _ = [ana_db:exec("INSERT INTO ana_system.sim_finding (run_id, fingerprint, category, severity, title, detail, scenario, persona, "
                     "seed, steps, trend) VALUES ($1, $2, $3, $4, $5, $6::text::jsonb, $7, $8, $9, $10::text::jsonb, $11)",
                     [Id, Fp, atom_to_binary(C), S, T, iolist_to_binary(json:encode(D)), Sc, P, Seed,
                      iolist_to_binary(json:encode(Steps)), case lists:member(Fp, New) of true -> <<"new">>; false -> <<"persistent">> end])
         || {Fp, #{category := C, severity := S, title := T, detail := D, scenario := Sc, persona := P, seed := Seed, steps := Steps}}
                <- maps:to_list(Fs)],
    Entries = lists:reverse(Log),
    Stats = #{steps => length(Entries), failed => length([x || #{ok := false} <- Entries]),
              mistakes => length([x || #{mistake := true} <- Entries]),
              scenarios => length(lists:usort([{S, I} || #{scenario := S, instance := I} <- Entries])) - 1,   % minus the setup
              findings => maps:size(Fs), new => length(New), resolved => length(Known -- maps:keys(Fs))},
    _ = ana_db:exec("UPDATE ana_system.sim_run SET status = CASE WHEN status = 'running' THEN 'done' ELSE status END, "
                    "finished_at = COALESCE(finished_at, now()), stats = $2::text::jsonb, steps = $3::text::jsonb WHERE id = $1",
                    [Id, iolist_to_binary(json:encode(Stats)), iolist_to_binary(json:encode(lists:sublist(Entries, ?MAX_LOG)))]),
    %% D6: a new finding is told to whoever looks after the instance.
    case New of
        [] -> ok;
        _ -> _ = ana_db:exec("INSERT INTO ana_system.notice (kind, severity, message, link) VALUES ('simulation', 'warning', $1, $2)",
                             [iolist_to_binary([<<"Uso simulado: "/utf8>>, integer_to_binary(length(New)),
                                                <<" achado(s) novo(s) na simulação "/utf8>>, integer_to_binary(Id)]),
                              <<"#/admin/simulation">>]),
             ok
    end,
    St.

log(Entry, St = #{log := L}) -> St#{log => [Entry | L]}.

category(<<"automation">>) -> automation;
category(<<"accounts">>) -> accounts;
category(<<"usability">>) -> usability;
category(<<"performance">>) -> performance;
category(<<"access">>) -> access;
category(_) -> robustness.

scenario_log(Name, #{log := L}) ->
    %% The steps of this scenario so far (the most recent instance): what reproduces the finding with the seed.
    lists:reverse(lists:takewhile(fun(#{scenario := S}) -> S =:= Name end, L)).

%% ------------------------------------------------------------------ personas, flows, helpers

personas() ->
    {ok, Rows} = ana_db:rows("SELECT name, label, role, groups, error_rate::float AS error_rate FROM ana_system.sim_persona "
                             "WHERE active ORDER BY name", []),
    _ = ana_db:exec("INSERT INTO ana_system.access_group (name, description) VALUES ('sim_aprovadores', $1) ON CONFLICT DO NOTHING",
                    [<<"Uso simulado: aprovadores de compra (spec 067)"/utf8>>]),
    maps:from_list([{N, ensure(R)} || R = #{<<"name">> := N} <- Rows]).

ensure(#{<<"name">> := N, <<"label">> := Label, <<"role">> := Role, <<"groups">> := Groups, <<"error_rate">> := E}) ->
    U = <<"sim_", N/binary>>,
    All = case N of <<"aprovador">> -> lists:usort([<<"sim_aprovadores">> | Groups]); _ -> Groups end,
    _ = ana_db:exec("INSERT INTO ana_system.app_user (username, name, password_hash, role, kind, must_change_password) "
                    "VALUES ($1, $2, $3, $4, 'robot', false) ON CONFLICT (username) DO UPDATE SET role = EXCLUDED.role, active = true",
                    [U, <<"Simulação — "/utf8, Label/binary>>, <<"robot$", (base64:encode(crypto:strong_rand_bytes(24)))/binary>>, Role]),
    _ = [ana_db:exec("INSERT INTO ana_system.user_group (username, group_name) VALUES ($1, $2) ON CONFLICT DO NOTHING", [U, G])
         || G <- All],
    _ = (catch ana_access:invalidate()),
    #{username => U, role => Role, error_rate => E}.

persona_user(<<"admin">>, #{user := User}) -> User;
persona_user(P, #{personas := Ps, user := User}) ->
    case maps:get(P, Ps, undefined) of
        #{username := U, role := R} -> #{username => U, role => R, name => U, kind => <<"robot">>};
        undefined -> User
    end.

%% The run may turn on the automatic steps of the pipelines (as the business-process trails do) and restores them after.
flows_on(User) ->
    lists:foldl(fun({Flow, Modes}, Acc) ->
                    case call(<<"flows.configure">>, #{<<"flow">> => Flow}, User, false) of
                        {ok, #{} = Saved} ->
                            _ = call(<<"flows.configure">>, #{<<"flow">> => Flow, <<"action">> => <<"activate">>}, User, false),
                            _ = [call(<<"flows.configure">>, #{<<"flow">> => Flow, <<"action">> => <<"mode">>, <<"step">> => S,
                                                               <<"mode">> => M}, User, false) || {S, M} <- Modes],
                            [{Flow, Saved} | Acc];
                        _ -> Acc
                    end
                end, [], ?FLOWS).

flows_restore(Saved, User) ->
    _ = [begin
             Active = maps:get(<<"active">>, S, false) =:= true,
             _ = call(<<"flows.configure">>, #{<<"flow">> => F, <<"action">> => case Active of true -> <<"activate">>; false -> <<"deactivate">> end},
                      User, false),
             [call(<<"flows.configure">>, #{<<"flow">> => F, <<"action">> => <<"mode">>, <<"step">> => maps:get(<<"seq">>, St),
                                            <<"mode">> => maps:get(<<"mode">>, St)}, User, false)
              || St <- maps:get(<<"steps">>, S, []), maps:get(<<"mode">>, St, <<"wait">>) =/= <<"wait">>]
         end || {F, S} <- Saved],
    ok.

call(Prog, Params, User, ReadOnly) ->
    case ana_execution:run(Prog, Params, User, #{origin => <<"internal">>, read_only => ReadOnly}) of
        {ok, #{result := R}} -> {ok, R};
        {error, E} -> {error, E}
    end.

code(#{<<"code">> := C}) when is_binary(C) -> C;
code(_) -> <<"FAILED">>.

message(#{<<"message">> := M}) when is_binary(M) -> M;
message(_) -> <<"falhou"/utf8>>.

mistake_text(#{<<"quantity">> := Q}) -> <<"quantidade "/utf8, (iolist_to_binary(json:encode(Q)))/binary>>;
mistake_text(#{<<"items">> := []}) -> <<"pedido sem itens"/utf8>>;
mistake_text(_) -> <<"dado inválido"/utf8>>.

cut(Params) ->
    J = iolist_to_binary(json:encode(Params)),
    case byte_size(J) > 2000 of true -> #{truncated => binary:part(J, 0, 2000)}; false -> Params end.

iso_now() ->
    list_to_binary(calendar:system_time_to_rfc3339(erlang:system_time(second), [{offset, "Z"}])).
