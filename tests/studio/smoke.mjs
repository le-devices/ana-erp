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
await until(() => text("#area-home").includes("Favoritos"), "home");
ok(!d.querySelector("#area-home").hidden, "Início é a área inicial");
ok(d.querySelectorAll(".area:not([hidden])").length === 4, "admin vê as quatro áreas");

// Operation: routine with form, result and history together (RF-020-03)
await go(w, "#/ops/demo/demo.hello");
await until(() => text("#ops-main").includes("Parâmetros") && d.querySelector("#ops-main form"), "routine page", jsErrors);
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

// Development: program tabs (RF-020-04)
await go(w, "#/dev/program/demo.hello");
await until(() => text("#program-name") === "demo.hello", "program", jsErrors);
ok(d.querySelector("#editor textarea").value.includes("def main"), "código no editor");
ok([...d.querySelectorAll("[data-ptab]")].map((b) => b.textContent).join("|") === "Código|Propriedades e limites|Versões|Execuções|Agendamentos", "abas do programa");
ok([...d.querySelectorAll("[data-panel]")].map((b) => b.textContent).join("|") === "Saída|Resultado", "painel inferior só com Saída e Resultado (CA-020-02)");
d.querySelector('[data-ptab="props"]').click();
await until(() => d.querySelectorAll("#limits-box input").length === 10, "limits", jsErrors);
await until(() => text("#program-commands").includes("hello"), "commands", jsErrors);
ok(text("#ptab-props").includes("Comandos") && text("#program-commands").includes("hello"), "propriedades, comandos e limites juntos");
d.querySelector('[data-ptab="versions"]').click();
await until(() => text("#version-list").includes("v1"), "versions", jsErrors);
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

// Consulting project in tabs (spec 021): address with parameters runs the routine (RF-020-12)
await go(w, "#/ops/projects/projects.workspace?project=PRJ-001&view=board");
await until(() => d.querySelectorAll("#ops-main .board-card").length > 0, "board", jsErrors);
ok(d.querySelectorAll("#ops-main .board-col").length === 5, "quadro com as cinco colunas do fluxo (RF-021-04)");
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

// Administration grouped (RF-020-06)
await go(w, "#/admin/users");
await until(() => d.querySelectorAll("#admin-main tbody tr").length > 0, "users", jsErrors);
ok([...d.querySelectorAll("#area-admin .nav-group")].map((g) => g.textContent).join("|") === "Pessoas e acesso|Sistema|Operação do sistema", "administração em três grupos (CA-020-03)");
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
                                 ["retention", "Expurgos recentes"], ["audit", "Auditoria"]]) {
  await go(w, `#/admin/${section}`);
  await until(() => text("#admin-main").includes(marker), section, jsErrors);
}
[...d.querySelectorAll("#admin-main .sub-tabs button")].find((b) => b.textContent === "Tarefas internas").click();
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
d.querySelector("#admin-main tbody tr").click();
await until(() => [...d.querySelectorAll("#admin-main button")].some((b) => b.textContent === "Ver trilha"), "trail button", jsErrors);
[...d.querySelectorAll("#admin-main button")].find((b) => b.textContent === "Ver trilha").click();
await until(() => text("#admin-main tbody").includes("requisição"), "trail", jsErrors);
ok(true, "ficha do usuário abre a trilha completa (RF-024-06)");
await go(w, "#/admin/retention");
await until(() => text("#admin-main").includes("Alterações administrativas"), "retention", jsErrors);
ok(d.querySelectorAll("#admin-main .num-input").length >= 7, "retenção editável por categoria (RF-024-08)");
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
await until(() => utext("#area-home").includes("Favoritos"), "user home", u.jsErrors);
ok([...u.d.querySelectorAll(".area")].filter((b) => !b.hidden).map((b) => b.dataset.area).join(",") === "home,ops", "usuário vê só Início e Operação");
u.w.location.hash = "#/dev";
await sleep(300);
ok(!u.d.querySelector("#area-home").hidden, "acesso direto a #/dev volta ao Início");
u.w.location.hash = "#/ops";
await until(() => utext("#ops-nav").includes("Vendas"), "user ops", u.jsErrors);
ok(!utext("#ops-nav").includes("Utilidades"), "bibliotecas não aparecem como rotinas");
ok(u.jsErrors.length === 0, "nenhum erro de JavaScript (usuário)");
await fetch(`${ANA_URL}/api/admin/users/${uname}`, { method: "PUT", headers: { "Content-Type": "application/json", Authorization: "Bearer " + token },
  body: JSON.stringify({ active: false }) });
u.w.close();
process.exit(0);

function location_hash(win) { return win.location.hash; }
