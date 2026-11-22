// SPDX-FileCopyrightText: 2026 André Luis Pereira dos Santos
// SPDX-License-Identifier: AGPL-3.0-or-later
// Assistant (spec 052, D7): a side panel on every screen and an entry in the command palette — "pergunte ou peça".
// A routine that writes comes back REHEARSED, as a card with its effect: only "Confirmar" here runs it (D2).
"use strict";
(function () {
  const { $, el, toast } = window.AnaUI;
  const API = window.AnaApi;
  let enabled = null;
  let conversation = null;

  async function isEnabled() {
    if (enabled !== null) return enabled;
    try { enabled = !!(await API.assistant.config()).enabled; } catch (_) { enabled = false; }
    return enabled;
  }

  function panel() {
    let p = $("#assistant-panel");
    if (p) return p;
    const log = el("div", { class: "assistant-log", role: "log", "aria-live": "polite", "aria-label": "Conversa com o assistente" },
      el("p", { class: "muted small", text: "Pergunte ou peça: \"pedidos com falta\", \"abra o pedido 123\", \"cancele o pedido 123\". O que grava é só ensaiado e espera a sua confirmação aqui." }));
    const input = el("textarea", { class: "assistant-input", rows: 2, "aria-label": "Pergunta ou pedido ao assistente", placeholder: "Pergunte ou peça…" });
    const send = el("button", { type: "submit", class: "primary", text: "Enviar" });
    const form = el("form", { class: "assistant-form" }, input, send);
    form.addEventListener("submit", (e) => { e.preventDefault(); ask(input.value); input.value = ""; });
    input.addEventListener("keydown", (e) => { if (e.key === "Enter" && !e.shiftKey) { e.preventDefault(); form.requestSubmit ? form.requestSubmit() : form.dispatchEvent(new Event("submit", { cancelable: true })); } });
    const close = el("button", { type: "button", class: "quiet small", "aria-label": "Fechar o assistente", text: "×", onclick: () => { p.hidden = true; } });
    const fresh = el("button", { type: "button", class: "quiet small", text: "Nova conversa", onclick: () => { conversation = null; log.replaceChildren(); input.focus(); } });
    p = el("aside", { id: "assistant-panel", class: "assistant-panel", role: "complementary", "aria-label": "Assistente", hidden: true },
      el("div", { class: "assistant-head" }, el("strong", { text: "Assistente" }), fresh, close), log, form);
    p.addEventListener("keydown", (e) => { if (e.key === "Escape") p.hidden = true; });
    document.body.append(p);
    return p;
  }

  const log = () => panel().querySelector(".assistant-log");
  const say = (who, text) => { const n = el("div", { class: "assistant-msg " + who }, el("p", { text })); log().append(n); n.scrollIntoView && n.scrollIntoView({ block: "end" }); return n; };

  function actionCard(a) {
    const r = window.AnaOps && window.AnaOps.routineOf ? window.AnaOps.routineOf(a.program) : null;
    const lines = (a.effect && a.effect.messages) || [];
    const docs = (a.effect && a.effect.documents) || [];
    const status = el("p", { class: "muted small", role: "status", text: "Ensaiado — nada foi gravado. Confirme para executar." });
    const yes = el("button", { type: "button", class: "primary", text: "Confirmar" });
    const no = el("button", { type: "button", class: "quiet", text: "Recusar" });
    const card = el("div", { class: "assistant-action card", "aria-label": `Ação proposta: ${(r && r.description) || a.program}` },
      el("strong", { text: (r && r.description) || a.program }),
      el("p", { class: "muted small", text: Object.entries(a.params || {}).map(([k, v]) => `${k}: ${typeof v === "object" ? JSON.stringify(v) : v}`).join(" · ") || "sem parâmetros" }),
      lines.length ? el("ul", { class: "assistant-effect" }, ...lines.map((l) => el("li", { text: l }))) : el("p", { class: "muted small", text: "O ensaio não mostrou mudanças." }),
      docs.length ? el("p", { class: "small" }, "Documentos: ", ...docs.slice(0, 5).map((d) => el("a", { href: `#/ops/docs/docs.view?kind=${d.kind}&key=${d.key}`, text: `${d.label} ${d.key} ` }))) : null,
      status, el("div", { class: "row-buttons" }, no, yes));
    const done = (text) => { yes.disabled = true; no.disabled = true; status.textContent = text; };
    yes.addEventListener("click", async () => {
      yes.disabled = true;
      try {
        const res = await API.assistant.decide(a.id, "confirm");
        done("Confirmado e executado.");
        toast(`Feito: ${(r && r.description) || a.program}.`);
        if (res.undo) window.AnaUI.offerUndo(res.undo);                       // spec 050: reversible routines
      } catch (e) { yes.disabled = false; status.textContent = window.AnaUI.errorText(e); }
    });
    no.addEventListener("click", async () => {
      try { await API.assistant.decide(a.id, "decline"); done("Recusado — nada foi feito."); } catch (e) { status.textContent = window.AnaUI.errorText(e); }
    });
    return card;
  }

  async function ask(text) {
    const q = String(text || "").trim();
    if (!q) return;
    say("me", q);
    const wait = say("bot", "pensando…");
    wait.classList.add("busy");
    try {
      const r = await API.assistant.ask({ conversation, text: q });
      conversation = r.conversation;
      wait.remove();
      say("bot", r.answer);
      for (const a of r.actions || []) log().append(actionCard(a));
    } catch (e) {
      wait.remove();
      say("bot error", window.AnaUI.errorText(e));
    }
  }

  async function open(text) {
    if (!(await isEnabled())) { toast("O assistente não está ligado nesta instalação (Administração → Assistente).", true); return; }
    const p = panel();
    p.hidden = false;
    if (text && String(text).trim()) ask(text);
    else p.querySelector(".assistant-input").focus();
  }

  // The top bar shows the entry only where the assistant is on.
  document.addEventListener("DOMContentLoaded", () => {
    const btn = $("#assistant-btn");
    if (btn) btn.addEventListener("click", () => open());
  });
  async function refresh() {
    enabled = null;
    const on = await isEnabled();
    const btn = $("#assistant-btn");
    if (btn) btn.hidden = !on;
    return on;
  }

  window.AnaAssistant = { open, ask, isEnabled, refresh, reset: () => { conversation = null; } };
})();
