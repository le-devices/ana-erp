// SPDX-FileCopyrightText: 2026 André Luis Pereira dos Santos
// SPDX-License-Identifier: AGPL-3.0-or-later
// Spec 050 (CA-050-01, CA-050-04): the verifier catches a screen that breaks the pattern, and error
// messages hide technical codes from operation users. Run before smoke.mjs (make teste-estudio).
import { JSDOM } from "jsdom";
import { audit } from "./ux_check.mjs";
import { ANA_URL, ensureAna } from "./target.mjs";

await ensureAna();
const ok = (c, m) => { if (!c) throw new Error("failed: " + m); console.log("✔", m); };
const page = (body) => new JSDOM(`<!doctype html><body><div id="app-screen"><div class="area" id="area-ops">${body}</div></div></body>`).window.document;

const clean = page(`<h1>Pedidos</h1><label>Cliente <input name="c"></label><button>Salvar</button>
  <table><tr><td class="muted empty-state">Nenhum pedido. <button>Criar pedido</button></td></tr></table>`);
ok(audit(clean).length === 0, "tela dentro do padrão não tem apontamentos");

const good = page(`<h1>Saúde</h1><table><tr><td class="muted empty-state empty-good">Nenhum incidente.</td></tr></table>`);
ok(audit(good).length === 0, "lista vazia que é boa notícia (empty-good) não exige ação (D3)");

const bad = audit(page(`<input name="cliente"><button></button><img src="x.png">
  <table><tr><td class="muted empty-state">Nada para mostrar.</td></tr></table><p>Erro: undefined</p>`));
const rules = new Set(bad.map((v) => v.rule));
for (const r of ["field-name", "control-name", "image-alt", "empty-without-action", "technical-text"]) {
  ok(rules.has(r), `tela nova fora do padrão é apontada: ${r} (CA-050-01)`);
}
const dev = new JSDOM(`<!doctype html><body><div id="app-screen"><div class="area" id="area-dev"><p>SQLSTATE 42P01</p></div></div></body>`).window.document;
ok(!audit(dev).some((v) => v.rule === "technical-text"), "texto técnico é permitido no Desenvolvimento");

// Error catalog: the operation user reads what happened and what to do; developers also see the code.
const src = await (await fetch(ANA_URL + "/studio/errors.js")).text();
for (const [role, expectCode] of [["user", false], ["developer", true]]) {
  const w = new JSDOM("<!doctype html><body></body>", { runScripts: "outside-only" }).window;
  w.AnaStudio = { user: () => ({ role }) };
  w.eval(src);
  const t = w.AnaErrors.text({ code: "SQL", message: "syntax error at or near \"FORM\"" });
  ok(t.includes("Nada foi gravado") && t.includes("Avise o responsável"), `erro técnico explicado em português (${role})`);
  ok(t.includes("syntax error") === expectCode, `código e mensagem técnica ${expectCode ? "visíveis" : "ocultos"} para ${role} (CA-050-04)`);
  const biz = w.AnaErrors.text({ code: "CUSTOMER_BLOCKED", message: "cliente bloqueado — limite de crédito" });
  ok(biz.startsWith("cliente bloqueado"), `mensagem de negócio mostrada como está (${role})`);
}
