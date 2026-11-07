// Development area (RF-020-04, RF-020-05): everything about a program lives in
// the program (code, properties and limits, versions, executions); data
// (catalog + SQL console) lives together.
"use strict";
(function () {
  const API = window.AnaApi;
  const { $, $$, el, fmtDate, errorText, toast, dataTable } = window.AnaUI;
  const R = window.AnaRunner;

  const TEMPLATE = `"""Descreva aqui o que o programa faz."""

PARAMS = {
    "name": {"type": "str", "default": "mundo"},
}


def main(name="mundo"):
    ana.log(f"executado por {ana.context.user}")
    return {"message": f"Olá, {name}!"}
`;

  const LIMIT_LABELS = {
    timeout_ms: "Tempo total (ms)", cpu_ms: "CPU (ms)", memory_mb: "Memória (MiB)",
    sql_timeout_ms: "Tempo por SQL (ms)", lock_timeout_ms: "Espera por trava (ms)", output_kb: "Saída (KiB)",
    max_rows: "Linhas por consulta", max_sql: "Comandos SQL", max_concurrent: "Execuções simultâneas",
    max_parallel_parts: "Partes paralelas simultâneas",
  };

  const state = { programs: [], current: null, dirty: false, exec: null, form: null, loaded: false, tab: "code" };
  let editor = null;

  // ------------------------------------------------------------------ entry
  async function show(route) {
    if (!state.loaded) await init();
    if (route[0] === "patterns") {                      // spec 050 (T-050-01)
      selectSide("patterns");
      showView("patterns");
      window.AnaPatterns.render($("#patterns-view"));
      return;
    }
    if (route[0] === "data") {
      selectSide("data");
      showView("data");
      if (route[1] && route[2]) showTable(route[1], route[2]);
      return;
    }
    selectSide("programs");
    showView("program");
    if (route[0] === "program" && route[1] && (!state.current || state.current.name !== route[1])) {
      await openProgram(route[1]);
    }
  }

  async function init() {
    state.loaded = true;
    editor = new window.AnaEditor($("#editor"));
    editor.onChange = () => markDirty(true);
    editor.onBreakpointsChange = (lines) => {
      if (state.exec && state.exec.debugging) API.command(state.exec.id, { action: "breakpoints", lines }).catch(() => {});
    };
    editor.value = "";
    editor.readOnly = true;
    wire();
    await Promise.all([loadPrograms(), loadCatalog()]);
  }

  function showView(v) {
    $("#program-view").hidden = v !== "program";
    $("#data-view").hidden = v !== "data";
    $("#patterns-view").hidden = v !== "patterns";
  }

  function selectSide(side) {
    for (const b of $$("[data-side]")) b.classList.toggle("active", b.dataset.side === side);
    $("#side-programs").hidden = side !== "programs";
    $("#side-data").hidden = side !== "data";
    $("#side-patterns").hidden = side !== "patterns";
  }

  function selectTab(tab) {
    state.tab = tab;
    for (const b of $$("[data-ptab]")) b.classList.toggle("active", b.dataset.ptab === tab);
    for (const t of $$(".ptab")) t.hidden = t.id !== "ptab-" + tab;
    if (tab === "versions") loadVersions();
    if (tab === "executions") loadExecutions();
    if (tab === "schedules") loadSchedules();
    if (tab === "perf") loadPerformance();
  }

  function notice(msg, isError = false) {
    const a = $("#notice");
    a.textContent = msg || "";
    a.hidden = !msg;
    a.className = "notice" + (isError ? "" : " info");
  }

  // ------------------------------------------------------------------ programs
  async function loadPrograms() {
    state.programs = await API.programs($("#show-inactive").checked);
    drawTree();
    return state.programs;
  }

  function drawTree() {
    const filter = $("#filter").value.trim().toLowerCase();
    const root = {};
    for (const p of state.programs) {
      if (filter && !p.name.includes(filter) && !(p.description || "").toLowerCase().includes(filter)) continue;
      const parts = p.name.split(".");
      let node = root;
      for (const part of parts.slice(0, -1)) node = (node[part] ||= { __children: {} }).__children;
      node[parts.at(-1) + "\u0000"] = p;
    }
    const build = (node, depth) => {
      const ul = el("ul");
      for (const key of Object.keys(node).sort()) {
        const v = node[key];
        if (key.endsWith("\u0000")) {
          const p = v;
          const item = el("div", {
            class: "node" + (state.current && state.current.name === p.name ? " active" : "") + (p.active ? "" : " inactive"),
            title: p.description || p.name, onclick: () => window.AnaStudio.go(`#/dev/program/${p.name}`),
          }, el("span", { text: (p.kind === "library" ? "◇ " : "▸ ") + key.slice(0, -1) }));
          if (p.exposed) item.append(el("span", { class: "tag exposed", text: p.public ? "público" : "exposto" }));
          if (p.restricted) item.append(el("span", { class: "tag restricted", text: "restrito" }));
          if (p.warning) item.append(el("span", { class: "tag warn", text: "!", title: p.warning }));
          // Spec 009 (D8): a product program edited here.
          if (p.customized) item.append(el("span", { class: "tag warn", text: "customizado", title: "Programa do produto alterado nesta instalação: fora do suporte padrão. As atualizações do produto pedem sua decisão." }));
          ul.append(el("li", {}, item));
        } else {
          const label = depth === 0 ? `${key} — ${R.moduleLabel(key)}` : key;
          const folder = el("div", { class: "node folder", text: depth === 0 && R.moduleLabel(key) !== key ? label : key,
                                     onclick: (e) => e.currentTarget.classList.toggle("closed") });
          ul.append(el("li", {}, folder, build(v.__children, depth + 1)));
        }
      }
      return ul;
    };
    $("#tree").replaceChildren(...build(root, 0).children);
  }

  async function openProgram(name) {
    if (state.dirty && !confirm("Há alterações não salvas. Descartar?")) {
      window.AnaStudio.replace(`#/dev/program/${state.current.name}`);
      return;
    }
    try {
      const p = await API.program(name);
      state.current = p;
      editor.value = p.source;
      editor.readOnly = false;
      editor.setBreakpoints([]);
      editor.markCurrent(null);
      fillProperties(p);
      markDirty(false);
      notice(p.warning ? "⚠ " + p.warning
             : p.customized ? "Programa do produto customizado nesta instalação — fora do suporte padrão." : "", true);
      buildParams(p.params);
      clearOutput();
      drawTree();
      selectTab(state.tab);
    } catch (e) { notice(errorText(e), true); }
  }

  function fillProperties(p) {
    $("#program-name").textContent = p.name;
    $("#program-version").textContent = p.version ? "v" + p.version : "novo";
    $("#program-desc").textContent = p.description || "";
    $("#p-description").value = p.description || "";
    $("#p-kind").value = p.kind || "program";
    $("#p-role").value = p.min_role || "user";
    $("#p-exposed").checked = !!p.exposed;
    $("#p-public").checked = !!p.public;
    $("#p-menu").checked = p.in_menu !== false;
    $("#p-restricted").checked = !!p.restricted;
    $("#p-active").checked = p.active !== false;
    $("#purge").disabled = !p.version;
    runButtons(false);
    loadLimits(p);
    loadProgramCommands(p);
  }

  async function loadLimits(p) {
    const box = $("#limits-box");
    box.replaceChildren();
    if (!p.version) { box.append(el("p", { class: "muted", text: "Salve o programa para definir limites." })); return; }
    let rows;
    try { rows = await API.limits(p.name); } catch (_) { return; }
    for (const r of rows) {
      const fmt = (v) => (r.zero_unlimited && v === 0 ? "sem limite" : String(v));
      const input = el("input", { type: "number", min: 0, name: r.key, value: r.declared ?? "", placeholder: `padrão ${fmt(r.default)}` });
      input.addEventListener("change", () => markDirty(true));
      box.append(el("label", { title: `teto ${fmt(r.ceiling)}` }, LIMIT_LABELS[r.key] || r.key, input,
        el("span", { class: "hint", text: `efetivo para você: ${fmt(r.effective)} · teto ${fmt(r.ceiling)}` })));
    }
  }

  async function loadProgramCommands(p) {
    const box = $("#program-commands");
    box.replaceChildren();
    if (!p.version) return;
    const all = await API.commands().catch(() => []);
    const mine = all.filter((c) => c.program === p.name);
    const code = el("input", { placeholder: "novo comando (ex.: pedido)" });
    box.append(
      el("div", { class: "chips" }, mine.length ? mine.map((c) => el("span", { class: "pill" }, c.code, " ",
        el("button", { class: "quiet small", title: "Remover", text: "×", onclick: async () => {
          if (!confirm(`Remover o comando ${c.code}?`)) return;
          await API.deleteCommand(c.code); loadProgramCommands(p);
        } }))) : el("span", { class: "muted", text: "Nenhum comando aponta para este programa." })),
      el("form", { class: "inline-form", onsubmit: async (e) => {
        e.preventDefault();
        try { await API.saveCommand(code.value.trim().toLowerCase(), { program: p.name, description: p.description || "" }); loadProgramCommands(p); }
        catch (err) { toast(errorText(err), true); }
      } }, code, el("button", { type: "submit", text: "Adicionar comando" })));
  }

  function readLimits() {
    const out = {};
    for (const i of $$("#limits-box input")) if (i.value !== "") out[i.name] = parseInt(i.value, 10);
    return out;
  }

  function markDirty(v) {
    state.dirty = v;
    $("#dirty").hidden = !v;
  }

  function newProgram() {
    const name = prompt("Nome do programa (ex.: sales.monthly_report):");
    if (!name) return;
    if (!/^[a-z][a-z0-9_]*(\.[a-z][a-z0-9_]*)*$/.test(name)) { alert("Nome inválido: use letras minúsculas, números, _ e pontos."); return; }
    if (state.programs.some((p) => p.name === name)) { window.AnaStudio.go(`#/dev/program/${name}`); return; }
    state.current = { name, version: null, kind: "program", min_role: "user", exposed: false, restricted: false, active: true };
    editor.value = TEMPLATE;
    editor.readOnly = false;
    fillProperties(state.current);
    markDirty(true);
    notice("");
    buildParams({ name: { type: "str", default: "mundo" } });
    selectTab("code");
    editor.focus();
  }

  async function save() {
    if (!state.current) return;
    const fields = {
      source: editor.value,
      description: $("#p-description").value,
      kind: $("#p-kind").value,
      min_role: $("#p-role").value,
      exposed: $("#p-exposed").checked,
      public: $("#p-exposed").checked && $("#p-public").checked,
      in_menu: $("#p-menu").checked,
      restricted: $("#p-restricted").checked,
      active: $("#p-active").checked,
      comment: $("#comment").value,
    };
    if (state.current.version) { fields.base_version = state.current.version; fields.limits = readLimits(); }
    try {
      const r = await API.saveProgram(state.current.name, fields);
      $("#comment").value = "";
      markDirty(false);
      await loadPrograms();
      const p = await API.program(state.current.name);
      state.current = p;
      fillProperties(p);
      buildParams(p.params);
      notice(r.warning ? "⚠ " + r.warning : `Salvo como versão ${r.version}.`, !!r.warning);
      const line = r.warning && /^linha (\d+)/.exec(r.warning);
      editor.markError(line ? Number(line[1]) : null);
      window.AnaStudio.replace(`#/dev/program/${p.name}`);
    } catch (e) {
      if (e.status === 409) notice("Conflito: o programa foi alterado por outra pessoa (versão " +
        e.body.error.current_version + "). Copie suas mudanças e reabra o programa.", true);
      else notice(errorText(e), true);
    }
  }

  async function purge() {
    const p = state.current;
    if (!p || !p.version) return;
    if (!confirm(`Excluir DEFINITIVAMENTE o programa ${p.name} e todas as suas versões?\nO histórico de execuções é mantido.`)) return;
    if (prompt("Digite o nome do programa para confirmar:") !== p.name) { toast("Exclusão cancelada."); return; }
    try {
      await API.purgeProgram(p.name);
      toast(`Programa ${p.name} excluído.`);
      state.current = null;
      markDirty(false);
      editor.value = "";
      editor.readOnly = true;
      $("#program-name").textContent = "Nenhum programa aberto";
      $("#program-version").textContent = "";
      $("#program-desc").textContent = "";
      await loadPrograms();
      window.AnaStudio.replace("#/dev");
    } catch (e) { toast(errorText(e), true); }
  }

  // ------------------------------------------------------------------ params
  function buildParams(decl) {
    state.form = R.paramsForm(decl, { showTypes: true,
      lookup: (program, params) => API.run(program, { params }).then((r) => (r.error ? [] : r.result)).catch(() => []) });
    const old = $("#params-form");
    state.form.node.id = "params-form";
    old.replaceWith(state.form.node);
    $("#params-json").hidden = true;
  }

  function readParams() {
    if (!$("#params-json").hidden) {
      const v = JSON.parse($("#params-json").value || "{}");
      if (typeof v !== "object" || Array.isArray(v) || v === null) throw new Error("parâmetros devem ser um objeto JSON");
      return v;
    }
    return state.form.read();
  }

  // ------------------------------------------------------------------ running
  function clearOutput() {
    $("#panel-output").replaceChildren();
    $("#result").textContent = "";
    $("#variables tbody").replaceChildren();
    $("#stack").replaceChildren();
    $("#console-history").replaceChildren();
    runState("");
  }

  function runState(text, cls = "") {
    const e = $("#run-state");
    e.textContent = text;
    e.className = "run-state " + cls;
  }

  // A library is imported by programs (from ana_lib.<namespace> import <name>); it never runs by itself.
  const LIBRARY_HINT = "Biblioteca: não executa sozinha — é usada pelos programas (from ana_lib.<módulo> import <nome>). Para testá-la, rode um programa que a importe.";
  function isLibrary() {
    return !!state.current && ($("#p-kind").value || state.current.kind) === "library";
  }
  function runButtons(running) {
    const lib = isLibrary();
    for (const id of ["#run", "#debug"]) {
      $(id).disabled = running || lib;
      $(id).title = lib ? LIBRARY_HINT : id === "#run" ? "Executar (F5)" : "Depurar (Ctrl+F5)";
    }
  }

  function debugButtons(paused, running) {
    for (const b of $$(".dbg")) b.disabled = !paused;
    $("#dbg-stop").disabled = !running;
    runButtons(running);
  }

  async function run(debug = false) {
    if (!state.current) return;
    if (isLibrary()) { notice(LIBRARY_HINT, true); return; }
    if (state.dirty) {
      await save();
      if (state.dirty) return;
    }
    let params;
    try { params = readParams(); } catch (e) { notice("Parâmetros inválidos: " + e.message, true); return; }
    clearOutput();
    editor.markCurrent(null);
    editor.markError(null);
    selectTab("code");
    showPanel("output");
    const body = { params };
    if (debug) {
      Object.assign(body, { debug: true, breakpoints: [...editor.breakpoints],
                            stop_on_entry: editor.breakpoints.size === 0, commit: $("#p-commit").checked });
    } else {
      body.async = true;
    }
    try {
      debugButtons(false, true);
      runState(debug ? "depurando…" : "executando…");
      const r = await API.run(state.current.name, body);
      if (r && r.error) { finish({ status: "error", error: r.error }); return; }
      state.exec = { id: r.id, seq: 0, debugging: debug, controller: new AbortController() };
      follow(state.exec);
    } catch (e) {
      debugButtons(false, false);
      runState("falhou", "error");
      $("#panel-output").append(el("div", { class: "end error", text: errorText(e) }));
    }
  }

  async function follow(exec) {
    while (state.exec === exec) {
      let r;
      try { r = await API.events(exec.id, exec.seq, exec.controller.signal); }
      catch (e) {
        if (e.name === "AbortError") return;
        await new Promise((ok) => setTimeout(ok, 1000));
        continue;
      }
      for (const ev of r.events) { exec.seq = Math.max(exec.seq, ev.seq); handleEvent(ev); }
      if (r.status === "finished") return;
    }
  }

  function handleEvent(ev) {
    if (ev.type === "output") R.drawOutput($("#panel-output"), ev);
    else if (ev.type === "pause") pause(ev);
    else if (ev.type === "eval") evalResult(ev);
    else if (ev.type === "end") finish(ev);
  }

  function pause(ev) {
    runState(`pausado na linha ${ev.line} (${ev.reason === "breakpoint" ? "ponto de parada" : "passo"})`, "paused");
    debugButtons(true, true);
    editor.markCurrent(ev.line);
    drawVariables(ev.variables);
    $("#stack").replaceChildren(...(ev.stack || []).map((q) => el("li", { text: `${q.function}  linha ${q.line}` })));
  }

  function drawVariables(vars) {
    $("#variables tbody").replaceChildren(...(vars || []).map((v) =>
      el("tr", {}, el("td", {}, v.name, el("span", { class: "type", text: v.type })), el("td", { text: v.value }))));
  }

  function evalResult(ev) {
    const h = $("#console-history");
    h.append(el("div", { class: "input", text: "» " + ev.expression }), el("div", { class: ev.ok ? "" : "failed", text: ev.value }));
    h.scrollTop = h.scrollHeight;
    if (ev.variables) drawVariables(ev.variables);
  }

  function finish(ev) {
    state.exec = null;
    debugButtons(false, false);
    editor.markCurrent(null);
    const ok = ev.status === "success";
    runState(`${ev.status}${ev.duration_ms !== undefined ? ` em ${ev.duration_ms} ms` : ""}${ev.rolled_back ? " · alterações desfeitas (depuração)" : ""}`,
             ok ? "ok" : "error");
    const out = $("#panel-output");
    if (ok) {
      $("#result").textContent = JSON.stringify(ev.result, null, 2);
      out.append(el("div", { class: "end ok", text: "✔ concluído" + (ev.rolled_back ? " — transação desfeita (depuração sem confirmação)" : "") + R.usageText(ev.usage) }));
    } else {
      const e = ev.error || {};
      $("#result").textContent = JSON.stringify(e, null, 2);
      out.append(el("div", { class: "end error", text: `✘ ${e.code || "ERRO"}: ${e.message || ""}${e.trace ? "\n" + e.trace : ""}` }));
      if (e.line) editor.markError(e.line);
    }
  }

  async function debugCommand(action, extra = {}) {
    if (!state.exec) return;
    try { await API.command(state.exec.id, { action, ...extra }); debugButtons(false, true); runState("executando…"); }
    catch (e) { notice(errorText(e), true); }
  }

  function showPanel(name) {
    for (const a of $$("[data-panel]")) a.classList.toggle("active", a.dataset.panel === name);
    $("#panel-output").hidden = name !== "output";
    $("#panel-result").hidden = name !== "result";
  }

  // ------------------------------------------------------------------ versions / executions
  async function loadVersions() {
    const list = $("#version-list");
    if (!state.current || !state.current.version) { list.replaceChildren(el("li", { class: "muted", text: "Programa ainda não salvo." })); return; }
    const name = state.current.name;
    const vs = await API.versions(name);
    list.replaceChildren(...vs.map((v) => el("li", {
      onclick: async () => { const d = await API.version(name, v.version); $("#version-preview").textContent = d.source; },
    }, el("strong", { text: "v" + v.version }), el("span", { text: `${v.created_by} · ${fmtDate(v.created_at)}` }),
       el("span", { class: "muted", text: v.comment || "" }),
       el("span", { class: "actions" }, el("button", { class: "small", text: "Restaurar", onclick: async (e) => {
         e.stopPropagation();
         if (!confirm(`Restaurar a versão ${v.version}? Uma nova versão será criada.`)) return;
         await API.restore(name, v.version);
         markDirty(false);
         await openProgram(name);
       } })))));
  }

  async function loadExecutions() {
    const list = $("#execution-list");
    if (!state.current || !state.current.version) { list.replaceChildren(); return; }
    const rows = await API.executions(state.current.name);
    list.replaceChildren(...rows.map((x) => el("li", {
      onclick: async () => { $("#execution-detail").textContent = JSON.stringify(await API.execution(x.id), null, 2); },
    }, el("span", { class: "status-" + x.status, text: "●" }), el("span", { text: `v${x.version ?? "?"} · ${x.username}` }),
       el("span", { class: "muted", text: `${fmtDate(x.started_at)} · ${x.duration_ms ?? "…"} ms${x.error ? " · " + x.error : ""}${x.debug ? " · depuração" : ""}` }))));
    if (!rows.length) list.append(el("li", { class: "muted", text: "Nenhuma execução." }));
  }

  // Spec 019: static findings with lines, the program's statements and its last profile.
  const SEV = { info: ["ℹ", "informação", ""], warning: ["▲", "atenção", "warn"], serious: ["◆", "sério", "off"], critical: ["■", "crítico", "off"] };
  async function loadPerformance() {
    const box = $("#ptab-perf");
    if (!state.current || !state.current.version) { box.replaceChildren(el("p", { class: "muted", text: "Salve o programa para ver o desempenho." })); return; }
    box.replaceChildren(el("p", { class: "muted", text: "Carregando…" }));
    let p;
    try { p = await API.programPerformance(state.current.name); } catch (e) { box.replaceChildren(el("p", { class: "error", text: errorText(e) })); return; }
    const sevPill = (s) => { const [i, l, c] = SEV[s] || ["", s, ""]; return el("span", { class: "pill " + c, text: `${i} ${l}` }); };
    const profileButton = el("button", { class: "primary", text: "▶ Perfilar uma execução", onclick: async () => {
      let params;
      try { params = readParams(); } catch (e) { notice("Parâmetros inválidos: " + e.message, true); return; }
      profileButton.disabled = true;
      try {
        const r = await API.run(state.current.name, { params, profile: true });
        toast(r.error ? `Executou com erro (${r.error.code}); o perfil foi guardado.` : "Perfil guardado.", !!r.error);
      } catch (e) { toast(errorText(e), true); }
      profileButton.disabled = false;
      loadPerformance();
    } });
    const prof = p.profile && p.profile.profile;
    box.replaceChildren(
      el("h3", { text: "Análise do SQL do código" }),
      el("p", { class: "muted", text: "Padrões que já são lentos ou vão ficar com o volume — recalculado a cada vez que o programa é salvo." }),
      p.lint.length ? window.AnaUI.table([
        { label: "Linha", value: (f) => el("button", { class: "link", text: String(f.line), onclick: () => { selectTab("code"); editor.markError(f.line); } }), class: "num" },
        { label: "Severidade", value: (f) => sevPill(f.severity) },
        { label: "O que", value: (f) => f.message },
        { label: "Sugestão", value: (f) => f.suggestion },
        { label: "SQL", value: (f) => el("code", { text: f.sql || "" }) },
      ], p.lint) : el("p", { class: "ok-text", text: "✓ Nenhum apontamento no SQL deste programa." }),
      el("h3", { text: "Comandos SQL medidos" }),
      p.sql.length ? window.AnaCharts.render({ type: "bar", title: "Tempo total por comando", format: "number", unit: "ms",
        x: p.sql.slice(0, 8).map((r) => r.sql.slice(0, 50) + (r.sql.length > 50 ? "…" : "")), series: [{ name: "Tempo total", values: p.sql.slice(0, 8).map((r) => Number(r.total_ms)) }] }) : null,
      p.sql.length ? window.AnaUI.table([
        { label: "Comando", value: (r) => el("code", { text: r.sql.length > 100 ? r.sql.slice(0, 100) + "…" : r.sql, title: r.sql }) },
        { label: "Chamadas", value: (r) => r.calls, class: "num" },
        { label: "Médio (ms)", value: (r) => r.mean_ms, class: "num" },
        { label: "Máx. (ms)", value: (r) => r.max_ms, class: "num" },
        { label: "Varredura completa", value: (r) => (r.plan_summary && r.plan_summary.seq_scans || []).map((s) => s.table).join(", ") },
      ], p.sql) : el("p", { class: "muted", text: "Ainda sem medições (aparecem até 1 minuto depois de executar)." }),
      el("h3", { text: "Perfil" }),
      el("div", { class: "row-buttons" }, profileButton,
        el("span", { class: "muted", text: "Executa com os parâmetros da aba Código e mede onde o tempo é gasto." })),
      prof && prof.functions ? el("div", {},
        el("p", { class: "muted", text: `Última: ${fmtDate(p.profile.started_at)} · ${prof.sql_wait_ms} ms esperando SQL` }),
        window.AnaCharts.render({ type: "bar", title: "Funções com mais tempo", format: "number", unit: "ms",
          x: prof.functions.slice(0, 10).map((f) => `${f.function} (linha ${f.line})`), series: [{ name: "Tempo total", values: prof.functions.slice(0, 10).map((f) => f.total_ms) }] }),
        window.AnaUI.table([{ label: "Função", value: (f) => f.function }, { label: "Onde", value: (f) => `${f.where}:${f.line}` },
          { label: "Chamadas", value: (f) => f.calls, class: "num" }, { label: "Próprio (ms)", value: (f) => f.self_ms, class: "num" },
          { label: "Total (ms)", value: (f) => f.total_ms, class: "num" }], prof.functions)) : null);
  }

  async function loadSchedules() {
    const box = $("#ptab-schedules");
    if (!state.current || !state.current.version) { box.replaceChildren(el("p", { class: "muted", text: "Salve o programa para agendá-lo." })); return; }
    try { await window.AnaScheduler.render(box, { program: state.current.name }); } catch (e) { toast(errorText(e), true); }
  }

  // ------------------------------------------------------------------ data
  async function loadCatalog() {
    const items = await API.catalog();
    const bySchema = {};
    for (const t of items) (bySchema[t.schema] ||= []).push(t);
    const tableItem = (schema, t) => el("li", {}, el("div", {
      class: "node", title: t.comment || "", onclick: () => window.AnaStudio.go(`#/dev/data/${schema}/${t.name}`),
    }, el("span", { text: (t.kind === "table" ? "▦ " : "◫ ") + t.name }), el("span", { class: "tag", text: "~" + t.estimated_rows })));
    const folder = (schema) => el("li", {},
      el("div", { class: "node folder closed", text: `${schema} — ${R.moduleLabel(schema)}`, onclick: (e) => e.currentTarget.classList.toggle("closed") }),
      el("ul", {}, ...bySchema[schema].map((t) => tableItem(schema, t))));
    $("#catalog-tree").replaceChildren(...Object.keys(bySchema).sort().map(folder));
  }

  async function showTable(schema, name) {
    try {
      const t = await API.table(schema, name);
      $("#table-detail").replaceChildren(
        el("div", { class: "page-header" }, el("h2", { text: `${schema}.${name}` }),
          el("button", { text: "Consultar no console", onclick: () => {
            $("#sql-input").value = `SELECT * FROM ${schema}.${name} LIMIT 100`;
            $("#sql-input").focus();
          } })),
        dataTable(["coluna", "tipo", "nulo", "padrão", "comentário"],
                  t.columns.map((c) => [c.name, c.type, c.nullable ? "sim" : "não", c.default_value, c.comment])),
        el("details", {}, el("summary", { text: `Índices (${t.indexes.length}) e restrições (${t.constraints.length})` }),
          dataTable(["índice", "definição"], t.indexes.map((i) => [i.name, i.definition])),
          dataTable(["restrição", "definição"], t.constraints.map((r) => [r.name, r.definition]))));
    } catch (e) { toast(errorText(e), true); }
  }

  async function runSql(sql) {
    const target = $("#sql-result");
    try {
      const r = await API.sql(sql);
      target.replaceChildren(el("p", { class: "muted", text: `${r.rows.length} linha(s)${r.truncated ? " — truncado em 1000" : ""}` }),
                             dataTable(r.columns.map((c) => c.name), r.rows));
    } catch (e) { target.replaceChildren(el("pre", { class: "end error", text: errorText(e) })); }
  }

  // ------------------------------------------------------------------ events
  function wire() {
    for (const b of $$("[data-side]")) b.addEventListener("click", () =>
      window.AnaStudio.go(b.dataset.side === "data" ? "#/dev/data" : b.dataset.side === "patterns" ? "#/dev/patterns"
        : (state.current ? `#/dev/program/${state.current.name}` : "#/dev")));
    for (const b of $$("[data-ptab]")) b.addEventListener("click", () => selectTab(b.dataset.ptab));
    for (const a of $$("[data-panel]")) a.addEventListener("click", () => showPanel(a.dataset.panel));
    $("#filter").addEventListener("input", drawTree);
    $("#show-inactive").addEventListener("change", loadPrograms);
    $("#new-program").addEventListener("click", newProgram);
    $("#save").addEventListener("click", save);
    $("#purge").addEventListener("click", purge);
    $("#p-kind").addEventListener("change", () => runButtons(false));
    $("#run").addEventListener("click", () => run(false));
    $("#debug").addEventListener("click", () => run(true));
    $("#dbg-continue").addEventListener("click", () => debugCommand("continue"));
    $("#dbg-over").addEventListener("click", () => debugCommand("over"));
    $("#dbg-into").addEventListener("click", () => debugCommand("into"));
    $("#dbg-out").addEventListener("click", () => debugCommand("out"));
    $("#dbg-stop").addEventListener("click", () => debugCommand("stop"));
    $("#toggle-json").addEventListener("click", () => {
      const json = $("#params-json");
      if (json.hidden) { try { json.value = JSON.stringify(state.form.read(), null, 2); } catch (_) { /* keep */ } }
      json.hidden = !json.hidden;
      $("#params-form").hidden = !json.hidden;
    });
    for (const id of ["#p-description", "#p-kind", "#p-role", "#p-exposed", "#p-public", "#p-menu", "#p-restricted", "#p-active"]) {
      $(id).addEventListener("change", () => markDirty(true));
    }
    $("#console-form").addEventListener("submit", async (e) => {
      e.preventDefault();
      const expr = $("#console-input").value;
      $("#console-input").value = "";
      if (!state.exec || !expr) return;
      try { await API.command(state.exec.id, { action: "eval", expression: expr }); }
      catch (err) { evalResult({ expression: expr, ok: false, value: errorText(err) }); }
    });
    $("#sql-form").addEventListener("submit", (e) => { e.preventDefault(); runSql($("#sql-input").value); });

    document.addEventListener("keydown", (e) => {
      if ($("#area-dev").hidden || $("#program-view").hidden) return;
      const k = e.key;
      if ((e.ctrlKey || e.metaKey) && k.toLowerCase() === "s") { e.preventDefault(); save(); }
      else if (k === "F5") { e.preventDefault(); run(e.ctrlKey); }
      else if (k === "F9") { e.preventDefault(); editor.toggleBreakpoint(editor.cursorLine()); }
      else if (k === "F8") { e.preventDefault(); debugCommand("continue"); }
      else if (k === "F10") { e.preventDefault(); debugCommand("over"); }
      else if (k === "F11") { e.preventDefault(); debugCommand(e.shiftKey ? "out" : "into"); }
    });
    window.addEventListener("beforeunload", (e) => { if (state.dirty) { e.preventDefault(); e.returnValue = ""; } });
  }

  window.AnaDev = { show, programs: () => state.programs, isDirty: () => state.dirty };
})();
