%% SPDX-FileCopyrightText: 2026 André Luis Pereira dos Santos
%% SPDX-License-Identifier: AGPL-3.0-or-later
%% The technical center (spec 077, T-077-03, D1–D3, RF-077-01, RF-077-02; plan §2.6): the existing sources —
%% health, incidents, checks, disk, core, license, updates, parameters, actions, runbooks, modes — organized by the
%% work, in six tabs. No data is duplicated: each tab reads its sources when opened. Every item answers what, why,
%% what effect it has and what to do (an action of the catalog or a runbook), and opens its section for the detail.
%% A source that fails becomes an item saying so (the tab never breaks).
-module(ana_central).

-export([tab/2]).

-define(ORDER, #{<<"critical">> => 0, <<"serious">> => 1, <<"warning">> => 2, <<"info">> => 3, <<"ok">> => 4}).

-spec tab(binary(), map()) -> {ok, map()} | {error, binary()}.
tab(<<"now">>, U) -> answer(<<"now">>, sources([fun mode/1, fun health/1, fun incidents/1, fun requests/1, fun runbooks/1,
                                                fun findings/1, fun license/1, fun queues/1, fun restarts/1, fun node/1], U));
tab(<<"routine">>, U) -> answer(<<"routine">>, sources([fun check_runs/1, fun updates/1, fun retention/1], U));
tab(<<"capacity">>, U) -> answer(<<"capacity">>, sources([fun disk/1, fun license_capacity/1, fun core/1], U));
tab(<<"changes">>, U) -> answer(<<"changes">>, sources([fun parameter_changes/1, fun policy_changes/1], U));
tab(<<"security">>, U) -> answer(<<"security">>, sources([fun reviews/1, fun act_now/1, fun high_risk/1, fun locked_users/1], U));
tab(<<"log">>, U) -> answer(<<"log">>, sources([fun record/1], U));
tab(_, _) -> {error, <<"aba inexistente"/utf8>>}.

sources(Fs, U) ->
    lists:append([try F(U) catch C:R -> [item(<<"warning">>, <<"Uma fonte da Central não respondeu"/utf8>>,
                                              unicode:characters_to_binary(io_lib:format("~0p", [{C, R}])), <<>>, #{}, null)] end
                   || F <- Fs]).

answer(Tab, Items) ->
    Sorted = lists:sort(fun(A, B) -> {sev(A), maps:get(what, A)} =< {sev(B), maps:get(what, B)} end, Items),
    Worst = case Sorted of [] -> <<"ok">>; [F | _] -> maps:get(severity, F) end,
    Ok = Tab =/= <<"now">> orelse maps:get(Worst, ?ORDER) >= 3,
    Headline = case {Tab, Ok} of
        {<<"now">>, true} -> <<"Está tudo bem: nada pede atenção agora."/utf8>>;
        {<<"now">>, false} ->
            N = length([I || I <- Sorted, maps:get(maps:get(severity, I), ?ORDER) < 3]),
            unicode:characters_to_binary(io_lib:format("~b ponto(s) pede(m) atenção — o primeiro: ~ts",
                                           [N, maps:get(what, hd(Sorted))]));
        _ -> null
    end,
    {ok, #{tab => Tab, ok => Ok, headline => Headline, items => Sorted,
           at => calendar:system_time_to_rfc3339(erlang:system_time(second))}}.

sev(#{severity := S}) -> maps:get(S, ?ORDER, 5).

%% what · why · effect · action {code, params} · detail (section of the Administration) · runbook
item(Sev, What, Why, Effect, Extra, Detail) ->
    maps:merge(#{severity => Sev, what => What, why => Why, effect => Effect, action => null, runbook => null,
                 detail => Detail}, Extra).

act(Code) -> act(Code, #{}).
act(Code, Params) -> #{action => #{code => Code, params => Params}}.

%% ------------------------------------------------------------------ Agora
mode(_) ->
    case ana_mode:current() of
        #{mode := <<"normal">>, inbound_paused := false, routines_suspended := false} -> [];
        S -> [item(<<"serious">>, ana_mode:message(),
                   <<"ligado por "/utf8, (null_text(maps:get(set_by, S)))/binary>>,
                   <<"as pessoas veem a faixa; gravações, entradas ou rotinas podem estar paradas"/utf8>>,
                   act(<<"mode.normal">>), <<"#/admin/central">>)]
    end.

health(_) ->
    St = ana_health:state(),
    [item(case S of red -> <<"critical">>; _ -> <<"warning">> end,
          <<"Componente "/utf8, (to_bin(C))/binary, " em ", (to_bin(S))/binary>>,
          maps:get(message, V, <<>>), effect_of(C),
          maps:merge(act(<<"health.check">>), #{runbook => runbook_of(C)}), <<"#/admin/health">>)
     || {C, V = #{state := S}} <- maps:to_list(St), S =/= green].

effect_of(<<"database">>) -> <<"telas e rotinas não leem nem gravam"/utf8>>;
effect_of(<<"python">>) -> <<"programas não executam"/utf8>>;
effect_of(<<"scheduler">>) -> <<"rotinas agendadas não disparam"/utf8>>;
effect_of(<<"integrations">>) -> <<"mensagens com outros sistemas atrasam"/utf8>>;
effect_of(_) -> <<"parte do ERP funciona mais devagar ou com falhas"/utf8>>.

runbook_of(<<"database">>) -> <<"database_down">>;
runbook_of(<<"python">>) -> <<"node_down">>;
runbook_of(<<"integrations">>) -> <<"stuck_queue">>;
runbook_of(_) -> null.

incidents(_) ->
    {ok, Rows} = ana_health:incidents(true),
    [item(case maps:get(<<"severity">>, R) of <<"critical">> -> <<"critical">>; <<"serious">> -> <<"serious">>; _ -> <<"warning">> end,
          <<"Alerta aberto: "/utf8, (null_text(maps:get(<<"rule">>, R)))/binary>>, null_text(maps:get(<<"message">>, R)),
          case maps:get(<<"silenced">>, R) of true -> <<"silenciado: ninguém é avisado"/utf8>>; _ -> <<"as pessoas do alerta foram avisadas"/utf8>> end,
          #{}, <<"#/admin/alerts">>)
     || R <- Rows].

requests(U) ->
    {ok, Rows} = ana_tech:pending(U),
    [item(<<"warning">>, <<"Aguarda a segunda pessoa: "/utf8, (maps:get(<<"name">>, R))/binary>>,
          <<"pedido de "/utf8, (maps:get(<<"requested_by">>, R))/binary>>, maps:get(<<"effect">>, R),
          #{request => maps:get(<<"id">>, R), status => maps:get(<<"status">>, R), mine => maps:get(<<"mine">>, R)},
          <<"#/admin/central">>)
     || R <- Rows].

runbooks(_) ->
    {ok, Rows} = ana_runbook:open_runs(),
    [item(<<"info">>, <<"Roteiro em andamento: "/utf8, (maps:get(<<"name">>, R))/binary>>,
          <<"conduzido por "/utf8, (maps:get(<<"owner">>, R))/binary>>, <<"passo "/utf8, (integer_to_binary(maps:get(<<"step">>, R)))/binary>>,
          #{run => maps:get(<<"id">>, R)}, <<"#/admin/central">>)
     || R <- Rows].

findings(_) ->
    {ok, Rows} = ana_db:rows("SELECT rule, severity, title, suggestion FROM ana_system.advice "
                             "WHERE status = 'open' AND severity IN ('critical', 'serious') ORDER BY severity, first_seen LIMIT 20", []),
    [item(maps:get(<<"severity">>, R), maps:get(<<"title">>, R), maps:get(<<"suggestion">>, R),
          <<"achado das verificações periódicas"/utf8>>, act(<<"checks.run">>), <<"#/admin/checks">>)
     || R <- Rows].

license(_) ->
    case ana_license:current() of
        #{state := <<"restricted">>} ->
            [item(<<"critical">>, <<"Licença: o ERP está somente para consulta"/utf8>>, <<"licença vencida ou inválida"/utf8>>,
                  <<"ninguém grava até instalar a licença"/utf8>>, #{runbook => <<"expiring_credentials">>}, <<"#/admin/license">>)];
        #{state := S, days_left := D} when S =:= <<"grace">>; S =:= <<"expiring">> ->
            [item(<<"warning">>, <<"A licença vence em breve"/utf8>>, unicode:characters_to_binary(io_lib:format("~p dia(s)", [D])),
                  <<"depois do prazo o ERP fica somente para consulta"/utf8>>, #{runbook => <<"expiring_credentials">>},
                  <<"#/admin/license">>)];
        _ -> []
    end.

queues(_) ->
    {ok, N, Text} = (maps:get(<<"queue_stuck">>, ana_runbook:checks()))(),
    case N of
        0 -> [];
        _ -> [item(<<"warning">>, <<"Fila de integração parada"/utf8>>, Text, <<"outros sistemas não recebem ou não mandam dados"/utf8>>,
                   #{runbook => <<"stuck_queue">>}, <<"#/admin/integrations">>)]
    end.

restarts(_) ->
    {ok, N, Text} = (maps:get(<<"restarts_last_hour">>, ana_runbook:checks()))(),
    case N > 3 of
        true -> [item(<<"serious">>, <<"Subsistemas caindo e voltando"/utf8>>, Text, <<"falhas intermitentes para as pessoas"/utf8>>,
                      #{runbook => <<"crash_loop">>}, <<"#/admin/core">>)];
        false -> []
    end.

node(_) ->
    case ana_ha:draining() of
        true -> [item(<<"warning">>, <<"Este nó está fora do balanceamento"/utf8>>, <<"foi drenado"/utf8>>,
                      <<"recebe só o que ainda chega a ele"/utf8>>, act(<<"node.resume">>), <<"#/admin/central">>)];
        false -> []
    end.

%% ------------------------------------------------------------------ Rotina
check_runs(_) ->
    {ok, #{runs := Runs}} = ana_checks:summary(),
    [item(case maps:get(<<"status">>, R) of <<"error">> -> <<"warning">>; _ -> <<"ok">> end,
          <<"Verificações: "/utf8, (maps:get(<<"category">>, R))/binary>>,
          <<"última execução "/utf8, (to_bin(maps:get(<<"started_at">>, R)))/binary, " (", (to_bin(maps:get(<<"status">>, R)))/binary, ")">>,
          <<"rodam sozinhas todo dia"/utf8>>, act(<<"checks.run">>, #{<<"category">> => maps:get(<<"category">>, R)}),
          <<"#/admin/checks">>)
     || R <- Runs].

updates(_) ->
    case ana_product_updates:pending_count() of
        0 -> [item(<<"ok">>, <<"Atualizações do produto em dia"/utf8>>, <<>>, <<>>, #{}, <<"#/admin/updates">>)];
        N -> [item(<<"info">>, unicode:characters_to_binary(io_lib:format("~b atualização(ões) do produto disponível(is)", [N])),
                   <<"programas do produto com versão nova"/utf8>>, <<"aceitar traz as correções e melhorias"/utf8>>, #{},
                   <<"#/admin/updates">>)]
    end.

retention(_) ->
    {ok, Rows} = ana_db:rows("SELECT started_at, status FROM ana_system.task_run WHERE task LIKE 'retention%' "
                             "ORDER BY started_at DESC LIMIT 1", []),
    case Rows of
        [] -> [item(<<"info">>, <<"Retenção ainda não rodou"/utf8>>, <<"roda todo dia no horário configurado"/utf8>>, <<>>,
                    act(<<"retention.purge">>), <<"#/admin/retention">>)];
        [R] -> [item(<<"ok">>, <<"Retenção"/utf8>>, <<"última limpeza "/utf8, (to_bin(maps:get(<<"started_at">>, R)))/binary>>,
                     <<>>, act(<<"retention.purge">>), <<"#/admin/retention">>)]
    end.

%% ------------------------------------------------------------------ Capacidade
disk(_) ->
    {ok, #{size := Mb}} = case (maps:get(<<"db_size_mb">>, ana_runbook:checks()))() of
        {ok, V, _} -> {ok, #{size => V}};
        _ -> {ok, #{size => null}}
    end,
    Free = case (maps:get(<<"disk_free_pct">>, ana_runbook:checks()))() of
        {ok, F, T} -> [item(case F < 15 of true -> <<"serious">>; false -> <<"ok">> end, <<"Espaço livre no disco"/utf8>>, T,
                            <<"sem espaço o banco para de gravar"/utf8>>, #{runbook => <<"disk_full">>}, <<"#/admin/disk">>)];
        {unknown, T} -> [item(<<"info">>, <<"Espaço livre no disco"/utf8>>, T, <<>>, #{runbook => <<"disk_full">>}, <<"#/admin/disk">>)]
    end,
    [item(<<"ok">>, <<"Tamanho do banco"/utf8>>, unicode:characters_to_binary(io_lib:format("~p MiB", [Mb])), <<>>, #{}, <<"#/admin/disk">>) | Free].

license_capacity(_) ->
    L = ana_license:current(),
    case maps:get(days_left, L, null) of
        D when is_integer(D) ->
            [item(case D < 30 of true -> <<"warning">>; false -> <<"ok">> end,
                  unicode:characters_to_binary(io_lib:format("A licença vence em ~b dia(s)", [D])), <<>>,
                  <<"depois do prazo o ERP fica somente para consulta"/utf8>>, #{}, <<"#/admin/license">>)];
        _ -> []
    end.

core(_) ->
    {ok, S} = ana_core_view:snapshot(),
    #{memory_mb := #{total := Total}, processes := P} = S,
    [item(<<"ok">>, <<"Núcleo deste nó"/utf8>>, unicode:characters_to_binary(io_lib:format("~b MiB em uso, ~b processos", [Total, P])),
          <<>>, #{}, <<"#/admin/core">>)].

%% ------------------------------------------------------------------ Mudanças
parameter_changes(_) ->
    {ok, Rows} = ana_db:rows("SELECT v.key, p.label, v.after, v.reason, v.set_by, v.set_at, v.until, v.kind "
                             "FROM technical.parameter_version v LEFT JOIN technical.parameter p ON p.key = v.key "
                             "WHERE v.set_at > now() - interval '30 days' ORDER BY v.id DESC LIMIT 50", []),
    [item(<<"info">>, <<"Parâmetro: "/utf8, (null_text(maps:get(<<"label">>, R)))/binary>>,
          <<(to_bin(maps:get(<<"set_by">>, R)))/binary, " — "/utf8, (null_text(maps:get(<<"reason">>, R)))/binary>>,
          case maps:get(<<"until">>, R) of null -> <<>>; T -> <<"temporária até "/utf8, (to_bin(T))/binary>> end,
          #{key => maps:get(<<"key">>, R), at => maps:get(<<"set_at">>, R)}, <<"#/admin/central">>)
     || R <- Rows].

policy_changes(_) ->
    {ok, Rows} = ana_db:rows("SELECT action, target, username, at FROM ana_system.admin_log "
                             "WHERE action IN ('tech.policy', 'parameter.risk') AND at > now() - interval '30 days' "
                             "ORDER BY id DESC LIMIT 30", []),
    [item(<<"info">>, <<"Rigor mudado: "/utf8, (maps:get(<<"target">>, R))/binary>>, <<"por "/utf8, (maps:get(<<"username">>, R))/binary>>,
          <<>>, #{at => maps:get(<<"at">>, R)}, <<"#/admin/central">>)
     || R <- Rows].

%% ------------------------------------------------------------------ Segurança técnica
reviews(_) ->
    {ok, Rows} = ana_db:rows("SELECT r.id, a.name, r.requested_by, r.requested_at FROM technical.action_run r "
                             "JOIN technical.action a ON a.code = r.code WHERE r.status = 'review' ORDER BY r.id", []),
    [item(<<"warning">>, <<"Ação feita sem segunda pessoa, aguarda revisão: "/utf8, (maps:get(<<"name">>, R))/binary>>,
          <<"por "/utf8, (maps:get(<<"requested_by">>, R))/binary>>, <<"agir agora e revisar depois"/utf8>>,
          #{request => maps:get(<<"id">>, R)}, <<"#/admin/central">>)
     || R <- Rows].

act_now(_) ->
    {ok, Rows} = ana_db:rows("SELECT p.code, a.name FROM technical.action_policy p JOIN technical.action a ON a.code = p.code "
                             "WHERE p.act_now", []),
    [item(<<"info">>, <<"Pode agir sem a segunda pessoa (plantão): "/utf8, (maps:get(<<"name">>, R))/binary>>,
          <<"revisão depois"/utf8>>, <<>>, #{}, <<"#/admin/central">>) || R <- Rows].

high_risk(_) ->
    {ok, Rows} = ana_db:rows("SELECT a.code, a.name, COALESCE(p.groups, '{}') AS groups FROM technical.action a "
                             "LEFT JOIN technical.action_policy p ON p.code = a.code "
                             "WHERE GREATEST(CASE a.risk WHEN 'high' THEN 3 WHEN 'medium' THEN 2 ELSE 1 END, "
                             "  CASE p.risk WHEN 'high' THEN 3 WHEN 'medium' THEN 2 ELSE 1 END) = 3", []),
    [item(<<"ok">>, <<"Pede segunda pessoa: "/utf8, (maps:get(<<"name">>, R))/binary>>,
          case maps:get(<<"groups">>, R) of [] -> <<"só administradores"/utf8>>;
                                             Gs -> <<"grupos: "/utf8, (iolist_to_binary(lists:join(<<", ">>, Gs)))/binary>> end,
          <<>>, #{}, <<"#/admin/central">>) || R <- Rows].

locked_users(_) ->
    case catch ana_db:rows("SELECT username FROM ana_system.app_user WHERE active AND locked_until > now() ORDER BY 1 LIMIT 20", []) of
        {ok, Rows} ->
            [item(<<"warning">>, <<"Usuário bloqueado por tentativas: "/utf8, (maps:get(<<"username">>, R))/binary>>, <<>>,
                  <<"a pessoa não entra até o bloqueio passar"/utf8>>,
                  act(<<"user.unlock">>, #{<<"username">> => maps:get(<<"username">>, R)}), <<"#/admin/users">>) || R <- Rows];
        _ -> []
    end.

%% ------------------------------------------------------------------ Registro
record(_) ->
    {ok, Runs} = ana_tech:runs(#{limit => 100}),
    [item(case maps:get(<<"status">>, R) of <<"failed">> -> <<"warning">>; _ -> <<"info">> end,
          maps:get(<<"name">>, R),
          <<(maps:get(<<"requested_by">>, R))/binary, " — "/utf8, (maps:get(<<"status">>, R))/binary,
            (case maps:get(<<"approved_by">>, R) of null -> <<>>; A -> <<", aprovado por "/utf8, A/binary>> end)/binary>>,
          null_text(maps:get(<<"reason">>, R)), #{at => maps:get(<<"requested_at">>, R), run => maps:get(<<"id">>, R)},
          <<"#/admin/central">>)
     || R <- Runs].

to_bin(B) when is_binary(B) -> B;
to_bin(A) when is_atom(A) -> atom_to_binary(A);
to_bin(X) -> unicode:characters_to_binary(io_lib:format("~0p", [X])).

null_text(null) -> <<>>;
null_text(B) -> to_bin(B).
