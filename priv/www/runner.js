// Shared pieces for running programs: parameter forms (RF-005-07) and output
// rendering, used by Operation and Development.
"use strict";
(function () {
  const { el, dataTable } = window.AnaUI;

  // Module labels by program namespace (RF-020-03). Unknown namespaces
  // (customer programs) are shown as they are.
  const MODULES = {
    base: "Cadastros", inventory: "Estoque", sales: "Vendas", finance: "Financeiro",
    projects: "Projetos", analytics: "Analítico", supply: "Suprimentos", production: "Produção",
    logistics: "Logística", field: "Serviços em campo", demo: "Demonstração",
  };
  const moduleOf = (name) => name.split(".")[0];
  const moduleLabel = (m) => MODULES[m] || m;

  /** Builds a form from PARAMS; returns {node, read(), summary()}; read() throws when invalid.
   *  options: initial (values), onSubmit, submitLabel, showTypes (development),
   *  lookup(program, params) → Promise<[{value, label}]> for fields with "lookup". */
  function paramsForm(decl, options = {}) {
    const initial = options.initial || {};
    const form = el("form", { class: "params-form" });
    form.addEventListener("submit", (e) => { e.preventDefault(); if (options.onSubmit) options.onSubmit(); });
    const freeJson = !decl;
    const json = el("textarea", { class: "params-json", rows: 6, spellcheck: "false", value: "{}" });
    if (!decl) {
      form.append(el("p", { class: "muted", text: "Sem PARAMS declarados: informe os parâmetros em JSON." }), json);
    } else if (!Object.keys(decl).length) {
      form.append(el("p", { class: "muted", text: "Esta rotina não tem parâmetros." }));
    }
    // Declared order ("order", kept by the core); older programs fall back to the stored order.
    const entries = Object.entries(decl || {}).map(([n, sp], i) => [n, sp || {}, (sp && sp.order !== undefined) ? sp.order : i])
      .sort((a, b) => a[2] - b[2]);
    const inputs = {};
    const lookups = [];
    for (const [name, spec] of entries) {
      const type = spec.type || "str";
      const labelText = spec.label || name;
      const label = el("span", { class: spec.required ? "required" : "", text: labelText });
      const hint = options.showTypes ? el("span", { class: "hint", text: type }) : null;
      const init = initial[name];
      let input;
      if (type === "bool") {
        input = el("input", { type: "checkbox", name, checked: init !== undefined ? (init === true || init === "true") : spec.default === true });
        input.dataset.type = type;
        inputs[name] = input;
        form.append(el("label", { class: "check", title: spec.help || "" }, input, label));
        continue;
      }
      if (spec.choices || spec.lookup) {
        input = el("select", { name });
        const fill = (opts, keep) => {
          const current = keep !== undefined ? keep : input.value;
          input.replaceChildren(el("option", { value: "", text: spec.required ? "— escolha —" : "—" }),
            ...opts.map((o) => el("option", { value: String(o.value), text: o.label })));
          if (current !== "" && current !== undefined && current !== null) {
            if (![...input.options].some((o) => o.value === String(current))) input.append(el("option", { value: String(current), text: String(current) }));
            input.value = String(current);
          }
        };
        const start = init !== undefined ? init : (spec.default !== undefined && spec.default !== null ? spec.default : "");
        if (spec.choices) {
          fill(spec.choices.map((c) => Array.isArray(c) ? { value: c[0], label: c[1] } : { value: c, label: String(c) }), start);
        } else {
          fill([], start);
          lookups.push({ input, spec, fill, start });
        }
      } else if (type === "list" || type === "dict") {
        input = el("textarea", { name, rows: 3, spellcheck: "false" });
        input.value = init !== undefined ? (typeof init === "string" ? init : JSON.stringify(init))
          : spec.default !== undefined && spec.default !== null ? JSON.stringify(spec.default) : (type === "list" ? "[]" : "{}");
      } else {
        const types = { int: "number", float: "number", decimal: "text", date: "date" };
        input = el("input", { name, type: types[type] || "text", step: type === "float" ? "any" : undefined,
                              inputmode: type === "decimal" ? "decimal" : undefined });
        if (init !== undefined && init !== null) input.value = init;
        else if (spec.default !== undefined && spec.default !== null) input.value = spec.default;
      }
      input.dataset.type = type;
      input.dataset.label = labelText;
      if (spec.required) input.dataset.required = "1";
      inputs[name] = input;
      form.append(el("label", { title: spec.help || "" }, el("span", { class: "label-line" }, label, hint), input,
                     spec.help ? el("span", { class: "help", text: spec.help }) : null));
    }
    // Lookups (e.g. activities follow the chosen project): loaded now and again when a dependency changes.
    for (const lk of lookups) {
      const deps = lk.spec.lookup.depends || [];
      const load = (keep) => {
        if (!options.lookup) return;
        const params = { ...(lk.spec.lookup.params || {}) };
        for (const d of deps) if (inputs[d] && inputs[d].value !== "") params[d] = inputs[d].value;
        if (deps.some((d) => !(d in params))) { lk.fill([], keep); return; }
        lk.input.classList.add("loading");
        options.lookup(lk.spec.lookup.program, params)
          .then((opts) => lk.fill(Array.isArray(opts) ? opts : [], keep))
          .catch(() => lk.fill([], keep))
          .finally(() => lk.input.classList.remove("loading"));
      };
      load(lk.start);
      for (const d of deps) if (inputs[d]) inputs[d].addEventListener("change", () => load(""));
    }
    if (options.submitLabel) form.append(el("button", { class: "primary run-button", type: "submit", text: options.submitLabel }));

    function read() {
      if (freeJson) {
        const v = JSON.parse(json.value || "{}");
        if (typeof v !== "object" || Array.isArray(v) || v === null) throw new Error("parâmetros devem ser um objeto JSON");
        return v;
      }
      const r = {};
      const missing = [];
      for (const input of form.elements) {
        if (!input.name) continue;
        const type = input.dataset.type;
        if (input.type === "checkbox") { r[input.name] = input.checked; continue; }
        if (input.value === "") { if (input.dataset.required) missing.push(input.dataset.label); continue; }
        if (type === "list" || type === "dict") r[input.name] = JSON.parse(input.value);
        else if (type === "int") r[input.name] = parseInt(input.value, 10);
        else if (type === "float") r[input.name] = parseFloat(input.value);
        else r[input.name] = input.value;
      }
      if (missing.length) throw new Error("preencha " + missing.join(", "));
      return r;
    }

    /** "projeto: PRJ-001 · aba: Visão geral" — shown when the form is collapsed. */
    function summary() {
      const parts = [];
      for (const [name, spec] of entries) {
        const input = inputs[name];
        if (!input) continue;
        let v = input.type === "checkbox" ? (input.checked ? "sim" : "") : input.tagName === "SELECT"
          ? (input.value !== "" ? input.options[input.selectedIndex].text : "") : input.value;
        if (v && v !== "[]" && v !== "{}") parts.push(`${spec.label || name}: ${v}`);
      }
      return parts.join(" · ") || "sem parâmetros";
    }
    return { node: form, read, summary, focus: () => { const f = form.querySelector("input, select, textarea"); if (f) f.focus(); } };
  }

  /** Appends one output event to a container. `ctx` (optional) runs actions:
   *  {run(program, params) → Promise<result>, open(program, params), refresh()}. */
  function drawOutput(container, ev, ctx) {
    let node = null;
    if (ev.kind === "text") node = el("pre", { class: "text", text: ev.data });
    else if (ev.kind === "log") node = el("div", { class: "log " + ev.data.level, text: `[${ev.data.level}] ${ev.data.message}` });
    else if (ev.kind === "table") node = drawTable(ev.data, ctx);
    else if (ev.kind === "metrics") node = drawMetrics(ev.data);
    else if (ev.kind === "chart") node = window.AnaCharts.render(ev.data);
    else if (ev.kind === "board") node = drawBoard(ev.data, ctx);
    else if (ev.kind === "gantt") node = drawGantt(ev.data);
    else if (ev.kind === "tabs") node = drawTabs(ev.data, ctx);
    else if (ev.kind === "actions") node = drawActions(ev.data, ctx);
    if (!node) return;
    const atEnd = container.scrollTop + container.clientHeight >= container.scrollHeight - 8;
    container.append(node);
    if (atEnd) container.scrollTop = container.scrollHeight;
  }

  const show = (v) => (v === null || v === undefined ? "" : typeof v === "object" ? JSON.stringify(v) : String(v));

  function drawTable(d, ctx) {
    if (!d.row_actions) return dataTable(d.columns, d.rows, d.title);
    const box = dataTable(d.columns, d.rows, d.title, (i) => {
      const slot = el("div", { class: "action-form-row", hidden: true });
      const wrap = el("div", {}, (d.row_actions[i] || []).map((a) => actionButton(a, ctx, slot)), slot);
      return wrap;
    });
    return box;
  }

  function drawMetrics(d) {
    return el("div", {}, d.title ? el("h3", { text: d.title }) : null,
      el("div", { class: "stat-grid" }, d.items.map((m) => el("div", { class: "stat" + (m.status ? " stat-" + m.status : "") },
        el("div", { class: "label", text: m.label }), el("div", { class: "value", text: show(m.value) }),
        m.hint ? el("div", { class: "sub", text: m.hint }) : null))));
  }

  function drawBoard(d, ctx) {
    return el("div", {}, d.title ? el("h3", { text: d.title }) : null,
      el("div", { class: "board resizable" }, d.columns.map((col) => {
        const cards = d.cards.filter((c) => c.column === col.key);
        return el("section", { class: "board-col" }, el("h4", {}, col.label, el("span", { class: "muted", text: ` ${cards.length}` })),
          cards.map((c) => {
            const extra = el("div", { class: "action-form-row", hidden: true });
            return el("div", { class: "board-card" + (c.status ? " card-" + c.status : "") },
              el("strong", { text: c.title }), c.subtitle ? el("div", { class: "muted", text: c.subtitle }) : null,
              c.badges && c.badges.length ? el("div", { class: "badges" }, c.badges.map((b) => el("span", { class: "pill", text: b }))) : null,
              c.actions && c.actions.length ? el("div", { class: "row-buttons" }, c.actions.map((a) => actionButton(a, ctx, extra))) : null,
              extra);
          }));
      })));
  }

  const DAY = 86400000;
  const toDay = (s) => Math.floor(Date.parse(s + "T00:00:00Z") / DAY);

  function drawGantt(d) {
    const items = d.items.filter((i) => i.start && i.finish);
    const days = items.flatMap((i) => [i.start, i.finish, i.baseline_start, i.baseline_finish].filter(Boolean).map(toDay));
    if (d.today) days.push(toDay(d.today));
    if (!days.length) return el("p", { class: "muted", text: "Sem datas para a linha do tempo." });
    const min = Math.min(...days), max = Math.max(...days) + 1, span = Math.max(max - min, 1);
    const pos = (s) => ((toDay(s) - min) / span * 100).toFixed(3) + "%";
    const width = (a, b) => (Math.max(toDay(b) - toDay(a) + 1, 0.4) / span * 100).toFixed(3) + "%";
    const rows = items.map((i) => {
      const lane = el("div", { class: "gantt-lane" });
      if (i.baseline_start && i.baseline_finish) {
        lane.append(el("div", { class: "gantt-baseline", style: `left:${pos(i.baseline_start)};width:${width(i.baseline_start, i.baseline_finish)}` }));
      }
      const bar = el("div", { class: "gantt-bar" + (i.critical ? " critical" : "") + (i.kind === "phase" ? " phase" : ""),
        style: `left:${pos(i.start)};width:${width(i.start, i.finish)}`, title: `${i.start} → ${i.finish}${i.float !== undefined ? ` · folga ${i.float} d` : ""}` });
      if (i.progress) bar.append(el("div", { class: "gantt-progress", style: `width:${Math.min(100, i.progress)}%` }));
      lane.append(bar);
      if (d.today) lane.append(el("div", { class: "gantt-today", style: `left:${pos(d.today)}` }));
      return el("div", { class: "gantt-row" },
        el("div", { class: "gantt-label", style: `padding-left:${(i.level || 0) * 14}px`, title: i.name },
          el("span", { class: "muted", text: (i.code || "") + " " }), i.kind === "phase" ? el("strong", { text: i.name }) : i.name),
        lane);
    });
    return el("div", { class: "gantt resizable" }, d.title ? el("h3", { text: d.title }) : null,
      el("div", { class: "gantt-scale muted" }, el("span", { text: new Date(min * DAY).toISOString().slice(0, 10) }),
        el("span", { text: new Date((max - 1) * DAY).toISOString().slice(0, 10) })),
      ...rows,
      el("div", { class: "gantt-legend muted" }, el("span", { class: "gantt-key critical" }), " caminho crítico ",
        el("span", { class: "gantt-key baseline" }), " linha de base ", el("span", { class: "gantt-key today" }), " hoje"));
  }

  function drawTabs(d, ctx) {
    return el("div", { class: "sub-tabs output-tabs" }, d.items.map((a) => {
      const key = a.params && (a.params.view ?? a.label);
      return el("button", { class: key === d.current || a.label === d.current ? "active" : "", text: a.label,
        onclick: () => ctx && ctx.open(a.program, a.params || {}) });
    }));
  }

  function drawActions(d, ctx) {
    const extra = el("div", { class: "action-form-row", hidden: true });
    return el("div", { class: "next-actions" }, d.title ? el("h3", { text: d.title }) : null,
      el("div", { class: "row-buttons" }, d.items.map((a) => actionButton(a, ctx, extra))), extra);
  }

  /** One action: opens a routine, asks for fields inline, or runs right away. */
  function actionButton(a, ctx, slot) {
    const b = el("button", { type: "button", class: "small " + (a.style || ""), text: a.label });
    if (!ctx) { b.disabled = true; return b; }
    b.addEventListener("click", async () => {
      if (a.open) return ctx.open(a.program, a.params || {});
      if (a.ask) {
        const target = slot;
        const f = paramsForm(a.ask, { submitLabel: a.label, lookup: ctx.lookup, onSubmit: async () => {
          let values;
          try { values = f.read(); } catch (e) { window.AnaUI.toast("Parâmetros inválidos: " + e.message, true); return; }
          if (await execute(a, { ...(a.params || {}), ...values }, ctx)) slot.hidden = true;
        } });
        const cancel = el("button", { type: "button", class: "quiet", text: "Cancelar", onclick: () => { slot.hidden = true; } });
        target.replaceChildren(el("div", { class: "inline-form" }, el("strong", { text: a.label }), f.node, cancel));
        slot.hidden = false;
        const first = f.node.querySelector("input, textarea, select");
        if (first) first.focus();
        return;
      }
      if (a.confirm && !window.confirm(a.confirm)) return;
      await execute(a, a.params || {}, ctx);
    });
    return b;
  }

  async function execute(a, params, ctx) {
    try {
      const res = await ctx.run(a.program, params);
      if (res.error) { window.AnaUI.toast(`${res.error.code}: ${res.error.message || ""}`, true); return false; }
      window.AnaUI.toast(`${a.label}: feito.`);
      ctx.refresh();
      return true;
    } catch (e) { window.AnaUI.toast(window.AnaUI.errorText(e), true); return false; }
  }

  function usageText(u) {
    if (!u || u.cpu_ms === undefined) return "";
    return ` · CPU ${u.cpu_ms} ms · memória ${Math.round((u.max_rss_kb || 0) / 1024)} MiB · ${u.sql_count} SQL`;
  }

  window.AnaRunner = { paramsForm, drawOutput, usageText, moduleOf, moduleLabel };
})();
