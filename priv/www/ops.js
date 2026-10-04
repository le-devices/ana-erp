// Home (RF-020-02) and Operation (RF-020-03): routines grouped by module, each
// with its form, result and the user's history on the same page.
"use strict";
(function () {
  const API = window.AnaApi;
  const { $, el, fmtDate, errorText, toast, table, pill } = window.AnaUI;
  const R = window.AnaRunner;

  const state = { routines: [], favorites: new Set(), current: null, filter: "" };

  async function loadRoutines() {
    state.routines = await API.routines();
    state.favorites = new Set(state.routines.filter((r) => r.favorite).map((r) => r.name));
    return state.routines;
  }

  const routine = (name) => state.routines.find((r) => r.name === name);
  const title = (r) => r.description || r.name;

  // ------------------------------------------------------------------ home
  async function home() {
    const main = $("#area-home");
    main.replaceChildren(el("p", { class: "muted", text: "Carregando…" }));
    const [routines, executions] = await Promise.all([loadRoutines(), API.executions(null, true).catch(() => [])]);
    const favs = routines.filter((r) => state.favorites.has(r.name));
    const recentNames = [...new Set(executions.map((x) => x.program))].filter((n) => routine(n)).slice(0, 8);

    const routineLink = (r) => el("li", {}, el("button", { class: "link", onclick: () => window.AnaStudio.go(`#/ops/${R.moduleOf(r.name)}/${r.name}`) },
      el("strong", { text: title(r) }), el("span", { class: "muted", text: ` ${R.moduleLabel(R.moduleOf(r.name))}${r.command ? " · " + r.command : ""}` })));

    main.replaceChildren(
      el("h1", { text: `Olá, ${window.AnaStudio.user().name || window.AnaStudio.user().username}` }),
      el("div", { class: "cards" },
        el("section", { class: "card" }, el("h2", { text: "Favoritos" }),
          favs.length ? el("ul", { class: "link-list" }, favs.map(routineLink))
                      : el("p", { class: "muted", text: "Fixe rotinas com ☆ na área de Operação para vê-las aqui." })),
        el("section", { class: "card" }, el("h2", { text: "Usadas recentemente" }),
          recentNames.length ? el("ul", { class: "link-list" }, recentNames.map((n) => routineLink(routine(n))))
                             : el("p", { class: "muted", text: "Nada ainda." })),
        el("section", { class: "card wide", id: "home-warnings", hidden: true }, el("h2", { text: "Avisos das minhas rotinas agendadas" }), el("div")),
        el("section", { class: "card wide" }, el("h2", { text: "Minhas últimas execuções" }),
          table([
            { label: "Quando", value: (x) => fmtDate(x.started_at) },
            { label: "Rotina", value: (x) => (routine(x.program) ? title(routine(x.program)) : x.program) },
            { label: "Status", value: (x) => el("span", { class: "status-" + x.status, text: x.status + (x.error ? ` (${x.error})` : "") }) },
            { label: "ms", value: (x) => x.duration_ms ?? "…", class: "num" },
          ], executions.slice(0, 10), { empty: "Nenhuma execução ainda.",
            onRow: (x) => routine(x.program) && window.AnaStudio.go(`#/ops/${R.moduleOf(x.program)}/${x.program}`) }))));
    const warn = $("#home-warnings");
    if (warn && window.AnaScheduler) {
      const n = await window.AnaScheduler.notifications(warn.lastChild, true);
      warn.hidden = !n;
    }
  }

  // ------------------------------------------------------------------ operation
  async function ops(module, name, query = {}) {
    if (!state.routines.length) await loadRoutines();
    drawNav(module, name);
    if (name && routine(name)) return openRoutine(routine(name), query);
    const list = state.routines.filter((r) => !module || R.moduleOf(r.name) === module);
    $("#ops-main").replaceChildren(
      el("h1", { text: module ? R.moduleLabel(module) : "Operação" }),
      el("p", { class: "lead", text: module ? "Rotinas disponíveis neste módulo." : "Escolha um módulo ou uma rotina à esquerda." }),
      el("div", { class: "routine-grid" }, list.map((r) => el("button", { class: "routine-card",
        onclick: () => window.AnaStudio.go(`#/ops/${R.moduleOf(r.name)}/${r.name}`) },
        el("strong", { text: title(r) }), el("span", { class: "muted", text: r.command ? `comando: ${r.command}` : r.name })))));
  }

  function drawNav(activeModule, activeName) {
    const nav = $("#ops-nav");
    const filter = el("input", { placeholder: "Filtrar rotinas…", value: state.filter, "aria-label": "Filtrar rotinas" });
    filter.addEventListener("input", () => { state.filter = filter.value; drawNav(activeModule, activeName); filterFocus(); });
    const groups = {};
    const f = state.filter.toLowerCase();
    for (const r of state.routines) {
      if (f && !(title(r).toLowerCase().includes(f) || r.name.includes(f) || (r.command || "").includes(f))) continue;
      (groups[R.moduleOf(r.name)] ||= []).push(r);
    }
    const sections = Object.keys(groups).sort((a, b) => R.moduleLabel(a).localeCompare(R.moduleLabel(b))).map((m) =>
      el("div", { class: "nav-module" },
        el("button", { class: "nav-group-link" + (m === activeModule && !activeName ? " active" : ""), text: R.moduleLabel(m),
                       onclick: () => window.AnaStudio.go(`#/ops/${m}`) }),
        groups[m].map((r) => el("button", { class: "nav-link" + (r.name === activeName ? " active" : ""),
          title: r.name, onclick: () => window.AnaStudio.go(`#/ops/${m}/${r.name}`) },
          state.favorites.has(r.name) ? "★ " : "", title(r)))));
    nav.replaceChildren(filter, ...sections);
  }

  function filterFocus() {
    const i = $("#ops-nav input");
    if (i) { i.focus(); i.setSelectionRange(i.value.length, i.value.length); }
  }

  /** Address of a routine with parameters (RF-020-12). */
  function routineHash(program, params = {}) {
    const q = new URLSearchParams();
    for (const [k, v] of Object.entries(params)) if (v !== null && v !== undefined) q.set(k, typeof v === "object" ? JSON.stringify(v) : String(v));
    const qs = q.toString();
    return `#/ops/${R.moduleOf(program)}/${program}${qs ? "?" + qs : ""}`;
  }

  async function openRoutine(r, query = {}) {
    state.current = r;
    const fav = el("button", { class: "quiet star", title: "Fixar nos favoritos", text: state.favorites.has(r.name) ? "★" : "☆" });
    fav.addEventListener("click", async () => {
      try {
        if (state.favorites.has(r.name)) { await API.unfavorite(r.name); state.favorites.delete(r.name); }
        else { await API.favorite(r.name); state.favorites.add(r.name); }
        fav.textContent = state.favorites.has(r.name) ? "★" : "☆";
        drawNav(R.moduleOf(r.name), r.name);
      } catch (e) { toast(errorText(e), true); }
    });
    const output = el("div", { class: "output result-box" });
    const resultJson = el("pre", { class: "json" });
    const status = el("span", { class: "run-state" });
    const history = el("div");
    const detail = el("pre", { class: "preview json" });
    const form = R.paramsForm(r.params, { submitLabel: "▶ Executar", onSubmit: () => run(), initial: query });
    // Actions drawn by the program (spec 021): run in place, open another routine, refresh this one.
    const ctx = {
      run: (program, params) => API.run(program, { params }),
      open: (program, params) => window.AnaStudio.go(routineHash(program, params)),
      refresh: () => run(true),
    };

    async function run(quiet) {
      let params;
      try { params = form.read(); } catch (e) { toast("Parâmetros inválidos: " + e.message, true); return; }
      const scroll = quiet ? document.scrollingElement && document.scrollingElement.scrollTop : null;
      output.replaceChildren();
      resultJson.textContent = "";
      status.textContent = "executando…";
      status.className = "run-state";
      try {
        const res = await API.run(r.name, { params });
        const events = res.events || (res.error && res.error.events) || [];
        for (const ev of events) if (ev.type === "output") R.drawOutput(output, ev, ctx);
        if (scroll !== null && document.scrollingElement) document.scrollingElement.scrollTop = scroll;
        if (res.error) {
          status.textContent = `erro: ${res.error.code}`;
          status.className = "run-state error";
          output.append(el("div", { class: "end error", text: `✘ ${res.error.code}: ${res.error.message || ""}` }));
        } else {
          status.textContent = `concluído em ${res.duration_ms} ms`;
          status.className = "run-state ok";
          resultJson.textContent = JSON.stringify(res.result, null, 2);
        }
      } catch (e) {
        status.textContent = "falhou";
        status.className = "run-state error";
        output.append(el("div", { class: "end error", text: errorText(e) }));
      }
      loadHistory();
    }

    async function loadHistory() {
      const rows = await API.executions(r.name, true).catch(() => []);
      history.replaceChildren(table([
        { label: "Quando", value: (x) => fmtDate(x.started_at) },
        { label: "Status", value: (x) => el("span", { class: "status-" + x.status, text: x.status + (x.error ? ` (${x.error})` : "") }) },
        { label: "ms", value: (x) => x.duration_ms ?? "…", class: "num" },
      ], rows.slice(0, 15), { empty: "Você ainda não executou esta rotina.",
        onRow: async (x) => { detail.textContent = JSON.stringify(await API.execution(x.id), null, 2); } }));
    }

    $("#ops-main").replaceChildren(
      el("div", { class: "page-header" },
        el("div", {}, el("div", { class: "breadcrumb", text: R.moduleLabel(R.moduleOf(r.name)) }),
          el("h1", {}, title(r), " ", fav)),
        el("div", { class: "muted", text: `${r.name}${r.command ? " · comando " + r.command : ""}${r.exposed ? " · disponível para integração" : ""}` })),
      r.docs ? el("p", { class: "docs", text: r.docs }) : null,
      el("div", { class: "routine-layout" },
        el("section", { class: "card" }, el("h2", { text: "Parâmetros" }), form.node),
        el("section", { class: "card" }, el("h2", {}, "Resultado ", status), output,
          el("details", {}, el("summary", { text: "dados retornados (JSON)" }), resultJson))),
      el("div", { class: "routine-layout" },
        el("section", { class: "card" }, el("h2", { text: "Minhas execuções desta rotina" }), history),
        el("section", { class: "card" }, el("h2", { text: "Detalhe" }), detail)));
    loadHistory();
    if (Object.keys(query).length) run();
  }

  window.AnaOps = { home, ops, loadRoutines, routineHash, routines: () => state.routines };
})();
