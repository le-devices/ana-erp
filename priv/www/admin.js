// Administration area (spec 011): users, groups, settings, company, commands,
// remote systems, default accounts, monitor and audit.
"use strict";
(function () {
  const API = window.AnaApi;
  const { $, $$, el, fmtDate, errorText, toast, table, pill } = window.AnaUI;
  const ROLES = { admin: "administrador", developer: "desenvolvedor", user: "usuário" };

  let monitorTimer = null;
  let current = "users";

  function main() { return $("#admin-main"); }

  function header(title, lead) {
    return [el("h2", { text: title }), el("p", { class: "lead", text: lead })];
  }

  async function guard(fn) {
    try { return await fn(); } catch (e) { toast(errorText(e), true); return undefined; }
  }

  function field(label, input) { return el("label", {}, label, input); }
  function check(label, input) { return el("label", { class: "check" }, input, label); }

  function secretBox(title, username, password) {
    return el("div", { class: "secret-box" },
      el("div", { text: title }),
      el("div", {}, "Login: ", el("strong", { text: username })),
      el("div", {}, "Senha: ", el("strong", { text: password })),
      el("div", { class: "muted", text: "Copie agora: ela não será exibida novamente. O usuário deverá trocá-la no primeiro acesso." }));
  }

  // ------------------------------------------------------------------ users
  async function users(search = "") {
    const [list, groups] = await Promise.all([API.admin.users(search), API.admin.groups()]);
    const side = el("div");
    const searchInput = el("input", { placeholder: "Buscar por login ou nome…", value: search });
    searchInput.addEventListener("keydown", (e) => { if (e.key === "Enter") users(searchInput.value); });

    const showForm = (u) => side.replaceChildren(userForm(u, groups));
    const t = table([
      { label: "Login", value: (u) => el("span", {}, u.username, u.kind === "robot" ? " " : "", u.kind === "robot" ? pill(u.builtin ? "robô interno" : "robô") : null) },
      { label: "Nome", value: (u) => u.name },
      { label: "Papel", value: (u) => ROLES[u.role] || u.role },
      { label: "Grupos", value: (u) => el("span", {}, (u.groups || []).map((g) => pill(g))) },
      { label: "Situação", value: (u) => el("span", {}, u.active ? pill("ativo", "ok") : pill("bloqueado", "off"),
                                              u.must_change_password ? pill("trocar senha", "warn") : null) },
      { label: "Último acesso", value: (u) => fmtDate(u.last_login_at) || "—" },
    ], list, { onRow: (u) => showForm(u) });

    main().replaceChildren(
      ...header("Usuários", "Inclua pessoas, defina papel e grupos, bloqueie acessos e redefina senhas."),
      el("div", { class: "admin-toolbar" }, searchInput,
        el("button", { text: "Buscar", onclick: () => users(searchInput.value) }),
        el("button", { class: "primary", text: "+ Novo usuário", onclick: () => showForm(null) }),
        el("button", { class: "quiet", text: "Desbloquear endereço IP", title: "Após muitas senhas erradas, um endereço fica bloqueado por alguns minutos",
          onclick: () => guard(async () => {
            const ip = prompt("Endereço IP a desbloquear (vazio = o seu):", "");
            if (ip === null) return;
            const r = await API.admin.unlockIp(ip.trim() || "self");
            toast(`Endereço ${r.ip} desbloqueado.`);
          }) })),
      el("div", { class: "admin-columns" }, el("div", {}, t), side));
    showForm(null);
  }

  function userForm(u, groups) {
    const isNew = !u;
    const isRobot = u && u.kind === "robot";
    const kind = el("select", {}, el("option", { value: "human", text: "pessoa" }), el("option", { value: "robot", text: "robô (rotinas e integrações)" }));
    const username = el("input", { value: u ? u.username : "", required: true, disabled: !isNew, placeholder: "ex.: maria.silva" });
    const name = el("input", { value: u ? u.name : "" });
    const role = el("select", {}, Object.entries(ROLES).map(([v, l]) => el("option", { value: v, text: l })));
    role.value = u ? u.role : "user";
    const passwordLabel = el("label", {}, "Senha inicial");
    kind.addEventListener("change", () => {
      passwordLabel.hidden = kind.value === "robot";
      role.querySelector('option[value="admin"]').disabled = kind.value === "robot";
      if (kind.value === "robot" && role.value === "admin") role.value = "user";
    });
    if (isRobot) role.querySelector('option[value="admin"]').disabled = true;
    const active = el("input", { type: "checkbox", checked: u ? u.active : true });
    if (u && u.builtin) { role.disabled = true; active.disabled = true; }
    const password = el("input", { type: "password", autocomplete: "new-password", placeholder: "deixe vazio para gerar" });
    const groupChecks = groups.map((g) => {
      const c = el("input", { type: "checkbox", value: g.name, checked: u ? (u.groups || []).includes(g.name) : false });
      return check(g.name, c);
    });
    const out = el("div");
    const quotaMax = el("input", { type: "number", min: 0, placeholder: "padrão" });
    const quotaRate = el("input", { type: "number", min: 0, placeholder: "padrão" });
    if (!isNew) API.admin.quota(u.username).then((q) => {
      quotaMax.placeholder = `atual ${q.max_concurrent || "sem limite"}`;
      quotaRate.placeholder = `atual ${q.runs_per_minute || "sem limite"}`;
    }).catch(() => {});

    const save = async (e) => {
      e.preventDefault();
      const selected = groupChecks.map((l) => l.querySelector("input")).filter((c) => c.checked).map((c) => c.value);
      const body = { name: name.value, role: role.value, groups: selected, active: active.checked };
      await guard(async () => {
        if (isNew) {
          const robot = kind.value === "robot";
          const r = await API.admin.createUser({ ...body, kind: kind.value, username: username.value.trim(),
                                                 password: robot ? undefined : (password.value || undefined) });
          toast(robot ? `Robô ${r.username} criado. Gere uma chave de API na ficha dele.` : `Usuário ${r.username} criado.`);
          await users();
          if (r.password) main().querySelector(".form-card").prepend(secretBox("Senha gerada", r.username, r.password));
        } else {
          await API.admin.updateUser(u.username, body);
          if (quotaMax.value !== "" || quotaRate.value !== "") {
            await API.admin.saveQuota(u.username, {
              max_concurrent: quotaMax.value === "" ? null : parseInt(quotaMax.value, 10),
              runs_per_minute: quotaRate.value === "" ? null : parseInt(quotaRate.value, 10),
            });
          }
          toast("Usuário atualizado.");
          await users();
        }
      });
    };

    const actions = isNew || isRobot ? [] : [
      el("button", { type: "button", text: "Redefinir senha", onclick: () => guard(async () => {
        if (!confirm(`Gerar nova senha para ${u.username}? As sessões atuais serão encerradas.`)) return;
        const r = await API.admin.resetPassword(u.username);
        out.replaceChildren(secretBox("Nova senha", r.username, r.password));
      }) }),
      el("button", { type: "button", text: "Encerrar sessões", onclick: () => guard(async () => {
        if (!confirm(`Encerrar todas as sessões de ${u.username}?`)) return;
        const r = await API.admin.revokeSessions(u.username);
        toast(`${r.sessions} sessão(ões) encerrada(s).`);
      }) }),
      el("button", { type: "button", text: "Desbloquear login", onclick: () => guard(async () => {
        await API.admin.unlock(u.username);
        toast("Bloqueio por tentativas removido.");
      }) }),
    ];

    passwordLabel.append(password);
    return el("form", { class: "form-card", onsubmit: save },
      el("h3", { text: isNew ? "Novo usuário" : `${isRobot ? "Robô" : "Editar"} ${u.username}` }),
      isNew ? field("Tipo", kind) : null,
      u && u.builtin ? el("p", { class: "muted", text: "Robô interno: dono das tarefas que o próprio ERP executa (sementes, atualização do analítico). Não pode ser desativado nem receber chaves; para integrações, crie um robô próprio." }) : null,
      isRobot ? el("p", { class: "muted", text: "Conta não interativa: usada por rotinas agendadas (executar como) e por integrações que chamam programas expostos com uma chave de API. Não entra pela tela de login." }) : null,
      field("Login", username), field("Nome", name), field("Papel", role),
      isNew ? passwordLabel : null,
      check("Ativo (pode entrar)", active),
      el("div", {}, el("div", { class: "muted", text: "Grupos de acesso" }),
        groups.length ? el("div", { class: "checks" }, groupChecks) : el("div", { class: "muted", text: "Nenhum grupo cadastrado." })),
      isNew ? null : el("div", {}, el("div", { class: "muted", text: "Cota de execução (vazio = padrão do sistema)" }),
        el("div", { class: "row-buttons" }, field("Simultâneas", quotaMax), field("Por minuto", quotaRate))),
      el("div", { class: "row-buttons" }, el("button", { class: "primary", type: "submit", text: isNew ? "Criar usuário" : "Salvar" })),
      actions.length ? el("div", {}, el("div", { class: "muted", text: "Acesso" }), el("div", { class: "row-buttons" }, actions)) : null,
      !isNew ? el("div", { class: "row-buttons" }, el("button", { type: "button", text: "Ver trilha", onclick: () => {
        window.AnaStudio.replace("#/admin/audit");
        current = "audit";
        guard(() => audit("trail", { username: u.username }));
      } })) : null,
      isRobot && !u.builtin ? robotKeys(u.username) : null,
      out);
  }

  // Robot API keys (RF-011-13): the key is shown only once.
  function robotKeys(username) {
    const box = el("div", {}, el("div", { class: "muted", text: "Chaves de API" }));
    const list = el("div");
    const name = el("input", { placeholder: "nome (ex.: integração loja)" });
    const days = el("input", { type: "number", min: 1, placeholder: "validade em dias (vazio = sem)" });
    const ips = el("input", { placeholder: "IPs/redes permitidos, separados por vírgula (vazio = qualquer)" });
    const out = el("div");
    async function load() {
      const keys = await API.admin.keys(username);
      list.replaceChildren(table([
        { label: "Nome", value: (k) => el("span", {}, k.name, " ", el("code", { class: "muted", text: k.prefix + "…" })) },
        { label: "Situação", value: (k) => k.revoked_at ? pill("revogada", "off") : (k.valid ? pill("válida", "ok") : pill("vencida", "warn")) },
        { label: "Último uso", value: (k) => fmtDate(k.last_used_at) || "—" },
        { label: "", value: (k) => k.revoked_at ? "" : el("button", { type: "button", class: "danger small", text: "Revogar", onclick: () => guard(async () => {
            if (!confirm(`Revogar a chave "${k.name}"? Integrações que a usam deixarão de funcionar imediatamente.`)) return;
            await API.admin.revokeKey(k.id); load();
          }) }) },
      ], keys, { empty: "Nenhuma chave." }));
    }
    const generate = el("button", { type: "button", text: "Gerar chave", onclick: () => guard(async () => {
      const r = await API.admin.createKey(username, {
        name: name.value || "chave",
        expires_in_days: days.value ? parseInt(days.value, 10) : null,
        ip_allow: ips.value.split(",").map((s) => s.trim()).filter(Boolean),
      });
      out.replaceChildren(el("div", { class: "secret-box" },
        el("div", { text: "Nova chave de API (copie agora: não será exibida novamente)" }),
        el("strong", { text: r.key }),
        el("div", { class: "muted", text: "Uso: Authorization: Bearer <chave>" })));
      name.value = ""; days.value = ""; ips.value = "";
      load();
    }) });
    box.append(list, name, days, ips, el("div", { class: "row-buttons" }, generate), out);
    load();
    return box;
  }

  // ------------------------------------------------------------------ groups
  async function groups() {
    const list = await API.admin.groups();
    const side = el("div");
    const showForm = (g) => side.replaceChildren(groupForm(g));
    main().replaceChildren(
      ...header("Grupos de acesso", "Defina quais programas cada grupo executa. Programas marcados como \"restrito\" só rodam para membros de um grupo que os cubra."),
      el("div", { class: "admin-toolbar" }, el("button", { class: "primary", text: "+ Novo grupo", onclick: () => showForm(null) })),
      el("div", { class: "admin-columns" },
        el("div", {}, table([
          { label: "Grupo", value: (g) => g.name },
          { label: "Descrição", value: (g) => g.description },
          { label: "Programas", value: (g) => el("span", {}, (g.program_patterns || []).map((p) => pill(p))) },
          { label: "Membros", value: (g) => g.members, class: "num" },
        ], list, { onRow: showForm })), side));
    showForm(null);
  }

  function groupForm(g) {
    const isNew = !g;
    const name = el("input", { value: g ? g.name : "", disabled: !isNew, placeholder: "ex.: engenharia" });
    const description = el("input", { value: g ? g.description : "" });
    const patterns = el("textarea", { rows: 6, placeholder: "um por linha, ex.:\nprojects.*\nsales.create_order" });
    patterns.value = g ? (g.program_patterns || []).join("\n") : "";
    return el("form", { class: "form-card", onsubmit: async (e) => {
      e.preventDefault();
      await guard(async () => {
        await API.admin.saveGroup((g ? g.name : name.value).trim(), {
          description: description.value,
          program_patterns: patterns.value.split("\n").map((s) => s.trim()).filter(Boolean),
        });
        toast("Grupo salvo.");
        await groups();
      });
    } },
      el("h3", { text: isNew ? "Novo grupo" : `Editar ${g.name}` }),
      field("Nome", name), field("Descrição", description), field("Programas (nome ou prefixo.*)", patterns),
      el("div", { class: "row-buttons" },
        el("button", { class: "primary", type: "submit", text: "Salvar" }),
        isNew ? null : el("button", { type: "button", class: "danger", text: "Excluir", onclick: () => guard(async () => {
          if (!confirm(`Excluir o grupo ${g.name}? Os membros perdem o acesso concedido por ele.`)) return;
          await API.admin.deleteGroup(g.name);
          toast("Grupo excluído.");
          await groups();
        }) })));
  }

  // ------------------------------------------------------------------ settings
  async function settings() {
    const list = await API.admin.settings();
    main().replaceChildren(
      ...header("Parâmetros", "Valem em até 5 segundos em todos os nós, sem reiniciar. Valores fora da faixa são recusados."),
      table([
        { label: "Parâmetro", value: (s) => el("div", {}, el("div", { text: s.description }), el("code", { class: "muted", text: s.key })) },
        { label: "Faixa", value: (s) => `${s.min} – ${s.max}`, class: "num" },
        { label: "Padrão", value: (s) => s.default, class: "num" },
        { label: "Valor", value: (s) => {
            const input = el("input", { type: "number", min: s.min, max: s.max, value: s.value });
            const btn = el("button", { text: "Salvar", onclick: () => guard(async () => {
              await API.admin.saveSetting(s.key, Number(input.value));
              toast(`${s.key} = ${input.value}`);
            }) });
            return el("div", { class: "row-buttons" }, input, btn);
          } },
      ], list));
  }

  // ------------------------------------------------------------------ company
  async function company() {
    const c = await API.admin.company();
    const fields = [["legal_name", "Razão social"], ["tax_id", "CNPJ / documento"], ["address", "Endereço"],
                    ["city", "Cidade"], ["state", "UF"], ["email", "E-mail"], ["phone", "Telefone"]];
    const inputs = Object.fromEntries(fields.map(([k]) => [k, el("input", { value: c[k] || "" })]));
    main().replaceChildren(
      ...header("Empresa", "Dados da empresa usados em documentos e no título do Estúdio."),
      el("form", { class: "form-card", onsubmit: async (e) => {
        e.preventDefault();
        await guard(async () => {
          const body = Object.fromEntries(Object.entries(inputs).map(([k, i]) => [k, i.value || null]));
          await API.admin.saveCompany(body);
          toast("Dados da empresa salvos.");
          window.AnaStudio && window.AnaStudio.refreshTitle(body.legal_name);
        });
      } }, fields.map(([k, label]) => field(label, inputs[k])),
        el("div", { class: "row-buttons" }, el("button", { class: "primary", type: "submit", text: "Salvar" }))));
  }

  // ------------------------------------------------------------------ commands
  async function commands() {
    const [list, programs] = await Promise.all([API.commands(), API.programs(false)]);
    const code = el("input", { placeholder: "ex.: logtime" });
    const program = el("select", {}, programs.filter((p) => p.kind === "program").map((p) => el("option", { value: p.name, text: p.name })));
    const description = el("input");
    main().replaceChildren(
      ...header("Comandos", "Atalhos digitados na barra superior que abrem um programa."),
      el("div", { class: "admin-columns" },
        el("div", {}, table([
          { label: "Comando", value: (c) => el("code", { text: c.code }) },
          { label: "Programa", value: (c) => c.program },
          { label: "Descrição", value: (c) => c.description },
          { label: "", value: (c) => el("div", { class: "cell-actions" }, el("button", { class: "danger small", text: "Remover", onclick: () => guard(async () => {
              if (!confirm(`Remover o comando ${c.code}?`)) return;
              await API.deleteCommand(c.code);
              await commands();
            }) })) },
        ], list, { onRow: (c) => { code.value = c.code; program.value = c.program; description.value = c.description; } })),
        el("form", { class: "form-card", onsubmit: async (e) => {
          e.preventDefault();
          await guard(async () => {
            await API.saveCommand(code.value.trim().toLowerCase(), { program: program.value, description: description.value });
            toast("Comando salvo.");
            await commands();
          });
        } }, el("h3", { text: "Incluir ou alterar" }), field("Código", code), field("Programa", program),
          field("Descrição", description), el("div", { class: "row-buttons" }, el("button", { class: "primary", type: "submit", text: "Salvar" })))));
  }

  // ------------------------------------------------------------------ remote systems
  async function remote() {
    const list = await API.admin.remoteSystems();
    const name = el("input", { placeholder: "ex.: matriz" });
    const url = el("input", { placeholder: "https://erp.exemplo.com" });
    const username = el("input");
    const password = el("input", { type: "password", autocomplete: "new-password", placeholder: "vazio mantém a atual" });
    const timeout = el("input", { type: "number", value: 15000, min: 100, max: 120000 });
    const active = el("input", { type: "checkbox", checked: true });
    main().replaceChildren(
      ...header("Sistemas remotos", "Outros sistemas que os programas podem chamar com ana.remote(). Programas nunca veem URL ou senha."),
      el("div", { class: "admin-columns" },
        el("div", {}, table([
          { label: "Nome", value: (s) => s.name },
          { label: "URL", value: (s) => s.url },
          { label: "Usuário", value: (s) => s.username || "—" },
          { label: "Senha", value: (s) => s.has_password ? pill("definida", "ok") : pill("ausente", "warn") },
          { label: "Situação", value: (s) => s.active ? pill("ativo", "ok") : pill("inativo", "off") },
        ], list, { onRow: (s) => { name.value = s.name; url.value = s.url; username.value = s.username || ""; timeout.value = s.timeout_ms; active.checked = s.active; password.value = ""; } })),
        el("form", { class: "form-card", onsubmit: async (e) => {
          e.preventDefault();
          await guard(async () => {
            await API.admin.saveRemoteSystem(name.value.trim(), { url: url.value.trim(), username: username.value || null,
              password: password.value || undefined, timeout_ms: Number(timeout.value), active: active.checked });
            toast("Sistema remoto salvo.");
            await remote();
          });
        } }, el("h3", { text: "Incluir ou alterar" }), field("Nome", name), field("URL", url), field("Usuário", username),
          field("Senha", password), field("Tempo máximo (ms)", timeout), check("Ativo", active),
          el("div", { class: "row-buttons" }, el("button", { class: "primary", type: "submit", text: "Salvar" })))));
  }

  // ------------------------------------------------------------------ default accounts
  async function accounts() {
    const list = await API.admin.defaultAccounts();
    main().replaceChildren(
      ...header("Contas padrão", "Contas contábeis usadas pelos programas do produto. Ajuste ao seu plano de contas."),
      table([
        { label: "Uso", value: (a) => el("div", {}, el("div", { text: a.description }), el("code", { class: "muted", text: a.key })) },
        { label: "Conta atual", value: (a) => `${a.account} — ${a.account_description}` },
        { label: "Nova conta", value: (a) => {
            const input = el("input", { value: a.account, placeholder: "ex.: 1.1.2" });
            return el("div", { class: "row-buttons" }, input, el("button", { text: "Salvar", onclick: () => guard(async () => {
              await API.admin.saveDefaultAccount(a.key, input.value.trim());
              toast("Conta padrão atualizada.");
              await accounts();
            }) }));
          } },
      ], list));
  }

  // ------------------------------------------------------------------ limits (spec 012)
  const LIMIT_KEYS = ["timeout_ms", "cpu_ms", "memory_mb", "sql_timeout_ms", "lock_timeout_ms", "output_kb",
                      "max_rows", "max_sql", "max_concurrent", "max_parallel_parts"];

  async function limits() {
    const [profiles, groupsList] = await Promise.all([API.admin.limitProfiles(), API.admin.groups()]);
    const kind = el("select", {}, el("option", { value: "role", text: "papel" }), el("option", { value: "group", text: "grupo" }));
    const target = el("input", { placeholder: "user | developer | admin | nome do grupo", list: "limit-targets" });
    const targets = el("datalist", { id: "limit-targets" },
      ["user", "developer", "admin", ...groupsList.map((g) => g.name)].map((t) => el("option", { value: t })));
    const inputs = Object.fromEntries(LIMIT_KEYS.map((k) => [k, el("input", { type: "number", min: 0, placeholder: k })]));
    const fill = (p) => {
      kind.value = p.target_kind; target.value = p.target;
      for (const k of LIMIT_KEYS) inputs[k].value = p.limits[k] ?? "";
    };
    const quotaUser = el("input", { placeholder: "login" });
    const quotaMax = el("input", { type: "number", min: 0, placeholder: "simultâneas" });
    const quotaRate = el("input", { type: "number", min: 0, placeholder: "por minuto" });

    main().replaceChildren(
      ...header("Limites e cotas", "Perfis de limite por papel e por grupo (grupos concedem; nunca acima do teto) e cota de um usuário. Tetos e padrões ficam em Sistema → Parâmetros; a cota também pode ser ajustada na ficha do usuário."),
      el("div", { class: "admin-columns" },
        el("div", {}, table([
          { label: "Alvo", value: (p) => `${p.target_kind === "role" ? "papel" : "grupo"}: ${p.target}` },
          { label: "Limites", value: (p) => el("span", {}, Object.entries(p.limits).map(([k, v]) => pill(`${k}=${v}`))) },
          { label: "", value: (p) => el("div", { class: "cell-actions" }, el("button", { class: "danger small", text: "Remover", onclick: () => guard(async () => {
              if (!confirm(`Remover o perfil de ${p.target}?`)) return;
              await API.admin.deleteLimitProfile(p.target_kind, p.target);
              await limits();
            }) })) },
        ], profiles, { onRow: fill, empty: "Nenhum perfil: valem os padrões e tetos globais." })),
        el("form", { class: "form-card", onsubmit: async (e) => {
          e.preventDefault();
          const body = {};
          for (const k of LIMIT_KEYS) if (inputs[k].value !== "") body[k] = parseInt(inputs[k].value, 10);
          await guard(async () => {
            await API.admin.saveLimitProfile(kind.value, target.value.trim(), body);
            toast("Perfil de limite salvo.");
            await limits();
          });
        } }, el("h3", { text: "Perfil de limite" }), field("Aplica a", kind), field("Alvo", target), targets,
          LIMIT_KEYS.map((k) => field(k, inputs[k])),
          el("div", { class: "row-buttons" }, el("button", { class: "primary", type: "submit", text: "Salvar" })))),
      el("h3", { text: "Cota de um usuário" }),
      el("form", { class: "admin-toolbar", onsubmit: async (e) => {
        e.preventDefault();
        await guard(async () => {
          const body = {
            max_concurrent: quotaMax.value === "" ? null : parseInt(quotaMax.value, 10),
            runs_per_minute: quotaRate.value === "" ? null : parseInt(quotaRate.value, 10),
          };
          const q = await API.admin.saveQuota(quotaUser.value.trim(), body);
          toast(`Cota de ${q.username}: ${q.max_concurrent} simultâneas, ${q.runs_per_minute}/min.`);
        });
      } }, quotaUser, quotaMax, quotaRate, el("button", { type: "submit", text: "Salvar cota" })),
      );
  }

  async function consumption(days = 7) {
    const usage = await API.admin.consumption(days);
    main().replaceChildren(
      ...header("Consumo", "Programas que mais consomem CPU, tempo e memória no período — ponto de partida para otimizar ou ajustar limites."),
      el("div", { class: "sub-tabs" }, [1, 7, 30].map((d) => el("button", { class: d === days ? "active" : "", text: `${d} dias`, onclick: () => consumption(d) }))),
      usage.length ? window.AnaCharts.render({ type: "bar", title: "CPU total por programa", subtitle: `últimos ${days} dia(s)`,
        x: usage.slice(0, 12).map((r) => r.program), series: [{ name: "CPU (ms)", values: usage.slice(0, 12).map((r) => Number(r.total_cpu_ms) || 0) }],
        format: "number", unit: "ms" }) : null,
      table([
        { label: "Programa", value: (r) => r.program },
        { label: "Execuções", value: (r) => r.runs, class: "num" },
        { label: "CPU total (ms)", value: (r) => r.total_cpu_ms ?? "—", class: "num" },
        { label: "Tempo médio (ms)", value: (r) => r.avg_ms ?? "—", class: "num" },
        { label: "Tempo máx. (ms)", value: (r) => r.max_ms ?? "—", class: "num" },
        { label: "Memória máx. (MiB)", value: (r) => r.max_rss_kb ? Math.round(r.max_rss_kb / 1024) : "—", class: "num" },
        { label: "SQL", value: (r) => r.sql_count ?? "—", class: "num" },
        { label: "Falhas", value: (r) => r.failures, class: "num" },
      ], usage));
  }

  // ------------------------------------------------------------------ monitor
  async function monitor() {
    const m = await API.admin.monitor();
    const stat = (label, value, sub) => el("div", { class: "stat" }, el("div", { class: "label", text: label }),
      el("div", { class: "value", text: String(value) }), sub ? el("div", { class: "sub", text: sub }) : null);
    const pool = (p) => `${p.busy} em uso · ${p.free} livres · ${p.waiting} aguardando`;
    main().replaceChildren(
      ...header("Monitor", `Versão ${m.version} · no ar há ${Math.floor(m.uptime_s / 3600)} h ${Math.floor(m.uptime_s % 3600 / 60)} min · atualiza a cada 5 s`),
      el("div", { class: "stat-grid" },
        stat("Execuções ativas", m.counters.executions, `${m.counters.debug_sessions} depuração(ões)`),
        stat("Banco (núcleo)", m.database.size, pool(m.database)),
        stat("Banco (programas)", m.database_programs.size, pool(m.database_programs)),
        stat("Python pré-aquecidos", m.python.ready, `alvo ${m.python.target}`),
        stat("Memória", `${m.memory_mb} MB`, `${m.processes} processos Erlang`),
        stat("Analítico", m.analytics.last_result || "—", fmtDate(m.analytics.last_refresh))),
      el("h3", { text: "Banco de dados (memória e extensões)" }),
      table([
        { label: "Parâmetro", value: (s) => el("code", { text: s.name }) },
        { label: "Valor", value: (s) => `${s.setting}${s.unit ? " × " + s.unit : ""}` },
      ], m.database_settings || []),
      el("h3", { text: "Execuções em andamento" }),
      table([
        { label: "Programa", value: (x) => x.program },
        { label: "Usuário", value: (x) => x.username },
        { label: "Início", value: (x) => fmtDate(x.started_at) },
        { label: "Tipo", value: (x) => x.debug ? pill("depuração", "warn") : pill("execução") },
        { label: "", value: (x) => el("div", { class: "cell-actions" }, el("button", { class: "danger small", text: "Parar", onclick: () => guard(async () => {
            if (!confirm(`Parar ${x.program} de ${x.username}? A transação será desfeita.`)) return;
            await API.admin.stopExecution(x.id);
            toast("Execução parada.");
            await monitor();
          }) })) },
      ], m.running, { empty: "Nenhuma execução em andamento." }));
    clearTimeout(monitorTimer);
    monitorTimer = setTimeout(() => { if (current === "monitor" && !$("#area-admin").hidden) guard(monitor); }, 5000);
  }

  // ------------------------------------------------------------------ audit (RF-011-09, spec 024)
  const AUDIT_TABS = [["executions", "Execuções"], ["access", "Requisições"], ["logins", "Logins"],
                      ["tasks", "Tarefas internas"], ["changes", "Alterações"], ["trail", "Trilha do usuário"]];
  const TRAIL_KIND = { access: "requisição", login: "login", execution: "execução", task: "tarefa interna", change: "alteração" };
  const period = [["from", "De (AAAA-MM-DD)"], ["to", "Até (AAAA-MM-DD)"]];

  async function audit(kind = "executions", filters = {}) {
    const inputs = {
      executions: [["username", "Usuário"], ["program", "Programa (prefixo)"], ["status", "Status"], ...period],
      access: [["username", "Usuário"], ["path", "Caminho (prefixo)"], ["status", "Status HTTP"], ...period],
      logins: [["username", "Usuário"], ["success", "Sucesso (true/false)"]],
      changes: [["username", "Administrador"], ["action", "Ação (prefixo)"]],
      tasks: [["username", "Dono"], ["task", "Tarefa (prefixo)"]],
      trail: [["username", "Usuário ou robô"], ...period],
    }[kind];
    const fields = inputs.map(([k, label]) => [k, el("input", { placeholder: label, value: filters[k] || "" })]);
    const detail = el("div");
    const columns = {
      executions: [
        { label: "Quando", value: (r) => fmtDate(r.started_at) },
        { label: "Programa", value: (r) => `${r.program} v${r.version ?? "?"}` },
        { label: "Usuário", value: (r) => r.username },
        { label: "Origem", value: (r) => r.origin + (r.debug ? " · depuração" : "") + (r.client_ip ? ` · ${r.client_ip}` : "") },
        { label: "Status", value: (r) => el("span", { class: "status-" + r.status, text: r.status + (r.error ? ` (${r.error})` : "") }) },
        { label: "ms", value: (r) => r.duration_ms ?? "…", class: "num" },
        { label: "CPU ms", value: (r) => r.cpu_ms ?? "", class: "num" },
      ],
      access: [
        { label: "Quando", value: (r) => fmtDate(r.at) },
        { label: "Usuário", value: (r) => r.username || el("span", { class: "muted", text: "não identificado" }) },
        { label: "Como", value: (r) => r.auth + (r.api_key_id ? ` #${r.api_key_id}` : "") },
        { label: "IP / nó", value: (r) => r.ip || "" },
        { label: "Requisição", value: (r) => el("code", { text: `${r.method} ${r.path}` }) },
        { label: "Status", value: (r) => el("span", { class: r.status >= 400 ? "status-error" : "status-success", text: String(r.status ?? "") }) },
        { label: "ms", value: (r) => r.duration_ms ?? "", class: "num" },
        { label: "Detalhe", value: (r) => r.detail ? el("code", { class: "muted", text: r.detail.slice(0, 120) }) : "" },
      ],
      logins: [
        { label: "Quando", value: (r) => fmtDate(r.at) },
        { label: "Usuário", value: (r) => r.username },
        { label: "IP", value: (r) => r.ip },
        { label: "Resultado", value: (r) => r.success ? pill("entrou", "ok") : pill(r.reason === "locked" ? "bloqueado" : r.reason === "robot" ? "robô (sem login)" : "senha inválida", "off") },
      ],
      changes: [
        { label: "Quando", value: (r) => fmtDate(r.at) },
        { label: "Administrador", value: (r) => r.username },
        { label: "Ação", value: (r) => el("code", { text: r.action }) },
        { label: "Alvo", value: (r) => r.target },
        { label: "Depois", value: (r) => r.after ? el("code", { class: "muted", text: JSON.stringify(r.after).slice(0, 160) }) : "" },
      ],
      tasks: [
        { label: "Quando", value: (r) => fmtDate(r.started_at) },
        { label: "Tarefa", value: (r) => el("code", { text: r.task }) },
        { label: "Dono", value: (r) => r.username },
        { label: "Origem", value: (r) => r.origin },
        { label: "Status", value: (r) => el("span", { class: "status-" + r.status, text: r.status }) },
        { label: "Detalhe", value: (r) => r.detail ? el("span", { class: "muted", text: String(r.detail).slice(0, 160) }) : "" },
        { label: "ms", value: (r) => r.duration_ms ?? "…", class: "num" },
      ],
      trail: [
        { label: "Quando", value: (r) => fmtDate(r.at) },
        { label: "O quê", value: (r) => pill(TRAIL_KIND[r.kind] || r.kind) },
        { label: "Detalhe", value: (r) => el("code", { text: r.what }) },
        { label: "Status", value: (r) => r.status || "" },
        { label: "", value: (r) => r.detail ? el("span", { class: "muted", text: String(r.detail).slice(0, 140) }) : "" },
        { label: "ms", value: (r) => r.duration_ms ?? "", class: "num" },
      ],
    }[kind];
    let rows = [];
    if (kind !== "trail" || filters.username) rows = await API.admin.audit(kind, { ...filters, limit: 200 });
    const onRow = kind === "executions" ? (r) => showExecution(r.id, detail)
                : kind === "trail" ? (r) => { if (r.kind === "execution") showExecution(r.ref, detail); }
                : null;
    const apply = () => audit(kind, Object.fromEntries(fields.map(([k, i]) => [k, i.value.trim()])));
    main().replaceChildren(
      ...header("Auditoria", "Tudo o que pessoas e robôs fazem: requisições, logins, execuções (tempo, CPU, stack traces), tarefas internas e alterações. Prazos de guarda em Retenção."),
      el("div", { class: "sub-tabs" }, AUDIT_TABS.map(([k, l]) =>
        el("button", { class: k === kind ? "active" : "", text: l, onclick: () => audit(k) }))),
      el("div", { class: "admin-toolbar" }, fields.map(([, i]) => {
        i.addEventListener("keydown", (e) => { if (e.key === "Enter") apply(); });
        return i;
      }), el("button", { text: "Filtrar", onclick: apply })),
      kind === "trail" && !filters.username ? el("p", { class: "muted", text: "Informe o usuário (ou abra pela ficha dele em Usuários → Ver trilha)." }) : table(columns, rows, { onRow }),
      detail);
  }

  // RF-024-07: everything recorded about one execution.
  async function showExecution(id, target) {
    const x = await API.admin.execution(id);
    const kv = (label, value) => el("div", {}, el("span", { class: "muted", text: label + ": " }), String(value ?? "—"));
    const block = (title, value) => value === null || value === undefined || value === "" ? null :
      el("div", {}, el("h4", { text: title }), el("pre", { class: "code-view", text: typeof value === "string" ? value : JSON.stringify(value, null, 2) }));
    target.replaceChildren(el("div", { class: "form-card" },
      el("h3", { text: `Execução ${x.program} v${x.version ?? "?"}` }),
      el("div", { class: "stat-grid" },
        kv("Dono", x.username), kv("Origem", x.origin + (x.debug ? " (depuração)" : "")), kv("Status", x.status),
        kv("Início", fmtDate(x.started_at)), kv("Duração", x.duration_ms != null ? `${x.duration_ms} ms` : null),
        kv("CPU", x.cpu_ms != null ? `${x.cpu_ms} ms` : null), kv("Memória máx.", x.max_rss_kb != null ? `${Math.round(x.max_rss_kb / 1024)} MB` : null),
        kv("Comandos SQL", x.sql_count), kv("Linhas lidas", x.rows_read), kv("IP", x.client_ip),
        kv("Chave de API", x.api_key_id ? "#" + x.api_key_id : null), kv("Nó", x.node)),
      x.payload_purged_at ? el("p", { class: "muted", text: `Conteúdo (parâmetros, resultado, saída e stack traces) expurgado em ${fmtDate(x.payload_purged_at)} pela política de retenção.` }) : null,
      x.parent ? el("p", {}, "Parte da execução ", el("button", { class: "link", text: x.parent, onclick: () => showExecution(x.parent, target) })) : null,
      x.parts && x.parts.length ? el("div", {}, el("h4", { text: `Partes paralelas (${x.parts.length}) · CPU total ${x.total.cpu_ms} ms · ${x.total.sql_count} SQL` }),
        table([
          { label: "Programa", value: (p) => p.program },
          { label: "Status", value: (p) => el("span", { class: "status-" + p.status, text: p.status + (p.error ? ` (${p.error})` : "") }) },
          { label: "ms", value: (p) => p.duration_ms ?? "…", class: "num" },
          { label: "CPU ms", value: (p) => p.cpu_ms ?? "", class: "num" },
        ], x.parts, { onRow: (p) => showExecution(p.id, target) })) : null,
      block("Erro", x.error && { code: x.error.code, message: x.error.message, line: x.error.line }),
      block("Stack trace", x.error && x.error.trace),
      x.error && x.error.frames && x.error.frames.length ? el("div", {}, el("h4", { text: "Quadros (do mais externo ao do erro)" }),
        table([{ label: "Programa", value: (f) => f.where }, { label: "Linha", value: (f) => f.line, class: "num" },
               { label: "Função", value: (f) => f.function }, { label: "Código", value: (f) => el("code", { text: f.code }) }], x.error.frames)) : null,
      x.error && x.error.locals && Object.keys(x.error.locals).length ? el("div", {}, el("h4", { text: "Variáveis no ponto do erro" }),
        table([{ label: "Nome", value: (v) => v[0] }, { label: "Valor", value: (v) => el("code", { text: v[1] }) }], Object.entries(x.error.locals))) : null,
      traceView(x.trace),
      block("Trace interno do núcleo", x.internal_trace),
      block("Limites aplicados", x.limits), block("Parâmetros", x.params),
      block("Resultado", x.result), block("Saída", x.output)));
    target.scrollIntoView?.({ block: "nearest" });
  }

  // RF-019-03/05: SQL timeline (where the time went) and profile of a traced execution.
  function traceView(t) {
    if (!t) return el("p", { class: "muted small", text: "Sem rastro detalhado (execuções rápidas e sem erro são amostradas)." });
    const evs = t.events || [];
    const byHash = {};
    for (const e of evs) { const k = e.hash; byHash[k] = byHash[k] || { sql: e.sql, ms: 0, n: 0 }; byHash[k].ms += e.ms; byHash[k].n += 1; }
    const top = Object.values(byHash).sort((a, b) => b.ms - a.ms).slice(0, 8);
    const prof = t.profile && t.profile.functions ? t.profile : null;
    return el("div", {},
      el("h4", { text: `Rastro (${({ error: "erro", slow: "execução lenta", sample: "amostra", profile: "perfil" })[t.reason] || t.reason}) · ${evs.length} comando(s) SQL · ${Number(t.sql_ms).toLocaleString("pt-BR")} ms em SQL` }),
      top.length > 1 ? window.AnaCharts.render({ type: "bar", title: "Tempo por comando nesta execução", format: "number", unit: "ms",
        x: top.map((h) => `${h.sql.slice(0, 50)}${h.sql.length > 50 ? "…" : ""} (${h.n}×)`), series: [{ name: "Tempo", values: top.map((h) => h.ms) }] }) : null,
      evs.length ? table([
        { label: "Aos (ms)", value: (e) => e.t_ms, class: "num" },
        { label: "Duração (ms)", value: (e) => Number(e.ms).toLocaleString("pt-BR", { maximumFractionDigits: 2 }), class: "num" },
        { label: "Linhas", value: (e) => e.rows, class: "num" },
        { label: "Onde", value: (e) => e.at ? `${e.at[0]}:${e.at[1]}` : "" },
        { label: "Comando", value: (e) => el("code", { class: e.error ? "status-error" : "", text: e.sql.length > 120 ? e.sql.slice(0, 120) + "…" : e.sql, title: e.sql }) },
      ], evs.slice(0, 500)) : null,
      prof ? el("div", {}, el("h4", { text: `Perfil · ${Number(prof.sql_wait_ms).toLocaleString("pt-BR")} ms esperando SQL` }),
        window.AnaCharts.render({ type: "bar", title: "Funções com mais tempo (total)", format: "number", unit: "ms",
          x: prof.functions.slice(0, 10).map((f) => `${f.function} (${f.where}:${f.line})`), series: [{ name: "Tempo total", values: prof.functions.slice(0, 10).map((f) => f.total_ms) }] }),
        table([{ label: "Função", value: (f) => f.function }, { label: "Onde", value: (f) => `${f.where}:${f.line}` },
               { label: "Chamadas", value: (f) => f.calls, class: "num" }, { label: "Próprio (ms)", value: (f) => f.self_ms, class: "num" },
               { label: "Total (ms)", value: (f) => f.total_ms, class: "num" }], prof.functions)) : null);
  }

  // ------------------------------------------------------------------ retention (RF-024-08..10)
  async function retention() {
    const r = await API.admin.retention();
    const mb = (b) => b >= 1048576 ? `${(b / 1048576).toFixed(1)} MB` : `${Math.round(b / 1024)} KB`;
    const out = el("div");
    const settingsList = await API.admin.settings();
    const meta = Object.fromEntries(settingsList.map((s) => [s.key, s]));
    const dayInput = (c) => {
      const s = meta[c.setting] || {};
      const i = el("input", { type: "number", min: s.min ?? 1, max: s.max ?? 36500, value: c.days, class: "num-input" });
      i.addEventListener("change", () => guard(async () => {
        await API.admin.saveSetting(c.setting, parseInt(i.value, 10));
        toast(`Prazo de "${c.label}" alterado para ${i.value} dias.`);
        retention();
      }));
      return el("span", {}, i, el("span", { class: "muted", text: ` dias (mín. ${s.min ?? 1})` }));
    };
    const last = r.last_purges[0];
    main().replaceChildren(
      ...header("Retenção", `Por quanto tempo guardar cada tipo de registro. O expurgo roda todo dia a partir das ${r.hour}h (fuso do cliente), em lotes pequenos e descartando partições inteiras — leve para o banco e para o disco. Categorias que compartilham o mesmo prazo mudam juntas.`),
      el("div", { class: "stat-grid" },
        el("div", { class: "stat" }, el("div", { class: "label", text: "Último expurgo" }),
          el("div", { class: "value", text: last ? (last.status === "success" ? "ok" : last.status) : "—" }),
          el("div", { class: "sub", text: last ? `${fmtDate(last.started_at)} · ${last.username} (${last.origin})` : "ainda não rodou" }))),
      table([
        { label: "Categoria", value: (c) => c.label },
        { label: "Guardar por", value: dayInput },
        { label: "Registros (aprox.)", value: (c) => c.rows.toLocaleString("pt-BR"), class: "num" },
        { label: "Espaço", value: (c) => mb(c.bytes), class: "num" },
        { label: "Mais antigo", value: (c) => fmtDate(c.oldest) || "—" },
        { label: "Vencidos", value: (c) => c.expired ? pill(String(c.expired), "warn") : "0", class: "num" },
      ], r.categories),
      el("div", { class: "row-buttons" }, el("button", { class: "primary", text: "Expurgar agora", onclick: () => guard(async () => {
        if (!confirm("Remover agora tudo o que passou do prazo? Não há como desfazer.")) return;
        const res = await API.admin.purge();
        out.replaceChildren(el("p", { text: "Removidos: " + Object.entries(res.counts).map(([k, v]) => `${k} ${v}`).join(" · ") }));
        await retention();
        main().append(out);
      }) })),
      el("h3", { text: "Expurgos recentes" }),
      table([
        { label: "Quando", value: (p) => fmtDate(p.started_at) },
        { label: "Dono", value: (p) => p.username },
        { label: "Origem", value: (p) => p.origin },
        { label: "Status", value: (p) => el("span", { class: "status-" + p.status, text: p.status }) },
        { label: "Removidos", value: (p) => p.detail ? el("code", { class: "muted", text: p.detail }) : "" },
      ], r.last_purges, { empty: "Nenhum expurgo ainda." }),
      out);
  }

  // ------------------------------------------------------------------ observability (spec 019)
  const STATE = { green: ["●", "normal", "ok"], yellow: ["▲", "atenção", "warn"], red: ["■", "falha", "off"] };
  const SEVERITY = { info: ["ℹ", "informação", ""], warning: ["▲", "atenção", "warn"], serious: ["◆", "sério", "off"], critical: ["■", "crítico", "off"] };
  const COMPONENT = { database: "Banco de dados", pool_core: "Conexões do núcleo", pool_programs: "Conexões dos programas",
    python: "Processos Python", scheduler: "Agendamento", access_log: "Registro de acessos", remote_systems: "Sistemas remotos" };
  const stateChip = (s) => { const [icon, label, cls] = STATE[s] || ["?", s, ""]; return pill(`${icon} ${label}`, cls); };
  const sevChip = (s) => { const [icon, label, cls] = SEVERITY[s] || ["", s, ""]; return pill(`${icon} ${label}`, cls); };
  const n2 = (v) => (v === null || v === undefined ? "—" : Number(v).toLocaleString("pt-BR", { maximumFractionDigits: 1 }));

  async function health() {
    const [h, samples] = await Promise.all([API.admin.obsHealth(), API.admin.obsSamples(24).catch(() => [])]);
    const stat = (c) => el("div", { class: "stat" }, el("div", { class: "label", text: COMPONENT[c.component] || c.component }),
      el("div", { class: "value" }, stateChip(c.state)), el("div", { class: "sub", text: `${c.message} · ${n2(c.latency_ms)} ms` }));
    // Executions per 5 min from the cumulative samples (one node at a time keeps it simple: sum by sample time).
    const byAt = new Map();
    for (const smp of samples) {
      const m = smp.metrics || {};
      const t = smp.at.slice(0, 16);
      const prev = byAt.get(t) || { ok: 0, bad: 0, mem: 0 };
      const ex = m.executions || {};
      prev.ok += ex.success || 0;
      prev.bad += (ex.error || 0) + (ex.timeout || 0) + (ex.aborted || 0);
      prev.mem += m.memory_mb || 0;
      byAt.set(t, prev);
    }
    const ats = [...byAt.keys()];
    const deltas = ats.slice(1).map((t, i) => {
      const a = byAt.get(ats[i]), b = byAt.get(t);
      return { t, ok: Math.max(0, b.ok - a.ok), bad: Math.max(0, b.bad - a.bad), mem: b.mem };
    });
    main().replaceChildren(
      ...header("Saúde", "Estado de cada componente (verificado a cada 10 s), incidentes e o que mudou. Só as mudanças ficam gravadas."),
      el("div", { class: "row-buttons" }, el("button", { text: "Verificar agora", onclick: () => guard(async () => { await API.admin.obsCheck(); health(); }) })),
      el("div", { class: "stat-grid" }, h.components.map(stat)),
      deltas.length >= 2 ? window.AnaCharts.render({ type: "stacked", title: "Execuções a cada 5 minutos", subtitle: "últimas 24 h",
        x: deltas.map((d) => d.t.replace("T", " ")), series: [{ name: "Concluídas", values: deltas.map((d) => d.ok) },
                                                               { name: "Com falha", values: deltas.map((d) => d.bad) }] }) : null,
      deltas.length >= 2 ? window.AnaCharts.render({ type: "line", title: "Memória do núcleo", format: "number", unit: "MB",
        x: deltas.map((d) => d.t.replace("T", " ")), series: [{ name: "Memória", values: deltas.map((d) => d.mem) }] }) : null,
      el("h3", { text: "Incidentes" }),
      table([
        { label: "Componente", value: (i) => COMPONENT[i.component] || i.component },
        { label: "Nó", value: (i) => i.node },
        { label: "Início", value: (i) => fmtDate(i.opened_at) },
        { label: "Fim", value: (i) => i.closed_at ? fmtDate(i.closed_at) : pill("■ aberto", "off") },
        { label: "Duração", value: (i) => `${Math.round(i.seconds / 60)} min`, class: "num" },
        { label: "Mensagem", value: (i) => i.message },
      ], h.incidents, { empty: "Nenhum incidente." }),
      el("h3", { text: "Mudanças de estado (72 h)" }),
      table([
        { label: "Quando", value: (e) => fmtDate(e.at) },
        { label: "Componente", value: (e) => COMPONENT[e.component] || e.component },
        { label: "Estado", value: (e) => stateChip(e.state) },
        { label: "Mensagem", value: (e) => e.message },
        { label: "Nó", value: (e) => e.node },
      ], h.events, { empty: "Nenhuma mudança." }));
  }

  async function sqlperf(filters = { order: "total" }) {
    const rows = await API.admin.obsSql(filters);
    const detail = el("div");
    const program = el("input", { placeholder: "Programa (opcional)", value: filters.program || "" });
    const order = el("select", {}, [["total", "Tempo total"], ["mean", "Tempo médio"], ["max", "Tempo máximo"], ["calls", "Chamadas"]]
      .map(([v, l]) => el("option", { value: v, text: "Ordenar por " + l.toLowerCase() })));
    order.value = filters.order || "total";
    const apply = () => sqlperf({ program: program.value.trim(), order: order.value });
    const short = (q) => q.length > 90 ? q.slice(0, 90) + "…" : q;
    const top = rows.slice(0, 10);
    main().replaceChildren(
      ...header("Desempenho do SQL", "Cada comando SQL dos programas, medido e agregado. Os lentos ganham plano de execução e sugestão; veja também as Dicas."),
      el("div", { class: "admin-toolbar" }, program, order, el("button", { text: "Filtrar", onclick: apply }),
        el("button", { class: "quiet", text: "Atualizar agora", title: "Grava as medições do último minuto", onclick: () => guard(async () => { await API.admin.obsFlush(); apply(); }) })),
      top.length ? window.AnaCharts.render({ type: "bar", title: "Comandos com mais tempo total", format: "number", unit: "ms",
        x: top.map((r) => short(r.sql).slice(0, 48)), series: [{ name: "Tempo total", values: top.map((r) => Number(r.total_ms)) }] }) : null,
      table([
        { label: "Comando", value: (r) => el("code", { text: short(r.sql), title: r.sql }) },
        { label: "Chamadas", value: (r) => n2(r.calls), class: "num" },
        { label: "Total (ms)", value: (r) => n2(r.total_ms), class: "num" },
        { label: "Médio (ms)", value: (r) => n2(r.mean_ms), class: "num" },
        { label: "Máx. (ms)", value: (r) => n2(r.max_ms), class: "num" },
        { label: "Lentas", value: (r) => r.slow_calls ? pill(`▲ ${r.slow_calls}`, "warn") : "0", class: "num" },
        { label: "Varredura completa", value: (r) => (r.plan_summary && r.plan_summary.seq_scans && r.plan_summary.seq_scans.length)
            ? r.plan_summary.seq_scans.map((s) => `${s.table} (${n2(s.table_rows)} linhas)`).join(", ") : "" },
        { label: "Programas", value: (r) => (r.programs || []).join(", ") },
      ], rows, { empty: "Ainda sem medições — execute programas e clique em Atualizar agora.", onRow: (r) => sqlDetail(r.hash, detail) }),
      detail);
  }

  async function sqlDetail(hash, target) {
    const r = await API.admin.obsSqlDetail(hash);
    const scans = (r.plan_summary && r.plan_summary.seq_scans) || [];
    target.replaceChildren(el("div", { class: "form-card" },
      el("h3", { text: "Comando SQL" }), el("pre", { class: "code-view", text: r.sql }),
      el("div", { class: "stat-grid" },
        ...[["Chamadas", n2(r.calls)], ["Tempo total", n2(r.total_ms) + " ms"], ["Médio", n2(r.total_ms / Math.max(r.calls, 1)) + " ms"],
            ["Máximo", n2(r.max_ms) + " ms"], ["Linhas", n2(r.rows)], ["Custo estimado", r.plan_summary ? n2(r.plan_summary.cost) : "—"]]
          .map(([l, v]) => el("div", { class: "stat" }, el("div", { class: "label", text: l }), el("div", { class: "value", text: v })))),
      scans.length ? el("div", {}, el("h4", { text: "Varreduras completas no plano" }),
        table([{ label: "Tabela", value: (s) => s.table }, { label: "Linhas na tabela", value: (s) => n2(s.table_rows), class: "num" },
               { label: "Filtro", value: (s) => el("code", { text: s.filter || "—" }) }, { label: "Colunas do filtro", value: (s) => (s.columns || []).join(", ") }], scans)) : null,
      (r.advice || []).length ? el("div", {}, el("h4", { text: "Dicas" }), r.advice.map(adviceCard)) : null,
      r.plan ? el("details", {}, el("summary", { text: "Plano completo (EXPLAIN, sem executar)" }), el("pre", { class: "code-view", text: JSON.stringify(r.plan, null, 2) })) : null));
    target.scrollIntoView?.({ block: "nearest" });
  }

  function adviceCard(a) {
    const copy = el("button", { type: "button", class: "quiet small", text: "Copiar", onclick: () => {
      try { navigator.clipboard.writeText(a.suggestion); toast("Sugestão copiada."); } catch (_) { toast("Não foi possível copiar.", true); }
    } });
    return el("div", { class: "advice-card" },
      el("div", { class: "advice-head" }, sevChip(a.severity), el("strong", { text: a.title })),
      a.detail ? el("p", { class: "muted", text: a.detail }) : null,
      a.suggestion ? el("div", { class: "advice-suggestion" }, el("code", { text: a.suggestion }), copy) : null);
  }

  async function advice(status = "open") {
    const rows = await API.admin.advice(status);
    const counts = rows.reduce((acc, a) => ({ ...acc, [a.severity]: (acc[a.severity] || 0) + 1 }), {});
    main().replaceChildren(
      ...header("Dicas de otimização", "Problemas atuais e futuros encontrados no SQL, nos programas e no banco, com a correção sugerida. Analisadas a cada 15 minutos."),
      el("div", { class: "sub-tabs" }, [["open", "Abertas"], ["dismissed", "Dispensadas"], ["resolved", "Resolvidas"]].map(([k, l]) =>
        el("button", { class: k === status ? "active" : "", text: l, onclick: () => advice(k) }))),
      el("div", { class: "row-buttons" }, el("button", { text: "Analisar agora", onclick: () => guard(async () => {
        const r = await API.admin.adviceRun(); toast(`${r.found} dica(s) encontrada(s), ${r.resolved} resolvida(s).`); advice(status);
      }) })),
      status === "open" ? el("div", { class: "stat-grid" }, ["critical", "serious", "warning", "info"].map((s) =>
        el("div", { class: "stat" }, el("div", { class: "label" }, sevChip(s)), el("div", { class: "value", text: String(counts[s] || 0) })))) : null,
      rows.length ? el("div", {}, rows.map((a) => {
        const card = adviceCard(a);
        if (status === "open") card.append(el("div", { class: "row-buttons" },
          el("button", { type: "button", class: "quiet small", text: "Dispensar por 30 dias", onclick: () => guard(async () => { await API.admin.adviceDismiss(a.id, 30); advice(status); }) }),
          el("button", { type: "button", class: "quiet small", text: "Dispensar sempre", onclick: () => guard(async () => { await API.admin.adviceDismiss(a.id, 0); advice(status); }) })));
        card.append(el("details", {}, el("summary", { text: "evidência" }), el("pre", { class: "code-view", text: JSON.stringify(a.evidence, null, 2) })),
          el("div", { class: "muted small", text: `${a.rule} · visto pela primeira vez ${fmtDate(a.first_seen)} · última ${fmtDate(a.last_seen)}` }));
        return card;
      })) : el("p", { class: "muted", text: status === "open" ? "Nenhuma dica aberta. Bom sinal." : "Nada aqui." }));
  }

  // ------------------------------------------------------------------ navigation
  // ------------------------------------------------------------------ scheduler (spec 018)
  async function scheduler() {
    const jobs = el("div"), hol = el("div"), notes = el("div");
    main().replaceChildren(
      ...header("Agendamento", "Rotinas agendadas de todos os programas, feriados (dias úteis) e avisos de falha, atraso e duração anômala."),
      el("h3", { text: "Avisos" }), notes,
      el("h3", { text: "Rotinas" }), jobs,
      el("h3", { text: "Feriados" }), hol);
    await Promise.all([window.AnaScheduler.notifications(notes, false), window.AnaScheduler.render(jobs, {}),
                       window.AnaScheduler.holidays(hol)]);
  }

  const SECTIONS = { users, groups, settings, company, commands, remote, accounts, limits, consumption, scheduler, monitor, audit, retention, health, sqlperf, advice };

  function show(section) {
    current = section;
    if (!SECTIONS[section]) section = "users";
    current = section;
    for (const b of $$("#area-admin .nav-link")) b.classList.toggle("active", b.dataset.section === section);
    main().replaceChildren(el("p", { class: "muted", text: "Carregando…" }));
    guard(() => SECTIONS[section]());
  }

  function wire() {
    for (const b of $$("#area-admin .nav-link")) b.addEventListener("click", () => window.AnaStudio.go("#/admin/" + b.dataset.section));
  }

  window.AnaAdmin = { wire, show, current: () => current };
})();
