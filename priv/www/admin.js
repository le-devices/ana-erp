// SPDX-FileCopyrightText: 2026 André Luis Pereira dos Santos
// SPDX-License-Identifier: AGPL-3.0-or-later
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
  // Spec 050 (D3): the action of an empty list takes the person to what fills it on the same screen.
  const toForm = (label) => ({ label, onClick: () => {
    const f = main().querySelector("form input:not([type=hidden]):not([type=file]), form select, form textarea, textarea");
    if (f) { f.scrollIntoView && f.scrollIntoView({ block: "center" }); f.focus(); } } });
  const pressing = (label, text) => ({ label, onClick: () => {
    const b = [...main().querySelectorAll("button")].find((x) => x.textContent.trim().startsWith(text));
    if (b) { b.scrollIntoView && b.scrollIntoView({ block: "center" }); b.focus(); } } });

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
    const searchInput = el("input", { "aria-label": "Buscar por login ou nome…", placeholder: "Buscar por login ou nome…", value: search });
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
    ], list, { onRow: (u) => showForm(u), screen: "admin.users", title: "Usuários" });

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
    const name = el("input", { "aria-label": "nome (ex.: integração loja)", placeholder: "nome (ex.: integração loja)" });
    const days = el("input", { type: "number", min: 1, placeholder: "validade em dias (vazio = sem)", "aria-label": "Validade em dias (vazio = sem validade)" });
    const ips = el("input", { "aria-label": "IPs/redes permitidos, separados por vírgula (vazio = qualquer)", placeholder: "IPs/redes permitidos, separados por vírgula (vazio = qualquer)" });
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
      ...header("Grupos de acesso", "Defina quais programas cada grupo executa e, se quiser, quais dados seus membros veem. Programas marcados como \"restrito\" só rodam para membros de um grupo que os cubra; o escopo de dados vale para todos os programas e é aplicado pelo banco."),
      el("div", { class: "admin-toolbar" }, el("button", { class: "primary", text: "+ Novo grupo", onclick: () => showForm(null) })),
      el("div", { class: "admin-columns" },
        el("div", {}, table([
          { label: "Grupo", value: (g) => g.name },
          { label: "Descrição", value: (g) => g.description },
          { label: "Programas", value: (g) => el("span", {}, (g.program_patterns || []).map((p) => pill(p))) },
          { label: "Dados", value: (g) => el("span", {}, scopePills(g)) },
          { label: "Membros", value: (g) => g.members, class: "num" },
        ], list, { emptyAction: { label: "Criar um grupo", onClick: () => showForm(null) }, onRow: showForm })), side));
    showForm(null);
  }

  // Spec 009 (D10): what the group's members see (nothing set = everything).
  function scopePills(g) {
    const out = [];
    if (g.data_cost_centers && g.data_cost_centers.length) out.push(pill("centros: " + g.data_cost_centers.join(", "), "warn"));
    if (g.data_portfolio) out.push(pill("só a carteira", "warn"));
    if (g.data_own_projects) out.push(pill("só os próprios projetos", "warn"));
    return out.length ? out : ["todos"];
  }

  // RF-020-13: what a member would see with this scope, simulated before saving (counts by the database's policies).
  function scopePreview(read) {
    const member = el("input", { placeholder: "simular como (usuário; carteira e projetos dele)", "aria-label": "Simular como" });
    const out = el("div", { class: "scope-preview", "aria-live": "polite" });
    const run = () => guard(async () => {
      const r = await API.admin.scopePreview({ ...read(), member: member.value.trim() });
      const when = new Date().toLocaleTimeString("pt-BR");
      out.replaceChildren(el("p", { class: "muted small", text: `${r.restricted ? "Com este escopo" : "Sem restrição"}, simulado às ${when} — nada foi gravado.` }),
        table([{ label: "O que", value: (x) => x.label },
               { label: "Veria", value: (x) => x.visible.toLocaleString("pt-BR"), class: "num" },
               { label: "De", value: (x) => x.total.toLocaleString("pt-BR") + (x.total >= r.cap ? "+" : ""), class: "num" }], r.entities));
    });
    return el("div", { class: "scope-sim" }, el("div", { class: "row-buttons" }, member,
      el("button", { type: "button", text: "Simular", onclick: run })), out);
  }

  function groupForm(g) {
    const isNew = !g;
    const name = el("input", { value: g ? g.name : "", disabled: !isNew, placeholder: "ex.: engenharia" });
    const description = el("input", { value: g ? g.description : "" });
    const patterns = el("textarea", { rows: 6, placeholder: "um por linha, ex.:\nprojects.*\nsales.create_order" });
    patterns.value = g ? (g.program_patterns || []).join("\n") : "";
    const centers = el("input", { value: g && g.data_cost_centers ? g.data_cost_centers.join(", ") : "",
                                  placeholder: "vazio = todos; ex.: COMERCIAL, FILIAL-SP (inclui os centros filhos)" });
    const portfolio = el("input", { type: "checkbox" }); portfolio.checked = !!(g && g.data_portfolio);
    const ownProjects = el("input", { type: "checkbox" }); ownProjects.checked = !!(g && g.data_own_projects);
    const values = el("textarea", { rows: 3, placeholder: "um por linha, ex.:\nfinanceiro.*\nestoque.deposito_principal" });
    values.value = g ? (g.value_patterns || []).join("\n") : "";
    const variantPats = el("textarea", { rows: 2, placeholder: "um por linha, ex.:\nfinance.*\nsales.order_report" });
    variantPats.value = g ? (g.variant_patterns || []).join("\n") : "";
    return el("form", { class: "form-card", onsubmit: async (e) => {
      e.preventDefault();
      await guard(async () => {
        await API.admin.saveGroup((g ? g.name : name.value).trim(), {
          description: description.value,
          program_patterns: patterns.value.split("\n").map((s) => s.trim()).filter(Boolean),
          data_cost_centers: centers.value.split(",").map((s) => s.trim().toUpperCase()).filter(Boolean),
          data_portfolio: portfolio.checked,
          data_own_projects: ownProjects.checked,
          value_patterns: values.value.split("\n").map((s) => s.trim()).filter(Boolean),
          variant_patterns: variantPats.value.split("\n").map((s) => s.trim()).filter(Boolean),
        });
        toast("Grupo salvo.");
        await groups();
      });
    } },
      el("h3", { text: isNew ? "Novo grupo" : `Editar ${g.name}` }),
      field("Nome", name), field("Descrição", description), field("Programas (nome ou prefixo.*)", patterns),
      field("Valores da empresa que alteram (nome ou área.*)", values),
      field("Variantes da empresa que publicam (rotina ou prefixo.*)", variantPats),
      el("h4", { text: "Dados que os membros veem" }),
      field("Centros de custo", centers),
      check("Só os clientes da própria carteira (e seus pedidos e títulos)", portfolio),
      check("Só os projetos que gerencia ou em que trabalha", ownProjects),
      el("p", { class: "muted", text: "Administradores veem tudo. Quem está em vários grupos com restrição vê a soma deles." }),
      scopePreview(() => ({ data_cost_centers: centers.value.split(",").map((s) => s.trim().toUpperCase()).filter(Boolean),
                            data_portfolio: portfolio.checked, data_own_projects: ownProjects.checked })),
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
            const input = el("input", { type: "number", min: s.min, max: s.max, value: s.value, "aria-label": s.description || s.key });
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
    const fields = [["legal_name", "Razão social"], ["display_name", "Nome de exibição (ao lado da marca do ANA e nos documentos; vazio = razão social)"],
                    ["tax_id", "CNPJ (numérico ou alfanumérico)"], ["address", "Endereço"],
                    ["city", "Cidade"], ["state", "UF"], ["email", "E-mail"], ["phone", "Telefone"],
                    ["latitude", "Latitude (ex.: -23,5505)"], ["longitude", "Longitude (ex.: -46,6333)"],
                    ["public_url", "Endereço público do ERP (ex.: https://erp.empresa.com.br) — usado nos links enviados a clientes"]];
    const inputs = Object.fromEntries(fields.map(([k]) => [k, el("input", { value: c[k] || "" })]));
    // Spec 043 (D4): fiscal data of the company (the same rules as the partners, checked by the database).
    const choose = (key, options) => {
      const s = el("select", {}, el("option", { value: "", text: "— não informado —" }), options.map(([v, l]) => el("option", { value: v, text: l })));
      s.value = c[key] || "";
      return s;
    };
    inputs.state_registration = el("input", { value: c.state_registration || "", placeholder: "só números ou ISENTO" });
    inputs.icms_taxpayer = choose("icms_taxpayer", [["taxpayer", "Contribuinte"], ["exempt", "Isento"], ["non_taxpayer", "Não contribuinte"]]);
    inputs.municipal_registration = el("input", { value: c.municipal_registration || "" });
    inputs.tax_regime = choose("tax_regime", [["simples", "Simples Nacional"], ["simples_excess", "Simples Nacional — excesso de sublimite"],
      ["presumed", "Lucro Presumido"], ["real", "Lucro Real"], ["mei", "MEI"], ["public", "Órgão público"], ["nonprofit", "Entidade sem fins lucrativos"]]);
    const fiscal = [["state_registration", "Inscrição estadual"], ["icms_taxpayer", "Contribuinte do ICMS"],
                    ["municipal_registration", "Inscrição municipal"], ["tax_regime", "Regime tributário"]];
    main().replaceChildren(
      ...header("Empresa", "Dados da empresa usados em documentos e no título do Estúdio. As coordenadas servem para distâncias até os clientes; o endereço público aparece nos links de download enviados a clientes e fornecedores."),
      el("form", { class: "form-card", onsubmit: async (e) => {
        e.preventDefault();
        await guard(async () => {
          const body = Object.fromEntries(Object.entries(inputs).map(([k, i]) => [k, i.value || null]));
          await API.admin.saveCompany(body);
          toast("Dados da empresa salvos.");
          window.AnaStudio && window.AnaStudio.refreshTitle(body.display_name || body.legal_name);
        });
      } }, fields.map(([k, label]) => field(label, inputs[k])),
        el("h3", { text: "Dados fiscais" }),
        el("p", { class: "muted", text: "CNPJ (numérico ou alfanumérico), inscrição estadual pelo formato da UF e coerência com o indicador do ICMS são conferidos ao salvar. O motor de impostos usa estes dados." }),
        fiscal.map(([k, label]) => field(label, inputs[k])),
        el("div", { class: "row-buttons" }, el("button", { class: "primary", type: "submit", text: "Salvar" }))),
      logoCard(c));
  }

  // Spec 009 (D11): any image becomes a small JPEG in the browser (white background, at most 480×160).
  function toJpeg(file) {
    return new Promise((resolve, reject) => {
      const img = new Image();
      img.onload = () => {
        const scale = Math.min(1, 480 / img.width, 160 / img.height);
        const cv = document.createElement("canvas");
        cv.width = Math.max(1, Math.round(img.width * scale)); cv.height = Math.max(1, Math.round(img.height * scale));
        const ctx = cv.getContext("2d");
        ctx.fillStyle = "#fff"; ctx.fillRect(0, 0, cv.width, cv.height);
        ctx.drawImage(img, 0, 0, cv.width, cv.height);
        URL.revokeObjectURL(img.src);
        resolve(cv.toDataURL("image/jpeg", 0.88).split(",")[1]);
      };
      img.onerror = () => reject(new Error("imagem ilegível"));
      img.src = URL.createObjectURL(file);
    });
  }

  function logoCard(c) {
    const preview = el("img", { class: "logo-preview", alt: "logotipo atual", hidden: !c.has_logo });
    if (c.has_logo) preview.src = "/api/company/logo?v=" + Date.now();
    const input = el("input", { type: "file", accept: "image/*", onchange: () => guard(async () => {
      if (!input.files[0]) return;
      const logo = await toJpeg(input.files[0]);
      await API.admin.saveLogo(logo);
      toast("Logotipo salvo: aparece no topo e nos documentos.");
      company();
      window.AnaStudio && window.AnaStudio.refreshTitle(c.display_name || c.legal_name, true);
    }) });
    return el("div", { class: "form-card" },
      el("h3", { text: "Logotipo" }),
      el("p", { class: "muted", text: "Fica ao lado da marca do ANA, no topo do Estúdio, e no timbre dos PDFs (pedidos, faturas, recibos). Qualquer imagem serve: o navegador a reduz e converte." }),
      preview, field("Escolher imagem", input),
      c.has_logo ? el("div", { class: "row-buttons" }, el("button", { type: "button", class: "danger", text: "Remover logotipo", onclick: () => guard(async () => {
        if (!confirm("Remover o logotipo?")) return;
        await API.admin.saveLogo(null); toast("Logotipo removido."); company();
        window.AnaStudio && window.AnaStudio.refreshTitle(c.display_name || c.legal_name, false);
      }) })) : null);
  }

  // ------------------------------------------------------------------ commands
  async function commands() {
    const [list, programs] = await Promise.all([API.commands(), API.programs(false)]);
    const code = el("input", { "aria-label": "ex.: logtime", placeholder: "ex.: logtime" });
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
    const name = el("input", { "aria-label": "ex.: matriz", placeholder: "ex.: matriz" });
    const url = el("input", { "aria-label": "https://erp.exemplo.com", placeholder: "https://erp.exemplo.com" });
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
        ], list, { emptyAction: toForm("Cadastrar um sistema remoto"), onRow: (s) => { name.value = s.name; url.value = s.url; username.value = s.username || ""; timeout.value = s.timeout_ms; active.checked = s.active; password.value = ""; } })),
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
            const input = el("input", { value: a.account, placeholder: "ex.: 1.1.2", "aria-label": `Nova conta para ${a.description}` });
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
    const target = el("input", { "aria-label": "user | developer | admin | nome do grupo", placeholder: "user | developer | admin | nome do grupo", list: "limit-targets" });
    const targets = el("datalist", { id: "limit-targets" },
      ["user", "developer", "admin", ...groupsList.map((g) => g.name)].map((t) => el("option", { value: t })));
    const inputs = Object.fromEntries(LIMIT_KEYS.map((k) => [k, el("input", { type: "number", min: 0, placeholder: k, "aria-label": k })]));
    const fill = (p) => {
      kind.value = p.target_kind; target.value = p.target;
      for (const k of LIMIT_KEYS) inputs[k].value = p.limits[k] ?? "";
    };
    const quotaUser = el("input", { "aria-label": "login", placeholder: "login" });
    const quotaMax = el("input", { type: "number", min: 0, placeholder: "simultâneas", "aria-label": "simultâneas" });
    const quotaRate = el("input", { type: "number", min: 0, placeholder: "por minuto", "aria-label": "por minuto" });

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
        ], profiles, { onRow: fill, empty: "Nenhum perfil: valem os padrões e tetos globais.",
                       emptyAction: { label: "Criar um perfil", onClick: () => target.focus() } })),
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
      ], m.running, { empty: "Nenhuma execução em andamento.", emptyAction: { label: "Ver as execuções recentes", href: "#/admin/audit" } }));
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
    const fields = inputs.map(([k, label]) => [k, el("input", { placeholder: label, "aria-label": label, value: filters[k] || "" })]);
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
      kind === "trail" && !filters.username ? el("p", { class: "muted", text: "Informe o usuário (ou abra pela ficha dele em Usuários → Ver trilha)." }) : table(columns, rows, { onRow, screen: "admin.audit." + kind, title: "Registros" }),
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
      const i = el("input", { type: "number", min: s.min ?? 1, max: s.max ?? 36500, value: c.days, class: "num-input", "aria-label": `Dias de retenção: ${c.label}` });
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
      ], r.last_purges, { empty: "Nenhum expurgo ainda.", emptyGood: true }),
      out);
  }

  // ------------------------------------------------------------------ observability (spec 019)
  const STATE = { green: ["●", "normal", "ok"], yellow: ["▲", "atenção", "warn"], red: ["■", "falha", "off"] };
  const SEVERITY = { info: ["ℹ", "informação", ""], warning: ["▲", "atenção", "warn"], serious: ["◆", "sério", "off"], critical: ["■", "crítico", "off"] };
  const COMPONENT = { database: "Banco de dados", pool_core: "Conexões do núcleo", pool_programs: "Conexões dos programas",
    python: "Processos Python", scheduler: "Agendamento", access_log: "Registro de acessos", remote_systems: "Sistemas remotos", integrations: "Integrações",
    public_api: "API pública" };
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
      el("p", { class: "muted", text: "Abertos pelas regras de alerta (veja Alertas). Silenciados ficam registrados, mas só avisam quando o silêncio termina." }),
      table([
        { label: "Regra", value: (i) => i.rule || "—" },
        { label: "Gravidade", value: (i) => sevChip(i.severity) },
        { label: "Alvo", value: (i) => COMPONENT[i.component] || METRIC[i.component] || i.component },
        { label: "Nó", value: (i) => i.node },
        { label: "Início", value: (i) => fmtDate(i.opened_at) },
        { label: "Fim", value: (i) => i.closed_at ? fmtDate(i.closed_at) : pill("■ aberto", "off") },
        { label: "Duração", value: (i) => `${Math.round(i.seconds / 60)} min`, class: "num" },
        { label: "Mensagem", value: (i) => i.silenced && !i.notified_at ? el("span", {}, pill("silenciado"), " ", i.message) : i.message },
      ], h.incidents, { empty: "Nenhum incidente.", emptyGood: true }),
      el("h3", { text: "Mudanças de estado (72 h)" }),
      table([
        { label: "Quando", value: (e) => fmtDate(e.at) },
        { label: "Componente", value: (e) => COMPONENT[e.component] || e.component },
        { label: "Estado", value: (e) => stateChip(e.state) },
        { label: "Mensagem", value: (e) => e.message },
        { label: "Nó", value: (e) => e.node },
      ], h.events, { empty: "Nenhuma mudança." }));
  }

  const METRIC = { running: "Execuções em andamento", failures_per_min: "Falhas por minuto", memory_mb: "Memória do núcleo (MB)",
    processes: "Processos Erlang", db_waiting: "Esperando conexão com o banco", python_ready: "Processos Python prontos",
    max_message_queue: "Maior fila de mensagens no núcleo", wal_mb_per_hour: "Escrita de WAL no banco (MB/h)",
    temp_mb_per_hour: "Arquivos temporários do banco (MB/h)" };
  const LEVEL = { yellow: "amarelo ou pior", red: "vermelho" };

  // RF-019-08 (T-019-08b): alert rules (threshold, window, destinations) and silences.
  async function alerts() {
    const a = await API.admin.alerts();
    const targetName = (r) => r.source === "health" ? (r.target === "*" ? "qualquer componente" : COMPONENT[r.target] || r.target)
      : METRIC[r.target] || r.target;
    const condition = (r) => r.source === "health" ? `${targetName(r)} em ${LEVEL[r.level] || r.level}`
      : `${targetName(r)} ${r.op} ${r.threshold_value ? "valor da empresa " + r.threshold_value : n2(r.threshold)}`;
    const destinations = (r) => [r.notify_studio ? "Estúdio" : null, r.connector ? `conector ${r.connector}` : null,
      (r.recipients || []).length ? `${r.recipients.length} e-mail(s)` : null].filter(Boolean).join(", ") || "nenhum";
    const opt = (v, t) => el("option", { value: v, text: t });

    const id = el("input", { type: "hidden" });
    const name = el("input", { "aria-label": "Ex.: Memória alta", placeholder: "Ex.: Memória alta" });
    const source = el("select", {}, opt("health", "Saúde de componente"), opt("metric", "Métrica do nó"));
    const target = el("select");
    const level = el("select", {}, opt("red", "vermelho"), opt("yellow", "amarelo ou pior"));
    const op = el("select", {}, [">", ">=", "<", "<="].map((o) => opt(o, o)));
    const threshold = el("input", { type: "number", step: "any", placeholder: "limiar" });
    // Spec 065 (T-065-07): or a company value, read at each check (changing it changes the rule, no edit here).
    const thresholdValue = el("input", { placeholder: "ou o nome de um valor da empresa (ex.: ti.memoria_maxima_mb)", "aria-label": "Valor da empresa do limiar" });
    const windowS = el("input", { type: "number", min: 0, max: 86400, value: 0 });
    const severity = el("select", {}, Object.entries(SEVERITY).map(([k, v]) => opt(k, v[1])));
    const studio = el("input", { type: "checkbox", checked: true });
    const connector = el("select", {}, opt("", "— nenhum —"), a.connectors.map((c) => opt(c.name, c.description ? `${c.name} — ${c.description}` : c.name)));
    const recipients = el("textarea", { rows: 2, placeholder: "e-mails separados por vírgula (entregues pelo conector)" });
    const active = el("input", { type: "checkbox", checked: true });
    const healthOnly = [field("Nível", level)];
    const metricOnly = [field("Comparação", op), field("Limiar", threshold), field("Limiar por valor da empresa", thresholdValue)];
    const sync = () => {
      const h = source.value === "health";
      const keep = target.value;
      target.replaceChildren(...(h ? [opt("*", "qualquer componente"), ...a.components.map((c) => opt(c, COMPONENT[c] || c))]
        : a.metrics.map((m) => opt(m, METRIC[m] || m))));
      if ([...target.options].some((o) => o.value === keep)) target.value = keep;
      for (const f of healthOnly) f.hidden = !h;
      for (const f of metricOnly) f.hidden = h;
    };
    source.onchange = sync;
    const fill = (r) => {
      id.value = r ? r.id : ""; name.value = r ? r.name : ""; source.value = r ? r.source : "health"; sync();
      target.value = r ? r.target : "*"; level.value = (r && r.level) || "red"; op.value = (r && r.op) || ">";
      threshold.value = r && r.threshold != null ? r.threshold : ""; windowS.value = r ? r.window_s : 0;
      thresholdValue.value = (r && r.threshold_value) || "";
      severity.value = r ? r.severity : "warning"; studio.checked = r ? r.notify_studio : true;
      connector.value = (r && r.connector) || ""; recipients.value = r ? (r.recipients || []).join(", ") : "";
      active.checked = r ? r.active : true;
    };
    fill(null);

    const silRule = el("select", { "aria-label": "Regra a silenciar" }, opt("", "todas as regras"), a.rules.map((r) => opt(r.id, r.name)));
    const silTarget = el("input", { "aria-label": "alvo (vazio = todos)", placeholder: "alvo (vazio = todos)", list: "alert-targets" });
    const silTargets = el("datalist", { id: "alert-targets" }, [...a.components, ...a.metrics].map((t) => opt(t, COMPONENT[t] || METRIC[t] || t)));
    const silNode = el("input", { "aria-label": "nó (vazio = todos)", placeholder: "nó (vazio = todos)" });
    const silMinutes = el("input", { type: "number", min: 1, max: 43200, value: 60 });
    const silReason = el("input", { "aria-label": "motivo (ex.: manutenção do banco)", placeholder: "motivo (ex.: manutenção do banco)" });

    main().replaceChildren(
      ...header("Alertas", "Regras sobre a saúde dos componentes e as métricas de cada nó. A condição precisa durar a janela inteira para abrir um incidente; ele se encerra sozinho quando a condição passa. Silêncios mantêm o registro, mas não avisam ninguém."),
      el("div", { class: "admin-columns" },
        el("div", {}, table([
          { label: "Regra", value: (r) => r.name },
          { label: "Condição", value: condition },
          { label: "Janela", value: (r) => r.window_s ? `${r.window_s} s` : "imediata", class: "num" },
          { label: "Gravidade", value: (r) => sevChip(r.severity) },
          { label: "Destinos", value: destinations },
          { label: "Situação", value: (r) => !r.active ? pill("inativa") : Number(r.open) ? pill(`■ ${r.open} aberto(s)`, "off") : pill("● ativa", "ok") },
          { label: "", value: (r) => el("div", { class: "cell-actions" }, el("button", { class: "danger small", text: "Remover", onclick: (e) => guard(async () => {
              e.stopPropagation();
              if (!confirm(`Remover a regra ${r.name}? Os incidentes continuam no histórico.`)) return;
              await API.admin.deleteAlertRule(r.id);
              await alerts();
            }) })) },
        ], a.rules, { onRow: fill, empty: "Nenhuma regra: nenhum incidente será aberto." })),
        el("form", { class: "form-card", onsubmit: async (e) => {
          e.preventDefault();
          const h = source.value === "health";
          const body = { id: id.value ? Number(id.value) : null, name: name.value.trim(), source: source.value, target: target.value,
            level: h ? level.value : null, op: h ? null : op.value, threshold: h || threshold.value === "" ? null : Number(threshold.value),
            threshold_value: h || !thresholdValue.value.trim() ? null : thresholdValue.value.trim(),
            window_s: parseInt(windowS.value || "0", 10), severity: severity.value, notify_studio: studio.checked,
            connector: connector.value || null, active: active.checked,
            recipients: recipients.value.split(/[,;\s]+/).map((x) => x.trim()).filter(Boolean) };
          await guard(async () => {
            await API.admin.saveAlertRule(body);
            toast("Regra de alerta salva.");
            await alerts();
          });
        } }, el("h3", { text: "Regra de alerta" }), id, field("Nome", name), field("Origem", source), field("Observa", target),
          ...healthOnly, ...metricOnly, field("Janela (segundos)", windowS), field("Gravidade", severity),
          check("Avisar no Estúdio", studio), field("Conector (webhook ou e-mail)", connector), field("Destinatários", recipients),
          check("Ativa", active),
          el("div", { class: "row-buttons" }, el("button", { class: "primary", type: "submit", text: "Salvar" }),
            el("button", { type: "button", text: "Nova", onclick: () => fill(null) })))),
      el("h3", { text: "Silêncios" }),
      el("form", { class: "admin-toolbar", onsubmit: async (e) => {
        e.preventDefault();
        await guard(async () => {
          await API.admin.createSilence({ rule_id: silRule.value ? Number(silRule.value) : null, target: silTarget.value.trim() || null,
            node: silNode.value.trim() || null, minutes: parseInt(silMinutes.value || "0", 10), reason: silReason.value.trim() });
          toast("Silêncio criado.");
          await alerts();
        });
      } }, silRule, silTarget, silTargets, silNode, field("Minutos", silMinutes), silReason, el("button", { type: "submit", text: "Silenciar" })),
      table([
        { label: "Regra", value: (x) => x.rule || "todas" },
        { label: "Alvo", value: (x) => x.target ? COMPONENT[x.target] || METRIC[x.target] || x.target : "todos" },
        { label: "Nó", value: (x) => x.node || "todos" },
        { label: "De", value: (x) => fmtDate(x.starts_at) },
        { label: "Até", value: (x) => fmtDate(x.ends_at) },
        { label: "Motivo", value: (x) => x.reason },
        { label: "Por", value: (x) => x.created_by },
        { label: "", value: (x) => x.in_force ? el("div", { class: "cell-actions" }, el("button", { class: "small", text: "Encerrar", onclick: () => guard(async () => {
            await API.admin.endSilence(x.id);
            await alerts();
          }) })) : pill("encerrado") },
      ], a.silences, { empty: "Nenhum silêncio nos últimos 7 dias.", emptyAction: { label: "Silenciar uma regra", onClick: () => silRule.focus() } }));
  }

  // Spec 062 (D6): a read-only look inside the running core.
  async function core() {
    const c = await API.admin.core();
    const procTable = (title, rows, key, label) => el("div", {}, el("h3", { text: title }), table([
      { label: "Processo", value: (p) => p.name },
      { label, value: (p) => n2(p[key]), class: "num" },
      { label: "Em", value: (p) => el("code", { text: p.current }) },
    ], rows, { empty: "Nenhum processo com fila de mensagens agora.",
               emptyAction: { label: "Atualizar", onClick: () => guard(core) } }));
    const dropped = Object.entries(c.dropped || {});
    main().replaceChildren(
      ...header("Núcleo", "Dentro do núcleo em execução: memória, processos, filas de mensagens, áreas supervisionadas e reinícios da última hora. Só leitura; uma fila crescendo pode virar alerta (métrica \"Maior fila de mensagens no núcleo\")."),
      el("div", { class: "row-buttons" }, el("button", { text: "Atualizar", onclick: () => guard(core) })),
      el("div", { class: "stat-grid" },
        ...[["Memória total", `${c.memory_mb.total} MB`], ["Processos (memória)", `${c.memory_mb.processes} MB`],
            ["ETS", `${c.memory_mb.ets} MB`], ["Processos", n2(c.processes)], ["Fila de execução", n2(c.run_queue)],
            ["Agendadores", n2(c.schedulers)], ["Nós", c.nodes.join(", ")]]
          .map(([l, v]) => el("div", { class: "stat" }, el("div", { class: "label", text: l }), el("div", { class: "value", text: v })))),
      el("h3", { text: "Áreas supervisionadas" }),
      table([
        { label: "Área", value: (a) => ({ ana_base_sup: "Base", ana_exec_area_sup: "Execução", ana_work_sup: "Trabalho de fundo",
                                          ana_observe_sup: "Observação" })[a.area] || a.area },
        { label: "Processos", value: (a) => a.children.map((x) => x.id).join(", ") },
        { label: "Situação", value: (a) => a.children.every((x) => x.alive) ? pill("● todos ativos", "ok") : pill("▲ algum parado", "warn") },
      ], c.areas),
      el("h3", { text: "Reinícios na última hora" }),
      table([{ label: "Quando", value: (r) => fmtDate(new Date(r.at * 1000).toISOString()) }, { label: "Área", value: (r) => r.area },
             { label: "Processo", value: (r) => r.child }], c.restarts,
            { empty: "Nenhum reinício: tudo estável.", emptyAction: { label: "Atualizar", onClick: () => guard(core) } }),
      dropped.length ? el("p", { class: "muted", text: "Registros descartados por fila cheia: " + dropped.map(([k, v]) => `${k}: ${v}`).join(", ") }) : null,
      el("div", { class: "admin-columns" },
        procTable("Mais memória", c.top_memory, "memory_kb", "KB"),
        procTable("Mais trabalho", c.top_reductions, "reductions", "Reduções")),
      procTable("Filas de mensagens", c.top_queue, "queue", "Mensagens"));
  }

  // Spec 063 (D3; P15): how much the database writes, who wrote it and how long the SSD lasts at this pace.
  const mb = (b) => (b === null || b === undefined ? "—" : (b >= 1e9 ? `${n2(b / 1e9)} GB` : `${n2(b / 1e6)} MB`));
  async function disk() {
    const d = await API.admin.disk();
    const lh = d.last_hour || {};
    const budget = d.budget || {};
    const idleBudget = budget.idle_wal_bytes_per_hour;
    const perHour = lh.minutes ? (lh.wal_bytes || 0) * 60 / lh.minutes : null;
    const p = d.projection || {};
    const ck = d.checkpoints || {};
    const stat = (l, v, sub) => el("div", { class: "stat" }, el("div", { class: "label", text: l }), el("div", { class: "value", text: v }),
      sub ? el("div", { class: "sub", text: sub }) : null);
    const within = idleBudget && perHour !== null ? (perHour <= idleBudget * (1 + (budget.tolerance || 0))
      ? pill("● dentro do orçamento de ocioso", "ok") : pill("▲ acima do orçamento de ocioso", "warn")) : null;
    const tbw = el("input", { type: "number", min: "0", step: "1", "aria-label": "Resistência do SSD (TBW, em TB)",
                              value: p.informed ? String(p.tbw_tb) : "" });
    const used = el("input", { type: "number", min: "0", max: "100", step: "1", "aria-label": "Desgaste já usado (%)",
                               value: p.informed ? String(p.used_pct) : "0" });
    const saveTbw = () => guard(async () => {
      await API.admin.saveSetting("disk_tbw_tb", Number(tbw.value || 0));
      await API.admin.saveSetting("disk_used_pct", Number(used.value || 0));
      toast("Resistência do disco salva.");
      await disk();
    });
    const projection = p.informed
      ? (p.years_left === null ? "sem escrita medida ainda" : `${n2(p.years_left)} anos no ritmo atual`)
      : "informe a resistência do SSD";
    const days = d.days || [];
    main().replaceChildren(
      ...header("Disco", "Quanto o banco de dados grava (WAL, páginas de dados e arquivos temporários), quem mais escreveu e quanto tempo o SSD dura neste ritmo. A medição só lê estatísticas do PostgreSQL; uma hora sem escrita não grava nada."),
      el("div", { class: "row-buttons" }, el("button", { text: "Atualizar", onclick: () => guard(disk) })),
      el("div", { class: "stat-grid" },
        stat("Última hora", mb((lh.wal_bytes || 0) + (lh.data_bytes || 0) + (lh.temp_bytes || 0)),
             lh.minutes ? `WAL ${mb(lh.wal_bytes)} · dados ${mb(lh.data_bytes)} · temporários ${mb(lh.temp_bytes)} em ${lh.minutes} min` : "medindo…"),
        stat("Ritmo de WAL agora", `${n2((d.rates || {}).wal_mb_per_hour)} MB/h`, "últimos 5 minutos; pode virar alerta"),
        stat("Média por dia", days.length ? mb(days.slice(0, Math.max(1, days.length - 1)).reduce((a, x) => a + x.total_bytes, 0) / Math.max(1, days.length - 1)) : "—",
             days.length ? `${days.length} dia(s) medidos` : "o primeiro dia aparece após uma hora com escrita"),
        stat("Vida útil restante", projection, p.informed ? `TBW ${n2(p.tbw_tb)} TB, ${n2(p.used_pct)}% já usado${d.disk_health ? " (lido do disco)" : ""}` : null),
        stat("Checkpoints", `${n2(ck.checkpoints_timed)} programados · ${n2(ck.checkpoints_req)} forçados`,
             `max_wal_size ${ck.max_wal_size} · intervalo ${ck.checkpoint_timeout}`),
        stat("Tamanho", mb((d.sizes || {}).database_bytes), `banco · repositório de arquivos ${mb((d.sizes || {}).files_bytes)}`)),
      within ? el("p", {}, within, el("span", { class: "muted", text: ` Orçamento de ocioso: ${mb(idleBudget)} de WAL por hora (versão ${budget.version}).` })) : null,
      days.length >= 2 ? window.AnaCharts.render({ type: "stacked", title: "Escrita por dia", subtitle: "últimos 35 dias", format: "number", unit: "MB",
        x: days.map((x) => x.day), series: [{ name: "WAL", values: days.map((x) => Math.round(x.wal_bytes / 1e6)) },
                                            { name: "Páginas de dados", values: days.map((x) => Math.round(x.data_bytes / 1e6)) },
                                            { name: "Temporários", values: days.map((x) => Math.round(x.temp_bytes / 1e6)) }] }) : null,
      el("h3", { text: "Resistência do SSD" }),
      d.disk_health ? el("p", {}, d.disk_health.healthy === false ? pill("■ o disco indica falha: troque-o", "off") : pill("● disco saudável", "ok"),
        el("span", { class: "muted", text: ` ${d.disk_health.model || d.disk_health.device || "disco"}: ${d.disk_health.used_pct ?? "—"}% da vida útil usada${d.disk_health.written_bytes ? `, ${mb(d.disk_health.written_bytes)} gravados no total` : ""} — lido por ana-ctl em ${fmtDate(d.disk_health.at)}.` }))
        : el("p", { class: "muted", text: "Para o ERP ler o desgaste do próprio SSD, rode \"ana-ctl disk\" como root no servidor (precisa do smartmontools); a leitura aparece aqui." }),
      el("p", { class: "muted", text: "O fabricante informa o TBW (terabytes que podem ser gravados) na ficha do disco. Com ele e a escrita média por dia, o painel projeta quando planejar a troca." }),
      el("div", { class: "form-grid" }, el("label", {}, "TBW (TB)", tbw), el("label", {}, "Já usado (%)", used),
        el("div", { class: "row-buttons" }, el("button", { text: "Salvar", onclick: saveTbw }))),
      el("div", { class: "admin-columns" },
        el("div", {}, el("h3", { text: "Tabelas que mais mudaram na última hora" }), table([
          { label: "Tabela", value: (t) => el("code", { text: t.table }) }, { label: "Linhas", value: (t) => n2(t.rows), class: "num" }],
          lh.tables || [], { empty: "Nada mudou na última hora.", emptyAction: { label: "Atualizar", onClick: () => guard(disk) } })),
        el("div", {}, el("h3", { text: "Programas que mais escreveram" }), table([
          { label: "Programa", value: (t) => t.program }, { label: "Tabela", value: (t) => el("code", { text: t.table }) },
          { label: "Linhas", value: (t) => n2(t.rows), class: "num" }],
          lh.programs || [], { empty: "Nenhum programa escreveu na última hora.", emptyAction: { label: "Atualizar", onClick: () => guard(disk) } }))),
      el("h3", { text: "Escrita por tipo de processo (desde o início das estatísticas)" }),
      table([
        { label: "Processo", value: (r) => r.backend_type }, { label: "Objeto", value: (r) => r.object }, { label: "Contexto", value: (r) => r.context },
        { label: "Gravado", value: (r) => mb(r.write_bytes), class: "num" }, { label: "Crescimento de arquivo", value: (r) => mb(r.extend_bytes), class: "num" }],
        d.io || [], { empty: "Sem escrita registrada." }),
      el("h3", { text: "Tabelas que mais cresceram (30 dias)" }),
      table([{ label: "Tabela", value: (g) => el("code", { text: g.table_name }) }, { label: "Tamanho", value: (g) => mb(g.bytes), class: "num" },
             { label: "Crescimento", value: (g) => mb(g.growth_bytes), class: "num" }],
        d.growth || [], { empty: "O crescimento aparece depois da primeira análise diária.", emptyGood: true }),
      el("h3", { text: "Sugestões para o servidor" }),
      el("p", { class: "muted", text: "O ERP nunca muda a configuração do sistema operacional nem desliga proteções do banco (fsync, full_page_writes): só sugere." }),
      el("ul", {}, (d.suggestions || []).map((t) => el("li", { text: t }))));
  }

  // Spec 050 (T-050-03, P18): how long screens take to open in the browsers, against the 1 s budget.
  async function uiperf(days = 7) {
    const rows = await API.admin.uiPerf(days);
    const ms = (v) => (v === null || v === undefined ? "> 5000" : n2(v));
    const opens = rows.filter((r) => r.kind === "open").sort((a, b) => (b.p95_ms ?? 1e9) - (a.p95_ms ?? 1e9));
    const top = opens.slice(0, 10);
    const period = el("select", { "aria-label": "Período" }, [[1, "Hoje"], [7, "Últimos 7 dias"], [30, "Últimos 30 dias"]]
      .map(([v, l]) => el("option", { value: v, text: l })));
    period.value = String(days);
    period.addEventListener("change", () => guard(() => uiperf(Number(period.value))));
    main().replaceChildren(
      ...header("Desempenho das telas", "Quanto cada tela leva para abrir e quanto duram as chamadas dela, medido nos navegadores de quem usa. Orçamento: 95 % das aberturas em até 1 s; acima disso vira apontamento nas Verificações."),
      el("div", { class: "admin-toolbar" }, period),
      top.length ? window.AnaCharts.render({ type: "bar", title: "Telas mais lentas para abrir (p95)", format: "number", unit: "ms",
        x: top.map((r) => r.screen), series: [{ name: "p95", values: top.map((r) => r.p95_ms ?? 5000) }] }) : null,
      table([
        { label: "Tela", value: (r) => r.screen },
        { label: "Medida", value: (r) => (r.kind === "open" ? "abrir a tela" : "chamadas ao servidor") },
        { label: "Amostras", value: (r) => n2(r.samples), class: "num" },
        { label: "Média (ms)", value: (r) => n2(r.avg_ms), class: "num" },
        { label: "p50 (ms)", value: (r) => ms(r.p50_ms), class: "num" },
        { label: "p95 (ms)", value: (r) => r.kind === "open" && (r.p95_ms === null || r.p95_ms > r.budget_ms)
            ? pill(`▲ ${ms(r.p95_ms)}`, "warn") : ms(r.p95_ms), class: "num" },
        { label: "Travamentos", value: (r) => n2(r.long_tasks), class: "num" },
      ], rows, { emptyGood: true, empty: "Ainda sem medições: as telas se medem sozinhas enquanto as pessoas usam o Estúdio.",
                 emptyAction: { label: "Atualizar", onClick: () => guard(() => uiperf(days)) } }));
  }

  async function sqlperf(filters = { order: "total" }) {
    const rows = await API.admin.obsSql(filters);
    const detail = el("div");
    const program = el("input", { "aria-label": "Programa (opcional)", placeholder: "Programa (opcional)", value: filters.program || "" });
    const order = el("select", { "aria-label": "Ordenar por" }, [["total", "Tempo total"], ["mean", "Tempo médio"], ["max", "Tempo máximo"], ["calls", "Chamadas"]]
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
      ], rows, { empty: "Ainda sem medições: execute programas e grave as do último minuto.", emptyAction: pressing("Atualizar agora", "Atualizar agora"), onRow: (r) => sqlDetail(r.hash, detail) }),
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

  // ------------------------------------------------------------------ periodic checks (spec 033)
  const CHECK_CATEGORIES = { security: "Segurança", dependencies: "Componentes", integrity: "Integridade",
                             robustness: "Robustez", performance: "Desempenho" };
  const SEV_ORDER = ["critical", "serious", "warning", "info"];

  async function checks(tab = "findings", filter = { status: "open", category: "" }) {
    const tabs = el("div", { class: "sub-tabs" }, [["findings", "Achados"], ["inventory", "Inventário e vulnerabilidades"], ["notify", "Avisos e base automática"]]
      .map(([k, l]) => el("button", { class: k === tab ? "active" : "", text: l, onclick: () => guard(() => checks(k, filter)) })));
    const head = header("Verificações", "Segurança da configuração, componentes com vulnerabilidade conhecida, integridade dos arquivos, " +
      "robustez (cópias, filas, erros) e desempenho, verificados periodicamente pelo robô system. Missão crítica: o que é crítico vira aviso no sino.");
    if (tab === "inventory") return checksInventory(head, tabs, filter);
    if (tab === "notify") return checksConfig(head, tabs);
    const [data, notices] = await Promise.all([API.admin.checks(filter), API.admin.notices(true).catch(() => [])]);
    const counts = {};
    for (const c of data.counts) (counts[c.category] = counts[c.category] || {})[c.severity] = c.n;
    const runs = Object.fromEntries(data.runs.map((r) => [r.category, r]));
    const runBtn = (category, label) => el("button", { type: "button", class: category === "all" ? "" : "quiet small", text: label,
      onclick: (e) => { e.stopPropagation(); guard(async () => {
        e.target.disabled = true;
        const r = await API.admin.checksRun(category);
        toast(`${r.found} achado(s), ${r.resolved} resolvido(s).`);
        checks(tab, filter);
      }); } });
    const cards = el("div", { class: "check-grid" }, data.categories.map((c) => {
      const cc = counts[c] || {};
      const worst = SEV_ORDER.find((s) => cc[s]);
      const total = SEV_ORDER.reduce((n, s) => n + (cc[s] || 0), 0);
      const r = runs[c];
      return el("div", { class: "check-card" + (filter.category === c ? " active" : "") + (worst ? " sev-" + worst : " sev-ok"),
                         role: "button", tabindex: "0", title: "Filtrar por " + CHECK_CATEGORIES[c],
                         onclick: () => guard(() => checks(tab, { ...filter, category: filter.category === c ? "" : c })) },
        el("div", { class: "check-title", text: CHECK_CATEGORIES[c] || c }),
        el("div", { class: "check-value", text: total ? String(total) : "ok" }),
        el("div", { class: "check-sev" }, ...SEV_ORDER.filter((s) => cc[s]).map((s) => el("span", {}, sevChip(s), ` ${cc[s]}`))),
        el("div", { class: "muted small", text: r ? `${r.status === "success" ? "verificado" : "falhou"} ${fmtDate(r.finished_at || r.started_at)}` : "ainda não verificado" }),
        runBtn(c, "Verificar"));
    }));
    const noticeBox = notices.length ? el("div", { class: "notice-box" },
      el("strong", { text: `${notices.length} aviso(s) novo(s)` }),
      el("ul", {}, notices.map((n) => el("li", {}, sevChip(n.severity), " ", n.message, el("span", { class: "muted small", text: " · " + fmtDate(n.created_at) })))),
      el("button", { type: "button", class: "small", text: "Marcar como lidos", onclick: () => guard(async () => {
        for (const n of notices) await API.admin.noticeRead(n.id);
        checks(tab, filter);
      }) })) : null;
    const status = el("div", { class: "sub-tabs" }, [["open", "Abertos"], ["dismissed", "Dispensados"], ["resolved", "Resolvidos"]].map(([k, l]) =>
      el("button", { class: k === filter.status ? "active" : "", text: l, onclick: () => guard(() => checks(tab, { ...filter, status: k })) })));
    const list = data.findings.length ? el("div", {}, data.findings.map((a) => {
      const card = adviceCard(a);
      card.querySelector(".advice-head").append(pill(CHECK_CATEGORIES[a.category] || a.category, ""));
      if (filter.status === "open") card.append(el("div", { class: "row-buttons" },
        el("button", { type: "button", class: "quiet small", text: "Dispensar por 30 dias", onclick: () => guard(async () => { await API.admin.adviceDismiss(a.id, 30); checks(tab, filter); }) }),
        el("button", { type: "button", class: "quiet small", text: "Dispensar sempre", onclick: () => guard(async () => { await API.admin.adviceDismiss(a.id, 0); checks(tab, filter); }) })));
      card.append(el("div", { class: "muted small", text: `${a.rule} · desde ${fmtDate(a.first_seen)} · visto ${fmtDate(a.last_seen)}` }));
      return card;
    })) : el("p", { class: "muted", text: filter.status === "open" ? "Nenhum achado aberto" + (filter.category ? " nesta categoria." : ". Bom sinal.") : "Nada aqui." });
    main().replaceChildren(...head, tabs, noticeBox || "", el("div", { class: "row-buttons" }, runBtn("all", "Verificar tudo agora")),
      cards, status, list);
  }

  // T-033-09b: the vulnerability base kept up to date by a connector, and new findings sent by e-mail or chat.
  async function checksConfig(head, tabs) {
    const c = await API.admin.checksConfig();
    const opt = (v, t) => el("option", { value: v, text: t });
    const conn = el("select", {}, opt("", "— só no sino do Estúdio —"),
      c.connectors.map((k) => opt(k.name, `${k.name} (${k.kind === "smtp" ? "e-mail" : "HTTP/chat"})${k.description ? " — " + k.description : ""}`)));
    conn.value = c.notify_connector || "";
    const to = el("input", { value: (c.notify_recipients || []).join(", "), placeholder: "e-mails separados por vírgula (para conector de e-mail)" });
    const min = el("select", {}, [["critical", "só críticos"], ["serious", "sérios e críticos"], ["warning", "atenção, sérios e críticos"]].map(([v, l]) => opt(v, l)));
    min.value = c.notify_min_severity || "critical";
    const feed = c.feed_available
      ? el("div", {},
          el("p", {}, "Conector ", el("code", { text: c.feed_available }), c.feed_at
            ? ` · última atualização ${fmtDate(c.feed_at)}: ` : " · ainda não atualizada",
            c.feed_at ? (c.feed_ok ? pill(`✓ ${c.feed_message}`, "ok") : pill(`■ ${c.feed_message}`, "off")) : ""),
          el("p", { class: "muted small", text: "Atualiza sozinha uma vez por dia, junto com a verificação de dependências." }),
          el("button", { type: "button", text: "Atualizar agora", onclick: (e) => guard(async () => {
            e.target.disabled = true;
            const r = await API.admin.checksFeedRefresh();
            toast(`Base atualizada: ${r.feed_message}. ${r.check.found} achado(s) de dependências.`);
            checks("notify");
          }) }))
      : el("div", {},
          el("p", { text: "Desligada: a base é enviada à mão (aba Inventário). Para atualizar sozinha, crie um conector HTTP com as opções:" }),
          el("pre", { class: "params-json", text: '{"purpose": "osv_feed", "mode": "feed", "path": "/caminho/do/arquivo-osv.json"}\n' +
                                                    'ou, com URL base https://api.osv.dev:\n{"purpose": "osv_feed", "mode": "query"}' }),
          el("button", { type: "button", class: "quiet", text: "Ir para Conectores", onclick: () => location.hash = "#/admin/integrations" }));
    main().replaceChildren(...head, tabs,
      el("div", { class: "admin-columns" },
        el("div", { class: "form-card" }, el("h3", { text: "Base de vulnerabilidades automática" }), feed),
        el("form", { class: "form-card", onsubmit: (e) => { e.preventDefault(); guard(async () => {
          await API.admin.checksSaveConfig({ notify_connector: conn.value || null, notify_min_severity: min.value,
            notify_recipients: to.value.split(/[,;\s]+/).map((x) => x.trim()).filter(Boolean) });
          toast("Avisos configurados.");
          checks("notify");
        }); } },
          el("h3", { text: "Avisos por e-mail ou chat" }),
          el("p", { class: "muted small", text: "Achados novos a partir da gravidade escolhida vão numa só mensagem por verificação. Os críticos continuam também no sino." }),
          field("Conector", conn), field("Destinatários", to), field("Gravidade mínima", min),
          el("div", { class: "row-buttons" }, el("button", { class: "primary", type: "submit", text: "Salvar" })))));
  }

  async function checksInventory(head, tabs, filter) {
    const [inv, found] = await Promise.all([API.admin.checksInventory(), API.admin.checks({ category: "dependencies", status: "open" })]);
    const vulnerable = new Map();
    for (const f of found.findings) if (f.rule === "vulnerable_component" && f.evidence) {
      const k = `${f.evidence.ecosystem}|${f.evidence.package}`;
      vulnerable.set(k, [...(vulnerable.get(k) || []), f]);
    }
    const file = el("input", { type: "file", accept: ".json,application/json", "aria-label": "Arquivo da base OSV" });
    const send = el("button", { type: "button", text: "Importar base", onclick: () => guard(async () => {
      const f = file.files[0];
      if (!f) { toast("Escolha o arquivo JSON da base OSV.", true); return; }
      send.disabled = true;
      try {
        const r = await API.admin.checksImport(f);
        toast(`${r.advisories} aviso(s) importado(s); ${r.findings ?? 0} achado(s) de componentes.`);
        checks("inventory", filter);
      } finally { send.disabled = false; }
    }) });
    const search = el("input", { type: "search", placeholder: "Filtrar componentes…", "aria-label": "Filtrar componentes" });
    const SOURCES = { runtime: "núcleo", image: "imagem", database: "banco" };
    const render = () => {
      const q = search.value.trim().toLowerCase();
      const rows = inv.components.filter((c) => !q || `${c.ecosystem} ${c.name} ${c.version}`.toLowerCase().includes(q))
        .sort((a, b) => (vulnerable.has(`${b.ecosystem}|${b.name}`) - vulnerable.has(`${a.ecosystem}|${a.name}`)));
      box.replaceChildren(table([
        { label: "Componente", value: (c) => c.name },
        { label: "Versão", value: (c) => c.version },
        { label: "Ecossistema", value: (c) => c.ecosystem },
        { label: "Origem", value: (c) => SOURCES[c.source] || c.source },
        { label: "Vulnerabilidades", value: (c) => {
            const v = vulnerable.get(`${c.ecosystem}|${c.name}`);
            return v ? el("span", {}, ...v.map((f) => el("span", {}, sevChip(f.severity), " ", f.evidence.osv_id,
                                                                  f.evidence.fixed ? ` → ${f.evidence.fixed}` : "", " "))) : "—";
          } },
      ], rows, { title: "Componentes", empty: "Inventário ainda não coletado.", emptyAction: pressing("Verificar agora", "Verificar") }));
    };
    const box = el("div");
    search.addEventListener("input", render);
    const feed = inv.feed || {};
    main().replaceChildren(...head, tabs,
      el("div", { class: "form-card" },
        el("h3", { text: "Base de vulnerabilidades (OSV)" }),
        el("p", { class: "muted", text: feed.advisories ? `${feed.advisories} aviso(s), importada em ${fmtDate(feed.imported_at)}.`
          : "Nenhuma base importada. Baixe em osv.dev (\"Data dump\") os avisos dos ecossistemas Hex, Debian e PyPI e envie o JSON aqui (até 20 MiB por arquivo)." }),
        el("div", { class: "row-buttons" }, file, send)),
      el("div", { class: "row-buttons" }, search, el("span", { class: "muted small", text: `${inv.components.length} componente(s) · ${vulnerable.size} com vulnerabilidade` })),
      box);
    render();
  }

  // ------------------------------------------------------------------ transports (spec 034)
  const T_STATUS = { exported: ["enviado", ""], received: ["recebido", "warn"], imported: ["importado", "ok"],
                     refused: ["recusado", "off"], reverted: ["desfeito", "off"] };
  const ITEM_STATUS = { new: ["novo", "ok"], unchanged: ["igual", ""], update: ["atualiza", "ok"], conflict: ["conflito", "off"] };

  async function transports(tab = "list", detail = null) {
    const tabs = el("div", { class: "sub-tabs" }, [["list", "Pacotes"], ["send", "Montar pacote"], ["receive", "Receber pacote"], ["exemptions", "Isenções"], ["keys", "Chave e origens"]]
      .map(([k, l]) => el("button", { class: k === tab ? "active" : "", text: l, onclick: () => guard(() => transports(k)) })));
    const head = header("Transportes", "Leve programas, comandos e parâmetros da instância de desenvolvimento e testes para a produção: " +
      "pacote assinado, verificação prévia (conflitos e dependências), importação numa transação, sem parada, e desfazer com um clique.");
    if (tab === "send") return transportSend(head, tabs);
    if (tab === "receive") return transportReceive(head, tabs);
    if (tab === "keys") return transportKeys(head, tabs);
    if (tab === "exemptions") return qualityExemptions(head, tabs);
    if (detail) return transportDetail(head, tabs, detail);
    const list = await API.admin.transports();
    main().replaceChildren(...head, tabs, table([
      { label: "Nº", value: (t) => String(t.id) },
      { label: "Sentido", value: (t) => t.direction === "out" ? "enviado daqui" : `recebido de ${t.origin}` },
      { label: "Título", value: (t) => t.title },
      { label: "Itens", value: (t) => String(t.items), class: "num" },
      { label: "Autor", value: (t) => t.author },
      { label: "Situação", value: (t) => { const [l, c] = T_STATUS[t.status] || [t.status, ""]; return pill(l, c); } },
      { label: "Quando", value: (t) => fmtDate(t.imported_at || t.received_at || t.created_at) },
    ], list, { empty: "Nenhum pacote ainda.", emptyAction: { label: "Enviar um pacote", onClick: () => guard(() => transports("send")) }, onRow: (t) => guard(() => transports("list", t.id)) }));
  }

  async function transportDetail(head, tabs, id) {
    const t = await API.admin.transport(id);
    const pre = t.preflight || {};
    const status = Object.fromEntries((pre.items || []).map((i) => [i.name, i.status]));
    const accept = new Set();
    const items = t.manifest.items;
    const rows = items.map((i) => {
      const st = status[i.name];
      const [l, c] = ITEM_STATUS[st] || [st || "—", ""];
      const box = st === "conflict" && t.status === "received"
        ? el("input", { type: "checkbox", "aria-label": "Aceitar o conflito de " + i.name, onchange: (e) => e.target.checked ? accept.add(i.name) : accept.delete(i.name) }) : null;
      return { i, l, c, box };
    });
    const diffs = el("div");
    const actions = el("div", { class: "row-buttons" });
    if (t.status === "received") {
      actions.append(
        el("button", { type: "button", text: "Importar", onclick: () => guard(async () => {
          const r = await API.admin.importTransport(id, { accept_conflicts: [...accept] });
          if (r && r.error) { toast(r.error.message + (r.error.conflicts ? ": " + r.error.conflicts.join(", ") : "") + (r.error.missing ? ": " + r.error.missing.join(", ") : ""), true); return; }
          toast(`Pacote importado: ${r.imported} item(ns).`); transports("list", id);
        }) }),
        el("button", { type: "button", class: "quiet", text: "Recusar", onclick: () => guard(async () => {
          const reason = window.prompt("Motivo da recusa:");
          if (!reason) return;
          await API.admin.refuseTransport(id, reason); toast("Pacote recusado."); transports("list", id);
        }) }));
    }
    if (t.status === "imported") actions.append(el("button", { type: "button", class: "quiet", text: "Desfazer importação", onclick: () => guard(async () => {
      if (!window.confirm("Voltar todos os itens deste pacote ao estado anterior?")) return;
      const r = await API.admin.revertTransport(id); toast(`${r.reverted} item(ns) voltaram ao estado anterior.`); transports("list", id);
    }) }));
    main().replaceChildren(...head, tabs,
      el("div", { class: "form-card" },
        el("h3", { text: `#${t.id} — ${t.title}` }),
        el("p", { class: "muted", text: `${t.direction === "out" ? "Enviado daqui" : "Recebido de " + t.origin} · autor ${t.author} · ` +
          `versão ${t.manifest.product_version} · SHA-256 ${t.manifest_sha256.slice(0, 16)}…` }),
        t.description ? el("p", { text: t.description }) : null,
        t.manifest.tests ? el("p", { class: "muted", text: "Testes declarados: " + t.manifest.tests }) : null,
        pre.missing && pre.missing.length ? el("p", { class: "warn-text", text: "Chama programas que não existem aqui: " + pre.missing.join(", ") }) : null,
        pre.missing_values && pre.missing_values.length ? el("p", { class: "warn-text" },
          "Lê valores da empresa que não existem aqui: " + pre.missing_values.join(", ") + " ",
          el("a", { href: "#/admin/values", class: "button small", text: "Criar em Valores da empresa" })) : null,
        t.refused_reason ? el("p", { class: "warn-text", text: `Recusado por ${t.refused_by}: ${t.refused_reason}` }) : null,
        table([
          { label: "Item", value: (r) => r.i.name },
          { label: "Tipo", value: (r) => ({ program: "programa", command: "comando", setting: "parâmetro", value: "valor da empresa" })[r.i.kind] || r.i.kind },
          { label: "Situação aqui", value: (r) => pill(r.l, r.c) },
          { label: "Aceitar conflito", value: (r) => r.box || "" },
          { label: "", value: (r) => r.i.kind === "program" ? el("button", { type: "button", class: "quiet small", text: "Comparar", onclick: () => {
              const here = (t.current || {})[r.i.name];
              diffs.replaceChildren(el("h4", { text: r.i.name }), here === undefined
                ? el("p", { class: "muted", text: "Não existe nesta instância: a importação cria o programa." })
                : diffView("Aqui (atual)", here, "No pacote", r.i.source));
              diffs.scrollIntoView?.({ block: "nearest" });
            } }) : "" },
        ], rows),
        actions),
      diffs);
  }

  async function transportSend(head, tabs) {
    const programs = await API.programs();
    const filter = el("input", { type: "search", placeholder: "Filtrar programas…", "aria-label": "Filtrar programas" });
    const chosen = new Set();
    const listBox = el("div", { class: "pick-list" });
    const draw = () => {
      const q = filter.value.trim().toLowerCase();
      listBox.replaceChildren(...programs.filter((p) => !q || p.name.toLowerCase().includes(q) || (p.description || "").toLowerCase().includes(q))
        .slice(0, 300).map((p) => el("label", { class: "check" },
          el("input", { type: "checkbox", checked: chosen.has(p.name), onchange: (e) => { e.target.checked ? chosen.add(p.name) : chosen.delete(p.name); count.textContent = `${chosen.size} escolhido(s)`; } }),
          el("span", {}, el("code", { text: p.name }), " ", el("span", { class: "muted small", text: `v${p.version} · ${p.description || ""}` })))));
    };
    filter.addEventListener("input", draw);
    const count = el("span", { class: "muted small", text: "0 escolhido(s)" });
    const title = el("input", { type: "text", placeholder: "ex.: Ajuste no faturamento de serviços" });
    const desc = el("textarea", { rows: 3 });
    const tests = el("textarea", { rows: 2, placeholder: "ex.: suíte de integração verde; testado com a massa de 05/10" });
    const commands = el("input", { type: "text", placeholder: "códigos separados por vírgula (opcional)" });
    const settings = el("input", { type: "text", placeholder: "parâmetros separados por vírgula (opcional)" });
    const gateBox = el("div", {});
    const split = (v) => v.split(",").map((x) => x.trim()).filter(Boolean);
    main().replaceChildren(...head, tabs, el("div", { class: "form-card" },
      field("Título do pacote", title), field("O que muda e por quê", desc), field("Testes feitos", tests),
      el("h4", {}, "Programas ", count), filter, listBox,
      field("Comandos", commands), field("Parâmetros", settings),
      el("div", { class: "row-buttons" }, el("button", { type: "button", text: "Gerar pacote assinado", onclick: async () => {
        gateBox.replaceChildren();
        try {
          const r = await API.admin.exportTransport({ title: title.value, description: desc.value, tests: tests.value, programs: [...chosen],
                                                      commands: split(commands.value), settings: split(settings.value) });
          API.saveBlob(new Blob([JSON.stringify(r.package)], { type: "application/json" }), r.file_name);
          toast(`Pacote #${r.id} gerado com o portão de qualidade verde: leve o arquivo ${r.file_name} à produção (Transportes → Receber pacote).`);
        } catch (e) {
          if (e.code === "QUALITY_GATE" && e.body && e.body.error && e.body.error.report) gateBox.replaceChildren(gateReport(e.body.error.report));
          toast(errorText(e), true);
        }
      } })), gateBox));
    draw();
  }

  // Spec 064 (D7, CA-064-01): what blocks the package, per program, with the way to fix it.
  function gateReport(report) {
    const rows = [];
    for (const p of report.programs) for (const f of p.blocking) rows.push({ program: p.name, ...f });
    return el("div", { class: "form-card" },
      el("h4", { text: `Portão de qualidade: ${rows.length} achado(s) bloqueiam (a partir de "${report.level}")` }),
      el("p", { class: "muted", text: "Corrija no Estúdio (o editor mostra cada achado na linha) ou peça isenção: outra pessoa aprova na aba Isenções." }),
      table([
        { label: "Programa", value: (r) => el("a", { href: `#/dev/program/${r.program}`, text: r.program }) },
        { label: "Linha", value: (r) => String(r.line), class: "num" },
        { label: "Gravidade", value: (r) => r.severity },
        { label: "O que", value: (r) => r.message },
        { label: "Como resolver", value: (r) => r.suggestion || "" },
      ], rows, { empty: "Nada bloqueia." }));
  }

  // Spec 064 (D3, CA-064-02): exemptions decided by someone other than who asked (the database refuses otherwise).
  async function qualityExemptions(head, tabs) {
    const list = await API.qualityExemptions({});
    const me = (window.AnaStudio && window.AnaStudio.user && window.AnaStudio.user()) || {};
    const ST = { requested: ["aguardando decisão", "warn"], approved: ["aprovada", "ok"], refused: ["recusada", "off"] };
    const decide = (x, approve) => guard(async () => {
      await API.decideExemption(x.id, approve, null);
      toast(approve ? "Isenção aprovada." : "Isenção recusada.");
      transports("exemptions");
    });
    main().replaceChildren(...head, tabs,
      el("p", { class: "muted", text: "Isenções do portão de qualidade: quem pede não decide. Aprovada, vale até a data e libera o transporte daquele achado." }),
      table([
        { label: "Programa", value: (x) => el("a", { href: `#/dev/program/${x.program}`, text: x.program }) },
        { label: "Regra", value: (x) => x.rule },
        { label: "Motivo", value: (x) => x.reason },
        { label: "Até", value: (x) => fmtDate(x.valid_until) },
        { label: "Pedida por", value: (x) => x.requested_by },
        { label: "Situação", value: (x) => { const [l, c] = ST[x.status] || [x.status, ""]; return pill(l, c); } },
        { label: "Decisão", value: (x) => x.status !== "requested" ? `${x.decided_by || ""}` : x.requested_by === me.username
            ? el("span", { class: "muted", text: "outra pessoa decide" })
            : el("span", { class: "row-buttons" }, el("button", { type: "button", text: "Aprovar", onclick: () => decide(x, true) }),
                 el("button", { type: "button", class: "quiet", text: "Recusar", onclick: () => decide(x, false) })) },
      ], list, { empty: "Nenhum pedido de isenção. Eles nascem no Estúdio, na faixa de qualidade abaixo do editor.",
                 emptyAction: { label: "Abrir o Estúdio", onClick: () => { location.hash = "#/dev"; } } }),
      el("div", { class: "form-card" },
        el("h4", { text: "Adotar o portão em programas antigos" }),
        el("p", { class: "muted", text: "Aceita os achados que já existem hoje como linha de base: daqui em diante só achados novos bloqueiam o transporte." }),
        el("div", { class: "row-buttons" }, el("button", { type: "button", text: "Registrar linha de base de todos os programas", onclick: () => guard(async () => {
          if (!confirm("Registrar os achados atuais de todos os programas como linha de base?")) return;
          const r = await API.admin.qualityBaseline([]);
          toast(`Linha de base registrada: ${r.findings} achado(s) em ${r.programs} programa(s).`);
        }) }))));
  }

  function transportReceive(head, tabs) {
    const file = el("input", { type: "file", accept: ".json,application/json", "aria-label": "Arquivo do pacote" });
    main().replaceChildren(...head, tabs, el("div", { class: "form-card" },
      el("p", { class: "muted", text: "O pacote só é aceito de uma origem cadastrada (Chave e origens), com assinatura e conteúdo conferidos. " +
        "Nada é aplicado agora: você verá a verificação prévia e decide importar." }),
      el("div", { class: "row-buttons" }, file, el("button", { type: "button", text: "Receber", onclick: () => guard(async () => {
        if (!file.files[0]) { toast("Escolha o arquivo do pacote.", true); return; }
        const r = await API.admin.receiveTransport(file.files[0]);
        toast(r.preflight.ok ? "Pacote recebido: sem conflitos." : "Pacote recebido: veja os conflitos antes de importar.");
        transports("list", r.id);
      }) }))));
  }

  async function transportKeys(head, tabs) {
    const [key, origins] = await Promise.all([API.admin.transportKey().catch((e) => ({ error: errorText(e) })), API.admin.transportOrigins()]);
    const name = el("input", { type: "text", placeholder: "ex.: ana-development" });
    const pub = el("input", { type: "text", placeholder: "chave pública (base64)" });
    main().replaceChildren(...head, tabs,
      el("div", { class: "form-card" },
        el("h3", { text: "Esta instância" }),
        key.error ? el("p", { class: "warn-text", text: key.error }) : el("div", {},
          el("p", {}, "Nome: ", el("strong", { text: key.name }), ` · papel: ${key.role} · versão ${key.product_version}`),
          el("p", {}, "Chave pública: ", el("code", { text: key.public_key })),
          el("p", { class: "muted", text: `Impressão digital ${key.fingerprint}. Cadastre nome e chave pública como origem na instância que vai receber os pacotes.` }))),
      el("div", { class: "form-card" },
        el("h3", { text: "Origens aceitas aqui" }),
        table([
          { label: "Origem", value: (o) => o.name },
          { label: "Impressão digital", value: (o) => el("code", { text: o.fingerprint }) },
          { label: "Cadastrada por", value: (o) => `${o.created_by} em ${fmtDate(o.created_at)}` },
          { label: "", value: (o) => el("button", { type: "button", class: "quiet small", text: "Remover", onclick: () => guard(async () => {
              await API.admin.deleteOrigin(o.name); transports("keys"); }) }) },
        ], origins, { empty: "Nenhuma origem: esta instância ainda não aceita pacotes.",
                      emptyAction: { label: "Cadastrar a primeira origem", onClick: () => name.focus() } }),
        el("div", { class: "row-buttons" }, field("Nome da origem", name), field("Chave pública da origem", pub), el("button", { type: "button", text: "Cadastrar origem", onclick: () => guard(async () => {
          await API.admin.saveOrigin(name.value.trim(), pub.value.trim()); toast("Origem cadastrada."); transports("keys");
        }) }))));
  }

  // ------------------------------------------------------------------ data copy (spec 034)
  const COPY_STATUS = { running: ["em andamento", "warn"], ready: ["pronta para baixar", "ok"], uploaded: ["recebida", ""],
                        imported: ["importada", "ok"], checked: ["ensaio ok", "ok"], failed: ["falhou", "off"], expired: ["expirada", ""] };
  const MASK_KINDS = { keep: "manter", person: "nome de pessoa", company: "nome de empresa", email: "e-mail", phone: "telefone",
                       document: "documento", address: "endereço", geo: "coordenada", text: "texto livre", null: "apagar" };

  async function datacopy(tab = "copies") {
    const tabs = el("div", { class: "sub-tabs" }, [["copies", "Cópias"], ["masking", "Máscaras"]]
      .map(([k, l]) => el("button", { class: k === tab ? "active" : "", text: l, onclick: () => guard(() => datacopy(k)) })));
    const inst = await API.admin.instance();
    const head = header("Cópia de dados para testes", "Leva os dados reais da produção para a instância de testes como massa de testes: " +
      "dados pessoais mascarados já na origem, arquivo cifrado, carga numa transação com contagens e totais conferidos. " +
      "Depois da carga, a instância de testes não chama nenhum sistema externo.");
    if (tab === "masking") return datacopyMasking(head, tabs);
    const copies = await API.admin.copies();
    const isProd = inst.role === "production";
    const keyBox = el("div");
    const exportCard = el("div", { class: "form-card" }, el("h3", { text: "Exportar daqui" }),
      el("p", { class: "muted", text: "Gera o arquivo cifrado desta instância. A chave aparece uma única vez: guarde-a para importar no destino." }),
      el("div", { class: "row-buttons" }, el("button", { type: "button", text: "Exportar dados mascarados", onclick: () => guard(async () => {
        const r = await API.admin.copyExport();
        keyBox.replaceChildren(el("div", { class: "secret-box" }, el("div", { text: `Cópia #${r.id} — chave (mostrada só agora):` }), el("strong", { text: r.key }),
          el("div", { class: "muted", text: "Copie a chave; o arquivo fica disponível por 48 horas." })));
        setTimeout(() => datacopy("copies").then(() => main().prepend(keyBox)), 2500);
      }) })), keyBox);
    const file = el("input", { type: "file", accept: ".anadc", "aria-label": "Arquivo da cópia" });
    const importCard = isProd ? el("div", { class: "form-card" }, el("p", { class: "muted", text: "Esta instância é a produção: ela não recebe cópias." }))
      : el("div", { class: "form-card" }, el("h3", { text: `Receber nesta instância (${inst.role === "test" ? "testes" : "desenvolvimento"})` }),
          el("p", { class: "warn-text", text: "A importação substitui todos os dados de negócio desta instância." }),
          el("div", { class: "row-buttons" }, file, el("button", { type: "button", text: "Enviar arquivo", onclick: () => guard(async () => {
            if (!file.files[0]) { toast("Escolha o arquivo da cópia.", true); return; }
            await API.admin.copyUpload(file.files[0]); toast("Arquivo recebido: informe a chave e importe."); datacopy("copies");
          }) })));
    main().replaceChildren(...head, tabs, el("div", { class: "card-pair" }, exportCard, importCard),
      table([
        { label: "Nº", value: (c) => String(c.id) },
        { label: "Sentido", value: (c) => c.direction === "out" ? "exportada daqui" : "recebida" },
        { label: "Situação", value: (c) => { const [l, k] = COPY_STATUS[c.status] || [c.status, ""]; return pill(l, k); } },
        { label: "Tamanho", value: (c) => c.size_bytes ? `${(c.size_bytes / 1048576).toFixed(1)} MiB` : "—", class: "num" },
        { label: "Resultado", value: (c) => c.error ? el("span", { class: "warn-text", text: c.error })
            : c.result ? `${c.result.tables} tabela(s), ${c.result.rows} linha(s)` + (c.result.skipped ? `, ${c.result.skipped} omitida(s)` : "") : "" },
        { label: "Quando", value: (c) => fmtDate(c.finished_at || c.created_at) },
        { label: "", value: (c) => c.direction === "out" && c.status === "ready"
            ? el("button", { type: "button", class: "small", text: "Baixar", onclick: () => guard(() => API.download(`/api/admin/datacopy/${c.id}/download`, `copia-${c.id}.anadc`)) })
            : c.direction === "in" && ["uploaded", "checked", "failed"].includes(c.status) && !isProd ? copyImportButtons(c) : "" },
      ], copies, { empty: "Nenhuma cópia.", emptyAction: pressing("Exportar dados mascarados", "Exportar dados") }));
  }

  function copyImportButtons(c) {
    const run = (dry) => guard(async () => {
      const key = window.prompt("Chave da cópia (mostrada na exportação):");
      if (!key) return;
      if (!dry && !window.confirm("Substituir todos os dados de negócio desta instância pela cópia?")) return;
      await API.admin.copyImport(c.id, { key: key.trim(), dry_run: dry });
      toast(dry ? "Ensaio iniciado: carga completa e desfeita ao final." : "Importação iniciada.");
      setTimeout(() => datacopy("copies"), 1500);
    });
    return el("span", { class: "row-buttons" },
      el("button", { type: "button", class: "quiet small", text: "Ensaiar", onclick: () => run(true) }),
      el("button", { type: "button", class: "small", text: "Importar", onclick: () => run(false) }));
  }

  async function datacopyMasking(head, tabs) {
    const m = await API.admin.masking();
    main().replaceChildren(...head, tabs,
      el("p", { class: "muted", text: "Colunas mascaradas na exportação (catálogo do produto e ajustes desta instalação). Tabelas do sistema, cofre, " +
        "integrações, arquivos e senhas nunca entram na cópia." }),
      table([
        { label: "Tabela", value: (c) => c.table },
        { label: "Coluna", value: (c) => c.column },
        { label: "Máscara", value: (c) => {
            const sel = el("select", { "aria-label": `Máscara de ${c.table}.${c.column}` },
              el("option", { value: "catalog", text: "padrão do produto" }),
              ...m.kinds.map((k) => el("option", { value: k, text: MASK_KINDS[k] || k })));
            sel.value = c.rule ? c.kind : "catalog";
            sel.addEventListener("change", () => guard(async () => {
              await API.admin.saveMasking({ table: c.table, column: c.column, kind: sel.value }); toast("Máscara salva.");
            }));
            return el("span", {}, sel, c.rule ? "" : el("span", { class: "muted small", text: ` (${MASK_KINDS[c.kind] || c.kind})` }));
          } },
      ], m.columns, { empty: "Nenhuma coluna mascarada." }));
  }

  // ------------------------------------------------------------------ integrations (spec 017)
  const MSG_STATUS = { pending: "pendente", processing: "processando", done: "entregue", dead: "esgotada", discarded: "descartada" };
  const SECRET_KEYS = { none: [], basic: ["username", "password"], bearer: ["token"], api_key: ["api_key"],
                        oauth2_client: ["client_id", "client_secret"] };

  async function integrations(tab = "panel", filter = {}) {
    const tabs = el("div", { class: "sub-tabs" }, [["panel", "Painel"], ["connectors", "Conectores"], ["outbox", "Saída"], ["inbox", "Entrada"]]
      .map(([k, l]) => el("button", { class: k === tab ? "active" : "", text: l, onclick: () => guard(() => integrations(k)) })));
    const body = el("div");
    main().replaceChildren(...header("Integrações", "Conectores com bancos, gateways e serviços externos. Programas usam o conector (ana.http, ana.send); segredos ficam no cofre e nunca chegam aos programas. Mensagens são entregues pelo menos uma vez, com novas tentativas."), tabs, body);
    if (tab === "panel") {
      const rows = await API.admin.integrationStats();
      body.replaceChildren(table([
        { label: "Conector", value: (c) => c.name },
        { label: "Tipo", value: (c) => (c.kind === "http_api" ? "saída HTTP" : "webhook de entrada") },
        { label: "Situação", value: (c) => (c.active ? pill("ativo", "ok") : pill("inativo", "off")) },
        { label: "Chamadas 24 h", value: (c) => c.calls },
        { label: "Erro %", value: (c) => (c.error_pct === null ? "—" : c.error_pct) },
        { label: "p95 (ms)", value: (c) => c.p95_ms ?? "—" },
        { label: "Fila de saída", value: (c) => `${c.out_pending}` + (c.out_dead ? ` · ${c.out_dead} esgotada(s)` : "") },
        { label: "Fila de entrada", value: (c) => `${c.in_pending}` + (c.in_dead ? ` · ${c.in_dead} esgotada(s)` : "") },
      ], rows, { empty: "Nenhum conector cadastrado.", emptyAction: { label: "Cadastrar um conector", onClick: () => guard(() => integrations("connectors")) }, onRow: (c) => guard(() => integrations(c.kind === "http_api" ? "outbox" : "inbox", { connector: c.name })) }));
    } else if (tab === "connectors") {
      body.replaceChildren(await connectorsView());
    } else {
      body.replaceChildren(await messagesView(tab, filter));
    }
  }

  async function connectorsView() {
    const data = await API.admin.connectors();
    const side = el("div");
    const form = (c = {}) => {
      const f = {
        name: el("input", { value: c.name || "", placeholder: "ex.: banco_x", disabled: !!c.name }),
        description: el("input", { value: c.description || "" }),
        kind: el("select", {}, [["http_api", "Saída HTTP (API)"], ["webhook_in", "Webhook de entrada"], ["smtp", "E-mail (SMTP)"]].map(([v, l]) => el("option", { value: v, text: l, selected: c.kind === v }))),
        base_url: el("input", { value: c.base_url || "", placeholder: "https://api.exemplo.com" }),
        auth: el("select", {}, [["none", "Nenhuma"], ["basic", "Usuário e senha"], ["bearer", "Token"], ["api_key", "Chave de API"], ["oauth2_client", "OAuth2 (client credentials)"]].map(([v, l]) => el("option", { value: v, text: l, selected: (c.auth || "none") === v }))),
        token_url: el("input", { value: c.token_url || "", placeholder: "https://… (OAuth2)" }),
        allowed_hosts: el("input", { value: (c.allowed_hosts || []).join(", "), placeholder: "outros hosts além do da URL base" }),
        outbound_program: el("input", { value: c.outbound_program || "", placeholder: "programa que entrega a caixa de saída" }),
        inbound_program: el("input", { value: c.inbound_program || "", placeholder: "programa que processa os webhooks" }),
        run_as: el("input", { value: c.run_as || "system" }),
        max_attempts: el("input", { type: "number", min: 1, max: 50, value: c.max_attempts || 8 }),
        timeout_ms: el("input", { type: "number", min: 100, max: 120000, value: c.timeout_ms || 15000 }),
        rate_per_min: el("input", { type: "number", min: 1, value: c.rate_per_min || 600 }),
        options: el("textarea", { rows: 3, class: "params-json", value: JSON.stringify(c.options || {}, null, 1) }),
        active: el("input", { type: "checkbox", checked: c.active !== false }),
      };
      // Spec 044: an e-mail (SMTP) connector keeps its settings in the options; the password goes to the vault.
      const o = c.options || {};
      const sm = {
        host: el("input", { value: o.host || "", placeholder: "smtp.empresa.com.br" }),
        port: el("input", { type: "number", min: 1, max: 65535, value: o.port || "", placeholder: "587 (STARTTLS) ou 465 (TLS)" }),
        security: el("select", {}, [["starttls", "STARTTLS (obrigatório)"], ["tls", "TLS direto"], ["none", "Sem criptografia (não recomendado)"]]
          .map(([v, l]) => el("option", { value: v, text: l, selected: (o.security || "starttls") === v }))),
        from: el("input", { value: o.from || "", placeholder: "erp@empresa.com.br" }),
        from_name: el("input", { value: o.from_name || "", placeholder: "nome do remetente" }),
        reply_to: el("input", { value: o.reply_to || "", placeholder: "responder para (opcional)" }),
        ca_cert: el("textarea", { rows: 2, class: "params-json", value: o.ca_cert || "", placeholder: "-----BEGIN CERTIFICATE----- (só para CA própria)" }),
        allow_plain: el("input", { type: "checkbox", checked: o.allow_plain === true }),
        default_email: el("input", { type: "checkbox", checked: c.default_email === true }),
      };
      const testTo = el("input", { type: "email", placeholder: "para (e-mail de teste)" });
      const smtpOnly = [field("Servidor SMTP", sm.host), field("Porta", sm.port), field("Segurança", sm.security), field("Remetente", sm.from),
        field("Nome do remetente", sm.from_name), field("Responder para", sm.reply_to), field("CA própria (PEM)", sm.ca_cert),
        check("Permitir sem criptografia (aparece nas Verificações)", sm.allow_plain), check("Conector de e-mail padrão", sm.default_email),
        el("div", { class: "row-buttons" },
          el("button", { type: "button", class: "quiet", text: "Testar conexão", disabled: !c.name, onclick: () => guard(async () => {
            await API.admin.smtpTest(c.name, {}); toast("Conexão com o servidor de e-mail ok.");
          }) }),
          testTo,
          el("button", { type: "button", class: "quiet", text: "Enviar e-mail de teste", disabled: !c.name, onclick: () => guard(async () => {
            if (!testTo.value.trim()) { toast("Informe o destinatário do teste.", true); return; }
            const r = await API.admin.smtpTest(c.name, { to: testTo.value.trim() }); toast(`Enviado: ${r.server_reply || "ok"}`);
          }) }))];
      const secrets = el("div");
      const drawSecrets = () => {
        const have = new Map((c.secrets || []).map((x) => [x.key, x]));
        const keys = [...new Set([...(SECRET_KEYS[f.auth.value] || []), ...(f.kind.value === "webhook_in" ? ["hmac_key"] : []), ...have.keys()])];
        secrets.replaceChildren(el("h4", { text: "Segredos (só escrita)" }), ...keys.map((k) => {
          const input = el("input", { type: "password", autocomplete: "new-password", placeholder: have.has(k) ? "definido — digite para trocar" : "não definido" });
          const exp = el("input", { type: "date", value: (have.get(k) || {}).expires_at || "" });
          return el("div", { class: "row-buttons" }, el("code", { text: k }), input, exp,
            have.get(k) && have.get(k).expiring ? pill("vence em breve", "warn") : null,
            el("button", { type: "button", class: "small", text: "Gravar", disabled: !c.name, onclick: () => guard(async () => {
              if (!input.value) return;
              await API.admin.saveSecret(c.name, k, input.value, exp.value); input.value = ""; toast("Segredo gravado no cofre.");
              integrations("connectors");
            }) }));
        }), c.name ? null : el("p", { class: "muted small", text: "Salve o conector antes de gravar segredos." }),
          data.vault ? null : el("p", { class: "muted small", text: "Cofre desligado: defina ANA_MASTER_KEY em todos os nós." }));
      };
      f.auth.addEventListener("change", drawSecrets);
      f.kind.addEventListener("change", drawSecrets);
      drawSecrets();
      const httpOnly = [field("URL base", f.base_url), field("URL do token (OAuth2)", f.token_url), field("Hosts permitidos", f.allowed_hosts),
        field("Programa de entrega (saída)", f.outbound_program), field("Programa de processamento (entrada)", f.inbound_program)];
      const showKind = () => {
        const smtp = f.kind.value === "smtp";
        for (const n of smtpOnly) n.hidden = !smtp;
        for (const n of httpOnly) n.hidden = smtp;
      };
      f.kind.addEventListener("change", showKind);
      side.replaceChildren(el("form", { class: "form-card", onsubmit: (e) => { e.preventDefault(); guard(async () => {
        let options;
        try { options = JSON.parse(f.options.value || "{}"); } catch (_) { toast("Opções devem ser um JSON de objeto.", true); return; }
        const name = f.name.value.trim();
        const smtp = f.kind.value === "smtp";
        if (smtp) {
          Object.assign(options, { host: sm.host.value.trim(), security: sm.security.value, from: sm.from.value.trim(),
            from_name: sm.from_name.value.trim() || null, reply_to: sm.reply_to.value.trim() || null,
            ca_cert: sm.ca_cert.value.trim() || null, allow_plain: sm.allow_plain.checked });
          if (sm.port.value) options.port = Number(sm.port.value);
        }
        await API.admin.saveConnector(name, { description: f.description.value, kind: f.kind.value, base_url: f.base_url.value.trim() || null,
          auth: f.auth.value, token_url: f.token_url.value.trim() || null,
          allowed_hosts: f.allowed_hosts.value.split(",").map((h) => h.trim()).filter(Boolean),
          outbound_program: f.outbound_program.value.trim() || null, inbound_program: f.inbound_program.value.trim() || null,
          run_as: f.run_as.value.trim() || "system", max_attempts: Number(f.max_attempts.value), timeout_ms: Number(f.timeout_ms.value),
          rate_per_min: Number(f.rate_per_min.value), options, active: f.active.checked, default_email: smtp && sm.default_email.checked });
        toast("Conector salvo."); integrations("connectors");
      }); } },
        el("h3", { text: c.name ? `Conector ${c.name}` : "Novo conector" }),
        field("Nome", f.name), field("Descrição", f.description), field("Tipo", f.kind), field("Autenticação", f.auth),
        ...httpOnly, ...smtpOnly,
        field("Roda como (usuário dono)", f.run_as), field("Tentativas", f.max_attempts), field("Tempo máximo (ms)", f.timeout_ms),
        field("Chamadas por minuto", f.rate_per_min), field("Opções para os programas (JSON)", f.options), check("Ativo", f.active),
        el("div", { class: "row-buttons" }, el("button", { class: "primary", type: "submit", text: "Salvar" })),
        secrets,
        c.kind === "webhook_in" ? el("p", { class: "muted small", text: `Endereço: POST /hooks/${c.name} com cabeçalhos ${c.timestamp_header} (segundos), ${c.signature_header} = sha256=<HMAC-SHA256 hex de "carimbo.corpo"> e ${c.event_id_header}.` }) : null));
      showKind();
    };
    form();
    return el("div", { class: "admin-columns" },
      el("div", {}, el("div", { class: "row-buttons" }, el("button", { text: "Novo conector", onclick: () => form() })),
        table([
          { label: "Nome", value: (c) => c.name },
          { label: "Tipo", value: (c) => ({ http_api: "saída HTTP", webhook_in: "webhook", smtp: "e-mail (SMTP)" })[c.kind] || c.kind },
          { label: "Destino", value: (c) => c.kind === "smtp" ? `${(c.options || {}).host || "?"}:${(c.options || {}).port || ""}${c.default_email ? " · padrão" : ""}`
            : c.base_url || `/hooks/${c.name}` },
          { label: "Segredos", value: (c) => (c.secrets.length ? c.secrets.map((x) => x.key).join(", ") : "—") },
          { label: "Situação", value: (c) => (c.active ? pill("ativo", "ok") : pill("inativo", "off")) },
        ], data.connectors, { empty: "Nenhum conector.", emptyAction: toForm("Cadastrar um conector"), onRow: (c) => form(c) })),
      side);
  }

  async function messagesView(kind, filter = {}) {
    const status = el("select", {}, [["", "Todas"], ...Object.entries(MSG_STATUS)].map(([v, l]) => el("option", { value: v, text: l, selected: (filter.status || "") === v })));
    const connector = el("input", { value: filter.connector || "", placeholder: "conector" });
    const reload = () => guard(() => integrations(kind, { status: status.value || undefined, connector: connector.value.trim() || undefined }));
    status.addEventListener("change", reload);
    connector.addEventListener("keydown", (e) => { if (e.key === "Enter") reload(); });
    const rows = await API.admin.integrationMessages({ kind, ...filter });
    const detail = el("div");
    return el("div", {},
      el("div", { class: "row-buttons" }, field("Situação", status), field("Conector", connector), el("button", { text: "Atualizar", onclick: reload })),
      table([
        { label: "#", value: (m) => m.id },
        { label: "Conector", value: (m) => m.connector },
        { label: kind === "outbox" ? "Tipo" : "Evento", value: (m) => (kind === "outbox" ? m.kind : m.event_id) },
        { label: "Situação", value: (m) => pill(MSG_STATUS[m.status] || m.status, m.status === "done" ? "ok" : m.status === "dead" ? "warn" : "") },
        { label: "Tentativas", value: (m) => m.attempts },
        { label: "Último erro", value: (m) => m.last_error || "" },
        { label: "Criada", value: (m) => fmtDate(m.created_at) },
        { label: "", value: (m) => el("div", { class: "row-buttons" },
            ["dead", "discarded"].includes(m.status) ? el("button", { class: "small", text: "Reprocessar", onclick: () => guard(async () => {
              await API.admin.integrationAction(kind, m.id, "reprocess"); toast("Mensagem voltou para a fila."); reload(); }) }) : null,
            ["dead", "pending"].includes(m.status) ? el("button", { class: "small quiet", text: "Descartar", onclick: () => guard(async () => {
              if (!confirm(`Descartar a mensagem ${m.id}? Ela não será entregue.`)) return;
              await API.admin.integrationAction(kind, m.id, "discard"); reload(); }) }) : null) },
      ], rows, { empty: "Nenhuma mensagem.", emptyGood: true, onRow: (m) => detail.replaceChildren(el("h4", { text: `Mensagem ${m.id}` }),
        el("pre", { class: "code-view", text: JSON.stringify({ payload: m.payload, result: m.result, headers: m.headers }, null, 2) })) }),
      detail);
  }

  // ------------------------------------------------------------------ license (spec 009)
  const LICENSE_STATE = { trial: ["avaliação", "warn"], valid: ["válida", "ok"], expiring: ["vence em breve", "warn"],
                          grace: ["vencida — em carência", "warn"], restricted: ["somente consulta", "off"] };
  const LICENSE_REASON = { expired: "vencida além da carência", trial_over: "avaliação de 30 dias encerrada",
                           clock: "relógio do servidor está atrás da última data vista: corrija a hora do servidor",
                           version: "não cobre a versão instalada", not_yet: "ainda não começou a valer" };

  async function license() {
    const l = await API.admin.license();
    const [label, tone] = LICENSE_STATE[l.state] || [l.state, ""];
    const users = l.named_users === "unlimited" ? `${l.named_users_used} (sem limite)` : `${l.named_users_used} de ${l.named_users}`;
    const days = l.days_left;
    const when = l.state === "trial" ? `${days} dia(s) de avaliação`
      : days === undefined || days === null ? "—"
      : days >= 0 ? `${fmtDate(l.valid_until)} (${days} dia(s))` : `${fmtDate(l.valid_until)} (vencida há ${-days} dia(s))`;
    const text = el("textarea", { rows: 6, placeholder: "-----BEGIN ANA LICENSE-----\n…\n-----END ANA LICENSE-----", spellcheck: "false" });
    main().replaceChildren(
      ...header("Licença", "O que esta instalação contratou. A licença vem assinada pelo fornecedor e funciona sem internet. Vencida, o ERP nunca prende seus dados: consultas, relatórios e exportação continuam."),
      el("dl", { class: "facts" },
        el("dt", { text: "Situação" }), el("dd", {}, pill(label, tone), l.reason ? el("span", { class: "muted", text: " " + (LICENSE_REASON[l.reason] || l.reason) }) : null),
        el("dt", { text: "Cliente" }), el("dd", { text: l.customer || "— (sem licença instalada)" }),
        el("dt", { text: "Validade" }), el("dd", { text: when }),
        el("dt", { text: "Ambiente" }), el("dd", {}, l.environment === "non_production" ? pill("testes — não usar em produção", "warn") : "produção"),
        el("dt", { text: "Usuários nomeados" }), el("dd", { text: users + " — robôs e contas do portal não contam" }),
        el("dt", { text: "Versão" }), el("dd", { text: `${l.product_version} instalada` + (l.max_version ? `; a licença cobre até ${l.max_version}` : "") })),
      el("h3", { text: "Módulos" }),
      table([
        { label: "Módulo", value: (m) => m.label },
        { label: "Programas", value: (m) => el("span", {}, (m.namespaces.length ? m.namespaces : ["—"]).map((n) => el("code", { text: n === "—" ? n : n + ".* " }))) },
        { label: "Situação", value: (m) => (m.module === "core" ? pill("sempre incluído", "ok")
          : l.modules.includes(m.module) ? pill("contratado", "ok") : pill("não contratado", "off")) },
      ], [{ module: "core", label: "Núcleo: plataforma, Estúdio, cadastros, financeiro, estoque, agendamento, integrações e os seus programas", namespaces: [] }]
          .concat(l.catalog)),
      el("h3", { text: "Instalar licença" }),
      el("form", { class: "stack", onsubmit: (e) => { e.preventDefault(); guard(async () => {
        const r = await API.admin.installLicense(text.value.trim());
        toast(`Licença instalada: ${(LICENSE_STATE[r.state] || [r.state])[0]}.`);
        license();
      }); } },
        field("Texto da licença (enviado pelo fornecedor)", text),
        el("div", { class: "row-buttons" }, el("button", { class: "primary", type: "submit", text: "Instalar" }))),
      el("p", { class: "muted", text: "Sem tela? Indique o arquivo em ANA_LICENSE_FILE: a licença mais nova é instalada na partida e a cada hora." }),
      el("h3", { text: "Histórico" }),
      table([
        { label: "Instalada em", value: (h) => fmtDate(h.installed_at) },
        { label: "Por", value: (h) => h.installed_by },
        { label: "Origem", value: (h) => (h.source === "file" ? "arquivo" : "tela") },
        { label: "Cliente", value: (h) => h.customer },
        { label: "Validade", value: (h) => fmtDate(h.valid_until) },
        { label: "", value: (h) => (h.active ? pill("em uso", "ok") : "") },
      ], l.history, { empty: "Nenhuma licença instalada ainda.", emptyAction: toForm("Instalar licença") }));
  }

  // ------------------------------------------------------------------ telemetry (spec 009, D13)
  const CONNECTOR_STATE = { ready: ["conector pronto", "ok"], inactive: ["conector inativo", "warn"], missing: ["sem conector \"telemetry\"", "warn"] };

  async function telemetry() {
    const t = await API.admin.telemetry();
    const [cl, ct] = CONNECTOR_STATE[t.connector] || [t.connector, ""];
    main().replaceChildren(
      ...header("Telemetria", "Opcional e desligada por padrão. Ligada, envia uma vez por dia ao suporte do fornecedor só o que aparece abaixo: versões, situação da licença, saúde e contagens de execuções e de códigos de erro. Nunca dados do negócio, nomes, mensagens ou usuários."),
      el("dl", { class: "facts" },
        el("dt", { text: "Situação" }), el("dd", {}, t.enabled ? pill("ligada", "ok") : pill("desligada", "off"),
          t.changed_by ? el("span", { class: "muted", text: ` por ${t.changed_by} em ${fmtDate(t.changed_at)}` }) : null),
        el("dt", { text: "Destino" }), el("dd", {}, pill(cl, ct), el("span", { class: "muted", text: " — configure o endereço do fornecedor em Integrações → Conectores, nome telemetry" })),
        el("dt", { text: "Último envio" }), el("dd", { text: t.last_sent_at ? `${fmtDate(t.last_sent_at)} — ${t.last_status}` : "nunca" }),
        el("dt", { text: "Instância" }), el("dd", {}, el("code", { text: t.instance_id }), el("span", { class: "muted", text: " (identificador anônimo, não é o cliente)" }))),
      el("div", { class: "row-buttons" },
        el("button", { class: t.enabled ? "danger" : "primary", text: t.enabled ? "Desligar" : "Ligar", onclick: () => guard(async () => {
          if (!t.enabled && !confirm("Enviar uma vez por dia ao fornecedor os dados mostrados abaixo?")) return;
          await API.admin.setTelemetry(!t.enabled); telemetry();
        }) }),
        t.enabled ? el("button", { text: "Enviar agora", onclick: () => guard(async () => {
          const r = await API.admin.sendTelemetry(); toast(`Envio: ${r.last_status}`, r.last_status !== "enviado"); telemetry();
        }) }) : null),
      el("h3", { text: "Exatamente o que é enviado" }),
      el("pre", { class: "json form-card", text: JSON.stringify(t.preview, null, 2) }));
  }

  // ------------------------------------------------------------------ extension points (spec 009, D9)
  async function extensions() {
    const r = await API.admin.extensions();
    const point = el("select", { "aria-label": "Ponto de extensão" }, r.points.map((p) => el("option", { value: p.point, text: `${p.label} — ${p.point}` })));
    const program = el("input", { "aria-label": "ex.: cli.validar_faturamento", placeholder: "ex.: cli.validar_faturamento" });
    const position = el("input", { type: "number", value: 100, min: 1, "aria-label": "Ordem" });
    const byPoint = Object.fromEntries(r.points.map((p) => [p.point, p]));
    main().replaceChildren(
      ...header("Extensões", "Regras da sua empresa nos programas do produto, sem copiá-los: um programa seu roda no ponto escolhido, na mesma transação. Os de \"antes\" podem recusar (com ana.Error) ou ajustar os campos permitidos; os de \"depois\" recebem o resultado. O programa recebe main(point, data)."),
      table([
        { label: "Ponto", value: (x) => el("span", {}, (byPoint[x.point] || {}).label || x.point, " ", el("code", { class: "muted", text: x.point })) },
        { label: "Programa", value: (x) => el("code", { text: x.program }) },
        { label: "Ordem", value: (x) => x.position, class: "num" },
        { label: "Por", value: (x) => x.created_by },
        { label: "", value: (x) => el("button", { class: "danger small", text: "Remover", onclick: () => guard(async () => {
          if (!confirm(`Desligar ${x.program} de ${x.point}?`)) return;
          await API.admin.deleteExtension(x.id); toast("Extensão removida."); extensions();
        }) }) },
      ], r.extensions, { empty: "Nenhuma extensão: os programas do produto rodam como vieram.",
                        emptyAction: { label: "Ligar um programa seu", onClick: () => program.focus() } }),
      el("form", { class: "form-card", onsubmit: (e) => { e.preventDefault(); guard(async () => {
        await API.admin.saveExtension({ point: point.value, program: program.value.trim(), position: Number(position.value) || 100 });
        toast("Extensão registrada."); extensions();
      }); } },
        el("h3", { text: "Ligar um programa seu" }),
        field("Ponto", point), field("Programa (fora dos namespaces do produto)", program), field("Ordem (menor roda primeiro)", position),
        el("p", { class: "muted", text: "Pontos que ajustam: " + r.points.filter((p) => p.adjust.length).map((p) => `${p.point} (${p.adjust.join(", ")})`).join("; ") }),
        el("div", { class: "row-buttons" }, el("button", { class: "primary", type: "submit", text: "Registrar" }))));
  }

  // ------------------------------------------------------------------ product updates (spec 028)
  /** Line diff (LCS) for the side-by-side comparison: [{t: "same"|"del"|"add", a, b}]. */
  function lineDiff(a, b) {
    const n = a.length, m = b.length;
    if (n * m > 4000000) return null;                       // too big to compare here
    const w = m + 1, len = new Uint32Array((n + 1) * w);
    for (let i = n - 1; i >= 0; i--) {
      for (let j = m - 1; j >= 0; j--) {
        len[i * w + j] = a[i] === b[j] ? len[(i + 1) * w + j + 1] + 1 : Math.max(len[(i + 1) * w + j], len[i * w + j + 1]);
      }
    }
    const out = [];
    let i = 0, j = 0;
    while (i < n || j < m) {
      if (i < n && j < m && a[i] === b[j]) { out.push({ t: "same", a: a[i++], b: b[j++] }); }
      else if (j < m && (i >= n || len[i * w + j + 1] >= len[(i + 1) * w + j])) { out.push({ t: "add", b: b[j++] }); }
      else { out.push({ t: "del", a: a[i++] }); }
    }
    return out;
  }

  function diffView(leftTitle, left, rightTitle, right) {
    const ops = lineDiff((left || "").split("\n"), (right || "").split("\n"));
    if (!ops) return el("p", { class: "muted", text: "Programa grande demais para comparar aqui." });
    const changed = ops.filter((o) => o.t !== "same").length;
    if (!changed) return el("p", { class: "muted", text: "Sem diferenças." });
    const rows = [];
    let la = 0, lb = 0;
    const keep = new Set();                                  // 3 lines of context around each change
    ops.forEach((o, k) => { if (o.t !== "same") for (let d = -3; d <= 3; d++) keep.add(k + d); });
    let skipped = 0;
    const flushSkip = () => {
      if (skipped) rows.push(el("tr", { class: "diff-skip" }, el("td", { colspan: "4", text: `… ${skipped} linha(s) iguais …` })));
      skipped = 0;
    };
    ops.forEach((o, k) => {
      if (o.t !== "add") la++;
      if (o.t !== "del") lb++;
      if (!keep.has(k)) { skipped++; return; }
      flushSkip();
      rows.push(el("tr", { class: "diff-" + o.t },
        el("td", { class: "diff-n", text: o.t === "add" ? "" : String(la) }),
        el("td", { class: "diff-code", text: o.t === "add" ? "" : o.a }),
        el("td", { class: "diff-n", text: o.t === "del" ? "" : String(lb) }),
        el("td", { class: "diff-code", text: o.t === "del" ? "" : o.b })));
    });
    flushSkip();
    return el("div", { class: "diff-box" },
      el("p", { class: "muted small", text: `${changed} linha(s) diferente(s)` }),
      el("table", { class: "diff" },
        el("thead", {}, el("tr", {}, el("th", { colspan: "2", text: leftTitle }), el("th", { colspan: "2", text: rightTitle }))),
        el("tbody", {}, rows)));
  }

  async function refreshUpdatesCount() {
    const badge = $("#updates-count");
    if (!badge) return;
    try {
      const r = await API.admin.productUpdates();
      badge.textContent = String(r.available);
      badge.hidden = !r.available;
    } catch (_) { badge.hidden = true; }
  }

  const UPDATE_STATUS = { available: "disponível", accepted: "aceita", dismissed: "dispensada" };

  async function updates() {
    const r = await API.admin.productUpdates();
    refreshUpdatesCount();
    const available = r.updates.filter((u) => u.status === "available");
    const unmodified = available.filter((u) => !u.locally_modified).length;
    main().replaceChildren(
      ...header("Atualizações do produto", "Versões novas dos programas que vêm com o ANA. Nada muda sozinho: você compara e decide. Programas alterados nesta instalação pedem confirmação; a versão atual sempre fica no histórico."),
      el("div", { class: "row-buttons" },
        el("button", { text: "Verificar agora", onclick: () => guard(async () => {
          const c = await API.admin.productUpdatesCheck(); toast(`${c.available} atualização(ões) disponível(is).`); updates();
        }) }),
        unmodified ? el("button", { class: "primary", text: `Aceitar as ${unmodified} não alteradas aqui`, onclick: () => guard(async () => {
          if (!confirm(`Atualizar ${unmodified} programa(s) que não foram alterados nesta instalação?`)) return;
          const a = await API.admin.productUpdatesAcceptUnmodified();
          toast(`${a.accepted.length} atualizado(s)` + (a.failed.length ? `, ${a.failed.length} com problema` : "") + ".", a.failed.length > 0);
          updates();
        }) }) : null),
      table([
        { label: "Programa", value: (u) => u.name },
        { label: "Tipo", value: (u) => (u.kind === "library" ? "biblioteca" : "programa") },
        { label: "Situação", value: (u) => UPDATE_STATUS[u.status] || u.status },
        { label: "Alterado aqui", value: (u) => (u.locally_modified ? pill("sim", "warn") : "não") },
        { label: "Detectada em", value: (u) => fmtDate(u.detected_at) },
        { label: "", value: (u) => el("button", { class: "quiet small", text: u.status === "available" ? "Comparar e decidir" : "Ver",
                                                   onclick: () => guard(() => updateDetail(u.name)) }) },
      ], r.updates, { empty: "Todos os programas do produto estão em dia.", emptyGood: true }));
  }

  async function updateDetail(name) {
    const d = await API.admin.productUpdate(name);
    const pending = d.status === "available";
    const compare = el("div");
    const views = [["installed", "Instalado × produto"]].concat(d.base ? [["local", "O que foi alterado aqui"], ["product", "O que o produto mudou"]] : []);
    const showView = (k) => {
      for (const b of tabs.children) b.classList.toggle("active", b.dataset.k === k);
      compare.replaceChildren(
        k === "installed" ? diffView(`Instalado (versão ${d.version})`, d.installed, "Produto (nova)", d.seed_source)
        : k === "local" ? diffView("Base do produto", d.base, "Instalado", d.installed)
        : diffView("Base do produto", d.base, "Produto (nova)", d.seed_source));
    };
    const tabs = el("div", { class: "sub-tabs" }, views.map(([k, l]) => el("button", { "data-k": k, text: l, onclick: () => showView(k) })));
    main().replaceChildren(
      ...header(`Atualização de ${name}`, d.locally_modified
        ? "Este programa foi alterado nesta instalação. Aceitar substitui as alterações pela versão do produto (a atual fica no histórico e pode ser restaurada)."
        : "Este programa não foi alterado nesta instalação: aceitar só traz a versão nova do produto."),
      el("div", { class: "row-buttons" },
        el("button", { class: "quiet", text: "← Voltar à lista", onclick: () => guard(updates) }),
        pending ? el("button", { class: d.locally_modified ? "danger" : "primary", text: d.locally_modified ? "Sobrescrever com a versão do produto" : "Aceitar", onclick: () => guard(async () => {
          if (d.locally_modified && !confirm(`Substituir as alterações feitas aqui em ${name} pela versão do produto?`)) return;
          const a = await API.admin.productUpdateAccept(name, d.locally_modified);
          toast(`${name} atualizado para a versão ${a.version}.`);
          updates();
        }) }) : null,
        pending ? el("button", { class: "quiet", text: "Dispensar", onclick: () => guard(async () => {
          await API.admin.productUpdateDismiss(name); toast("Dispensada: só volta quando o produto mudar de novo."); updates();
        }) }) : null),
      tabs, compare);
    showView("installed");
  }

  // ------------------------------------------------------------------ navigation
  // ------------------------------------------------------------------ scheduler (spec 018)
  // ------------------------------------------------------------------ public API (spec 010)
  const API_KINDS = { confidential: "servidor (segredo)", browser: "navegador com login", publishable: "chave publicável (site)" };
  const lines = (v) => v.split(/[\n,]/).map((s) => s.trim()).filter(Boolean);

  function shownOnce(title, value, usage) {
    return el("div", { class: "secret-box" },
      el("div", { text: `${title} (copie agora: não será exibido novamente)` }),
      el("strong", { text: value }),
      usage ? el("div", { class: "muted", text: usage }) : null);
  }

  async function publicapi(tab = "clients", detail = null) {
    const tabs = el("div", { class: "sub-tabs" }, [["clients", "Clientes"], ["new", "Novo cliente"], ["calls", "Chamadas"]]
      .map(([k, l]) => el("button", { class: k === tab ? "active" : "", text: l, onclick: () => guard(() => publicapi(k)) })));
    const head = header("API pública", "Sistemas de terceiros, sites e aplicativos chamam programas expostos por /rpc. Cada cliente " +
      "executa como um usuário robô (toda chamada tem dono), só alcança os programas do seu escopo e tem limite por minuto e cota diária.");
    if (tab === "new") return apiClientNew(head, tabs);
    if (tab === "calls") return apiCallsView(head, tabs, detail);
    if (detail) return apiClientDetail(head, tabs, detail);
    const list = await API.admin.apiClients();
    main().replaceChildren(...head, tabs, table([
      { label: "Nome", value: (c) => c.name },
      { label: "Tipo", value: (c) => API_KINDS[c.kind] || c.kind },
      { label: "Executa como", value: (c) => c.run_as },
      { label: "Escopo", value: (c) => c.scopes.join(", ") || "—" },
      { label: "Hoje", value: (c) => String(c.today), class: "num" },
      { label: "Situação", value: (c) => apiClientState(c) },
    ], list, { empty: "Nenhum cliente: a API pública está fechada.", emptyAction: { label: "Novo cliente", onClick: () => guard(() => publicapi("new")) }, onRow: (c) => guard(() => publicapi("clients", c.client_id)) }),
    el("div", { class: "form-card" },
      el("h3", { text: "Chaves de assinatura dos tokens" }),
      el("p", { class: "muted", text: "Os tokens de acesso duram 10 minutos. Trocar a chave não derruba quem já tem token: a anterior segue valendo até eles vencerem." }),
      el("button", { type: "button", class: "quiet", text: "Trocar chave de assinatura", onclick: () => guard(async () => {
        if (!confirm("Gerar nova chave de assinatura dos tokens?")) return;
        await API.admin.rotateApiKeys(); toast("Nova chave de assinatura ativa.");
      }) })));
  }

  async function robotUsers() {
    return (await API.admin.users("")).filter((u) => u.kind === "robot" && u.active !== false);
  }

  async function apiClientNew(head, tabs) {
    const robots = await robotUsers();
    const name = el("input", { type: "text", placeholder: "ex.: Loja virtual" });
    const kind = el("select", {}, ...Object.entries(API_KINDS).map(([k, l]) => el("option", { value: k, text: l })));
    const runAs = el("select", {}, ...robots.map((u) => el("option", { value: u.username, text: u.username })));
    const scopes = el("textarea", { rows: 3, placeholder: "um por linha: sales.* ou sales.create_order" });
    const origins = el("textarea", { rows: 2, placeholder: "https://loja.exemplo.com.br (um por linha)" });
    const ips = el("input", { type: "text", placeholder: "IPs/redes permitidos, separados por vírgula (vazio = qualquer)" });
    const rate = el("input", { type: "number", min: 1, value: 600 });
    const quota = el("input", { type: "number", min: 1, placeholder: "vazio = sem cota" });
    const sign = el("input", { type: "checkbox" });
    const out = el("div");
    kind.addEventListener("change", () => { rate.value = kind.value === "publishable" ? 60 : 600; });
    const form = el("form", { class: "form-card" },
      robots.length ? null : el("p", { class: "warn-text", text: "Crie antes um usuário robô (Usuários → Novo, tipo robô) com o papel e os grupos que o cliente deve ter." }),
      field("Nome", name), field("Tipo", kind), field("Executa como (robô)", runAs), field("Escopo", scopes),
      field("Origens permitidas (sites)", origins), field("Endereços permitidos", ips),
      field("Chamadas por minuto", rate), field("Cota diária", quota),
      check("Exigir requisições assinadas (HMAC)", sign),
      el("div", { class: "row-buttons" }, el("button", { type: "submit", text: "Criar cliente" })), out);
    form.addEventListener("submit", (e) => { e.preventDefault(); guard(async () => {
      const r = await API.admin.createApiClient({
        name: name.value.trim(), kind: kind.value, run_as: runAs.value, scopes: lines(scopes.value), origins: lines(origins.value),
        ip_allow: lines(ips.value), rate_per_minute: parseInt(rate.value, 10) || 600,
        daily_quota: quota.value ? parseInt(quota.value, 10) : null, require_signature: sign.checked,
      });
      out.replaceChildren(el("p", {}, "Cliente criado: ", el("code", { text: r.client_id })),
        r.client_secret ? shownOnce("Segredo do cliente", r.client_secret, "POST /oauth/token com grant_type=client_credentials (Basic client_id:segredo)") : null,
        r.publishable_key ? shownOnce("Chave publicável", r.publishable_key, "Cabeçalho X-Api-Key; só programas marcados como públicos, só das origens cadastradas") : null);
      form.querySelector("button[type=submit]").disabled = true;
    }); });
    main().replaceChildren(...head, tabs, form);
  }

  // RNF-010-10: a client suspended by its circuit breaker says until when.
  const apiClientState = (c) => !c.active ? pill("desativado", "off")
    : c.suspended_until ? pill(`▲ suspenso até ${fmtDate(c.suspended_until)}`, "warn") : pill("ativo", "ok");

  async function apiClientDetail(head, tabs, id) {
    const c = (await API.admin.apiClients()).find((x) => x.client_id === id);
    if (!c) return publicapi();
    const out = el("div");
    const scopes = el("textarea", { rows: 3 }); scopes.value = c.scopes.join("\n");
    const origins = el("textarea", { rows: 2 }); origins.value = c.origins.join("\n");
    const ips = el("input", { type: "text", value: c.ip_allow.join(", ") });
    const rate = el("input", { type: "number", min: 1, value: c.rate_per_minute });
    const quota = el("input", { type: "number", min: 1, value: c.daily_quota ?? "" });
    const sign = el("input", { type: "checkbox" }); sign.checked = c.require_signature;
    const save = el("button", { type: "button", text: "Salvar", onclick: () => guard(async () => {
      await API.admin.updateApiClient(id, { scopes: lines(scopes.value), origins: lines(origins.value), ip_allow: lines(ips.value),
        rate_per_minute: parseInt(rate.value, 10), daily_quota: quota.value ? parseInt(quota.value, 10) : null, require_signature: sign.checked });
      toast("Cliente atualizado (vale em todos os nós em até 5 s).");
    }) });
    const toggle = el("button", { type: "button", class: c.active ? "danger" : "", text: c.active ? "Desativar" : "Reativar", onclick: () => guard(async () => {
      if (c.active && !confirm(`Desativar "${c.name}"? As chamadas param em até 5 s, mesmo com token válido.`)) return;
      await API.admin.updateApiClient(id, { active: !c.active }); publicapi("clients", id);
    }) });
    const secrets = c.kind === "confidential" ? el("div", { class: "row-buttons" },
      el("button", { type: "button", class: "quiet", text: "Gerar novo segredo", onclick: () => guard(async () => {
        const r = await API.admin.rotateApiSecret(id);
        out.replaceChildren(shownOnce("Novo segredo", r.client_secret, "O anterior continua valendo até você removê-lo: troque no sistema cliente e depois remova."));
      }) }),
      c.secrets > 1 ? el("button", { type: "button", class: "quiet", text: "Remover segredo anterior", onclick: () => guard(async () => {
        if (!confirm("Remover o segredo anterior? Quem ainda o usa deixa de obter tokens.")) return;
        await API.admin.dropOldApiSecret(id); toast("Segredo anterior removido."); publicapi("clients", id);
      }) }) : null) : null;
    const signing = el("button", { type: "button", class: "quiet", text: c.signing ? "Trocar chave de assinatura HMAC" : "Gerar chave de assinatura HMAC",
      onclick: () => guard(async () => {
        const r = await API.admin.apiSigningSecret(id);
        out.replaceChildren(shownOnce("Chave HMAC", r.signing_secret, "Cabeçalhos X-Ana-Timestamp, X-Ana-Nonce e X-Ana-Signature = HMAC-SHA256(método\\ncaminho\\ntimestamp\\nnonce\\nsha256(corpo))"));
      }) });
    main().replaceChildren(...head, tabs,
      el("div", { class: "form-card" },
        el("h3", { text: c.name }),
        el("p", {}, el("code", { text: c.client_id }), ` · ${API_KINDS[c.kind] || c.kind} · executa como ${c.run_as} · criado por ${c.created_by} em ${fmtDate(c.created_at)}`),
        el("p", {}, apiClientState(c), ` ${c.today} chamada(s) hoje`,
          Number(c.breaker_openings) ? ` · disjuntor abriu ${c.breaker_openings} vez(es) em 7 dias` : ""),
        c.suspended_until ? el("div", { class: "row-buttons" },
          el("p", { class: "muted", text: "Suspenso pelo disjuntor: falhas técnicas demais (erro interno, tempo esgotado) nas chamadas deste cliente. Corrija a causa (veja as chamadas) e libere, ou aguarde o fim do prazo." }),
          el("button", { type: "button", text: "Liberar agora", onclick: () => guard(async () => {
            await API.admin.releaseApiBreaker(id); toast("Cliente liberado (vale em todos os nós em até 5 s)."); publicapi("clients", id);
          }) })) : null,
        field("Escopo", scopes), field("Origens permitidas", origins), field("Endereços permitidos", ips),
        field("Chamadas por minuto", rate), field("Cota diária", quota), check("Exigir requisições assinadas (HMAC)", sign),
        el("div", { class: "row-buttons" }, save, toggle,
          el("button", { type: "button", class: "quiet", text: "Ver chamadas", onclick: () => guard(() => publicapi("calls", id)) })),
        secrets, el("div", { class: "row-buttons" }, signing), out));
  }

  async function apiCallsView(head, tabs, client) {
    const rows = await API.admin.apiCalls(client || "");
    main().replaceChildren(...head, tabs,
      client ? el("p", {}, "Cliente ", el("code", { text: client }), " ",
        el("button", { type: "button", class: "quiet small", text: "Todos", onclick: () => guard(() => publicapi("calls")) })) : null,
      table([
        { label: "Quando", value: (r) => fmtDate(r.at) },
        { label: "Cliente", value: (r) => r.client_id || "—" },
        { label: "Autenticação", value: (r) => r.auth },
        { label: "Programa", value: (r) => r.program || "—" },
        { label: "Situação", value: (r) => pill(String(r.status), r.status < 300 ? "ok" : r.status === 429 ? "warn" : "off") },
        { label: "ms", value: (r) => r.duration_ms == null ? "" : String(r.duration_ms), class: "num" },
        { label: "Origem", value: (r) => r.ip || "" },
      ], rows, { empty: "Nenhuma chamada registrada.", emptyGood: true }));
  }

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

  // ------------------------------------------------------------------ company values (spec 065)
  const VALUE_TYPES = { text: "texto", integer: "número inteiro", decimal: "decimal", date: "data", boolean: "sim/não",
                        month: "mês", reference: "cadastro" };
  const VALUE_SHAPES = { single: "simples", list: "lista", selection: "seleção" };
  const VALUE_STATUS = { pending: ["aguarda aprovação", "warn"], active: ["em uso", "ok"], refused: ["recusada", "off"],
                         withdrawn: ["retirada", "off"], replaced: ["substituída", ""] };
  const VALUE_ACTIONS = { defined: "criou", redefined: "mudou a definição", requested: "pediu mudança", activated: "mudou",
                          approved: "aprovou", refused: "recusou", withdrawn: "retirou", archived: "arquivou", restored: "restaurou",
                          kept: "mudou pela rotina", transported: "veio num transporte" };
  const INSTANCES = { development: "desenvolvimento", test: "teste", production: "produção" };
  let valuesMeta = null, valuesState = { q: "", area: "", archived: false, open: null };

  const brDate = (s) => (s && /^\d{4}-\d{2}-\d{2}$/.test(s) ? s.slice(8, 10) + "/" + s.slice(5, 7) + "/" + s.slice(0, 4) : s);
  function valueText(v, type, labels) {
    if (v === null || v === undefined) return "—";
    const one = (x) => {
      if (x === null || x === undefined) return "—";
      if (type === "boolean") return x ? "sim" : "não";
      if (type === "decimal") return String(x).replace(".", ",");
      if (type === "date") return brDate(String(x));
      if (type === "month" && /^\d{4}-\d{2}$/.test(x)) return x.slice(5) + "/" + x.slice(0, 4);
      if (type === "reference" && labels && labels[String(x)]) return `${x} — ${labels[String(x)]}`;
      return String(x);
    };
    if (Array.isArray(v)) return v.length ? v.map(one).join(", ") : "(lista vazia)";
    if (typeof v === "object") {
      const parts = [];
      if ((v.include || []).length) parts.push(v.include.map(one).join(", "));
      for (const [a, b] of v.ranges || []) parts.push(`de ${one(a)} a ${one(b)}`);
      for (const p of v.prefixes || []) parts.push(`começa com ${p}`);
      if (!parts.length) parts.push("todos");
      if ((v.exclude || []).length) parts.push("exceto " + v.exclude.map(one).join(", "));
      return parts.join("; ");
    }
    return one(v);
  }
  const exprLabel = (e) => {
    if (!e) return "";
    const m = /^([a-z_]+)([+-]\d+)?$/.exec(e);
    const x = valuesMeta && valuesMeta.expressions.find((t) => t.token === (m ? m[1] : e));
    if (!x) return e;
    const unit = { day: "dia(s)", month: "mês(es)" }[x.offset_unit] || "";
    return x.label.replace(/ \(± N .*\)$/, "") + (m && m[2] ? ` ${m[2][0]} ${m[2].slice(1)} ${unit}` : "");
  };
  function currentText(c, d) {
    if (!c) return el("span", { class: "muted", text: "sem valor em vigor" });
    return el("span", {}, el("strong", { text: valueText(c.value, d.value_type) }),
      c.expression ? el("span", { class: "muted small", text: ` (${exprLabel(c.expression)})` }) : null);
  }

  async function values() {
    if (!valuesMeta) valuesMeta = await API.values.meta();
    const st = valuesState;
    const r = await API.values.list({ q: st.q || undefined, area: st.area || undefined, archived: st.archived ? "1" : undefined });
    if (current !== "values") return;
    const side = el("div", { class: "value-side" });
    const search = el("input", { type: "search", value: st.q, placeholder: "Buscar por nome ou descrição…", "aria-label": "Buscar valores" });
    search.addEventListener("keydown", (e) => { if (e.key === "Enter") { st.q = search.value.trim(); values(); } });
    const area = el("select", { "aria-label": "Área", onchange: () => { st.area = area.value; values(); } },
      el("option", { value: "", text: "Todas as áreas" }), r.areas.map((a) => el("option", { value: a, text: a })));
    area.value = st.area;
    const arch = el("input", { type: "checkbox", onchange: () => { st.archived = arch.checked; values(); } });
    arch.checked = st.archived;
    const open = (n) => { st.open = n; valueDetail(n, side); };
    const groups = {};
    for (const v of r.values) (groups[v.area] = groups[v.area] || []).push(v);
    const lists = Object.keys(groups).sort().map((a) => el("section", { class: "value-area" },
      el("h3", { text: a }),
      table([
        { label: "Valor", value: (v) => el("span", {}, el("code", { text: v.name }), el("div", { class: "muted small", text: v.description })) },
        { label: "Hoje", value: (v) => currentText(v.current, v) },
        { label: "Próxima vigência", value: (v) => v.next ? `${brDate(v.next.valid_from)}: ${valueText(v.next.value, v.value_type)}${v.next.expression ? " (" + exprLabel(v.next.expression) + ")" : ""}` : "—" },
        { label: "", value: (v) => el("span", {}, v.sensitive ? pill("sensível", "warn") : null,
                                       v.pending ? pill(`${v.pending} aguardando aprovação`, "warn") : null,
                                       v.archived ? pill("arquivado", "off") : null,
                                       v.unused ? pill("sem uso há 180 dias: arquivar?", "warn") : null) },
      ], groups[a], { onRow: (v) => open(v.name) })));
    main().replaceChildren(
      ...header("Valores da empresa", "Valores de negócio com nome — período aberto, margem mínima, depósito principal, centros de custo de P&D — que as rotinas leem pelo nome (ana.value no Python, base.company_value no SQL). Mude aqui, com vigência, sem tocar em código."),
      el("div", { class: "admin-toolbar" }, search, area,
        el("button", { text: "Buscar", onclick: () => { st.q = search.value.trim(); values(); } }),
        el("label", { class: "check" }, arch, "Mostrar arquivados"),
        el("button", { class: "primary", text: "+ Novo valor", onclick: () => { st.open = null; side.replaceChildren(valueDefineForm(null)); } })),
      el("div", { class: "admin-columns" },
        el("div", {}, lists.length ? lists : el("p", { class: "empty-state muted" },
          el("span", { text: st.q || st.area ? "Nenhum valor com esse filtro. " : "Nenhum valor cadastrado. " }),
          el("button", { type: "button", class: "small", text: st.q || st.area ? "Limpar filtro" : "+ Novo valor",
            onclick: () => { if (st.q || st.area) { st.q = ""; st.area = ""; values(); } else side.replaceChildren(valueDefineForm(null)); } }))),
        side));
    if (st.open) valueDetail(st.open, side);
    else side.replaceChildren(el("p", { class: "muted", text: `Hoje é ${brDate(r.today)}; esta instância é de ${INSTANCES[r.instance] || r.instance}. Escolha um valor para ver a linha do tempo, mudar ou aprovar.` }));
  }

  // Live (spec 062): a value changed in another session or node — read again, keeping what is open.
  let valuesTimer = null;
  document.addEventListener("ana:values", () => {
    clearTimeout(valuesTimer);
    valuesTimer = setTimeout(() => {
      const area = document.querySelector("#area-admin");
      const editing = document.activeElement && document.activeElement.closest && document.activeElement.closest(".value-side form");
      if (current === "values" && area && !area.hidden && !editing) guard(values);
    }, 400);
  });

  async function valueDetail(name, side) {
    const d = await API.values.get(name);
    const def = d.definition;
    const actions = (v) => {
      const out = [];
      const act = (label, action, cls, ask) => el("button", { type: "button", class: "small " + (cls || ""), text: label, onclick: () => guard(async () => {
        let note = null;
        if (ask) { note = prompt(ask, ""); if (note === null) return; }
        await API.values.act(name, v.id, action, note);
        toast({ approve: "Mudança aprovada.", refuse: "Mudança recusada.", withdraw: "Versão retirada." }[action]);
        await values();
      }) });
      if (v.status === "pending" && d.can_edit && v.requested_by !== d.me) out.push(act("Aprovar", "approve", "primary"), act("Recusar", "refuse", "danger", "Motivo da recusa (opcional):"));
      if (v.status === "pending" && v.requested_by === d.me) out.push(el("span", { class: "muted small", text: "aguarda outra pessoa " }));
      if ((v.status === "pending" && (v.requested_by === d.me || d.can_edit)) || (v.status === "active" && v.valid_from > valuesMeta.today && d.can_edit))
        out.push(act("Retirar", "withdraw", "quiet"));
      return el("span", { class: "row-buttons" }, out);
    };
    const where = (v) => [v.instance ? INSTANCES[v.instance] : null, v.company || null].filter(Boolean).join(" · ") || "todas";
    const now = d.current || {};
    side.replaceChildren(
      el("h3", {}, el("code", { text: def.name })),
      el("p", { text: def.description }),
      el("p", {}, pill(VALUE_TYPES[def.value_type] || def.value_type), " ", pill(VALUE_SHAPES[def.shape] || def.shape),
        def.ref_kind ? pill((valuesMeta.reference_kinds.find((k) => k.kind === def.ref_kind) || {}).label || def.ref_kind) : null,
        def.sensitive ? pill("sensível: quatro olhos", "warn") : null, def.archived ? pill("arquivado", "off") : null),
      el("div", { class: "value-now" },
        el("div", { class: "muted small", text: "Em vigor hoje" }),
        now.error ? el("span", { class: "error", text: now.error })
          : el("div", { class: "value-big", text: valueText(now.value, def.value_type, (d.versions.find((v) => v.id === now.version) || {}).labels) }),
        now.expression ? el("div", { class: "muted small", text: `${exprLabel(now.expression)}, desde ${brDate(now.valid_from)}` })
          : now.valid_from ? el("div", { class: "muted small", text: `desde ${brDate(now.valid_from)}` }) : null),
      valuePreviewAt(name, def),
      el("h4", { text: "Linha do tempo" }),
      table([
        { label: "Vigência", value: (v) => brDate(v.valid_from) },
        { label: "Onde", value: (v) => where(v) },
        { label: "Valor", value: (v) => v.expression ? exprLabel(v.expression) : valueText(v.content, def.value_type, v.labels) },
        { label: "Situação", value: (v) => pill(...(VALUE_STATUS[v.status] || [v.status])) },
        { label: "Quem", value: (v) => el("span", { class: "small" }, v.requested_by, v.decided_by ? ` → ${v.decided_by}` : "",
                                          v.reason ? el("div", { class: "muted", text: v.reason }) : null) },
        { label: "", value: actions },
      ], d.versions, { empty: "Nenhuma versão ainda: informe o primeiro valor abaixo." }),
      valueUsage(d.usage, def),
      d.can_edit && !def.archived ? valueVersionForm(def, d) : null,
      d.can_edit ? el("details", { class: "value-def" }, el("summary", { text: "Definição" }), valueDefineForm(def, d.usage)) : null,
      !d.changes.length ? null : el("details", { class: "value-history" }, el("summary", { text: `Histórico (${d.changes.length})` }),
        table([
          { label: "Quando", value: (c) => fmtDate(c.at) },
          { label: "Quem", value: (c) => c.program ? `${c.program} (para ${c.username})` : c.username },
          { label: "O quê", value: (c) => VALUE_ACTIONS[c.action] || c.action },
          { label: "Antes → depois", value: (c) => el("span", { class: "small" }, change(c.before), " → ", change(c.after)) },
          { label: "Motivo", value: (c) => c.reason || "" },
        ], d.changes)));
    function change(x) {
      if (!x) return "—";
      if (x.expression) return exprLabel(x.expression) + (x.from ? ` desde ${brDate(x.from)}` : "");
      if ("content" in x) return valueText(x.content, def.value_type) + (x.from ? ` desde ${brDate(x.from)}` : "");
      if (x.status) return (VALUE_STATUS[x.status] || [x.status])[0];
      return Object.keys(x).filter((k) => k !== "name").map((k) => `${k}: ${x[k]}`).join(", ");
    }
  }

  // D8: who reads or keeps the value — shown before changing or archiving it.
  function usageCount(u) {
    if (!u) return 0;
    return ["programs", "libraries", "variants", "schedules", "alert_rules", "processes", "flows", "tax_rules"]
      .reduce((n, k) => n + (u[k] || []).length, 0);
  }
  function valueUsage(u, def) {
    if (!u) return null;
    const items = [];
    const add = (label, list, text, href) => { if ((list || []).length) items.push(el("li", {}, el("strong", { text: label + ": " }),
      ...list.map((x, i) => [i ? ", " : "", href ? el("a", { href: href(x), text: text(x) }) : text(x)]).flat())); };
    add("Mantido pelas rotinas", (u.maintained_by || []).map((p) => ({ p })), (x) => x.p, (x) => `#/dev/program/${x.p}`);
    add("Programas", u.programs, (x) => `${x.name} (linha ${x.line})${x.keeps ? " — mantém" : ""}`, (x) => `#/dev/program/${x.name}`);
    add("Bibliotecas", u.libraries, (x) => `${x.name} (linha ${x.line})`, (x) => `#/dev/program/${x.name}`);
    add("Variantes", u.variants, (x) => `${x.program} · ${x.name}${x.company ? " (empresa)" : ""}`);
    add("Agendamentos", u.schedules, (x) => `${x.name} (${x.program})`);
    add("Regras de alerta", u.alert_rules, (x) => x.name, () => "#/admin/alerts");
    add("Processos", u.processes, (x) => x.name);
    add("Esteiras", u.flows, (x) => x.name);
    add("Regras de imposto", u.tax_rules, (x) => x.name);
    const reads = u.reads && Number(u.reads.n) ? `${u.reads.n} execução(ões) leram nos últimos 180 dias; a última em ${fmtDate(u.reads.last)}.`
                                               : "Nenhuma execução leu este valor nos últimos 180 dias.";
    return el("details", { class: "value-usage", open: true }, el("summary", { text: `Onde é usado (${usageCount(u)})` }),
      items.length ? el("ul", {}, items) : el("p", { class: "muted", text: "Nenhum programa, variante, agendamento ou regra cita este valor pelo nome." }),
      el("p", { class: "muted small", text: reads }));
  }

  function valuePreviewAt(name, def) {
    const at = el("input", { type: "date", "aria-label": "Data de referência" });
    const out = el("span", { class: "muted", "aria-live": "polite" });
    return el("div", { class: "row-buttons value-preview" }, el("span", { class: "small", text: "Valor em outra data:" }), at,
      el("button", { type: "button", class: "small", text: "Ver", onclick: () => guard(async () => {
        if (!at.value) { at.focus(); return; }
        const r = await API.values.preview({ name, at: at.value });
        out.textContent = `${brDate(at.value)}: ${valueText(r.value, def.value_type)}${r.expression ? " (" + exprLabel(r.expression) + ")" : ""}`;
      }) }), out);
  }

  // The input for the content, by type and form (D1).
  function valueInput(def) {
    const t = def.value_type;
    const single = () => {
      if (t === "boolean") { const c = el("input", { type: "checkbox" }); return { node: el("label", { class: "check" }, c, "sim"), read: () => c.checked }; }
      const i = el("input", { "aria-label": "Valor", type: { date: "date", month: "month", integer: "number", decimal: "text" }[t] || "text",
        inputmode: t === "decimal" ? "decimal" : undefined, placeholder: t === "reference" ? "código do cadastro" : t === "decimal" ? "ex.: 18,5" : "" });
      return { node: i, read: () => (t === "integer" ? (i.value === "" ? null : Number(i.value)) : i.value.trim()) };
    };
    const items = (s) => s.split(/[\n,;]/).map((x) => x.trim()).filter(Boolean).map((x) => (t === "integer" ? Number(x) : x));
    if (def.shape === "list") {
      const a = el("textarea", { rows: 4, placeholder: "um por linha", "aria-label": "Itens da lista" });
      return { node: a, read: () => items(a.value) };
    }
    if (def.shape === "selection") {
      const inc = el("input", { placeholder: "ex.: 4100, 4200" }), rng = el("textarea", { rows: 2, placeholder: "uma faixa por linha, ex.: 4000 a 4999" });
      const pre = el("input", { placeholder: "ex.: 3.1" }), exc = el("input", { placeholder: "ex.: 4500" });
      return { node: el("div", { class: "value-selection" }, field("Incluir", inc), field("Faixas", rng),
                        t === "integer" ? null : field("Começa com", pre), field("Exceto", exc)),
               read: () => ({ include: items(inc.value), exclude: items(exc.value), prefixes: t === "integer" ? [] : items(pre.value),
                              ranges: rng.value.split("\n").map((l) => l.split(/\s+a\s+|\s*-\s*|\s*\.\.\s*/).map((x) => x.trim()))
                                .filter((p) => p.length === 2 && p[0] && p[1]).map((p) => (t === "integer" ? p.map(Number) : p)) }) };
    }
    return single();
  }

  function valueVersionForm(def, d) {
    const input = valueInput(def);
    const exprs = valuesMeta.expressions.filter((x) => ({ date: ["date"], month: ["month"], text: ["text", "datetime", "cost_center"],
      reference: def.ref_kind === "cost_center" ? ["cost_center"] : [] }[def.value_type] || []).includes(x.result_type));
    const mode = el("select", { "aria-label": "Forma do valor" }, el("option", { value: "fixed", text: "Valor fixo" }),
      def.shape === "single" && exprs.length ? el("option", { value: "expr", text: "Calculado (expressão)" }) : null);
    const expr = el("select", { "aria-label": "Expressão" }, exprs.map((x) => el("option", { value: x.token, text: x.label })));
    const offset = el("input", { type: "number", value: "0", step: "1", "aria-label": "Deslocamento", class: "narrow" });
    const exprBox = el("div", { class: "row-buttons", hidden: true }, expr, offset);
    const preview = el("span", { class: "muted small", "aria-live": "polite" });
    const exprValue = () => expr.value + (Number(offset.value) ? (Number(offset.value) > 0 ? "+" : "") + Number(offset.value) : "");
    const syncOffset = () => { const x = exprs.find((e) => e.token === expr.value); offset.hidden = !(x && x.offset_unit); if (offset.hidden) offset.value = "0"; };
    expr.addEventListener("change", syncOffset); syncOffset();
    mode.addEventListener("change", () => { exprBox.hidden = mode.value !== "expr"; input.node.hidden = mode.value === "expr"; });
    const from = el("input", { type: "date", value: valuesMeta.today, "aria-label": "Vigência a partir de" });
    const inst = el("select", { "aria-label": "Instância" }, el("option", { value: "", text: "todas as instâncias" }),
      Object.entries(INSTANCES).map(([k, l]) => el("option", { value: k, text: "só em " + l })));
    const co = el("select", { "aria-label": "Empresa" }, el("option", { value: "", text: "todas as empresas" }),
      valuesMeta.companies.map((c) => el("option", { value: c.id, text: c.legal_name })));
    const reason = el("textarea", { rows: 2, placeholder: def.reason_required ? "obrigatório" : "opcional" });
    return el("form", { class: "form-card", onsubmit: (e) => { e.preventDefault(); guard(async () => {
      const body = { valid_from: from.value || null, instance: inst.value || null, company_id: co.value ? Number(co.value) : null,
                     reason: reason.value.trim() || null };
      if (mode.value === "expr") body.expression = exprValue(); else body.content = input.read();
      const r = await API.values.propose(def.name, body);
      toast(r.status === "pending" ? "Pedido registrado: aguarda a aprovação de outra pessoa." : "Valor mudado.");
      await values();
    }); } },
      el("h4", { text: "Mudar o valor" }),
      def.sensitive ? el("p", { class: "muted small", text: "Valor sensível: a mudança fica pendente até outra pessoa com permissão aprovar." }) : null,
      field("Valor", el("div", {}, mode, input.node, exprBox,
        el("button", { type: "button", class: "small quiet", text: "Prévia", onclick: () => guard(async () => {
          if (mode.value !== "expr") { preview.textContent = valueText(input.read(), def.value_type); return; }
          const r = await API.values.preview({ expression: exprValue() });
          preview.textContent = "hoje: " + valueText(r.value, def.value_type);
        }) }), preview)),
      field("A partir de", from), field("Onde", el("div", { class: "row-buttons" }, inst, co)),
      field("Motivo", reason),
      el("div", { class: "row-buttons" }, el("button", { class: "primary", type: "submit", text: def.sensitive ? "Pedir aprovação" : "Salvar" })));
  }

  function valueDefineForm(def, usage) {
    const isNew = !def;
    const name = el("input", { value: def ? def.name : "", disabled: !isNew, placeholder: "ex.: financeiro.margem_minima" });
    const description = el("input", { value: def ? def.description : "" });
    const area = el("input", { value: def ? def.area : "", placeholder: "vazio = a primeira parte do nome" });
    const type = el("select", {}, Object.entries(VALUE_TYPES).map(([k, l]) => el("option", { value: k, text: l })));
    const shape = el("select", {}, Object.entries(VALUE_SHAPES).map(([k, l]) => el("option", { value: k, text: l })));
    const ref = el("select", {}, valuesMeta.reference_kinds.map((k) => el("option", { value: k.kind, text: k.label })));
    type.value = def ? def.value_type : "text"; shape.value = def ? def.shape : "single"; if (def && def.ref_kind) ref.value = def.ref_kind;
    const refField = field("Cadastro", ref);
    const sync = () => { refField.hidden = type.value !== "reference"; };
    type.addEventListener("change", sync); sync();
    const box = (label, on) => { const c = el("input", { type: "checkbox" }); c.checked = !!on; return [c, check(label, c)]; };
    const [sens, sensL] = box("Sensível: mudança só com aprovação de outra pessoa", def && def.sensitive);
    const [reas, reasL] = box("Exige motivo em cada mudança", def && def.reason_required);
    const [same, sameL] = box("Igual em todos os ambientes (o conteúdo viaja nos transportes)", def && def.same_everywhere);
    const keepers = el("input", { value: def ? (def.maintained_by || []).join(", ") : "", placeholder: "ex.: finance.close_period (separe por vírgula)",
                                  "aria-label": "Rotinas que mantêm o valor" });
    const body = () => ({ description: description.value.trim(), area: area.value.trim() || null, value_type: type.value, shape: shape.value,
                          ref_kind: type.value === "reference" ? ref.value : null, sensitive: sens.checked, reason_required: reas.checked,
                          same_everywhere: same.checked,
                          maintained_by: keepers.value.split(",").map((s) => s.trim()).filter(Boolean) });
    return el("form", { class: "form-card", onsubmit: (e) => { e.preventDefault(); guard(async () => {
      if (isNew) {
        const n = name.value.trim();
        await API.values.define({ name: n, ...body() });
        toast("Valor criado: informe agora o conteúdo.");
        valuesState.open = n;
      } else {
        const b = body(); if (!b.area) b.area = def.area;
        await API.values.redefine(def.name, b);
        toast("Definição salva.");
      }
      await values();
    }); } },
      el("h4", { text: isNew ? "Novo valor da empresa" : "Definição" }),
      field("Nome", name), field("Descrição", description), field("Área responsável", area),
      el("div", { class: "row-buttons" }, field("Tipo", type), field("Forma", shape), refField),
      sensL, reasL, sameL,
      field("Mantido pelas rotinas (ana.set_value)", keepers),
      isNew ? el("p", { class: "muted small", text: "Senhas, tokens e chaves não são valores da empresa: vão para o cofre dos conectores." }) : null,
      el("div", { class: "row-buttons" }, el("button", { class: "primary", type: "submit", text: isNew ? "Criar" : "Salvar definição" }),
        isNew ? null : el("button", { type: "button", class: def.archived ? "" : "danger", text: def.archived ? "Restaurar" : "Arquivar",
          onclick: () => guard(async () => {
            const n = usageCount(usage);
            if (!def.archived && !confirm(`Arquivar ${def.name}? ${n ? `${n} uso(s) listado(s) em "Onde é usado" deixam de funcionar — ` : ""}`
                                          + `as rotinas que o lerem passam a receber "valor arquivado". O histórico fica.`)) return;
            await API.values.redefine(def.name, { archived: !def.archived });
            toast(def.archived ? "Valor restaurado." : "Valor arquivado.");
            await values();
          }) })));
  }

  // ------------------------------------------------------------------ home panel (spec 048, RF-048-02)
  async function home() {
    const r = await API.admin.home();
    const routines = (await window.AnaOps.loadRoutines().catch(() => [])).slice().sort((a, b) => (a.description || a.name).localeCompare(b.description || b.name));
    const SIZES = [["small", "Pequeno"], ["medium", "Médio"], ["wide", "Largo"]];
    const groupsBox = (chosen) => {
      const box = el("div", { class: "check-list" }, ...r.groups.map((g) => check(g.name + (g.description ? ` — ${g.description}` : ""),
        el("input", { type: "checkbox", value: g.name, checked: chosen.includes(g.name) }))));
      box.value = () => [...box.querySelectorAll("input:checked")].map((i) => i.value);
      return box;
    };
    const spaceForm = (sp) => {
      const name = el("input", { value: sp ? sp.name : "", "aria-label": "Nome do espaço" });
      const desc = el("input", { value: sp ? sp.description : "", "aria-label": "Descrição do espaço" });
      const pos = el("input", { type: "number", value: sp ? sp.position : 0, "aria-label": "Ordem do espaço" });
      const groups = groupsBox(sp ? sp.access_groups : []);
      return el("form", { class: "form-card", onsubmit: (e) => { e.preventDefault(); guard(async () => {
        await API.admin.homeSpace(sp && sp.id, { name: name.value, description: desc.value, position: Number(pos.value) || 0, access_groups: groups.value() });
        toast("Espaço salvo."); home();
      }); } },
        el("h3", { text: sp ? `Espaço: ${sp.name}` : "Novo espaço" }),
        field("Nome", name), field("Descrição", desc), field("Ordem", pos),
        el("fieldset", {}, el("legend", { text: "Publicado para os grupos (nenhum marcado = todos)" }), groups),
        el("div", { class: "row-buttons" }, el("button", { class: "primary", type: "submit", text: sp ? "Salvar o espaço" : "Criar espaço" }),
          sp ? el("button", { type: "button", class: "danger", text: "Apagar o espaço", onclick: () => guard(async () => {
            if (!confirm(`Apagar o espaço "${sp.name}" e os blocos dele? Os usuários deixam de vê-lo.`)) return;
            await API.admin.homeSpaceDelete(sp.id); toast("Espaço apagado."); home();
          }) }) : null));
    };
    const blockForm = (sp) => {
      const title = el("input", { "aria-label": "Título do bloco" });
      const program = el("select", { "aria-label": "Rotina que o bloco abre" }, el("option", { value: "", text: "— rotina —" }),
        ...routines.map((x) => el("option", { value: x.name, text: `${x.description || x.name} (${x.name})` })));
      const variant = el("select", { "aria-label": "Variante da empresa" }, el("option", { value: "", text: "— sem variante —" }));
      const indicator = el("select", { "aria-label": "Indicador do bloco" }, el("option", { value: "", text: "— sem indicador —" }),
        ...r.indicators.map((i) => el("option", { value: i.name, text: `${i.description || i.name} (a cada ${Math.round(i.refresh_s / 60)} min)` })));
      const size = el("select", { "aria-label": "Tamanho do bloco" }, ...SIZES.map(([k, v]) => el("option", { value: k, text: v })));
      size.value = "medium";
      const pos = el("input", { type: "number", value: sp.blocks.length + 1, "aria-label": "Ordem do bloco" });
      program.addEventListener("change", () => guard(async () => {
        variant.replaceChildren(el("option", { value: "", text: "— sem variante —" }));
        if (!program.value) return;
        const vs = await API.runVariants.list(program.value).catch(() => ({ variants: [] }));
        for (const v of (vs.variants || []).filter((x) => x.owner === null && x.published)) variant.append(el("option", { value: String(v.id), text: v.name }));
        if (!title.value) title.value = (routines.find((x) => x.name === program.value) || {}).description || "";
      }));
      return el("form", { class: "form-card", onsubmit: (e) => { e.preventDefault(); guard(async () => {
        await API.admin.homeBlock(sp.id, null, { title: title.value, program: program.value, variant_id: variant.value ? Number(variant.value) : null,
                                                indicator: indicator.value || null, size: size.value, position: Number(pos.value) || 0 });
        toast("Bloco incluído."); home();
      }); } },
        el("h3", { text: `Novo bloco em ${sp.name}` }),
        field("Título", title), field("Abre a rotina", program), field("Com a variante (da empresa, publicada)", variant),
        field("Indicador (número, situação e linha curta)", indicator), field("Tamanho", size), field("Ordem", pos),
        el("div", { class: "row-buttons" }, el("button", { class: "primary", type: "submit", text: "Incluir bloco" })));
    };
    const as = el("input", { "aria-label": "Usuário para pré-visualizar", placeholder: "usuário" });
    const preview = el("div", { class: "home-preview" });
    main().replaceChildren(
      ...header("Painel inicial", "Espaços com blocos que a empresa publica para os grupos de acesso: cada bloco abre uma rotina (com variante, se quiser) e pode mostrar um indicador ao vivo. Quem não pode executar a rotina não vê o bloco; quem não pode executar o indicador vê o bloco sem o número."),
      ...r.spaces.map((sp) => el("section", { class: "card" }, spaceForm(sp),
        table([
          { label: "Ordem", value: (b) => b.position, class: "num" },
          { label: "Título", value: (b) => b.title },
          { label: "Abre", value: (b) => el("span", {}, el("code", { text: b.program }), b.variant_name ? ` · variante ${b.variant_name}` : "") },
          { label: "Indicador", value: (b) => (b.indicator ? el("code", { text: b.indicator }) : "—") },
          { label: "Tamanho", value: (b) => (SIZES.find(([k]) => k === b.size) || [0, b.size])[1] },
          { label: "", value: (b) => el("button", { class: "danger small", text: "Remover", onclick: () => guard(async () => {
            if (!confirm(`Remover o bloco "${b.title}"?`)) return;
            await API.admin.homeBlockDelete(b.id); toast("Bloco removido."); home();
          }) }) },
        ], sp.blocks, { empty: "Nenhum bloco neste espaço ainda.", emptyAction: { label: "Incluir bloco", onClick: () => main().querySelector(`#home-new-${sp.id} select`)?.focus() } }),
        el("div", { id: `home-new-${sp.id}` }, blockForm(sp)))),
      el("section", { class: "card" }, spaceForm(null)),
      el("section", { class: "card" }, el("h3", { text: "Ver como um usuário vê" }),
        el("form", { class: "row-buttons", onsubmit: (e) => { e.preventDefault(); guard(async () => {
          const v = await API.admin.homePreview(as.value.trim());
          preview.replaceChildren(...(v.spaces.length ? v.spaces.map((sp) => el("div", {}, el("strong", { text: sp.name }),
            el("ul", {}, ...sp.blocks.map((b) => el("li", { text: b.title + (b.indicator ? " · com indicador" : "") })))))
            : [el("p", { class: "muted", text: `${v.user} não vê nenhum espaço da empresa.` })]));
        }); } }, field("Usuário", as), el("button", { type: "submit", text: "Ver" })), preview));
  }

  // ------------------------------------------------------------------ assistant (spec 052)
  async function assistant() {
    const [cfg, conns, convs] = await Promise.all([API.admin.assistant(), API.admin.connectors().catch(() => []),
                                                   API.admin.assistantConversations().catch(() => [])]);
    const http = (Array.isArray(conns) ? conns : conns.connectors || []).filter((c) => c.kind === "http_api");
    const enabled = el("input", { type: "checkbox", checked: cfg.enabled });
    const provider = el("select", { "aria-label": "Provedor do modelo" },
      el("option", { value: "anthropic", text: "Modelo de linguagem (Claude) por conector" }),
      el("option", { value: "program", text: "Modelo local (sem internet): acha a rotina pelas palavras" }));
    provider.value = cfg.provider;
    const connector = el("select", { "aria-label": "Conector do modelo" }, el("option", { value: "", text: "— conector —" }),
      ...http.map((c) => el("option", { value: c.name, text: `${c.name} — ${c.base_url || ""}` })));
    connector.value = cfg.connector || "";
    const model = el("input", { value: cfg.model, "aria-label": "Modelo" });
    const effort = el("select", { "aria-label": "Esforço do modelo" }, ...[["low", "Baixo"], ["medium", "Médio"], ["high", "Alto"]].map(([k, v]) => el("option", { value: k, text: v })));
    effort.value = cfg.effort;
    const program = el("input", { value: cfg.program || "", "aria-label": "Programa do modelo local" });
    const daily = el("input", { type: "number", min: 1000, value: cfg.daily_tokens, "aria-label": "Limite diário de tokens por pessoa" });
    const blocked = el("input", { value: (cfg.blocked || []).join(", "), placeholder: "ex.: finance.close_period, tax.*", "aria-label": "Rotinas fora do alcance do assistente" });
    const viaConnector = el("div", {}, field("Conector (base https://api.anthropic.com, autenticação por chave no cabeçalho x-api-key, chave no cofre)", connector),
      field("Modelo", model), field("Esforço", effort));
    const viaProgram = el("div", {}, field("Programa do modelo local", program));
    const sync = () => { viaConnector.hidden = provider.value !== "anthropic"; viaProgram.hidden = provider.value !== "program"; };
    provider.addEventListener("change", sync);
    sync();
    const KIND = { question: "pergunta", answer: "resposta", query: "consulta", rehearsal: "ensaio", refused_tool: "ferramenta recusada",
                   confirmed: "confirmada e executada", declined: "recusada pela pessoa", expired: "expirou", failed: "falhou" };
    main().replaceChildren(
      ...header("Assistente", "Pergunte ou peça em linguagem natural. O assistente usa só as rotinas que a pessoa pode executar; o que só consulta roda na hora (sem poder gravar) e o que grava é ensaiado e só executa quando a pessoa confirma na tela. Dados pessoais vão mascarados ao modelo; tudo fica registrado abaixo."),
      el("form", { class: "form-card", onsubmit: (e) => { e.preventDefault(); guard(async () => {
        await API.admin.saveAssistant({ enabled: enabled.checked, provider: provider.value, connector: connector.value || null, model: model.value.trim(),
                                        effort: effort.value, program: program.value.trim() || null, daily_tokens: Number(daily.value) || 300000,
                                        blocked: blocked.value.split(",").map((x) => x.trim()).filter(Boolean) });
        toast("Assistente salvo."); if (window.AnaAssistant) window.AnaAssistant.refresh(); assistant();
      }); } },
        check("Ligado para os usuários", enabled), field("Provedor", provider), viaConnector, viaProgram,
        field("Limite diário por pessoa (tokens)", daily), field("Fora do alcance do assistente (nomes ou padrões)", blocked),
        el("div", { class: "row-buttons" }, el("button", { class: "primary", type: "submit", text: "Salvar" }))),
      el("h3", { text: "Conversas" }),
      table([
        { label: "Quando", value: (c) => fmtDate(c.updated_at) },
        { label: "Usuário", value: (c) => c.username },
        { label: "Assunto", value: (c) => c.title },
        { label: "Registro", value: (c) => el("ul", { class: "small" }, ...c.events.map((ev) => el("li", {},
            `${KIND[ev.kind] || ev.kind}${ev.program ? " · " + ev.program : ""}${ev.detail && ev.detail.text ? " — " + String(ev.detail.text).slice(0, 120) : ""}`,
            ev.execution_id ? el("span", { class: "muted", text: ` (execução ${ev.execution_id.slice(0, 8)})` }) : null))) },
      ], convs, { empty: "Nenhuma conversa ainda." }));
  }

  // ------------------------------------------------------------------ usage simulation (spec 067)
  const SIM_CATEGORY = { automation: "Automação", accounts: "Contas", usability: "Usabilidade", robustness: "Robustez",
                         performance: "Desempenho", access: "Acesso" };
  const SIM_SEVERITY = { critical: "crítico", serious: "sério", warning: "atenção", info: "informação" };
  let simSelected = null;
  async function simulation(runId) {
    const r = await API.admin.simulation();
    const days = el("input", { type: "number", min: 1, max: 60, value: 1, "aria-label": "Dias simulados" });
    const perDay = el("input", { type: "number", min: 1, max: 200, value: 6, "aria-label": "Cenários por dia" });
    const seed = el("input", { type: "number", min: 0, placeholder: "nova", "aria-label": "Semente" });
    const flows = el("input", { type: "checkbox" });
    const report = el("div", { class: "sim-report" });
    const STATUS = { running: "em andamento", done: "concluída", failed: "falhou", stopped: "parada" };
    main().replaceChildren(
      ...header("Uso simulado", "Personas (usuários robô com acesso real) percorrem as esteiras inteiras — venda, compra, campo, produção, projeto, estoque — com variação e erros humanos, e apontam furos de automação, contas e robustez. Roda na instância de testes (nunca na produção), à noite pela rotina agendada \"uso.simulado\" ou aqui. A semente de um achado o reproduz."),
      el("form", { class: "form-card inline", onsubmit: (e) => { e.preventDefault(); guard(async () => {
        const s = await API.admin.simulationRun({ days: Number(days.value) || 1, per_day: Number(perDay.value) || 6,
                                                  seed: seed.value === "" ? null : Number(seed.value), flows: flows.checked });
        toast(`Simulação ${s.id} começou (semente ${s.seed}).`); simulation(s.id);
      }); } },
        field("Dias", days), field("Cenários por dia", perDay), field("Semente", seed), check("Ligar os passos automáticos das esteiras", flows),
        el("div", { class: "row-buttons" }, el("button", { class: "primary", type: "submit", text: "Rodar agora" }))),
      el("h3", { text: "Rodadas" }),
      table([
        { label: "Nº", value: (x) => x.id, class: "num" },
        { label: "Situação", value: (x) => STATUS[x.status] || x.status },
        { label: "Início", value: (x) => fmtDate(x.started_at) },
        { label: "Semente", value: (x) => x.seed },
        { label: "Dias × cenários", value: (x) => `${x.days} × ${x.per_day}` },
        { label: "Passos", value: (x) => (x.stats && x.stats.steps) || "—", class: "num" },
        { label: "Achados", value: (x) => `${x.findings}${x.new ? ` (${x.new} novo${x.new > 1 ? "s" : ""})` : ""}` },
        { label: "", value: (x) => el("button", { type: "button", class: "quiet small", text: "Ver", onclick: () => guard(() => show(x.id)) }) },
      ], r.runs, { empty: "Nenhuma simulação ainda.", emptyAction: { label: "Rodar agora", onClick: () => days.focus() } }),
      report,
      el("h3", { text: "Personas" }),
      table([
        { label: "Persona", value: (p) => p.label },
        { label: "Usuário robô", value: (p) => el("code", { text: "sim_" + p.name }) },
        { label: "Papel", value: (p) => p.role },
        { label: "Erros humanos", value: (p) => `${Math.round(p.error_rate * 100)}%` },
      ], r.personas, { empty: "Nenhuma persona." }));
    async function show(id) {
      const x = await API.admin.simulationReport(id);
      simSelected = id;                       // the screen is redrawn by live events: the chosen run stays
      const byCat = {};
      for (const f of x.findings) (byCat[f.category] = byCat[f.category] || []).push(f);
      report.replaceChildren(el("section", { class: "card" },
        el("h3", { text: `Simulação ${x.id} — semente ${x.seed} — ${STATUS[x.status] || x.status}` }),
        x.status === "running" ? el("button", { type: "button", class: "quiet small", text: "Parar", onclick: () => guard(async () => {
          await API.admin.simulationStop(x.id); toast("Simulação parada."); simulation(x.id); }) }) : null,
        el("p", { class: "muted", text: x.stats && x.stats.steps ? `${x.stats.steps} passos em ${x.stats.scenarios} cenários; ${x.stats.mistakes} erros humanos simulados; ${x.stats.failed} passos sem sucesso.` : (x.reason || "") }),
        x.findings.length ? null : el("p", { text: x.status === "done" ? "Nenhum furo encontrado nesta rodada." : "" }),
        ...Object.entries(byCat).map(([cat, list]) => el("div", {}, el("h4", { text: `${SIM_CATEGORY[cat] || cat} (${list.length})` }),
          el("ul", { class: "sim-findings" }, ...list.map((f) => el("li", {},
            el("strong", { text: f.title }), " ", pill(f.trend === "new" ? "novo" : "persistente", f.trend === "new" ? "warn" : ""),
            " ", el("span", { class: "muted small", text: `${SIM_SEVERITY[f.severity] || f.severity}${f.scenario ? " · cenário " + f.scenario : ""}${f.persona ? " · persona " + f.persona : ""} · semente ${f.seed}` }),
            f.steps && f.steps.length ? el("details", {}, el("summary", { text: `Passos para reproduzir (${f.steps.length})` }),
              el("ol", {}, ...f.steps.map((st) => el("li", { class: "small", text: `${st.persona}: ${st.program} ${JSON.stringify(st.params)} → ${st.ok ? "ok" : (st.code || "falhou")}${st.mistake ? " (erro humano)" : ""}` })))) : null))))),
        x.resolved && x.resolved.length ? el("div", {}, el("h4", { text: "Resolvidos desde a rodada anterior" }),
          el("ul", {}, ...x.resolved.map((g) => el("li", { text: g.title })))) : null));
    }
    const pick = runId || simSelected;
    if (pick) await guard(() => show(pick));
  }

  // ------------------------------------------------------------------ automations (spec 051)
  // D1: everything that runs by itself in one list; D2: rules "quando… então…" with the condition builder, rehearsed
  // before they are turned on; D3: suggestions from usage (analysed in the background, here on demand).
  const AUTO_KIND = { schedule: "Agendamento", flow: "Esteira", process: "Processo", rule: "Regra", alert: "Alerta", connector: "Conector" };
  const RULE_TRIGGER = { created: "Documento criado", status: "Mudança de situação", changed: "Campo alterado (cadastro ou documento)",
                         schedule: "Horário", metric: "Limite de métrica", message: "Mensagem recebida" };
  // Spec 068 (D1, D6, D12): where a change came from, and one firing per record or grouped.
  const ORIGIN = { screen: "Tela", api: "API", import: "Importação", rule: "Outra regra", integration: "Integração", routine: "Rotina", other: "Outra" };
  const WATCH_MODE = { auto: "Automático (agrupa importação, rotina e lotes acima de 20)", record: "Um disparo por registro", grouped: "Um disparo agrupado" };
  const CLASS_MARK = { secret: "🔒", personal: "👤" };
  const CLASS_TEXT = { secret: "sigiloso", personal: "dado pessoal (LGPD)" };
  const watchFieldLabel = (f) => `${f.label}${CLASS_MARK[f.classification] ? " " + CLASS_MARK[f.classification] : ""}`;
  // "Quando" of a rule in words; the field labels come from the catalog when it is at hand.
  function ruleWhen(x, cat) {
    if (x.trigger_kind === "changed") {
      const w = cat && cat.watchable.find((e) => e.entity === x.entity);
      const labels = (x.watch_fields || []).map((ref) => { const f = w && w.fields.find((y) => y.ref === ref); return f ? watchFieldLabel(f) : ref.split(".").pop(); });
      return `Alterado · ${x.entity_label || x.entity}${x.watch_key ? " " + x.watch_key : ""} · ${labels.join(", ")}`;
    }
    return `${RULE_TRIGGER[x.trigger_kind]}${x.entity_label ? " · " + x.entity_label : ""}${x.status_to ? " → " + x.status_to : ""}${x.cron ? " · " + x.cron : ""}${x.metric ? ` · ${x.metric} ${x.metric_op} ${x.metric_value}` : ""}${x.connector ? " · " + x.connector : ""}`;
  }
  const RULE_ACTION = { task: "Criar tarefa", run: "Executar rotina", notify: "Avisar", email: "Enviar e-mail", connector: "Chamar conector" };
  const FIRE = { done: "feito", failed: "falhou", blocked: "bloqueada", rehearsal: "ensaio", skipped: "pulado" };
  let autoFilter = { kind: "", state: "", q: "" };
  async function automations() {
    const parts = (location.hash.split("?")[0] || "").split("/");       // #/admin/automations/rules/<id>
    if (parts[3] === "rules") return parts[4] === "new" ? ruleEditor(null) : parts[4] ? ruleDetail(Number(parts[4])) : rulesList();
    const r = await API.admin.automations();
    const kind = el("select", { "aria-label": "Tipo" }, el("option", { value: "", text: "Todos os tipos" }),
      ...Object.entries(AUTO_KIND).map(([v, l]) => el("option", { value: v, text: l })));
    const state = el("select", { "aria-label": "Situação" }, ...[["", "Todas"], ["on", "Ligadas"], ["off", "Desligadas"], ["failing", "Com falha"]]
      .map(([v, l]) => el("option", { value: v, text: l })));
    const q = el("input", { type: "search", placeholder: "Buscar por nome, dono ou rotina", "aria-label": "Buscar" });
    kind.value = autoFilter.kind; state.value = autoFilter.state; q.value = autoFilter.q;
    const box = el("div");
    const draw = () => {
      autoFilter = { kind: kind.value, state: state.value, q: q.value };
      const term = q.value.trim().toLowerCase();
      const items = r.items.filter((i) => (!kind.value || i.kind === kind.value)
        && (!state.value || (state.value === "on" ? i.active : state.value === "off" ? !i.active : i.failures > 0))
        && (!term || [i.name, i.owner, i.program, i.description].some((x) => x && String(x).toLowerCase().includes(term))));
      box.replaceChildren(table([
        { label: "Tipo", value: (i) => i.kind_label },
        { label: "Nome", value: (i) => el("a", { href: i.link, text: i.name || String(i.id) }) },
        { label: "Dono", value: (i) => i.owner || "—" },
        { label: "Situação", value: (i) => pill(i.active ? "ligada" : "desligada", i.active ? "on" : "off") },
        { label: "Último resultado", value: (i) => i.last_at ? `${fmtDate(i.last_at)}${i.last_status ? " · " + (FIRE[i.last_status] || i.last_status) : ""}` : "—" },
        { label: "Próxima", value: (i) => i.next_at ? fmtDate(i.next_at) : "—" },
        { label: "Falhas", value: (i) => i.failures ? el("span", { class: "error", title: i.last_error || "", text: `${i.failures}${i.last_error ? " — " + String(i.last_error).slice(0, 80) : ""}` }) : "—" },
        { label: "", value: (i) => el("div", { class: "row-buttons" },
            i.toggle ? el("button", { type: "button", class: "quiet small", text: i.active ? "Desligar" : "Ligar",
              onclick: () => guard(async () => { await API.admin.automationActive(i.kind, i.id, !i.active); toast(i.active ? "Desligada." : "Ligada."); automations(); }) }) : null,
            i.kind === "rule" ? el("button", { type: "button", class: "quiet small", text: "Abrir", onclick: () => window.AnaStudio.go(i.link) }) : null) },
      ], items, { empty: r.items.length ? "Nada com esse filtro." : "Nada roda sozinho ainda.",
                  emptyAction: { label: "Criar uma regra", onClick: () => window.AnaStudio.go("#/admin/automations/rules/new") } }));
    };
    for (const x of [kind, state]) x.addEventListener("change", draw);
    q.addEventListener("input", draw);
    const s = r.summary;
    main().replaceChildren(
      ...header("Automações", "Tudo o que roda sozinho, num lugar só: agendamentos e rotinas do produto, esteiras, processos, regras \"quando… então…\", alertas e conectores — com dono, último resultado, próxima execução e as falhas com o motivo. Liga e desliga pelo mesmo caminho da tela de cada um."),
      el("p", { class: "muted", text: `${s.total} automações · ${s.active} ligadas · ${s.failing} com falha` }),
      el("div", { class: "row-buttons" },
        el("button", { type: "button", class: "primary", text: "Regras \"quando… então…\"", onclick: () => window.AnaStudio.go("#/admin/automations/rules") }),
        el("button", { type: "button", class: "quiet", text: "Analisar o uso agora (sugestões)", onclick: () => guard(async () => {
          const a = await API.admin.analyzeSuggestions();
          toast(`Uso analisado: ${a.schedule} sugestão(ões) de agendar e ${a.variant} de variante.`); }) })),
      el("div", { class: "md-toolbar" }, kind, state, q), box);
    draw();
  }

  async function rulesList() {
    const [rules, cat] = await Promise.all([API.admin.rules(), API.admin.rulesCatalog()]);
    main().replaceChildren(
      ...header("Regras \"quando… então…\"", "Quando um documento é criado ou muda de situação, quando um campo de um cadastro ou documento é alterado, num horário, quando uma métrica passa do limite ou quando chega uma mensagem — se as condições valem, então a regra cria uma tarefa, executa uma rotina, avisa, envia e-mail ou chama um conector. Sem programar. Toda regra tem dono, é ensaiada antes de ligar e nunca entra em laço."),
      el("div", { class: "row-buttons" },
        el("button", { type: "button", class: "primary", text: "Nova regra", onclick: () => window.AnaStudio.go("#/admin/automations/rules/new") }),
        el("button", { type: "button", class: "quiet", text: "Voltar às automações", onclick: () => window.AnaStudio.go("#/admin/automations") })),
      table([
        { label: "Regra", value: (x) => el("a", { href: `#/admin/automations/rules/${x.id}`, text: x.name }) },
        { label: "Quando", value: (x) => ruleWhen(x, cat) },
        { label: "Então", value: (x) => RULE_ACTION[x.action.kind] || x.action.kind },
        { label: "Dono", value: (x) => x.owner },
        { label: "Situação", value: (x) => x.blocked_reason ? pill("bloqueada", "off") : pill(x.active ? "ligada" : x.rehearsed_version === x.version ? "ensaiada" : "a ensaiar", x.active ? "on" : "") },
        { label: "Disparos", value: (x) => `${x.fired}${x.failed ? ` (${x.failed} com falha)` : ""}`, class: "num" },
        { label: "Agrupados", value: (x) => x.trigger_kind === "changed" ? String(x.grouped) : "—", class: "num" },
        { label: "Fora do alcance", value: (x) => x.trigger_kind === "changed" ? (x.out_of_reach ? el("span", { class: "warn", title: "Mudanças que o dono da regra não pode ver: não dispararam", text: String(x.out_of_reach) }) : "0") : "—", class: "num" },
      ], rules, { empty: "Nenhuma regra ainda.", emptyAction: { label: "Nova regra", onClick: () => window.AnaStudio.go("#/admin/automations/rules/new") } }));
  }

  async function ruleEditor(rule) {
    const cat = await API.admin.rulesCatalog();
    // Spec 068 (CA-068-10): from a record's history, "Avisar quando mudar" arrives with the entity, the record and the field.
    const q = new URLSearchParams(location.hash.split("?")[1] || "");
    const from = !rule && q.get("entity") ? { entity: q.get("entity"), key: q.get("key"), field: q.get("field"), back: q.get("back") } : null;
    const fromEntity = from && cat.watchable.find((w) => w.entity === from.entity);
    const fromField = fromEntity && from.field && fromEntity.fields.find((f) => f.ref === from.field);
    const r = rule || (from ? { trigger_kind: "changed", entity: from.entity, watch_key: from.key || null,
                                watch_fields: fromField ? [fromField.ref] : [], watch_filter: {}, watch_origins: null, watch_mode: "auto",
                                name: fromEntity ? `Avisar: ${fromField ? fromField.label : "alteração"} de ${fromEntity.label}${from.key ? " " + from.key : ""}`.slice(0, 120) : "",
                                conditions: [], max_fires: 20, window_minutes: 60,
                                // A message ready to save: the field before and after, who changed it (the facts of the change).
                                action: { kind: "notify", user: window.AnaStudio.user().username,
                                          message: fromField ? `${fromEntity.label} {{key}}: ${fromField.label} mudou de {{${fromField.ref.split(".").pop()}_before}} para {{${fromField.ref.split(".").pop()}}} (por {{changed_by}})`
                                                             : `${fromEntity ? fromEntity.label : "Registro"} {{key}} foi alterado por {{changed_by}}` },
                                owner: window.AnaStudio.user().username }
      : { trigger_kind: "created", conditions: [], action: { kind: "task", task_kind: "human" }, max_fires: 20, window_minutes: 60,
          owner: window.AnaStudio.user().username });
    const cancelTo = rule ? `#/admin/automations/rules/${rule.id}` : from && from.back ? from.back : "#/admin/automations/rules";
    const opt = (list, value, blank) => [blank ? el("option", { value: "", text: blank }) : null,
      ...list.map((x) => Array.isArray(x) ? el("option", { value: x[0], text: x[1] }) : el("option", { value: x, text: x }))]
      .filter(Boolean).map((o) => { if (o.value === String(value ?? "")) o.selected = true; return o; });
    const name = el("input", { value: r.name || "", required: true, maxlength: 120 });
    const desc = el("input", { value: r.description || "" });
    const owner = el("select", {}, ...opt(cat.users, r.owner));
    const trig = el("select", {}, ...opt(Object.entries(RULE_TRIGGER), r.trigger_kind));
    const entity = el("select", {}, ...opt(cat.documents.map((d) => [d.entity, d.label]), r.entity));
    const status = el("select", {});
    const cron = el("input", { value: r.cron || "0 8 * * 1-5", placeholder: "minuto hora dia mês dia-da-semana" });
    const metric = el("select", {}, ...opt(cat.metrics, r.metric));
    const op = el("select", {}, ...opt([">", ">=", "<", "<="], r.metric_op || ">"));
    const mval = el("input", { type: "number", step: "any", value: r.metric_value ?? "" });
    const conn = el("select", {}, ...opt(cat.connectors, r.connector, "—"));
    // Spec 068: what is watched — the catalog only, by label, with the classification shown (D12).
    const wentity = el("select", { "aria-label": "Cadastro ou documento vigiado" },
      ...opt(cat.watchable.map((w) => [w.entity, `${w.label}${w.source === "document" ? " (documento)" : ""}`]), r.trigger_kind === "changed" ? r.entity : "", "— escolha —"));
    const wf = r.watch_filter || {};
    const wkey = el("input", { value: r.watch_key || "", placeholder: "todos", "aria-label": "Só o registro", size: 12 });
    const wfrom = el("input", { value: wf.from ?? "", placeholder: "qualquer", "aria-label": "Valor antes" });
    const wto = el("input", { value: wf.to ?? "", placeholder: "qualquer", "aria-label": "Valor depois" });
    const wbecame = el("select", { "aria-label": "Ficou" }, ...opt([["empty", "esvaziado"], ["filled", "preenchido"]], wf.became, "—"));
    const wdir = el("select", { "aria-label": "Direção" }, ...opt([["up", "subiu (número ou data adiada)"], ["down", "desceu (número ou data antecipada)"]], wf.direction, "—"));
    const wpct = el("input", { type: "number", min: 0.01, step: "any", value: wf.min_change_pct ?? "", placeholder: "qualquer", "aria-label": "Variação mínima (%)" });
    const wmode = el("select", { "aria-label": "Disparo" }, ...opt(Object.entries(WATCH_MODE), r.watch_mode || "auto"));
    const defaultOrigins = Object.keys(ORIGIN).filter((o) => o !== "import");
    const chosenOrigins = r.watch_origins || defaultOrigins;
    const worigins = Object.entries(ORIGIN).map(([v, l]) => {
      const c = el("input", { type: "checkbox", value: v });
      c.checked = chosenOrigins.includes(v);
      return el("label", { class: "check" }, c, ` ${l}`);
    });
    let watchFields = [...(r.watch_fields || [])];
    const fieldsBox = el("div", { class: "check-list", role: "group", "aria-label": "Campos vigiados" });
    const filterBox = el("div");
    const drawWatch = () => {
      const w = cat.watchable.find((x) => x.entity === wentity.value);
      watchFields = watchFields.filter((ref) => w && w.fields.some((f) => f.ref === ref));
      fieldsBox.replaceChildren(...(w ? w.fields.map((f) => {
        const c = el("input", { type: "checkbox", value: f.ref });
        c.checked = watchFields.includes(f.ref);
        c.addEventListener("change", () => { watchFields = c.checked ? [...watchFields, f.ref] : watchFields.filter((x) => x !== f.ref); drawFilter(); });
        return el("label", { class: "check", title: CLASS_TEXT[f.classification] || "" }, c, ` ${watchFieldLabel(f)}`,
          CLASS_MARK[f.classification] ? el("span", { class: "sr-only", text: ` (${CLASS_TEXT[f.classification]})` }) : null);
      }) : [el("p", { class: "muted", text: "Escolha o cadastro ou documento." })]));
      drawFilter();
      drawConditions();
    };
    const drawFilter = () => {
      const w = cat.watchable.find((x) => x.entity === wentity.value);
      const chosen = w ? w.fields.filter((f) => watchFields.includes(f.ref)) : [];
      const secret = chosen.some((f) => f.classification === "secret");
      const personal = chosen.some((f) => f.classification === "personal");
      for (const x of [wfrom, wto, wbecame, wdir, wpct]) x.disabled = secret;
      filterBox.replaceChildren(
        secret ? el("p", { class: "muted small", text: "🔒 Campo sigiloso: só \"foi alterado\" — o valor nunca é comparado nem mostrado, e só um administrador cria a regra." }) : null,
        personal ? el("p", { class: "muted small", text: "👤 Dado pessoal (LGPD): só sai por um conector autorizado a receber dados pessoais (com quatro olhos)." }) : null,
        el("div", { class: "form-grid" }, field("De (antes)", wfrom), field("Para (depois)", wto), field("Ficou", wbecame),
          field("Direção", wdir), field("Variação mínima (%)", wpct)));
    };
    wentity.addEventListener("change", drawWatch);
    const readWatch = () => {
      const f = {};
      if (wfrom.value !== "" && !wfrom.disabled) f.from = wfrom.value;
      if (wto.value !== "" && !wto.disabled) f.to = wto.value;
      if (wbecame.value && !wbecame.disabled) f.became = wbecame.value;
      if (wdir.value && !wdir.disabled) f.direction = wdir.value;
      if (wpct.value !== "" && !wpct.disabled) f.min_change_pct = Number(wpct.value);
      const os = worigins.map((l) => l.querySelector("input")).filter((c) => c.checked).map((c) => c.value);
      const same = os.length === defaultOrigins.length && defaultOrigins.every((o) => os.includes(o));
      return { entity: wentity.value, watch_fields: watchFields, watch_filter: f, watch_key: wkey.value.trim() || null,
               watch_origins: same ? null : os, watch_mode: wmode.value };
    };
    const trigBox = el("div", { class: "form-grid" });
    let conditions = r.conditions;
    const condBox = el("div");
    const drawConditions = () => {
      const doc = cat.documents.find((d) => d.entity === (trig.value === "changed" ? wentity.value : entity.value));
      const fields = (["created", "status", "changed"].includes(trig.value) && doc ? doc.fields : []).map((f) => ({ ...f, label: f.name.replace(/_/g, " ") }));
      condBox.replaceChildren(window.AnaConditions.builder({ fields, value: conditions, free: true, onChange: (c) => { conditions = c; } }).node,
        el("p", { class: "muted small", text: "Sem condição, a regra vale para todo evento. Os campos são os fatos do documento (os mesmos das esteiras)." }));
    };
    const drawTrigger = () => {
      const doc = cat.documents.find((d) => d.entity === entity.value);
      status.replaceChildren(...opt(doc ? doc.statuses : [], r.status_to, "qualquer situação"));
      const k = trig.value;
      trigBox.replaceChildren(...(k === "created" ? [field("Documento", entity)]
        : k === "status" ? [field("Documento", entity), field("Quando passa para", status)]
        : k === "changed" ? [field("Cadastro ou documento", wentity), field("Só o registro (código)", wkey),
            el("fieldset", { class: "wide" }, el("legend", { text: "Campos — quando qualquer um mudar" }), fieldsBox,
              el("p", { class: "muted small", text: "🔒 sigiloso · 👤 dado pessoal (LGPD)" })),
            el("fieldset", { class: "wide" }, el("legend", { text: "Como mudou (vazio: qualquer mudança)" }), filterBox),
            el("fieldset", { class: "wide" }, el("legend", { text: "Mudanças vindas de" }), el("div", { class: "check-list" }, ...worigins),
              el("p", { class: "muted small", text: "Importação fica de fora por padrão: uma carga de milhares de linhas não vira milhares de avisos." })),
            field("Disparo", wmode),
            cat.high_volume.length ? el("p", { class: "muted small wide", text: `Não vigiados por campo (muito movimento): ${cat.high_volume.map((h) => `${h.label} — ${h.alternative}`).join(" ")}` }) : null]
        : k === "schedule" ? [field("Horário (cron)", cron)]
        : k === "metric" ? [field("Métrica", metric), field("Comparação", op), field("Limite", mval)]
        : [field("Conector", conn)]));
      if (k === "changed") drawWatch(); else drawConditions();
    };
    trig.addEventListener("change", drawTrigger);
    entity.addEventListener("change", drawTrigger);
    const a = r.action;
    const act = el("select", {}, ...opt(Object.entries(RULE_ACTION), a.kind));
    const inp = (k, v, extra = {}) => el("input", { value: v ?? "", "data-k": k, ...extra });
    const actBox = el("div", { class: "form-grid" });
    const routines = el("datalist", { id: "rule-routines" });
    API.routines().then((list) => routines.replaceChildren(...list.map((x) => el("option", { value: x.name, label: x.description })))).catch(() => {});
    const drawAction = () => {
      const k = act.value;
      const jsonBox = (key, v) => el("textarea", { "data-k": key, "data-json": "1", rows: 3, text: JSON.stringify(v || {}, null, 1) });
      actBox.replaceChildren(...(k === "task" ? [
          field("Tarefa", inp("name", a.name, { placeholder: "Aprovar pedido acima do limite" })),
          field("Tipo", el("select", { "data-k": "task_kind" }, ...opt([["human", "Fazer"], ["approval", "Aprovar ou recusar"]], a.task_kind))),
          field("Para o grupo", el("select", { "data-k": "group" }, ...opt(cat.groups, a.group, "—"))),
          field("Ou para a pessoa", el("select", { "data-k": "assignee" }, ...opt(cat.users, a.assignee, "—"))),
          field("Instruções", inp("instructions", a.instructions)),
          field("Rotina para abrir (opcional)", inp("program", a.program, { list: "rule-routines" }))]
        : k === "run" ? [field("Rotina", inp("program", a.program, { list: "rule-routines", required: true })),
                         field("Parâmetros (use {{campo}} para os fatos)", jsonBox("params", a.params))]
        : k === "notify" ? [field("Pessoa", el("select", { "data-k": "user" }, ...opt(cat.users, a.user, "—"))),
                            field("Ou grupo", el("select", { "data-k": "group" }, ...opt(cat.groups, a.group, "—"))),
                            field("Mensagem ({{campo}} vale)", inp("message", a.message))]
        : k === "email" ? [field("Para", inp("to", a.to, { type: "email" })), field("Assunto ({{campo}} vale)", inp("subject", a.subject)),
                           field("Texto", el("textarea", { "data-k": "text", rows: 3, text: a.text || "" }))]
        : [field("Conector", el("select", { "data-k": "connector" }, ...opt(cat.connectors, a.connector))),
           field("Tipo da mensagem", inp("message_kind", a.message_kind, { placeholder: "pedido.grande" })),
           field("Conteúdo (JSON; {{campo}} vale)", jsonBox("payload", a.payload))]), routines);
    };
    act.addEventListener("change", drawAction);
    const max = el("input", { type: "number", min: 1, max: 10000, value: r.max_fires });
    const win = el("input", { type: "number", min: 1, max: 10080, value: r.window_minutes });
    const readAction = () => {
      const out = { kind: act.value };
      for (const x of actBox.querySelectorAll("[data-k]")) {
        if (x.value === "") continue;
        out[x.dataset.k] = x.dataset.json ? JSON.parse(x.value) : x.value;
      }
      return out;
    };
    main().replaceChildren(
      ...header(rule ? `Regra: ${rule.name}` : "Nova regra", "Quando… (o gatilho), se… (as condições), então… (a ação). Salvar não liga a regra: ensaie primeiro."),
      el("form", { class: "form-card", onsubmit: (e) => { e.preventDefault(); guard(async () => {
        const body = { id: rule ? rule.id : null, name: name.value, description: desc.value, owner: owner.value, trigger_kind: trig.value,
                       entity: entity.value, status_to: status.value || null, cron: cron.value, metric: metric.value, metric_op: op.value,
                       metric_value: mval.value === "" ? null : Number(mval.value), connector: conn.value || null,
                       conditions, action: readAction(), max_fires: Number(max.value), window_minutes: Number(win.value),
                       ...(trig.value === "changed" ? readWatch() : {}) };
        const res = await API.admin.saveRule(body);
        toast("Regra salva. Ensaie para poder ligar.");
        window.AnaStudio.go(`#/admin/automations/rules/${res.id}`);
      }); } },
        el("div", { class: "form-grid" }, field("Nome", name), field("Dono (responde pela regra)", owner), field("Descrição", desc)),
        el("h3", { text: "Quando" }), field("Gatilho", trig), trigBox,
        el("h3", { text: "Se" }), condBox,
        el("h3", { text: "Então" }), field("Ação", act), actBox,
        el("h3", { text: "Limites (nunca em laço)" }),
        el("div", { class: "form-grid" }, field("No máximo (disparos)", max), field("Em (minutos)", win)),
        el("div", { class: "row-buttons" }, el("button", { class: "primary", type: "submit", text: "Salvar" }),
          el("button", { type: "button", class: "quiet", text: "Cancelar", onclick: () => window.AnaStudio.go(cancelTo) }))));
    drawTrigger();
    drawAction();
    if (from && !fromEntity) toast("Este cadastro não pode ser vigiado: escolha um do catálogo.");
    else if (from && from.field && !fromField) toast("Este campo não pode ser vigiado: escolha um dos campos do catálogo.");
    name.focus();
  }

  function watchFilterText(f) {
    f = f || {};
    const parts = [];
    if (f.from !== undefined) parts.push(`de ${f.from}`);
    if (f.to !== undefined) parts.push(`para ${f.to}`);
    if (f.became) parts.push(f.became === "empty" ? "esvaziado" : "preenchido");
    if (f.direction) parts.push(f.direction === "up" ? "subiu" : "desceu");
    if (f.min_change_pct !== undefined) parts.push(`variou ${f.min_change_pct}% ou mais`);
    return parts.length ? parts.join(", ") : "qualquer mudança";
  }

  function effectView(e) {
    if (!e) return el("p", { class: "muted", text: "Nada a fazer: as condições não valem para este documento." });
    const tables = e.tables || [], held = e.held || [], messages = e.messages || [];
    return el("div", {},
      tables.length ? el("ul", {}, ...tables.map((t) => el("li", { text: `${t.label || t.table}: ${t.rows} ${t.change === "created" ? "criado(s)" : t.change === "deleted" ? "excluído(s)" : "alterado(s)"}` }))) : null,
      messages.length ? el("ul", {}, ...messages.map((m) => el("li", { text: `sairia: ${m.kind || "mensagem"}${m.connector ? " pelo conector " + m.connector : ""}` }))) : null,
      held.length ? el("ul", {}, ...held.map((h) => el("li", { text: `retido: ${h.kind}${h.name ? " " + h.name : ""}` }))) : null,
      !tables.length && !messages.length && !held.length ? el("p", { class: "muted", text: "A ação não mudaria nada." }) : null);
  }

  async function ruleDetail(id) {
    const r = await API.admin.rule(id);
    const changed = r.trigger_kind === "changed";
    const cat = changed ? await API.admin.rulesCatalog() : null;
    const wfields = changed ? ((cat.watchable.find((w) => w.entity === r.entity) || {}).fields || []) : [];
    const refLabel = (ref) => { const f = wfields.find((y) => y.ref === ref); return f ? watchFieldLabel(f) : ref.split(".").pop(); };
    const doc = el("input", { placeholder: changed ? "todos" : "o último", "aria-label": changed ? "Registro para o ensaio" : "Documento para o ensaio", size: 10 });
    const out = el("div", { class: "card", hidden: true });
    const rehearsed = r.rehearsed_version === r.version;
    main().replaceChildren(
      ...header(`Regra: ${r.name}`, r.description || ""),
      r.blocked_reason ? el("p", { class: "error", text: `Bloqueada em ${fmtDate(r.blocked_at)}: ${r.blocked_reason}. Corrija e ensaie de novo para ligar.` }) : null,
      el("dl", { class: "kv" },
        el("dt", { text: "Quando" }), el("dd", { text: ruleWhen(r, cat) }),
        changed ? el("dt", { text: "Como mudou" }) : null,
        changed ? el("dd", { text: watchFilterText(r.watch_filter) }) : null,
        changed ? el("dt", { text: "Vindas de" }) : null,
        changed ? el("dd", { text: `${(r.watch_origins || Object.keys(ORIGIN).filter((o) => o !== "import")).map((o) => ORIGIN[o] || o).join(", ")} · ${WATCH_MODE[r.watch_mode] || r.watch_mode}` }) : null,
        el("dt", { text: "Se" }), el("dd", { text: window.AnaConditions.describe(r.conditions, []) || "sempre" }),
        el("dt", { text: "Então" }), el("dd", { text: `${RULE_ACTION[r.action.kind]}${r.action.name ? ": " + r.action.name : ""}${r.action.program ? " · " + r.action.program : ""}${r.action.group ? " · grupo " + r.action.group : ""}` }),
        el("dt", { text: "Dono" }), el("dd", { text: r.owner }),
        el("dt", { text: "Limite" }), el("dd", { text: `${r.max_fires} disparo(s) em ${r.window_minutes} minuto(s)` }),
        el("dt", { text: "Situação" }), el("dd", {}, pill(r.active ? "ligada" : "desligada", r.active ? "on" : "off"), " ",
          rehearsed ? pill("ensaiada nesta versão", "") : pill("a ensaiar", "warn"))),
      el("div", { class: "row-buttons" },
        doc,
        el("button", { type: "button", class: rehearsed ? "quiet" : "primary", text: "Ensaiar", onclick: () => guard(async () => {
          const x = await API.admin.rehearseRule(id, doc.value || null);
          out.hidden = false;
          out.replaceChildren(
            // Spec 068 (D12, CA-068-10): over the real changes of the last days — "teria disparado 7 vezes: …".
            changed && x.history ? el("div", {},
              el("h3", { text: x.would_have_fired ? `Teria disparado ${x.would_have_fired} ${x.would_have_fired === 1 ? "vez" : "vezes"} nos últimos ${x.days} dias`
                                                  : `Não teria disparado nos últimos ${x.days} dias` }),
              x.examples && x.examples.length ? el("ul", { class: "rehearsal-examples" }, ...x.examples.map((e) => el("li", { text:
                `${fmtDate(e.at)} · registro ${e.key}${e.by ? " · por " + e.by : ""} · ` +
                Object.entries(e.changes).map(([ref, [b, a]]) => `${refLabel(ref)}: ${b ?? "—"} → ${a ?? "—"}`).join("; ") }))) : null)
            : changed ? el("p", { class: "muted", text: "Documentos não guardam o histórico campo a campo: o ensaio usa o documento como está agora." }) : null,
            el("h3", { text: changed ? `Ação ensaiada ${x.document ? "no registro " + x.document : "(sem mudança para ensaiar)"}` : `Ensaio no documento ${x.document ?? "—"}` }),
            x.document === null && changed ? null
              : el("p", { text: x.conditions_hold ? "As condições valem: a regra faria isto (nada foi gravado):" : `As condições não valem para este ${changed ? "registro" : "documento"}.` }),
            x.conditions_hold ? effectView(x.effect) : null,
            x.error ? el("p", { class: "error", text: `A ação falharia: ${x.error.message}` }) : null,
            el("details", {}, el("summary", { text: "Fatos do documento" }), el("pre", { class: "small", text: JSON.stringify(x.facts, null, 1) })),
            x.rehearsed ? el("button", { type: "button", class: "primary", text: "Ligar a regra", onclick: () => guard(async () => {
              await API.admin.automationActive("rule", id, true); toast("Regra ligada."); ruleDetail(id); }) }) : null);
        }) }),
        el("button", { type: "button", class: "quiet", text: r.active ? "Desligar" : "Ligar", onclick: () => guard(async () => {
          await API.admin.automationActive("rule", id, !r.active); toast(r.active ? "Regra desligada." : "Regra ligada."); ruleDetail(id); }) }),
        el("button", { type: "button", class: "quiet", text: "Editar", onclick: () => guard(() => ruleEditor(r)) }),
        el("button", { type: "button", class: "quiet danger", text: "Excluir", onclick: () => guard(async () => {
          if (!confirm(`Excluir a regra "${r.name}" e o histórico dela? Não dá para desfazer.`)) return;
          await API.admin.deleteRule(id); toast("Regra excluída."); window.AnaStudio.go("#/admin/automations/rules"); }) })),
      out,
      el("h3", { text: "Histórico" }),
      table([
        { label: "Quando", value: (f) => fmtDate(f.at) },
        { label: changed ? "Registro" : "Documento", value: (f) => f.doc_key || "—" },
        { label: "Resultado", value: (f) => pill(FIRE[f.outcome] || f.outcome, f.outcome === "done" ? "on" : f.outcome === "rehearsal" ? "" : "off") },
        { label: "Detalhe", value: (f) => el("span", {},
            f.count > 1 && f.outcome !== "skipped" ? pill(`agrupado: ${f.count} registros`, "") : null,
            f.detail && f.detail.out_of_reach ? pill(`${f.detail.out_of_reach} fora do alcance do dono`, "warn") : null, " ",
            f.detail && (f.detail.reason || (f.detail.error && f.detail.error.message)) || (f.execution_id ? el("a", { href: `#/ops/executions/${f.execution_id}`, text: "execução" }) : "")) },
        { label: "Por", value: (f) => f.by || "" },
      ], r.fires, { empty: "Ainda não disparou.", emptyGood: true }));
  }

  // Spec 077 (T-077-03): the technical center — the work of keeping the ERP up, organized by the work.
  const central = () => window.AnaTech.render(main(), { header, guard });
  const SECTIONS = { central, users, groups, settings, company, values, home, assistant, simulation, automations, commands, remote, accounts, limits, consumption, scheduler, monitor, audit, retention, health, alerts, core, disk, uiperf, sqlperf, advice, updates, integrations, checks, transports, datacopy, publicapi, license, extensions, telemetry };

  function show(section) {
    refreshUpdatesCount();
    current = section;
    if (!SECTIONS[section]) section = "users";
    current = section;
    for (const b of $$("#area-admin .nav-link")) b.classList.toggle("active", b.dataset.section === section);
    main().replaceChildren(el("p", { class: "muted", text: "Carregando…" }));
    return guard(() => SECTIONS[section]());
  }

  function wire() {
    for (const b of $$("#area-admin .nav-link")) b.addEventListener("click", () => window.AnaStudio.go("#/admin/" + b.dataset.section));
  }

  window.AnaAdmin = { wire, show, current: () => current, lineDiff };
})();
