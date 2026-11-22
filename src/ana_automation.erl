%% SPDX-FileCopyrightText: 2026 André Luis Pereira dos Santos
%% SPDX-License-Identifier: AGPL-3.0-or-later
%% Central of automations (spec 051, D1, RF-051-01, CA-051-04): everything that runs by itself, in one list —
%% schedules, esteiras, processes, rules, alert rules and connectors — with its owner, last result, next run and
%% failures with the reason; turned on and off through the same path (and the same checks) as its own screen.
-module(ana_automation).
-export([central/0, set_active/4]).

-spec central() -> {ok, map()}.
central() ->
    Items = lists:append([schedules(), flows(), bpm_processes(), rules(), alerts(), connectors()]),
    Count = fun(P) -> length([I || I <- Items, P(I)]) end,
    {ok, #{<<"items">> => Items,
           <<"summary">> => #{<<"total">> => length(Items),
                              <<"active">> => Count(fun(#{<<"active">> := A}) -> A =:= true end),
                              <<"failing">> => Count(fun(#{<<"failures">> := F}) -> F > 0 end)}}}.

rows(Sql) ->
    case ana_db:rows(Sql, []) of
        {ok, R} -> R;
        {error, E} -> logger:warning("automation central: ~0p", [E]), []
    end.

item(Kind, Label, R, Link) ->
    maps:merge(#{<<"kind">> => Kind, <<"kind_label">> => Label, <<"link">> => Link,
                 <<"last_at">> => null, <<"last_status">> => null, <<"next_at">> => null, <<"failures">> => 0,
                 <<"last_error">> => null, <<"rehearse">> => false, <<"toggle">> => true}, R).

%% Schedules (spec 018), including the product's own routines (owner "system").
schedules() ->
    [item(<<"schedule">>, case O of <<"system">> -> <<"Rotina do produto"/utf8>>; _ -> <<"Agendamento"/utf8>> end,
          R#{<<"rehearse">> => true}, <<"#/admin/scheduler/", (integer_to_binary(Id))/binary>>)
     || R = #{<<"id">> := Id, <<"owner">> := O} <- rows(
        "SELECT j.id, j.name, j.description, j.program, j.owner, j.active, "
        "  (SELECT min(t.next_at) FROM scheduler.trigger t WHERE t.job_id = j.id) AS next_at, "
        "  l.finished_at AS last_at, l.status AS last_status, l.error ->> 'message' AS last_error, "
        "  (SELECT count(*) FROM scheduler.occurrence o WHERE o.job_id = j.id AND o.status = 'error' "
        "     AND o.scheduled_at > now() - interval '7 days')::int AS failures "
        "FROM scheduler.job j LEFT JOIN LATERAL (SELECT o.finished_at, o.status, o.error FROM scheduler.occurrence o "
        "  WHERE o.job_id = j.id AND o.status IN ('success', 'error') ORDER BY o.id DESC LIMIT 1) l ON true "
        "ORDER BY j.name")].

%% Esteiras (spec 030): the automatic steps that failed and are still failed.
flows() ->
    [item(<<"flow">>, <<"Esteira"/utf8>>, R#{<<"id">> => C, <<"owner">> => maps:get(<<"run_as">>, R)},
          <<"#/admin/flows/", C/binary>>)
     || R = #{<<"code">> := C} <- rows(
        "SELECT f.code, f.name, f.description, f.active, f.run_as, "
        "  (SELECT max(x.finished_at) FROM flow.instance_step x JOIN flow.instance i ON i.id = x.instance_id "
        "     WHERE i.flow_code = f.code AND x.how = 'auto') AS last_at, "
        "  (SELECT count(*) FROM flow.instance_step x JOIN flow.instance i ON i.id = x.instance_id "
        "     WHERE i.flow_code = f.code AND x.status = 'failed')::int AS failures, "
        "  (SELECT x.error ->> 'message' FROM flow.instance_step x JOIN flow.instance i ON i.id = x.instance_id "
        "     WHERE i.flow_code = f.code AND x.status = 'failed' ORDER BY x.instance_id DESC LIMIT 1) AS last_error "
        "FROM flow.definition f ORDER BY f.name")].

%% Processes (spec 039) with a published version — the esteiras' own entries and the ERP tasks are shown elsewhere.
bpm_processes() ->
    [item(<<"process">>, <<"Processo"/utf8>>, R#{<<"id">> => C}, <<"#/bpm/process/", C/binary>>)
     || R = #{<<"code">> := C} <- rows(
        "SELECT p.code, p.name, p.objective AS description, p.owner, p.active, "
        "  (SELECT max(c.started_at) FROM bpm.case c WHERE c.process_code = p.code) AS last_at, "
        "  (SELECT count(*) FROM bpm.case c WHERE c.process_code = p.code AND c.status = 'failed')::int AS failures "
        "FROM bpm.process p WHERE p.flow_code IS NULL AND p.code <> 'erp.tarefa' "
        "  AND EXISTS (SELECT 1 FROM bpm.version v WHERE v.process_code = p.code AND v.status = 'published') "
        "ORDER BY p.name")].

%% Rules "when… then…" (D2).
rules() ->
    [item(<<"rule">>, <<"Regra"/utf8>>,
          R#{<<"rehearse">> => true, <<"last_status">> => case L of #{<<"outcome">> := O} -> O; _ -> null end,
             <<"last_at">> => case L of #{<<"at">> := At} -> At; _ -> null end,
             <<"last_error">> => case {maps:get(<<"blocked_reason">>, R), L} of
                                     {B, _} when is_binary(B) -> B;
                                     {_, #{<<"detail">> := #{<<"error">> := #{<<"message">> := M}}}} -> M;
                                     _ -> null
                                 end,
             <<"failures">> => maps:get(<<"failed">>, R) + case maps:get(<<"blocked_reason">>, R) of null -> 0; _ -> 1 end},
          <<"#/admin/automations/rules/", (integer_to_binary(Id))/binary>>)
     || R = #{<<"id">> := Id, <<"last">> := L} <- [maps:with([<<"id">>, <<"name">>, <<"description">>, <<"owner">>,
                                                               <<"active">>, <<"last">>, <<"failed">>, <<"blocked_reason">>,
                                                               <<"trigger_kind">>, <<"entity_label">>], X)
                                                    || X <- ana_rules:list()]].

%% Alert rules (spec 019).
alerts() ->
    [item(<<"alert">>, <<"Alerta"/utf8>>, R, <<"#/admin/observability">>)
     || R <- rows("SELECT r.id, r.name, r.source || ': ' || r.target AS description, r.updated_by AS owner, r.active, "
                  "  (SELECT max(i.opened_at) FROM ana_system.incident i WHERE i.rule_id = r.id) AS last_at, "
                  "  (SELECT count(*) FROM ana_system.incident i WHERE i.rule_id = r.id AND i.closed_at IS NULL)::int AS failures "
                  "FROM ana_system.alert_rule r ORDER BY r.name")].

%% Connectors (spec 017): messages that ran out of attempts are failures somebody must see.
connectors() ->
    [item(<<"connector">>, <<"Conector"/utf8>>, R#{<<"id">> => N, <<"toggle">> => false}, <<"#/admin/connectors">>)
     || R = #{<<"name">> := N} <- rows(
        "SELECT c.name, c.description, c.run_as AS owner, c.active, "
        "  (SELECT max(o.done_at) FROM integration.outbox o WHERE o.connector = c.name) AS last_at, "
        "  (SELECT count(*) FROM integration.outbox o WHERE o.connector = c.name AND o.status = 'dead')::int AS failures, "
        "  (SELECT o.last_error FROM integration.outbox o WHERE o.connector = c.name AND o.status = 'dead' "
        "     ORDER BY o.id DESC LIMIT 1) AS last_error "
        "FROM integration.connector c ORDER BY c.name")].

%% On and off through each one's own path: the scheduler's, the esteira's routine (as the person), the rule's
%% (rehearsed first), the process's and the alert's.
-spec set_active(binary(), binary(), boolean(), map()) -> {ok, map()} | {error, integer(), binary(), binary()}.
set_active(<<"schedule">>, Id, On, U) ->
    case catch binary_to_integer(Id) of
        N when is_integer(N) ->
            case ana_schedule:set_active(N, On, U) of
                {ok, _} -> {ok, #{<<"active">> => On}};
                {error, not_found} -> {error, 404, <<"NOT_FOUND">>, <<"agendamento não encontrado"/utf8>>}
            end;
        _ -> {error, 400, <<"INVALID_PARAMETER">>, <<"agendamento inválido"/utf8>>}
    end;
set_active(<<"flow">>, Code, On, U) ->
    Action = case On of true -> <<"activate">>; false -> <<"deactivate">> end,
    case ana_execution:run(<<"flows.configure">>, #{<<"flow">> => Code, <<"action">> => Action}, U, #{origin => <<"api">>}) of
        {ok, _} -> {ok, #{<<"active">> => On}};
        {error, #{<<"code">> := C, <<"message">> := M}} -> {error, 400, C, M}
    end;
set_active(<<"rule">>, Id, On, #{username := Who}) ->
    case catch binary_to_integer(Id) of
        N when is_integer(N) ->
            case ana_rules:activate(N, On, Who) of
                ok -> {ok, #{<<"active">> => On}};
                {error, <<"NOT_FOUND">> = C, M} -> {error, 404, C, M};
                {error, C, M} -> {error, 409, C, M}
            end;
        _ -> {error, 400, <<"INVALID_PARAMETER">>, <<"regra inválida"/utf8>>}
    end;
set_active(<<"process">>, Code, On, #{username := Who}) ->
    one(ana_db:exec("UPDATE bpm.process SET active = $2, updated_by = $3, updated_at = now() WHERE code = $1 "
                    "AND flow_code IS NULL AND code <> 'erp.tarefa'", [Code, On, Who]), On, <<"processo"/utf8>>);
set_active(<<"alert">>, Id, On, #{username := Who}) ->
    case catch binary_to_integer(Id) of
        N when is_integer(N) ->
            one(ana_db:exec("UPDATE ana_system.alert_rule SET active = $2, updated_by = $3, updated_at = now() WHERE id = $1",
                            [N, On, Who]), On, <<"regra de alerta"/utf8>>);
        _ -> {error, 400, <<"INVALID_PARAMETER">>, <<"regra de alerta inválida"/utf8>>}
    end;
set_active(<<"connector">>, _, _, _) ->
    {error, 409, <<"USE_SCREEN">>, <<"o conector liga e desliga na tela de Conectores, que confere as credenciais"/utf8>>};
set_active(_, _, _, _) ->
    {error, 400, <<"INVALID_PARAMETER">>, <<"tipo de automação desconhecido"/utf8>>}.

one({ok, 1}, On, _) -> {ok, #{<<"active">> => On}};
one({ok, 0}, _, What) -> {error, 404, <<"NOT_FOUND">>, <<What/binary, " não encontrado(a)"/utf8>>};
one({error, E}, _, _) -> {error, 400, <<"INVALID">>, iolist_to_binary(io_lib:format("~0p", [E]))}.
