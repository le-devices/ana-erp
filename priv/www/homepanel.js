// SPDX-FileCopyrightText: 2026 André Luis Pereira dos Santos
// SPDX-License-Identifier: AGPL-3.0-or-later
// Home panel (spec 048): the company's spaces with live indicator blocks (each asked on its own, in parallel — a slow
// or failing one never holds the others), personal layout of those blocks (hide, move, size; "Restaurar padrão"),
// the search at the top (the command palette, spec 050) and the notice center of the bell (D4).
"use strict";
(function () {
  const { $, el, toast } = window.AnaUI;
  const API = window.AnaApi;
  const LAYOUT = "home.layout";
  const SIZE_LABEL = { small: "pequeno", medium: "médio", wide: "largo" };
  const STATUS = {
    ok: { label: "em dia", icon: "✓" }, warning: { label: "atenção", icon: "!" }, critical: { label: "crítico", icon: "‼" },
    unavailable: { label: "indisponível", icon: "–" },
  };
  let timers = [];
  let editing = false;

  const layout = () => { const v = window.AnaPrefs.get(LAYOUT); return v && typeof v === "object" ? v : {}; };
  const saveLayout = (v) => window.AnaPrefs.set(LAYOUT, Object.keys(v).length ? v : null);
  const stopTimers = () => { timers.forEach(clearInterval); timers = []; };

  /** "#/ops/m/p?…" for a block: its routine with the block's parameters and company variant (RF-048-06). */
  function blockHash(b) {
    const q = new URLSearchParams();
    for (const [k, v] of Object.entries(b.params || {})) if (v !== null && v !== undefined && v !== "") q.set(k, typeof v === "object" ? JSON.stringify(v) : String(v));
    if (b.variant_id) q.set("_variant", String(b.variant_id));
    const qs = q.toString();
    return `#/ops/${b.program.split(".")[0]}/${b.program}${qs ? "?" + qs : ""}`;
  }

  /** The blocks of a space in the user's order and size, the hidden ones apart. */
  function arranged(space) {
    const lay = layout();
    const blocks = space.blocks.map((b, i) => ({ ...b, _pos: lay[b.id] && lay[b.id].pos !== undefined ? lay[b.id].pos : i,
                                                  _size: (lay[b.id] && lay[b.id].size) || b.size,
                                                  _hidden: !!(lay[b.id] && lay[b.id].hidden) }));
    blocks.sort((a, b) => a._pos - b._pos);
    return blocks;
  }

  function setLayout(id, patch) {
    const lay = layout();
    lay[id] = { ...(lay[id] || {}), ...patch };
    saveLayout(lay);
  }

  function move(space, id, delta) {
    const order = arranged(space);
    const i = order.findIndex((b) => b.id === id);
    const j = i + delta;
    if (i < 0 || j < 0 || j >= order.length) return;
    [order[i], order[j]] = [order[j], order[i]];
    const lay = layout();
    order.forEach((b, k) => { lay[b.id] = { ...(lay[b.id] || {}), pos: k }; });
    saveLayout(lay);
  }

  // ------------------------------------------------------------------ one block
  function blockTile(b, redraw, space) {
    const value = el("span", { class: "block-value", text: b.indicator ? "…" : "" });
    const status = el("span", { class: "block-status", hidden: true });
    const line = el("span", { class: "block-line muted small", text: b.indicator ? "carregando…" : (b.variant_name ? `variante ${b.variant_name}` : "abrir") });
    const when = el("span", { class: "block-when muted small" });
    const open = el("button", { type: "button", class: "block-open", "data-block": String(b.id) },
      el("span", { class: "block-title", text: b.title }), value, status, line);
    open.addEventListener("click", () => { if (!editing) window.AnaStudio.go(blockHash(b)); });
    const label = (txt) => open.setAttribute("aria-label", `${b.title}: ${txt}`);
    label(b.indicator ? "carregando" : "abrir a rotina");
    const tile = el("div", { class: `home-block size-${b._size}${b._hidden ? " is-hidden" : ""}` }, open);

    async function load(fresh) {
      try {
        const a = await API.home.indicator(b.id, fresh);
        const st = STATUS[a.status] || STATUS.ok;
        value.textContent = a.value === null || a.value === undefined ? "–" : (typeof a.value === "number" ? a.value.toLocaleString("pt-BR") : String(a.value));
        status.hidden = false;
        status.className = "block-status status-" + a.status;
        status.replaceChildren(el("span", { "aria-hidden": "true", text: st.icon }), el("span", { text: " " + st.label }));
        line.textContent = a.text || "";
        if (a.reason) line.title = a.reason;
        when.textContent = a.at ? `atualizado às ${new Date(a.at).toLocaleTimeString("pt-BR", { hour: "2-digit", minute: "2-digit" })}` : "";
        label(`${value.textContent}, ${st.label}${a.text ? ", " + a.text : ""}`);
      } catch (e) {
        value.textContent = "–";
        status.hidden = false;
        status.className = "block-status status-unavailable";
        status.replaceChildren(el("span", { "aria-hidden": "true", text: STATUS.unavailable.icon }), el("span", { text: " indisponível" }));
        line.textContent = window.AnaUI.errorText(e);
        label("indisponível");
      }
    }
    if (b.indicator) {
      const refresh = el("button", { type: "button", class: "quiet small block-refresh", "aria-label": `Atualizar ${b.title}`,
                                     title: "Atualizar agora" }, window.AnaUI.icon("refresh", 14));
      refresh.addEventListener("click", () => load(true));
      tile.append(el("div", { class: "block-foot" }, when, refresh));
      load(false);
      // D1: the panel follows the indicator's own rhythm while it is on screen.
      if (b.refresh_s) timers.push(setInterval(() => { if (!$("#area-home").hidden && !document.hidden) load(false); }, b.refresh_s * 1000));
    }
    if (editing) {
      const size = el("select", { "aria-label": `Tamanho de ${b.title}` },
        ...Object.entries(SIZE_LABEL).map(([k, v]) => el("option", { value: k, text: v })));
      size.value = b._size;
      size.addEventListener("change", () => { setLayout(b.id, { size: size.value }); redraw(); });
      tile.append(el("div", { class: "block-edit row-buttons" },
        el("button", { type: "button", class: "small quiet", "aria-label": `Mover ${b.title} para antes`, text: "↑", onclick: () => { move(space, b.id, -1); redraw(); } }),
        el("button", { type: "button", class: "small quiet", "aria-label": `Mover ${b.title} para depois`, text: "↓", onclick: () => { move(space, b.id, 1); redraw(); } }),
        size,
        el("button", { type: "button", class: "small quiet", text: b._hidden ? "Mostrar" : "Esconder",
                       onclick: () => { setLayout(b.id, { hidden: !b._hidden }); redraw(); } })));
    }
    return tile;
  }

  // ------------------------------------------------------------------ the company's spaces
  // ------------------------------------------------------------------ suggestions from usage (spec 051, D3)
  // What the person does again and again, offered to the ERP: accept does it at once; "Não sugerir mais" never returns.
  async function suggestionsBox() {
    let list = [];
    try { list = await API.suggestions.mine(); } catch (_) { return null; }
    if (!list.length) return null;
    const box = el("section", { class: "home-space home-suggestions", "aria-label": "Sugestões do ERP" },
      el("div", { class: "home-space-head" }, el("h2", { text: "Sugestões do ERP" }),
        el("p", { class: "muted small", text: "O ERP percebeu algo que você faz sempre do mesmo jeito e pode fazer por você." })));
    const ul = el("ul", { class: "suggestion-list" });
    const drop = (li) => { li.remove(); if (!ul.children.length) box.remove(); };
    for (const s of list) {
      const li = el("li", { class: "suggestion" }, el("strong", { text: s.title }), el("p", { class: "small", text: s.explanation }));
      li.append(el("div", { class: "row-buttons" },
        el("button", { type: "button", class: "primary small", text: s.kind === "schedule" ? "Agendar" : "Salvar variante", onclick: async () => {
          try {
            const r = await API.suggestions.accept(s.id, {});
            toast(s.kind === "schedule" ? `Agendado: ${s.program} de segunda a sexta (${r.cron}). Você pode mudar em Agendamento.` : "Variante salva: escolha pelo nome na próxima vez.");
            drop(li);
          } catch (e) { toast(window.AnaUI.errorText(e), true); }
        } }),
        el("button", { type: "button", class: "quiet small", text: "Não sugerir mais", onclick: async () => {
          try { await API.suggestions.decline(s.id); toast("Combinado: não vamos sugerir isso de novo."); drop(li); } catch (e) { toast(window.AnaUI.errorText(e), true); }
        } })));
      ul.append(li);
    }
    box.append(ul);
    return box;
  }

  async function spaces(host) {
    stopTimers();
    let list;
    try { list = await API.home.spaces(); } catch (e) { host.replaceChildren(el("p", { class: "muted", text: window.AnaUI.errorText(e) })); return; }
    const sugg = await suggestionsBox();
    const draw = () => {
      stopTimers();
      const sections = list.filter((s) => s.blocks.length).map((s) => {
        const blocks = arranged(s).filter((b) => editing || !b._hidden);
        return el("section", { class: "home-space", "aria-label": s.name },
          el("div", { class: "home-space-head" }, el("h2", { text: s.name }), s.description ? el("p", { class: "muted small", text: s.description }) : null),
          blocks.length ? el("div", { class: "home-blocks" }, ...blocks.map((b) => blockTile(b, draw, s)))
                        : el("p", { class: "muted small", text: "Todos os blocos deste espaço estão escondidos." }));
      });
      const hidden = list.reduce((n, s) => n + arranged(s).filter((b) => b._hidden).length, 0);
      const tools = sections.length ? el("div", { class: "home-tools row-buttons" },
        el("button", { type: "button", class: "quiet small", text: editing ? "Concluir" : "Personalizar", "aria-pressed": editing ? "true" : "false",
                       onclick: () => { editing = !editing; draw(); } }),
        editing || hidden || Object.keys(layout()).length
          ? el("button", { type: "button", class: "quiet small", text: "Restaurar padrão", onclick: () => { saveLayout({}); toast("Painel no padrão da empresa."); draw(); } })
          : null,
        hidden && !editing ? el("span", { class: "muted small", text: `${hidden} bloco(s) escondido(s)` }) : null) : null;
      host.replaceChildren(...(sugg && sugg.isConnected !== false && sugg.querySelector("li") ? [sugg] : []), ...(tools ? [tools] : []), ...sections);
    };
    draw();
  }

  // ------------------------------------------------------------------ search at the top (D5: the palette)
  function search() {
    const input = el("input", { type: "search", class: "home-search-input", placeholder: "Buscar rotina, nº do documento, CNPJ, cliente ou item…",
                                "aria-label": "Buscar rotina, documento ou cadastro", autocomplete: "off" });
    const go = () => window.AnaPalette && window.AnaPalette.open(input.value);
    input.addEventListener("keydown", (e) => { if (e.key === "Enter") { e.preventDefault(); go(); input.value = ""; } });
    input.addEventListener("input", () => { if (input.value.length >= 2) { go(); input.value = ""; } });
    const box = el("div", { class: "home-search" }, window.AnaUI.icon("search", 18), input, el("kbd", { class: "muted small", text: "Ctrl K" }));
    // Spec 052 (D7): where the assistant is on, it is one click away from the top of the panel.
    const wrap = el("div", { class: "home-search-row" }, box);
    if (window.AnaAssistant) window.AnaAssistant.isEnabled().then((on) => {
      if (on) wrap.append(el("button", { type: "button", class: "quiet", text: "Perguntar ao assistente",
                                         onclick: () => window.AnaAssistant.open(input.value) }));
    });
    return wrap;
  }

  // ------------------------------------------------------------------ notice center (D4)
  async function notices() {
    const user = window.AnaStudio.user();
    const isAdmin = user && user.role === "admin";
    const items = [];
    const tasks = window.AnaBpm ? await window.AnaBpm.unread().catch(() => 0) : 0;
    items.push({ label: "Tarefas dos processos", n: tasks, go: "#/bpm" });
    const sched = await API.scheduler.notifications(true).then((l) => l.length).catch(() => 0);
    items.push({ label: "Avisos das rotinas agendadas", n: sched, go: "#/home" });
    // Spec 051 (D3): what the ERP offers to do for the person.
    items.push({ label: "Sugestões do ERP", n: await API.suggestions.mine().then((l) => l.length).catch(() => 0), go: "#/home" });
    if (isAdmin) {
      // Spec 065: versions of company values waiting for a second person.
      const vals = await API.values.list({}).then((r) => (r.values || []).reduce((a, v) => a + (v.pending || 0), 0)).catch(() => 0);
      items.push({ label: "Valores da empresa aguardando aprovação", n: vals, go: "#/admin/values" });
    }
    if (isAdmin) items.push({ label: "Avisos das verificações do sistema", n: await API.admin.notices(true).then((l) => l.length).catch(() => 0), go: "#/admin/checks" });
    const close = el("button", { type: "button", class: "primary", text: "Fechar" });
    const dlg = el("dialog", { class: "md-dialog notices-dialog", "aria-label": "Avisos" }, el("h2", { text: "Avisos" }),
      el("ul", { class: "notice-list" }, ...items.map((i) => el("li", {},
        el("a", { href: i.go, onclick: () => dlg.close() }, el("span", { text: i.label }),
          el("span", { class: "notice-count" + (i.n ? " has" : ""), text: String(i.n), "aria-label": `${i.n} pendente(s)` }))))),
      items.every((i) => !i.n) ? el("p", { class: "muted", text: "Nada esperando por você." }) : null,
      el("div", { class: "row-buttons" }, close));
    close.addEventListener("click", () => dlg.close());
    window.AnaUI.modal(dlg);
    close.focus();
  }

  document.addEventListener("ana:prefs", () => { /* the layout arrives after login; the next draw uses it */ });
  window.AnaHome = { spaces, search, notices, stop: stopTimers, blockHash };
})();
