// SPDX-FileCopyrightText: 2026 André Luis Pereira dos Santos
// SPDX-License-Identifier: AGPL-3.0-or-later
// Processes (spec 039): the company's process map, the modeler, simulation, cases, monitoring and
// discovery — and "Minhas tarefas". The diagram itself is drawn by bpm-diagram.js.
"use strict";
(function () {
  const API = window.AnaApi;
  const { $, el, fmtDate, toast, pill } = window.AnaUI;
  const D = () => window.AnaBpmDiagram;
  const main = () => $("#bpm-main");
  const go = (h) => { location.hash = h; };
  const enc = encodeURIComponent;
  const state = { catalog: null, editor: null, proc: null };

  async function call(program, params) {
    const res = await API.run(program, { params });
    if (res.error) { const e = new Error(res.error.message || res.error.code); e.code = res.error.code; e.data = res.error.data; throw e; }
    return res.result;
  }
  const errText = (e) => e.message + (e.data && e.data.issues ? ` (${e.data.issues.length} problema(s))` : "");
  const num = (v, d = 1) => (v === null || v === undefined ? "—" : Number(v).toLocaleString("pt-BR", { maximumFractionDigits: d }));
  const money = (v) => (v === null || v === undefined ? "—" : "R$ " + Number(v).toLocaleString("pt-BR", { minimumFractionDigits: 2, maximumFractionDigits: 2 }));
  const STATUS = { running: ["em andamento", "ok"], waiting: ["aguardando", ""], failed: ["com falha", "off"], done: ["concluído", "ok"], cancelled: ["cancelado", "off"] };
  const statusPill = (s) => { const [l, c] = STATUS[s] || [s, ""]; return pill(l, c); };
  /** replaceChildren without the null/false of optional parts. */
  const rc = (node, ...kids) => node.replaceChildren(...kids.flat().filter((k) => k !== null && k !== undefined && k !== false && k !== ""));
  const kpi = (label, value, hint, cls = "") => el("div", { class: "stat " + cls }, el("div", { class: "muted small", text: label }), el("strong", { text: value }), hint ? el("div", { class: "muted small", text: hint }) : null);

  // ------------------------------------------------------------------ navigation
  function nav(current) {
    const box = $("#bpm-nav");
    const link = (k, label, hash) => el("button", { class: "nav-link" + (current === k ? " active" : ""), text: label, onclick: () => go(hash) });
    const items = [el("div", { class: "nav-group", text: "Processos" }), link("map", "Mapa de processos", "#/bpm"),
                   link("tasks", "Minhas tarefas", "#/bpm/tasks"), link("cases", "Casos", "#/bpm/cases")];
    if (state.catalog) {
      items.push(el("div", { class: "nav-group", text: "Processos publicados" }));
      for (const p of state.catalog.processes.filter((x) => x.published && x.active).slice(0, 30)) {
        items.push(link("p:" + p.code, p.name, `#/bpm/p/${enc(p.code)}`));
      }
    }
    rc(box, ...items);
  }

  async function show(rest, query) {
    try { state.catalog = await call("bpm.catalog", {}); } catch (e) { rc(main(), el("p", { class: "error", text: e.message })); return; }
    const [a, b, c] = rest;
    if (state.editor && state.editor.dirty() && !(a === "p" && b === state.proc)) {
      if (!confirm("Há alterações não salvas no diagrama. Sair mesmo assim?")) { history.back(); return; }
    }
    state.editor = null;
    if (a === "tasks") { nav("tasks"); return tasks(); }
    if (a === "cases") { nav("cases"); return casesPage(query.process || null); }
    if (a === "case") { nav("cases"); return casePage(Number(b)); }
    if (a === "p" && b) { nav("p:" + b); state.proc = b; return processPage(b, c || "diagram", query); }
    nav("map");
    return mapPage(query.q || "");
  }

  // ------------------------------------------------------------------ map (RF-039-01)
  function mapPage(q) {
    const cat = state.catalog;
    const search = el("input", { type: "search", placeholder: "Buscar processo", value: q, "aria-label": "Buscar processo" });
    const box = el("div", { class: "bpm-map" });
    const draw = () => {
      const t = search.value.trim().toLowerCase();
      const all = cat.processes.filter((p) => !t || (p.name + " " + p.code).toLowerCase().includes(t));
      const kids = (parent) => all.filter((p) => (p.parent_code || null) === parent);
      const card = (p) => el("button", { type: "button", class: "bpm-card" + (p.active ? "" : " inactive"), onclick: () => go(`#/bpm/p/${enc(p.code)}`) },
        el("div", { class: "bpm-card-head" }, el("strong", { text: p.name }),
          p.flow_code ? pill("esteira", "") : p.published ? pill(`v${p.published}`, "ok") : pill("rascunho", "warn")),
        el("div", { class: "muted small", text: p.objective || p.code }),
        el("div", { class: "bpm-card-foot" },
          el("span", { text: `${p.open_cases} caso(s) aberto(s)` }),
          p.late ? el("span", { class: "warn-text", text: `${p.late} atrasada(s)` }) : null,
          p.owner ? el("span", { class: "muted", text: `dono: ${p.owner}` }) : null));
      const roots = kids(null);
      const chains = roots.filter((p) => p.level === "chain");
      const loose = roots.filter((p) => p.level !== "chain");
      const section = (title, items, sub) => el("section", { class: "bpm-chain" },
        el("h2", { text: title }), sub ? el("p", { class: "muted small", text: sub }) : null,
        el("div", { class: "bpm-cards" }, ...items.map((p) => el("div", { class: "bpm-card-wrap" }, card(p),
          ...kids(p.code).map((c) => el("div", { class: "bpm-sub" }, card(c)))))));
      rc(box, ...chains.map((c) => section(c.name, kids(c.code), c.objective)),
        loose.length ? section(chains.length ? "Outros processos" : "Processos", loose) : null,
        !all.length ? el("p", { class: "muted", text: t ? "Nada encontrado." : "Nenhum processo ainda: comece por um modelo pronto." }) : null);
    };
    search.addEventListener("input", draw);
    rc(main(), 
      el("div", { class: "page-header" }, el("h1", { text: "Mapa de processos" }),
        el("p", { class: "lead", text: "Como a empresa trabalha: desenhe, simule antes de mudar, execute dentro do ERP e acompanhe como acontece de verdade." })),
      el("div", { class: "md-toolbar" }, search, cat.can_design ? el("button", { type: "button", class: "primary", text: "Novo processo", onclick: newProcess }) : null),
      box);
    draw();
  }

  async function newProcess() {
    let opts;
    try { opts = (await call("bpm.model", { process: state.catalog.processes[0].code })).options; } catch (_) { opts = { templates: [] }; }
    const code = el("input", { type: "text", placeholder: "ex.: vendas.pedido", required: true });
    const name = el("input", { type: "text", placeholder: "ex.: Do pedido ao recebimento", required: true });
    const parent = el("select", {}, el("option", { value: "", text: "— no topo do mapa —" }),
      ...state.catalog.processes.filter((p) => !p.flow_code).map((p) => el("option", { value: p.code, text: p.name })));
    const level = el("select", {}, ...[["process", "Processo"], ["chain", "Cadeia de valor (agrupa processos)"], ["subprocess", "Subprocesso"]].map(([v, l]) => el("option", { value: v, text: l })));
    let template = "";
    const gallery = el("div", { class: "bpm-templates", role: "radiogroup", "aria-label": "Modelo pronto" });
    const pick = (code_, card_) => { template = code_; for (const c of gallery.children) c.classList.toggle("active", c === card_); };
    const blank = el("button", { type: "button", class: "bpm-template active", role: "radio" }, el("strong", { text: "Em branco" }), el("span", { class: "muted small", text: "Início e fim; você desenha o resto." }));
    blank.addEventListener("click", () => pick("", blank));
    gallery.append(blank, ...opts.templates.map((t) => {
      const b = el("button", { type: "button", class: "bpm-template", role: "radio" }, el("strong", { text: t.name }), el("span", { class: "muted small", text: t.description }));
      b.addEventListener("click", () => { pick(t.code, b); if (!name.value) name.value = t.name; if (!code.value) code.value = t.code.replace(/_/g, "."); });
      return b;
    }));
    const msg = el("p", { class: "error" });
    const dlg = el("dialog", { class: "md-dialog bpm-dialog" },
      el("h3", { text: "Novo processo" }),
      el("div", { class: "form-grid" }, el("label", {}, "Código", code), el("label", {}, "Nome", name), el("label", {}, "Acima no mapa", parent), el("label", {}, "Nível", level)),
      el("h4", { text: "Começar de" }), gallery, msg,
      el("div", { class: "row-buttons" },
        el("button", { type: "button", class: "primary", text: "Criar", onclick: async () => {
          try {
            await call("bpm.save_process", { code: code.value.trim().toLowerCase(), name: name.value.trim(), parent: parent.value || null, level: level.value, template: template || null });
            dlg.close(); go(`#/bpm/p/${enc(code.value.trim().toLowerCase())}`);
          } catch (e) { msg.textContent = e.message; }
        } }),
        el("button", { type: "button", class: "quiet", text: "Cancelar", onclick: () => dlg.close() })));
    document.body.append(dlg);
    dlg.addEventListener("close", () => dlg.remove());
    dlg.showModal();
    code.focus();
  }

  // ------------------------------------------------------------------ process page
  const TABS = [["diagram", "Diagrama"], ["simulation", "Simulação"], ["cases", "Casos"], ["panel", "Painel"], ["discovery", "Descoberta"],
                ["versions", "Versões"], ["about", "Sobre"]];

  async function processPage(code, tab, query) {
    let data;
    try { data = await call("bpm.model", { process: code, version: query.version || null }); }
    catch (e) { rc(main(), el("p", { class: "error", text: e.message })); return; }
    const p = data.process;
    const head = el("div", { class: "bpm-head" },
      el("button", { type: "button", class: "quiet small", text: "← Mapa", onclick: () => go("#/bpm") }),
      el("h1", { text: p.name }),
      p.flow_code ? pill("esteira", "") : pill(data.status === "draft" ? `rascunho (v${data.version})` : data.status === "published" ? `publicada v${data.version}` : `v${data.version} aposentada`,
        data.status === "draft" ? "warn" : data.status === "published" ? "ok" : "off"));
    const strip = el("div", { class: "sub-tabs", role: "tablist" }, ...TABS.map(([k, l]) => el("button", { type: "button", role: "tab", class: k === tab ? "active" : "", text: l,
      onclick: () => go(`#/bpm/p/${enc(code)}/${k}`) })));
    const body = el("div", { class: "bpm-body" });
    rc(main(), head, strip, body);
    if (tab === "diagram") return diagramTab(body, code, data);
    if (tab === "simulation") return simulationTab(body, code, data);
    if (tab === "cases") return casesTab(body, code, data);
    if (tab === "panel") return panelTab(body, code, data);
    if (tab === "discovery") return discoveryTab(body, code, data);
    if (tab === "versions") return versionsTab(body, code, data);
    return aboutTab(body, code, data);
  }

  function diagramTab(body, code, data) {
    const p = data.process;
    const bar = el("div", { class: "bpm-actbar" });
    if (p.flow_code) bar.append(el("span", { class: "muted", text: "Esteira (spec 030): modos, condições e robô se configuram em Esteiras." }),
      el("button", { type: "button", class: "quiet small", text: "Abrir Esteiras", onclick: () => go("#/ops/flows/flows.configure") }));
    if (data.status !== "draft" && !p.flow_code && data.editable === false && state.catalog.can_design) {
      bar.append(el("button", { type: "button", class: "primary small", text: "Editar (cria rascunho)", onclick: async () => {
        try { await call("bpm.save_model", { process: code, model: data.model }); go(`#/bpm/p/${enc(code)}/diagram?r=${Date.now()}`); } catch (e) { toast(e.message, true); }
      } }));
    }
    if (data.can_publish && data.status === "draft") {
      bar.append(el("button", { type: "button", class: "primary small", text: "Publicar", onclick: async () => {
        if (state.editor && state.editor.dirty()) { toast("Salve antes de publicar.", true); return; }
        const comment = prompt("O que mudou nesta versão?", "");
        if (comment === null) return;
        try { const r = await call("bpm.publish", { process: code, comment });
              toast(`Versão ${r.version} publicada.` + (r.running_old ? ` ${r.running_old} caso(s) seguem na versão anterior (migre em Versões).` : ""));
              go(`#/bpm/p/${enc(code)}/diagram?r=${Date.now()}`); }
        catch (e) { toast(errText(e), true); }
      } }));
    }
    if (data.status === "published" && !p.flow_code) bar.append(el("button", { type: "button", class: "quiet small", text: "Iniciar caso", onclick: () => startCase(code, data.model) }));
    bar.append(el("button", { type: "button", class: "quiet small", text: "Exportar BPMN", onclick: async () => {
      try { const r = await call("bpm.bpmn", { action: "export", process: code, version: String(data.version) });
            const a = el("a", { href: URL.createObjectURL(new Blob([r.xml], { type: "application/xml" })), download: r.filename }); document.body.append(a); a.click(); a.remove(); }
      catch (e) { toast(e.message, true); }
    } }));
    if (data.editable) {
      const file = el("input", { type: "file", accept: ".bpmn,.xml", hidden: true });
      file.addEventListener("change", () => {
        const f = file.files[0]; if (!f) return;
        const rd = new FileReader();
        rd.onload = async () => {
          try { const r = await call("bpm.bpmn", { action: "import", process: code, xml: String(rd.result) });
                toast(r.warnings.length ? `Importado com ${r.warnings.length} aviso(s): ${r.warnings.slice(0, 3).join("; ")}` : "BPMN importado no rascunho.");
                go(`#/bpm/p/${enc(code)}/diagram?r=${Date.now()}`); }
          catch (e) { toast(e.message, true); }
        };
        rd.readAsText(f);
      });
      bar.append(file, el("button", { type: "button", class: "quiet small", text: "Importar BPMN", onclick: () => file.click() }));
    }
    const box = el("div");
    body.append(bar, box);
    let saving = false;
    state.editor = D().editor(box, {
      model: data.model, issues: data.issues, options: data.options, editable: data.editable, name: code,
      readonlyReason: data.status === "draft" ? "Somente leitura: desenhar exige o papel de desenvolvedor ou o grupo \"processos\"." : "Versão publicada: use \"Editar\" para criar um rascunho.",
      onSave: async (model) => {
        if (saving) return;
        saving = true;
        try { const r = await call("bpm.save_model", { process: code, model, base_updated_at: data.updated_at });
              data.updated_at = r.updated_at; state.editor.setIssues(r.issues); state.editor.saved();
              toast(r.issues.filter((i) => i.level === "error").length ? "Rascunho salvo (há erros a corrigir antes de publicar)." : "Rascunho salvo."); }
        catch (e) { toast(e.message, true); }
        finally { saving = false; }
      },
    });
  }

  async function startCase(code, model) {
    const doc = model.document && model.document !== "none";
    const key = doc ? prompt("Chave do documento que o caso segue (ex.: número do pedido):") : "";
    if (doc && !key) return;
    try { const r = await call("bpm.start", { process: code, document: key || null }); toast(`Caso ${r.case} iniciado.`); go(`#/bpm/case/${r.case}`); }
    catch (e) { toast(e.message, true); }
  }

  // ------------------------------------------------------------------ simulation (RF-039-08..10)
  function simulationTab(body, code, data) {
    const m = data.model;
    const p0 = { days: 60, hours_per_day: 8, arrivals_per_day: 10, runs: 5, seed: 42, ...(data.sim || {}) };
    const f = (label, value, attrs = {}) => { const i = el("input", { type: "text", inputmode: "decimal", value: String(value ?? ""), ...attrs }); return [el("label", {}, label, i), i]; };
    const [lDays, iDays] = f("Dias simulados", p0.days);
    const [lHours, iHours] = f("Horas de trabalho por dia", p0.hours_per_day);
    const [lArr, iArr] = f("Casos novos por dia", p0.arrivals_per_day);
    const [lRuns, iRuns] = f("Repetições", p0.runs);
    const [lSeed, iSeed] = f("Semente (mesma semente = mesmo resultado)", p0.seed);
    const res = p0.resources || {};
    const laneRows = (m.lanes || []).map((l) => {
      const c = el("input", { type: "text", inputmode: "numeric", value: String((res[l.id] || {}).count ?? 1) });
      const k = el("input", { type: "text", inputmode: "decimal", value: String((res[l.id] || {}).cost_hour ?? 0) });
      return { l, c, k, tr: el("tr", {}, el("td", { text: l.name }), el("td", {}, c), el("td", {}, k)) };
    });
    const durs = p0.durations || {};
    const work = m.nodes.filter((n) => !["start", "end", "annotation"].includes(n.type) && !n.type.startsWith("gw"));
    const nodeRows = work.map((n) => {
      const d = durs[n.id] || {};
      const dist = el("select", {}, ...[["", "padrão"], ["fixed", "fixa"], ["triangular", "mín/provável/máx"], ["uniform", "entre mín e máx"], ["exponential", "exponencial (média)"], ["empirical", "medida (calibrada)"]]
        .map(([v, l]) => el("option", { value: v, text: l })));
      dist.value = d.dist || "";
      const a = el("input", { type: "text", inputmode: "decimal", value: d.dist === "fixed" ? d.value ?? "" : d.min ?? d.mean ?? "", placeholder: "mín / valor / média" });
      const b = el("input", { type: "text", inputmode: "decimal", value: d.mode ?? "", placeholder: "provável" });
      const c = el("input", { type: "text", inputmode: "decimal", value: d.max ?? "", placeholder: "máx" });
      const auto = el("input", { type: "checkbox" });
      auto.checked = (p0.automate || []).includes(n.id);
      const keep = d.dist === "empirical" ? d.values : null;
      return { n, dist, a, b, c, auto, keep, tr: el("tr", {}, el("td", { text: n.name }), el("td", {}, dist), el("td", {}, a), el("td", {}, b), el("td", {}, c),
        el("td", {}, ["task_human", "task_approval"].includes(n.type) ? el("label", { class: "check", title: "E se esta tarefa fosse automática?" }, auto, " automatizar") : "")) };
    });
    const gws = m.edges.filter((e) => { const n = m.nodes.find((x) => x.id === e.from); return n && (n.type === "gw_xor" || n.type === "gw_or") && !e.on; });
    const probs = p0.probabilities || {};
    const probRows = gws.map((e) => {
      const i = el("input", { type: "text", inputmode: "decimal", value: probs[e.id] !== undefined ? String(Math.round(probs[e.id] * 1000) / 10) : "", placeholder: "%" });
      const from = m.nodes.find((x) => x.id === e.from), to = m.nodes.find((x) => x.id === e.to);
      return { e, i, tr: el("tr", {}, el("td", { text: from.name }), el("td", { text: `→ ${to.name}${e.name ? ` (${e.name})` : ""}` }), el("td", {}, i)) };
    });
    const parse = (i) => { const v = Number(String(i.value).replace(",", ".")); return Number.isFinite(v) ? v : undefined; };
    const params = () => {
      const out = { days: parse(iDays), hours_per_day: parse(iHours), arrivals_per_day: parse(iArr), runs: parse(iRuns), seed: parse(iSeed),
                    resources: {}, durations: {}, probabilities: {}, automate: [] };
      for (const r of laneRows) out.resources[r.l.id] = { count: parse(r.c) || 1, cost_hour: parse(r.k) || 0 };
      for (const r of nodeRows) {
        if (r.auto.checked) out.automate.push(r.n.id);
        const d = r.dist.value;
        if (!d) continue;
        if (d === "fixed") out.durations[r.n.id] = { dist: d, value: parse(r.a) || 0 };
        else if (d === "exponential") out.durations[r.n.id] = { dist: d, mean: parse(r.a) || 1 };
        else if (d === "empirical" && r.keep) out.durations[r.n.id] = { dist: d, values: r.keep };
        else if (d !== "empirical") out.durations[r.n.id] = { dist: d, min: parse(r.a) || 0, mode: parse(r.b) ?? parse(r.a) ?? 0, max: parse(r.c) ?? parse(r.a) ?? 0 };
      }
      for (const r of probRows) { const v = parse(r.i); if (v !== undefined) out.probabilities[r.e.id] = v / 100; }
      return out;
    };
    const resultBox = el("div", { class: "bpm-sim-result" });
    const diagBox = el("div");
    const viewer = D().viewer(diagBox, m, { compact: true, label: "Animação da simulação" });
    let stop = () => {};
    const run = async (save) => {
      const name = save ? prompt("Nome do cenário (ex.: 3 técnicos):", "cenário") : null;
      if (save && !name) return;
      rc(resultBox, el("p", { class: "muted", text: "Simulando…" }));
      try {
        const r = await call("bpm.simulate", { process: code, version: String(data.version), params: params(), name, save: !!save });
        drawResult(r.result);
        stop(); stop = D().animate(viewer, m, r.result.trace);
        if (save) { toast("Cenário guardado."); loadScenarios(); }
      } catch (e) { rc(resultBox, el("p", { class: "error", text: errText(e) })); }
    };
    function drawResult(r) {
      const lanes = Object.values(r.lanes || {});
      rc(resultBox, 
        el("div", { class: "stat-grid" },
          kpi("Prazo médio", `${num(r.cycle_days.avg)} dia(s)`, `${num(r.cycle_h.avg)} h`),
          kpi("Prazo de 90 % dos casos", `${num(r.cycle_days.p90)} dia(s)`, `metade em até ${num(r.cycle_days.p50)} dia(s)`),
          kpi("Custo por caso", money(r.cost_per_case)),
          kpi("Concluídos por semana", num(r.throughput_week)),
          kpi("Em aberto no fim", num(r.wip_end), `${num(r.cases)} casos no período`),
          kpi("Gargalo", r.bottleneck ? r.bottleneck.name : "nenhum", r.bottleneck ? (r.bottleneck.kind === "lane" ? `pessoas ocupadas ${num(r.bottleneck.utilization * 100, 0)} % do tempo` : `espera média ${D().fmtH(r.bottleneck.wait_h)}`) : "", r.bottleneck ? "stat-bad" : "stat-ok")),
        lanes.length ? el("div", { class: "bpm-bars", role: "table", "aria-label": "Ocupação das pessoas por raia" },
          el("h4", { text: "Ocupação das pessoas por raia" }),
          ...lanes.map((l) => el("div", { class: "bpm-bar", role: "row" }, el("span", { role: "cell", text: `${l.name} (${l.count})` }),
            el("span", { class: "bpm-bar-track", role: "cell" }, el("span", { class: "bpm-bar-fill" + (l.utilization >= 0.85 ? " hot" : ""), style: `width:${Math.min(100, l.utilization * 100).toFixed(1)}%` })),
            el("span", { role: "cell", class: "num", text: `${num(l.utilization * 100, 0)} %` })))) : null,
        el("div", { class: "table-box" }, el("table", { class: "data-table" },
          el("thead", {}, el("tr", {}, ...["Elemento", "Vezes", "Espera média", "Execução média"].map((h) => el("th", { text: h })))),
          el("tbody", {}, ...Object.values(r.nodes).map((n) => el("tr", {}, el("td", { text: n.name }), el("td", { class: "num", text: num(n.visits) }),
            el("td", { class: "num", text: D().fmtH(n.wait_h) }), el("td", { class: "num", text: D().fmtH(n.service_h) })))))),
        el("p", { class: "muted small", text: `${r.runs} repetição(ões), semente ${r.seed}. A animação mostra os primeiros casos da primeira repetição.` }));
    }
    const scen = el("div");
    async function loadScenarios() {
      try {
        const r = await call("bpm.scenarios", { process: code });
        const picked = new Set();
        const cmp = el("div");
        const draw = () => {
          const two = r.scenarios.filter((x) => picked.has(x.id));
          if (two.length !== 2) { rc(cmp, el("p", { class: "muted small", text: "Marque dois cenários para comparar." })); return; }
          const [a, b] = two;
          const row = (label, fa, fmt, better) => {
            const va = fa(a.result), vb = fa(b.result);
            const d = va !== null && vb !== null && va !== undefined && vb !== undefined ? vb - va : null;
            return el("tr", {}, el("td", { text: label }), el("td", { class: "num", text: fmt(va) }), el("td", { class: "num", text: fmt(vb) }),
              el("td", { class: "num " + (d === null || d === 0 ? "" : (better === "low" ? d < 0 : d > 0) ? "ok-text" : "warn-text"), text: d === null ? "—" : (d > 0 ? "+" : "") + fmt(d) }));
          };
          rc(cmp, el("table", { class: "data-table" },
            el("thead", {}, el("tr", {}, el("th", { text: "" }), el("th", { text: a.name }), el("th", { text: b.name }), el("th", { text: "Diferença" }))),
            el("tbody", {}, row("Prazo médio (dias)", (x) => x.cycle_days.avg, (v) => num(v), "low"), row("Prazo de 90 % (dias)", (x) => x.cycle_days.p90, (v) => num(v), "low"),
              row("Custo por caso", (x) => x.cost_per_case, money, "low"), row("Concluídos por semana", (x) => x.throughput_week, (v) => num(v), "high"))));
        };
        rc(scen, el("h3", { text: "Cenários guardados" }),
          r.scenarios.length ? el("ul", { class: "link-list" }, ...r.scenarios.map((x) => {
            const cb = el("input", { type: "checkbox", "aria-label": "Comparar " + x.name });
            cb.addEventListener("change", () => { cb.checked ? picked.add(x.id) : picked.delete(x.id); draw(); });
            return el("li", {}, cb, ` ${x.name} — prazo ${num(x.result.cycle_days.avg)} d, custo ${money(x.result.cost_per_case)} (${fmtDate(x.created_at)} por ${x.created_by})`);
          })) : el("p", { class: "muted small", text: "Nenhum ainda." }), cmp);
        draw();
      } catch (e) { rc(scen, el("p", { class: "error", text: e.message })); }
    }
    const calBox = el("div");
    const qualityTable = (q) => {
      const rows = q.map(([k, v]) => el("tr", {},
        el("td", { text: (m.nodes.find((n) => n.id === k) || {}).name || k }), el("td", { class: "num", text: String(v.samples) }),
        el("td", { class: "num", text: D().fmtH(v.avg_h) }), el("td", { class: "num", text: D().fmtH(v.p90_h) })));
      return el("table", { class: "data-table" }, el("thead", {}, el("tr", {}, ...["Elemento", "Amostras", "Média", "90 %"].map((h) => el("th", { text: h })))),
        el("tbody", {}, ...rows));
    };
    const calibrate = async () => {
      rc(calBox, el("p", { class: "muted", text: "Medindo os casos reais…" }));
      try {
        const r = await call("bpm.calibrate", { process: code, days: 90 });
        const q = Object.entries(r.quality);
        rc(calBox, el("p", {}, `${r.cases_started} caso(s) iniciados e ${r.real_cases} concluídos nos últimos 90 dias; prazo médio real ${D().fmtH(r.real_cycle_h)}.`),
          q.length ? qualityTable(q) : el("p", { class: "muted", text: "Ainda não há casos suficientes para calibrar." }),
          q.length ? el("button", { type: "button", class: "primary small", text: "Simular com os números reais", onclick: async () => {
            rc(resultBox, el("p", { class: "muted", text: "Simulando…" }));
            try { const s2 = await call("bpm.simulate", { process: code, version: String(data.version), params: r.params }); drawResult(s2.result); stop(); stop = D().animate(viewer, m, s2.result.trace); }
            catch (e) { toast(e.message, true); }
          } }) : null);
      } catch (e) { rc(calBox, el("p", { class: "error", text: e.message })); }
    };
    body.append(
      el("p", { class: "lead", text: "Teste mudanças antes de fazê-las: quantas pessoas por raia, quanto tempo cada etapa leva, que caminho os casos seguem. Use a calibração para começar dos números reais." }),
      el("div", { class: "bpm-sim" },
        el("div", { class: "bpm-sim-params" },
          el("div", { class: "form-grid" }, lDays, lArr, lHours, lRuns, lSeed),
          laneRows.length ? el("details", { open: true }, el("summary", { text: "Pessoas por raia" }), el("table", { class: "data-table" },
            el("thead", {}, el("tr", {}, ...["Raia", "Pessoas", "Custo/hora"].map((h) => el("th", { text: h })))), el("tbody", {}, ...laneRows.map((r) => r.tr)))) : null,
          el("details", {}, el("summary", { text: "Durações (horas)" }), el("table", { class: "data-table" },
            el("thead", {}, el("tr", {}, ...["Elemento", "Distribuição", "Mín/valor", "Provável", "Máx", ""].map((h) => el("th", { text: h })))), el("tbody", {}, ...nodeRows.map((r) => r.tr)))),
          probRows.length ? el("details", {}, el("summary", { text: "Caminhos das decisões (%)" }), el("table", { class: "data-table" },
            el("thead", {}, el("tr", {}, ...["Decisão", "Caminho", "%"].map((h) => el("th", { text: h })))), el("tbody", {}, ...probRows.map((r) => r.tr)))) : null,
          el("div", { class: "row-buttons" },
            el("button", { type: "button", class: "primary", text: "Simular", onclick: () => run(false) }),
            el("button", { type: "button", class: "quiet", text: "Guardar como cenário", onclick: () => run(true) }),
            el("button", { type: "button", class: "quiet", text: "Calibrar pela realidade", onclick: calibrate })),
          calBox),
        el("div", { class: "bpm-sim-out" }, resultBox, diagBox)),
      scen);
    loadScenarios();
  }

  // ------------------------------------------------------------------ cases
  async function casesTab(body, code, data) {
    if (data.process.flow_code) {
      body.append(el("p", {}, "Os casos desta esteira ficam no quadro de Esteiras. ",
        el("button", { type: "button", class: "quiet small", text: "Abrir o quadro", onclick: () => go(`#/ops/flows/flows.board?flow=${data.process.flow_code}`) })));
      return;
    }
    const list = el("div");
    const status = el("select", {}, ...[["open", "Em andamento"], ["failed", "Com falha"], ["done", "Concluídos"], ["all", "Todos"]].map(([v, l]) => el("option", { value: v, text: l })));
    const load = async () => {
      const r = await call("bpm.cases", { process: code, status: status.value });
      rc(list, caseTable(r.cases, false));
    };
    status.addEventListener("change", load);
    body.append(el("div", { class: "md-toolbar" }, status, data.status === "published" || (data.versions || []).some((v) => v.status === "published")
      ? el("button", { type: "button", class: "primary small", text: "Iniciar caso", onclick: () => startCase(code, data.model) }) : null), list);
    load().catch((e) => rc(list, el("p", { class: "error", text: e.message })));
  }
  function caseTable(rows, withProcess) {
    if (!rows.length) return el("p", { class: "muted", text: "Nenhum caso." });
    const tb = el("tbody");
    for (const c of rows) {
      const tr = el("tr", { class: "row-open", tabindex: "0" }, el("td", { text: String(c.id) }), withProcess ? el("td", { text: c.process }) : null,
        el("td", { text: c.title }), el("td", {}, statusPill(c.status)), el("td", { text: c.at || (c.reason || "") }),
        el("td", {}, c.late ? pill(`${c.late} atrasada(s)`, "warn") : ""), el("td", { text: fmtDate(c.started_at) }));
      tr.addEventListener("click", () => go(`#/bpm/case/${c.id}`));
      tr.addEventListener("keydown", (ev) => { if (ev.key === "Enter") go(`#/bpm/case/${c.id}`); });
      tb.append(tr);
    }
    return el("div", { class: "table-box" }, el("table", { class: "data-table" },
      el("thead", {}, el("tr", {}, ...["Caso", withProcess ? "Processo" : null, "Título", "Situação", "Onde está", "", "Início"].filter((x) => x !== null).map((h) => el("th", { text: h })))), tb));
  }
  async function casesPage(process) {
    const q = el("input", { type: "search", placeholder: "Buscar caso" });
    const status = el("select", {}, ...[["open", "Em andamento"], ["failed", "Com falha"], ["done", "Concluídos"], ["all", "Todos"]].map(([v, l]) => el("option", { value: v, text: l })));
    const list = el("div");
    let t = null;
    const load = async () => { try { const r = await call("bpm.cases", { process, status: status.value, q: q.value || null }); rc(list, caseTable(r.cases, true)); } catch (e) { rc(list, el("p", { class: "error", text: e.message })); } };
    q.addEventListener("input", () => { clearTimeout(t); t = setTimeout(load, 250); });
    status.addEventListener("change", load);
    rc(main(), el("h1", { text: "Casos" }), el("div", { class: "md-toolbar" }, q, status), list);
    load();
  }

  async function casePage(id) {
    let r;
    try { r = await call("bpm.case", { case: id }); } catch (e) { rc(main(), el("p", { class: "error", text: e.message })); return; }
    const c = r.case;
    const diag = el("div");
    const act = async (action, extra = {}) => {
      try { await call("bpm.case_action", { case: id, action, ...extra }); toast("Feito."); setTimeout(() => casePage(id), 600); } catch (e) { toast(e.message, true); }
    };
    const tasksTb = el("tbody", {}, ...r.tasks.filter((t) => !(t.kind === "rule" && ["Início", "Junção"].includes(t.name))).map((t) => el("tr", {},
      el("td", { text: t.name }), el("td", {}, statusPill(t.status === "done" ? "done" : t.status === "failed" ? "failed" : t.status === "cancelled" ? "cancelled" : "waiting")),
      el("td", { text: t.done_by || t.assignee || t.role || t.group_name || (t.kind === "auto" ? "automática" : "") }),
      el("td", { text: D().fmtH(Number(t.hours)) }), el("td", { text: t.outcome || t.how || "" }),
      el("td", { text: t.error ? t.error.message : (t.comment || "") }),
      el("td", { class: "cell-actions" },
        r.can_manage && t.status === "failed" ? el("button", { type: "button", class: "quiet small", text: "Reprocessar", onclick: () => act("retry", { task: t.id }) }) : null,
        r.can_manage && ["waiting", "failed", "ready"].includes(t.status) ? el("button", { type: "button", class: "quiet small", text: "Pular", onclick: () => {
          const why = prompt("Por que pular esta etapa?"); if (why) act("skip", { task: t.id, reason: why });
        } }) : null,
        t.child_case ? el("a", { href: `#/bpm/case/${t.child_case}`, text: `subprocesso ${t.child_case}` }) : null))));
    const timeline = el("ol", { class: "bpm-timeline" }, ...r.events.slice().reverse().slice(0, 200).map((e) => el("li", {},
      el("span", { class: "muted small", text: fmtDate(e.at) }), " ",
      el("strong", { text: ({ start: "Início", enter: "Chegou em", done: "Concluiu", skip: "Pulou", warn: "Aviso de prazo", escalate: "Escalonou", error: "Erro", retry: "Reprocessou",
                              cancel: "Cancelou", end: "Fim em", delegate: "Delegou", claim: "Pegou", release: "Devolveu", comment: "Comentou", migrate: "Migrou de versão", wait: "Aguardando junção", fail: "Falha" })[e.kind] || e.kind }),
      " ", e.node ? (r.names[e.node] || e.node) : "", e.by ? el("span", { class: "muted", text: ` — ${e.by}` }) : null,
      e.detail && (e.detail.reason || e.detail.text || e.detail.message || e.detail.comment) ? el("div", { class: "muted small", text: e.detail.reason || e.detail.text || e.detail.message || e.detail.comment }) : null)));
    const vars = { ...c.data }; delete vars.doc;
    rc(main(), 
      el("div", { class: "bpm-head" }, el("button", { type: "button", class: "quiet small", text: "← " + c.process, onclick: () => go(`#/bpm/p/${enc(c.process_code)}/cases`) }),
        el("h1", { text: `Caso ${c.id}: ${c.title}` }), statusPill(c.status)),
      el("p", { class: "muted" }, `Versão ${c.version} · iniciado por ${c.started_by} em ${fmtDate(c.started_at)}`,
        c.doc_key && c.doc_program ? el("span", {}, " · ", el("a", { href: `#/ops/docs/docs.view?kind=${c.doc_program}&key=${enc(c.doc_key)}`, text: `${c.doc_label} ${c.doc_key}` })) : null,
        c.reason ? el("span", { class: "warn-text", text: ` · ${c.reason}` }) : null),
      r.can_manage ? el("div", { class: "row-buttons" },
        r.newest_version && r.newest_version !== c.version ? el("button", { type: "button", class: "quiet small", text: `Migrar para a versão ${r.newest_version}`, onclick: () => act("migrate") }) : null,
        el("button", { type: "button", class: "danger small", text: "Cancelar o caso", onclick: () => { const why = prompt("Motivo do cancelamento:"); if (why) act("cancel", { reason: why }); } })) : null,
      diag,
      el("div", { class: "bpm-case-cols" },
        el("section", {}, el("h3", { text: "Tarefas" }), el("div", { class: "table-box" }, el("table", { class: "data-table" },
          el("thead", {}, el("tr", {}, ...["Tarefa", "Situação", "Quem", "Tempo", "Resultado", "Observação", ""].map((h) => el("th", { text: h })))), tasksTb))),
        el("section", {}, el("h3", { text: "Linha do tempo" }), timeline,
          Object.keys(vars).length ? el("details", {}, el("summary", { text: "Dados do caso" }), el("pre", { class: "json", text: JSON.stringify(vars, null, 2) })) : null)));
    D().viewer(diag, r.model, { path: { done: r.done, current: r.current, failed: r.failed }, label: "Caminho do caso no processo" });
  }

  // ------------------------------------------------------------------ panel (RF-039-15)
  async function panelTab(body, code, data) {
    const days = el("select", {}, ...[[30, "30 dias"], [90, "90 dias"], [365, "12 meses"]].map(([v, l]) => el("option", { value: String(v), text: l })));
    days.value = "90";
    const out = el("div");
    const load = async () => {
      try {
        const r = await call("bpm.dashboard", { process: code, days: Number(days.value) });
        const cy = r.cycle_h;
        const diag = el("div");
        const maxW = Math.max(1, ...r.weekly.map((w) => w.done));
        rc(out, 
          el("div", { class: "stat-grid" },
            kpi("Casos iniciados", num(r.cases.started, 0)), kpi("Concluídos", num(r.cases.done, 0)), kpi("Em aberto", num(r.cases.open, 0)),
            kpi("Com falha", num(r.cases.failed, 0), "", r.cases.failed ? "stat-bad" : ""), kpi("Com tarefa atrasada", num(r.cases.late, 0), "", r.cases.late ? "stat-warn" : ""),
            kpi("Prazo médio", D().fmtH(cy.avg), cy.target ? `meta ${D().fmtH(cy.target)}` : "sem meta (defina em Sobre)"),
            kpi("Prazo de 90 %", D().fmtH(cy.p90)), kpi("No prazo", cy.on_time_pct === null ? "—" : `${num(cy.on_time_pct)} %`, "", cy.on_time_pct !== null && cy.on_time_pct < 80 ? "stat-warn" : "")),
          el("h3", { text: "Concluídos por semana" }),
          r.weekly.length ? el("div", { class: "bpm-weekly", role: "table", "aria-label": "Casos concluídos por semana" }, ...r.weekly.map((w) => el("div", { class: "bpm-week", role: "row", title: `${w.week}: ${w.done}` },
            el("span", { class: "bpm-week-bar", style: `height:${(w.done / maxW * 100).toFixed(1)}%`, role: "cell" }), el("span", { class: "bpm-week-n", text: String(w.done), role: "cell" }),
            el("span", { class: "bpm-week-l muted small", text: String(w.week).slice(5, 10).split("-").reverse().join("/"), role: "cell" }))))
            : el("p", { class: "muted", text: "Nenhum caso concluído nas últimas 12 semanas." }),
          el("h3", { text: "Mapa de calor: tempo médio em cada elemento" }),
          el("p", { class: "muted small", text: "Quanto mais escuro, mais tempo os casos passam ali. O número mostra quantas vezes passou, o tempo médio e os atrasos." }),
          diag);
        D().viewer(diag, data.model, { heat: r.heat, label: "Mapa de calor do processo" });
      } catch (e) { rc(out, el("p", { class: "error", text: e.message })); }
    };
    days.addEventListener("change", load);
    body.append(el("div", { class: "md-toolbar" }, el("label", {}, "Período ", days)), out);
    load();
  }

  // ------------------------------------------------------------------ discovery (RF-039-16)
  async function discoveryTab(body, code, data) {
    const out = el("div", {}, el("p", { class: "muted", text: "Analisando os casos…" }));
    body.append(el("p", { class: "lead", text: "O caminho que os casos realmente seguiram, os mais frequentes primeiro, e onde fugiram do modelo publicado." }), out);
    try {
      const r = await call("bpm.discover", { process: code, days: 180 });
      const dc = r.deviation_counts;
      rc(out, 
        el("div", { class: "stat-grid" }, kpi("Casos analisados", num(r.cases, 0)), kpi("Variantes", num(r.variants.length, 0)),
          kpi("Etapas puladas", num(dc.skipped, 0), "", dc.skipped ? "stat-warn" : ""), kpi("Retrabalho", num(dc.rework, 0), "", dc.rework ? "stat-warn" : ""),
          kpi("Ordem fora do modelo", num(dc.order, 0), "", dc.order ? "stat-bad" : "")),
        el("h3", { text: "Variantes mais frequentes" }),
        r.variants.length ? el("ol", { class: "bpm-variants" }, ...r.variants.map((v) => el("li", {},
          el("div", { class: "bpm-variant-head" }, el("strong", { text: `${num(v.share_pct)} % (${v.count} caso(s))` }), el("span", { class: "muted", text: v.avg_h !== null ? ` · prazo médio ${D().fmtH(v.avg_h)}` : "" })),
          el("div", { class: "bpm-variant-bar" }, el("span", { style: `width:${v.share_pct}%` })),
          el("div", { class: "bpm-variant-path", text: v.labels.join(" → ") })))) : el("p", { class: "muted", text: "Ainda não há casos neste período." }),
        r.deviations.length ? el("details", {}, el("summary", { text: `Casos com desvio (${r.deviations.length})` }),
          el("ul", { class: "link-list" }, ...r.deviations.slice(0, 100).map((d) => el("li", {},
            data.process.flow_code ? el("span", { text: `Esteira, documento ${d.case}` }) : el("a", { href: `#/bpm/case/${d.case}`, text: `Caso ${d.case}` }),
            ": ", d.issues.map((i) => `${i.label} (${i.nodes.join(", ")})`).join("; "))))) : null,
        r.variants.length && state.catalog.can_design ? el("button", { type: "button", class: "quiet", text: "Criar um modelo a partir da variante principal", onclick: async () => {
          const codeNew = prompt("Código do novo processo (rascunho):", `${code.replace(/^esteira\./, "")}.real`);
          if (!codeNew) return;
          try { const x = await call("bpm.discover", { process: code, days: 180, to_model: codeNew }); toast("Rascunho criado."); go(`#/bpm/p/${enc(x.created)}`); }
          catch (e) { toast(e.message, true); }
        } }) : null);
    } catch (e) { rc(out, el("p", { class: "error", text: e.message })); }
  }

  // ------------------------------------------------------------------ versions (RF-039-06)
  async function versionsTab(body, code, data) {
    const rows = data.versions;
    const a = el("select", {}, ...rows.map((v) => el("option", { value: String(v.version), text: `v${v.version} (${{ draft: "rascunho", published: "publicada", retired: "aposentada" }[v.status]})` })));
    const b = a.cloneNode(true);
    if (rows.length > 1) { a.value = String(rows[1].version); b.value = String(rows[0].version); }
    const out = el("div");
    const compare = async () => {
      try {
        const r = await call("bpm.compare", { process: code, a: a.value, b: b.value });
        const vb = await call("bpm.model", { process: code, version: b.value });
        const diag = el("div");
        rc(out, el("p", {}, el("strong", { text: r.summary }), r.nodes.removed.length ? ` · removidos: ${r.nodes.removed.join(", ")}` : ""),
          el("p", { class: "muted small", text: "Verde: novo na versão mais nova. Âmbar: alterado." }), diag);
        D().viewer(diag, vb.model, { diff: r, label: "Diferença entre versões" });
      } catch (e) { rc(out, el("p", { class: "error", text: e.message })); }
    };
    body.append(
      el("div", { class: "table-box" }, el("table", { class: "data-table" },
        el("thead", {}, el("tr", {}, ...["Versão", "Situação", "O que mudou", "Criada", "Publicada"].map((h) => el("th", { text: h })))),
        el("tbody", {}, ...rows.map((v) => el("tr", { class: "row-open", tabindex: "0", onclick: () => go(`#/bpm/p/${enc(code)}/diagram?version=${v.version}`) },
          el("td", { text: `v${v.version}` }), el("td", {}, v.status === "published" ? pill("publicada", "ok") : v.status === "draft" ? pill("rascunho", "warn") : pill("aposentada", "off")),
          el("td", { text: v.comment || "" }), el("td", { text: `${fmtDate(v.created_at)} — ${v.created_by}` }), el("td", { text: v.published_at ? `${fmtDate(v.published_at)} — ${v.published_by}` : "" })))))),
      rows.length > 1 ? el("div", { class: "md-toolbar" }, el("span", { text: "Comparar " }), a, el("span", { text: " com " }), b,
        el("button", { type: "button", class: "primary small", text: "Comparar", onclick: compare })) : null,
      out);
  }

  // ------------------------------------------------------------------ about (catalog card)
  function aboutTab(body, code, data) {
    const p = data.process;
    const i = (v, attrs = {}) => el("input", { type: "text", value: v ?? "", ...attrs });
    const name = i(p.name), owner = i(p.owner), objective = i(p.objective), trig = i(p.trigger_text), outcome = i(p.outcome);
    const target = i((p.kpi || {}).cycle_hours, { inputmode: "decimal", placeholder: "horas" });
    const tags = i((p.tags || []).join(", "));
    const parent = el("select", {}, el("option", { value: "", text: "— no topo —" }), ...state.catalog.processes.filter((x) => x.code !== code && !x.flow_code).map((x) => el("option", { value: x.code, text: x.name })));
    parent.value = p.parent_code || "";
    const level = el("select", {}, ...[["process", "Processo"], ["chain", "Cadeia de valor"], ["subprocess", "Subprocesso"]].map(([v, l]) => el("option", { value: v, text: l })));
    level.value = p.level;
    const editable = state.catalog.can_design;
    body.append(el("div", { class: "form-grid" },
      el("label", {}, "Nome", name), el("label", {}, "Acima no mapa", parent), el("label", {}, "Nível", level), el("label", {}, "Dono (usuário)", owner),
      el("label", {}, "Objetivo", objective), el("label", {}, "O que dispara", trig), el("label", {}, "Resultado esperado", outcome),
      el("label", {}, "Meta de prazo (horas)", target), el("label", {}, "Etiquetas (vírgula)", tags)),
      editable ? el("div", { class: "row-buttons" }, el("button", { type: "button", class: "primary", text: "Salvar", onclick: async () => {
        try {
          const t = Number(String(target.value).replace(",", "."));
          await call("bpm.save_process", { code, name: name.value.trim(), parent: parent.value || null, level: level.value, owner: owner.value.trim() || null,
            objective: objective.value, trigger_text: trig.value, outcome: outcome.value, kpi: { ...(p.kpi || {}), cycle_hours: Number.isFinite(t) && target.value ? t : undefined },
            tags: tags.value.split(",").map((x) => x.trim()).filter(Boolean) });
          toast("Ficha salva.");
        } catch (e) { toast(e.message, true); }
      } })) : null);
  }

  // ------------------------------------------------------------------ my tasks (RF-039-12)
  function openTaskUrl(t) {
    if (!t.program) return null;
    const mod = t.program.split(".")[0];
    const qs = Object.entries(t.params || {}).filter(([, v]) => ["string", "number", "boolean"].includes(typeof v)).map(([k, v]) => `${enc(k)}=${enc(v)}`).join("&");
    return `#/ops/${mod}/${t.program}${qs ? "?" + qs : ""}`;
  }
  function taskCard(t, refresh) {
    const act = async (action, extra = {}) => {
      try { await call("bpm.task_action", { task: t.id, action, ...extra }); toast("Feito."); refresh(); } catch (e) { toast(e.message, true); }
    };
    const due = t.due_at ? new Date(t.due_at) : null;
    const url = openTaskUrl(t);
    return el("article", { class: "bpm-task" + (t.late ? " late" : ""), "aria-label": `Tarefa ${t.name}` },
      el("div", { class: "bpm-task-head" }, el("strong", { text: t.name }), t.late ? pill("atrasada", "off") : due ? pill(`prazo ${fmtDate(t.due_at)}`, "") : null,
        t.priority <= 2 ? pill(`prioridade ${t.priority}`, "warn") : null),
      el("div", { class: "muted small" }, el("a", { href: `#/bpm/case/${t.case_id}`, text: t.title }), ` · ${t.process}`,
        t.assignee ? ` · com ${t.assignee}` : ` · para ${t.group_name ? "grupo " + t.group_name : { user: "usuários", developer: "desenvolvedores", admin: "administradores" }[t.role] || t.role}`),
      t.instructions ? el("p", { class: "small", text: t.instructions }) : null,
      t.fact ? el("p", { class: "muted small", text: "Conclui sozinha quando o ERP registrar o resultado (ex.: ao expedir pelo programa)." }) : null,
      el("div", { class: "row-buttons" },
        url ? el("button", { type: "button", class: "primary small", text: "Abrir", onclick: () => go(url) }) : null,
        t.kind === "approval" ? el("button", { type: "button", class: url ? "quiet small" : "primary small", text: "Aprovar", onclick: () => act("approve", { comment: prompt("Comentário (opcional):") || null }) }) : null,
        t.kind === "approval" ? el("button", { type: "button", class: "quiet small", text: "Recusar", onclick: () => { const c = prompt("Motivo da recusa:"); if (c) act("reject", { comment: c }); } }) : null,
        t.kind === "human" ? el("button", { type: "button", class: url ? "quiet small" : "primary small", text: "Concluir", onclick: () => act("complete", { comment: null }) }) : null,
        !t.assignee ? el("button", { type: "button", class: "quiet small", text: "Pegar", onclick: () => act("claim") }) : null,
        t.assignee === window.AnaStudio.user().username && (t.role || t.group_name) ? el("button", { type: "button", class: "quiet small", text: "Devolver", onclick: () => act("release") }) : null,
        el("button", { type: "button", class: "quiet small", text: "Delegar", onclick: () => { const to = prompt("Delegar para (usuário):"); if (to) act("delegate", { to }); } }),
        el("button", { type: "button", class: "quiet small", text: "Comentar", onclick: () => { const c = prompt("Comentário:"); if (c) act("comment", { comment: c }); } })));
  }
  async function tasks() {
    const q = el("input", { type: "search", placeholder: "Buscar tarefa" });
    const scope = el("select", {}, ...[["mine", "Minhas e do meu papel/grupo"], ["assigned", "Só as atribuídas a mim"], ["all", "Todas (administrador)"]].map(([v, l]) => el("option", { value: v, text: l })));
    const list = el("div", { class: "bpm-tasks" });
    let t = null;
    const load = async () => {
      try {
        const r = await call("bpm.tasks", { scope: scope.value, q: q.value || null });
        rc(list, ...(r.tasks.length ? r.tasks.map((x) => taskCard(x, load)) : [el("p", { class: "muted", text: "Nenhuma tarefa esperando você. 🎉" })]));
        call("bpm.notifications", { all_read: true }).catch(() => {});
      } catch (e) { rc(list, el("p", { class: "error", text: e.message })); }
    };
    q.addEventListener("input", () => { clearTimeout(t); t = setTimeout(load, 250); });
    scope.addEventListener("change", load);
    rc(main(), el("h1", { text: "Minhas tarefas" }),
      el("p", { class: "lead", text: "O que os processos esperam de você: atrasadas primeiro, depois por prioridade e prazo." }),
      el("div", { class: "md-toolbar" }, q, scope), list);
    load();
  }

  /** Widget for Início: up to five tasks. */
  async function homeWidget(container) {
    try {
      const r = await call("bpm.tasks", { scope: "mine" });
      if (!r.tasks.length) { container.hidden = true; return 0; }
      container.hidden = false;
      rc(container, el("h2", {}, "Minhas tarefas ", el("span", { class: "table-count", text: `(${r.tasks.length}${r.late ? `, ${r.late} atrasada(s)` : ""})` })),
        el("div", { class: "bpm-tasks compact" }, ...r.tasks.slice(0, 5).map((x) => taskCard(x, () => homeWidget(container)))),
        r.tasks.length > 5 ? el("button", { type: "button", class: "quiet small", text: "Ver todas", onclick: () => go("#/bpm/tasks") }) : null);
      return r.tasks.length;
    } catch (_) { container.hidden = true; return 0; }
  }
  async function unread() {
    try { return (await call("bpm.tasks", { scope: "mine" })).unread; } catch (_) { return 0; }
  }

  window.AnaBpm = { show, homeWidget, unread };
})();
