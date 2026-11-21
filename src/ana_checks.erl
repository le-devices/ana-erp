%% SPDX-FileCopyrightText: 2026 André Luis Pereira dos Santos
%% SPDX-License-Identifier: AGPL-3.0-or-later
%% Periodic checks: security, vulnerable components, integrity, robustness and performance
%% (spec 033).
%%
%% Runs on the scheduler leader (once per cluster) as internal tasks of the `system` robot
%% (P14) and on demand. Findings share the advisor's model (spec 019): unchanged findings
%% are not rewritten (P15), findings that disappear are resolved, dismissed findings stay
%% quiet until their date unless they get worse. A new critical finding becomes a notice
%% in the administrators' bell.
-module(ana_checks).
-behaviour(gen_server).

-export([start_link/0, run/2, summary/0, import_vulnerabilities/2, notices/1, mark_notice/1]).
-export([regression/3, demo/0, technical_codes/0, config/0, save_config/2, refresh_feed/1]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2]).

-define(TICK_MS, 5 * 60 * 1000).        % probes; robustness every 3rd tick
-define(CATEGORIES, [<<"security">>, <<"dependencies">>, <<"integrity">>, <<"robustness">>, <<"performance">>]).
-define(RULES, #{
    <<"security">> => [<<"trivial_password">>, <<"example_secret">>, <<"weak_policy">>, <<"too_many_admins">>,
                       <<"pending_password_change">>, <<"stale_api_key">>, <<"open_share_links">>,
                       <<"connector_without_hosts">>, <<"short_audit_retention">>, <<"smtp_plaintext">>],
    <<"dependencies">> => [<<"vulnerable_component">>, <<"vulnerability_feed">>, <<"vulnerability_feed_failed">>],
    <<"integrity">> => [<<"shipped_files">>, <<"ledger_reconciliation">>, <<"master_quality">>],
    <<"robustness">> => [<<"wal_archiving">>, <<"base_backup">>, <<"restore_test">>, <<"dead_letters">>,
                         <<"open_breaker">>, <<"error_rate">>, <<"files_disk">>],
    <<"performance">> => [<<"probe_regression">>, <<"ui_slow_screen">>]}).
-define(TRIVIAL, [<<"admin">>, <<"password">>, <<"123456">>, <<"12345678">>, <<"ana">>, <<"senha">>]).
-define(TECHNICAL, [<<"EXCEPTION">>, <<"CPU_LIMIT">>, <<"MEMORY">>, <<"SYNTAX">>, <<"SQL">>, <<"INTERNAL">>, <<"TIMEOUT">>,
                    <<"OVERLOAD">>, <<"PROTOCOL">>, <<"PROCESS_EXITED">>, <<"SQL_LIMIT">>, <<"ROW_LIMIT">>,
                    <<"RESULT_TOO_LARGE">>, <<"MAX_DEPTH">>]).
-define(EXAMPLE_KEY, <<"ZGV2LW9ubHktbWFzdGVyLWtleS1jaGFuZ2UtbWUhISE=">>).

start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

%% On demand (Administração → Verificações → Verificar agora): runs here, owned by the caller.
-spec run(binary(), map()) -> {ok, map()} | {error, term()}.
run(<<"all">>, User) ->
    Rs = [run(C, User) || C <- ?CATEGORIES],
    {ok, #{found => lists:sum([N || {ok, #{found := N}} <- Rs]), resolved => lists:sum([N || {ok, #{resolved := N}} <- Rs])}};
run(Category, User) ->
    case lists:member(Category, ?CATEGORIES) of
        true -> ana_task:run(<<"checks.", Category/binary>>, User, origin(User), fun() -> check(Category) end);
        false -> {error, unknown_category}
    end.

origin(#{username := <<"system">>}) -> <<"internal">>;
origin(_) -> <<"studio">>.

init([]) ->
    erlang:send_after(?TICK_MS, self(), tick),
    erlang:send_after(120000, self(), daily),
    {ok, #{ticks => 0, last_eval => 0}}.

handle_call(_, _From, S) -> {reply, {error, unknown}, S}.
handle_cast(_, S) -> {noreply, S}.

handle_info(tick, S = #{ticks := N, last_eval := Last}) ->
    erlang:send_after(?TICK_MS, self(), tick),
    case leader() of
        true ->
            _ = catch sample_probes(),
            _ = N rem 3 =:= 0 andalso internal(<<"robustness">>),
            Now = erlang:monotonic_time(second),
            case Now - Last >= 3600 of
                true -> _ = internal(<<"performance">>), {noreply, S#{ticks := N + 1, last_eval := Now}};
                false -> {noreply, S#{ticks := N + 1}}
            end;
        false -> {noreply, S#{ticks := N + 1}}
    end;
handle_info(daily, S) ->
    erlang:send_after(24 * 3600 * 1000, self(), daily),
    _ = leader() andalso begin
        _ = [internal(C) || C <- [<<"security">>, <<"integrity">>, <<"dependencies">>, <<"robustness">>]],
        purge()
    end,
    {noreply, S};
handle_info(_, S) -> {noreply, S}.

leader() ->
    case catch ana_scheduler:status() of
        #{leader := true} -> true;
        _ -> false
    end.

internal(Category) -> catch run(Category, ana_task:system_user()).

purge() ->
    _ = ana_db:exec("DELETE FROM ana_system.perf_sample WHERE at < now() - interval '30 days'", []),
    _ = ana_db:exec("DELETE FROM ana_system.notice WHERE read AND created_at < now() - interval '90 days'", []),
    _ = catch ana_datacopy:purge(),        % spec 034: copy files live 48 h
    ok.

%% Spec 030: technical failures are retried by the flows engine; business refusals are not.
-spec technical_codes() -> [binary()].
technical_codes() -> ?TECHNICAL.

-spec demo() -> boolean().
demo() -> ana_config:text("ANA_DEMO", "false") =:= "true".

%% ---------------------------------------------------------------- engine

check(Category) ->
    {ok, Before} = ana_db:rows("SELECT rule || '|' || target AS k FROM ana_system.advice "
                               "WHERE category = $1 AND status IN ('open', 'dismissed')", [Category]),
    Known = [K || #{<<"k">> := K} <- Before],
    Found = lists:append([safe(F) || F <- rules(Category)]),
    _ = [ana_advisor:upsert(Category, R, T, Sev, Ti, D, Su, E) || {R, T, Sev, Ti, D, Su, E} <- Found],
    Keys = [<<R/binary, "|", T/binary>> || {R, T, _, _, _, _, _} <- Found],
    {ok, Resolved} = ana_db:exec(
        "UPDATE ana_system.advice SET status = 'resolved' WHERE status = 'open' AND category = $1 "
        "AND rule = ANY($2::text[]) AND NOT (rule || '|' || target = ANY($3::text[]))",
        [Category, maps:get(Category, ?RULES), Keys]),
    Fresh = [F || F = {R, T, _, _, _, _, _} <- Found, not lists:member(<<R/binary, "|", T/binary>>, Known)],
    New = [Ti || {_, _, <<"critical">>, Ti, _, _, _} <- Fresh],
    _ = catch notify(Category, Fresh),
    %% A finding that comes and goes (resolved, then found again) never piles up the same unread notice (spec 042).
    _ = [ana_db:exec("INSERT INTO ana_system.notice (kind, severity, message, link) SELECT 'check', 'critical', $1, '#/admin/checks' "
                     "WHERE NOT EXISTS (SELECT 1 FROM ana_system.notice WHERE NOT read AND kind = 'check' AND message = $1)",
                     [Ti]) || Ti <- New],
    {ok, #{category => Category, found => length(Found), resolved => Resolved, new_critical => length(New)}}.

%% ---------------------------------------------------------------- feed and notifications (T-033-09b)

%% The base of advisories comes first from the connector (when one is on); a failure is a finding.
feed() ->
    case ana_osv:refresh() of
        {error, Msg} ->
            [{<<"vulnerability_feed_failed">>, <<"connector">>, <<"warning">>,
              <<"Atualização automática da base de vulnerabilidades falhou"/utf8>>, Msg,
              <<"Confira o conector da base (Administração → Integrações) e o registro de chamadas."/utf8>>, #{}}];
        _ -> []
    end.

-define(SEV_RANK, #{<<"info">> => 0, <<"warning">> => 1, <<"serious">> => 2, <<"critical">> => 3}).

%% New findings at or above the configured severity go, in one message, through the connector:
%% e-mail for SMTP (spec 044), a "checks.findings" message for an HTTP connector with a delivery program.
notify(Category, Fresh) ->
    {ok, Cfg} = ana_db:one("SELECT c.notify_connector, c.notify_recipients, c.notify_min_severity, k.kind "
                           "FROM ana_system.check_config c LEFT JOIN integration.connector k "
                           "ON k.name = c.notify_connector AND k.active", []),
    Min = maps:get(maps:get(<<"notify_min_severity">>, Cfg), ?SEV_RANK),
    Items = [F || F = {_, _, Sev, _, _, _, _} <- Fresh, maps:get(Sev, ?SEV_RANK, 0) >= Min],
    case {Items, Cfg} of
        {[], _} -> ok;
        {_, #{<<"kind">> := null}} -> ok;
        {_, #{<<"notify_connector">> := Conn, <<"kind">> := <<"smtp">>, <<"notify_recipients">> := To}} when To =/= [] ->
            Text = iolist_to_binary([fmt("~b achado(s) novo(s) nas Verificações (~ts):\r\n\r\n", [length(Items), Category]),
                                     [fmt("[~ts] ~ts\r\n~ts\r\nO que fazer: ~ts\r\n\r\n", [Sev, Ti, D, Su])
                                      || {_, _, Sev, Ti, D, Su, _} <- Items],
                                     <<"Veja Administração → Verificações no Estúdio."/utf8>>]),
            outbox(Conn, <<"email">>, #{to => To, subject => fmt("[ANA] Verificações: ~b achado(s) novo(s)", [length(Items)]),
                                        text => Text});
        {_, #{<<"notify_connector">> := Conn, <<"kind">> := <<"http_api">>}} ->
            outbox(Conn, <<"checks.findings">>,
                   #{category => Category, findings => [#{rule => R, target => T, severity => Sev, title => Ti, detail => D,
                                                          suggestion => Su} || {R, T, Sev, Ti, D, Su, _} <- Items]});
        _ -> ok
    end.

outbox(Conn, Kind, Payload) ->
    _ = ana_db:exec("INSERT INTO integration.outbox (connector, kind, payload, created_by) VALUES ($1, $2, $3::text::jsonb, 'system')",
                    [Conn, Kind, iolist_to_binary(json:encode(Payload))]),
    _ = catch ana_integration:poke(),
    ok.

-spec config() -> {ok, map()}.
config() ->
    {ok, C} = ana_db:one("SELECT notify_connector, notify_recipients, notify_min_severity, feed_connector, feed_at, feed_ok, "
                         "  feed_message, feed_advisories, updated_by, updated_at FROM ana_system.check_config", []),
    {ok, Conns} = ana_db:rows("SELECT name, kind, description FROM integration.connector WHERE active "
                              "AND (kind = 'smtp' OR (kind = 'http_api' AND outbound_program IS NOT NULL)) ORDER BY name", []),
    Feed = case ana_osv:feed_connector() of none -> null; #{<<"name">> := N} -> N end,
    {ok, C#{<<"connectors">> => Conns, <<"feed_available">> => Feed}}.

-spec save_config(map(), map()) -> {ok, map()} | {error, binary()}.
save_config(B, #{username := Who}) ->
    Conn = case maps:get(<<"notify_connector">>, B, null) of <<>> -> null; X -> X end,
    To = maps:get(<<"notify_recipients">>, B, []),
    Min = maps:get(<<"notify_min_severity">>, B, <<"critical">>),
    Kind = case Conn of
        null -> null;
        _ -> case ana_db:one("SELECT kind FROM integration.connector WHERE name = $1 AND active "
                             "AND (kind = 'smtp' OR (kind = 'http_api' AND outbound_program IS NOT NULL))", [Conn]) of
                 {ok, #{<<"kind">> := K}} -> K;
                 _ -> invalid
             end
    end,
    if
        Kind =:= invalid -> {error, <<"o conector precisa estar ativo e ser de e-mail (SMTP) ou HTTP com programa de saída"/utf8>>};
        not is_list(To) -> {error, <<"destinatários inválidos"/utf8>>};
        true ->
            case {lists:all(fun ana_smtp:valid_address/1, To), Kind =/= <<"smtp">> orelse To =/= [],
                  lists:member(Min, [<<"warning">>, <<"serious">>, <<"critical">>])} of
                {false, _, _} -> {error, <<"destinatários devem ser e-mails válidos"/utf8>>};
                {_, false, _} -> {error, <<"e-mail (SMTP): informe os destinatários"/utf8>>};
                {_, _, false} -> {error, <<"gravidade mínima: atenção, sério ou crítico"/utf8>>};
                _ ->
                    {ok, _} = ana_db:exec("UPDATE ana_system.check_config SET notify_connector = $1, notify_recipients = $2, "
                                          "notify_min_severity = $3, updated_by = $4, updated_at = now()", [Conn, To, Min, Who]),
                    ana_admin:log(Who, <<"checks.notify">>, <<"config">>, null, #{connector => Conn, recipients => To, min => Min}),
                    config()
            end
    end.

%% "Atualizar agora": the base from the connector, then the dependency findings with it.
-spec refresh_feed(map()) -> {ok, map()} | {error, binary()}.
refresh_feed(User = #{username := Who}) ->
    ana_admin:log(Who, <<"checks.feed_refresh">>, <<"osv">>, null, null),
    case run(<<"dependencies">>, User) of
        {ok, R} ->
            {ok, C} = config(),
            case C of
                #{<<"feed_available">> := null} -> {error, <<"nenhum conector de base de vulnerabilidades ligado (Integrações)"/utf8>>};
                #{<<"feed_ok">> := false, <<"feed_message">> := M} -> {error, M};
                _ -> {ok, C#{<<"check">> => R}}
            end;
        E -> E
    end.

safe(F) ->
    try F()
    catch C:R:St -> logger:warning("check failed: ~0p:~0p ~0p", [C, R, St]), []
    end.

rules(<<"security">>) ->
    [fun trivial_password/0, fun example_secret/0, fun weak_policy/0, fun too_many_admins/0,
     fun pending_password_change/0, fun stale_api_key/0, fun open_share_links/0, fun connector_without_hosts/0,
     fun short_audit_retention/0, fun smtp_plaintext/0];
rules(<<"dependencies">>) -> [fun feed/0, fun inventory/0, fun ana_osv:findings/0, fun vulnerability_feed/0];
rules(<<"integrity">>) -> [fun shipped_files/0, fun ledger_reconciliation/0, fun master_quality/0];
rules(<<"robustness">>) ->
    [fun wal_archiving/0, fun base_backup/0, fun restore_test/0, fun dead_letters/0, fun open_breaker/0,
     fun error_rate/0, fun files_disk/0];
rules(<<"performance">>) -> [fun probe_regression/0, fun ui_slow_screen/0].

%% ---------------------------------------------------------------- security (RF-033-03)

%% Privileged people whose password is trivial (their user name or a common one). The guess
%% that matched is never recorded.
trivial_password() ->
    {ok, Users} = ana_db:rows("SELECT username, password_hash FROM ana_system.app_user WHERE active AND kind = 'human' "
                              "AND role IN ('admin', 'developer') ORDER BY username LIMIT 50", []),
    [{<<"trivial_password">>, U, <<"critical">>, fmt("A conta ~ts usa senha trivial", [U]),
      <<"A senha é o próprio nome do usuário ou uma senha comum (como a de fábrica): qualquer um entra com privilégios."/utf8>>,
      <<"Troque a senha agora (menu da conta → Trocar senha, ou Administração → Usuários → Redefinir senha)."/utf8>>,
      #{username => U}}
     || #{<<"username">> := U, <<"password_hash">> := H} <- Users,
        lists:any(fun(P) -> ana_security:verify_password(P, H) end, [U | ?TRIVIAL])].

example_secret() ->
    Key = [{<<"master_key">>, <<"Chave mestra (ANA_MASTER_KEY) é a de exemplo"/utf8>>,
            <<"Os segredos dos conectores ficam decifráveis por quem conhece o exemplo publicado."/utf8>>,
            <<"Gere outra com `openssl rand -base64 32`, configure em todos os nós e cadastre os segredos de novo."/utf8>>}
           || list_to_binary(ana_config:text("ANA_MASTER_KEY", "")) =:= ?EXAMPLE_KEY],
    Db = [{<<"db_password">>, <<"Senha do banco (ANA_DB_PASSWORD) é a de exemplo"/utf8>>,
           <<"Quem alcança o banco pela rede entra com a senha publicada no docker-compose.yml."/utf8>>,
           <<"Defina ANA_DB_PASSWORD (e POSTGRES_PASSWORD) fortes e reinicie os nós um a um."/utf8>>}
          || ana_config:text("ANA_DB_PASSWORD", "") =:= "ana_change_this_password"],
    Cookie = [{<<"cookie">>, <<"Cookie de distribuição Erlang (ANA_COOKIE) é o de exemplo"/utf8>>,
               <<"Com o cookie, um nó estranho na rede assume o controle do ERP."/utf8>>,
               <<"Defina ANA_COOKIE longo e aleatório, igual em todos os nós."/utf8>>}
              || lists:member(ana_config:text("ANA_COOKIE", ""), ["ana-cluster-test-cookie", "ana", "cookie", "secret"])],
    [{<<"example_secret">>, T, <<"critical">>, Ti, D, Su, #{setting => T}} || {T, Ti, D, Su} <- Key ++ Db ++ Cookie].

weak_policy() ->
    Rules = [{password_min_length, fun(V) -> V < 10 end, <<"warning">>, <<"Senhas podem ter menos de 10 caracteres"/utf8>>,
              <<"Aumente o tamanho mínimo de senha para 10 ou mais."/utf8>>},
             {session_hours, fun(V) -> V > 24 end, <<"warning">>, <<"Sessões duram mais de 24 horas"/utf8>>,
              <<"Reduza a validade da sessão (12 h é o padrão)."/utf8>>},
             {max_login_failures, fun(V) -> V > 10 end, <<"warning">>, <<"Muitas tentativas de login antes do bloqueio"/utf8>>,
              <<"Use até 10 falhas seguidas antes de bloquear."/utf8>>}],
    [{<<"weak_policy">>, atom_to_binary(K), Sev, Ti, fmt("Valor atual: ~p.", [V]),
      <<Su/binary, " (Administração → Sistema → Parâmetros)"/utf8>>, #{setting => K, value => V}}
     || {K, Bad, Sev, Ti, Su} <- Rules, V <- [ana_settings:get(K)], is_integer(V), Bad(V)].

too_many_admins() ->
    {ok, #{<<"n">> := N}} = ana_db:one("SELECT count(*) AS n FROM ana_system.app_user WHERE active AND role = 'admin'", []),
    [{<<"too_many_admins">>, <<"admins">>, <<"warning">>, fmt("~b administradores ativos", [N]),
      <<"Cada administrador a mais é uma conta que, se tomada, controla tudo."/utf8>>,
      <<"Mantenha até 3 administradores; os demais podem ser desenvolvedores ou usuários com grupos."/utf8>>, #{count => N}}
     || N > 3].

pending_password_change() ->
    {ok, Rows} = ana_db:rows("SELECT username FROM ana_system.app_user WHERE active AND kind = 'human' AND must_change_password "
                             "AND created_at < now() - interval '7 days' ORDER BY username LIMIT 100", []),
    case [U || #{<<"username">> := U} <- Rows] of
        [] -> [];
        Us -> [{<<"pending_password_change">>, <<"users">>, <<"warning">>,
                fmt("~b conta(s) sem trocar a senha inicial há mais de 7 dias", [length(Us)]),
                fmt("Contas: ~ts.", [lists:join(<<", ">>, Us)]),
                <<"Desative as contas sem uso ou peça a troca; a senha inicial circulou por e-mail ou mensagem."/utf8>>,
                #{users => Us}}]
    end.

stale_api_key() ->
    MaxDays = ana_settings:get(checks_key_max_days),
    {ok, Rows} = ana_db:rows(
        "SELECT id, username, name, to_char(created_at, 'DD/MM/YYYY') AS created, to_char(last_used_at, 'DD/MM/YYYY') AS used, "
        "  COALESCE(last_used_at, created_at) < now() - interval '90 days' AS idle "
        "FROM ana_system.api_key WHERE revoked_at IS NULL AND (expires_at IS NULL OR expires_at > now()) "
        "AND (COALESCE(last_used_at, created_at) < now() - interval '90 days' "
        "     OR (expires_at IS NULL AND created_at < now() - make_interval(days => $1::int))) ORDER BY id LIMIT 200", [MaxDays]),
    [{<<"stale_api_key">>, fmt("~b", [Id]), <<"warning">>,
      case Idle of
          true -> fmt("Chave de API sem uso há mais de 90 dias: ~ts (~ts)", [Name, U]);
          false -> fmt("Chave de API com mais de ~b dias e sem validade: ~ts (~ts)", [MaxDays, Name, U])
      end,
      fmt("Criada em ~ts; último uso: ~ts.", [str(C), case Used of null -> <<"nunca">>; _ -> str(Used) end]),
      <<"Revogue a chave sem uso, ou gere outra com validade e troque no sistema que a usa."/utf8>>, #{id => Id, username => U}}
     || #{<<"id">> := Id, <<"username">> := U, <<"name">> := Name, <<"created">> := C, <<"used">> := Used, <<"idle">> := Idle} <- Rows].

open_share_links() ->
    {ok, #{<<"n">> := N}} = ana_db:one(
        "SELECT count(*) AS n FROM files.share_link WHERE NOT revoked AND password_hash IS NULL "
        "AND expires_at > now() + interval '30 days'", []),
    [{<<"open_share_links">>, <<"files">>, <<"warning">>, fmt("~b link(s) de compartilhamento sem senha e válidos por mais de 30 dias", [N]),
      <<"Quem tiver o endereço baixa o arquivo, sem senha, por muito tempo."/utf8>>,
      <<"Revogue os links que não precisam mais existir, ou recrie-os com senha e validade curta (Arquivos → Compartilhar)."/utf8>>,
      #{count => N}}
     || N > 0].

connector_without_hosts() ->
    {ok, Rows} = ana_db:rows("SELECT name FROM integration.connector WHERE active AND kind = 'http_api' "
                             "AND cardinality(allowed_hosts) = 0 ORDER BY name", []),
    [{<<"connector_without_hosts">>, N, <<"serious">>, fmt("Conector ~ts sem lista de hosts permitidos", [N]),
      <<"Sem a lista, o conector aceita endereços montados pelos programas: risco de enviar dados ou segredos a outro host."/utf8>>,
      <<"Informe os hosts permitidos do conector (Administração → Integrações)."/utf8>>, #{connector => N}}
     || #{<<"name">> := N} <- Rows].

%% Spec 044 (D1): e-mail without encryption is allowed only on purpose, and it stays visible.
smtp_plaintext() ->
    {ok, Rows} = ana_db:rows("SELECT name FROM integration.connector WHERE active AND kind = 'smtp' "
                             "AND options ->> 'security' = 'none' ORDER BY name", []),
    [{<<"smtp_plaintext">>, N, <<"serious">>, fmt("Conector de e-mail ~ts sem criptografia", [N]),
      <<"As mensagens (e a senha, se houver) trafegam abertas na rede até o servidor de e-mail."/utf8>>,
      <<"Use TLS ou STARTTLS no conector (Administração → Integrações)."/utf8>>, #{connector => N}}
     || #{<<"name">> := N} <- Rows].

short_audit_retention() ->
    V = ana_settings:get(retention_access_days),
    [{<<"short_audit_retention">>, <<"retention_access_days">>, <<"warning">>,
      fmt("Acessos guardados por só ~b dias", [V]),
      <<"Incidentes de segurança costumam ser descobertos semanas depois; sem o registro não há como investigar."/utf8>>,
      <<"Guarde os acessos por 90 dias ou mais (Administração → Retenção)."/utf8>>, #{days => V}}
     || is_integer(V), V < 90].

%% ---------------------------------------------------------------- dependencies (RF-033-01/02)

inventory() ->
    {ok, _} = ana_inventory:sync(),
    [].

vulnerability_feed() ->
    {ok, #{<<"n">> := N, <<"age">> := Age}} = ana_db:one(
        "SELECT count(*) AS n, COALESCE(extract(day FROM now() - max(imported_at))::int, -1) AS age FROM ana_system.vulnerability", []),
    Suggestion = <<"Baixe a base OSV dos ecossistemas Hex, Debian e PyPI (osv.dev → \"Data dump\") e envie em "
                   "Administração → Verificações → Inventário."/utf8>>,
    if
        N =:= 0 -> [{<<"vulnerability_feed">>, <<"osv">>, <<"info">>, <<"Base de vulnerabilidades não importada"/utf8>>,
                     <<"Sem a base, os componentes da instalação não são conferidos contra vulnerabilidades conhecidas."/utf8>>,
                     Suggestion, #{}}];
        Age > 30 -> [{<<"vulnerability_feed">>, <<"osv">>, <<"warning">>, fmt("Base de vulnerabilidades com ~b dias", [Age]),
                      <<"Vulnerabilidades novas são publicadas todos os dias."/utf8>>, Suggestion, #{age_days => Age}}];
        true -> []
    end.

-spec import_vulnerabilities(binary(), map()) -> {ok, map()} | {error, binary()}.
import_vulnerabilities(Body, User = #{username := Who}) ->
    case ana_osv:import(Body, Who) of
        {ok, R} ->
            ana_admin:log(Who, <<"checks.vulnerabilities.import">>, <<"osv">>, null, R),
            Found = case run(<<"dependencies">>, User) of {ok, #{found := F}} -> F; _ -> null end,
            {ok, R#{findings => Found}};
        E -> E
    end.

%% ---------------------------------------------------------------- integrity (RF-033-04)

shipped_files() ->
    case ana_inventory:verify_files() of
        {ok, _} -> [];
        no_manifest ->
            [{<<"shipped_files">>, <<"manifest">>, <<"info">>, <<"Manifesto dos arquivos do produto ausente"/utf8>>,
              <<"A instalação não foi feita pela imagem oficial: a integridade dos arquivos não pode ser conferida."/utf8>>,
              <<"Use a imagem construída pelo Dockerfile do produto."/utf8>>, #{}}];
        {mismatch, Bad} ->
            Shown = lists:sublist(Bad, 20),
            [{<<"shipped_files">>, <<"priv">>, <<"critical">>, fmt("~b arquivo(s) do produto alterado(s) depois da construção", [length(Bad)]),
              fmt("~ts~ts", [lists:join(<<"; ">>, [[F, <<" ("/utf8>>, what(W), <<")">>] || {F, W} <- Shown]),
                             case length(Bad) > 20 of true -> <<"…"/utf8>>; false -> <<>> end]),
              <<"Arquivos do produto só mudam com uma imagem nova. Investigue a alteração e reconstrua o nó a partir da imagem."/utf8>>,
              #{files => [#{file => F, change => W} || {F, W} <- Shown]}}]
    end.

%% Spec 038 (RF-038-04): every subledger matches the ledger; a difference is critical (a notice
%% reaches the administrator) and resolves itself when it is back to zero.
ledger_reconciliation() ->
    {ok, Rows} = ana_db:rows(
        "SELECT key, label, difference::text AS difference, items FROM finance.reconciliation() "
        "WHERE abs(COALESCE(difference, 0)) >= 0.01", []),
    [{<<"ledger_reconciliation">>, K, <<"critical">>,
      fmt("Conciliação divergente: ~ts (diferença R$ ~ts)", [L, D]),
      fmt("~ts não bate com a contabilidade (~b item(ns) envolvidos).", [L, N]),
      <<"Abra Conciliações (finance.reconciliations), detalhe a linha e corrija pelo documento de origem; "
        "não corrija com lançamento manual."/utf8>>,
      #{key => K, difference => D}}
     || #{<<"key">> := K, <<"label">> := L, <<"difference">> := D, <<"items">> := N} <- Rows].

%% Spec 040 (RF-040-10): the quality indicators declared for each master entity (master.entities),
%% computed by the product program as the robot "system"; one finding per indicator with records.
master_quality() ->
    case ana_execution:run(<<"master.quality">>, #{}, ana_task:system_user(), #{origin => <<"internal">>}) of
        {ok, #{result := #{<<"entities">> := Es}}} ->
            [{<<"master_quality">>, <<E/binary, ":", L/binary>>, <<"warning">>,
              fmt("Cadastros: ~ts — ~ts (~b)", [P, L, N]), H,
              <<"Abra Cadastros → Qualidade dos cadastros e corrija os registros listados."/utf8>>,
              #{entity => E, indicator => L, count => N}}
             || #{<<"entity">> := E, <<"plural">> := P, <<"items">> := Items} <- Es,
                #{<<"label">> := L, <<"count">> := N, <<"hint">> := H} <- Items, is_integer(N), N > 0];
        _ -> []
    end.

what(changed) -> <<"alterado"/utf8>>;
what(missing) -> <<"ausente"/utf8>>;
what(added) -> <<"a mais"/utf8>>.

%% ---------------------------------------------------------------- robustness (RF-033-05)

ops_sev(Sev) ->
    case demo() of true -> <<"info">>; false -> Sev end.

wal_archiving() ->
    {ok, R} = ana_db:one(
        "SELECT current_setting('archive_mode') AS mode, failed_count, "
        "  COALESCE(last_failed_time > COALESCE(last_archived_time, 'epoch'), false) AS failing "
        "FROM pg_stat_archiver", []),
    case R of
        #{<<"mode">> := <<"off">>} ->
            [{<<"wal_archiving">>, <<"off">>, ops_sev(<<"serious">>), <<"Arquivamento contínuo do banco desligado"/utf8>>,
              <<"Sem o WAL arquivado, só é possível voltar ao último backup completo: as transações depois dele se perdem."/utf8>>,
              <<"Ligue com scripts/backup.sh enable e agende scripts/backup.sh base diariamente."/utf8>>, #{}}];
        #{<<"failing">> := true, <<"failed_count">> := N} ->
            [{<<"wal_archiving">>, <<"failing">>, <<"serious">>, <<"Arquivamento do WAL falhando"/utf8>>,
              fmt("~b falha(s) registradas; a última depois do último sucesso.", [N]),
              <<"Verifique espaço e permissões do volume wal_archive (logs do banco)."/utf8>>, #{failed => N}}];
        _ -> []
    end.

base_backup() ->
    ops_age(<<"backup_base">>, ana_settings:get(checks_backup_max_hours), hour, <<"base_backup">>,
            <<"Cópia completa do banco"/utf8>>, <<"Agende scripts/backup.sh base (diário) e copie o volume para outro lugar."/utf8>>,
            <<"serious">>).

restore_test() ->
    ops_age(<<"restore_test">>, ana_settings:get(checks_restore_max_days) * 24, hour, <<"restore_test">>,
            <<"Teste de restauração"/utf8>>, <<"Rode scripts/restore-test.sh (mensal): backup que nunca foi restaurado não é garantia."/utf8>>,
            <<"warning">>).

ops_age(Kind, MaxHours, hour, Rule, What, Suggestion, Sev) ->
    {ok, R} = ana_db:one(
        "SELECT (SELECT max(at) FROM ana_system.ops_event WHERE kind = $1 AND ok) AS last_ok, "
        "  (SELECT ok FROM ana_system.ops_event WHERE kind = $1 ORDER BY at DESC LIMIT 1) AS last_result, "
        "  COALESCE(extract(epoch FROM now() - (SELECT max(at) FROM ana_system.ops_event WHERE kind = $1 AND ok)) / 3600, -1)::int AS hours",
        [Kind]),
    case R of
        #{<<"last_result">> := false} ->
            [{Rule, <<"failed">>, Sev, fmt("~ts: a última execução falhou", [What]), <<"Veja a saída do script que a executou."/utf8>>,
              Suggestion, #{}}];
        #{<<"hours">> := -1} ->
            [{Rule, <<"never">>, ops_sev(Sev), fmt("~ts nunca registrado(a)", [What]),
              <<"Nenhuma execução bem-sucedida registrada pelos scripts do produto."/utf8>>, Suggestion, #{}}];
        #{<<"hours">> := H} when H > MaxHours ->
            [{Rule, <<"old">>, ops_sev(Sev), fmt("~ts tem ~b hora(s)", [What, H]), fmt("Limite: ~b hora(s).", [MaxHours]),
              Suggestion, #{hours => H, limit_hours => MaxHours}}];
        _ -> []
    end.

dead_letters() ->
    {ok, Rows} = ana_db:rows("SELECT connector, count(*) AS n FROM integration.outbox WHERE status = 'dead' "
                             "GROUP BY connector ORDER BY connector", []),
    [{<<"dead_letters">>, C, <<"warning">>, fmt("~b mensagem(ns) parada(s) na fila de falhas do conector ~ts", [N, C]),
      <<"Mensagens que esgotaram as tentativas não chegam ao destino até alguém reenviar ou descartar."/utf8>>,
      <<"Corrija a causa (Administração → Integrações → Mensagens) e reenvie."/utf8>>, #{connector => C, count => N}}
     || #{<<"connector">> := C, <<"n">> := N} <- Rows].

open_breaker() ->
    [{<<"open_breaker">>, fmt("~p", [K]), <<"warning">>, fmt("Disjuntor aberto: ~p", [K]),
      <<"Chamadas a esse sistema externo estão sendo recusadas na hora por falhas seguidas."/utf8>>,
      <<"Verifique o sistema externo e a rede; o disjuntor tenta de novo sozinho."/utf8>>, #{}}
     || K <- ana_breaker:open_keys()].

%% Technical failures only: a business refusal (CUSTOMER_BLOCKED, INSUFFICIENT_STOCK…) is the
%% program doing its job.
error_rate() ->
    {ok, Rows} = ana_db:rows(
        "WITH e AS (SELECT program, status = 'timeout' OR (status = 'error' AND error->>'code' = ANY($1::text[])) AS bad "
        "           FROM ana_system.execution WHERE started_at > now() - interval '1 hour' AND status <> 'running') "
        "SELECT program, count(*) AS n, count(*) FILTER (WHERE bad) AS bad FROM e "
        "GROUP BY program HAVING count(*) >= 20 AND count(*) FILTER (WHERE bad) >= 0.2 * count(*) "
        "ORDER BY program LIMIT 50", [?TECHNICAL]),
    [{<<"error_rate">>, P, <<"warning">>, fmt("~ts teve falha técnica em ~b de ~b execuções na última hora", [P, B, N]),
      <<"Uma rotina que falha muito costuma indicar mudança de dados, integração fora do ar ou versão com defeito."/utf8>>,
      <<"Veja as execuções com erro (Auditoria → Execuções) e a versão atual do programa."/utf8>>, #{runs => N, errors => B}}
     || #{<<"program">> := P, <<"n">> := N, <<"bad">> := B} <- Rows].

files_disk() ->
    Dir = ana_config:text("ANA_FILES_DIR", "/var/lib/ana/files"),
    case disk_free(Dir) of
        {Total, Avail} when Total > 0, Avail * 10 < Total ->
            [{<<"files_disk">>, <<"files">>, <<"serious">>, fmt("Disco do repositório de arquivos com ~b% livre", [Avail * 100 div Total]),
              fmt("~ts: ~b MiB livres de ~b MiB.", [Dir, Avail div 1024, Total div 1024]),
              <<"Amplie o volume ou mova arquivos antigos; sem espaço, envios e PDFs falham."/utf8>>, #{}}];
        _ -> []
    end.

disk_free(Dir) ->
    case os:find_executable("df") of
        false -> undefined;
        Df ->
            Port = open_port({spawn_executable, Df}, [{args, ["-Pk", Dir]}, exit_status, stderr_to_stdout, binary]),
            case collect(Port, <<>>) of
                {0, Out} ->
                    case binary:split(Out, <<"\n">>, [global, trim_all]) of
                        [_, Line | _] ->
                            case string:lexemes(Line, " ") of
                                [_, T, _, A | _] -> {binary_to_integer(T), binary_to_integer(A)};
                                _ -> undefined
                            end;
                        _ -> undefined
                    end;
                _ -> undefined
            end
    end.

collect(Port, Acc) ->
    receive
        {Port, {data, D}} -> collect(Port, <<Acc/binary, D/binary>>);
        {Port, {exit_status, S}} -> {S, Acc}
    after 5000 -> catch port_close(Port), {timeout, Acc}
    end.

%% ---------------------------------------------------------------- performance (RF-033-06)

sample_probes() ->
    Probes = [{<<"db_roundtrip">>, fun() -> ana_db:one("SELECT 1 AS one", []) end},
              {<<"catalog_query">>, fun() -> ana_db:rows("SELECT name FROM ana_system.program WHERE active ORDER BY name LIMIT 200", []) end},
              {<<"python_exec">>, fun() -> ana_py:inspect(<<"def main():\n    return 1\n">>) end}],
    Samples = [{P, T / 1000} || {P, F} <- Probes, {T, _} <- [timer:tc(F)]],
    _ = ana_db:exec("INSERT INTO ana_system.perf_sample (probe, ms) SELECT * FROM unnest($1::text[], $2::text[]::real[])",
                    [[P || {P, _} <- Samples], [float_to_binary(Ms, [{decimals, 3}]) || {_, Ms} <- Samples]]),
    ok.

%% Spec 050 (T-050-03, P18): a screen that takes more than 1 s to open for 5 % of the people.
ui_slow_screen() ->
    [{<<"ui_slow_screen">>, S, <<"warning">>,
      fmt("Tela ~ts demora para abrir (p95 acima de ~ts ms)", [S, case P of null -> <<"5000">>; _ -> integer_to_binary(P) end]),
      fmt("Nos últimos 7 dias, ~b aberturas; o orçamento é 1 s para 95 % delas.", [N]),
      <<"Veja as chamadas da tela em Administração → Desempenho das telas e as consultas em Desempenho do SQL."/utf8>>,
      #{screen => S, samples => N, p95_ms => P}}
     || #{<<"screen">> := S, <<"samples">> := N, <<"p95_ms">> := P} <- ana_ui_perf:slow_screens()].

%% Last hour's p95 against the median of the hourly p95 of the previous 7 days.
probe_regression() ->
    Factor = ana_settings:get(checks_perf_factor_pct),
    {ok, Rows} = ana_db:rows(
        "WITH h AS (SELECT probe, date_trunc('hour', at) AS hr, percentile_cont(0.95) WITHIN GROUP (ORDER BY ms) AS p95 "
        "           FROM ana_system.perf_sample WHERE at > now() - interval '7 days' AND at < now() - interval '1 hour' "
        "           GROUP BY 1, 2), "
        "b AS (SELECT probe, percentile_cont(0.5) WITHIN GROUP (ORDER BY p95) AS base, count(*) AS hours FROM h GROUP BY 1), "
        "c AS (SELECT probe, percentile_cont(0.95) WITHIN GROUP (ORDER BY ms) AS cur, count(*) AS n "
        "      FROM ana_system.perf_sample WHERE at >= now() - interval '1 hour' GROUP BY 1) "
        "SELECT c.probe, b.base::float8 AS base, c.cur::float8 AS cur, c.n, b.hours FROM c JOIN b USING (probe) "
        "WHERE c.n >= 6 AND b.hours >= 6", []),
    [{<<"probe_regression">>, P, <<"warning">>, fmt("Sonda ~ts ficou mais lenta: p95 ~.1f ms (base ~.1f ms)", [P, Cur, Base]),
      fmt("Última hora contra a mediana dos p95 horários dos últimos 7 dias (~b hora(s) de base).", [Hours]),
      <<"Veja a Saúde (banco, pool Python), o Desempenho do SQL e mudanças recentes de versão ou carga."/utf8>>,
      #{base_ms => Base, p95_ms => Cur, samples => N}}
     || #{<<"probe">> := P, <<"base">> := Base, <<"cur">> := Cur, <<"n">> := N, <<"hours">> := Hours} <- Rows,
        regression(Base, Cur, Factor)].

%% CA-033-05: slower by the factor AND by at least 50 ms (sub-millisecond noise is not a regression).
-spec regression(number(), number(), number()) -> boolean().
regression(Base, Cur, FactorPct) ->
    Cur >= Base * FactorPct / 100 andalso Cur >= Base + 50.

%% ---------------------------------------------------------------- reading

summary() ->
    {ok, Counts} = ana_db:rows(
        "SELECT category, severity, count(*) AS n FROM ana_system.advice WHERE status = 'open' GROUP BY 1, 2", []),
    {ok, Runs} = ana_db:rows(
        "SELECT DISTINCT ON (task) substr(task, 8) AS category, started_at, finished_at, status, username "
        "FROM ana_system.task_run WHERE task LIKE 'checks.%' ORDER BY task, started_at DESC", []),
    {ok, #{categories => ?CATEGORIES, counts => Counts, runs => Runs}}.

%% Each message once (its latest), newest first: repeated notices never push an older critical one out of sight.
notices(OnlyUnread) ->
    ana_db:rows("SELECT id, kind, severity, message, link, read, created_at FROM ("
                "  SELECT DISTINCT ON (message) id, kind, severity, message, link, read, created_at FROM ana_system.notice "
                "  WHERE NOT $1 OR NOT read ORDER BY message, created_at DESC) n ORDER BY created_at DESC LIMIT 100", [OnlyUnread]).

%% Read once, read for every copy of the same message.
mark_notice(Id) ->
    ana_db:exec("UPDATE ana_system.notice SET read = true WHERE NOT read AND (id = $1 OR message = "
                "(SELECT message FROM ana_system.notice WHERE id = $1))", [Id]).

%% ---------------------------------------------------------------- helpers

str(D) when is_binary(D) -> D;
str(D) -> fmt("~p", [D]).

fmt(F, A) -> unicode:characters_to_binary(io_lib:format(F, A)).
