// SPDX-FileCopyrightText: 2026 André Luis Pereira dos Santos
// SPDX-License-Identifier: AGPL-3.0-or-later
// Master data (spec 040): one list, one record sheet, one search for every master entity, generated
// from the declarations (master.describe). Business rules stay on the server (master.save → the
// entity's writer); the screen only anticipates them (required, numbers, CNPJ/CPF, e-mail).
"use strict";
(function () {
  const API = window.AnaApi;
  const { $, el, fmtDate, toast, pill } = window.AnaUI;
  const UF = ["AC", "AL", "AP", "AM", "BA", "CE", "DF", "ES", "GO", "MA", "MT", "MS", "MG", "PA", "PB", "PR", "PE", "PI", "RJ", "RN",
              "RS", "RO", "RR", "SC", "SP", "SE", "TO"];
  const state = { meta: null, entity: null, list: null, sheet: null };

  // ------------------------------------------------------------------ server calls
  async function call(program, params) {
    const res = await API.run(program, { params });
    if (res.error) { const e = new Error(res.error.message || res.error.code); e.code = res.error.code; e.data = res.error.data; throw e; }
    return res.result;
  }
  async function meta() {
    if (!state.meta) state.meta = await call("master.describe", {});
    return state.meta;
  }
  const entityOf = (name) => state.meta.entities.find((e) => e.name === name);
  const main = () => $("#master-main");
  const go = (hash) => { location.hash = hash; };
  const enc = encodeURIComponent;

  // ------------------------------------------------------------------ values
  const isEmpty = (v) => v === null || v === undefined || String(v).trim() === "";
  const brNum = (v) => {
    const s = String(v).trim().replace(/^R\$\s*/, "").replace("%", "");
    const n = s.includes(",") ? Number(s.replace(/\./g, "").replace(",", ".")) : Number(s);
    return Number.isFinite(n) ? n : NaN;
  };
  const show = (f, v) => {
    if (v === null || v === undefined) return "";
    if (["money", "decimal", "percent"].includes(f.type) && /^-?\d+(\.\d+)?$/.test(String(v))) {
      const n = Number(v);
      return f.type === "money" ? n.toLocaleString("pt-BR", { minimumFractionDigits: 2, maximumFractionDigits: 2 })
                                : n.toLocaleString("pt-BR", { maximumFractionDigits: 6 });
    }
    return String(v);
  };
  function taxIdOk(v) {
    const d = String(v).replace(/\D/g, "");
    if (/^(\d)\1+$/.test(d)) return false;
    if (d.length === 11) {
      for (const n of [9, 10]) {
        let s = 0; for (let i = 0; i < n; i++) s += Number(d[i]) * (n + 1 - i);
        if ((s * 10) % 11 % 10 !== Number(d[n])) return false;
      }
      return true;
    }
    if (d.length === 14) {
      const w = [6, 5, 4, 3, 2, 9, 8, 7, 6, 5, 4, 3, 2];
      for (const n of [12, 13]) {
        let s = 0; for (let i = 0; i < n; i++) s += Number(d[i]) * w[i + (13 - n)];
        const r = s % 11; if ((r < 2 ? 0 : 11 - r) !== Number(d[n])) return false;
      }
      return true;
    }
    return false;
  }
  /** The same first checks the server makes; "" when fine. */
  function check(f, v) {
    if (f.computed || f.hidden) return "";
    if (isEmpty(v)) return f.required ? "obrigatório" : "";
    if (["int", "decimal", "money", "percent"].includes(f.type)) {
      const n = brNum(v);
      if (Number.isNaN(n)) return "número inválido";
      if (f.type === "int" && !Number.isInteger(n)) return "número inteiro";
      if (f.type === "money" && n < 0) return "não pode ser negativo";
      if (f.type === "percent" && (n < 0 || n > 100)) return "deve ficar entre 0 e 100";
    }
    if (f.type === "email" && !/^[^@\s]+@[^@\s]+\.[^@\s]+$/.test(v)) return "e-mail inválido";
    if (f.type === "tax_id" && !taxIdOk(v)) return "CNPJ/CPF inválido: confira os números";
    if (f.type === "url" && !/^https?:\/\/\S+$/.test(v)) return "comece com http:// ou https://";
    if (f.max && String(v).length > f.max) return `no máximo ${f.max} caracteres`;
    return "";
  }

  // ------------------------------------------------------------------ inputs
  const refCache = new Map();
  async function refOptions(ref, by, q, of, field) {
    const key = [ref, by, q || "", of || "", field || ""].join("|");
    if (!refCache.has(key)) refCache.set(key, call("master.lookup", { entity: ref, by, q: q || null, of: of || null, field: field || null }).catch(() => []));
    return refCache.get(key);
  }
  /** One input per field type; returns { node, get(), set(v), input }. */
  function inputFor(f, value, opts = {}) {
    const id = "f-" + Math.random().toString(36).slice(2);
    let input, get, set;
    if (f.hidden) {
      input = el("input", { id, type: "text", value: "•••", disabled: true });
      get = () => undefined; set = () => {};
    } else if (f.type === "bool") {
      input = el("input", { id, type: "checkbox" });
      input.checked = value === true || value === "true";
      get = () => input.checked; set = (v) => { input.checked = v === true || v === "true"; };
    } else if (f.type === "choice" || f.type === "state") {
      const choices = f.type === "state" ? UF.map((u) => [u, u]) : (f.choices || []);
      input = el("select", { id }, el("option", { value: "", text: f.required ? "— escolha —" : "—" }),
        ...choices.map(([v, l]) => el("option", { value: v, text: l })));
      set = (v) => { input.value = v === null || v === undefined ? "" : String(v); };
      set(value);
      get = () => input.value || null;
    } else if (f.type === "ref" || f.type === "lookup") {
      // Searchable choice: the label is shown, the stored value is kept (id or code).
      const list = el("datalist", { id: id + "-l" });
      input = el("input", { id, type: "text", list: id + "-l", autocomplete: "off", placeholder: "digite para buscar" });
      let chosen = value === undefined ? null : value;
      let labels = new Map();
      const by = f.type === "ref" && /_id$/.test(f.name) ? "id" : "key";
      const load = async (q) => {
        const opts2 = f.type === "ref" ? await refOptions(f.ref, by, q, opts.entity, f.name)
          : await API.run(f.lookup.program, { params: f.lookup.params }).then((r) => r.result || []).catch(() => []);
        labels = new Map(opts2.map((o) => [o.label, o.value]));
        list.replaceChildren(...opts2.slice(0, 300).map((o) => el("option", { value: o.label })));
        return opts2;
      };
      set = async (v, title) => {
        chosen = v === undefined ? null : v;
        if (chosen === null) { input.value = ""; return; }
        if (title) { input.value = title; labels.set(title, chosen); return; }
        const all = await load("");
        const hit = all.find((o) => String(o.value) === String(chosen));
        input.value = hit ? hit.label : String(chosen);
        if (hit) labels.set(hit.label, hit.value);
      };
      let t = null;
      input.addEventListener("input", () => {
        if (labels.has(input.value)) { chosen = labels.get(input.value); return; }
        chosen = input.value.trim() === "" ? null : undefined;           // undefined = typed but not chosen
        clearTimeout(t); t = setTimeout(() => load(input.value.trim()), 250);
      });
      input.addEventListener("focus", () => { if (!list.children.length) load(""); }, { once: true });
      get = () => (chosen === undefined ? input.value : chosen);
      set(value, opts.title);
      const wrap = el("span", { class: "md-ref" }, input, list);
      return { node: wrap, input, get, set };
    } else {
      const numeric = ["int", "decimal", "money", "percent"].includes(f.type);
      input = el("input", { id, type: f.type === "date" ? "date" : f.type === "email" ? "email" : "text",
                            inputmode: numeric ? "decimal" : null, maxlength: f.max || null });
      set = (v) => { input.value = v === null || v === undefined ? "" : (f.type === "date" ? String(v).slice(0, 10) : show(f, v)); };
      set(value);
      get = () => (input.value.trim() === "" ? null : f.upper ? input.value.trim().toUpperCase() : input.value.trim());
      if (f.upper) input.addEventListener("blur", () => { input.value = input.value.toUpperCase(); });
    }
    return { node: input, input, get, set };
  }

  function fieldBox(f, value, opts) {
    const ctl = inputFor(f, value, opts);
    const err = el("span", { class: "md-err", role: "alert" });
    const label = el("label", { class: "md-field" + (f.type === "bool" ? " check" : "") + (f.required ? " required" : "") },
      f.type === "bool" ? ctl.node : null,
      el("span", { class: "md-label", text: f.label + (f.sensitive ? " 🔒" : "") }),
      f.type === "bool" ? null : ctl.node, f.help ? el("span", { class: "muted small", text: f.help }) : null, err);
    if (f.sensitive) label.title = "Campo sensível: a alteração pode exigir aprovação de outra pessoa.";
    const ro = opts.readonly || (f.readonly && opts.existing) || f.computed;
    if (ro && ctl.input) ctl.input.disabled = true;
    const showErr = (m) => { err.textContent = m || ""; label.classList.toggle("invalid", !!m); if (ctl.input) ctl.input.setAttribute("aria-invalid", m ? "true" : "false"); };
    if (ctl.input && !ro) ctl.input.addEventListener("blur", () => showErr(check(f, ctl.get())));
    return { f, node: label, ctl, showErr, readonly: ro };
  }

  // ------------------------------------------------------------------ navigation
  function nav(current) {
    const m = state.meta;
    const box = $("#master-nav");
    const items = [];
    for (const g of m.groups) {
      const ents = m.entities.filter((e) => e.group === g);
      if (!ents.length) continue;
      items.push(el("div", { class: "nav-group", text: g }));
      for (const e of ents) items.push(el("button", { class: "nav-link" + (e.name === current ? " active" : ""), text: e.plural,
                                                     onclick: () => go(`#/master/${e.name}`) }));
    }
    items.push(el("div", { class: "nav-group", text: "Ferramentas" }));
    const tool = (k, label) => el("button", { class: "nav-link" + (current === k ? " active" : ""), text: label, onclick: () => go(`#/master/${k}`) });
    items.push(tool("_quality", "Qualidade dos cadastros"), tool("_import", "Importar planilha"));
    if (m.entities.some((e) => e.can_approve)) items.push(tool("_requests", "Aprovações pendentes"));
    if (window.AnaStudio && window.AnaStudio.canSee && window.AnaStudio.canSee("admin")) items.push(tool("_settings", "Configuração"));
    box.replaceChildren(...items);
  }

  async function showArea(rest, query) {
    await meta();
    const [name, key] = rest;
    const entity = name || state.meta.entities[0]?.name;
    nav(entity);
    if (entity === "_quality") return quality(query);
    if (entity === "_import") return importer(query.entity);
    if (entity === "_requests") return requests();
    if (entity === "_settings") return settings();
    const e = entityOf(entity);
    if (!e) { main().replaceChildren(el("p", { class: "muted", text: "Cadastro não encontrado ou sem permissão." })); return; }
    if (key === undefined) return listView(e, query);
    return sheet(e, key === "novo" ? null : key, query);
  }

  // ------------------------------------------------------------------ list (RF-040-02)
  async function listView(e, query) {
    const q = el("input", { type: "search", placeholder: `Buscar ${e.plural.toLowerCase()} (/)`, value: query.q || "", "aria-label": "Buscar" });
    const status = el("select", { "aria-label": "Situação" }, ...[["true", "Ativos"], ["false", "Inativos"], ["all", "Todos"]]
      .map(([v, l]) => el("option", { value: v, text: l })));
    status.value = query.active || "true";
    const count = el("span", { class: "muted" });
    const holder = el("div", { class: "md-list" });
    const more = el("button", { type: "button", class: "quiet", text: "Mostrar mais", hidden: true });
    let offset = 0, loaded = [], columns = [];
    const toolbar = el("div", { class: "md-toolbar" }, q, status,
      e.can_edit ? el("button", { type: "button", class: "primary", text: "Novo (N)", "aria-keyshortcuts": "N", onclick: () => go(`#/master/${e.name}/novo`) }) : null,
      e.can_edit ? el("button", { type: "button", class: "quiet", text: "Importar", onclick: () => go(`#/master/_import?entity=${e.name}`) }) : null,
      el("button", { type: "button", class: "quiet", text: "Exportar tudo (CSV)", title: "Todos os cadastros da busca, não só os carregados",
                     onclick: () => exportCsv(e, q.value, status.value) }), count);
    main().replaceChildren(el("h1", { text: e.plural }), toolbar, holder, more);

    // The work table (RF-020-17) over the loaded page(s): columns, order, filters and variants per user.
    const draw = () => {
      const cellOf = (c) => (row) => {
        const v = row.values[c.name + "__title"] ?? row.values[c.name];
        return c.type === "choice" ? ((c.choices || []).find(([k]) => String(k) === String(v)) || [null, v])[1] : show(c, v);
      };
      const activate = status.value === "false";
      holder.replaceChildren(window.AnaTable.create({
        title: e.plural, screen: "md:" + e.name, rows: loaded,
        columns: [...columns.map((c) => ({ key: c.name, label: c.label, value: cellOf(c), num: ["money", "decimal", "int", "percent"].includes(c.type) })),
                  { key: "_active", label: "Situação", value: (row) => (row.active ? "ativo" : "inativo"),
                    render: (row) => (row.active ? pill("ativo", "ok") : pill("inativo", "off")) }],
        onOpen: (row) => go(`#/master/${e.name}/${enc(row.key)}`),
        empty: q.value ? "Nada encontrado com esse texto." : "Nenhum cadastro ainda.",
        bulk: e.can_edit ? [{ label: activate ? "Reativar" : "Desativar", run: async (rows) => {
          if (!confirm(`${activate ? "Reativar" : "Desativar"} ${rows.length} cadastro(s)?`)) return;
          const r = await call("master.set_active", { entity: e.name, keys: rows.map((x) => String(x.key)), active: activate });
          toast(`${r.changed} alterado(s).`);
          load(true);
        } }] : null,
      }));
    };
    async function load(reset) {
      if (reset) { offset = 0; loaded = []; }
      try {
        const r = await call("master.search", { entity: e.name, q: q.value || null, active: status.value, offset, limit: 50 });
        columns = r.columns;
        loaded = loaded.concat(r.rows);
        offset += r.rows.length;
        count.textContent = `${r.total} cadastro(s)`;
        more.hidden = offset >= r.total;
        draw();
      } catch (err) { toast(err.message, true); }
    }
    let t = null;
    q.addEventListener("input", () => { clearTimeout(t); t = setTimeout(() => { history.replaceState(null, "", `#/master/${e.name}?q=${enc(q.value)}&active=${status.value}`); load(true); }, 250); });
    status.addEventListener("change", () => load(true));
    more.addEventListener("click", () => load(false));
    state.list = { e, focus: () => q.focus() };
    state.sheet = null;
    await load(true);
    q.focus();
  }

  async function exportCsv(e, q, active) {
    try {
      const r = await call("master.export", { entity: e.name, q: q || null, active });
      const a = el("a", { href: URL.createObjectURL(new Blob([r.content], { type: "text/csv;charset=utf-8" })), download: r.filename });
      document.body.append(a); a.click(); a.remove();
      toast(`${r.rows} cadastro(s) exportado(s).`);
    } catch (err) { toast(err.message, true); }
  }

  // ------------------------------------------------------------------ record sheet (RF-040-03)
  async function sheet(e, key, query) {
    let rec = null;
    state.list = null;
    try { if (key !== null) rec = await call("master.get", { entity: e.name, key }); }
    catch (err) { main().replaceChildren(el("p", { class: "error", text: err.message })); return; }
    const existing = !!rec;
    const editable = e.can_edit;
    const boxes = [];
    const tabs = [];
    const banner = el("div", { class: "md-banner", hidden: true });
    const pending = rec && rec.pending && rec.pending.length
      ? el("div", { class: "notice-box" }, `Alteração aguardando aprovação (pedido ${rec.pending.map((p) => p.id).join(", ")}): `,
          ...rec.pending.map((p) => el("span", { text: Object.entries(p.changes.diff || {}).map(([k, [a, b]]) => `${k}: ${a ?? "—"} → ${b ?? "—"}`).join("; ") })))
      : null;

    // General tab: the main fields (product fields first, then the company's own fields).
    const general = el("div", { class: "form-grid md-grid" });
    const own = el("div", { class: "form-grid md-grid" });
    for (const f of e.fields) {
      const v = rec ? rec.values[f.name] : (query[f.name] ?? f.default ?? null);
      const b = fieldBox(f, v, { existing, readonly: !editable, entity: e.name, title: rec && rec.titles ? rec.titles[f.name] : null });
      boxes.push(b);
      (f.custom ? own : general).append(b.node);
    }
    tabs.push({ label: "Geral", node: el("div", {}, general, own.children.length ? el("h3", { class: "md-sub", text: "Campos da empresa" }) : null,
                                          own.children.length ? own : null) });

    const tabState = {};
    for (const t of e.tabs) {
      // A tab may ask for more than the record (spec 068: bank data only by an administrator).
      const tabEditable = editable && t.can_edit !== false;
      const data = rec ? rec.tabs[t.label] : (t.kind === "rows" ? [] : {});
      if (t.kind === "view") {
        if (!existing) continue;
        const node = el("div", {});
        const draw = (rows, title) => {
          if (!rows || !rows.length) return null;
          const cols = Object.keys(rows[0]);
          return el("div", { class: "table-box" }, title ? el("h3", { class: "md-sub", text: title }) : null,
            el("table", { class: "data-table" }, el("thead", {}, el("tr", {}, ...cols.map((c) => el("th", { text: c })))),
              el("tbody", {}, ...rows.map((r) => el("tr", {}, ...cols.map((c) => el("td", { text: show({ type: typeof r[c] === "string" && /^-?\d+\.\d+$/.test(r[c]) ? "decimal" : "text" }, r[c]) })))))));
        };
        node.append(draw(data.rows) || el("p", { class: "muted", text: "Nada a mostrar." }), draw(data.after, "Custo") || "");
        tabs.push({ label: t.label, node });
      } else if (t.kind === "one") {
        const grid = el("div", { class: "form-grid md-grid" });
        const tb = t.fields.map((f) => fieldBox(f, data ? data[f.name] : f.default ?? null, { existing, readonly: !tabEditable, entity: e.name }));
        tb.forEach((b) => grid.append(b.node));
        tabState[t.label] = { kind: "one", boxes: tb, original: null };
        tabs.push({ label: t.label, node: grid });
      } else {
        const st = { kind: "rows", t, rows: [], original: null };
        const body = el("tbody");
        const addRow = (values) => {
          const rb = t.fields.map((f) => fieldBox(f, values ? values[f.name] : f.default ?? null, { existing: false, readonly: !tabEditable, entity: e.name }));
          const tr = el("tr", {}, ...rb.map((b) => el("td", {}, b.node)),
            tabEditable ? el("td", {}, el("button", { type: "button", class: "quiet small", text: "Remover", title: "Remover a linha",
              onclick: () => { st.rows = st.rows.filter((x) => x.tr !== tr); tr.remove(); markDirty(); } })) : null);
          for (const b of rb) if (b.ctl.input) b.ctl.input.addEventListener("input", markDirty);
          st.rows.push({ tr, boxes: rb });
          body.append(tr);
        };
        (data || []).forEach(addRow);
        tabState[t.label] = st;
        tabs.push({ label: t.label, node: el("div", {},
          el("div", { class: "table-box" }, el("table", { class: "data-table md-rows" },
            el("thead", {}, el("tr", {}, ...t.fields.map((f) => el("th", { text: f.label + (f.required ? " *" : "") })), tabEditable ? el("th") : null)), body)),
          tabEditable ? el("button", { type: "button", class: "quiet", text: "Adicionar linha", onclick: () => { addRow(null); markDirty(); } }) : null) });
      }
    }
    if (existing) {
      const hist = el("div", {}, el("p", { class: "muted", text: "Carregando…" }));
      tabs.push({ label: "Histórico", node: hist, lazy: async () => {
        try {
          const r = await call("master.history", { entity: e.name, key: rec.key });
          // Spec 068 (D12, CA-068-10): "Avisar quando mudar" opens a rule already filled with this record (and the
          // field, from a line); rules are the administrator's (spec 051), so only they see it.
          const admin = (window.AnaStudio.user() || {}).role === "admin";
          const watch = (ref) => window.AnaStudio.go(`#/admin/automations/rules/new?entity=${encodeURIComponent(e.name)}` +
            `&key=${encodeURIComponent(r.watch_key)}${ref ? `&field=${encodeURIComponent(ref)}` : ""}` +
            `&back=${encodeURIComponent(location.hash)}`);
          hist.replaceChildren(
            admin ? el("div", { class: "row-buttons" }, el("button", { type: "button", class: "quiet", text: "Avisar quando mudar",
              title: "Cria uma regra que avisa (ou chama um conector) quando este registro mudar", onclick: () => watch(null) })) : null,
            r.changes.length ? el("div", { class: "table-box" }, el("table", { class: "data-table" },
            el("thead", {}, el("tr", {}, ...["Quando", "Campo", "Antes", "Depois", "Por", "Origem"].map((h) => el("th", { text: h })), admin ? el("th") : null)),
            el("tbody", {}, ...r.changes.map((c) => el("tr", {}, el("td", { text: fmtDate(c.at) }), el("td", { text: c.field }),
              el("td", { text: c.before ?? "—" }), el("td", { text: c.after ?? "—" }), el("td", { text: c.by || "" }), el("td", { text: c.origin || "" }),
              admin ? el("td", {}, c.ref ? el("button", { type: "button", class: "quiet small", text: "Avisar quando mudar",
                "aria-label": `Avisar quando ${c.field} mudar`, onclick: () => watch(c.ref) }) : null) : null)))))
            : el("p", { class: "muted", text: "Sem alterações registradas." }));
        } catch (err) { hist.replaceChildren(el("p", { class: "error", text: err.message })); }
      } });
      const use = el("div", {}, el("p", { class: "muted", text: "Carregando…" }));
      tabs.push({ label: "Uso", node: use, lazy: async () => {
        try {
          const r = await call("master.usage", { entity: e.name, key: rec.key });
          use.replaceChildren(r.used.length ? el("ul", { class: "link-list" }, ...r.used.map((u) => el("li", { text: `${u.label}: ${u.rows}` })))
            : el("p", { class: "muted", text: "Ainda não usado em nenhum documento: pode ser apagado." }));
        } catch (err) { use.replaceChildren(el("p", { class: "error", text: err.message })); }
      } });
    }

    // Tabs strip
    const strip = el("div", { class: "sub-tabs", role: "tablist" });
    const panes = el("div", { class: "md-panes" });
    tabs.forEach((t, i) => {
      const b = el("button", { type: "button", role: "tab", class: i === 0 ? "active" : "", text: t.label });
      t.node.hidden = i !== 0;
      b.addEventListener("click", () => {
        for (const x of strip.children) x.classList.remove("active");
        b.classList.add("active");
        tabs.forEach((y) => { y.node.hidden = y !== t; });
        if (t.lazy) { t.lazy(); t.lazy = null; }
      });
      strip.append(b);
      panes.append(t.node);
    });
    // T-040-11b: "#/master/product/X?aba=Fornecimento" opens the sheet on that tab (routines of the menu land here).
    if (query && query.aba) {
      const i = tabs.findIndex((t) => t.label === query.aba);
      if (i > 0) strip.children[i].click();
    }

    const save = el("button", { type: "button", class: "primary", text: existing ? "Salvar (Ctrl+S)" : "Criar (Ctrl+S)", disabled: existing });
    const discard = el("button", { type: "button", class: "quiet", text: "Descartar", disabled: true,
      onclick: () => sheet(e, key, query) });
    function markDirty() { save.disabled = false; discard.disabled = false; }
    for (const b of boxes) if (b.ctl.input) { b.ctl.input.addEventListener("input", markDirty); b.ctl.input.addEventListener("change", markDirty); }
    for (const st of Object.values(tabState)) if (st.kind === "one") for (const b of st.boxes) if (b.ctl.input) {
      b.ctl.input.addEventListener("input", markDirty); b.ctl.input.addEventListener("change", markDirty);
    }

    // What the screen showed at first: "changed?" compares like with like (formatted values on both sides).
    const snapOne = (st) => JSON.stringify(st.boxes.filter((b) => !b.f.hidden).map((b) => b.ctl.get() ?? null));
    const snapRows = (st) => JSON.stringify(st.rows.map((r) => r.boxes.map((b) => b.ctl.get() ?? null)));
    for (const st of Object.values(tabState)) st.original = st.kind === "one" ? snapOne(st) : snapRows(st);

    function collect() {
      let bad = 0;
      const values = {};
      for (const b of boxes) {
        if (b.readonly || b.f.hidden) continue;
        const v = b.ctl.get();
        const msg = v === undefined ? "escolha uma opção da lista" : check(b.f, v);
        b.showErr(msg); if (msg) bad++;
        const before = rec ? rec.values[b.f.name] : undefined;
        if (!rec || String(v ?? "") !== String(before ?? "")) values[b.f.name] = v;
      }
      const tabValues = {};
      for (const [label, st] of Object.entries(tabState)) {
        if (st.kind === "one") {
          const o = {};
          for (const b of st.boxes) { if (b.f.hidden) continue; const v = b.ctl.get(); const m = v === undefined ? "escolha da lista" : check(b.f, v); b.showErr(m); if (m) bad++; o[b.f.name] = v; }
          if (snapOne(st) !== st.original) tabValues[label] = o;
        } else {
          const rows = st.rows.map((r) => {
            const o = {};
            for (const b of r.boxes) { const v = b.ctl.get(); const m = v === undefined ? "escolha da lista" : check(b.f, v); b.showErr(m); if (m) bad++; o[b.f.name] = v; }
            return o;
          });
          if (snapRows(st) !== st.original) tabValues[label] = rows;
        }
      }
      return { bad, values, tabValues };
    }

    async function doSave(extra = {}) {
      const { bad, values, tabValues } = collect();
      if (bad) { banner.hidden = false; banner.className = "md-banner error"; banner.textContent = "Corrija os campos destacados."; return; }
      save.disabled = true;
      try {
        const r = await call("master.save", { entity: e.name, key: rec ? String(rec.key) : null, values, tabs: tabValues,
                                              version: rec ? rec.version : null, ...extra });
        if (r.pending) { toast(r.message); }
        else toast(existing ? "Cadastro salvo." : "Cadastro criado.");
        state.meta = state.meta;   // definitions do not change by saving
        go(`#/master/${e.name}/${enc(r.pending ? rec.key : r.key)}`);
        if (existing) sheet(e, String(r.pending ? rec.key : r.key), {});
      } catch (err) {
        save.disabled = false;
        banner.hidden = false;
        banner.className = "md-banner error";
        if (err.code === "INVALID_FIELDS" && err.data && err.data.fields) {
          banner.textContent = "Corrija os campos destacados.";
          for (const [k, m] of Object.entries(err.data.fields)) {
            const b = boxes.find((x) => x.f.name === k);
            if (b) b.showErr(m); else banner.textContent += ` ${k}: ${m}.`;
          }
        } else if (err.code === "POSSIBLE_DUPLICATE") {
          duplicateDialog(e, err.data.candidates, (reason) => doSave({ confirm_duplicate: true, reason }));
          banner.hidden = true;
        } else if (err.code === "CONFLICT") {
          banner.replaceChildren(el("span", { text: err.message + " " }),
            el("button", { type: "button", class: "quiet small", text: "Recarregar", onclick: () => sheet(e, key, query) }));
        } else banner.textContent = err.message;
      }
    }
    save.addEventListener("click", () => doSave());

    const actions = el("div", { class: "row-buttons md-actions" }, editable ? save : null, editable ? discard : null,
      existing && editable ? el("button", { type: "button", class: "quiet", text: rec.active ? "Desativar" : "Reativar", onclick: async () => {
        if (rec.active && !confirm("Desativar? O cadastro sai das buscas de uso, mas continua nos documentos antigos.")) return;
        try { await call("master.set_active", { entity: e.name, keys: [String(rec.key)], active: !rec.active }); toast(rec.active ? "Desativado." : "Reativado."); sheet(e, key, query); }
        catch (err) { toast(err.message, true); }
      } }) : null,
      existing && editable ? el("button", { type: "button", class: "danger", text: "Apagar", onclick: async () => {
        if (!confirm("Apagar definitivamente? Só é possível se o cadastro nunca foi usado.")) return;
        try { await call("master.delete", { entity: e.name, key: String(rec.key) }); toast("Cadastro apagado."); go(`#/master/${e.name}`); }
        catch (err) {
          const used = err.data && err.data.used ? " Usado em: " + err.data.used.map((u) => `${u.table} (${u.rows})`).join(", ") + "." : "";
          toast(err.message + used, true);
        }
      } }) : null,
      // Spec 043 (D6): outside lookup (CNPJ): fills empty fields, shows differences to confirm, never saves.
      e.fetch && editable ? el("button", { type: "button", class: "quiet", text: e.fetch.label, onclick: async () => {
        const src = boxes.find((b) => b.f.name === e.fetch.field);
        const doc = src && src.ctl.get();
        if (!doc) { src && src.showErr("preencha para buscar"); return; }
        try {
          const r = await call(e.fetch.program, { [e.fetch.param]: doc });
          const diffs = [];
          for (const [k, v] of Object.entries(r.values || {})) {
            const b = boxes.find((x) => x.f.name === k);
            if (!b || b.readonly) continue;
            const cur = b.ctl.get();
            if (cur === null || cur === undefined || cur === "") b.ctl.set(v);
            else if (String(cur) !== String(v)) diffs.push([b, v]);
          }
          banner.hidden = false;
          banner.className = "md-banner";
          banner.replaceChildren(el("span", { text: `Dados de ${r.tax_id}${r.status ? " — situação: " + r.status : ""}. ` +
            (diffs.length ? "Diferente do que está na ficha: " + diffs.map(([b, v]) => `${b.f.label}: ${v}`).join("; ") + ". " : "Campos vazios preenchidos. ") +
            "Nada foi gravado: confira e salve. " }),
            diffs.length ? el("button", { type: "button", class: "quiet small", text: "Usar os dados encontrados", onclick: () => {
              for (const [b, v] of diffs) b.ctl.set(v);
              banner.hidden = true;
            } }) : null);
        } catch (err) { toast(err.message, true); }
      } }) : null,
      existing ? el("button", { type: "button", class: "quiet", text: "Possíveis duplicados", onclick: async () => {
        try { const r = await call("master.duplicates", { entity: e.name, key: String(rec.key) });
              duplicateDialog(e, r.candidates, null, rec); }
        catch (err) { toast(err.message, true); }
      } }) : null);

    main().replaceChildren(
      el("div", { class: "md-head" },
        el("button", { type: "button", class: "quiet small", text: "← " + e.plural, onclick: () => go(`#/master/${e.name}`) }),
        el("h1", { text: rec ? rec.title : `Novo: ${e.label.toLowerCase()}` }),
        rec ? (rec.active ? pill("ativo", "ok") : pill("inativo", "off")) : null),
      ...[pending, banner, strip, panes, actions].filter(Boolean));
    state.sheet = { save: () => { if (!save.disabled) doSave(); } };
    const first = boxes.find((b) => !b.readonly && b.ctl.input);
    if (first && !existing) first.ctl.input.focus();
  }

  function duplicateDialog(e, candidates, onConfirm, current) {
    const reason = el("input", { type: "text", placeholder: "por que não é o mesmo cadastro?" });
    const dlg = el("dialog", { class: "md-dialog" },
      el("h3", { text: candidates.length ? "Possíveis duplicados" : "Nenhum duplicado encontrado" }),
      candidates.length ? el("ul", { class: "link-list" }, ...candidates.map((c) => el("li", {},
        el("a", { href: `#/master/${e.name}/${enc(c.key)}`, text: c.title, onclick: () => dlg.close() }),
        el("span", { class: "muted", text: ` — ${c.reasons.join(", ")}${c.active ? "" : " (inativo)"}` }),
        current && window.AnaStudio && window.AnaStudio.canSee("admin") ? el("button", { type: "button", class: "quiet small", text: "Mesclar neste",
          onclick: async () => {
            const why = prompt(`Mesclar "${current.title}" em "${c.title}"? As referências passam para "${c.title}" e "${current.title}" é desativado. Motivo:`);
            if (!why) return;
            try { const r = await call("master.merge", { entity: e.name, keep: String(c.key), drop: String(current.key), reason: why });
                  toast(`Mesclado: ${Object.values(r.moved).reduce((a, b) => a + b, 0)} referência(s) movida(s).`); dlg.close(); go(`#/master/${e.name}/${enc(c.key)}`); }
            catch (err) { toast(err.message, true); }
          } }) : null))) : null,
      onConfirm ? el("label", {}, "Não é duplicado — motivo: ", reason) : null,
      el("div", { class: "row-buttons" },
        onConfirm ? el("button", { type: "button", class: "primary", text: "Criar mesmo assim", onclick: () => {
          if (reason.value.trim().length < 3) { reason.focus(); return; }
          dlg.close(); onConfirm(reason.value.trim());
        } }) : null,
        el("button", { type: "button", class: "quiet", text: "Fechar", onclick: () => dlg.close() })));
    document.body.append(dlg);
    dlg.addEventListener("close", () => dlg.remove());
    dlg.showModal();
  }

  // ------------------------------------------------------------------ import (RF-040-09)
  function importer(entity) {
    const m = state.meta;
    const sel = el("select", {}, ...m.entities.filter((e) => e.can_edit).map((e) => el("option", { value: e.name, text: e.plural })));
    if (entity) sel.value = entity;
    const file = el("input", { type: "file", accept: ".csv,text/csv" });
    const out = el("div");
    let content = null;
    const run = async (confirmIt) => {
      if (!content) { toast("Escolha o arquivo CSV.", true); return; }
      out.replaceChildren(el("p", { class: "muted", text: confirmIt ? "Gravando…" : "Conferindo linha a linha…" }));
      try {
        const r = await call("master.import", { entity: sel.value, content, confirm: confirmIt });
        const cards = el("div", { class: "stat-grid" }, ...[["Novos", r.new, ""], ["Alterações", r.update, ""], ["Iguais", r.same, ""], ["Com erro", r.error, r.error ? "stat-bad" : "stat-ok"]]
          .map(([l, v, c]) => el("div", { class: "stat " + c }, el("div", { class: "muted small", text: l }), el("strong", { text: String(v) }))));
        const cols = el("p", { class: "muted small", text: "Colunas: " + Object.entries(r.columns).map(([h, c]) => `${h} → ${c ? (c === "__key" ? "código" : c) : "ignorada"}`).join("; ") });
        const errs = r.errors.length ? el("div", { class: "table-box" }, el("table", { class: "data-table" },
          el("thead", {}, el("tr", {}, el("th", { text: "Linha" }), el("th", { text: "Registro" }), el("th", { text: "Problema" }))),
          el("tbody", {}, ...r.errors.slice(0, 300).map((x) => el("tr", {}, el("td", { text: String(x.linha) }), el("td", { text: x.registro || "" }), el("td", { text: x.detalhe })))))) : null;
        out.replaceChildren(el("h3", { text: confirmIt ? "Importação gravada" : "Prévia" }), cards, cols, errs || "",
          !confirmIt && (r.new + r.update) ? el("button", { type: "button", class: "primary", text: `Gravar ${r.new + r.update} linha(s) válida(s)`, onclick: () => run(true) }) : "",
          confirmIt ? el("button", { type: "button", class: "quiet", text: "Abrir a lista", onclick: () => go(`#/master/${sel.value}`) }) : "");
      } catch (err) { out.replaceChildren(el("p", { class: "error", text: err.message })); }
    };
    file.addEventListener("change", () => {
      const f = file.files[0];
      if (!f) return;
      if (f.size > 20 * 1024 * 1024) { toast("Arquivo acima de 20 MB: divida em partes.", true); return; }
      const rd = new FileReader();
      rd.onload = () => { content = String(rd.result); run(false); };
      rd.readAsText(f, "utf-8");
    });
    main().replaceChildren(el("h1", { text: "Importar planilha" }),
      el("p", { class: "lead", text: "CSV com cabeçalho (separador ; ou ,). Use os nomes dos campos — o mais fácil é exportar a lista, editar e importar de volta. Nada é gravado antes da prévia." }),
      el("div", { class: "form-grid md-grid" }, el("label", {}, "Cadastro", sel), el("label", {}, "Arquivo", file)), out);
  }

  // ------------------------------------------------------------------ quality (RF-040-10)
  async function quality(query) {
    main().replaceChildren(el("h1", { text: "Qualidade dos cadastros" }), el("p", { class: "muted", text: "Calculando…" }));
    try {
      const r = await call("master.quality", query.entity && query.indicator ? { entity: query.entity, indicator: query.indicator } : {});
      if (r.rows) {
        main().replaceChildren(el("h1", { text: query.indicator }), el("button", { type: "button", class: "quiet small", text: "← Qualidade", onclick: () => go("#/master/_quality") }),
          el("ul", { class: "link-list" }, ...r.rows.map((x) => el("li", {}, el("a", { href: `#/master/${query.entity}/${enc(x.key)}`, text: x.title })))));
        return;
      }
      main().replaceChildren(el("h1", { text: "Qualidade dos cadastros" }),
        el("p", { class: "lead", text: r.pending ? `${r.pending} pendência(s): abra cada uma para corrigir.` : "Nenhuma pendência. 🎉" }),
        el("div", { class: "cards md-quality" }, ...r.entities.filter((x) => x.items.length).map((x) => el("div", { class: "card" },
          el("h3", { text: x.plural }), el("div", { class: "muted small", text: `${x.active} ativo(s)` }),
          el("ul", { class: "link-list" }, ...x.items.map((i) => el("li", {},
            i.count ? el("a", { href: `#/master/_quality?entity=${x.entity}&indicator=${enc(i.label)}`, text: `${i.label}: ${i.count}` })
                    : el("span", { class: "muted", text: `${i.label}: 0 ✓` }),
            i.count ? el("div", { class: "muted small", text: i.hint }) : null)))))));
    } catch (err) { main().replaceChildren(el("p", { class: "error", text: err.message })); }
  }

  // ------------------------------------------------------------------ approvals (RF-040-08)
  async function requests() {
    try {
      const r = await call("master.requests", {});
      const head = el("tr", {}, ...["Pedido", "Cadastro", "Registro", "Alteração", "Pedido por", "Quando", ""].map((h) => el("th", { text: h })));
      const row = (x) => {
        const buttons = x.mine
          ? [el("button", { type: "button", class: "quiet small", text: "Cancelar", onclick: () => decide(x.id, "cancel") })]
          : [el("button", { type: "button", class: "primary small", text: "Aprovar", onclick: () => decide(x.id, "approve") }),
             el("button", { type: "button", class: "quiet small", text: "Recusar", onclick: () => {
               const m = prompt("Motivo da recusa:");
               if (m) decide(x.id, "reject", m);
             } })];
        const diff = Object.entries(x.diff).map(([k, [a, b]]) => `${k}: ${a ?? "—"} → ${b ?? "—"}`).join("; ");
        return el("tr", {}, el("td", { text: String(x.id) }), el("td", { text: x.label }), el("td", { text: x.title }),
          el("td", { text: diff }), el("td", { text: x.requested_by }), el("td", { text: fmtDate(x.requested_at) }),
          el("td", { class: "cell-actions" }, ...buttons));
      };
      const body = r.rows.length
        ? el("div", { class: "table-box" }, el("table", { class: "data-table" }, el("thead", {}, head), el("tbody", {}, ...r.rows.map(row))))
        : el("p", { class: "muted", text: "Nada aguardando aprovação." });
      main().replaceChildren(el("h1", { text: "Aprovações pendentes" }),
        el("p", { class: "lead", text: "Alterações de campos sensíveis aguardando outra pessoa (quatro olhos)." }), body);
    } catch (err) { main().replaceChildren(el("p", { class: "error", text: err.message })); }
  }
  async function decide(id, decision, reason) {
    try { await call("master.requests", { id, decision, reason: reason || null }); toast("Feito."); requests(); }
    catch (err) { toast(err.message, true); }
  }

  // ------------------------------------------------------------------ settings (admin)
  async function settings() {
    try {
      const r = await call("master.settings", {});
      const m = state.meta;
      const ent = el("select", {}, ...m.entities.filter((e) => ["party", "product"].includes(e.name)).map((e) => el("option", { value: e.name, text: e.plural })));
      const name = el("input", { type: "text", placeholder: "nome técnico (ex.: segmento)" });
      const label = el("input", { type: "text", placeholder: "rótulo na tela (ex.: Segmento)" });
      const type = el("select", {}, ...[["text", "Texto"], ["int", "Número inteiro"], ["decimal", "Número"], ["bool", "Sim/não"], ["date", "Data"], ["choice", "Lista de opções"]].map(([v, l]) => el("option", { value: v, text: l })));
      const choices = el("input", { type: "text", placeholder: "opções separadas por vírgula" });
      const req = el("input", { type: "checkbox" });
      main().replaceChildren(el("h1", { text: "Configuração dos cadastros" }),
        el("h3", { text: "Aprovação de campos sensíveis" }),
        el("div", { class: "table-box" }, el("table", { class: "data-table" },
          el("thead", {}, el("tr", {}, el("th", { text: "Cadastro" }), el("th", { text: "Campos sensíveis" }), el("th", { text: "Aprovação" }), el("th"))),
          el("tbody", {}, ...m.entities.map((e) => {
            const on = !!r.policies[e.name];
            const sens = e.fields.concat(...e.tabs.map((t) => t.fields)).filter((f) => f.sensitive).map((f) => f.label).join(", ") || "—";
            return el("tr", {}, el("td", { text: e.plural }), el("td", { text: sens }), el("td", {}, on ? pill("exigida", "warn") : pill("não")),
              el("td", {}, el("button", { type: "button", class: "quiet small", text: on ? "Desligar" : "Exigir", onclick: async () => {
                try { await call("master.settings", { entity: e.name, approval: !on }); state.meta = null; await meta(); settings(); } catch (err) { toast(err.message, true); }
              } })));
          })))),
        el("h3", { text: "Campos próprios da empresa" }),
        el("p", { class: "muted", text: "Acrescente campos a clientes e itens sem mudar o banco: aparecem na ficha, na lista de importação e na exportação." }),
        el("div", { class: "form-grid md-grid" }, el("label", {}, "Cadastro", ent), el("label", {}, "Nome", name), el("label", {}, "Rótulo", label),
          el("label", {}, "Tipo", type), el("label", {}, "Opções", choices), el("label", { class: "check" }, req, "obrigatório")),
        el("div", { class: "row-buttons" }, el("button", { type: "button", class: "primary", text: "Adicionar campo", onclick: async () => {
          try {
            await call("master.settings", { entity: ent.value, field: { name: name.value, label: label.value, type: type.value, required: req.checked,
                                                                         choices: choices.value.split(",").map((s) => s.trim()).filter(Boolean) } });
            toast("Campo criado."); state.meta = null; await meta(); settings();
          } catch (err) { toast(err.message, true); }
        } })));
    } catch (err) { main().replaceChildren(el("p", { class: "error", text: err.message })); }
  }

  // ------------------------------------------------------------------ keyboard (RNF-040-01)
  document.addEventListener("keydown", (ev) => {
    if ($("#area-master") && $("#area-master").hidden) return;
    const typing = /^(INPUT|SELECT|TEXTAREA)$/.test(document.activeElement && document.activeElement.tagName);
    if ((ev.ctrlKey || ev.metaKey) && ev.key.toLowerCase() === "s" && state.sheet) { ev.preventDefault(); state.sheet.save(); return; }
    if (typing) { if (ev.key === "Escape") document.activeElement.blur(); return; }
    const m = /^#\/master\/([^/?]+)/.exec(location.hash);
    if (ev.key === "/" && state.list) { ev.preventDefault(); state.list.focus(); }
    else if (ev.key.toLowerCase() === "n" && m && !m[1].startsWith("_")) { ev.preventDefault(); go(`#/master/${m[1]}/novo`); }
    else if (ev.key === "Escape" && m && /\/master\/[^/]+\/./.test(location.hash)) go(`#/master/${m[1]}`);
  });

  window.AnaMaster = { show: showArea, reset: () => { state.meta = null; refCache.clear(); } };
})();
