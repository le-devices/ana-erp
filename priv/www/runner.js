// SPDX-FileCopyrightText: 2026 LE Devices
// SPDX-License-Identifier: AGPL-3.0-or-later
// Shared pieces for running programs: parameter forms (RF-005-07) and output
// rendering, used by Operation and Development.
"use strict";
(function () {
  const { el, dataTable } = window.AnaUI;

  // Module labels by program namespace (RF-020-03). Unknown namespaces
  // (customer programs) are shown as they are.
  const MODULES = {
    base: "Cadastros", master: "Cadastros", inventory: "Estoque", sales: "Vendas", finance: "Financeiro",
    projects: "Projetos", analytics: "Analítico", supply: "Compras", production: "Produção",
    logistics: "Logística e campo", field: "Logística e campo", demo: "Demonstração", files: "Documentos e arquivos",
    integration: "Integrações", flows: "Processos", bpm: "Processos", docs: "Documentos e arquivos", tax: "Fiscal",
  };
  const moduleOf = (name) => name.split(".")[0];
  const moduleLabel = (m) => MODULES[m] || m.charAt(0).toUpperCase() + m.slice(1);
  // Spec 020 (RF-020-19): business area and category of a routine ("Área/Categoria" in the program header);
  // without it, the area of the namespace. Programs of the company without a namespace of the product: "Da empresa".
  const AREA_ORDER = ["Vendas", "Compras", "Estoque", "Produção", "Logística e campo", "Projetos", "Financeiro", "Contabilidade", "Fiscal",
                      "Cadastros", "Processos", "Analítico", "Integrações", "Documentos e arquivos", "Demonstração"];
  const areaOf = (r) => (r.category ? r.category.split("/")[0].trim() : MODULES[moduleOf(r.name)] || "Da empresa");
  const categoryOf = (r) => (r.category && r.category.includes("/") ? r.category.split("/").slice(1).join("/").trim() : "Outras");
  const areaRank = (a) => { const i = AREA_ORDER.indexOf(a); return i < 0 ? 99 : i; };

  /** Calendar / clock button beside date and time fields: opens the browser's picker (no typing). */
  function pickerButton(input, type) {
    if (!["date", "datetime", "time"].includes(type)) return null;
    const iconName = type === "time" ? "clock" : "calendar";
    const b = el("button", { type: "button", class: "picker-btn", title: type === "time" ? "Escolher a hora" : "Escolher no calendário",
                             "aria-label": type === "time" ? "Escolher a hora" : "Escolher a data" }, window.AnaUI.icon(iconName, 16));
    b.addEventListener("click", () => {
      try { input.showPicker(); } catch (_) { input.focus(); }
    });
    const today = el("button", { type: "button", class: "picker-btn", title: type === "date" ? "Hoje" : "Agora",
                                 text: type === "date" ? "hoje" : "agora" });
    today.addEventListener("click", () => {
      const now = new Date();
      const pad = (n) => String(n).padStart(2, "0");
      const d = `${now.getFullYear()}-${pad(now.getMonth() + 1)}-${pad(now.getDate())}`;
      const t = `${pad(now.getHours())}:${pad(now.getMinutes())}`;
      input.value = type === "date" ? d : type === "time" ? t : `${d}T${t}`;
      input.dispatchEvent(new Event("change", { bubbles: true }));
    });
    return el("span", { class: "picker-btns" }, b, today);
  }

  // Spec 050 (T-050-08, RF-050-08): bar codes and QR codes read by the camera, where the browser reads codes
  // (BarcodeDetector) and there is a camera. A USB reader keeps working as a keyboard everywhere.
  const canScan = () => typeof window.BarcodeDetector === "function" && !!(navigator.mediaDevices && navigator.mediaDevices.getUserMedia);
  function putScanned(input, code) {
    if (input.tagName === "SELECT") {
      const op = [...input.options].find((o) => o.value === code) || [...input.options].find((o) => o.value && o.textContent.split(/\s+/).includes(code));
      if (!op) { window.AnaUI.toast(`Código ${code} lido, mas não está entre as opções deste campo.`, true); return; }
      input.value = op.value;
    } else input.value = code;
    input.dispatchEvent(new Event("input", { bubbles: true }));
    input.dispatchEvent(new Event("change", { bubbles: true }));
  }
  function scanButton(input, label) {
    if (!canScan()) return null;
    const b = el("button", { type: "button", class: "picker-btn scan-btn", title: `Ler ${label || "o código"} pela câmera`,
                             "aria-label": `Ler ${label || "o código"} pela câmera` }, window.AnaUI.icon("scan", 16));
    b.addEventListener("click", () => scan(input, label));
    return b;
  }
  async function scan(input, label) {
    const video = el("video", { class: "scan-video", autoplay: true, muted: true, playsinline: true, "aria-label": "Imagem da câmera" });
    const note = el("p", { class: "muted small", role: "status", text: "Aponte a câmera para o código de barras ou QR." });
    const cancel = el("button", { type: "button", class: "quiet", text: "Cancelar" });
    const dlg = el("dialog", { class: "md-dialog scan-dialog", "aria-label": `Ler ${label || "o código"} pela câmera` },
      el("h2", { text: `Ler ${label || "o código"}` }), video, note, el("div", { class: "row-buttons" }, cancel));
    let stream = null, done = false, timer = null;
    const stop = () => { done = true; clearTimeout(timer); if (stream) stream.getTracks().forEach((t) => t.stop()); };
    cancel.addEventListener("click", () => dlg.close());
    window.AnaUI.modal(dlg, stop);
    cancel.focus();
    try {
      stream = await navigator.mediaDevices.getUserMedia({ video: { facingMode: "environment" }, audio: false });
      if (done) { stop(); return; }
      video.srcObject = stream;                     // autoplay + muted: the browser plays it by itself
      const detector = new window.BarcodeDetector();
      const look = async () => {
        if (done) return;
        try {
          const codes = await detector.detect(video);
          const code = codes && codes[0] && String(codes[0].rawValue || "").trim();
          if (code) { dlg.close(); putScanned(input, code); return; }
        } catch (_) { /* the frame was not ready: try the next one */ }
        timer = setTimeout(look, 200);
      };
      look();
    } catch (e) {
      note.textContent = e && e.name === "NotAllowedError"
        ? "A câmera não foi liberada. Libere o acesso à câmera para este endereço no navegador e tente de novo."
        : "Não foi possível abrir a câmera. Digite o código ou use um leitor USB.";
    }
  }

  /** Typed number in Brazilian notation ("1.234,56") or plain ("1234.56"). */
  const brNumber = (t) => parseFloat(String(t).includes(",") ? String(t).replace(/\./g, "").replace(",", ".") : t);

  /** Editable rows for list PARAMS with "columns" (e.g. order items). */
  function rowsEditor(columns, startRows, hidden, options, topInputs, addLabel, optional) {
    // Declared order ("order", kept by the core): JSON objects have no order.
    const cols = Object.entries(columns).map(([c, cs], i) => [c, cs || {}, cs && cs.order !== undefined ? cs.order : i])
      .sort((a, b) => a[2] - b[2]).map(([c, cs]) => [c, cs]);
    const body = el("tbody");
    const optionsCache = {};
    const sync = () => {
      const rows = [];
      for (const tr of body.children) {
        const r = {};
        let any = false;
        for (const [c, cs] of cols) {
          const inp = tr.querySelector(`[data-col="${c}"]`);
          if (inp && inp.type === "checkbox") { r[c] = inp.checked; continue; }   // a yes/no alone does not make a line
          if (!inp || inp.value === "") continue;
          // Decimals travel in plain notation ("1.234,56" typed → "1234.56").
          r[c] = cs.type === "int" ? parseInt(inp.value, 10)
            : cs.type === "decimal" && inp.value.includes(",") ? inp.value.replace(/\./g, "").replace(",", ".") : inp.value;
          if (cs.default === undefined || String(cs.default) !== inp.value) any = true;   // an untouched line (defaults only) is not sent
        }
        if (any) rows.push(r);
      }
      hidden.value = rows.length ? JSON.stringify(rows) : "";
      total.textContent = lineTotalsText(rows.length);
    };
    const lineTotalsText = (filled) => {
      const lines = filled === 0 ? "nenhuma linha" : `${filled} linha(s)`;
      if (!columns.quantity || !columns.price) return lines;
      let sum = 0, known = true;
      for (const tr of body.children) {
        const q = brNumber((tr.querySelector('[data-col="quantity"]') || {}).value || "0");
        const pIn = tr.querySelector('[data-col="price"]');
        const p = brNumber((pIn && (pIn.value || pIn.placeholder)) || "");
        if (isNaN(p)) { known = false; continue; }
        sum += (isNaN(q) ? 0 : q) * p;
      }
      return `${lines} · total ${known ? "" : "≈ "}R$ ${sum.toLocaleString("pt-BR", { minimumFractionDigits: 2, maximumFractionDigits: 2 })}`;
    };
    const loadOptions = async (c, cs) => {
      const lk = cs.lookup;
      const params = { ...(lk.params || {}) };
      for (const d of lk.depends || []) if (topInputs[d] && topInputs[d].value !== "") params[d] = topInputs[d].value;
      const key = c + JSON.stringify(params);
      if (!optionsCache[key]) optionsCache[key] = options.lookup ? options.lookup(lk.program, params).catch(() => []) : Promise.resolve([]);
      return optionsCache[key];
    };
    const fillSelect = async (sel, c, cs, keep) => {
      const opts = cs.choices ? cs.choices.map((x) => Array.isArray(x) ? { value: x[0], label: x[1] } : { value: x, label: String(x) })
                              : await loadOptions(c, cs);
      sel.replaceChildren(el("option", { value: "", text: "— escolha —" }), ...opts.map((o) => {
        const op = el("option", { value: String(o.value), text: o.label });
        if (o.price !== undefined) op.dataset.price = String(o.price);
        if (o.stock !== undefined) op.dataset.stock = String(o.stock);
        if (o.kind) op.dataset.kind = o.kind;
        return op;
      }));
      if (keep !== undefined && keep !== "") {
        if (![...sel.options].some((o) => o.value === String(keep))) sel.append(el("option", { value: String(keep), text: String(keep) }));
        sel.value = String(keep);
      }
    };
    const addRow = (values = {}) => {
      const tr = el("tr");
      const status = el("span", { class: "row-status muted small" });
      for (const [c, cs] of cols) {
        let inp;
        if (cs.type === "bool") {
          inp = el("input", { "data-col": c, type: "checkbox", "aria-label": cs.label || c,
                              checked: values[c] !== undefined ? values[c] === true : cs.default === true });
        } else if (cs.lookup || cs.choices) {
          inp = el("select", { "data-col": c, "aria-label": cs.label || c });
          fillSelect(inp, c, cs, values[c]).then(() => { inp.dispatchEvent(new Event("refresh")); });
        } else {
          inp = el("input", { "data-col": c, type: cs.type === "int" ? "number" : cs.type === "date" ? "date" : "text",
                              inputmode: cs.type === "decimal" ? "decimal" : undefined, "aria-label": cs.label || c,
                              value: values[c] !== undefined ? values[c] : (cs.default !== undefined ? cs.default : "") });
        }
        inp.addEventListener("change", sync);
        inp.addEventListener("input", sync);
        const scanBtn = cs.scan ? scanButton(inp, cs.label || c) : null;
        tr.append(el("td", { "data-label": cs.label || c }, scanBtn ? el("span", { class: "picker-wrap" }, inp, scanBtn) : inp));
      }
      // Item chosen: list price as a hint and stock of the warehouse beside the quantity.
      const prodSel = tr.querySelector('[data-col="product"]');
      const priceIn = tr.querySelector('[data-col="price"]');
      const qtyIn = tr.querySelector('[data-col="quantity"]');
      const showStock = () => {
        const op = prodSel && prodSel.options[prodSel.selectedIndex];
        if (!op || !op.value) { status.textContent = ""; status.className = "row-status muted small"; return; }
        if (priceIn) priceIn.placeholder = op.dataset.price ? op.dataset.price.replace(".", ",") : "";
        if (op.dataset.kind === "service") { status.textContent = "serviço"; status.className = "row-status muted small"; }
        else if (op.dataset.stock !== undefined) {
          const stock = parseFloat(op.dataset.stock);
          const q = brNumber((qtyIn && qtyIn.value) || "0");
          status.textContent = `saldo ${stock.toLocaleString("pt-BR")}`;
          status.className = "row-status small " + (q > stock ? "warn" : "ok");
        }
        sync();
      };
      if (prodSel) { prodSel.addEventListener("change", showStock); prodSel.addEventListener("refresh", showStock); }
      if (qtyIn) qtyIn.addEventListener("input", showStock);
      tr.append(el("td", {}, status), el("td", { class: "row-remove" }, el("button", { type: "button", class: "quiet small", title: "Remover a linha",
        "aria-label": "Remover a linha", onclick: () => { tr.remove(); sync(); } }, window.AnaUI.icon("close", 14))));
      body.append(tr);
      sync();
      return tr;
    };
    const total = el("span", { class: "muted small" });
    const table = el("table", { class: "rows-editor" },
      el("thead", {}, el("tr", {}, cols.map(([c, cs]) => el("th", { class: cs.required ? "required" : "", text: cs.label || c })),
        el("th", { text: "" }), el("th", { text: "" }))), body);
    // An optional grid ("vazio = tudo") starts empty: an untouched line would look mandatory.
    (startRows.length ? startRows : optional ? [] : [{}]).forEach((r) => addRow(r));
    if (!body.children.length) sync();
    // Options that depend on top-level fields (warehouse) are reloaded when those change.
    for (const [c, cs] of cols) {
      for (const d of (cs.lookup && cs.lookup.depends) || []) {
        const top = topInputs[d];
        if (top) top.addEventListener("change", () => {
          for (const tr of body.children) { const sel = tr.querySelector(`[data-col="${c}"]`); if (sel) fillSelect(sel, c, cs, sel.value).then(() => sel.dispatchEvent(new Event("refresh"))); }
        });
      }
    }
    return el("div", { class: "rows-box" }, table,
      el("div", { class: "rows-foot" }, el("button", { type: "button", class: "small icon-text", onclick: () => {
        const tr = addRow(); const f = tr.querySelector("select, input"); if (f) f.focus(); } }, window.AnaUI.icon("plus", 14), el("span", { text: addLabel || "Adicionar linha" })),
        total));
  }

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
    const deferred = [];         // run once every field exists (dependencies declared later in the form)
    for (const [name, spec] of entries) {
      if (spec.simulate && options.simulate) continue;     // set by the "Simular" button (RF-020-13)
      const type = spec.type || "str";
      let labelText = spec.label || name;
      // A list with "(vazio = X)" in its label shows X as the empty option instead (shorter label).
      let emptyText = spec.empty;
      const vazio = (spec.choices || spec.lookup) && !emptyText && /\s*\(vazio = ([^)]+)\)$/.exec(labelText);
      if (vazio) { emptyText = vazio[1]; labelText = labelText.slice(0, vazio.index); }
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
          input.replaceChildren(el("option", { value: "", text: spec.required ? "— escolha —" : emptyText ? `— ${emptyText} —` : "—" }),
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
      } else if (type === "list" && spec.columns) {
        // Rows editor (spec 029): one line per item, columns typed like fields, lookups that follow
        // other fields (e.g. stock of the chosen warehouse); the value travels as JSON in a hidden input.
        input = el("input", { type: "hidden", name });
        const startRows = Array.isArray(init) ? init : (typeof init === "string" && init ? JSON.parse(init) : (spec.default || []));
        const grid = rowsEditor(spec.columns, startRows, input, options, inputs, spec.add_label, !spec.required);
        input.dataset.type = type;
        input.dataset.label = labelText;
        if (spec.required) input.dataset.required = "1";
        inputs[name] = input;
        form.append(el("div", { class: "rows-field" }, el("span", { class: "label-line" }, label, hint), grid, input,
                       spec.help ? el("span", { class: "help", text: spec.help }) : null));
        continue;
      } else if (type === "condition") {
        // Condition builder (RF-020-14): criteria, exceptions and value help; travels as JSON in a hidden input.
        input = el("input", { type: "hidden", name });
        const start = typeof init === "string" && init ? JSON.parse(init) : init !== undefined ? init : (spec.default ?? []);
        input.value = JSON.stringify(start);
        const holder = el("div", { class: "cond-holder" });
        const fieldDef = (f) => ({ ...f, lookup: f.lookup && options.lookup
          ? (q) => options.lookup(f.lookup.program, { ...(f.lookup.params || {}), q })
              .then((opts) => (Array.isArray(opts) ? opts : []).map((o) => [o.value, o.label])) : undefined });
        const draw = (fields) => {
          const b = window.AnaConditions.builder({ fields: fields.map(fieldDef), value: JSON.parse(input.value || "[]"),
                                                   onChange: (c) => { input.value = JSON.stringify(c); } });
          holder.replaceChildren(b.node);
        };
        if (Array.isArray(spec.fields)) draw(spec.fields);
        else if (spec.fields && spec.fields.program) {
          // Fields that follow other parameters (e.g. the facts of the chosen flow).
          const deps = spec.fields.depends || [];
          const load = () => {
            const params = { ...(spec.fields.params || {}) };
            for (const d of deps) if (inputs[d] && inputs[d].value !== "") params[d] = inputs[d].value;
            if (!options.lookup || deps.some((d) => !(d in params))) { draw([]); return; }
            options.lookup(spec.fields.program, params).then((fs) => draw(Array.isArray(fs) ? fs : [])).catch(() => draw([]));
          };
          deferred.push(() => { load(); for (const d of deps) if (inputs[d]) inputs[d].addEventListener("change", load); });
        } else draw([]);
        input.dataset.type = type;
        input.dataset.label = labelText;
        inputs[name] = input;
        form.append(el("div", { class: "rows-field cond-field" }, el("span", { class: "label-line" }, label, hint), holder, input,
                       spec.help ? el("span", { class: "help", text: spec.help }) : null));
        continue;
      } else if (type === "list" || type === "dict") {
        input = el("textarea", { name, rows: 3, spellcheck: "false" });
        input.value = init !== undefined ? (typeof init === "string" ? init : JSON.stringify(init))
          : spec.default !== undefined && spec.default !== null ? JSON.stringify(spec.default) : (type === "list" ? "[]" : "{}");
      } else {
        const types = { int: "number", float: "number", decimal: "text", date: "date", datetime: "datetime-local", time: "time" };
        input = el("input", { name, type: types[type] || "text", step: type === "float" ? "any" : undefined,
                              inputmode: type === "decimal" ? "decimal" : undefined });
        if (init !== undefined && init !== null) input.value = type === "datetime" ? String(init).slice(0, 16).replace(" ", "T") : init;
        else if (spec.default !== undefined && spec.default !== null) input.value = spec.default;
      }
      const picker = pickerButton(input, type);
      const scanBtn = spec.scan ? scanButton(input, labelText) : null;
      input.dataset.type = type;
      input.dataset.label = labelText;
      if (spec.required) input.dataset.required = "1";
      inputs[name] = input;
      form.append(el("label", { title: spec.help || "", class: type === "datetime" ? "wide" : undefined }, el("span", { class: "label-line" }, label, hint),
                     picker || scanBtn ? el("span", { class: "picker-wrap" }, input, picker, scanBtn) : input,
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
    for (const f of deferred) f();
    // Spec 050 (T-050-07, D6): values from the context — when the field it depends on changes (e.g. the customer), the
    // lookup (run as the user) gives the context's values and the field is filled, unless the person already changed it.
    for (const [name, spec] of entries) {
      const df = spec.default_from;
      const input = inputs[name];
      if (!df || typeof df !== "object" || !df.program || !input || !options.lookup) continue;
      const deps = df.depends || [];
      input.addEventListener("input", (e) => { if (e.isTrusted) input.dataset.touched = "1"; });
      input.addEventListener("change", (e) => { if (e.isTrusted) input.dataset.touched = "1"; });
      const apply = async () => {
        const params = { ...(df.params || {}) };
        for (const d of deps) if (inputs[d] && inputs[d].value !== "") params[d] = inputs[d].value;
        if (deps.some((d) => !(d in params)) || input.dataset.touched === "1") return;
        let ctx;
        try { ctx = await options.lookup(df.program, params); } catch (_) { return; }
        const v = ctx && !Array.isArray(ctx) && typeof ctx === "object" ? ctx[df.field || name] : undefined;
        if (v === undefined || v === null || v === "" || input.dataset.touched === "1") return;
        if (input.tagName === "SELECT" && ![...input.options].some((o) => o.value === String(v))) input.append(el("option", { value: String(v), text: String(v) }));
        input.value = String(v);
        input.dataset.fromContext = "1";
        input.dispatchEvent(new Event("change", { bubbles: true }));
      };
      for (const d of deps) if (inputs[d]) inputs[d].addEventListener("change", apply);
      if (input.value === "" && deps.every((d) => inputs[d] && inputs[d].value !== "")) apply();
    }
    if (options.submitLabel) form.append(el("button", { class: "primary run-button", type: "submit", text: options.submitLabel }));

    // The values as they are, without asking for the required ones (saving a variant, spec 045).
    function peek() {
      try { return read(true); } catch (_) { return {}; }
    }
    function read(lenient) {
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
        if (type === "list" || type === "dict" || type === "condition") r[input.name] = JSON.parse(input.value);
        else if (type === "int") r[input.name] = parseInt(input.value, 10);
        else if (type === "float") r[input.name] = parseFloat(input.value);
        else r[input.name] = input.value;
      }
      if (missing.length && !lenient) throw new Error("preencha " + missing.join(", "));
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
        if (spec.columns && v) { try { v = `${JSON.parse(v).length} linha(s)`; } catch (_) { /* keep */ } }
        if (spec.type === "condition" && v) { try { v = window.AnaConditions.describe(JSON.parse(v)); } catch (_) { /* keep */ } }
        if (v && v !== "[]" && v !== "{}") parts.push(`${spec.label || name}: ${v}`);
      }
      return parts.join(" · ") || "sem parâmetros";
    }
    // Spec 045 (D3): a variant locks fields (seen, not changed) or hides them; the core enforces it as well.
    const box = (input) => input.closest(".rows-field") || input.closest("label") || input;
    function lock(names) {
      for (const n of names || []) {
        const input = inputs[n];
        if (!input) continue;
        const b = box(input);
        b.classList.add("locked-field");
        b.title = "Travado pela variante";
        for (const c of b.querySelectorAll("input, select, textarea, button")) c.disabled = true;
        input.disabled = true;
      }
    }
    function hide(names) {
      for (const n of names || []) if (inputs[n]) box(inputs[n]).hidden = true;
    }
    return { node: form, read: () => read(false), peek, summary, lock, hide, focus: () => { const f = form.querySelector("input:not([disabled]), select:not([disabled]), textarea:not([disabled])"); if (f) f.focus(); } };
  }

  /** Appends one output event to a container. `ctx` (optional) runs actions:
   *  {run(program, params) → Promise<result>, open(program, params), refresh()}. */
  function drawOutput(container, ev, ctx) {
    let node = null;
    if (ev.kind === "text") node = el("pre", { class: "text", text: ev.data });
    else if (ev.kind === "log") node = el("div", { class: "log " + ev.data.level, text: `[${ev.data.level}] ${ev.data.message}` });
    else if (ev.kind === "table") node = drawTable(ev.data, ctx);
    else if (ev.kind === "metrics") node = drawMetrics(ev.data);
    else if (ev.kind === "chart") {
      // Consecutive charts share a responsive grid of cards (RF-029-04).
      const chart = window.AnaCharts.render(ev.data);
      const last = container.lastElementChild;
      if (last && last.classList.contains("viz-grid")) { last.append(chart); return; }
      node = el("div", { class: "viz-grid" }, chart);
    }
    else if (ev.kind === "board") node = drawBoard(ev.data, ctx);
    else if (ev.kind === "gantt") node = drawGantt(ev.data);
    else if (ev.kind === "tabs") node = drawTabs(ev.data, ctx);
    else if (ev.kind === "actions") node = drawActions(ev.data, ctx);
    else if (ev.kind === "steps") node = drawSteps(ev.data);
    else if (ev.kind === "grid") node = window.AnaGrid.render(ev.data, ctx);
    if (!node) return;
    const atEnd = container.scrollTop + container.clientHeight >= container.scrollHeight - 8;
    container.append(node);
    if (atEnd) container.scrollTop = container.scrollHeight;
  }

  const show = (v) => (v === null || v === undefined ? "" : typeof v === "object" ? JSON.stringify(v) : String(v));

  function drawTable(d, ctx) {
    // Spec 035: a row with "open" opens its document (click or Enter).
    const onOpen = d.row_open ? (i, test) => {
      const a = d.row_open[i];
      if (test || !a) return !!a;
      return ctx.open(a.program, a.params || {});
    } : null;
    // The layout each user leaves on this table (columns, order, filters, variants) comes back (RF-020-17).
    const screen = ctx && ctx.screen ? `${ctx.screen}:${d.title || "itens"}` : null;
    if (!d.row_actions) return dataTable(d.columns, d.rows, d.title, null, onOpen, screen);
    const box = dataTable(d.columns, d.rows, d.title, (i) => {
      const slot = el("div", { class: "action-form-row", hidden: true });
      const wrap = el("div", {}, (d.row_actions[i] || []).map((a) => actionButton(a, ctx, slot)), slot);
      return wrap;
    }, onOpen, screen);
    return box;
  }

  // Indicators as KPI chips: label, big value, state border (spec 029, RF-029-03).
  function drawMetrics(d) {
    return el("div", { class: "kpi-block" }, d.title ? el("h3", { class: "block-title", text: d.title }) : null,
      el("div", { class: "stat-grid kpi-strip" }, d.items.map((m) => el("div", { class: "stat kpi" + (m.status ? " stat-" + m.status : ""),
                                                                           title: m.hint || "" },
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

  // RF-020-11: stages of a process; the current one is announced to screen readers (aria-current="step").
  function drawSteps(d) {
    const label = { done: "concluída", current: "etapa atual", todo: "a fazer" };
    return el("section", { class: "steps-box", "aria-label": d.title || "Etapas" },
      d.title ? el("h3", { text: d.title }) : null,
      el("ol", { class: "steps" }, (d.items || []).map((s, i) => el("li", {
        class: "step " + (s.status || "todo"), ...(s.status === "current" ? { "aria-current": "step" } : {}),
      }, el("span", { class: "step-mark", "aria-hidden": "true", text: s.status === "done" ? "✓" : String(i + 1) }),
         el("span", { class: "step-text" }, el("strong", { text: s.label }),
            el("span", { class: "step-hint", text: s.hint || label[s.status] || "" }),
            el("span", { class: "sr-only", text: ` (${label[s.status] || ""})` }))))));
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
      // Spec 050 (D5): the consequence, in a dialog, before an action that cannot be undone.
      if (a.confirm && !(await window.AnaUI.confirmDialog(a.confirm, { title: a.label, ok: a.label }))) return;
      // Spec 035: "download" actions return {_download: {file}}; the tab opens now (inside the click,
      // so the browser allows it) and receives the file's signed address when it arrives.
      const tab = a.download ? window.open("", "_blank") : null;
      const res = await execute(a, a.params || {}, ctx, true);
      const f = res && res.result && res.result._download;
      if (tab) {
        if (f && f.file) {
          try { const r = await window.AnaApi.files.download(f.file, null, true); tab.location.href = r.url; }
          catch (e) { tab.close(); window.AnaUI.toast(window.AnaUI.errorText(e), true); }
        } else tab.close();
      }
    });
    return b;
  }

  async function execute(a, params, ctx, wantResult) {
    try {
      const res = await ctx.run(a.program, params);
      if (res.error) { window.AnaUI.toast(window.AnaErrors.text(res.error), true); return false; }
      if (wantResult && a.download) return res;          // the file opens; the screen stays as it is
      window.AnaUI.toast(`${a.label}: feito.`);
      ctx.refresh();
      return true;
    } catch (e) { window.AnaUI.toast(window.AnaUI.errorText(e), true); return false; }
  }

  function usageText(u) {
    if (!u || u.cpu_ms === undefined) return "";
    return ` · CPU ${u.cpu_ms} ms · memória ${Math.round((u.max_rss_kb || 0) / 1024)} MiB · ${u.sql_count} SQL`;
  }

  // Spec 056 (RF-056-02): the effect of a rehearsal in business terms — records that would be created, changed or
  // deleted, e-mails that would leave, calls and files held. Nothing of it was kept.
  const CHANGE = { created: "seriam criados", changed: "seriam alterados", created_or_changed: "seriam criados ou alterados",
                   deleted: "seriam excluídos" };
  function heldText(h) {
    switch (h.kind) {
      case "http": return `chamaria o conector ${h.connector} (${h.method} ${h.path || "/"})`;
      case "remote": return `chamaria ${h.function} no sistema ${h.system}`;
      case "files": return `${h.action === "put" ? "gravaria o arquivo" : "faria “" + h.action + "” no arquivo"} ${h.name || h.file || ""}`.trim();
      case "schedule": return `${h.active === false ? "pararia" : "agendaria"} a rotina ${h.name}${h.cron ? " (" + h.cron + ")" : ""}`;
      default: return "efeito externo retido";
    }
  }
  function sampleTable(rows) {
    const keys = [...new Set(rows.flatMap((x) => Object.keys(x)))].filter((k) => !/^(created|updated)_(at|by)$/.test(k)).slice(0, 7);
    const fmt = (v) => v === null || v === undefined ? "" : typeof v === "object" ? JSON.stringify(v).slice(0, 60) : String(v);
    const t = el("table", { class: "grid-table compact" });
    t.append(el("thead", {}, el("tr", {}, keys.map((k) => el("th", { text: k.replace(/_/g, " ") })))));
    t.append(el("tbody", {}, rows.map((x) => el("tr", {}, keys.map((k) => el("td", { text: fmt(x[k]) }))))));
    return t;
  }
  function rehearsalCard(effects, error, ctx) {
    const box = el("section", { class: "rehearsal-card", role: "status", "aria-label": "Resultado do ensaio" });
    box.append(el("div", { class: "rehearsal-head" }, el("strong", { text: error ? "Ensaio parou num erro" : "Ensaio" }),
      el("span", { class: "muted small", text: "nada foi gravado nem enviado" })));
    if (error) {
      const why = window.AnaErrors ? window.AnaErrors.describe(error) : { title: error.message };
      box.append(el("div", { class: "end error" }, el("strong", { text: why.title }), why.action ? el("div", { text: why.action }) : null));
    }
    const e = effects || {};
    const tables = e.tables || [], messages = e.messages || [], held = e.held || [];
    if (!tables.length && !messages.length && !held.length) {
      box.append(el("p", { class: "muted", text: error ? "Até o erro, nada teria sido gravado." : "Esta execução não gravaria nada." }));
      return box;
    }
    if (messages.length) {
      box.append(el("h3", { text: "Mensagens que seriam enviadas" }),
        el("ul", { class: "rehearsal-list" }, messages.map((m) => el("li", {},
          el("strong", { text: m.kind === "email" ? "E-mail" : (m.kind || "Mensagem") }),
          ` para ${[].concat(m.to || []).join(", ") || "—"}${m.subject ? ": " + m.subject : ""}`))));
    }
    if (held.length) {
      box.append(el("h3", { text: "Chamadas externas retidas" }),
        el("ul", { class: "rehearsal-list" }, held.map((h) => el("li", { text: heldText(h) }))));
    }
    if (tables.length) {
      box.append(el("h3", { text: "Registros" }));
      const list = el("ul", { class: "rehearsal-list" });
      for (const t of tables) {
        const li = el("li");
        const n = t.change === "deleted" ? t.deleted : t.rows;
        li.append(el("strong", { text: t.label }), ` — ${n} ${CHANGE[t.change] || "seriam gravados"}`);
        if (t.deleted && t.change !== "deleted") li.append(`; ${t.deleted} seriam excluídos`);
        if (t.partial) li.append(el("span", { class: "muted small", text: " (só a contagem: tabela grande ou fora do ensaio)" }));
        // Documents that already exist (changed) open in the viewer; new ones exist only in the rehearsal.
        if ((t.documents || []).length) {
          li.append(el("div", { class: "rehearsal-docs" }, t.documents.map((d) => t.change === "changed" && ctx && ctx.open
            ? el("button", { type: "button", class: "quiet small", text: `${t.label} ${d.key}`, onclick: () => ctx.open("docs.view", { kind: d.kind, key: d.key }) })
            : el("span", { class: "pill", text: `nº ${d.key}` }))));
        }
        if ((t.sample || []).length) li.append(el("details", {}, el("summary", { text: "ver os registros" }), sampleTable(t.sample)));
        list.append(li);
      }
      box.append(list);
    }
    return box;
  }

  window.AnaRunner = { paramsForm, drawOutput, usageText, moduleOf, moduleLabel, areaOf, categoryOf, areaRank, rehearsalCard };
})();
