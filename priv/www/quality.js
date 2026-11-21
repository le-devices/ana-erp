// SPDX-FileCopyrightText: 2026 André Luis Pereira dos Santos
// SPDX-License-Identifier: AGPL-3.0-or-later
// Quality of a program (spec 064, D8): the gate's findings, the program's tests with coverage and the comparison with
// the previous version, the versions (and the package that brought each one) and the failures by version. "Explicar"
// opens the assistant (spec 052) with the finding and the lines around it; the person applies and reviews.
"use strict";
(function () {
  const { el, toast, table, fmtDate, pill } = window.AnaUI;
  const API = window.AnaApi;
  const SEVERITY = { critical: "crítico", serious: "sério", warning: "atenção", info: "informação" };
  const METRIC = { sql_count: "comandos SQL", cpu_ms: "CPU (ms)" };

  const HOWTO = "Declare os testes junto do programa: TESTS = [{\"name\": \"…\", \"params\": {…}, \"expect\": {…}}] (o resultado contém expect) "
    + "ou {\"name\", \"params\", \"error\": \"CODIGO\"} (a rotina falha com esse código); ou funções def test_algo(): com assert. "
    + "Cada teste roda num ensaio: tudo é desfeito e e-mails, conectores e arquivos ficam retidos.";

  async function explain(program, f) {
    let snippet = "";
    try {
      const src = (await API.program(program)).source || "";
      const lines = src.split("\n");
      const from = Math.max(0, (f.line || 1) - 4);
      snippet = lines.slice(from, from + 8).map((l, i) => `${from + i + 1}: ${l}`).join("\n");
    } catch (_) { /* the finding alone */ }
    const text = `Explique o achado "${f.rule}" (${f.message}) na linha ${f.line} do programa ${program} e proponha a correção.\n${snippet}`;
    if (window.AnaAssistant) window.AnaAssistant.open(text);
  }

  async function render(host, program) {
    host.replaceChildren(el("p", { class: "muted", text: "Carregando…" }));
    let q;
    try { q = await API.programQuality(program); } catch (e) { host.replaceChildren(el("p", { class: "error", text: window.AnaUI.errorText(e) })); return; }
    const gate = q.gate || { blocking: [], exempted: [], baseline: [] };
    const last = q.runs[0] || null;
    const assistant = window.AnaAssistant ? await window.AnaAssistant.isEnabled() : false;
    const runBtn = el("button", { type: "button", class: "primary", text: "Rodar os testes", disabled: q.in_production,
                                  title: q.in_production ? "Testes rodam na instância de desenvolvimento ou de testes" : "" });
    runBtn.addEventListener("click", async () => {
      runBtn.disabled = true;
      runBtn.textContent = "Rodando…";
      try {
        const r = await API.runProgramTests(program);
        toast(`${r.passed} passaram, ${r.failed} falharam${r.coverage !== null ? ` · cobertura ${r.coverage}%` : ""}${r.regressions.length ? ` · ${r.regressions.length} piora(s) de desempenho` : ""}.`, !!(r.failed || r.regressions.length));
        render(host, program);
      } catch (e) { toast(window.AnaUI.errorText(e), true); runBtn.disabled = false; runBtn.textContent = "Rodar os testes"; }
    });
    const findings = [...gate.blocking.map((f) => ({ ...f, state: "bloqueia" })), ...gate.exempted.map((f) => ({ ...f, state: "isento" })),
                      ...gate.baseline.map((f) => ({ ...f, state: "linha de base" }))];
    host.replaceChildren(
      el("div", { class: "quality-head" },
        el("h2", { text: `Qualidade de ${program} (v${q.version})` }),
        pill(q.gate_ok ? "portão verde" : "portão bloqueia o transporte", q.gate_ok ? "ok" : "bad"),
        runBtn),
      el("section", { class: "card" }, el("h3", { text: "Achados do portão" }),
        table([
          { label: "Linha", value: (f) => f.line || "—", class: "num" },
          { label: "Gravidade", value: (f) => SEVERITY[f.severity] || f.severity },
          { label: "Situação", value: (f) => f.state },
          { label: "O que é", value: (f) => el("span", {}, el("strong", { text: f.message }), f.suggestion ? el("div", { class: "muted small", text: f.suggestion }) : null) },
          { label: "", value: (f) => (assistant ? el("button", { type: "button", class: "quiet small", text: "Explicar", onclick: () => explain(program, f) }) : "") },
        ], findings, { empty: "Nenhum achado: o programa passa no portão." })),
      el("section", { class: "card" }, el("h3", { text: "Testes" }),
        last ? el("p", {}, `Última rodada (v${last.version}, ${fmtDate(last.run_at)}, por ${last.run_by}): `,
          el("strong", { text: `${last.passed} passaram, ${last.failed} falharam` }),
          last.coverage !== null ? ` · cobertura de linhas ${last.coverage}% (${last.executed_lines} de ${last.executable_lines})` : "",
          last.previous_version ? ` · comparado com a v${last.previous_version}` : " · sem versão anterior para comparar")
             : el("p", { class: "muted", text: "Os testes ainda não rodaram nesta instalação." }),
        last ? table([
          { label: "Teste", value: (t) => t.name },
          { label: "Situação", value: (t) => el("span", { class: "status-chip status-" + (t.status === "passed" ? "success" : "error"), text: t.status === "passed" ? "passou" : "falhou" }) },
          { label: "SQL", value: (t) => (t.metrics ? t.metrics.sql_count : "—"), class: "num" },
          { label: "CPU (ms)", value: (t) => (t.metrics ? t.metrics.cpu_ms : "—"), class: "num" },
          { label: "Motivo", value: (t) => t.message || "" },
        ], last.results, { empty: "O programa não declara testes. " + HOWTO }) : el("p", { class: "muted small", text: HOWTO }),
        last && last.regressions.length ? el("div", { class: "quality-regressions" }, el("h4", { text: "Piora em relação à versão anterior" }),
          el("ul", {}, ...last.regressions.map((g) => el("li", { text: `${g.test}: ${METRIC[g.metric] || g.metric} de ${g.previous} para ${g.current}` })))) : null),
      el("section", { class: "card" }, el("h3", { text: "Falhas por versão" }),
        table([
          { label: "Versão", value: (g) => `v${g.version}` },
          { label: "Erro", value: (g) => el("span", {}, el("code", { text: g.code || "?" }), el("div", { class: "muted small", text: g.message || "" })) },
          { label: "Vezes", value: (g) => g.n, class: "num" },
          { label: "Desde", value: (g) => `${fmtDate(g.first_seen)}${g.started_in ? ` · começou na v${g.started_in}` : ""}` },
          { label: "Pacote que trouxe a versão", value: (g) => (g.package
              ? `${g.package.title} (${fmtDate(g.package.imported_at)})${g.package.gate ? (g.package.gate.ok ? " · portão verde" : " · portão com bloqueios") : " · sem relatório do portão"}`
              : "feita nesta instância") },
        ], q.failures, { empty: "Nenhuma falha nos últimos 90 dias." })),
      el("section", { class: "card" }, el("h3", { text: "Versões" }),
        table([
          { label: "Versão", value: (v) => `v${v.version}` },
          { label: "Quando", value: (v) => fmtDate(v.created_at) },
          { label: "Por", value: (v) => v.created_by },
          { label: "Pacote", value: (v) => v.package || "—" },
          { label: "Comentário", value: (v) => v.comment || "" },
        ], q.versions, { empty: "Sem versões." })));
  }

  window.AnaQuality = { render };
})();
