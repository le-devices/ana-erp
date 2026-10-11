// Shared UI helpers. All server content goes through textContent (RNF-005-02).
"use strict";
(function () {
  const $ = (s, root = document) => root.querySelector(s);
  const $$ = (s, root = document) => [...root.querySelectorAll(s)];

  function el(tag, props = {}, ...children) {
    const e = document.createElement(tag);
    for (const [k, v] of Object.entries(props)) {
      if (k === "class") e.className = v;
      else if (k === "text") e.textContent = v;
      else if (k.startsWith("on")) e.addEventListener(k.slice(2), v);
      else if (k === "dataset") Object.assign(e.dataset, v);
      else if (k === "value") e.value = v ?? "";
      // CSSOM, not the style attribute: the strict CSP (style-src 'self') blocks the latter.
      else if (k === "style") e.style.cssText = v;
      else if (k === "checked") e.checked = !!v;
      else if (v !== undefined && v !== null && v !== false) e.setAttribute(k, v === true ? "" : v);
    }
    for (const c of children.flat()) if (c !== null && c !== undefined && c !== false) e.append(c);
    return e;
  }

  function fmtDate(s) {
    if (!s) return "";
    const d = new Date(s);
    return isNaN(d) ? String(s) : d.toLocaleString("pt-BR");
  }

  function errorText(e) {
    if (e instanceof window.AnaApiError) return `${e.code || e.status}: ${e.message}`;
    return String((e && e.message) || e);
  }

  let toastTimer = null;
  function toast(message, isError = false) {
    const t = $("#toast");
    t.textContent = message;
    t.className = "toast" + (isError ? " error" : "");
    t.hidden = false;
    clearTimeout(toastTimer);
    toastTimer = setTimeout(() => { t.hidden = true; }, isError ? 7000 : 3500);
  }

  // Generic table: columns = [{label, value: row => text|Node, class}]
  function table(columns, rows, options = {}) {
    const t = el("table", { class: "grid-table" });
    t.append(el("thead", {}, el("tr", {}, columns.map((c) => el("th", { class: c.class || "", text: c.label })))));
    const tb = el("tbody");
    for (const r of rows) {
      const tr = el("tr", { class: options.onRow ? "clickable" : "" });
      if (options.onRow) tr.addEventListener("click", (ev) => { if (!ev.target.closest("button,input,select,a")) options.onRow(r, tr); });
      for (const c of columns) {
        const v = c.value(r);
        tr.append(el("td", { class: c.class || "" }, v instanceof Node ? v : (v === null || v === undefined ? "" : String(v))));
      }
      tb.append(tr);
    }
    if (!rows.length) tb.append(el("tr", {}, el("td", { colspan: columns.length, class: "muted", text: options.empty || "Nada para mostrar." })));
    t.append(tb);
    return t;
  }

  const cellText = (v) => (v === null || v === undefined ? "" : typeof v === "object" ? JSON.stringify(v) : String(v));
  const NUMERIC = /^-?[\d.]+(,\d+)?$|^-?\d+(\.\d+)?$/;

  /** Program output table: sortable columns, numbers to the right, CSV export,
   *  resizable box. `extra(i)` may return a node for an extra last cell. */
  /** onOpen(i) → true when row i opens a document (spec 035): the row is clickable and focusable. */
  function dataTable(columns, rows, title, extra, onOpen) {
    const t = el("table", { class: "data-table" });
    const tb = el("tbody");
    let order = rows.map((_, i) => i);
    let sortCol = -1, asc = true;
    const draw = () => {
      tb.replaceChildren(...order.map((i) => {
        const opens = onOpen && onOpen(i, true);
        const tr = el("tr", opens ? { class: "row-open", tabindex: "0", title: "Abrir o documento (Enter)" } : {},
          rows[i].map((v, ci) => {
            const s = cellText(v);
            return el("td", { class: (NUMERIC.test(s) ? "num" : "") + (opens && ci === 0 ? " doc-link" : ""), text: v === null ? "—" : s });
          }),
          extra ? el("td", { class: "cell-actions" }, extra(i)) : null);
        if (opens) {
          tr.addEventListener("click", (ev) => { if (!ev.target.closest("button,input,select,a,textarea,form")) onOpen(i); });
          tr.addEventListener("keydown", (ev) => { if (ev.key === "Enter" && ev.target === tr) { ev.preventDefault(); onOpen(i); } });
        }
        return tr;
      }));
      if (!rows.length) tb.append(el("tr", {}, el("td", { colspan: columns.length + (extra ? 1 : 0), class: "muted", text: "Nada para mostrar." })));
    };
    const key = (v) => { const s = cellText(v); const n = Number(s.replace(/\./g, "").replace(",", ".")); return NUMERIC.test(s) && !isNaN(n) ? n : s.toLowerCase(); };
    const head = el("tr", {}, columns.map((c, ci) => el("th", { class: "sortable", text: c, title: "Ordenar", onclick: () => {
      asc = sortCol === ci ? !asc : true;
      sortCol = ci;
      order = rows.map((_, i) => i).sort((a, b) => { const x = key(rows[a][ci]), y = key(rows[b][ci]); return (x < y ? -1 : x > y ? 1 : 0) * (asc ? 1 : -1); });
      for (const th of head.children) th.classList.remove("asc", "desc");
      head.children[ci].classList.add(asc ? "asc" : "desc");
      draw();
    } })), extra ? el("th", { text: "" }) : null);
    t.append(el("thead", {}, head), tb);
    draw();
    const csv = () => {
      const q = (s) => /[";\n]/.test(s) ? `"${s.replace(/"/g, '""')}"` : s;
      const text = [columns, ...order.map((i) => rows[i])].map((r) => r.map((v) => q(cellText(v))).join(";")).join("\n");
      const a = el("a", { href: "data:text/csv;charset=utf-8," + encodeURIComponent("\ufeff" + text),
                          download: (title || "dados").replace(/[^\w\- ]+/g, "").trim().replace(/\s+/g, "_") + ".csv" });
      document.body.append(a); a.click(); a.remove();
    };
    const exportBtn = el("button", { type: "button", class: "quiet small icon-text", title: "Exportar para planilha (CSV)", onclick: csv },
      icon("download", 16), el("span", { text: "CSV" }));
    return el("div", { class: "table-box" },
      el("div", { class: "table-head" },
        el("strong", { class: "table-title", text: title || "Itens" }),
        el("span", { class: "table-count", text: `(${rows.length})` }),
        el("span", { class: "muted", text: `${rows.length} linha(s)` }),
        el("div", { class: "table-tools" }, exportBtn)),
      el("div", { class: "resizable" }, t));
  }

  /** Draggable divider: sets a CSS variable (px) on `host`; remembered per viewer. */
  function splitter(host, cssVar, { min = 160, max = 900, key, initial } = {}) {
    let saved = null;
    try { saved = key ? parseInt(localStorage.getItem("ana.split." + key), 10) : null; } catch (_) { /* storage blocked */ }
    if (saved || initial) host.style.setProperty(cssVar, (saved || initial) + "px");
    const bar = el("div", { class: "splitter", role: "separator", title: "Arraste para redimensionar (duplo clique: tamanho padrão)" });
    bar.addEventListener("pointerdown", (e) => {
      e.preventDefault();
      const start = e.clientX;
      const base = parseInt(getComputedStyle(host).getPropertyValue(cssVar), 10) || bar.previousElementSibling.getBoundingClientRect().width;
      const move = (ev) => host.style.setProperty(cssVar, Math.max(min, Math.min(max, base + ev.clientX - start)) + "px");
      const up = () => {
        window.removeEventListener("pointermove", move);
        window.removeEventListener("pointerup", up);
        try { if (key) localStorage.setItem("ana.split." + key, parseInt(getComputedStyle(host).getPropertyValue(cssVar), 10)); } catch (_) { /* ignore */ }
      };
      window.addEventListener("pointermove", move);
      window.addEventListener("pointerup", up);
    });
    bar.addEventListener("dblclick", () => {
      host.style.removeProperty(cssVar);
      try { if (key) localStorage.removeItem("ana.split." + key); } catch (_) { /* ignore */ }
    });
    return bar;
  }

  function pill(text, kind = "") { return el("span", { class: "pill " + kind, text }); }

  // Own line icons (spec 029): 24×24 grid, 1.8 stroke, no icon font, no third-party set.
  const ICONS = {
    back: "M15 5l-7 7 7 7",
    home: "M3.5 11.5L12 4.5l8.5 7M6 10v9.5h4.5v-5h3v5H18V10",
    search: "M10.5 4.5a6 6 0 1 1 0 12 6 6 0 0 1 0-12zM15 15l5 5",
    bell: "M6.5 16.5V11a5.5 5.5 0 0 1 11 0v5.5l1.5 2H5zM10 20.5a2 2 0 0 0 4 0",
    down: "M6.5 9.5l5.5 5.5 5.5-5.5",
    right: "M9.5 6l6 6-6 6",
    download: "M12 4.5v10M7.5 10.5L12 15l4.5-4.5M5 19.5h14",
    table: "M4.5 5.5h15v13h-15zM4.5 10h15M4.5 14.5h15M10 5.5v13",
    chart: "M5.5 19V12M10 19V6M14.5 19v-5M19 19V9",
    refresh: "M19 12a7 7 0 1 1-2.05-4.95M19 5v4h-4",
    filter: "M4.5 5.5h15l-5.75 7v5l-3.5 2v-7z",
    edit: "M5 19l.8-3.6L15.6 5.6a1.5 1.5 0 0 1 2.1 0l.7.7a1.5 1.5 0 0 1 0 2.1L8.6 18.2z",
    play: "M8 5.5v13l10.5-6.5z",
    menu: "M4.5 7h15M4.5 12h15M4.5 17h15",
    expand: "M14 4.5h5.5V10M10 19.5H4.5V14M19.5 4.5L13.5 10.5M4.5 19.5l6-6",
    close: "M6 6l12 12M18 6L6 18",
    folder: "M3.5 7.5a2 2 0 0 1 2-2h4l2 2h7a2 2 0 0 1 2 2v7.5a2 2 0 0 1-2 2h-13a2 2 0 0 1-2-2z",
    file: "M7 3.5h6.5l4 4V20a.5.5 0 0 1-.5.5H7a.5.5 0 0 1-.5-.5V4a.5.5 0 0 1 .5-.5zM13.5 3.5V8h4",
    calendar: "M5 6.5h14v13H5zM5 10.5h14M9 4v4M15 4v4",
    clock: "M12 4.5a7.5 7.5 0 1 1 0 15 7.5 7.5 0 0 1 0-15zM12 8v4.5l3 2",
    plus: "M12 5v14M5 12h14",
  };
  const SVG_NS = "http://www.w3.org/2000/svg";
  function icon(name, size = 18) {
    const svg = document.createElementNS(SVG_NS, "svg");
    for (const [k, v] of Object.entries({ viewBox: "0 0 24 24", width: size, height: size, fill: "none", stroke: "currentColor",
      "stroke-width": "1.8", "stroke-linecap": "round", "stroke-linejoin": "round", "aria-hidden": "true", class: "icon" })) {
      svg.setAttribute(k, String(v));
    }
    const path = document.createElementNS(SVG_NS, "path");
    path.setAttribute("d", ICONS[name] || ICONS.right);
    if (name === "play") { path.setAttribute("fill", "currentColor"); path.setAttribute("stroke", "none"); }
    svg.append(path);
    return svg;
  }

  window.AnaUI = { $, $$, el, fmtDate, errorText, toast, table, dataTable, pill, splitter, icon };
})();
