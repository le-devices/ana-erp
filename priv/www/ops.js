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
    let [routines, executions] = await Promise.all([loadRoutines(), API.executions(null, true).catch(() => []),
                                                    window.AnaCategories.load()]);
    const favs = routines.filter((r) => state.favorites.has(r.name));
    const recentNames = [...new Set(executions.map((x) => x.program))].filter((n) => routine(n)).slice(0, 8);
    // Only routines of the menu: helpers (lookups of forms, libraries) are not something the user ran.
    executions = executions.filter((x) => routine(x.program));

    const user = window.AnaStudio.user();
    main.replaceChildren(
      el("div", { class: "home-head" },
        el("h1", { text: `Olá, ${user.name || user.username}` }),
        el("p", { class: "lead", text: "Suas rotinas favoritas, suas categorias e as da empresa, e as usadas há pouco. Fixe com ☆ ou use “Copiar para categoria…” na rotina." })),
      el("section", { class: "card wide", id: "home-tasks", hidden: true }),
      tileGroup("Favoritas", favs, "Fixe rotinas com ☆ para vê-las aqui."),
      // RF-020-22: the user's and the company's categories, with their shortcuts (drag to reorder and move).
      ...window.AnaCategories.sections(routine, shortcutTile, () => home()),
      tileGroup("Usadas recentemente", recentNames.map(routine), "Nada ainda."),
      el("section", { class: "card wide", id: "home-warnings", hidden: true }, el("h2", { text: "Avisos das minhas rotinas agendadas" }), el("div")),
      el("section", { class: "card wide table-card" }, el("h2", {}, "Minhas últimas execuções ", el("span", { class: "table-count", text: `(${Math.min(executions.length, 10)})` })),
        table([
          { label: "Quando", value: (x) => fmtDate(x.started_at) },
          { label: "Rotina", value: (x) => (routine(x.program) ? title(routine(x.program)) : x.program) },
          { label: "Situação", value: (x) => el("span", { class: "status-chip status-" + x.status, text: STATUS_LABEL[x.status] || x.status }) },
          { label: "Duração (ms)", value: (x) => x.duration_ms ?? "…", class: "num" },
        ], executions.slice(0, 10), { empty: "Nenhuma execução ainda.",
          onRow: (x) => routine(x.program) && window.AnaStudio.go(`#/ops/${R.moduleOf(x.program)}/${x.program}`) })));
    if (window.AnaBpm && $("#home-tasks")) window.AnaBpm.homeWidget($("#home-tasks"));    // spec 039: Minhas tarefas
    const warn = $("#home-warnings");
    if (warn && window.AnaScheduler) {
      const n = await window.AnaScheduler.notifications(warn.lastChild, true);
      warn.hidden = !n;
    }
  }

  const STATUS_LABEL = { success: "concluída", error: "erro", timeout: "tempo esgotado", aborted: "interrompida", running: "executando" };

  /** Launch tile of a routine (spec 029, RF-029-06); with `select`, a check box to pick it (RF-020-21). */
  function tile(r, select) {
    const t = el("button", { class: "tile", title: r.name, onclick: () => window.AnaStudio.go(`#/ops/${R.moduleOf(r.name)}/${r.name}`) },
      el("span", { class: "tile-title", text: title(r) }),
      el("span", { class: "tile-sub", text: `${R.areaOf(r)} · ${R.categoryOf(r)}` }),
      el("span", { class: "tile-foot" }, window.AnaUI.icon("chart", 20),
        el("span", { class: "tile-cmd", text: r.command || "" })));
    if (!select) return t;
    const box = el("input", { type: "checkbox", "aria-label": `Selecionar ${title(r)}` });
    box.checked = select.has(r.name);
    box.addEventListener("change", () => { box.checked ? select.add(r.name) : select.delete(r.name); select.onchange(); });
    return el("div", { class: "tile-wrap" + (box.checked ? " picked" : "") }, t, el("label", { class: "tile-pick", title: "Selecionar" }, box));
  }

  /** Tile of a shortcut in a category: its own name and pre-filled parameters (RF-020-21). */
  function shortcutTile(s, r) {
    const hasParams = s.params && Object.keys(s.params).length;
    return el("button", { class: "tile", title: r.name, onclick: () => window.AnaStudio.go(routineHash(s.program, s.params || {})) },
      el("span", { class: "tile-title", text: s.label || title(r) }),
      el("span", { class: "tile-sub", text: hasParams ? "com parâmetros salvos" : `${R.areaOf(r)} · ${R.categoryOf(r)}` }),
      el("span", { class: "tile-foot" }, window.AnaUI.icon("chart", 20), el("span", { class: "tile-cmd", text: r.command || "" })));
  }

  function tileGroup(name, routines, empty) {
    return el("section", { class: "tile-group" }, el("h2", { text: name }),
      routines.length ? el("div", { class: "tiles" }, routines.map((r) => tile(r))) : el("p", { class: "muted", text: empty }));
  }

  let routesCache = null;
  async function sheetFor(program, query) {
    if (!routesCache) {
      try { routesCache = (await API.run("master.describe", { params: {} })).result.routes || []; } catch (_) { routesCache = []; }
    }
    const r = routesCache.find((x) => x.program === program);
    if (!r) return null;
    const key = query[r.key_param];
    const enc = encodeURIComponent;
    if (key) return `#/master/${r.entity}/${enc(key)}${r.tab ? "?aba=" + enc(r.tab) : ""}`;
    return r.tab ? `#/master/${r.entity}` : `#/master/${r.entity}/novo`;
  }

  // ------------------------------------------------------------------ operation
  async function ops(module, name, query = {}) {
    if (!state.routines.length) await loadRoutines();
    drawNav(module, name);
    runCurrent = null;
    // T-040-11b: a routine that writes master data opens the standard sheet (same checks, history and approvals);
    // "?_rotina=1" keeps its own form.
    if (name && query._rotina !== "1") {
      const to = await sheetFor(name, query);
      if (to) { window.history.replaceState(null, "", to); window.AnaStudio.go(to); return; }
    }
    if (name && routine(name)) return openRoutine(routine(name), query);
    await window.AnaCategories.load();
    // "#/ops/~Área" lists one business area; a namespace (old addresses) lists its area too.
    const area = module ? (module.startsWith("~") ? decodeURIComponent(module.slice(1)) : R.moduleLabel(module)) : null;
    const list = state.routines.filter((r) => !area || R.areaOf(r) === area);
    const select = new Set();
    const bar = el("div", { class: "pick-bar", hidden: true });
    select.onchange = () => {
      bar.hidden = !select.size;
      bar.replaceChildren(el("strong", { text: `${select.size} selecionada(s)` }),
        el("button", { type: "button", class: "primary", text: "Copiar para categoria…", onclick: async () => {
          if (await window.AnaCategories.copyDialog([...select])) { select.clear(); ops(module); }
        } }),
        el("button", { type: "button", class: "quiet", text: "Limpar seleção", onclick: () => ops(module) }));
      for (const w of $("#ops-main").querySelectorAll(".tile-wrap")) w.classList.toggle("picked", !!w.querySelector("input:checked"));
    };
    // Area → category → routines (RF-020-19), areas in the business order.
    const byArea = new Map();
    for (const r of list) {
      const a = R.areaOf(r), c = R.categoryOf(r);
      if (!byArea.has(a)) byArea.set(a, new Map());
      if (!byArea.get(a).has(c)) byArea.get(a).set(c, []);
      byArea.get(a).get(c).push(r);
    }
    const areas = [...byArea.keys()].sort((a, b) => R.areaRank(a) - R.areaRank(b) || a.localeCompare(b));
    $("#ops-main").replaceChildren(
      el("section", { class: "page-band" },
        el("div", { class: "breadcrumb", text: "Operação" }),
        el("h1", { text: area || "Todas as rotinas" }),
        el("p", { class: "lead", text: area ? `${list.length} rotina(s) nesta área.`
          : "Rotinas por área do negócio. Marque uma ou mais e use “Copiar para categoria…” para montar as suas." })),
      el("div", { class: "page-body" },
        bar,
        area ? null : el("div", { class: "cat-sections" }, ...window.AnaCategories.sections(routine, shortcutTile, () => ops(module))),
        ...areas.map((a) => el("section", { class: "area-block" },
          area ? null : el("h2", { class: "area-title" }, el("a", { href: `#/ops/~${encodeURIComponent(a)}`, text: a })),
          ...[...byArea.get(a).keys()].sort((x, y) => x.localeCompare(y)).map((c) => el("div", { class: "tile-group" },
            el("h3", { class: "cat-title", text: c }),
            el("div", { class: "tiles routine-grid" }, byArea.get(a).get(c).map((r) => tile(r, select)))))))));
  }

  function drawNav(activeModule, activeName) {
    const nav = $("#ops-nav");
    const filter = el("input", { placeholder: "Filtrar rotinas…", value: state.filter, "aria-label": "Filtrar rotinas" });
    filter.addEventListener("input", () => { state.filter = filter.value; drawNav(activeModule, activeName); filterFocus(); });
    const groups = {};
    const f = state.filter.toLowerCase();
    for (const r of state.routines) {
      if (f && !(title(r).toLowerCase().includes(f) || r.name.includes(f) || (r.command || "").includes(f)
                 || R.categoryOf(r).toLowerCase().includes(f))) continue;
      (groups[R.areaOf(r)] ||= []).push(r);
    }
    const activeArea = activeModule ? (activeModule.startsWith("~") ? decodeURIComponent(activeModule.slice(1)) : R.moduleLabel(activeModule)) : null;
    const sections = Object.keys(groups).sort((a, b) => R.areaRank(a) - R.areaRank(b) || a.localeCompare(b)).map((a) =>
      el("div", { class: "nav-module" },
        el("button", { class: "nav-group-link" + (a === activeArea && !activeName ? " active" : ""), text: a,
                       onclick: () => window.AnaStudio.go(`#/ops/~${encodeURIComponent(a)}`) }),
        groups[a].sort((x, y) => R.categoryOf(x).localeCompare(R.categoryOf(y)) || title(x).localeCompare(title(y))).map((r) =>
          el("button", { class: "nav-link" + (r.name === activeName ? " active" : ""),
            title: `${R.categoryOf(r)} — ${title(r)}`, onclick: () => window.AnaStudio.go(`#/ops/${R.moduleOf(r.name)}/${r.name}`) },
            state.favorites.has(r.name) ? "★ " : "", title(r)))));
    nav.replaceChildren(filter, ...sections);
  }

  function filterFocus() {
    const i = $("#ops-nav input");
    if (i) { i.focus(); i.setSelectionRange(i.value.length, i.value.length); }
  }

  /** Address of a routine with parameters (RF-020-12). Opening it runs the routine,
   *  except with `_form=1` (selection screen, as when coming back to it). */
  function routineHash(program, params = {}, extra = {}) {
    const q = new URLSearchParams();
    for (const [k, v] of Object.entries({ ...params, ...extra })) {
      if (v !== null && v !== undefined && v !== "") q.set(k, typeof v === "object" ? JSON.stringify(v) : String(v));
    }
    const qs = q.toString();
    return `#/ops/${R.moduleOf(program)}/${program}${qs ? "?" + qs : ""}`;
  }

  // Last values used per routine (per viewer convenience, like the last selection in a report).
  const lastKey = (name) => "ana.params." + name;
  function lastParams(name) {
    try { return JSON.parse(localStorage.getItem(lastKey(name)) || "{}"); } catch (_) { return {}; }
  }
  function rememberParams(name, params) {
    try { localStorage.setItem(lastKey(name), JSON.stringify(params)); } catch (_) { /* storage blocked */ }
  }

  // Options of fields with "lookup" (cached while the screen is open).
  const lookupCache = new Map();
  function lookup(program, params) {
    const key = program + JSON.stringify(params);
    if (!lookupCache.has(key)) {
      lookupCache.set(key, API.run(program, { params }).then((res) => (res.error ? [] : res.result))
        .catch(() => { lookupCache.delete(key); return []; }));
    }
    return lookupCache.get(key);
  }

  let runCurrent = null;       // F8 runs the routine on screen
  let runSimulation = null;    // F9 simulates a definition (RF-020-13)

  async function openRoutine(r, query = {}) {
    state.current = r;
    lookupCache.clear();
    const formOnly = query._form === "1";
    const given = Object.fromEntries(Object.entries(query).filter(([k]) => !k.startsWith("_")));
    const initial = Object.keys(given).length ? given : lastParams(r.name);
    const fav = el("button", { class: "quiet star", title: "Fixar nos favoritos", text: state.favorites.has(r.name) ? "★" : "☆" });
    fav.addEventListener("click", async () => {
      try {
        if (state.favorites.has(r.name)) { await API.unfavorite(r.name); state.favorites.delete(r.name); }
        else { await API.favorite(r.name); state.favorites.add(r.name); }
        fav.textContent = state.favorites.has(r.name) ? "★" : "☆";
        drawNav(R.moduleOf(r.name), r.name);
      } catch (e) { toast(errorText(e), true); }
    });
    const output = el("div", { class: "output analytic-output" });
    const resultJson = el("pre", { class: "json" });
    const status = el("span", { class: "run-state" });
    const historyBox = el("div");
    const detail = el("pre", { class: "preview json" });
    // RF-020-13: a definition (rule, condition…) is edited on the left and simulated on the right, nothing saved.
    const simName = (Object.entries(r.params || {}).find(([, sp]) => sp && sp.simulate) || [])[0];
    const form = R.paramsForm(r.params, { submitLabel: simName ? "Salvar (F8)" : "Executar (F8)", onSubmit: () => execute(), initial, lookup,
                                          simulate: !!simName });
    const summaryText = el("span", { class: "summary-text" });
    const layout = el("div", { class: "routine-layout" });
    let lastRun = null;

    const collapse = () => {
      layout.classList.add("collapsed");
      summaryText.textContent = form.summary();
    };
    const expand = () => { layout.classList.remove("collapsed"); form.focus(); };

    // Running from the form: the selection screen stays in history (Back returns to it, filled in).
    function execute() {
      let params;
      try { params = form.read(); } catch (e) { toast("Parâmetros: " + e.message, true); return; }
      rememberParams(r.name, params);
      const runHash = routineHash(r.name, params);
      if (location.hash !== runHash) {
        window.history.replaceState(null, "", routineHash(r.name, params, { _form: "1" }));
        window.history.pushState(null, "", runHash);
        window.AnaStudio.noteNav(runHash);
      }
      run(params);
    }

    const ctx = {
      run: (program, params) => API.run(program, { params }),
      open: (program, params) => window.AnaStudio.go(routineHash(program, params)),
      refresh: () => lastRun && run(lastRun, true),
      lookup,
      screen: "out:" + r.name,
    };

    async function run(params, quiet) {
      lastRun = params;
      const scroll = quiet && document.scrollingElement ? document.scrollingElement.scrollTop : null;
      const button = form.node.querySelector(".run-button");
      if (button) button.disabled = true;
      if (!quiet) output.replaceChildren(el("p", { class: "muted", text: "Executando…" }));
      resultJson.textContent = "";
      status.textContent = "executando…";
      status.className = "run-state busy";
      try {
        const res = await API.run(r.name, { params });
        output.replaceChildren();
        const events = res.events || (res.error && res.error.events) || [];
        for (const ev of events) if (ev.type === "output") R.drawOutput(output, ev, ctx);
        if (res.error) {
          status.textContent = "não concluída";
          status.className = "run-state error";
          output.append(el("div", { class: "end error" }, el("strong", { text: res.error.message || res.error.code }),
            el("span", { class: "muted", text: `  (${res.error.code})` })));
        } else {
          status.textContent = `concluído em ${res.duration_ms} ms`;
          status.className = "run-state ok";
          resultJson.textContent = JSON.stringify(res.result, null, 2);
          if (!output.childNodes.length) output.append(el("p", { class: "muted", text: "Concluída, sem saída na tela. Veja os dados retornados abaixo." }));
        }
        collapse();
      } catch (e) {
        status.textContent = "falhou";
        status.className = "run-state error";
        output.replaceChildren(el("div", { class: "end error", text: errorText(e) }));
      } finally {
        if (button) button.disabled = false;
      }
      if (scroll !== null && document.scrollingElement) document.scrollingElement.scrollTop = scroll;
      loadHistory();
    }
    runCurrent = execute;

    const simOut = el("div", { class: "output sim-output" },
      el("p", { class: "muted", text: "“Simular” mostra aqui o que a definição pega, sem gravar nada." }));
    const simWhen = el("span", { class: "muted small sim-when" });
    async function simulate() {
      let params;
      try { params = form.read(); } catch (e) { toast("Parâmetros: " + e.message, true); return; }
      simOut.replaceChildren(el("p", { class: "muted", text: "Simulando…" }));
      try {
        const res = await API.run(r.name, { params: { ...params, [simName]: true } });
        simOut.replaceChildren();
        const events = res.events || (res.error && res.error.events) || [];
        for (const ev of events) if (ev.type === "output") R.drawOutput(simOut, ev, { ...ctx, screen: "sim:" + r.name });
        if (res.error) simOut.append(el("div", { class: "end error" }, el("strong", { text: res.error.message || res.error.code })));
        else if (!simOut.childNodes.length) simOut.append(el("p", { class: "muted", text: "A simulação não mostrou nada." }));
        simWhen.textContent = `simulado às ${new Date().toLocaleTimeString("pt-BR")} · nada foi gravado`;
      } catch (e) { simOut.replaceChildren(el("div", { class: "end error", text: errorText(e) })); }
    }
    if (simName) {
      runSimulation = simulate;
      const btn = form.node.querySelector(".run-button");
      const simBtn = el("button", { type: "button", class: "sim-button", text: "Simular (F9)", onclick: simulate });
      if (btn) btn.before(simBtn); else form.node.append(simBtn);
    } else runSimulation = null;

    async function loadHistory() {
      const rows = await API.executions(r.name, true).catch(() => []);
      historyBox.replaceChildren(table([
        { label: "Quando", value: (x) => fmtDate(x.started_at) },
        { label: "Status", value: (x) => el("span", { class: "status-" + x.status, text: x.status + (x.error ? ` (${x.error})` : "") }) },
        { label: "ms", value: (x) => x.duration_ms ?? "…", class: "num" },
      ], rows.slice(0, 15), { empty: "Você ainda não executou esta rotina.",
        onRow: async (x) => { detail.textContent = JSON.stringify(await API.execution(x.id), null, 2); } }));
    }

    const I = window.AnaUI.icon;
    function simSplit() {
      const split = el("div", { class: "sim-split" });
      const def = el("section", { class: "params-card def-card" },
        el("div", { class: "filter-head" }, I("edit", 16), el("strong", { text: "Definição" })), form.node);
      const sim = el("section", { class: "sim-card", "aria-label": "Simulação" },
        el("div", { class: "filter-head" }, I("play", 16), el("strong", { text: "Simulação" }), simWhen), simOut);
      split.append(def, window.AnaUI.splitter(split, "--def-w", { min: 260, max: 1100, key: "sim." + r.name }), sim);
      return split;
    }
    const band = el("section", { class: "page-band" });
    layout.append(band);
    band.append(
      el("div", { class: "page-header" },
        el("div", { class: "page-title" }, el("div", { class: "breadcrumb", text: `${R.areaOf(r)} · ${R.categoryOf(r)}` }),
          el("h1", {}, title(r), " ", fav,
            el("button", { type: "button", class: "quiet small copy-to-cat", title: "Copiar para uma categoria sua ou da empresa",
                           onclick: () => window.AnaCategories.copyDialog([r.name]) }, "Copiar para categoria…"))),
        el("div", { class: "page-meta" }, status,
          el("span", { class: "muted small", text: `${r.command ? "comando " + r.command + " · " : ""}${r.exposed ? "integração · " : ""}F8 executa · F3 volta` }),
          window.AnaUI.pinnable(band, "routine." + r.name))),
      simName ? simSplit() : el("section", { class: "params-card filter-bar" },
        el("div", { class: "filter-head" }, I("filter", 16), el("strong", { text: "Filtros" })), form.node),
      el("div", { class: "params-summary" },
        el("button", { type: "button", class: "quiet small icon-text", onclick: expand, title: "Alterar os filtros" }, I("edit", 16), el("span", { text: "Filtros" })),
        summaryText,
        el("button", { type: "button", class: "quiet small icon-text", onclick: () => lastRun && run(lastRun) }, I("refresh", 16), el("span", { text: "Executar de novo" }))));
    layout.append(
      el("section", { class: "result-card page-body" }, output,
        el("details", { class: "json-box" }, el("summary", { text: "dados retornados (JSON)" }), resultJson)));
    $("#ops-main").replaceChildren(
      layout,
      el("details", { class: "history-box page-body" }, el("summary", { text: "Minhas execuções desta rotina" }),
        el("div", { class: "routine-layout plain" },
          el("section", { class: "card" }, historyBox),
          el("section", { class: "card" }, el("h2", { text: "Detalhe" }), detail))));
    output.append(el("div", { class: "empty-state" }, window.AnaUI.icon("chart", 40),
      el("span", { text: "Defina os filtros e execute (F8) para ver o resultado." })));
    loadHistory();
    // A definition opened with its values is simulated, never saved, until the person chooses Salvar.
    if (Object.keys(given).length && !formOnly) { if (simName) simulate(); else run(given); }
    else form.focus();
  }

  document.addEventListener("keydown", (e) => {
    if (e.key === "F8" && runCurrent && !$("#area-ops").hidden) { e.preventDefault(); runCurrent(); }
    else if (e.key === "F9" && runSimulation && !$("#area-ops").hidden) { e.preventDefault(); runSimulation(); }
    else if (e.key === "Enter" && (e.ctrlKey || e.metaKey) && runCurrent && e.target.closest && e.target.closest("#ops-main .params-form")) {
      e.preventDefault(); runCurrent();
    }
  });

  window.AnaOps = { routineOf: (n) => routine(n), home, ops, loadRoutines, routineHash, routines: () => state.routines };
})();
