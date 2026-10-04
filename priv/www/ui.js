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
  function dataTable(columns, rows, title, extra) {
    const t = el("table", { class: "data-table" });
    const tb = el("tbody");
    let order = rows.map((_, i) => i);
    let sortCol = -1, asc = true;
    const draw = () => {
      tb.replaceChildren(...order.map((i) => el("tr", {},
        rows[i].map((v) => { const s = cellText(v); return el("td", { class: NUMERIC.test(s) ? "num" : "", text: v === null ? "—" : s }); }),
        extra ? el("td", { class: "cell-actions" }, extra(i)) : null)));
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
    return el("div", { class: "table-box" },
      el("div", { class: "table-head" }, el("strong", { text: title || "" }),
        el("span", { class: "muted", text: `${rows.length} linha(s)` }),
        el("button", { type: "button", class: "quiet small", text: "⬇ CSV", title: "Exportar para planilha", onclick: csv })),
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

  window.AnaUI = { $, $$, el, fmtDate, errorText, toast, table, dataTable, pill, splitter };
})();
