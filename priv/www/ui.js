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

  function dataTable(columns, rows, title) {
    const t = el("table", { class: "data-table" });
    if (title) t.append(el("caption", { text: title }));
    t.append(el("thead", {}, el("tr", {}, columns.map((c) => el("th", { text: c })))));
    const tb = el("tbody");
    for (const r of rows) {
      tb.append(el("tr", {}, r.map((v) => el("td", { text: v === null ? "∅" : (typeof v === "object" ? JSON.stringify(v) : String(v)) }))));
    }
    t.append(tb);
    return t;
  }

  function pill(text, kind = "") { return el("span", { class: "pill " + kind, text }); }

  window.AnaUI = { $, $$, el, fmtDate, errorText, toast, table, dataTable, pill };
})();
