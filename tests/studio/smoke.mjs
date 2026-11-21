// SPDX-FileCopyrightText: 2026 LE Devices
// SPDX-License-Identifier: AGPL-3.0-or-later
// Studio smoke test (specs 005, 011, 012, 020): loads the real page in a DOM
// (jsdom), runs the scripts served by ANA and walks through the areas.
// Run: docker run --rm --network host -v $PWD/tests/studio:/t -w /t node:22-alpine \
//      sh -c "npm i --silent --no-save jsdom@24 && node smoke.mjs"
import { JSDOM, VirtualConsole } from "jsdom";
import { Verifier } from "./ux_check.mjs";

const ANA_URL = process.env.ANA_URL || "http://localhost:8080";
const PASSWORD = process.env.ANA_ADMIN_PASSWORD || "admin";

async function open(username, password) {
  const jsErrors = [];
  const vc = new VirtualConsole();
  vc.on("jsdomError", (e) => jsErrors.push(String(e.message || e)));
  vc.on("error", (e) => jsErrors.push(String(e)));
  const html = await (await fetch(ANA_URL + "/")).text();
  const dom = new JSDOM(html, {
    url: ANA_URL + "/", runScripts: "dangerously", resources: "usable", pretendToBeVisual: true, virtualConsole: vc,
    beforeParse(w) {
      w.fetch = (u, o) => fetch(new URL(u, ANA_URL), o);
      w.document.execCommand = () => false;
      w.confirm = () => true;
    },
  });
  const w = dom.window;
  w.__session = username;
  current = w;
  await new Promise((r) => w.addEventListener("load", r));
  await until(() => !w.document.querySelector("#login-screen").hidden, "login screen", jsErrors);
  const f = w.document.querySelector("#login-form");
  f.elements.namedItem("username").value = username;
  f.elements.namedItem("password").value = password;
  submit(w, f);
  await until(() => !w.document.querySelector("#app-screen").hidden, "app", jsErrors);
  return { w, d: w.document, jsErrors };
}

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
// Spec 050 (T-050-02): every screen reached is checked against the premium-experience rules.
const verifier = new Verifier();
let current = null;
const screenOf = (w) => `${w.__session} ${(w.location.hash || "#/home").split("?")[0].replace(/\/\d+(?=\/|$)/g, "/:id")}`;
async function until(cond, label, errs = [], ms = 15000) {
  const end = Date.now() + ms;
  while (Date.now() < end) {
    if (cond()) { if (current && current.document.querySelector("#app-screen:not([hidden])")) verifier.check(current.document, screenOf(current)); return; }
    await sleep(50);
  }
  throw new Error("timed out waiting for: " + label + "\nJS errors: " + errs.join("\n"));
}
const ok = (c, m) => { if (!c) throw new Error("failed: " + m); console.log("✔", m); };
const submit = (w, form) => form.dispatchEvent(new w.Event("submit", { cancelable: true }));
const go = async (w, hash) => { current = w; w.location.hash = hash; await sleep(50); };
// Data a screen needs is created by the suite itself: on CI each suite starts from a clean database.
let rpcToken = null;
async function rpc(method, params) {
  rpcToken ??= (await (await fetch(ANA_URL + "/api/session", { method: "POST", headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ username: "admin", password: PASSWORD }) })).json()).token;
  const r = await (await fetch(ANA_URL + "/rpc", { method: "POST", headers: { "Content-Type": "application/json", Authorization: "Bearer " + rpcToken },
    body: JSON.stringify({ jsonrpc: "2.0", id: 1, method, params }) })).json();
  if (r.error) throw new Error(`${method}: ${JSON.stringify(r.error)}`);
  return r.result;
}

// ---------------------------------------------------------------- admin/developer
const { w, d, jsErrors } = await open("admin", PASSWORD);
const text = (s) => (d.querySelector(s) || {}).textContent || "";
await until(() => text("#area-home").includes("Favoritas"), "home");
ok(!d.querySelector("#area-home").hidden, "Início é a área inicial");
ok([...d.querySelectorAll(".area:not([hidden])")].map((b) => b.dataset.area).join(",") === "home,ops,bpm,master,files,dev,admin", "admin vê as sete áreas (Portal é só para contas externas)");

// Operation: routine with form, result and history together (RF-020-03)
await go(w, "#/ops/demo/demo.hello");
await until(() => text("#ops-main").includes("Filtros") && d.querySelector("#ops-main form"), "routine page", jsErrors);
ok(text("#ops-nav").includes("Demonstração") && text("#ops-nav").includes("Projetos"), "módulos agrupados na navegação");
const form = d.querySelector("#ops-main form");
form.querySelector("[name=name]").value = "Operador";
submit(w, form);
await until(() => text("#ops-main").includes("concluído"), "routine run", jsErrors);
ok(text("#ops-main").includes("3² = 9"), "saída da rotina na mesma tela");
await until(() => d.querySelectorAll("#ops-main .grid-table tbody tr").length > 0 && !text("#ops-main").includes("ainda não executou"), "history");
ok(true, "histórico da rotina na mesma tela");
d.querySelector("#ops-main .star").click();
await until(() => text("#ops-nav").includes("★"), "favorite");
await go(w, "#/home");
await until(() => text("#area-home").includes("Programa de demonstração"), "favorite in home", jsErrors);
ok(true, "favorito aparece no Início (CA-020-05)");

// Spec 045: the values on screen saved as a variant, chosen at once, with a locked field.
await go(w, "#/ops/demo/demo.hello?name=Variante&_form=1");
await until(() => [...d.querySelectorAll("#ops-main .variant-bar button")].some((b) => b.textContent === "Salvar como variante…"), "variant bar", jsErrors);
[...d.querySelectorAll("#ops-main .variant-bar button")].find((b) => b.textContent === "Salvar como variante…").click();
await until(() => d.querySelector("#ops-main .variant-panel form"), "variant panel", jsErrors);
const vname = "Smoke " + Date.now().toString().slice(-6);
const vf = d.querySelector("#ops-main .variant-panel form");
vf.querySelector("input[aria-label='Nome da variante']").value = vname;
vf.querySelector("input[aria-label^='Travar']").checked = true;
submit(w, vf);
await until(() => [...d.querySelectorAll("#ops-main .variant-select option")].some((o) => o.textContent.startsWith(vname) && o.selected), "variant saved", jsErrors);
await until(() => d.querySelector("#ops-main form.params-form [name=name]") && d.querySelector("#ops-main form.params-form [name=name]").disabled, "variant applied", jsErrors);
ok(d.querySelector("#ops-main form.params-form [name=name]").value === "Variante", "variante salva da tela, escolhida e com o campo travado (spec 045)");
{
  const tk = (await (await fetch(ANA_URL + "/api/session", { method: "POST", headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ username: "admin", password: PASSWORD }) })).json()).token;
  const vs = await (await fetch(ANA_URL + "/api/programs/demo.hello/variants", { headers: { Authorization: "Bearer " + tk } })).json();
  for (const v of vs.variants.filter((x) => x.name === vname))
    await fetch(ANA_URL + `/api/programs/demo.hello/variants/${v.id}`, { method: "DELETE", headers: { Authorization: "Bearer " + tk } });
}

// A library opens for editing, but Executar/Depurar say it is not run by itself.
await go(w, "#/dev/program/util.pdf");
await until(() => text("#program-name") === "util.pdf", "library", jsErrors);
ok(d.querySelector("#run").disabled && d.querySelector("#debug").disabled && d.querySelector("#run").title.includes("Biblioteca"),
   "biblioteca: Executar e Depurar desativados, com a explicação");

// Development: program tabs (RF-020-04)
await go(w, "#/dev/program/demo.hello");
await until(() => text("#program-name") === "demo.hello", "program after library", jsErrors);
ok(!d.querySelector("#run").disabled, "programa comum volta a ter Executar");
await until(() => text("#program-name") === "demo.hello", "program", jsErrors);
ok(d.querySelector("#editor textarea").value.includes("def main"), "código no editor");
ok([...d.querySelectorAll("[data-ptab]")].map((b) => b.textContent).join("|") === "Código|Propriedades e limites|Versões|Execuções|Agendamentos|Desempenho", "abas do programa");
ok([...d.querySelectorAll("[data-panel]")].map((b) => b.textContent).join("|") === "Saída|Resultado", "painel inferior só com Saída e Resultado (CA-020-02)");
d.querySelector('[data-ptab="props"]').click();
await until(() => d.querySelectorAll("#limits-box input").length === 10, "limits", jsErrors);
await until(() => text("#program-commands").includes("hello"), "commands", jsErrors);
ok(text("#ptab-props").includes("Comandos") && text("#program-commands").includes("hello"), "propriedades, comandos e limites juntos");
d.querySelector('[data-ptab="perf"]').click();
await until(() => text("#ptab-perf").includes("Análise do SQL do código"), "perf tab", jsErrors);
ok(true, "aba Desempenho do programa (spec 019)");
d.querySelector('[data-ptab="versions"]').click();
await until(() => /\bv\d+/.test(text("#version-list")), "versions", jsErrors);
ok(true, "versões na aba do programa");
// Schedules of this program (spec 018)
d.querySelector('[data-ptab="schedules"]').click();
await until(() => d.querySelector("#ptab-schedules form.form-card"), "schedule form", jsErrors);
const jobName = "smoke-" + Date.now().toString().slice(-6);
const jf = d.querySelector("#ptab-schedules form.form-card");
jf.querySelector("input").value = jobName;
jf.dispatchEvent(new w.Event("submit", { cancelable: true }));
await until(() => text("#ptab-schedules").includes(jobName), "job created", jsErrors);
ok(text("#ptab-schedules").includes("ativa"), "rotina agendada criada na aba do programa");
[...d.querySelectorAll("#ptab-schedules tbody tr")].find((tr) => tr.textContent.includes(jobName)).click();
await until(() => text("#ptab-schedules").includes("Próximas execuções"), "job detail", jsErrors);
ok(text("#ptab-schedules").includes("Pular a próxima"), "detalhe com próximas execuções e ações");
const delBtn = [...d.querySelectorAll("#ptab-schedules button")].find((b) => b.textContent === "Excluir");
delBtn.click();
await until(() => !text("#ptab-schedules").includes(jobName), "job deleted", jsErrors);
d.querySelector('[data-ptab="code"]').click();
const line = d.querySelector("#editor textarea").value.split("\n").findIndex((l) => l.includes("total += q")) + 1;
d.querySelector(`#editor .num[data-line="${line}"]`).click();
d.querySelector("#debug").click();
await until(() => text("#run-state").includes(`linha ${line}`), "breakpoint", jsErrors);
ok([...d.querySelectorAll("#variables td")].some((td) => td.textContent.startsWith("q")), "depurador: variáveis");
d.querySelector(`#editor .num[data-line="${line}"]`).click();
await sleep(150);
d.querySelector("#dbg-continue").click();
await until(() => text("#run-state").startsWith("success"), "debug end", jsErrors);
ok(text("#panel-output").includes("CPU"), "consumo exibido ao final (spec 012)");

// Data: catalog + console together (RF-020-05)
await go(w, "#/dev/data/base/product");
await until(() => text("#table-detail").includes("base.product"), "table", jsErrors);
d.querySelector("#table-detail .page-header button").click();
submit(w, d.querySelector("#sql-form"));
await until(() => text("#sql-result").includes("linha(s)"), "sql", jsErrors);
ok(true, "catálogo e console SQL na mesma tela");

// Spec 050 (T-050-01): the pattern catalog, with live examples built by the real components.
await go(w, "#/dev/patterns");
await until(() => text("#patterns-view").includes("Padrões de experiência") && d.querySelector("#patterns-view .empty-state button"), "patterns", jsErrors);
ok(d.querySelectorAll("#patterns-view section").length >= 6, "catálogo de padrões com exemplos vivos (spec 050)");

// Go-to bar
d.querySelector("#command").value = "balance";
submit(w, d.querySelector("#command-form"));
await until(() => location_hash(w).startsWith("#/ops/inventory/inventory.balance"), "go-to", jsErrors);
ok(true, "barra Ir para abre rotina pelo comando");

// Usability: selection screen with choices and lookups, collapse after running, Back (F3)
await go(w, "#/ops/projects/projects.workspace");
await until(() => d.querySelector("#ops-main select[name=view]"), "choices", jsErrors);
ok([...d.querySelectorAll("#ops-main .params-form [name]")].map((i) => i.name).slice(0, 2).join(",") === "project,view",
   "campos na ordem declarada no programa");
ok([...d.querySelector("#ops-main select[name=view]").options].some((o) => o.textContent === "Viabilidade"), "aba como lista de escolha em português");
await until(() => [...d.querySelector("#ops-main select[name=project]").options].some((o) => o.value === "PRJ-001"), "project lookup", jsErrors);
ok(!text("#ops-main").includes("RF-021"), "sem texto técnico do programa na Operação");
d.querySelector("#ops-main select[name=project]").value = "PRJ-001";
submit(w, d.querySelector("#ops-main form"));
await until(() => d.querySelector("#ops-main .routine-layout.collapsed") && text("#ops-main .params-summary").includes("PRJ-001"), "collapsed", jsErrors);
ok(true, "depois de executar, o resultado ocupa a tela e os parâmetros viram resumo");
ok(d.querySelectorAll(".splitter").length >= 2, "divisórias redimensionáveis");
ok(!d.querySelector("#back").hidden, "botão Voltar visível");
d.querySelector("#back").click();
await until(() => d.querySelector("#ops-main .routine-layout:not(.collapsed)") && d.querySelector("#ops-main select[name=project]")
             && d.querySelector("#ops-main select[name=project]").value === "PRJ-001", "back to selection", jsErrors);
ok(true, "Voltar retorna à tela de seleção preenchida (F3)");

// Consulting project in tabs (spec 021): address with parameters runs the routine (RF-020-12)
await go(w, "#/ops/projects/projects.workspace?project=PRJ-001&view=board");
await until(() => d.querySelectorAll("#ops-main .board-card").length > 0, "board", jsErrors);
ok(d.querySelectorAll("#ops-main .board-col").length === 5, "quadro com as cinco colunas do fluxo (RF-021-04)");
await go(w, "#/ops/projects/projects.workspace?project=PRJ-001&view=structure");
await until(() => d.querySelector("#ops-main .table-box button"), "table tools", jsErrors);
ok([...d.querySelectorAll("#ops-main .table-box button")].some((b) => b.textContent.includes("CSV")) && d.querySelector("#ops-main th.sortable"),
   "tabelas com ordenação e exportação CSV");
// Work table (RF-020-17, CA-020-12): choose columns, filter, save a variant; the layout comes back on reopening.
{
  const box = () => d.querySelector("#ops-main .work-box");
  const heads = () => box().querySelectorAll("thead tr:first-child th.sortable").length;
  const btn = (label) => [...box().querySelectorAll(".table-tools button")].find((b) => b.textContent.includes(label));
  const before = heads();
  ok(before >= 2 && btn("Colunas") && btn("Filtros") && btn("Variante") && box().querySelector(".table-search"), "barra da tabela: busca, filtros, colunas, variantes e CSV");
  btn("Colunas").click();
  await until(() => !box().querySelector(".table-pop").hidden, "columns panel", jsErrors);
  const boxes = box().querySelectorAll(".col-list input[type=checkbox]");
  boxes[1].checked = false;
  boxes[1].dispatchEvent(new w.Event("change"));
  await until(() => heads() === before - 1, "column hidden", jsErrors);
  ok(true, "escolha das colunas muda a tabela");
  btn("Filtros").click();
  const f = box().querySelector(".col-filter");
  f.value = "zzz-nada-assim";
  f.dispatchEvent(new w.Event("input"));
  await until(() => box().textContent.includes("Nenhuma linha com essa busca ou filtro"), "column filter", jsErrors);
  ok(box().querySelector(".table-count").textContent.includes(" de "), "filtro por coluna, com a contagem do que aparece");
  f.value = "";
  f.dispatchEvent(new w.Event("input"));
  await until(() => !box().textContent.includes("Nenhuma linha com essa busca"), "filter cleared", jsErrors);
  btn("Variante").click();
  await until(() => box().querySelector(".variant-save input"), "variants panel", jsErrors);
  box().querySelector(".variant-save input").value = "Teste estúdio";
  [...box().querySelectorAll(".variant-save button")].find((b) => b.textContent === "Salvar variante").click();
  await until(() => btn("Variante").textContent.includes("Teste estúdio"), "variant saved", jsErrors);
  await go(w, "#/ops/projects/projects.workspace?project=PRJ-001&view=board");
  await until(() => d.querySelectorAll("#ops-main .board-card").length > 0, "board (leave table)", jsErrors);
  await go(w, "#/ops/projects/projects.workspace?project=PRJ-001&view=structure");
  await until(() => box() && heads() === before - 1, "layout back", jsErrors);
  ok(btn("Variante").textContent.includes("Teste estúdio"), "colunas e variante voltam ao reabrir a tela (CA-020-12)");
  btn("Variante").click();
  await until(() => [...box().querySelectorAll(".variant-save button")].some((b) => b.textContent.includes("Excluir")), "variant delete", jsErrors);
  [...box().querySelectorAll(".variant-save button")].find((b) => b.textContent.includes("Excluir")).click();
  await until(() => btn("Variante").textContent.includes("atual"), "variant removed", jsErrors);
  btn("Colunas").click();
  await until(() => !box().querySelector(".table-pop").hidden, "columns panel again", jsErrors);
  [...box().querySelectorAll(".table-pop button")].find((b) => b.textContent === "Restaurar padrão").click();
  await until(() => heads() === before, "layout restored", jsErrors);
  ok(true, "variante excluída e colunas de volta ao padrão");
  // Screen state (RF-020-18): collapsible side panel and pinned header, remembered.
  const side = d.querySelector("#area-ops .split-toggle");
  side.click();
  ok(d.querySelector("#area-ops").classList.contains("split-collapsed") && side.getAttribute("aria-expanded") === "false", "painel lateral recolhe");
  side.click();
  ok(!d.querySelector("#area-ops").classList.contains("split-collapsed"), "e volta");
  const pin = d.querySelector("#ops-main .pin-toggle");
  pin.click();
  ok(d.querySelector("#ops-main .page-band").classList.contains("pinned") && w.AnaPrefs.get("pin.routine.projects.workspace") === true, "cabeçalho fixado e lembrado");
  pin.click();
}
// Definition with the simulation beside it and the condition builder (RF-020-13/14, CA-020-08/09).
// The builder lists the facts of an open sales order.
await rpc("sales.create_order", { customer: 1, items: [{ product: "FEIJAO-1", quantity: 1 }] });
await go(w, "#/ops/flows/flows.step_condition?flow=sales&step=2&_form=1");
await until(() => d.querySelector("#ops-main .sim-split .cond-builder") && d.querySelector("#ops-main .cond-line select option[value=total]"), "condition builder", jsErrors);
{
  const m = d.querySelector("#ops-main");
  ok(m.querySelector(".sim-card") && [...m.querySelectorAll("button")].some((b) => b.textContent === "Simular (F9)")
     && [...m.querySelectorAll("button")].some((b) => b.textContent === "Salvar (F8)"), "definição à esquerda, simulação à direita, salvar separado");
  ok(!m.querySelector("input[name=simulate]"), "a opção de simular não aparece como campo");
  const line = m.querySelector(".cond-criterion .cond-line");
  const [field, op] = line.querySelectorAll("select");
  field.value = "total"; field.dispatchEvent(new w.Event("change"));
  await sleep(50);
  const line2 = m.querySelector(".cond-criterion .cond-line");
  line2.querySelectorAll("select")[1].value = ">";
  line2.querySelectorAll("select")[1].dispatchEvent(new w.Event("change"));
  await sleep(50);
  const v = m.querySelector(".cond-criterion .cond-line input");
  v.value = "1.000"; v.dispatchEvent(new w.Event("change"));
  m.querySelector(".cond-add").click();
  const exAdd = [...m.querySelectorAll(".cond-except button")].find((b) => b.textContent === "+ exceção");
  exAdd.click();
  ok(text("#ops-main .cond-text").includes("Total maior que 1.000") && m.querySelectorAll(".cond-tabs button").length === 2,
     "construtor: linha com operador do tipo, outro critério (OU) e exceção, regra em português");
  void op;
  [...m.querySelectorAll("button")].find((b) => b.textContent === "Simular (F9)").click();
  await until(() => text("#ops-main .sim-output").includes("Documentos que tornariam a etapa automática"), "simulation", jsErrors);
  ok(text("#ops-main .sim-when").includes("nada foi gravado"), "simulação ao lado com hora, sem gravar (CA-020-08)");
}

// Planning grid by period and its chart (RF-020-15/16, CA-020-10/11): at least four budget lines in the year.
for (const account of ["5.1.1", "5.1.2", "5.1.3", "5.1.4"])
  await rpc("finance.save_budget", { cost_center: "GERAL", account, months: ["2026-01", "2026-02", "2026-03"], amount: "100" });
await go(w, "#/ops/finance/finance.budget_plan?start=2026-01&end=2026-12");
await until(() => d.querySelector("#ops-main .plan-grid tbody td.cell"), "planning grid", jsErrors);
{
  const m = d.querySelector("#ops-main");
  ok(m.querySelectorAll(".plan-grid thead th.period").length === 12 && m.querySelectorAll(".plan-grid thead th.sticky-col.dim").length === 2
     && m.querySelector(".plan-grid tfoot tr.totals"), "grade: colunas dos meses pelo intervalo, dimensões fixas e totais");
  const totalBefore = m.querySelector(".plan-grid tfoot td.total").textContent;
  const cell = m.querySelector(".plan-grid tbody td.cell");
  cell.dispatchEvent(new w.MouseEvent("click", { bubbles: true }));
  cell.dispatchEvent(new w.KeyboardEvent("keydown", { key: "7", bubbles: true }));
  const ed = m.querySelector(".plan-grid .cell-editor");
  ok(ed && ed.value === "7", "digitar numa célula abre a edição");
  ed.value = "1.234,50";
  ed.dispatchEvent(new w.KeyboardEvent("keydown", { key: "Enter", bubbles: true }));
  await until(() => m.querySelector(".plan-grid td.cell.changed"), "cell changed", jsErrors);
  ok(m.querySelector(".plan-grid td.cell.changed").textContent === "1.234,50" && m.querySelector(".plan-grid tfoot td.total").textContent !== totalBefore
     && /Salvar alterações \(1\)/.test([...m.querySelectorAll(".plan-foot button")].map((b) => b.textContent).join()),
     "edição com número brasileiro, total acompanha, salvar mostra o que mudou");
  const second = m.querySelectorAll(".plan-grid tbody tr")[1].querySelector("td.cell");
  const paste = new w.Event("paste", { bubbles: true, cancelable: true });
  paste.clipboardData = { getData: () => "10\t20\n30\t40\n" };
  second.dispatchEvent(paste);
  await until(() => m.querySelectorAll(".plan-grid td.cell.changed").length >= 5, "pasted block", jsErrors);
  ok(true, "colar bloco da planilha preenche células à direita e abaixo");
  const neg = new w.KeyboardEvent("keydown", { key: "-", bubbles: true });
  const third = m.querySelectorAll(".plan-grid tbody tr")[3].querySelector("td.cell");
  third.dispatchEvent(new w.MouseEvent("click", { bubbles: true })); third.dispatchEvent(neg);
  const ed2 = m.querySelector(".plan-grid .cell-editor");
  if (ed2) { ed2.value = "-5"; ed2.dispatchEvent(new w.KeyboardEvent("keydown", { key: "Enter", bubbles: true })); }
  ok(w.AnaLeave.dirty(), "alterações não salvas são lembradas ao sair");
  m.querySelectorAll(".plan-grid tbody tr")[0].querySelector("td.dim").dispatchEvent(new w.MouseEvent("click", { bubbles: true }));
  await until(() => text("#ops-main .plan-chart .chart-legend").includes("Realizado"), "linked chart", jsErrors);
  ok(text("#ops-main .plan-chart .chart-legend").includes("Orçado") && text("#ops-main .plan-chart .chart-legend").includes("Saldo")
     && m.querySelectorAll(".plan-chart svg.chart-svg").length === 1, "gráfico da linha: orçado × realizado × saldo num só eixo");
  const c = w.AnaCharts.render({ type: "column", x: ["a", "b"], alert: { series: 2 },
    series: [{ name: "P", values: [1, 1] }, { name: "C", values: [2, 0] }, { name: "D", values: [-1, 1] }] });
  ok(c.querySelectorAll(".bar.alert").length === 1 && c.querySelector(".neg-label").textContent.includes("⚠") && c.textContent.includes("D negativo"),
     "disponível negativo em destaque, com rótulo e legenda (CA-020-11)");
}

// Spec 041: the order is simulated by the policy before confirming; orders with shortages have their own screen.
await go(w, "#/ops/sales/sales.create_order?_form=1");
await until(() => [...d.querySelectorAll("#ops-main button")].some((b) => b.textContent === "Simular (F9)"), "order simulate", jsErrors);
ok(d.querySelector("#ops-main select[name=mode]") && !d.querySelector("#ops-main input[name=simulate]"),
   "pedido: modo de atendimento conforme a política e simulação antes de confirmar");
// Spec 056: a routine that writes offers "Ensaiar (F9)": it runs whole, is undone, and the effect is shown.
await go(w, "#/ops/sales/sales.release_held?_form=1");
await until(() => [...d.querySelectorAll("#ops-main button")].some((b) => b.textContent === "Ensaiar (F9)"), "rehearse button", jsErrors);
{
  [...d.querySelectorAll("#ops-main button")].find((b) => b.textContent === "Ensaiar (F9)").click();
  await until(() => d.querySelector("#ops-main .rehearsal-card"), "rehearsal card", jsErrors);
  ok(text("#ops-main .rehearsal-card").includes("nada foi gravado nem enviado"), "ensaio: mostra o efeito e diz que nada foi gravado");
}
await go(w, "#/ops/inventory/inventory.balance?_form=1");
await until(() => d.querySelector("#ops-main form"), "balance form", jsErrors);
ok(![...d.querySelectorAll("#ops-main button")].some((b) => b.textContent === "Ensaiar (F9)"), "rotina que só lê não oferece ensaio");
await go(w, "#/ops/sales/sales.shortages");
await until(() => d.querySelector("#ops-main form select[name=situation]"), "shortages form", jsErrors);
submit(w, d.querySelector("#ops-main form"));
await until(() => text("#ops-main").includes("Com data prometida vencida"), "shortages", jsErrors);
ok(text("#ops-main").includes("Atendimento dos pedidos"), "tela de pedidos com falta");
await go(w, "#/ops/sales/sales.fulfillment_policy");
await until(() => d.querySelector("#ops-main form select[name=action]"), "policy form", jsErrors);
submit(w, d.querySelector("#ops-main form"));
await until(() => text("#ops-main").includes("Exceções (a mais específica vale)"), "fulfillment policy", jsErrors);
ok(text("#ops-main").includes("Política de atendimento da empresa"), "política de atendimento com as exceções");

await go(w, "#/ops/projects/projects.workspace?project=PRJ-001&view=board");
await until(() => d.querySelectorAll("#ops-main .board-card").length > 0, "board again", jsErrors);
ok([...d.querySelectorAll("#ops-main .output-tabs button")].map((b) => b.textContent).includes("Viabilidade"), "abas do projeto, incluindo Viabilidade");
[...d.querySelectorAll("#ops-main .board-card button")].find((b) => b.textContent === "Andamento").click();
await until(() => d.querySelector("#ops-main .inline-form"), "inline form", jsErrors);
ok(d.querySelector("#ops-main .inline-form input"), "ação abre formulário na própria tela (CA-021-06)");
[...d.querySelectorAll("#ops-main .output-tabs button")].find((b) => b.textContent === "Linha do tempo").click();
await until(() => d.querySelectorAll("#ops-main .gantt-bar").length > 0, "gantt", jsErrors, 30000);   // busy right after the integration suites
ok(d.querySelectorAll("#ops-main .gantt-bar.critical").length > 0, "linha do tempo com caminho crítico");
[...d.querySelectorAll("#ops-main .output-tabs button")].find((b) => b.textContent === "Viabilidade").click();
await until(() => text("#ops-main").includes("pessimista"), "viability", jsErrors);
ok(text("#ops-main").includes("otimista") && text("#ops-main").includes("Mês a mês"), "viabilidade com cenários base, otimista e pessimista");
ok(d.querySelectorAll("#ops-main .chart svg .line").length >= 3 && d.querySelector("#ops-main .chart-legend"), "gráficos com legenda na viabilidade (spec 026)");
d.querySelector("#ops-main .chart .chart-tools button").click();
ok(!d.querySelector("#ops-main .chart .chart-table").hidden, "gráfico tem visão em tabela");

// Sales order screen (spec 031): lists for customer/warehouse/term, items grid with stock, Brazilian decimals
await go(w, "#/ops/sales/sales.create_order?_form=1");
await until(() => d.querySelector("#ops-main .rows-editor select[data-col=product]"), "items grid", jsErrors);
ok([...d.querySelectorAll("#ops-main .rows-editor th")].map((th) => th.textContent).slice(0, 3).join("|") === "item|quantidade|preço unitário (vazio = tabela)",
   "grade de itens com colunas na ordem declarada e rótulos em português");
await until(() => [...d.querySelector("#ops-main select[name=warehouse]").options].some((o) => o.value === "CENTRAL"), "warehouse list", jsErrors);
ok(![...d.querySelector("#ops-main select[name=warehouse]").options].some((o) => o.value === "TRANSITO"), "depósito é uma lista (sem trânsito/quarentena)");
ok(d.querySelector("#ops-main select[name=payment_term]").options[0].textContent === "— a do cliente —", "condição vazia explica o padrão");
const prod = d.querySelector("#ops-main .rows-editor select[data-col=product]");
await until(() => [...prod.options].some((o) => o.dataset.stock !== undefined), "products with stock", jsErrors);
prod.selectedIndex = [...prod.options].findIndex((o) => o.dataset.stock !== undefined && o.dataset.kind !== "service");
prod.dispatchEvent(new w.Event("change", { bubbles: true }));
const qty = d.querySelector("#ops-main .rows-editor input[data-col=quantity]");
qty.value = "999999";
qty.dispatchEvent(new w.Event("input", { bubbles: true }));
ok(d.querySelector("#ops-main .rows-editor .row-status.warn").textContent.startsWith("saldo"), "saldo do depósito ao lado da linha, alerta quando falta");
d.querySelector("#ops-main .rows-editor input[data-col=price]").value = "1,50";
d.querySelector("#ops-main .rows-editor input[data-col=price]").dispatchEvent(new w.Event("input", { bubbles: true }));
ok(text("#ops-main .rows-foot").includes("1.499.998,50"), "total da grade com vírgula decimal");
[...d.querySelectorAll("#ops-main .rows-foot button")].find((b) => b.textContent.includes("Adicionar item")).click();
ok(d.querySelectorAll("#ops-main .rows-editor tbody tr").length === 2, "botão Adicionar item cria nova linha");
ok(JSON.parse(d.querySelector("#ops-main input[type=hidden][name=items]").value)[0].price === "1.50", "linhas viajam como lista de itens, decimal sem vírgula");

// Documents open from their row (spec 035): keyboard (Enter) and mouse. The customer has an invoiced order.
await rpc("sales.invoice_order", { number: (await rpc("sales.create_order", { customer: 1, items: [{ product: "FEIJAO-1", quantity: 1 }] })).number });
await go(w, "#/ops/files/files.my_invoices?customer=1");
await until(() => d.querySelector("#ops-main tr.row-open"), "invoice rows", jsErrors);
const invoiceRow = d.querySelector("#ops-main tr.row-open");
ok(invoiceRow.getAttribute("tabindex") === "0", "linha da fatura alcançável pelo teclado");
invoiceRow.dispatchEvent(new w.KeyboardEvent("keydown", { key: "Enter", bubbles: true }));
await until(() => location_hash(w).includes("docs.view") && text("#ops-main").includes("Título a receber"), "bill opened", jsErrors);
ok(text("#ops-main").includes("Vencimento"), "Enter na linha abre a fatura (CA-035-04)");
const opened = { href: null, closed: false };
w.open = () => ({ location: { set href(v) { opened.href = v; }, get href() { return opened.href; } }, close() { opened.closed = true; } });
[...d.querySelectorAll("#ops-main button")].find((b) => b.textContent === "PDF da fatura").click();
await until(() => opened.href || opened.closed, "pdf tab", jsErrors);
ok(opened.href && !opened.closed, "PDF da fatura abre numa aba com o endereço assinado do arquivo");

// Automated flows (spec 030): board with one column per step
await go(w, "#/ops/flows/flows.board?flow=sales");
await until(() => d.querySelectorAll("#ops-main .board-col").length === 4, "flow board", jsErrors);
ok(text("#ops-main").includes("Faturamento") && text("#ops-main").includes("Recebimento"), "esteira de venda em quadro por etapa");

// Date/time pickers beside date fields (no typing needed)
await go(w, "#/ops/field/field.schedule?_form=1");
await until(() => d.querySelector("#ops-main input[name=start]"), "datetime field", jsErrors);
ok(d.querySelector("#ops-main input[name=start]").type === "datetime-local" && d.querySelector("#ops-main .picker-wrap .picker-btn"),
   "campo data e hora com botão de calendário");
[...d.querySelectorAll("#ops-main .picker-btn")].find((b) => b.textContent === "agora").click();
ok(/^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}$/.test(d.querySelector("#ops-main input[name=start]").value), "botão agora preenche data e hora");

// Administration grouped (RF-020-06)
await go(w, "#/admin/users");
await until(() => d.querySelectorAll("#admin-main tbody tr").length > 0, "users", jsErrors);
ok([...d.querySelectorAll("#area-admin .nav-group")].map((g) => g.textContent).join("|") === "Pessoas e acesso|Sistema|Operação do sistema|Observabilidade", "administração em grupos (CA-020-03)");
d.querySelector("#admin-main tbody tr").click();
await until(() => text("#admin-main .form-card").includes("Cota de execução"), "user card", jsErrors);
ok(text("#admin-main .form-card").includes("Redefinir senha") && text("#admin-main .form-card").includes("Grupos"), "ficha do usuário reúne grupos, cota e acesso");
// Robots (RF-011-12, RF-011-16): built-in robot is protected; new robots get API keys.
{
  const find = d.querySelector("#admin-main .table-search");      // the table's own search (many users in a test database)
  find.value = "robo interno";
  find.dispatchEvent(new w.Event("input"));
  await until(() => [...d.querySelectorAll("#admin-main tbody tr")].some((r) => r.textContent.includes("robô interno")), "search robot", jsErrors);
}
[...d.querySelectorAll("#admin-main tbody tr")].find((r) => r.textContent.includes("robô interno")).click();
await until(() => text("#admin-main .form-card").includes("Robô interno"), "system robot card", jsErrors);
ok(!text("#admin-main .form-card").includes("Gerar chave") && !text("#admin-main .form-card").includes("Redefinir senha"),
   "robô interno sem chaves nem senha");
{
  const tk = (await (await fetch(ANA_URL + "/api/session", { method: "POST", headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ username: "admin", password: PASSWORD }) })).json()).token;
  const rname = "smokebot" + Date.now().toString().slice(-6);
  await fetch(ANA_URL + "/api/admin/users", { method: "POST", headers: { "Content-Type": "application/json", Authorization: "Bearer " + tk },
    body: JSON.stringify({ username: rname, kind: "robot", role: "user" }) });
  await go(w, "#/admin/audit");
  await go(w, "#/admin/users");
  await until(() => text("#admin-main .table-title") === "Usuários", "users table", jsErrors);
  const find = d.querySelector("#admin-main .table-search");
  find.value = rname;
  find.dispatchEvent(new w.Event("input"));
  await until(() => text("#admin-main tbody").includes(rname), "robot row", jsErrors);
  [...d.querySelectorAll("#admin-main tbody tr")].find((r) => r.textContent.includes(rname)).click();
  await until(() => text("#admin-main .form-card").includes("Gerar chave"), "robot card", jsErrors);
  ok(text("#admin-main .form-card").includes("Chaves de API"), "ficha do robô reúne as chaves de API");
  await fetch(`${ANA_URL}/api/admin/users/${rname}`, { method: "PUT", headers: { "Content-Type": "application/json", Authorization: "Bearer " + tk },
    body: JSON.stringify({ active: false }) });
}
[...d.querySelectorAll("#admin-main button")].find((b) => b.textContent === "+ Novo usuário").click();
await until(() => text("#admin-main .form-card").includes("Tipo"), "new user form", jsErrors);
ok([...d.querySelectorAll("#admin-main .form-card option")].some((o) => o.value === "robot"), "novo usuário pode ser pessoa ou robô");
for (const [section, marker] of [["groups", "Grupos de acesso"], ["limits", "Perfil de limite"], ["company", "Razão social"],
                                 ["settings", "ceiling_cpu_ms"], ["accounts", "service_revenue"], ["commands", "hello"],
                                 ["remote", "Sistemas remotos"], ["scheduler", "Feriados"], ["monitor", "Execuções ativas"], ["consumption", "CPU total"],
                                 ["retention", "Expurgos recentes"], ["health", "Mudanças de estado"], ["alerts", "Componente em falha"], ["core", "Áreas supervisionadas"], ["disk", "Resistência do SSD"], ["uiperf", "Desempenho das telas"], ["sqlperf", "Desempenho do SQL"],
                                 ["advice", "Dicas de otimização"], ["updates", "Atualizações do produto"], ["license", "Usuários nomeados"], ["extensions", "Ligar um programa seu"], ["telemetry", "Exatamente o que é enviado"], ["company", "Logotipo"], ["groups", "Dados que os membros veem"], ["integrations", "Chamadas 24 h"], ["audit", "Auditoria"]]) {
  await go(w, `#/admin/${section}`);
  await until(() => text("#admin-main").includes(marker), section, jsErrors);
  if (section === "groups" && marker === "Dados que os membros veem") {
    // RF-020-13: the data scope is simulated before saving.
    [...d.querySelectorAll("#admin-main .scope-sim button")].find((b) => b.textContent === "Simular").click();
    await until(() => text("#admin-main .scope-preview").includes("Pedidos de venda"), "scope preview", jsErrors);
    ok(text("#admin-main .scope-preview").includes("nada foi gravado"), "escopo de dados simulado antes de salvar o grupo");
  }
  if (section === "alerts") {
    // T-019-08b: a metric rule asks for comparison and threshold; a health rule asks for the level.
    const form = d.querySelector("#admin-main .form-card");
    const [source, target] = form.querySelectorAll("select");
    const visible = (label) => [...form.querySelectorAll("label")].some((l) => !l.hidden && l.textContent.startsWith(label));
    ok(visible("Nível") && !visible("Limiar"), "regra de saúde pede o nível");
    source.value = "metric"; source.dispatchEvent(new w.Event("change"));
    ok(!visible("Nível") && visible("Limiar") && [...target.options].some((o) => o.value === "memory_mb"),
       "regra de métrica pede comparação e limiar (T-019-08b)");
    ok(text("#admin-main").includes("Silêncios"), "silêncios ficam na mesma tela");
  }
  if (section === "license") {
    ok(text("#admin-main").includes("Núcleo") && text("#admin-main").includes("Instalar licença"),
       "licença mostra situação, módulos e instalação (spec 009)");
  }
  if (section === "integrations") {
    [...d.querySelectorAll("#admin-main .sub-tabs button")].find((b) => b.textContent === "Conectores").click();
    await until(() => text("#admin-main").includes("Segredos (só escrita)"), "connectors", jsErrors);
    // Spec 044: an e-mail (SMTP) connector shows its own fields instead of the HTTP ones.
    const kindSel = [...d.querySelectorAll("#admin-main .form-card select")].find((x) => [...x.options].some((o) => o.value === "smtp"));
    kindSel.value = "smtp"; kindSel.dispatchEvent(new w.Event("change"));
    const shown = (label) => [...d.querySelectorAll("#admin-main .form-card label")].some((l) => !l.hidden && l.textContent.startsWith(label));
    ok(shown("Servidor SMTP") && shown("Remetente") && !shown("URL base"), "conector de e-mail (SMTP) mostra os próprios campos (spec 044)");
    kindSel.value = "http_api"; kindSel.dispatchEvent(new w.Event("change"));
    [...d.querySelectorAll("#admin-main .sub-tabs button")].find((b) => b.textContent === "Saída").click();
    await until(() => text("#admin-main").includes("Último erro"), "outbox", jsErrors);
    ok(true, "integrações: painel, conectores com segredos só de escrita e mensagens (spec 017)");
  }
  if (section === "updates") {
    // Spec 028: an update row opens the side-by-side comparison (demo.hello is used by the integration suite).
    const view = [...d.querySelectorAll("#admin-main tbody button")][0];
    if (view) {
      view.click();
      await until(() => text("#admin-main").includes("Instalado × produto"), "product update detail", jsErrors);
      ok(true, "atualização do produto abre a comparação lado a lado (spec 028)");
    }
    const ops = w.AnaAdmin.lineDiff(["a", "b", "c", "d"], ["a", "x", "c", "d", "e"]).map((o) => o.t).join(",");
    ok(ops === "same,add,del,same,same,add" || ops === "same,del,add,same,same,add", "comparação linha a linha: " + ops);
  }
}
// CA-020-06 / CA-020-07: the order offers its next step and the sale shows its stages.
await w.AnaApi.run("base.save_product", { params: { code: "SMOKEGUIA", description: "Serviço do teste de fumaça", price: "1", kind: "service" } });
const created = await w.AnaApi.run("sales.create_order", { params: { customer: 3, items: [{ product: "SMOKEGUIA", quantity: 1, price: "5" }] } });
const nextStep = (created.events || []).filter((e) => e.kind === "actions").pop();
ok(nextStep && nextStep.data.items.some((a) => a.label === "Faturar este pedido" && String(a.params.number) === String(created.result.number)),
   "após criar o pedido: Faturar este pedido, com o número (CA-020-06)");
await go(w, `#/ops/flows/flows.guide?flow=sales&document=${created.result.number}`);
await until(() => d.querySelector("#area-ops .steps li[aria-current='step']"), "process stages", jsErrors);
ok(d.querySelector("#area-ops .steps li[aria-current='step']").textContent.includes("Faturamento"),
   "etapas da venda com a etapa atual destacada (CA-020-07)");
await go(w, "#/admin/audit");
await until(() => d.querySelector("#admin-main .sub-tabs"), "audit again", jsErrors);
// RF-020-19..22: routines by business area and category; pick two, copy them to a new category; it shows on Início.
await go(w, "#/ops");
await until(() => text("#ops-main").includes("Conciliação bancária") && d.querySelector("#ops-main .area-title"), "areas", jsErrors);
ok([...d.querySelectorAll("#ops-main .area-title")].some((h) => h.textContent === "Financeiro")
   && ![...d.querySelectorAll("#ops-main .tile-sub")].some((t) => /^(bpm|master)\b/.test(t.textContent)),
   "Operação por área do negócio e categoria, sem nome técnico (CA-020-13)");
const picks = [...d.querySelectorAll("#ops-main .tile-pick input")].slice(0, 2);
for (const p of picks) { p.checked = true; p.dispatchEvent(new w.Event("change", { bubbles: true })); }
await until(() => text("#ops-main .pick-bar").includes("2 selecionada(s)"), "pick bar", jsErrors);
[...d.querySelectorAll("#ops-main .pick-bar button")].find((b) => b.textContent.startsWith("Copiar")).click();
await until(() => d.querySelector(".cat-dialog"), "copy dialog", jsErrors);
const catName = "Fumaça " + Date.now().toString(36);
const fresh = d.querySelector('.cat-dialog input[value="new"]');
fresh.checked = true; fresh.dispatchEvent(new w.Event("change", { bubbles: true }));
d.querySelector('.cat-dialog .cat-new input[aria-label="Nome da nova categoria"]').value = catName;
[...d.querySelectorAll(".cat-dialog button")].find((b) => b.textContent === "Copiar").click();
await until(() => !d.querySelector(".cat-dialog") && text("#ops-main .cat-sections").includes(catName), "category made", jsErrors);
ok(d.querySelectorAll("#ops-main .cat-sections .cat-group .tile").length >= 2, "duas rotinas copiadas para a categoria nova (CA-020-14)");
await go(w, "#/home");
await until(() => text("#area-home").includes(catName), "category on home", jsErrors);
ok(true, "categoria aparece no Início com os atalhos (RF-020-22)");
const made = (await w.AnaApi.categories()).find((c) => c.name === catName);
if (made) await w.AnaApi.deleteCategory(made.id);

// T-017-05b: statement sources per bank account (folder of OFX/CNAB 240 files or bank API).
await go(w, "#/ops/finance/finance.statement_sources?active=true");   // with a parameter the routine runs
await until(() => text("#area-ops").includes("Usar pasta de arquivos"), "statement sources", jsErrors);
ok(text("#area-ops").includes("Usar pasta de arquivos") && text("#area-ops").includes("Usar API do banco"),
   "fontes de extrato: pasta de arquivos ou API do banco, por conta");
await go(w, "#/admin/audit");
await until(() => d.querySelector("#admin-main .sub-tabs"), "audit (after sources)", jsErrors);
// RF-020-09 (T-020-07): tabs are tabs for screen readers and the keyboard; every field has a name.
await until(() => [...d.querySelectorAll("#admin-main .sub-tabs button")].every((b) => b.getAttribute("role") === "tab"), "a11y tab roles", jsErrors);
const selectedTabs = () => [...d.querySelectorAll("#admin-main .sub-tabs button")].filter((b) => b.getAttribute("aria-selected") === "true");
ok(selectedTabs().length === 1 && d.querySelector("#admin-main .sub-tabs").getAttribute("role") === "tablist",
   "abas com papéis e uma só selecionada (teclado e leitor de tela)");
const firstTab = selectedTabs()[0].textContent;
selectedTabs()[0].dispatchEvent(new w.KeyboardEvent("keydown", { key: "ArrowRight", bubbles: true }));
await until(() => selectedTabs().length === 1 && selectedTabs()[0].textContent !== firstTab, "arrow moves tab", jsErrors);
ok(true, "seta para a direita leva à próxima aba: " + selectedTabs()[0].textContent);
const unnamed = [...d.querySelectorAll("#admin-main input:not([type=hidden]), #admin-main select, #admin-main textarea")]
  .filter((f) => !(f.labels && f.labels.length) && !f.getAttribute("aria-label") && !f.getAttribute("aria-labelledby"));
ok(unnamed.length === 0, "todo campo tem nome acessível" + (unnamed.length ? ": " + unnamed.map((f) => f.outerHTML.slice(0, 60)).join(" | ") : ""));
ok(d.querySelector("#skip-link") && d.querySelector("#skip-link").textContent.includes("Pular"), "atalho para pular ao conteúdo");
[...d.querySelectorAll("#admin-main .sub-tabs button")].find((b) => b.textContent === "Tarefas internas").click();
// Filtered by prefix: on a busy instance the latest 100 tasks may all be periodic ones.
await until(() => d.querySelector('#admin-main input[placeholder="Tarefa (prefixo)"]'), "internal tasks filter", jsErrors);
d.querySelector('#admin-main input[placeholder="Tarefa (prefixo)"]').value = "seed.";
[...d.querySelectorAll("#admin-main button")].find((b) => b.textContent === "Filtrar").click();
await until(() => text("#admin-main tbody").includes("seed.programs"), "internal tasks", jsErrors);
ok(text("#admin-main tbody").includes("system"), "tarefas internas têm dono (P14)");
[...d.querySelectorAll("#admin-main .sub-tabs button")].find((b) => b.textContent === "Requisições").click();
await until(() => text("#admin-main tbody").includes("/api/"), "access log", jsErrors, 30000);   // busy right after the integration suites
ok(true, "auditoria mostra as requisições (spec 024)");
[...d.querySelectorAll("#admin-main .sub-tabs button")].find((b) => b.textContent === "Execuções").click();
await until(() => d.querySelectorAll("#admin-main tbody tr.clickable").length > 0, "executions", jsErrors);
d.querySelector("#admin-main tbody tr.clickable").click();
await until(() => text("#admin-main").includes("Comandos SQL"), "execution detail", jsErrors);
ok(text("#admin-main").includes("CPU") && text("#admin-main").includes("Nó"), "detalhe da execução com consumo e origem (RF-024-07)");
await go(w, "#/admin/users");
await until(() => d.querySelectorAll("#admin-main tbody tr").length > 0, "users again", jsErrors);
// The admin's own trail (it surely has accesses); test users created by other suites may have none.
([...d.querySelectorAll("#admin-main tbody tr")].find((tr) => tr.cells[0] && tr.cells[0].textContent.trim() === "admin")
  || d.querySelector("#admin-main tbody tr")).click();
await until(() => [...d.querySelectorAll("#admin-main button")].some((b) => b.textContent === "Ver trilha"), "trail button", jsErrors);
[...d.querySelectorAll("#admin-main button")].find((b) => b.textContent === "Ver trilha").click();
await until(() => text("#admin-main tbody").includes("requisição"), "trail", jsErrors);
ok(true, "ficha do usuário abre a trilha completa (RF-024-06)");
await go(w, "#/admin/retention");
await until(() => text("#admin-main").includes("Alterações administrativas"), "retention", jsErrors);
ok(d.querySelectorAll("#admin-main .num-input").length >= 7, "retenção editável por categoria (RF-024-08)");
await go(w, "#/admin/checks");
await until(() => d.querySelectorAll("#admin-main .check-card").length === 5, "checks", jsErrors);
ok(text("#admin-main .check-grid").includes("Segurança") && text("#admin-main .check-grid").includes("Desempenho"),
   "verificações por categoria com Verificar agora (spec 033)");
[...d.querySelectorAll("#admin-main .sub-tabs button")].find((b) => b.textContent.startsWith("Inventário")).click();
await until(() => d.querySelector("#admin-main input[type=file]") && d.querySelector("#admin-main table"), "inventory", jsErrors);
ok(text("#admin-main table").includes("Componente") && text("#admin-main").includes("Base de vulnerabilidades (OSV)"), "inventário e envio da base OSV");
ok(text("#instance-band") === "DESENVOLVIMENTO" && !d.querySelector("#instance-band").hidden, "faixa da instância de desenvolvimento (spec 034)");
await go(w, "#/admin/transports");
await until(() => text("#admin-main").includes("Montar pacote"), "transports", jsErrors);
[...d.querySelectorAll("#admin-main .sub-tabs button")].find((b) => b.textContent === "Chave e origens").click();
await until(() => text("#admin-main").includes("Chave pública"), "transport key", jsErrors);
ok(text("#admin-main").includes("Origens aceitas aqui"), "transportes: chave da instância e origens");
[...d.querySelectorAll("#admin-main .sub-tabs button")].find((b) => b.textContent === "Montar pacote").click();
await until(() => d.querySelectorAll("#admin-main .pick-list input[type=checkbox]").length > 5, "transport send", jsErrors);
ok(true, "transportes: montar pacote com escolha de programas");
// Spec 065: company values — grouped by area, what is in effect today, the timeline and the change form.
await go(w, "#/admin/values");
await until(() => text("#admin-main").includes("financeiro.periodo_aberto"), "company values", jsErrors);
[...d.querySelectorAll("#admin-main tbody tr")].find((tr) => tr.textContent.includes("financeiro.periodo_aberto")).click();
await until(() => text("#admin-main").includes("Linha do tempo"), "value timeline", jsErrors);
ok(/\d{2}\/\d{4}/.test(text("#admin-main .value-big")) && text("#admin-main").includes("Mês atual") && text("#admin-main").includes("Mudar o valor"),
   "valores da empresa: vigente hoje, linha do tempo e mudança com vigência (spec 065)");
await go(w, "#/admin/datacopy");
await until(() => text("#admin-main").includes("Exportar dados mascarados"), "datacopy", jsErrors);
[...d.querySelectorAll("#admin-main .sub-tabs button")].find((b) => b.textContent === "Máscaras").click();
await until(() => text("#admin-main").includes("base.party"), "masking", jsErrors);
ok(true, "cópia de dados: exportar, receber e catálogo de máscaras");
// Processes (spec 039): the map, a process diagram (SVG, no library), tasks and simulation.
await go(w, "#/bpm");
await until(() => text("#bpm-main").includes("Mapa de processos") && d.querySelectorAll("#bpm-main .bpm-card").length >= 4, "bpm map", jsErrors);
ok(text("#bpm-main").includes("Venda"), "Processos: mapa com as esteiras como processos (spec 039)");
await go(w, "#/bpm/p/esteira.sales");
await until(() => d.querySelectorAll("#bpm-main svg [data-node]").length >= 5, "bpm diagram", jsErrors);
ok(d.querySelector("#bpm-main [data-node=invoice]") && d.querySelector("#bpm-main .bpm-panel"), "diagrama desenhado em SVG com painel de propriedades");
d.querySelector("#bpm-main [data-node=invoice]").dispatchEvent(new w.Event("pointerdown", { bubbles: true }));
await until(() => text("#bpm-main .bpm-panel").includes("Faturamento"), "bpm select", jsErrors);
ok(true, "selecionar um elemento mostra as propriedades");
[...d.querySelectorAll("#bpm-main .sub-tabs button")].find((b) => b.textContent === "Simulação").click();
await until(() => text("#bpm-main").includes("Calibrar pela realidade"), "bpm simulation", jsErrors);
ok(true, "aba de simulação com parâmetros e calibração");
await go(w, "#/bpm/tasks");
await until(() => text("#bpm-main").includes("Minhas tarefas"), "bpm tasks", jsErrors);
ok(true, "Minhas tarefas abre");
// Master data (spec 040): the same list and sheet for every entity.
await go(w, "#/master/party");
await until(() => d.querySelectorAll("#master-main .md-list tbody tr").length > 0, "master list", jsErrors);
ok(text("#master-nav").includes("Clientes e fornecedores") && text("#master-nav").includes("Qualidade dos cadastros"), "Cadastros: menu por grupos (spec 040)");
d.querySelector("#master-main .md-list tbody tr").click();
await until(() => d.querySelector("#master-main .sub-tabs") && text("#master-main").includes("Histórico"), "master sheet", jsErrors);
ok(d.querySelector("#master-main .md-actions button.primary").disabled, "ficha abre com Salvar desabilitado até alterar algo");
[...d.querySelectorAll("#master-main .sub-tabs button")].find((b) => b.textContent === "Histórico").click();
await until(() => text("#master-main").includes("Sem alterações registradas") || text("#master-main").includes("Antes"), "master history", jsErrors);
ok(true, "ficha com abas e histórico");
// T-040-11b: the menu's master-data routines open the standard sheet (on the tab that routine writes).
{
  const code = (await w.AnaApi.run("master.search", { params: { entity: "product", limit: 1 } })).result.rows[0].key;
  await go(w, `#/ops/base/base.save_product?code=${encodeURIComponent(code)}`);
  await until(() => w.location.hash.startsWith(`#/master/product/${encodeURIComponent(code)}`) && d.querySelector("#master-main .sub-tabs"), "routine → sheet", jsErrors);
  ok(true, "rotina de cadastro do menu abre a ficha padrão do registro");
  await go(w, `#/ops/supply/supply.save_supplier_item?product=${encodeURIComponent(code)}`);
  await until(() => w.location.hash.includes("aba=Fornecimento") && [...d.querySelectorAll("#master-main .sub-tabs button.active")].some((b) => b.textContent === "Fornecimento"),
              "routine → sheet tab", jsErrors);
  ok(true, "rotina de uma aba abre a ficha já nessa aba");
  await go(w, "#/ops/base/base.save_product?_rotina=1");
  await until(() => d.querySelector("#ops-main form [name=code]"), "classic routine form", jsErrors);
  ok(w.location.hash.startsWith("#/ops/"), "com _rotina=1 a rotina mantém o próprio formulário");
}
await go(w, "#/master/product/novo");
await until(() => text("#master-main").includes("Novo: item"), "master new", jsErrors);
d.querySelector("#master-main .md-actions button.primary").click();
await until(() => text("#master-main").includes("Corrija os campos destacados"), "master validation", jsErrors);
ok(d.querySelectorAll("#master-main .md-field.invalid").length >= 2, "campos obrigatórios destacados antes de enviar");
await go(w, "#/master/_quality");
await until(() => text("#master-main").includes("pendência") || text("#master-main").includes("Nenhuma pendência"), "master quality", jsErrors);
ok(true, "painel de qualidade dos cadastros");
await go(w, "#/admin/publicapi");
await until(() => text("#admin-main").includes("Chaves de assinatura dos tokens"), "public api", jsErrors);
[...d.querySelectorAll("#admin-main .sub-tabs button")].find((b) => b.textContent === "Novo cliente").click();
await until(() => text("#admin-main").includes("Executa como (robô)"), "public api new", jsErrors);
[...d.querySelectorAll("#admin-main .sub-tabs button")].find((b) => b.textContent === "Chamadas").click();
await until(() => d.querySelector("#admin-main table"), "public api calls", jsErrors);
ok(true, "API pública: clientes, novo cliente e chamadas (spec 010)");
// ---------------------------------------------------------------- spec 050, phase 2: palette, undo, confirmation, context, camera
{
  const key = (k, extra = {}) => d.dispatchEvent(new w.KeyboardEvent("keydown", { key: k, bubbles: true, cancelable: true, ...extra }));
  const typeIn = (input, v) => { input.value = v; input.dispatchEvent(new w.Event("input", { bubbles: true })); };
  const items = () => [...d.querySelectorAll(".palette-dialog .palette-item")];
  const cnpjOf = (base12) => {
    const dg = [...base12].map(Number);
    const wt = [6, 5, 4, 3, 2, 9, 8, 7, 6, 5, 4, 3, 2];
    for (const n of [12, 13]) { let r = 0; for (let i = 0; i < n; i++) r += dg[i] * wt[i + 13 - n]; r %= 11; dg.push(r < 2 ? 0 : 11 - r); }
    const t = dg.join("");
    return `${t.slice(0, 2)}.${t.slice(2, 5)}.${t.slice(5, 8)}/${t.slice(8, 12)}-${t.slice(12)}`;
  };
  const stamp = Date.now().toString().slice(-8);
  const taxId = cnpjOf(stamp + "0001");
  const party = (await rpc("base.save_party", { name: `Cliente Paleta ${stamp}`, state: "SP", tax_id: taxId })).id;
  await rpc("finance.save_credit_profile", { customer: party, default_term: "D30" });
  const num = (await rpc("sales.create_order", { customer: 1, items: [{ product: "FEIJAO-1", quantity: 1 }] })).number;

  // CA-050-02: a routine, an order by its number and a customer by CNPJ, and the chosen one is opened.
  await go(w, "#/home");
  await until(() => !d.querySelector("#area-home").hidden && d.querySelector("#area-ops").hidden, "home shown", jsErrors);
  key("k", { ctrlKey: true });
  await until(() => d.querySelector(".palette-dialog .palette-input"), "palette", jsErrors);
  const pin = d.querySelector(".palette-dialog .palette-input");
  typeIn(pin, "fatura pedido baixa");
  await until(() => items().some((i) => i.textContent.startsWith("Fatura pedido")), "palette routine", jsErrors);
  pin.dispatchEvent(new w.KeyboardEvent("keydown", { key: "Enter", bubbles: true, cancelable: true }));
  await until(() => w.location.hash.startsWith("#/ops/sales/sales.invoice_order") && !d.querySelector(".palette-dialog"), "palette opens routine", jsErrors);
  ok(true, "Ctrl+K acha a rotina pelo nome e abre (CA-050-02)");
  // The screen really changed (a form left by an earlier visit to this routine does not count).
  await until(() => !d.querySelector("#area-ops").hidden && d.querySelector("#area-home").hidden && d.querySelector("#ops-main .run-button"),
              "routine screen shown (toast: " + text("#toast") + ")", jsErrors);
  key("k", { ctrlKey: true });
  await until(() => d.querySelector(".palette-dialog"), "palette 2", jsErrors);
  typeIn(d.querySelector(".palette-dialog .palette-input"), "executar");
  ok([...d.querySelectorAll(".palette-dialog .palette-group")].some((g) => g.textContent === "Nesta tela") &&
     items().some((i) => i.textContent.includes("Executar (F8)")), "a paleta traz as ações da tela aberta" +
     ` (tela ${w.location.hash}; vistas: ${JSON.stringify(w.AnaPalette.screenActions().map((a) => a.label).slice(0, 25))}; ` +
     `botão: ${(d.querySelector("#ops-main .run-button") || {}).textContent}, desabilitado ${!!(d.querySelector("#ops-main .run-button") || {}).disabled}; ` +
     `áreas visíveis: ${[...d.querySelectorAll(".area-page")].filter((a) => !a.hidden).map((a) => a.id)}; ` +
     `oculto acima do botão: ${((d.querySelector("#ops-main .run-button") || { closest: () => null }).closest("[hidden], dialog:not([open])") || {}).outerHTML?.slice(0, 120)})`);
  typeIn(d.querySelector(".palette-dialog .palette-input"), String(num));
  await until(() => items().some((i) => i.textContent.startsWith(`Pedido de venda ${num}`)), "palette order", jsErrors);
  items().find((i) => i.textContent.startsWith(`Pedido de venda ${num}`)).click();
  await until(() => w.location.hash.includes(`docs.view?kind=order&key=${num}`) && text("#ops-main").includes(String(num)), "palette opens order", jsErrors);
  ok(true, "Ctrl+K acha o pedido pelo número e abre o documento (CA-050-02)");
  key("k", { metaKey: true });
  await until(() => d.querySelector(".palette-dialog"), "palette 3", jsErrors);
  typeIn(d.querySelector(".palette-dialog .palette-input"), taxId.replace(/\D/g, ""));
  await until(() => items().some((i) => i.textContent.includes(`Cliente Paleta ${stamp}`)), "palette cnpj", jsErrors);
  d.querySelector(".palette-dialog .palette-input").dispatchEvent(new w.KeyboardEvent("keydown", { key: "Enter", bubbles: true, cancelable: true }));
  await until(() => w.location.hash === `#/master/party/${party}`, "palette opens customer", jsErrors);
  ok(true, "Ctrl+K acha o cliente pelo CNPJ (sem pontuação) e abre o cadastro (CA-050-02)");

  // RF-050-04: "?" lists the shortcuts, the global ones and the screen's.
  await go(w, "#/ops/sales/sales.create_order?_form=1");
  await until(() => d.querySelector("#ops-main select[name=customer]"), "order form", jsErrors);
  key("?");
  await until(() => d.querySelector(".shortcuts-dialog"), "shortcuts", jsErrors);
  const sc = d.querySelector(".shortcuts-dialog").textContent;
  ok(sc.includes("Ctrl+K") && sc.includes("Nesta tela") && sc.includes("Salvar (F8)") && sc.includes("Simular (F9)"),
     "? lista os atalhos globais e os da tela");
  [...d.querySelectorAll(".shortcuts-dialog button")].find((b) => b.textContent === "Fechar").click();
  await until(() => !d.querySelector(".shortcuts-dialog"), "shortcuts closed", jsErrors);

  // T-050-07 (D6): the customer brings its payment term.
  const cust = d.querySelector("#ops-main select[name=customer]");
  if (![...cust.options].some((o) => o.value === String(party))) cust.append(new w.Option(`Cliente Paleta ${stamp}`, String(party)));
  cust.value = String(party);
  cust.dispatchEvent(new w.Event("change", { bubbles: true }));
  await until(() => d.querySelector("#ops-main select[name=payment_term]").value === "D30", "payment term from customer", jsErrors);
  ok(true, "pedido: a condição de pagamento vem do cliente escolhido (RF-050-06)");

  // CA-050-03: cancelling shows "Desfazer"; undoing reopens the order.
  await w.AnaApi.run("sales.cancel_order", { params: { number: num } });
  await until(() => d.querySelector("#undo-bar .undo-button"), "undo bar", jsErrors);
  ok(text("#undo-bar").includes(`Pedido ${num} cancelado`), "cancelar o pedido mostra Desfazer (CA-050-03)");
  d.querySelector("#undo-bar .undo-button").click();
  await until(() => text("#toast").includes("Desfeito") && !d.querySelector("#undo-bar"), "undone", jsErrors);
  const again = await w.AnaApi.run("sales.reopen_order", { params: { number: num } });
  ok(again.error && again.error.code === "ORDER_NOT_CANCELLED", "desfazer reabriu o pedido (CA-050-03)");

  // D5: an irreversible routine says its consequence and asks; "Voltar" runs nothing.
  await go(w, "#/ops/inventory/inventory.write_off?quantity=1");
  await until(() => d.querySelector(".confirm-dialog"), "confirm dialog", jsErrors);
  ok(text(".confirm-dialog").includes("Não há desfazer"), "rotina irreversível pede confirmação dizendo a consequência");
  [...d.querySelectorAll(".confirm-dialog button")].find((b) => b.textContent === "Voltar").click();
  await until(() => !d.querySelector(".confirm-dialog"), "confirm closed", jsErrors);
  await sleep(200);
  ok(!text("#ops-main").includes("Executando"), "Voltar não executa a rotina");

  // RF-050-08: the camera reads the code into the field (a reader stands in for the camera here).
  w.BarcodeDetector = class { async detect() { return [{ rawValue: String(num) }]; } };
  Object.defineProperty(w.navigator, "mediaDevices", { configurable: true,
    value: { getUserMedia: async () => ({ getTracks: () => [{ stop() {} }] }) } });
  await go(w, "#/ops/docs/docs.view?_form=1");
  await until(() => d.querySelector("#ops-main .scan-btn"), "scan button", jsErrors);
  d.querySelector("#ops-main .scan-btn").click();
  await until(() => d.querySelector("#ops-main input[name=key]").value === String(num) && !d.querySelector(".scan-dialog"), "scanned", jsErrors);
  ok(true, "câmera lê o código e preenche o campo (RF-050-08)");
  delete w.BarcodeDetector;
}
ok(true, "todas as seções administrativas abrem");
ok(jsErrors.length === 0, "nenhum erro de JavaScript (admin)" + (jsErrors.length ? ": " + jsErrors.join("; ") : ""));
w.close();

// ---------------------------------------------------------------- plain user (CA-020-01)
const token = (await (await fetch(ANA_URL + "/api/session", { method: "POST", headers: { "Content-Type": "application/json" },
  body: JSON.stringify({ username: "admin", password: PASSWORD }) })).json()).token;
const uname = "op" + Date.now().toString().slice(-7);
await fetch(ANA_URL + "/api/admin/users", { method: "POST", headers: { "Content-Type": "application/json", Authorization: "Bearer " + token },
  body: JSON.stringify({ username: uname, password: "Operator-pass-1", role: "user", must_change_password: false }) });
const u = await open(uname, "Operator-pass-1");
const utext = (s) => (u.d.querySelector(s) || {}).textContent || "";
await until(() => utext("#area-home").includes("Favoritas"), "user home", u.jsErrors);
ok([...u.d.querySelectorAll(".area")].filter((b) => !b.hidden).map((b) => b.dataset.area).join(",") === "home,ops,bpm,master,files", "usuário vê Início, Operação, Processos, Cadastros e Arquivos");
u.w.location.hash = "#/dev";
await sleep(300);
ok(!u.d.querySelector("#area-home").hidden, "acesso direto a #/dev volta ao Início");
u.w.location.hash = "#/ops";
await until(() => utext("#ops-nav").includes("Vendas"), "user ops", u.jsErrors);
ok(!utext("#ops-nav").includes("Utilidades"), "bibliotecas não aparecem como rotinas");
u.w.location.hash = "#/files";
await until(() => utext("#area-files").includes("Arraste arquivos"), "user files", u.jsErrors);
ok(true, "área Arquivos abre para o usuário (spec 016)");
ok(u.jsErrors.length === 0, "nenhum erro de JavaScript (usuário)");
await fetch(`${ANA_URL}/api/admin/users/${uname}`, { method: "PUT", headers: { "Content-Type": "application/json", Authorization: "Bearer " + token },
  body: JSON.stringify({ active: false }) });
u.w.close();

// ---------------------------------------------------------------- external portal account (spec 016)
const auth = { "Content-Type": "application/json", Authorization: "Bearer " + token };
const sql = await (await fetch(ANA_URL + "/api/sql", { method: "POST", headers: auth,
  body: JSON.stringify({ sql: "SELECT id FROM base.party WHERE active ORDER BY id LIMIT 1" }) })).json();
const xname = "ex" + Date.now().toString().slice(-7);
await fetch(ANA_URL + "/api/admin/users", { method: "POST", headers: auth,
  body: JSON.stringify({ username: xname, password: "Portal-pass-1", role: "external", party_id: sql.rows[0][0] }) });
const xt = (await (await fetch(ANA_URL + "/api/session", { method: "POST", headers: { "Content-Type": "application/json" },
  body: JSON.stringify({ username: xname, password: "Portal-pass-1" }) })).json()).token;
await fetch(ANA_URL + "/api/me/password", { method: "POST", headers: { "Content-Type": "application/json", Authorization: "Bearer " + xt },
  body: JSON.stringify({ current: "Portal-pass-1", new: "Portal-pass-2" }) });
const x = await open(xname, "Portal-pass-2");
const xtext = (s) => (x.d.querySelector(s) || {}).textContent || "";
await until(() => xtext("#area-portal").includes("Consultas liberadas"), "portal", x.jsErrors);
ok([...x.d.querySelectorAll(".area")].filter((b) => !b.hidden).map((b) => b.dataset.area).join(",") === "files,portal",
   "conta externa vê só Arquivos e Portal");
[...x.d.querySelectorAll("#portal-main button")].find((b) => b.textContent.startsWith("Minhas faturas")).click();
await until(() => [...x.d.querySelectorAll("#portal-main h3, #portal-main .table-title, #portal-main caption")]
  .some((n) => n.textContent.includes("Faturas")) || xtext("#portal-main .output").includes("Faturas"), "my invoices", x.jsErrors);
ok(true, "portal executa Minhas faturas");
ok([...x.d.querySelectorAll("#portal-main button")].some((b) => b.textContent.startsWith("Aprovações do cliente")),
   "portal oferece as aprovações do cliente (T-021-11)");
x.w.location.hash = "#/dev";
await sleep(300);
ok(!x.d.querySelector("#area-portal").hidden, "conta externa não entra no Desenvolvimento");
ok(x.jsErrors.length === 0, "nenhum erro de JavaScript (portal)" + (x.jsErrors.length ? ": " + x.jsErrors.join("; ") : ""));
await fetch(`${ANA_URL}/api/admin/users/${xname}`, { method: "PUT", headers: auth, body: JSON.stringify({ active: false }) });
x.w.close();
// ---------------------------------------------------------------- premium experience (spec 050)
const ux = verifier.finish();
if (ux.written !== undefined) console.log(`linha de base da experiência gravada: ${ux.written} violação(ões) conhecidas`);
if (ux.fixed.length) console.log(`✔ ${ux.fixed.length} violação(ões) da linha de base já corrigida(s): rode com UX_BASELINE=write para atualizá-la`);
ok(ux.fresh.length === 0, "nenhuma tela nova quebra o padrão de experiência (spec 050)" +
   (ux.fresh.length ? ":\n  " + ux.fresh.join("\n  ") : ""));
process.exit(0);

function location_hash(win) { return win.location.hash; }

