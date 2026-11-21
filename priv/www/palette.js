// SPDX-FileCopyrightText: 2026 André Luis Pereira dos Santos
// SPDX-License-Identifier: AGPL-3.0-or-later
// Command palette and keyboard help (spec 050, T-050-05, D4). Ctrl+K (⌘K) on any screen: routines, commands,
// categories, programs, tables and admin sections (the same targets as the "Ir para…" bar, already filtered by role,
// groups and license); the actions of the screen on display (its visible buttons, by accessible name — every screen has
// them without declaring anything); documents by number and customers, suppliers and items by CNPJ/CPF, name or code
// (base.find, as the user). "?" outside a text field lists the shortcuts: the global ones and the screen's
// (aria-keyshortcuts).
"use strict";
(function () {
  const { $, $$, el } = window.AnaUI;
  const API = window.AnaApi;
  const PER_GROUP = 8;
  const norm = (s) => String(s || "").normalize("NFD").replace(/[̀-ͯ]/g, "").toLowerCase().trim();

  const GLOBAL_KEYS = [
    ["Control+K", "Ctrl+K", "Paleta de comandos: ir para rotinas, documentos, cadastros e ações desta tela"],
    ["?", "?", "Esta lista de atalhos"],
    ["F3", "F3", "Voltar à tela anterior"],
    ["F8", "F8", "Executar a rotina (ou salvar a definição)"],
    ["F9", "F9", "Simular ou ensaiar a rotina"],
    ["Control+Enter", "Ctrl+Enter", "Executar a partir do formulário"],
    ["Control+Z", "Ctrl+Z", "Desfazer a última ação, enquanto o aviso estiver na tela"],
    ["Escape", "Esc", "Fechar diálogos, menus e esta paleta"],
  ];

  const visible = (n) => !n.closest("[hidden], dialog:not([open]), .palette-dialog, .undo-bar") && !n.disabled;
  // The area of the address on display (#/ops/… → #area-ops); the first visible one if the address names none.
  const currentArea = () => {
    const name = (location.hash.replace(/^#\/?/, "").split(/[/?]/)[0]) || "home";
    const byHash = document.getElementById("area-" + name);
    return byHash && byHash.classList.contains("area-page") ? byHash : [...$$(".area-page")].find((a) => !a.hidden);
  };
  const nameOf = (n) => (n.getAttribute("aria-label") || n.textContent || n.title || "").replace(/\s+/g, " ").trim();

  /** The actions on screen: visible, enabled buttons and links of the open area, by accessible name. */
  function screenActions() {
    const area = currentArea();
    if (!area) return [];
    const seen = new Set();
    const out = [];
    // The screen's own content first (its main buttons), then the area's menus.
    // The screen's own content (all of it), then up to 60 of the area's menus (a long menu never hides the content).
    const main = area.querySelector("[id$='-main']") || area.querySelector("main, .page-main");
    const own = main ? $$("button, a[href]", main) : [];
    const menus = $$("button, a[href]", area).filter((n) => !main || !main.contains(n));
    let fromMenus = 0;
    for (const n of [...own, ...menus]) {
      if (!visible(n)) continue;
      const label = nameOf(n);
      if (!label || label.length < 2 || seen.has(label)) continue;
      const isMenu = !main || !main.contains(n);
      if (isMenu && ++fromMenus > 60) break;
      seen.add(label);
      out.push({ group: "Nesta tela", label, detail: n.getAttribute("aria-keyshortcuts") || "", run: () => n.click() });
    }
    return out;
  }

  function match(items, q) {
    const words = norm(q).split(/\s+/).filter(Boolean);
    if (!words.length) return items.slice(0, PER_GROUP);
    const scored = [];
    for (const it of items) {
      const hay = norm(it.label + " " + (it.detail || ""));
      if (!words.every((w) => hay.includes(w))) continue;
      const label = norm(it.label);
      scored.push([label.startsWith(words[0]) ? 0 : label.includes(words[0]) ? 1 : 2, label.length, it]);
    }
    scored.sort((a, b) => a[0] - b[0] || a[1] - b[1]);
    return scored.slice(0, PER_GROUP).map((s) => s[2]);
  }

  function targets() {
    const t = window.AnaStudio && window.AnaStudio.targets ? window.AnaStudio.targets() : new Map();
    return [...t.entries()].map(([label, hash]) => ({ group: "Ir para", label, hash }));
  }

  // T-045-07b: the variants of the routines (the user's and the company's published), asked once a minute at most.
  let variantsCache = { at: 0, items: [] };
  async function variants() {
    if (Date.now() - variantsCache.at < 60000) return variantsCache.items;
    let rows = [];
    try { rows = await API.runVariants.visible(); } catch (_) { rows = []; }
    const label = (p) => { const r = window.AnaOps && window.AnaOps.routineOf ? window.AnaOps.routineOf(p) : null; return (r && r.description) || p; };
    variantsCache = { at: Date.now(), items: (rows || []).map((v) => ({ group: "Variantes", label: `${label(v.program)} — ${v.name}`,
      detail: v.company ? "da empresa" : "minha", hash: `#/ops/${v.program.split(".")[0]}/${v.program}?_variant=${v.id}` })) };
    return variantsCache.items;
  }

  // ------------------------------------------------------------------ the palette
  let open = null;
  function show(initial = "") {
    if (open) { open.input.focus(); return; }
    const user = window.AnaStudio && window.AnaStudio.user && window.AnaStudio.user();
    if (!user || $("#app-screen").hidden) return;
    const external = user.role === "external";
    const input = el("input", { type: "text", class: "palette-input", role: "combobox", "aria-expanded": "true",
                                "aria-controls": "palette-list", "aria-autocomplete": "list", autocomplete: "off",
                                "aria-label": "Buscar rotina, documento, cadastro ou ação",
                                placeholder: "Rotina, nº do documento, CNPJ, cliente, item ou ação desta tela…" });
    const list = el("ul", { id: "palette-list", class: "palette-list", role: "listbox", "aria-label": "Resultados" });
    const hint = el("p", { class: "palette-hint muted small", text: "↑↓ escolhem · Enter abre · Esc fecha · ? atalhos" });
    const dlg = el("dialog", { class: "md-dialog palette-dialog", "aria-label": "Paleta de comandos" }, input, list, hint);
    const local = { targets: external ? [] : targets(), actions: screenActions(), variants: [] };
    if (!external) variants().then((v) => { local.variants = v; if (open) draw(); });
    const help = { group: "Ajuda", label: "Atalhos do teclado", detail: "?", run: () => shortcuts() };
    let items = [];
    let active = 0;
    let remote = [];
    let seq = 0;
    let timer = null;

    function draw() {
      const q = input.value;
      const groups = [match(local.targets, q), q.trim() ? match(local.variants, q) : [], match(local.actions, q), remote, match([help], q)];
      items = groups.flat();
      if (active >= items.length) active = Math.max(0, items.length - 1);
      const rows = [];
      let last = null;
      items.forEach((it, i) => {
        if (it.group !== last) { rows.push(el("li", { class: "palette-group", role: "presentation", text: it.group })); last = it.group; }
        const li = el("li", { id: "palette-opt-" + i, class: "palette-item" + (i === active ? " active" : ""), role: "option",
                              "aria-selected": i === active ? "true" : "false" },
          el("span", { class: "palette-label", text: it.label }), it.detail ? el("span", { class: "palette-detail muted small", text: it.detail }) : null);
        li.addEventListener("mousedown", (e) => e.preventDefault());
        li.addEventListener("click", () => choose(i));
        rows.push(li);
      });
      if (!items.length) rows.push(el("li", { class: "palette-empty muted", role: "presentation",
                                              text: q.trim() ? `Nada encontrado para "${q.trim()}". Tente o número do documento, o CNPJ ou parte do nome.` : "Digite para buscar." }));
      list.replaceChildren(...rows);
      if (items.length) input.setAttribute("aria-activedescendant", "palette-opt-" + active); else input.removeAttribute("aria-activedescendant");
      const a = list.querySelector(".palette-item.active");
      if (a && a.scrollIntoView) a.scrollIntoView({ block: "nearest" });
    }

    // Documents and records: asked to the server (as the user) after a short pause in typing.
    function ask() {
      clearTimeout(timer);
      const q = input.value.trim();
      const mine = ++seq;
      if (external || !q || (q.length < 3 && !/^\d+$/.test(q))) { remote = []; draw(); return; }
      timer = setTimeout(async () => {
        let found = [];
        try { const r = await API.run("base.find", { params: { q } }); found = Array.isArray(r.result) ? r.result : []; } catch (_) { found = []; }
        if (mine !== seq || !open) return;
        remote = found.map((f) => ({ group: f.group || "Encontrado", label: f.label, detail: f.detail, hash: f.hash }));
        draw();
      }, 200);
    }

    function choose(i) {
      const it = items[i];
      if (!it) return;
      dlg.close();
      if (it.hash) window.AnaStudio.go(it.hash);
      else if (it.run) setTimeout(it.run, 0);       // after the dialog is gone (the action may open another)
    }

    input.addEventListener("input", () => { active = 0; draw(); ask(); });
    input.addEventListener("keydown", (e) => {
      if (e.key === "ArrowDown") { e.preventDefault(); active = Math.min(items.length - 1, active + 1); draw(); }
      else if (e.key === "ArrowUp") { e.preventDefault(); active = Math.max(0, active - 1); draw(); }
      else if (e.key === "Enter") { e.preventDefault(); choose(active); }
    });
    const back = document.activeElement;
    open = { dlg, input };
    window.AnaUI.modal(dlg, () => {
      open = null;
      clearTimeout(timer);
      if (back && back.focus && document.contains(back)) back.focus();
    });
    input.value = initial;
    draw();
    if (initial) ask();
    input.focus();
  }

  // ------------------------------------------------------------------ keyboard help
  function shortcuts() {
    const area = currentArea();
    const local = [];
    const seen = new Set();
    for (const n of area ? $$("[aria-keyshortcuts]", area) : []) {
      if (!visible(n)) continue;
      const keys = n.getAttribute("aria-keyshortcuts");
      const label = nameOf(n);
      if (!label || seen.has(keys + label)) continue;
      seen.add(keys + label);
      local.push([keys, keys.replace(/Control\+/g, "Ctrl+"), label]);
    }
    const table = (rows) => el("table", { class: "grid-table shortcuts-table" },
      el("thead", {}, el("tr", {}, el("th", { text: "Tecla" }), el("th", { text: "O que faz" }))),
      el("tbody", {}, ...rows.map(([, shown, what]) => el("tr", {}, el("td", {}, el("kbd", { text: shown })), el("td", { text: what })))));
    const close = el("button", { type: "button", class: "primary", text: "Fechar" });
    const dlg = el("dialog", { class: "md-dialog shortcuts-dialog", "aria-label": "Atalhos do teclado" },
      el("h2", { text: "Atalhos do teclado" }), table(GLOBAL_KEYS),
      local.length ? el("h3", { text: "Nesta tela" }) : null, local.length ? table(local) : null,
      el("div", { class: "row-buttons" }, close));
    close.addEventListener("click", () => dlg.close());
    window.AnaUI.modal(dlg);
    close.focus();
  }

  document.addEventListener("keydown", (e) => {
    if ((e.ctrlKey || e.metaKey) && !e.altKey && e.key.toLowerCase() === "k") {
      if ($("#app-screen").hidden) return;
      e.preventDefault();
      show();
    } else if (e.key === "?" && !e.ctrlKey && !e.metaKey && !window.AnaUI.typing(e.target) && !open && !$("#app-screen").hidden
               && !document.querySelector("dialog[open]")) {
      e.preventDefault();
      shortcuts();
    }
  });

  window.AnaPalette = { open: show, shortcuts, screenActions };
})();
