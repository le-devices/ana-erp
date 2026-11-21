// SPDX-FileCopyrightText: 2026 LE Devices
// SPDX-License-Identifier: AGPL-3.0-or-later
// Pattern catalog (spec 050, T-050-01; constitution P18): the rules every screen follows, each with a
// live example built by the same components the screens use. Developers see it in Desenvolvimento →
// Padrões; the verifier of the Studio tests (tests/studio/ux_check.mjs) enforces the checkable ones.
(function () {
  "use strict";
  const { el, pill, table } = window.AnaUI;

  const SECTIONS = [
    { id: "acoes", title: "Ações e botões", rules: [
        "Um botão primário por área: a ação principal do momento (Salvar, Executar).",
        "Ação que grava pode ser ensaiada antes (F9, spec 056); F8 salva.",
        "Ação irreversível pede confirmação dizendo a consequência; reversível oferece desfazer.",
        "Todo botão tem texto ou nome acessível (aria-label) — verificado automaticamente."],
      demo: () => el("div", { class: "row-buttons" },
        el("button", { type: "button", class: "primary", text: "Salvar (F8)" }),
        el("button", { type: "button", text: "Ensaiar (F9)" }),
        el("button", { type: "button", class: "quiet", text: "Cancelar" }),
        el("button", { type: "button", class: "danger", text: "Apagar…" })) },
    { id: "situacao", title: "Situação", rules: [
        "Situação sempre com ícone e texto, nunca só cor (acessibilidade).",
        "As cores de situação são reservadas: não servem para séries de gráfico."],
      demo: () => el("div", { class: "row-buttons" }, pill("● ativo", "ok"), pill("▲ atenção", "warn"), pill("■ falha", "off"), pill("inativo")) },
    { id: "tabela", title: "Tabela de trabalho", rules: [
        "Listas usam a tabela de trabalho: busca, filtros, colunas e variantes por usuário (spec 020).",
        "Clicar na linha abre o documento ou a ficha; números alinhados à direita.",
        "Lista vazia diz por quê e oferece a ação que a preenche — verificado automaticamente."],
      demo: () => el("div", {},
        table([{ label: "Pedido", value: (r) => r.n }, { label: "Cliente", value: (r) => r.c }, { label: "Valor", value: (r) => r.v, class: "num" }],
              [{ n: "PV-1001", c: "Exemplo Indústria", v: "1.250,00" }, { n: "PV-1002", c: "Exemplo Comércio", v: "980,00" }]),
        el("h4", { text: "Estado vazio" }),
        table([{ label: "Pedido", value: () => "" }], [], { empty: "Nenhum pedido ainda.",
          emptyAction: { label: "Criar pedido", onClick: () => window.AnaUI.toast("Exemplo: abriria a criação do pedido.") } })) },
    { id: "formulario", title: "Formulários", rules: [
        "Todo campo tem rótulo (nome acessível) e, quando ajuda, uma dica curta — verificado automaticamente.",
        "Valores padrão pelo contexto e pelo último uso; o usuário digita o mínimo.",
        "O erro aparece no próprio campo, dizendo como corrigir."],
      demo: () => {
        const input = el("input", { value: "12.ABC.345/01DE-34", "aria-invalid": "true" });
        return el("div", { class: "form-card" }, el("label", {}, "CNPJ", input),
          el("div", { class: "field-error", text: "CNPJ inválido: confira os números e letras (dígito verificador)." }));
      } },
    { id: "erros", title: "Mensagens de erro", rules: [
        "O que aconteceu e o que fazer, em português simples; nunca código técnico na tela de operação (P18).",
        "Desenvolvedores e administradores também veem o código e a mensagem original.",
        "Texto técnico (undefined, pilha, SQLSTATE) na tela de operação é apontado automaticamente."],
      demo: () => {
        const d = window.AnaErrors.describe({ code: "TIMEOUT", message: "execution exceeded 60000 ms" });
        return el("div", { class: "end error" }, el("strong", { text: d.title }), el("div", { text: d.action }),
          d.technical ? el("div", { class: "muted small", text: d.technical }) : null);
      } },
    { id: "indicadores", title: "Indicadores e gráficos", rules: [
        "Número e situação antes de texto longo; indicadores no topo da página da rotina.",
        "Gráficos pela biblioteca do produto (spec 026): paleta validada para daltonismo, legenda, dicas e tabela.",
        "Um eixo só; nunca dois eixos verticais."],
      demo: () => el("div", {}, el("div", { class: "stat-grid" },
          el("div", { class: "stat" }, el("div", { class: "label", text: "Pedidos hoje" }), el("div", { class: "value", text: "42" })),
          el("div", { class: "stat" }, el("div", { class: "label", text: "Em atraso" }), el("div", { class: "value", text: "3" }))),
        window.AnaCharts ? window.AnaCharts.render({ type: "bar", title: "Exemplo: pedidos por dia", x: ["seg", "ter", "qua"],
          series: [{ name: "Pedidos", values: [12, 18, 9] }] }) : null) },
    { id: "fluxo", title: "Próximo passo e desempenho", rules: [
        "Toda tela de resultado mostra a próxima ação do processo (spec 020); nenhuma tela é beco sem saída.",
        "Resposta visível em até 100 ms a cada ação; tela aberta em até 1 s (p95) — medido nos navegadores (Desempenho das telas).",
        "Funciona no celular, no tema claro e escuro, e só com o teclado."],
      demo: () => el("div", { class: "row-buttons" }, el("span", { text: "Pedido criado. Próximo passo: " }),
        el("button", { type: "button", class: "primary", text: "Faturar este pedido" })) },
  ];

  function render(target) {
    target.replaceChildren(
      el("h1", { text: "Padrões de experiência" }),
      el("p", { class: "lead", text: "Como toda tela do ANA se comporta (constituição P18, spec 050). As regras marcadas como verificadas automaticamente fazem a bateria de testes falhar quando uma tela nova as quebra." }),
      el("nav", { class: "row-buttons", "aria-label": "Seções do catálogo" },
        SECTIONS.map((s) => el("a", { href: `#/dev/patterns`, class: "button quiet small", text: s.title,
          onclick: (e) => { e.preventDefault(); target.querySelector("#pattern-" + s.id).scrollIntoView(); } }))),
      ...SECTIONS.map((s) => el("section", { class: "card", id: "pattern-" + s.id },
        el("h2", { text: s.title }),
        el("ul", {}, s.rules.map((r) => el("li", { text: r }))),
        el("div", { class: "pattern-demo" }, s.demo()))));
  }

  window.AnaPatterns = { render, SECTIONS };
})();
