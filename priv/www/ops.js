// SPDX-FileCopyrightText: 2026 LE Devices
// SPDX-License-Identifier: AGPL-3.0-or-later
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
  // Spec 050 (T-050-07, D6): fields declared "default_from": "last" follow the user to any computer (kept on the
  // server with the screen preferences, written only when they change — P15).
  const lastFields = (r) => Object.entries(r.params || {}).filter(([, sp]) => sp && sp.default_from === "last").map(([k]) => k);
  function lastUsed(r) {
    const v = window.AnaPrefs.get("last." + r.name);
    return v && typeof v === "object" && !Array.isArray(v) ? v : {};
  }
  function rememberLast(r, params) {
    const keep = {};
    for (const k of lastFields(r)) if (params[k] !== undefined && params[k] !== null && params[k] !== "") keep[k] = params[k];
    if (!Object.keys(keep).length || JSON.stringify(keep) === JSON.stringify(lastUsed(r))) return;
    window.AnaPrefs.set("last." + r.name, keep);
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

  let onUndone = null;         // spec 050 (D5): what the routine on screen does after an undo
  document.addEventListener("ana:undone", (e) => { if (onUndone && !$("#area-ops").hidden) onUndone(e.detail || {}); });
  let runCurrent = null;       // F8 runs the routine on screen
  let runSimulation = null;    // F9 simulates a definition (RF-020-13)

  async function openRoutine(r, query = {}) {
    state.current = r;
    lookupCache.clear();
    const formOnly = query._form === "1";
    const given = Object.fromEntries(Object.entries(query).filter(([k]) => !k.startsWith("_")));
    const initial = Object.keys(given).length ? { ...lastUsed(r), ...given } : { ...lastUsed(r), ...lastParams(r.name) };
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
    // Spec 045: the form is rebuilt when a variant is chosen (its values filled, locked and hidden fields applied).
    let variant = null;
    let form = null;
    const formHost = el("div", { class: "form-host" });
    function makeForm(init, v) {
      form = R.paramsForm(r.params, { submitLabel: simName ? "Salvar (F8)" : "Executar (F8)", onSubmit: () => execute(), initial: init, lookup,
                                      simulate: !!simName });
      variant = v || null;
      if (variant) { form.lock(variant.locked); form.hide(variant.hidden); }
      const runBtn = form.node.querySelector(".run-button");
      if (runBtn) runBtn.setAttribute("aria-keyshortcuts", "F8");
      addTestButtons();
      formHost.replaceChildren(form.node);
    }
    // The values to send: the locked fields are the variant's, filled by the core.
    const readParams = () => {
      const p = form.read();
      if (variant) for (const k of variant.locked || []) delete p[k];
      return p;
    };
    const withVariant = (body) => (variant ? { ...body, variant: variant.id } : body);
    makeForm(initial, null);
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
      try { params = readParams(); } catch (e) { toast("Parâmetros: " + e.message, true); return; }
      rememberParams(r.name, params);
      rememberLast(r, params);
      const vq = variant ? { _variant: variant.id } : {};
      const runHash = routineHash(r.name, params, vq);
      if (location.hash !== runHash) {
        window.history.replaceState(null, "", routineHash(r.name, params, { ...vq, _form: "1" }));
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
      // Spec 050 (D5): a routine that cannot be undone says its consequence and asks first.
      if (!quiet && r.confirm && !(await window.AnaUI.confirmDialog(r.confirm, { title: r.description || r.name, ok: "Executar" }))) return;
      lastRun = params;
      const scroll = quiet && document.scrollingElement ? document.scrollingElement.scrollTop : null;
      const button = form.node.querySelector(".run-button");
      if (button) button.disabled = true;
      if (!quiet) output.replaceChildren(el("p", { class: "muted", text: "Executando…" }));
      resultJson.textContent = "";
      status.textContent = "executando…";
      status.className = "run-state busy";
      try {
        const res = await API.run(r.name, withVariant({ params }));
        output.replaceChildren();
        if (res.variant && res.variant.warnings && res.variant.warnings.length) toast(res.variant.warnings.join("; "));
        const events = res.events || (res.error && res.error.events) || [];
        for (const ev of events) if (ev.type === "output") R.drawOutput(output, ev, ctx);
        if (res.error) {
          status.textContent = "não concluída";
          status.className = "run-state error";
          const why = window.AnaErrors.describe(res.error);
          output.append(el("div", { class: "end error" }, el("strong", { text: why.title }),
            why.action ? el("div", { text: why.action }) : null,
            why.technical ? el("div", { class: "muted small", text: why.technical }) : null));
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
    // After an undo: a routine that only reads (a document, a list) shows the state again; one that writes is not run
    // again — its result says it was undone.
    onUndone = ({ offer }) => {
      if (!lastRun) return;
      if (!r.writes) { run(lastRun, true); return; }
      output.prepend(el("div", { class: "end undone", role: "status", text: `Desfeito: ${(offer && offer.label) || "a última ação"}. O que está abaixo é de antes.` }));
      status.textContent = "desfeito";
      status.className = "run-state";
    };

    const simOut = el("div", { class: "output sim-output" },
      el("p", { class: "muted", text: "“Simular” mostra aqui o que a definição pega, sem gravar nada." }));
    const simWhen = el("span", { class: "muted small sim-when" });
    async function simulate() {
      let params;
      try { params = readParams(); } catch (e) { toast("Parâmetros: " + e.message, true); return; }
      simOut.replaceChildren(el("p", { class: "muted", text: "Simulando…" }));
      try {
        const res = await API.run(r.name, withVariant({ params: { ...params, [simName]: true } }));
        simOut.replaceChildren();
        const events = res.events || (res.error && res.error.events) || [];
        for (const ev of events) if (ev.type === "output") R.drawOutput(simOut, ev, { ...ctx, screen: "sim:" + r.name });
        if (res.error) simOut.append(el("div", { class: "end error" }, el("strong", { text: window.AnaErrors.text(res.error) })));
        else if (!simOut.childNodes.length) simOut.append(el("p", { class: "muted", text: "A simulação não mostrou nada." }));
        simWhen.textContent = `simulado às ${new Date().toLocaleTimeString("pt-BR")} · nada foi gravado`;
      } catch (e) { simOut.replaceChildren(el("div", { class: "end error", text: errorText(e) })); }
    }
    // Spec 056: every routine that writes can be rehearsed — it runs whole, everything is undone, and the effect
    // (records, e-mails, calls held) is shown in business terms. A routine with its own simulation keeps it (D4).
    async function rehearse() {
      let params;
      try { params = readParams(); } catch (e) { toast("Parâmetros: " + e.message, true); return; }
      output.replaceChildren(el("p", { class: "muted", text: "Ensaiando… nada será gravado." }));
      resultJson.textContent = "";
      status.textContent = "ensaiando…";
      status.className = "run-state busy";
      try {
        const res = await API.run(r.name, withVariant({ params, rehearse: true }));
        output.replaceChildren();
        const effects = res.rehearsal || (res.error && res.error.rehearsal) || null;
        output.append(R.rehearsalCard(effects, res.error, ctx));
        const events = res.events || (res.error && res.error.events) || [];
        for (const ev of events) if (ev.type === "output") R.drawOutput(output, ev, { ...ctx, screen: "rehearsal:" + r.name });
        if (!res.error) resultJson.textContent = JSON.stringify(res.result, null, 2);
        status.textContent = res.error ? "ensaio parou num erro · nada foi gravado" : `ensaio em ${res.duration_ms} ms · nada foi gravado`;
        status.className = "run-state " + (res.error ? "error" : "ok");
        collapse();
      } catch (e) {
        status.textContent = "falhou";
        status.className = "run-state error";
        output.replaceChildren(el("div", { class: "end error", text: errorText(e) }));
      }
    }
    function addTestButtons() {
      if (simName) {
        runSimulation = simulate;
        const btn = form.node.querySelector(".run-button");
        const simBtn = el("button", { type: "button", class: "sim-button", text: "Simular (F9)", onclick: simulate, "aria-keyshortcuts": "F9" });
        if (btn) btn.before(simBtn); else form.node.append(simBtn);
      } else if (r.writes) {
        runSimulation = rehearse;
        const btn = form.node.querySelector(".run-button");
        const reBtn = el("button", { type: "button", class: "sim-button rehearse-button", text: "Ensaiar (F9)", onclick: rehearse, "aria-keyshortcuts": "F9",
                                     title: "Executa tudo e desfaz no fim: mostra o que seria gravado e enviado, sem gravar nada" });
        if (btn) btn.before(reBtn); else form.node.append(reBtn);
      } else runSimulation = null;
    }

    async function loadHistory() {
      const rows = await API.executions(r.name, true).catch(() => []);
      historyBox.replaceChildren(table([
        { label: "Quando", value: (x) => fmtDate(x.started_at) },
        { label: "Status", value: (x) => el("span", { class: "status-" + x.status, text: x.status + (x.error ? ` (${x.error})` : "") }) },
        { label: "ms", value: (x) => x.duration_ms ?? "…", class: "num" },
      ], rows.slice(0, 15), { empty: "Você ainda não executou esta rotina.",
        // Spec 050: the empty history offers the next step. A routine with simulation saves with its main
        // button, so there the step is filling the definition, never saving by surprise.
        emptyAction: simName
          ? { label: "Preencher a definição", onClick: () => form.node.querySelector("input, select, textarea")?.focus() }
          : { label: "Executar agora", onClick: () => {
              const b = form.node.querySelector(".run-button");
              if (b && !b.disabled) b.click(); else form.node.querySelector("input, select, textarea")?.focus();
            } },
        onRow: async (x) => { detail.textContent = JSON.stringify(await API.execution(x.id), null, 2); } }));
    }

    // ---- Spec 045: variants — named parameters, chosen, saved, published and set as default right here.
    const variantBar = el("div", { class: "variant-bar" });
    const variantPanel = el("div", { class: "variant-panel", hidden: true });
    let variants = { variants: [], default_id: null, my_default_id: null, can_publish: false };
    const declared = Object.entries(r.params || {}).filter(([, sp]) => !(sp && sp.simulate));
    const editableVariant = (v) => !!v && (v.owner !== null || variants.can_publish);
    async function loadVariants() {
      try { variants = await API.runVariants.list(r.name); } catch (_) { /* the routine still runs without them */ }
      drawVariantBar();
      return variants;
    }
    async function useVariant(id, over) {
      if (!id) {
        const keep = form.peek();
        makeForm({ ...keep, ...(over || {}) }, null);
        drawVariantBar();
        return;
      }
      try {
        const p = await API.runVariants.preview(r.name, id);
        const free = Object.fromEntries(Object.entries(over || {}).filter(([k]) => !(p.locked || []).includes(k)));
        makeForm({ ...p.params, ...free }, p);
        if (p.warnings && p.warnings.length) toast(p.warnings.join("; "));
      } catch (e) {
        toast(errorText(e), true);
        makeForm(form.peek(), null);
      }
      drawVariantBar();
    }
    function drawVariantBar() {
      const list = variants.variants || [];
      const current = variant && list.find((v) => v.id === variant.id);
      const sel = el("select", { "aria-label": "Variante", class: "variant-select",
                                 onchange: () => useVariant(sel.value ? Number(sel.value) : null) },
        el("option", { value: "", text: list.length ? "— sem variante —" : "Sem variantes" }),
        list.map((v) => el("option", { value: v.id, disabled: v.status === "invalid", title: v.status_reason || "",
          text: v.name + (v.owner === null ? (v.published ? " · empresa" : " · empresa (rascunho)") : "")
                + (v.id === variants.default_id ? " ★" : "") + (v.status === "invalid" ? " (inválida)" : "") })));
      sel.value = variant ? String(variant.id) : "";
      const act = (label, fn, cls) => el("button", { type: "button", class: "small quiet " + (cls || ""), text: label,
        onclick: () => fn().then(() => loadVariants()).catch((e) => toast(errorText(e), true)) });
      const items = [];
      if (current) {
        items.push(variants.my_default_id === current.id
          ? act("Deixar de ser minha padrão", () => API.runVariants.clearDefault(r.name))
          : act("Usar como minha padrão", () => API.runVariants.act(r.name, current.id, "default")));
        if (editableVariant(current)) {
          items.push(el("button", { type: "button", class: "small quiet", text: "Alterar…", onclick: () => variantDialog(current) }));
          if (current.owner === null) {
            items.push(current.published ? act("Despublicar", () => API.runVariants.act(r.name, current.id, "unpublish"))
                                         : act("Publicar para a empresa", () => API.runVariants.act(r.name, current.id, "publish")));
            if (current.published && !current.company_default) items.push(act("Tornar a padrão da empresa", () => API.runVariants.act(r.name, current.id, "company_default")));
            if (current.has_previous) items.push(act("Restaurar versão anterior", async () => { await API.runVariants.act(r.name, current.id, "restore"); await useVariant(current.id); }));
          }
          items.push(act("Excluir", async () => {
            if (!confirm(`Excluir a variante "${current.name}"?`)) return;
            await API.runVariants.remove(r.name, current.id);
            makeForm(form.peek(), null);
          }, "danger"));
        }
      }
      variantBar.replaceChildren(
        declared.length || list.length ? sel : null,
        declared.length ? el("button", { type: "button", class: "small", text: "Salvar como variante…", onclick: () => variantDialog(null) }) : null,
        items.length ? el("details", { class: "variant-menu" }, el("summary", { "aria-label": "Mais ações da variante", text: "⋯" }),
                          el("div", { class: "variant-menu-items" }, items)) : null,
        variant && variant.locked && variant.locked.length ? el("span", { class: "muted small", text: `${variant.locked.length} campo(s) travado(s)` }) : null);
    }
    let valueMeta = null, companyValues = null;
    async function variantDialog(existing) {
      if (!valueMeta) valueMeta = await API.values.meta().catch(() => ({ expressions: [] }));
      if (!companyValues) companyValues = await API.values.list().then((x) => x.values.map((v) => v.name)).catch(() => []);
      const now = form.peek();
      const entries = existing ? existing.entries || {} : {};
      const name = el("input", { value: existing ? existing.name : "", "aria-label": "Nome da variante", placeholder: "ex.: Mês anterior, P&D" });
      const scope = el("select", { "aria-label": "Quem vê", disabled: !!existing },
        el("option", { value: "personal", text: "Só eu" }), variants.can_publish ? el("option", { value: "company", text: "A empresa (eu publico)" }) : null);
      if (existing && existing.owner === null) scope.value = "company";
      const listId = "cv-names-" + r.name.replace(/\W/g, "_");
      const rows = declared.map(([n, sp]) => {
        sp = sp || {};
        const type = sp.type || "str";
        const exprs = (valueMeta.expressions || []).filter((x) => type === "str" || (type === "date" && x.result_type === "date")
                                                                  || (type === "datetime" && x.result_type === "datetime"));
        const e = entries[n] || null;
        const mode = el("select", { "aria-label": "Como guardar " + (sp.label || n) },
          el("option", { value: "", text: "não guardar" }), el("option", { value: "value", text: "este valor" }),
          exprs.map((x) => el("option", { value: "expr:" + x.token, text: x.label })),
          el("option", { value: "company", text: "valor da empresa…" }));
        const offset = el("input", { type: "number", step: "1", value: "0", class: "narrow", "aria-label": "Deslocamento", hidden: true });
        const cv = el("input", { list: listId, placeholder: "nome do valor", "aria-label": "Valor da empresa", hidden: true });
        const lock = el("input", { type: "checkbox", "aria-label": "Travar " + (sp.label || n) });
        const hide = el("input", { type: "checkbox", "aria-label": "Ocultar " + (sp.label || n) });
        if (e && e.expr) {
          const m = /^([a-z_]+)([+-]\d+)?$/.exec(e.expr);
          mode.value = "expr:" + (m ? m[1] : e.expr); if (m && m[2]) offset.value = String(Number(m[2]));
        } else if (e && e.company_value) { mode.value = "company"; cv.value = e.company_value; }
        else if (e || (!existing && now[n] !== undefined && now[n] !== "" && now[n] !== false && !(Array.isArray(now[n]) && !now[n].length))) mode.value = "value";
        lock.checked = !!(existing && (existing.locked || []).includes(n));
        hide.checked = !!(existing && (existing.hidden || []).includes(n));
        const sync = () => {
          const x = exprs.find((t) => "expr:" + t.token === mode.value);
          offset.hidden = !(x && x.offset_unit);
          cv.hidden = mode.value !== "company";
          lock.disabled = hide.disabled = !mode.value;
        };
        mode.addEventListener("change", sync); sync();
        return { n, sp, mode, offset, cv, lock, hide,
                 entry: () => {
                   if (!mode.value) return null;
                   if (mode.value === "value") return { value: e && e.value !== undefined && now[n] === undefined ? e.value : (now[n] ?? null) };
                   if (mode.value === "company") return cv.value.trim() ? { company_value: cv.value.trim() } : null;
                   const off = Number(offset.value || 0);
                   return { expr: mode.value.slice(5) + (off ? (off > 0 ? "+" : "") + off : "") };
                 } };
      });
      const close = () => { variantPanel.hidden = true; variantPanel.replaceChildren(); };
      variantPanel.replaceChildren(el("form", { class: "form-card", onsubmit: (ev) => { ev.preventDefault(); (async () => {
        const body = { name: name.value.trim(), scope: scope.value, entries: {}, locked: [], hidden: [] };
        if (existing) body.id = existing.id;
        for (const x of rows) {
          const en = x.entry();
          if (!en) continue;
          body.entries[x.n] = en;
          if (x.lock.checked) body.locked.push(x.n);
          if (x.hide.checked) body.hidden.push(x.n);
        }
        const res = await API.runVariants.save(r.name, body);
        close();
        toast(existing ? "Variante alterada." : "Variante salva.");
        await loadVariants();
        await useVariant(res.id);
      })().catch((e) => toast(errorText(e), true)); } },
        el("h4", { text: existing ? `Alterar a variante "${existing.name}"` : "Salvar como variante" }),
        el("div", { class: "row-buttons" }, el("label", {}, "Nome", name), el("label", {}, "Quem vê", scope)),
        el("datalist", { id: listId }, companyValues.map((v) => el("option", { value: v }))),
        el("table", { class: "grid-table variant-fields" },
          el("thead", {}, el("tr", {}, ["Campo", "Guardar como", "Travar", "Ocultar"].map((h) => el("th", { text: h })))),
          el("tbody", {}, rows.map((x) => el("tr", {},
            el("td", { text: x.sp.label || x.n }),
            el("td", {}, x.mode, x.offset, x.cv),
            el("td", {}, x.lock), el("td", {}, x.hide))))),
        el("p", { class: "muted small", text: "Expressões e valores da empresa são resolvidos na hora de cada execução. Campo travado não muda na tela, na API nem no agendamento." }),
        el("div", { class: "row-buttons" }, el("button", { class: "primary", type: "submit", text: "Salvar variante" }),
          el("button", { type: "button", class: "quiet", text: "Cancelar", onclick: close }))));
      variantPanel.hidden = false;
      name.focus();
    }

    const I = window.AnaUI.icon;
    function simSplit() {
      const split = el("div", { class: "sim-split" });
      const def = el("section", { class: "params-card def-card" },
        el("div", { class: "filter-head" }, I("edit", 16), el("strong", { text: "Definição" }), variantBar), variantPanel, formHost);
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
          el("span", { class: "muted small", text: `${r.command ? "comando " + r.command + " · " : ""}${r.exposed ? "integração · " : ""}F8 executa${r.writes && !simName ? " · F9 ensaia" : ""} · F3 volta` }),
          window.AnaUI.pinnable(band, "routine." + r.name))),
      simName ? simSplit() : el("section", { class: "params-card filter-bar" },
        el("div", { class: "filter-head" }, I("filter", 16), el("strong", { text: "Filtros" }), variantBar), variantPanel, formHost),
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
      el("span", { text: "Defina os filtros e execute (F8) para ver o resultado." }),
      el("button", { type: "button", class: "quiet small icon-text", onclick: () => execute() }, I("play", 16), el("span", { text: "Executar (F8)" }))));
    loadHistory();
    // A definition opened with its values is simulated, never saved, until the person chooses Salvar.
    // Spec 045 (D4, D5): a variant asked in the address, or the user's default when nothing else was given.
    await loadVariants();
    const askedVariant = query._variant ? Number(query._variant) : null;
    const valid = (id) => (variants.variants || []).some((v) => v.id === id && v.status !== "invalid");
    const startVariant = askedVariant || (!Object.keys(given).length && !formOnly && valid(variants.default_id) ? variants.default_id : null);
    if (startVariant) await useVariant(startVariant, given);
    if (Object.keys(given).length && !formOnly) { if (simName) simulate(); else run(variant ? readParams() : given); }
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
