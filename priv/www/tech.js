// SPDX-FileCopyrightText: 2026 André Luis Pereira dos Santos
// SPDX-License-Identifier: AGPL-3.0-or-later
// Technical center (spec 077, T-077-03, D1–D4, D7–D9, D14): the technical work in tabs — Agora, Rotina, Capacidade,
// Mudanças, Segurança técnica, Registro — plus the deeper layers: Roteiros, Parâmetros and Console. Every item says
// what, why, what effect and what to do; the recommended action is the main button, with its consequence before
// running; the detail opens the section of the Administration. The command palette finds every button of this screen.
(function () {
  "use strict";
  const { el, toast, table, pill, confirmDialog, fmtDate } = window.AnaUI;
  const API = window.AnaApi;
  const TABS = [["now", "Agora"], ["routine", "Rotina"], ["capacity", "Capacidade"], ["changes", "Mudanças"],
                ["security", "Segurança técnica"], ["log", "Registro"], ["runbooks", "Roteiros"], ["parameters", "Parâmetros"],
                ["console", "Console"]];
  const SEV = { critical: ["■ crítico", "off"], serious: ["▲ grave", "off"], warning: ["▲ atenção", "warn"],
                info: ["● informação", ""], ok: ["● em dia", "ok"] };
  const APPLIES = { now: "na hora", next_run: "na próxima execução", restart: "ao reiniciar" };
  const ORIGIN = { product: "padrão do produto", server: "servidor", installation: "instalação", node: "este nó" };
  let catalog = null;
  let state = { tab: "now", main: null, header: null, guard: null };

  async function actions() {
    if (!catalog) catalog = new Map((await API.request("GET", "/api/tech/actions")).map((a) => [a.code, a]));
    return catalog;
  }

  function sevPill(s) { const [t, c] = SEV[s] || [s, ""]; return pill(t, c); }

  async function render(main, h) {
    state = { ...state, main, header: h.header, guard: h.guard };
    await show(state.tab);
  }

  const ADMIN_ONLY = new Set(["parameters", "console"]);
  const isAdmin = () => ((window.AnaStudio && window.AnaStudio.user()) || {}).role === "admin";

  function tabs() {
    return el("div", { class: "tabs", role: "tablist" }, TABS.filter(([k]) => isAdmin() || !ADMIN_ONLY.has(k)).map(([k, label]) =>
      el("button", { type: "button", role: "tab", "aria-selected": String(k === state.tab), class: k === state.tab ? "active" : "",
                     text: label, onclick: () => state.guard(() => show(k)) })));
  }

  async function show(tab) {
    state.tab = tab;
    const body = el("div", { class: "tech-body" }, el("p", { class: "muted", text: "Carregando…" }));
    state.main.replaceChildren(...state.header("Central técnica",
      "O que precisa de atenção, o que é feito sempre, o que vem pela frente, o que mudou — com o próximo passo em cada item."),
      tabs(), body);
    const view = { runbooks: runbooksView, parameters: parametersView, console: consoleView }[tab] || itemsView;
    body.replaceChildren(...(await view(tab)));
  }

  // ------------------------------------------------------------------ items (the six tabs of the work)
  async function itemsView(tab) {
    const [r, cat] = await Promise.all([API.request("GET", `/api/tech/central/${tab}`), actions()]);
    const out = [];
    if (r.headline) out.push(el("div", { class: "tech-headline " + (r.ok ? "ok" : "bad") },
      sevPill(r.ok ? "ok" : (r.items[0] || {}).severity), el("strong", { text: " " + r.headline })));
    if (!r.items.length) out.push(el("p", { class: "muted", text: { now: "Nada pede atenção agora.", log: "Nenhuma ação técnica registrada ainda." }[tab] || "Nada a mostrar nesta aba." }));
    for (const it of r.items) out.push(itemCard(it, cat));
    return out;
  }

  function itemCard(it, cat) {
    const buttons = [];
    if (it.action && cat.get(it.action.code)) {
      const a = cat.get(it.action.code);
      buttons.push(el("button", { type: "button", class: "primary", text: a.name, disabled: !a.allowed,
                                  title: a.allowed ? a.effect : "sem permissão para esta ação",
                                  onclick: () => state.guard(() => runAction(a, it.action.params || {})) }));
    }
    if (it.runbook) buttons.push(el("button", { type: "button", text: "Seguir o roteiro",
                                                onclick: () => state.guard(() => startRunbook(it.runbook)) }));
    if (it.request && !it.mine) {
      buttons.push(el("button", { type: "button", class: "primary", text: "Aprovar",
                                  onclick: () => state.guard(() => decide(it.request, "approve")) }));
      buttons.push(el("button", { type: "button", text: "Recusar", onclick: () => state.guard(() => decide(it.request, "reject")) }));
    }
    if (it.run && state.tab === "now") buttons.push(el("button", { type: "button", text: "Abrir o roteiro",
                                                                    onclick: () => state.guard(() => openRun(it.run)) }));
    if (it.detail && it.detail !== "#/admin/central") buttons.push(el("a", { href: it.detail, text: "Ver detalhe" }));
    return el("div", { class: "tech-item " + it.severity },
      el("div", { class: "tech-item-head" }, sevPill(it.severity), el("strong", { text: " " + it.what })),
      it.why ? el("div", { class: "muted", text: "Por quê: " + it.why }) : null,
      it.effect ? el("div", { text: "Efeito: " + it.effect }) : null,
      it.at ? el("div", { class: "muted small", text: fmtDate(it.at) }) : null,
      buttons.length ? el("div", { class: "row-buttons" }, buttons) : null);
  }

  async function runAction(a, params) {
    if (a.risk !== "low" && !(await confirmDialog(`${a.effect}. Quem é afetado: ${a.impact}.` +
        (a.risk === "high" ? " Risco alto: outra pessoa precisa aprovar." : ""), { title: a.name, ok: a.name }))) return;
    const r = await API.request("POST", `/api/tech/actions/${a.code}`, { params, confirmed: true });
    toast(r.pending_approval ? "Pedido feito: aguarda a aprovação de outra pessoa." : `${a.name}: feito.`);
    await show(state.tab);
  }

  async function decide(id, what) {
    let body = {};
    if (what === "reject") {
      const reason = window.prompt("Motivo da recusa:");
      if (!reason) return;
      body = { reason };
    }
    await API.request("POST", `/api/tech/requests/${id}/${what}`, body);
    toast(what === "approve" ? "Aprovado e executado." : "Pedido recusado.");
    await show(state.tab);
  }

  // ------------------------------------------------------------------ runbooks
  async function runbooksView() {
    const [books, runs] = await Promise.all([API.request("GET", "/api/tech/runbooks"), API.request("GET", "/api/tech/runbooks/runs")]);
    return [
      runs.length ? el("h3", { text: "Em andamento" }) : null,
      runs.length ? table([{ label: "Roteiro", value: (r) => r.name }, { label: "Situação", value: (r) => r.status },
                           { label: "Passo", value: (r) => r.step, class: "num" }, { label: "Conduzido por", value: (r) => r.owner }],
                          runs, { onRow: (r) => state.guard(() => openRun(r.id)), title: "Roteiros em andamento" }) : null,
      el("h3", { text: "Roteiros" }),
      ...books.map((b) => el("div", { class: "tech-item" }, el("strong", { text: b.name }),
        el("div", { class: "muted", text: b.when_to_use + ` · ${b.steps.length} passo(s)` }),
        el("div", { class: "row-buttons" }, el("button", { type: "button", class: "primary", text: `Seguir: ${b.name}`,
                                                          onclick: () => state.guard(() => startRunbook(b.code)) }))))];
  }

  async function startRunbook(code) {
    const r = await API.request("POST", `/api/tech/runbooks/${code}/start`, {});
    state.tab = "runbooks";
    await showRun(r);
  }

  async function openRun(id) { state.tab = "runbooks"; await showRun(await API.request("GET", `/api/tech/runbooks/runs/${id}`)); }

  async function showRun(r) {
    const body = el("div", { class: "tech-body" });
    state.main.replaceChildren(...state.header("Roteiro: " + r.name, "As verificações rodam sozinhas; você decide as ações e confirma as instruções."),
                               tabs(), body);
    const done = new Map((r.log || []).map((l) => [l.step, l]));
    const steps = r.steps.map((s, i) => {
      const n = i + 1;
      const l = done.get(n);
      const status = l ? (l.ok === true ? "ok" : l.ok === false ? "warning" : "info") : n === r.step && r.status !== "done" ? "info" : "";
      return el("li", { class: "tech-step " + (n === r.step ? "current" : "") },
        status ? sevPill(status) : null, el("span", { text: ` ${n}. ${s.text}` }),
        l ? el("div", { class: "muted small", text: `${l.result} · ${l.ms} ms` }) : null);
    });
    const act = (body2) => state.guard(async () => showRun(await API.request("POST", `/api/tech/runbooks/runs/${r.id}/advance`, body2)));
    const buttons = [];
    if (r.status === "running" && r.waiting_for === "action") buttons.push(el("button", { type: "button", class: "primary", text: "Executar a ação e seguir", onclick: () => act({ confirm: true }) }));
    if (r.status === "running" && r.waiting_for === "instruction") buttons.push(el("button", { type: "button", class: "primary", text: "Feito — seguir", onclick: () => act({ confirm: true }) }));
    if (r.status === "running" && !r.waiting_for) buttons.push(el("button", { type: "button", text: "Seguir até a próxima decisão", onclick: () => act({}) }));
    if (r.status === "waiting") buttons.push(el("button", { type: "button", text: "Conferir a aprovação", onclick: () => act({}) }));
    if (r.status === "running") buttons.push(el("button", { type: "button", text: "Pausar", onclick: () => state.guard(async () => showRun(await API.request("POST", `/api/tech/runbooks/runs/${r.id}/pause`, {}))) }));
    if (r.status === "paused") buttons.push(el("button", { type: "button", text: "Retomar", onclick: () => state.guard(async () => showRun(await API.request("POST", `/api/tech/runbooks/runs/${r.id}/resume`, {}))) }));
    if (["running", "paused", "waiting"].includes(r.status)) buttons.push(el("button", { type: "button", text: "Entregar a outra pessoa", onclick: () => state.guard(async () => {
      const to = window.prompt("Usuário que vai conduzir o roteiro:");
      if (to) showRun(await API.request("POST", `/api/tech/runbooks/runs/${r.id}/hand-over`, { to }));
    }) }));
    const label = { running: "em andamento", paused: "pausado", waiting: "aguardando a segunda pessoa", done: "concluído", stopped: "parado: peça ajuda (pacote de diagnóstico ao suporte)" }[r.status];
    body.replaceChildren(el("p", {}, sevPill(r.status === "done" ? "ok" : r.status === "stopped" ? "serious" : "info"),
                                    el("strong", { text: ` ${label} — conduzido por ${r.owner}` })),
                         el("ol", { class: "tech-steps" }, steps), el("div", { class: "row-buttons" }, buttons));
  }

  // ------------------------------------------------------------------ parameters
  async function parametersView() {
    const l = await API.request("GET", "/api/tech/parameters");
    const edit = (p) => state.guard(async () => {
      const value = window.prompt(`${p.label}\nQuando mudar: ${p.when_to_change || "—"}\nVale ${APPLIES[p.applies]}. Valor (${p.min}–${p.max}; vazio volta ao padrão ${p.default}):`, p.value);
      if (value === null) return;
      const reason = window.prompt("Motivo da mudança:");
      if (!reason) return;
      const minutes = window.prompt("Só por quantos minutos? (vazio = sem prazo)", "");
      const r = await API.request("PUT", `/api/tech/parameters/${p.key}`, { value: value === "" ? null : Number(value), reason,
        minutes: minutes ? Number(minutes) : null, confirmed: true });
      toast(r.pending_approval ? "Aguarda a aprovação de outra pessoa." : "Parâmetro mudado.");
      await show("parameters");
    });
    return [
      el("p", { class: "muted", text: `Valores em uso no nó ${l.node}. Os alterados vêm primeiro; cada mudança pede motivo e fica no histórico.` }),
      table([{ label: "Parâmetro", value: (p) => p.label }, { label: "Valor", value: (p) => String(p.value), class: "num" },
             { label: "De onde vem", value: (p) => ORIGIN[p.origin] || p.origin + (p.temporary ? " (temporária)" : "") },
             { label: "Vale", value: (p) => APPLIES[p.applies] || p.applies }, { label: "Risco", value: (p) => p.risk }],
            l.parameters, { onRow: edit, title: "Parâmetros técnicos", screen: "tech.parameters" }),
      el("h3", { text: "Definidos no servidor" }),
      table([{ label: "Variável", value: (s) => s.env }, { label: "O que é", value: (s) => s.label },
             { label: "Valor", value: (s) => s.value === null ? "não definido" : s.value }, { label: "Como mudar", value: (s) => s.how }],
            l.server, { title: "Parâmetros do servidor", screen: "tech.server" })];
  }

  // ------------------------------------------------------------------ console
  async function consoleView() {
    const queries = await API.request("GET", "/api/tech/console/queries");
    const out = el("div", {});
    const showResult = (r) => out.replaceChildren(table(r.columns.map((c, i) => ({ label: c.name + (c.masked ? " (mascarada)" : ""), value: (row) => row[i] })),
                                                        r.rows, { title: "Resultado", screen: "tech.console" }),
                                                  r.truncated ? el("p", { class: "muted", text: "Mostrando as primeiras 500 linhas." }) : null);
    const sql = el("textarea", { rows: 4, "aria-label": "SQL somente leitura", placeholder: "SELECT … (o console só lê: 5 s, 500 linhas)" });
    const run = (explain) => state.guard(async () => showResult(await API.request("POST", "/api/tech/console/sql", { sql: sql.value, explain })));
    return [
      el("h3", { text: "Consultas prontas" }),
      el("div", { class: "row-buttons" }, queries.map((q) => el("button", { type: "button", text: q.name, title: q.description,
        onclick: () => state.guard(async () => showResult(await API.request("POST", `/api/tech/console/queries/${q.code}/run`, { params: {} }))) }))),
      el("h3", { text: "SQL somente leitura" }),
      el("label", {}, "Consulta", sql),
      el("div", { class: "row-buttons" }, el("button", { type: "button", class: "primary", text: "Consultar", onclick: () => run(false) }),
         el("button", { type: "button", text: "Ver o plano", onclick: () => run(true) }),
         el("button", { type: "button", text: "Registros deste nó", onclick: () => state.guard(async () => {
           const r = await API.request("GET", "/api/tech/console/logs?level=warning&limit=200");
           out.replaceChildren(table([{ label: "Nível", value: (x) => x.level }, { label: "Subsistema", value: (x) => x.subsystem },
                                      { label: "Mensagem", value: (x) => x.text }], r.lines, { title: "Registros", screen: "tech.logs",
                                      empty: "Nenhum aviso ou erro recente neste nó." }));
         }) })),
      out];
  }

  window.AnaTech = { render };
})();
