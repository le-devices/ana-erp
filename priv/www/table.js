// Work tables (spec 020, RF-020-17): title with count, search, filters per column, choice and order of the
// columns, sorting, named variants per user (one default), spreadsheet export and actions on the selection.
// One component for Operação (program output), Cadastros and Administração. The layout the user leaves comes
// back on the next visit (RF-020-18); variants are named snapshots of it, kept on the server per user.
"use strict";
(function () {
  const UI = window.AnaUI;
  const { el, icon, toast, errorText, cellText } = UI;

  const NUMERIC = /^-?[\d.]+(,\d+)?$|^-?\d+(\.\d+)?$/;
  // Decimals as programs return them ("2829426.98", "21.000"): shown in pt-BR ("2.829.426,98", "21").
  // Money keeps its 2 places; quantities lose trailing zeros. Integers stay as they are (codes, years).
  const DECIMAL = /^-?\d+\.\d{2,6}$/;
  const brDecimal = (s) => {
    const f = s.split(".")[1];
    const places = f.length > 2 ? f.replace(/0+$/, "").length : f.length;
    return Number(s).toLocaleString("pt-BR", { minimumFractionDigits: places, maximumFractionDigits: places });
  };
  const plain = (v) => (v instanceof Node ? v.textContent : cellText(v));
  const norm = (s) => s.normalize("NFD").replace(/[̀-ͯ]/g, "").toLowerCase();
  /** Number of a cell: raw decimals as programs return them ("12.50"), else the Brazilian format ("1.234,5"). */
  const cellNumber = (s) => {
    s = String(s).trim();
    if (DECIMAL.test(s)) return Number(s);
    return NUMERIC.test(s) ? Number(s.replace(/\./g, "").replace(",", ".")) : NaN;
  };
  /** Number typed by a person: Brazilian format ("1.000" is a thousand, "1,5" one and a half; "1.5" too). */
  const toNumber = (s) => {
    s = String(s).trim();
    if (/^-?\d{1,3}(\.\d{3})+(,\d+)?$/.test(s) || s.includes(",")) return NUMERIC.test(s) ? Number(s.replace(/\./g, "").replace(",", ".")) : NaN;
    return /^-?\d+(\.\d+)?$/.test(s) ? Number(s) : NaN;
  };

  /** Filter of one column, typed by the user: "texto" (contém), "=texto" (é), "!texto" (não contém),
   *  ">10", "<=5", "10..20" (entre). Returns (text, number) → bool, or null when empty. */
  function matcher(expr) {
    const e = String(expr || "").trim();
    if (!e) return null;
    let m = e.match(/^(.+?)\.\.(.+)$/);
    if (m && !isNaN(toNumber(m[1])) && !isNaN(toNumber(m[2]))) {
      const a = toNumber(m[1]), b = toNumber(m[2]);
      return (_, n) => n >= Math.min(a, b) && n <= Math.max(a, b);
    }
    m = e.match(/^(>=|<=|>|<)\s*(.+)$/);
    if (m && !isNaN(toNumber(m[2]))) {
      const x = toNumber(m[2]);
      return { ">": (_, n) => n > x, "<": (_, n) => n < x, ">=": (_, n) => n >= x, "<=": (_, n) => n <= x }[m[1]];
    }
    if (e.startsWith("!")) { const x = norm(e.slice(1).trim()); return (t) => !t.includes(x); }
    if (e.startsWith("=")) { const x = norm(e.slice(1).trim()); return (t) => t === x; }
    const x = norm(e);
    return (t) => t.includes(x);
  }

  const variantCache = new Map();     // screen → [variant] (one request per screen and visit)
  async function variantsOf(screen, fresh) {
    if (!fresh && variantCache.has(screen)) return variantCache.get(screen);
    let list = [];
    try { list = await window.AnaApi.variants(screen); } catch (_) { /* no variants: system layout */ }
    variantCache.set(screen, list);
    return list;
  }

  /**
   * def: {
   *   columns: [{key, label, value(row) → text|number|Node, render?(row) → Node|text, num?, hidden?, class?}],
   *   rows, title, screen (key of the remembered layout and variants; none = not remembered),
   *   onOpen?(row) and opens?(row) → bool (row opens a document, spec 035), onRow?(row, tr),
   *   extra?(row) → Node (last cell), bulk?: [{label, run(rows), danger?}], empty?, emptyAction? ({label, onClick|href},
   *   spec 050: the action that fills an empty list), compact? (no toolbar)
   * }
   */
  function create(def) {
    const columns = def.columns.map((c, i) => ({ ...c, key: String(c.key ?? i) }));
    const byKey = new Map(columns.map((c) => [c.key, c]));
    const rows = def.rows;
    const system = () => ({ cols: columns.filter((c) => !c.hidden).map((c) => c.key), sort: null, filters: {}, variant: null });
    const prefKey = def.screen ? "table." + def.screen : null;

    // Text of every cell, computed once: searching, filtering and sorting never touch the DOM.
    const cache = rows.map((r) => {
      const o = {};
      for (const c of columns) {
        const v = c.value(r);
        const t = plain(v);
        o[c.key] = { v, t, n: norm(t), x: cellNumber(t) };
      }
      return o;
    });

    const sane = (s) => {
      const base = system();
      if (!s || typeof s !== "object") return base;
      const known = new Set(Array.isArray(s.known) ? s.known : []);
      let cols = (Array.isArray(s.cols) ? s.cols : []).filter((k) => byKey.has(k));
      // Columns the program gained after the layout was saved come in at the end.
      if (known.size) cols = cols.concat(base.cols.filter((k) => !known.has(k) && !cols.includes(k)));
      const filters = {};
      for (const [k, v] of Object.entries(s.filters || {})) if (byKey.has(k) && typeof v === "string" && v.trim()) filters[k] = v;
      const sort = s.sort && byKey.has(s.sort.key) ? { key: s.sort.key, asc: !!s.sort.asc } : null;
      return { cols: cols.length ? cols : base.cols, sort, filters, variant: typeof s.variant === "string" ? s.variant : null };
    };
    const saved = prefKey ? window.AnaPrefs.get(prefKey) : null;
    let st = sane(saved);
    let search = "";
    let showFilters = Object.keys(st.filters).length > 0;
    const selected = new Set();
    let shown = [];

    const remember = () => {
      if (!prefKey) return;
      window.AnaPrefs.set(prefKey, { cols: st.cols, known: columns.map((c) => c.key), sort: st.sort, filters: st.filters, variant: st.variant });
    };

    // ---------------------------------------------------------------- DOM
    const t = el("table", { class: "data-table work-table" });
    const thead = el("thead");
    const tbody = el("tbody");
    t.append(thead, tbody);
    const count = el("span", { class: "table-count" });
    const searchBox = el("input", { type: "search", class: "table-search", placeholder: "Buscar na tabela", "aria-label": "Buscar na tabela" });
    const bulkBar = el("div", { class: "table-bulk", hidden: true });
    const pop = el("div", { class: "table-pop", hidden: true });
    const variantBtn = el("button", { type: "button", class: "quiet small icon-text table-variant", "aria-haspopup": "true", "aria-expanded": "false" });
    const filterBtn = el("button", { type: "button", class: "quiet small icon-text", "aria-pressed": "false", title: "Filtros por coluna (ex.: >100, 10..20, =SP, !cancelado)" },
      icon("filter", 16), el("span", { text: "Filtros" }));
    const colsBtn = el("button", { type: "button", class: "quiet small icon-text", "aria-haspopup": "true", "aria-expanded": "false", title: "Escolher e ordenar as colunas" },
      icon("table", 16), el("span", { text: "Colunas" }));
    const csvBtn = el("button", { type: "button", class: "quiet small icon-text", title: "Exportar para planilha (CSV): colunas e linhas como estão na tela" },
      icon("download", 16), el("span", { text: "CSV" }));

    const visible = () => st.cols.map((k) => byKey.get(k));
    const hasBulk = !!(def.bulk && def.bulk.length);

    function compute() {
      const tests = Object.entries(st.filters).map(([k, e]) => [k, matcher(e)]).filter(([, f]) => f);
      const q = norm(search.trim());
      const cols = st.cols;
      let idx = [];
      for (let i = 0; i < rows.length; i++) {
        const c = cache[i];
        if (tests.some(([k, f]) => !f(c[k].n, c[k].x))) continue;
        if (q && !cols.some((k) => c[k].n.includes(q))) continue;
        idx.push(i);
      }
      if (st.sort) {
        const k = st.sort.key, dir = st.sort.asc ? 1 : -1;
        const val = (i) => { const c = cache[i][k]; return isNaN(c.x) ? c.n : c.x; };
        idx = idx.sort((a, b) => {
          const x = val(a), y = val(b);
          if (typeof x !== typeof y) return (typeof x === "number" ? -1 : 1) * dir;
          return (x < y ? -1 : x > y ? 1 : a - b) * dir;
        });
      }
      shown = idx;
    }

    function drawHead() {
      const cols = visible();
      const all = el("input", { type: "checkbox", "aria-label": "Selecionar todas as linhas mostradas" });
      all.checked = shown.length > 0 && shown.every((i) => selected.has(i));
      all.addEventListener("change", () => { for (const i of shown) all.checked ? selected.add(i) : selected.delete(i); drawBody(); drawBulk(); });
      const head = el("tr", {}, hasBulk ? el("th", { class: "sel" }, all) : null,
        cols.map((c) => {
          const on = st.sort && st.sort.key === c.key;
          const th = el("th", { class: "sortable" + (on ? (st.sort.asc ? " asc" : " desc") : "") + (c.class ? " " + c.class : ""),
                                text: c.label, title: "Ordenar", tabindex: "0",
                                "aria-sort": on ? (st.sort.asc ? "ascending" : "descending") : "none" });
          const sortBy = () => {
            st.sort = on ? (st.sort.asc ? { key: c.key, asc: false } : null) : { key: c.key, asc: true };
            changed();
          };
          th.addEventListener("click", sortBy);
          th.addEventListener("keydown", (e) => { if (e.key === "Enter" || e.key === " ") { e.preventDefault(); sortBy(); } });
          return th;
        }), def.extra ? el("th", { text: "" }) : null);
      const rowsHead = [head];
      if (showFilters) {
        rowsHead.push(el("tr", { class: "filter-row" }, hasBulk ? el("th") : null,
          cols.map((c) => {
            const f = el("input", { class: "col-filter", value: st.filters[c.key] || "", placeholder: "filtrar",
                                    "aria-label": `Filtrar ${c.label}`, title: "texto (contém), =texto, !texto, >10, <=5, 10..20" });
            f.addEventListener("input", debounce(() => {
              if (f.value.trim()) st.filters[c.key] = f.value; else delete st.filters[c.key];
              st.variant = null;
              compute(); drawBody(); drawCount(); remember(); drawVariantBtn();
            }, 180));
            return el("th", {}, f);
          }), def.extra ? el("th") : null));
      }
      thead.replaceChildren(...rowsHead);
      filterBtn.setAttribute("aria-pressed", showFilters ? "true" : "false");
      filterBtn.classList.toggle("on", showFilters || Object.keys(st.filters).length > 0);
    }

    function cell(c, i) {
      const r = rows[i];
      const { v, t: s } = cache[i][c.key];
      const out = c.render ? c.render(r) : v;
      const node = out instanceof Node ? out : null;
      const txt = node ? null : out === null || out === undefined ? (c.render ? "" : "—") : DECIMAL.test(s) ? brDecimal(s) : plain(out);
      const numeric = c.num ?? (!node && NUMERIC.test(s));
      return el("td", { class: (numeric ? "num" : "") + (c.class ? " " + c.class : "") }, node || txt);
    }

    const LIMIT = 2000;     // rows drawn at once; the rest after "Mostrar todas" (search and export see all)
    let drawAll = false;
    function drawBody() {
      const cols = visible();
      const list = drawAll ? shown : shown.slice(0, LIMIT);
      const trs = list.map((i) => {
        const r = rows[i];
        const opens = def.onOpen && (!def.opens || def.opens(r));
        const tr = el("tr", opens ? { class: "row-open", tabindex: "0", title: "Abrir o documento (Enter)" } : def.onRow ? { class: "clickable" } : {});
        if (hasBulk) {
          const box = el("input", { type: "checkbox", "aria-label": "Selecionar a linha" });
          box.checked = selected.has(i);
          box.addEventListener("change", () => { box.checked ? selected.add(i) : selected.delete(i); drawBulk(); });
          tr.append(el("td", { class: "sel" }, box));
        }
        cols.forEach((c, ci) => { const td = cell(c, i); if (opens && ci === 0) td.classList.add("doc-link"); tr.append(td); });
        if (def.extra) tr.append(el("td", { class: "cell-actions" }, def.extra(r)));
        if (opens) {
          tr.addEventListener("click", (ev) => { if (!ev.target.closest("button,input,select,a,textarea,form")) def.onOpen(r); });
          tr.addEventListener("keydown", (ev) => { if (ev.key === "Enter" && ev.target === tr) { ev.preventDefault(); def.onOpen(r); } });
        } else if (def.onRow) {
          tr.addEventListener("click", (ev) => { if (!ev.target.closest("button,input,select,a,textarea")) def.onRow(r, tr); });
        }
        return tr;
      });
      const span = cols.length + (hasBulk ? 1 : 0) + (def.extra ? 1 : 0);
      if (!rows.length) trs.push(el("tr", {}, window.AnaUI && window.AnaUI.emptyCell
        ? window.AnaUI.emptyCell(span, def.empty, def.emptyAction)
        : el("td", { colspan: span, class: "muted empty-state", text: def.empty || "Nada para mostrar." })));
      else if (!shown.length) trs.push(el("tr", {}, el("td", { colspan: span, class: "muted", text: "Nenhuma linha com essa busca ou filtro." })));
      else if (list.length < shown.length) trs.push(el("tr", {}, el("td", { colspan: span, class: "muted" },
        `${shown.length - list.length} linha(s) a mais. `,
        el("button", { type: "button", class: "quiet small", text: "Mostrar todas", onclick: () => { drawAll = true; drawBody(); } }))));
      tbody.replaceChildren(...trs);
    }

    function drawCount() {
      count.textContent = shown.length === rows.length ? `(${rows.length})` : `(${shown.length} de ${rows.length})`;
    }

    function drawBulk() {
      if (!hasBulk) return;
      const picked = [...selected].map((i) => rows[i]);
      bulkBar.hidden = !picked.length;
      bulkBar.replaceChildren(el("span", { text: `${picked.length} selecionada(s)` }),
        def.bulk.map((a) => el("button", { type: "button", class: "quiet small" + (a.danger ? " danger" : ""), text: a.label, onclick: async () => {
          try { await a.run(picked); } catch (e) { toast(errorText(e), true); }
        } })),
        el("button", { type: "button", class: "quiet small", text: "Limpar seleção", onclick: () => { selected.clear(); drawBody(); drawBulk(); drawHead(); } }));
    }

    function drawVariantBtn() {
      variantBtn.replaceChildren(el("span", { text: "Variante: " }), el("strong", { text: st.variant || "atual" }), icon("down", 14));
      variantBtn.hidden = !def.screen;
    }

    function changed() {
      st.variant = null;
      compute(); drawHead(); drawBody(); drawCount(); drawVariantBtn(); remember();
    }

    function applyState(s, variantName) {
      st = sane(s);
      st.variant = variantName || null;
      showFilters = Object.keys(st.filters).length > 0;
      compute(); drawHead(); drawBody(); drawCount(); drawVariantBtn(); remember();
    }

    // ---------------------------------------------------------------- pop-ups (columns, variants)
    function openPop(btn, build) {
      if (!pop.hidden && pop.dataset.owner === btn.textContent) { closePop(); return; }
      pop.dataset.owner = btn.textContent;
      for (const b of [colsBtn, variantBtn]) b.setAttribute("aria-expanded", b === btn ? "true" : "false");
      pop.replaceChildren(...build());
      pop.hidden = false;
      const first = pop.querySelector("input,button");
      if (first) first.focus();
    }
    function closePop() {
      pop.hidden = true;
      for (const b of [colsBtn, variantBtn]) b.setAttribute("aria-expanded", "false");
    }
    pop.addEventListener("keydown", (e) => { if (e.key === "Escape") { e.stopPropagation(); closePop(); } });

    function columnsPanel() {
      // All columns: visible ones in their order first, then the hidden ones.
      const order = st.cols.concat(columns.map((c) => c.key).filter((k) => !st.cols.includes(k)));
      const list = el("ul", { class: "col-list" }, order.map((k) => {
        const c = byKey.get(k);
        const on = st.cols.includes(k);
        const box = el("input", { type: "checkbox" });
        box.checked = on;
        box.addEventListener("change", () => {
          if (box.checked) st.cols = order.filter((x) => x === k || st.cols.includes(x));
          else if (st.cols.length > 1) st.cols = st.cols.filter((x) => x !== k);
          else { box.checked = true; toast("A tabela precisa de ao menos uma coluna.", true); return; }
          changed(); refresh();
        });
        const move = (d) => {
          const j = st.cols.indexOf(k), to = j + d;
          if (j < 0 || to < 0 || to >= st.cols.length) return;
          [st.cols[j], st.cols[to]] = [st.cols[to], st.cols[j]];
          changed(); refresh();
          const again = pop.querySelectorAll(".col-list li")[to];
          if (again) again.querySelector(d < 0 ? ".up" : ".down")?.focus();
        };
        const pos = st.cols.indexOf(k);
        return el("li", {}, el("label", { class: "check" }, box, c.label),
          el("button", { type: "button", class: "quiet small up", "aria-label": `Subir ${c.label}`, title: "Subir", disabled: !on || pos === 0, onclick: () => move(-1) }, "↑"),
          el("button", { type: "button", class: "quiet small down", "aria-label": `Descer ${c.label}`, title: "Descer", disabled: !on || pos === st.cols.length - 1, onclick: () => move(1) }, "↓"));
      }));
      const refresh = () => { pop.replaceChildren(...columnsPanel()); };
      return [el("strong", { text: "Colunas" }), list,
        el("div", { class: "row-buttons" },
          el("button", { type: "button", class: "quiet small", text: "Restaurar padrão", onclick: () => { applyState(system()); refresh(); } }),
          el("button", { type: "button", class: "quiet small", text: "Fechar", onclick: closePop }))];
    }

    function variantsPanel(list) {
      const name = el("input", { placeholder: "nome da variante (ex.: Só em atraso)", maxlength: "60", "aria-label": "Nome da variante", value: st.variant || "" });
      const asDefault = el("input", { type: "checkbox" });
      const current = list.find((v) => v.name === st.variant);
      return [
        el("strong", { text: "Variantes" }),
        el("ul", { class: "variant-list" },
          el("li", {}, el("button", { type: "button", class: "quiet small" + (!st.variant ? " on" : ""), text: "Padrão do sistema",
            onclick: () => { applyState(system()); closePop(); } })),
          list.map((v) => el("li", {}, el("button", { type: "button", class: "quiet small" + (v.name === st.variant ? " on" : ""),
            title: v.is_default ? "Abre assim quando não há outra escolha" : "", onclick: () => { applyState(v.state, v.name); closePop(); } },
            v.name, v.is_default ? " ★" : "")))),
        el("div", { class: "variant-save" }, name,
          el("label", { class: "check" }, asDefault, "padrão desta tela"),
          el("div", { class: "row-buttons" },
            el("button", { type: "button", class: "primary small", text: "Salvar variante", onclick: async () => {
              const n = name.value.trim();
              if (!n) { name.focus(); return; }
              try {
                await window.AnaApi.saveVariant({ screen: def.screen, name: n, default: asDefault.checked,
                  state: { cols: st.cols, known: columns.map((c) => c.key), sort: st.sort, filters: st.filters } });
                st.variant = n; remember(); drawVariantBtn();
                await variantsOf(def.screen, true);
                toast(`Variante "${n}" salva.`);
                closePop();
              } catch (e) { toast(errorText(e), true); }
            } }),
            current ? el("button", { type: "button", class: "quiet small danger", text: "Excluir esta variante", onclick: async () => {
              if (!confirm(`Excluir a variante ${current.name}?`)) return;
              try { await window.AnaApi.deleteVariant(current.id); await variantsOf(def.screen, true); st.variant = null; remember(); drawVariantBtn(); closePop(); }
              catch (e) { toast(errorText(e), true); }
            } }) : null,
            el("button", { type: "button", class: "quiet small", text: "Fechar", onclick: closePop }))),
      ];
    }

    filterBtn.addEventListener("click", () => { showFilters = !showFilters; drawHead(); if (showFilters) thead.querySelector(".col-filter")?.focus(); });
    colsBtn.addEventListener("click", () => openPop(colsBtn, columnsPanel));
    variantBtn.addEventListener("click", async () => {
      const list = await variantsOf(def.screen);
      openPop(variantBtn, () => variantsPanel(list));
    });
    searchBox.addEventListener("input", debounce(() => { search = searchBox.value; compute(); drawBody(); drawCount(); }, 150));
    csvBtn.addEventListener("click", () => {
      const cols = visible();
      const q = (s) => /[";\n]/.test(s) ? `"${s.replace(/"/g, '""')}"` : s;
      const lines = [cols.map((c) => q(c.label)).join(";"), ...shown.map((i) => cols.map((c) => q(cache[i][c.key].t)).join(";"))];
      const a = el("a", { href: "data:text/csv;charset=utf-8," + encodeURIComponent("﻿" + lines.join("\n")),
                          download: (def.title || "dados").replace(/[^\w\- ]+/g, "").trim().replace(/\s+/g, "_") + ".csv" });
      document.body.append(a); a.click(); a.remove();
    });

    compute(); drawHead(); drawBody(); drawCount(); drawBulk(); drawVariantBtn();
    // First visit with a default variant: the screen opens with it.
    if (def.screen && !saved) {
      variantsOf(def.screen).then((list) => { const d = list.find((v) => v.is_default); if (d && !st.variant) applyState(d.state, d.name); });
    }

    const tools = def.compact ? null : el("div", { class: "table-tools" }, searchBox, filterBtn, colsBtn, variantBtn, csvBtn);
    const box = el("div", { class: "table-box work-box" },
      el("div", { class: "table-head" },
        el("strong", { class: "table-title", text: def.title || "Itens" }), count, tools, pop),
      bulkBar,
      el("div", { class: "resizable" }, t));
    box.addEventListener("focusout", (e) => { if (!pop.hidden && !box.contains(e.relatedTarget) && e.relatedTarget) closePop(); });
    return box;
  }

  function debounce(fn, ms) {
    let timer = null;
    return (...a) => { clearTimeout(timer); timer = setTimeout(() => fn(...a), ms); };
  }

  /** Program output table (columns = names, rows = arrays): `extra(i)` / `onOpen(i)` work with the row index.
   *  `screen` remembers the layout per user (RF-020-17). */
  function dataTable(columns, rows, title, extra, onOpen, screen) {
    // Key of a column = its name (a layout survives a program that reorders columns); repeated or empty
    // names fall back to the position.
    const seen = new Map();
    for (const c of columns) seen.set(c, (seen.get(c) || 0) + 1);
    return create({
      title, screen,
      columns: columns.map((c, ci) => ({ key: c && seen.get(c) === 1 ? String(c) : "#" + ci, label: c, value: (i) => rows[i][ci] })),
      rows: rows.map((_, i) => i),
      extra: extra || undefined,
      onOpen: onOpen ? (i) => onOpen(i) : undefined,
      opens: onOpen ? (i) => !!onOpen(i, true) : undefined,
    });
  }

  window.AnaTable = { create, matcher, toNumber };
  UI.dataTable = dataTable;
})();
