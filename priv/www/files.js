// SPDX-FileCopyrightText: 2026 André Luis Pereira dos Santos
// SPDX-License-Identifier: AGPL-3.0-or-later
// File repository (spec 016) and the external portal (RF-016-04).
// Content is never handled by this page: downloads go through short-lived signed
// URLs issued by the core after the permission check.
"use strict";
(function () {
  const API = window.AnaApi;
  const { $, el, fmtDate, errorText, toast, table, pill, splitter } = window.AnaUI;
  const LEVELS = { 1: "ver", 2: "baixar", 3: "enviar", 4: "gerenciar" };
  const SUBJECTS = [["user", "Usuário"], ["group", "Grupo"], ["role", "Papel"], ["party", "Cliente/fornecedor (id)"]];
  const CHUNK = 8 * 1024 * 1024;
  let current = null;

  const main = () => $("#files-main");
  async function guard(fn) { try { return await fn(); } catch (e) { toast(errorText(e), true); return undefined; } }

  function size(n) {
    if (n === null || n === undefined) return "";
    if (n < 1024) return `${n} B`;
    if (n < 1048576) return `${(n / 1024).toFixed(1)} KB`;
    return `${(n / 1048576).toFixed(1)} MB`;
  }

  async function show(rest = []) {
    const folder = rest[0] === "f" ? Number(rest[1]) : null;
    const file = rest[2] === "file" ? Number(rest[3]) : null;
    await browse(folder, file);
  }

  async function browse(folder, openFile) {
    current = folder;
    const data = await API.files.list(folder);
    const detail = el("div", { class: "files-detail" }, el("p", { class: "muted", text: "Escolha um arquivo para ver versões, acessos e histórico." }));
    const crumbs = el("div", { class: "breadcrumbs" },
      el("button", { class: "linkish", text: "Arquivos", onclick: () => go(null) }),
      ...(data.path || []).flatMap((p) => [" ▸ ", el("button", { class: "linkish", text: p.name, onclick: () => go(p.id) })]));
    const picker = el("input", { type: "file", multiple: true, hidden: true });
    picker.addEventListener("change", () => upload([...picker.files]));
    const progress = el("div", { class: "upload-progress" });
    const search = el("input", { type: "search", placeholder: "Buscar arquivos por nome…", "aria-label": "Buscar arquivos por nome" });
    search.addEventListener("keydown", (e) => { if (e.key === "Enter" && search.value.trim()) guard(() => results(search.value.trim())); });
    const canUpload = data.level >= 3 && folder !== null;
    const list = el("div", { class: "files-list" },
      table([
        { label: "Nome", value: (r) => r.kind === "folder"
            ? el("span", {}, el("button", { class: "linkish icon-text", onclick: () => go(r.id) }, window.AnaUI.icon("folder", 16),
                                el("span", { text: r.name })),
                 r.external ? el("span", { class: "pill ok external-pill", text: "para parceiros", title: "Clientes/fornecedores podem ter acesso" }) : null)
            : el("button", { class: "linkish icon-text", onclick: () => guard(() => fileDetail(r.id, detail)) }, window.AnaUI.icon("file", 16),
                 el("span", { text: r.name })) },
        { label: "Versão", value: (r) => r.version ? `v${r.version}` : "" },
        { label: "Tamanho", value: (r) => size(r.size) },
        { label: "Atualizado", value: (r) => r.updated_at ? fmtDate(r.updated_at) : "" },
        { label: "Acesso", value: (r) => LEVELS[r.level] || "" },
      ], [...data.folders.map((f) => ({ ...f, kind: "folder" })), ...data.files.map((f) => ({ ...f, kind: "file" }))],
      { empty: folder === null ? "Nenhuma pasta disponível para você." : "Pasta vazia." }));
    if (canUpload) {
      list.addEventListener("dragover", (e) => { e.preventDefault(); list.classList.add("drop"); });
      list.addEventListener("dragleave", () => list.classList.remove("drop"));
      list.addEventListener("drop", (e) => { e.preventDefault(); list.classList.remove("drop"); upload([...e.dataTransfer.files]); });
    }
    const split = el("div", { class: "files-split" }, list, detail);
    split.insertBefore(splitter(split, "--files-list-w", { min: 280, max: 1200, key: "files" }), detail);
    main().replaceChildren(
      el("h2", { text: "Arquivos" }),
      el("p", { class: "lead", text: "Documentos de projetos, clientes e fornecedores, com versões e acesso controlado. Arraste arquivos para a lista para enviar." }),
      crumbs,
      // Spec 037: what is inside a folder for partners can reach customers/suppliers; elsewhere never.
      folder !== null && data.external ? el("p", { class: "notice-external", text:
        "Pasta para clientes/fornecedores: o que estiver aqui pode ser compartilhado com eles. Documentos internos ficam fora." }) : null,
      el("div", { class: "row-buttons" },
        folder !== null && document.body.classList.contains("is-admin")
          ? el("button", { class: "quiet", text: data.external ? "Tornar pasta interna" : "Marcar como pasta para parceiros",
                           onclick: () => guard(async () => {
                             const msg = data.external
                               ? "Tornar interna? Clientes e fornecedores perdem o acesso que tinham aqui."
                               : "Marcar como pasta para clientes/fornecedores? Só ponha aqui o que eles podem ver.";
                             if (!window.confirm(msg)) return;
                             await API.files.setExternal(folder, !data.external);
                             browse(folder);
                           }) }) : null,
        data.level >= 3 ? el("button", { text: "Nova pasta", onclick: () => guard(async () => {
          const name = prompt("Nome da pasta");
          if (!name) return;
          await API.files.createFolder(folder, name.trim());
          browse(folder);
        }) }) : null,
        canUpload ? el("button", { class: "primary", text: "Enviar arquivos", onclick: () => picker.click() }) : null,
        folder !== null && data.level >= 2 ? el("button", { text: "Baixar pasta (ZIP)", onclick: () => guard(async () => {
          const r = await API.files.zip(folder); window.location.href = r.url; }) }) : null,
        search, picker),
      progress,
      split);
    if (openFile) guard(() => fileDetail(openFile, detail));

    async function upload(files) {
      for (const f of files) {
        const bar = el("div", { class: "upload-line", text: `${f.name}: enviando…` });
        progress.append(bar);
        try {
          let r;
          if (f.size <= CHUNK) r = await API.files.uploadSmall(folder, f.name, f);
          else {
            const up = await API.files.uploadInit(folder, f.name, f.size);
            let offset = up.received;
            while (offset < f.size) {
              try {
                const res = await API.files.uploadChunk(up.id, offset, f.slice(offset, offset + CHUNK));
                offset = res.received;
              } catch (e) {
                // Resumes from what the server already has (network drop, retry).
                offset = (await API.files.uploadStatus(up.id)).received;
              }
              bar.textContent = `${f.name}: ${Math.floor((offset / f.size) * 100)}%`;
            }
            r = await API.files.uploadComplete(up.id);
          }
          bar.textContent = `${f.name}: enviado (v${r.version})`;
          bar.classList.add("ok");
        } catch (e) {
          bar.textContent = `${f.name}: ${errorText(e)}`;
          bar.classList.add("error");
        }
      }
      const data2 = await API.files.list(folder).catch(() => null);
      if (data2) browse(folder);
    }
  }

  function go(folder) { window.AnaStudio.go(folder === null ? "#/files" : `#/files/f/${folder}`); }

  async function results(q) {
    const rows = await API.files.search({ q });
    main().replaceChildren(el("h2", { text: `Busca: ${q}` }),
      el("div", { class: "row-buttons" }, el("button", { class: "quiet", text: "← Voltar às pastas", onclick: () => browse(current) })),
      table([
        { label: "Arquivo", value: (r) => el("button", { class: "linkish", text: r.name,
                                                         onclick: () => window.AnaStudio.go(`#/files/f/${r.folder_id}/file/${r.id}`) }) },
        { label: "Pasta", value: (r) => r.folder },
        { label: "Versão", value: (r) => `v${r.version}` },
        { label: "Tamanho", value: (r) => size(r.size) },
        { label: "Atualizado", value: (r) => fmtDate(r.updated_at) },
      ], rows, { empty: "Nada encontrado (ou sem acesso)." }));
  }

  async function fileDetail(id, box) {
    const d = await API.files.detail(id);
    const f = d.file;
    const manage = d.level >= 4;
    const download = (version, inline) => guard(async () => {
      const r = await API.files.download(id, version, inline);
      if (inline) window.open(r.url, "_blank", "noopener"); else window.location.href = r.url;
    });
    const parts = [
      el("h3", { text: f.name }),
      el("p", { class: "muted small", text: `Versão atual v${f.version} · seu acesso: ${LEVELS[d.level]}` }),
      el("div", { class: "row-buttons" },
        d.level >= 2 ? el("button", { class: "primary", text: "Baixar", onclick: () => download(null, false) }) : null,
        d.level >= 2 && /^(application\/pdf|image\/|text\/plain)/.test(d.versions[0].mime) ?
          el("button", { text: "Visualizar", onclick: () => download(null, true) }) : null,
        manage ? el("button", { class: "quiet", text: "Excluir", onclick: () => guard(async () => {
          if (!confirm(`Excluir ${f.name}? As versões continuam no histórico.`)) return;
          await API.files.remove(id); browse(current); }) }) : null),
      el("h4", { text: "Versões" }),
      table([
        { label: "Versão", value: (v) => `v${v.version}` },
        { label: "Tamanho", value: (v) => size(v.size) },
        { label: "Autor", value: (v) => v.created_by },
        { label: "Data", value: (v) => fmtDate(v.created_at) },
        { label: "Comentário", value: (v) => v.comment },
        { label: "", value: (v) => d.level >= 2 ? el("button", { class: "small", text: "Baixar", onclick: () => download(v.version, false) }) : "" },
      ], d.versions),
    ];
    if (manage) {
      const kind = el("select", {}, SUBJECTS.map(([v, l]) => el("option", { value: v, text: l })));
      const subject = el("input", { placeholder: "login, grupo, papel ou id" });
      const level = el("select", {}, [["view", "ver"], ["download", "baixar"], ["upload", "enviar"], ["manage", "gerenciar"]]
        .map(([v, l]) => el("option", { value: v, text: l, selected: v === "download" })));
      const deny = el("input", { type: "checkbox" });
      parts.push(el("h4", { text: "Acessos" }),
        table([
          { label: "Sujeito", value: (g) => `${(SUBJECTS.find((s) => s[0] === g.subject_kind) || [, g.subject_kind])[1]}: ${g.subject}` },
          { label: "Nível", value: (g) => g.deny ? pill("negado", "warn") : g.level },
          { label: "Onde", value: (g) => g.scope },
          { label: "Validade", value: (g) => g.expires_at ? fmtDate(g.expires_at) : "—" },
          { label: "", value: (g) => el("button", { class: "small quiet", text: "Remover", onclick: () => guard(async () => {
              await API.files.revoke(g.id); fileDetail(id, box); }) }) },
        ], d.grants, { empty: "Sem acessos específicos (vale o da pasta)." }),
        el("form", { class: "inline-form", onsubmit: (e) => { e.preventDefault(); guard(async () => {
          await API.files.grant({ file_id: id, subject_kind: kind.value, subject: subject.value.trim(), level: level.value, deny: deny.checked });
          fileDetail(id, box); }); } },
          kind, subject, level, el("label", { class: "check" }, deny, "negar"), el("button", { type: "submit", text: "Conceder" })));
      const hours = el("input", { type: "number", min: 1, max: 720, value: 24 });
      const maxd = el("input", { type: "number", min: 1, placeholder: "sem limite" });
      const pass = el("input", { type: "password", autocomplete: "new-password", placeholder: "opcional" });
      const created = el("div");
      parts.push(el("h4", { text: "Links de compartilhamento" }),
        table([
          { label: "#", value: (l) => l.id },
          { label: "Validade", value: (l) => fmtDate(l.expires_at) },
          { label: "Downloads", value: (l) => `${l.downloads}${l.max_downloads ? " / " + l.max_downloads : ""}` },
          { label: "Senha", value: (l) => l.has_password ? "sim" : "não" },
          { label: "Situação", value: (l) => l.revoked ? pill("revogado", "off") : pill("ativo", "ok") },
          { label: "", value: (l) => l.revoked ? "" : el("button", { class: "small quiet", text: "Revogar", onclick: () => guard(async () => {
              await API.files.unlink(l.id); fileDetail(id, box); }) }) },
        ], d.links, { empty: "Nenhum link." }),
        el("form", { class: "inline-form", onsubmit: (e) => { e.preventDefault(); guard(async () => {
          const r = await API.files.link(id, { hours: Number(hours.value), max_downloads: maxd.value ? Number(maxd.value) : null,
                                                password: pass.value || null });
          const url = location.origin + r.url;
          created.replaceChildren(el("div", { class: "secret-box" }, el("div", { text: "Copie agora: o endereço não será mostrado de novo." }),
            el("code", { text: url })));
        }); } }, el("label", {}, "Horas ", hours), el("label", {}, "Máx. downloads ", maxd), el("label", {}, "Senha ", pass),
          el("button", { type: "submit", text: "Criar link" })),
        created,
        el("h4", { text: "Histórico" }),
        table([
          { label: "Quando", value: (ev) => fmtDate(ev.at) },
          { label: "Ação", value: (ev) => ev.action },
          { label: "Versão", value: (ev) => ev.version ? `v${ev.version}` : "" },
          { label: "Quem", value: (ev) => ev.username || "link público" },
          { label: "IP", value: (ev) => ev.ip || "" },
        ], d.events, { empty: "Sem registros." }));
    }
    box.replaceChildren(...parts);
  }

  // ------------------------------------------------------------------ portal (external accounts)
  async function portal(rest = []) {
    const list = await API.portalPrograms();
    const out = el("div", { class: "output" });
    const runBox = el("div");
    const open = (p, initial) => {
      // Spec 035: a document row opens docs.view (or another portal routine) with its parameters.
      const ctx = { run: (program, params) => API.run(program, { params }), open: (program, params) => openByName(program, params),
                    refresh: () => null, lookup: () => Promise.resolve([]) };
      const form = window.AnaRunner.paramsForm(p.params, { initial: initial || {}, submitLabel: "Consultar", onSubmit: () => guard(async () => {
        out.replaceChildren(el("p", { class: "muted", text: "Consultando…" }));
        const res = await API.run(p.name, { params: form.read() });
        out.replaceChildren();
        const events = res.events || (res.error && res.error.events) || [];
        for (const ev of events) if (ev.type === "output") window.AnaRunner.drawOutput(out, ev, ctx);
        if (res.error) out.append(el("div", { class: "end error", text: res.error.message || res.error.code }));
      }) });
      runBox.replaceChildren(el("h3", { text: p.description || p.name }), form.node);
      out.replaceChildren();
      if (initial || !p.params || !Object.keys(p.params).length || Object.values(p.params).every((s) => !s.required)) form.node.requestSubmit();
    };
    const openByName = (name, params) => { const p = list.find((x) => x.name === name); if (p) open(p, params); };
    $("#portal-main").replaceChildren(
      el("h2", { text: "Portal" }),
      el("p", { class: "lead", text: "Consultas liberadas para você. Os documentos compartilhados ficam em Arquivos." }),
      el("div", { class: "row-buttons" }, list.map((p) => el("button", { text: p.description || p.name, onclick: () => open(p) }))),
      list.length ? null : el("p", { class: "muted", text: "Nenhuma consulta liberada." }),
      runBox, out);
    if (rest[0]) openByName(rest[0]); else if (list.length === 1) open(list[0]);
  }

  window.AnaFiles = { show, portal };
})();
