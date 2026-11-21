// SPDX-FileCopyrightText: 2026 LE Devices
// SPDX-License-Identifier: AGPL-3.0-or-later
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

  // Spec 050 (T-050-04): what happened and what to do; the technical code only for developers.
  function errorText(e) {
    if (window.AnaErrors && e && (e instanceof window.AnaApiError || e.code)) return window.AnaErrors.text(e);
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

  // Generic table: columns = [{label, value: row => text|Node, class}]. With `options.screen` it is the work
  // table (RF-020-17: search, filters, columns, variants per user; `title`, `bulk` as in AnaTable.create).
  function table(columns, rows, options = {}) {
    if (options.screen && window.AnaTable) {
      return window.AnaTable.create({ title: options.title, screen: options.screen, rows, empty: options.empty,
        emptyAction: options.emptyAction, onRow: options.onRow, bulk: options.bulk,
        columns: columns.map((c, i) => ({ key: c.key || c.label || "#" + i, label: c.label, value: c.value, class: c.class })) });
    }
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
    if (!rows.length) tb.append(el("tr", {}, emptyCell(columns.length, options.empty, options.emptyAction)));
    t.append(tb);
    return t;
  }

  /** Spec 050 (D3, P18): an empty list says why and offers the action that fills it
   *  (emptyAction: {label, onClick} or {label, href}). */
  function emptyCell(span, text, action) {
    const btn = !action ? null : action.href
      ? el("a", { href: action.href, class: "button small", text: action.label })
      : el("button", { type: "button", class: "small", text: action.label, onclick: action.onClick });
    return el("td", { colspan: span, class: "muted empty-state" }, el("span", { text: (text || "Nada para mostrar.") + (btn ? " " : "") }), btn);
  }

  const cellText = (v) => (v === null || v === undefined ? "" : typeof v === "object" ? JSON.stringify(v) : String(v));

  // ------------------------------------------------------------------ screen state per user (RF-020-17/18)
  // Dividers, collapsed panels, pinned headers and the last table layout come back on any computer: kept on
  // the server per user, loaded once after login (screens drawn before that re-apply on "ana:prefs").
  // The browser copy only covers the moment before the load and a server that cannot answer.
  const prefs = { data: {}, timers: {} };
  const Prefs = {
    async load() {
      try { prefs.data = await window.AnaApi.uiSettings(); } catch (_) { prefs.data = {}; }
      document.dispatchEvent(new CustomEvent("ana:prefs"));
    },
    get(key) {
      if (key in prefs.data) return prefs.data[key];
      try { const v = localStorage.getItem("ana.pref." + key); return v === null ? undefined : JSON.parse(v); } catch (_) { return undefined; }
    },
    /** value undefined/null forgets it. Writes are debounced per key (dragging sends one request). */
    set(key, value) {
      if (value === undefined || value === null) delete prefs.data[key]; else prefs.data[key] = value;
      try { if (value === undefined || value === null) localStorage.removeItem("ana.pref." + key); else localStorage.setItem("ana.pref." + key, JSON.stringify(value)); } catch (_) { /* storage blocked */ }
      clearTimeout(prefs.timers[key]);
      prefs.timers[key] = setTimeout(() => {
        window.AnaApi.putUiSetting(key, value === undefined ? null : value).catch(() => { /* kept locally */ });
      }, 400);
    },
  };

  /** Draggable divider with a collapse button: sets a CSS variable (px) on `host`; width and collapsed state
   *  remembered per user (RF-020-18). Collapsing hides the panel before the divider (`collapsedClass` on host). */
  function splitter(host, cssVar, { min = 160, max = 900, key, initial, collapsible = true } = {}) {
    const prefKey = key ? "split." + key : null;
    const bar = el("div", { class: "splitter", role: "separator", "aria-orientation": "vertical",
                            title: "Arraste para redimensionar (duplo clique: tamanho padrão)" });
    const toggle = collapsible ? el("button", { type: "button", class: "split-toggle", "aria-label": "Recolher o painel", title: "Recolher o painel" }, "‹") : null;
    if (toggle) bar.append(toggle);
    const state = () => (prefKey && Prefs.get(prefKey)) || {};
    const apply = () => {
      const s = state();
      const w = typeof s === "number" ? s : s.w;            // older value: just the width
      const collapsed = !!s.collapsed;
      if (collapsed) host.style.setProperty(cssVar, "0px");
      else if (w || initial) host.style.setProperty(cssVar, (w || initial) + "px");
      else host.style.removeProperty(cssVar);
      host.classList.toggle("split-collapsed", collapsed);
      if (toggle) {
        toggle.textContent = collapsed ? "›" : "‹";
        toggle.setAttribute("aria-label", collapsed ? "Mostrar o painel" : "Recolher o painel");
        toggle.title = toggle.getAttribute("aria-label");
        toggle.setAttribute("aria-expanded", collapsed ? "false" : "true");
      }
    };
    const save = (patch) => { if (prefKey) { const s = state(); Prefs.set(prefKey, { ...(typeof s === "number" ? { w: s } : s), ...patch }); } };
    apply();
    document.addEventListener("ana:prefs", apply);
    if (toggle) toggle.addEventListener("click", (e) => { e.stopPropagation(); save({ collapsed: !state().collapsed }); apply(); });
    bar.addEventListener("pointerdown", (e) => {
      if (e.target === toggle || host.classList.contains("split-collapsed")) return;
      e.preventDefault();
      const start = e.clientX;
      const base = parseInt(getComputedStyle(host).getPropertyValue(cssVar), 10) || bar.previousElementSibling.getBoundingClientRect().width;
      const move = (ev) => host.style.setProperty(cssVar, Math.max(min, Math.min(max, base + ev.clientX - start)) + "px");
      const up = () => {
        window.removeEventListener("pointermove", move);
        window.removeEventListener("pointerup", up);
        save({ w: parseInt(getComputedStyle(host).getPropertyValue(cssVar), 10) || undefined });
      };
      window.addEventListener("pointermove", move);
      window.addEventListener("pointerup", up);
    });
    bar.addEventListener("dblclick", (e) => {
      if (e.target === toggle || host.classList.contains("split-collapsed")) return;
      host.style.removeProperty(cssVar);
      save({ w: undefined });
    });
    return bar;
  }

  /** Pin button for a screen header: pinned, it stays in sight while the page scrolls (filters and range
   *  always visible); remembered per screen and user (RF-020-18). */
  function pinnable(header, key) {
    const prefKey = "pin." + key;
    const btn = el("button", { type: "button", class: "quiet small pin-toggle" });
    const apply = () => {
      const on = !!Prefs.get(prefKey);
      header.classList.toggle("pinned", on);
      btn.textContent = on ? "Desafixar cabeçalho" : "Fixar cabeçalho";
      btn.setAttribute("aria-pressed", on ? "true" : "false");
      btn.title = on ? "O cabeçalho volta a rolar com a página" : "Mantém filtros e título à vista ao rolar";
    };
    btn.addEventListener("click", () => { Prefs.set(prefKey, Prefs.get(prefKey) ? null : true); apply(); });
    apply();
    return btn;
  }

  function pill(text, kind = "") { return el("span", { class: "pill " + kind, text }); }

  // ------------------------------------------------------------------ dialogs, confirmation and undo (spec 050)
  /** Modal dialog: native when the browser has it; Esc and the close callback always end it. */
  function modal(dlg, onClose) {
    document.body.append(dlg);
    dlg.addEventListener("close", () => { dlg.remove(); if (onClose) onClose(); });
    dlg.addEventListener("keydown", (e) => { if (e.key === "Escape") { e.preventDefault(); dlg.close(); } });
    if (!dlg.close) dlg.close = () => { dlg.removeAttribute("open"); dlg.dispatchEvent(new Event("close")); };
    if (dlg.showModal) dlg.showModal(); else dlg.setAttribute("open", "");
    return dlg;
  }

  /** D5: an irreversible action asks first, saying its consequence. Resolves true only on "Confirmar". */
  function confirmDialog(consequence, { title = "Confirmar?", ok = "Confirmar" } = {}) {
    return new Promise((resolve) => {
      let answer = false;
      const yes = el("button", { type: "button", class: "primary", text: ok });
      const no = el("button", { type: "button", class: "quiet", text: "Voltar" });
      const dlg = el("dialog", { class: "md-dialog confirm-dialog", role: "alertdialog", "aria-label": title },
        el("h2", { text: title }), el("p", { class: "consequence", text: consequence }),
        el("div", { class: "row-buttons" }, no, yes));
      yes.addEventListener("click", () => { answer = true; dlg.close(); });
      no.addEventListener("click", () => dlg.close());
      modal(dlg, () => resolve(answer));
      no.focus();                                  // the safe choice has the focus
    });
  }

  /** D5: "… — Desfazer" for the seconds the routine gave; Ctrl+Z (outside a text field) does the same. */
  let undoState = null;
  function offerUndo(offer) {
    if (!offer || !offer.id) return;
    dropUndo();
    const left = el("span", { class: "undo-left" });
    const btn = el("button", { type: "button", class: "undo-button", text: "Desfazer", "aria-keyshortcuts": "Control+Z" });
    const bar = el("div", { id: "undo-bar", class: "undo-bar", role: "status" },
      el("span", { class: "undo-text", text: offer.label || "Feito" }), btn, left,
      el("button", { type: "button", class: "quiet small undo-close", "aria-label": "Fechar o aviso de desfazer", text: "×", onclick: dropUndo }));
    const until = Date.now() + (offer.seconds || 30) * 1000;
    const tick = () => {
      const s = Math.ceil((until - Date.now()) / 1000);
      if (s <= 0) { dropUndo(); return; }
      left.textContent = `${s} s`;
    };
    undoState = { offer, bar, timer: setInterval(tick, 1000) };
    tick();
    btn.addEventListener("click", () => undo(offer));
    document.body.append(bar);
  }
  function dropUndo() {
    if (!undoState) return;
    clearInterval(undoState.timer);
    undoState.bar.remove();
    undoState = null;
  }
  async function undo(offer) {
    dropUndo();
    try {
      const res = await window.AnaApi.undo(offer.id);
      if (res.error) { toast(errorText(res.error), true); return; }
      toast(`Desfeito: ${offer.label || "a última ação"}.`);
      document.dispatchEvent(new CustomEvent("ana:undone", { detail: { offer, result: res.result } }));
    } catch (e) { toast(errorText(e), true); }
  }
  const typing = (t) => t && (t.isContentEditable || /^(INPUT|TEXTAREA|SELECT)$/.test(t.tagName));
  document.addEventListener("keydown", (e) => {
    if (undoState && !e.defaultPrevented && (e.ctrlKey || e.metaKey) && !e.shiftKey && e.key.toLowerCase() === "z" && !typing(e.target)) {
      e.preventDefault();
      undo(undoState.offer);
    }
  });

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
    scan: "M4.5 8V4.5H8M16 4.5h3.5V8M19.5 16v3.5H16M8 19.5H4.5V16M8.5 8.5v7M11.5 8.5v7M15.5 8.5v7",
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

  // ------------------------------------------------------------------ keyboard and screen readers (RF-020-09)
  // Applied once to everything on screen, also to what is drawn later: tabs (roles, arrow keys, roving
  // focus), tree items (focusable, Enter/Space, expanded state) and fields without a label (name from the
  // placeholder). Screens keep using plain buttons and divs; this keeps them accessible.
  const TABLISTS = ".tabs, .sub-tabs, .shell-tabs";
  function enhance(root) {
    for (const list of $$(TABLISTS, root)) {
      list.setAttribute("role", "tablist");
      const tabs = [...list.children].filter((b) => b.tagName === "BUTTON" && !b.hidden);
      const any = tabs.some((b) => b.classList.contains("active"));
      tabs.forEach((b, i) => {
        const on = b.classList.contains("active") || (!any && i === 0);
        b.setAttribute("role", "tab");
        b.setAttribute("aria-selected", on ? "true" : "false");
        b.tabIndex = on ? 0 : -1;
      });
    }
    for (const n of $$(".node", root)) {
      if (n.tabIndex < 0 || !n.hasAttribute("tabindex")) n.tabIndex = 0;
      n.setAttribute("role", n.classList.contains("folder") ? "treeitem" : "link");
      if (n.classList.contains("folder")) n.setAttribute("aria-expanded", n.classList.contains("closed") ? "false" : "true");
    }
    for (const f of $$("input:not([type=hidden]), select, textarea", root)) {
      if (f.labels && f.labels.length) continue;
      if (f.hasAttribute("aria-label") || f.hasAttribute("aria-labelledby")) continue;
      const name = f.getAttribute("placeholder") || f.getAttribute("title") || f.name;
      if (name) f.setAttribute("aria-label", name);
    }
  }
  document.addEventListener("keydown", (e) => {
    const t = e.target;
    if (t && t.getAttribute && t.getAttribute("role") === "tab" && ["ArrowLeft", "ArrowRight", "Home", "End"].includes(e.key)) {
      const tabs = [...t.parentElement.children].filter((b) => b.getAttribute("role") === "tab" && !b.hidden && !b.disabled);
      const i = tabs.indexOf(t);
      const next = { ArrowLeft: tabs[(i - 1 + tabs.length) % tabs.length], ArrowRight: tabs[(i + 1) % tabs.length],
                     Home: tabs[0], End: tabs[tabs.length - 1] }[e.key];
      if (next) { e.preventDefault(); next.focus(); next.click(); }
    } else if (t && t.classList && t.classList.contains("node") && (e.key === "Enter" || e.key === " ")) {
      e.preventDefault();
      t.click();
    }
  });
  let pending = false;
  new MutationObserver(() => {
    if (pending) return;
    pending = true;
    setTimeout(() => { pending = false; enhance(document); }, 30);
  }).observe(document.documentElement, { childList: true, subtree: true, attributes: true, attributeFilter: ["class", "hidden"] });
  document.addEventListener("DOMContentLoaded", () => enhance(document));

  window.AnaPrefs = Prefs;
  window.AnaUI = { $, $$, el, fmtDate, errorText, toast, table, emptyCell, pill, splitter, pinnable, icon, enhance, cellText,
                   modal, confirmDialog, offerUndo, typing };
})();
