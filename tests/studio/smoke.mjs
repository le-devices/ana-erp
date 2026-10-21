// Studio smoke test (specs 005, 011, 012, 020): loads the real page in a DOM
// (jsdom), runs the scripts served by ANA and walks through the areas.
// Run: docker run --rm --network host -v $PWD/tests/studio:/t -w /t node:22-alpine \
//      sh -c "npm i --silent --no-save jsdom@24 && node smoke.mjs"
import { JSDOM, VirtualConsole } from "jsdom";

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
async function until(cond, label, errs = [], ms = 15000) {
  const end = Date.now() + ms;
  while (Date.now() < end) { if (cond()) return; await sleep(50); }
  throw new Error("timed out waiting for: " + label + "\nJS errors: " + errs.join("\n"));
}
const ok = (c, m) => { if (!c) throw new Error("failed: " + m); console.log("✔", m); };
const submit = (w, form) => form.dispatchEvent(new w.Event("submit", { cancelable: true }));
const go = async (w, hash) => { w.location.hash = hash; await sleep(50); };

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
await go(w, "#/ops/projects/projects.workspace?project=PRJ-001&view=board");
await until(() => d.querySelectorAll("#ops-main .board-card").length > 0, "board again", jsErrors);
ok([...d.querySelectorAll("#ops-main .output-tabs button")].map((b) => b.textContent).includes("Viabilidade"), "abas do projeto, incluindo Viabilidade");
[...d.querySelectorAll("#ops-main .board-card button")].find((b) => b.textContent === "Andamento").click();
await until(() => d.querySelector("#ops-main .inline-form"), "inline form", jsErrors);
ok(d.querySelector("#ops-main .inline-form input"), "ação abre formulário na própria tela (CA-021-06)");
[...d.querySelectorAll("#ops-main .output-tabs button")].find((b) => b.textContent === "Linha do tempo").click();
await until(() => d.querySelectorAll("#ops-main .gantt-bar").length > 0, "gantt", jsErrors);
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

// Documents open from their row (spec 035): keyboard (Enter) and mouse
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
                                 ["retention", "Expurgos recentes"], ["health", "Mudanças de estado"], ["sqlperf", "Desempenho do SQL"],
                                 ["advice", "Dicas de otimização"], ["updates", "Atualizações do produto"], ["license", "Usuários nomeados"], ["extensions", "Ligar um programa seu"], ["telemetry", "Exatamente o que é enviado"], ["company", "Logotipo"], ["groups", "Dados que os membros veem"], ["integrations", "Chamadas 24 h"], ["audit", "Auditoria"]]) {
  await go(w, `#/admin/${section}`);
  await until(() => text("#admin-main").includes(marker), section, jsErrors);
  if (section === "license") {
    ok(text("#admin-main").includes("Núcleo") && text("#admin-main").includes("Instalar licença"),
       "licença mostra situação, módulos e instalação (spec 009)");
  }
  if (section === "integrations") {
    [...d.querySelectorAll("#admin-main .sub-tabs button")].find((b) => b.textContent === "Conectores").click();
    await until(() => text("#admin-main").includes("Segredos (só escrita)"), "connectors", jsErrors);
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
await until(() => text("#admin-main tbody").includes("/api/"), "access log", jsErrors);
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
process.exit(0);

function location_hash(win) { return win.location.hash; }
