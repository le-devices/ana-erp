// ANA shell (spec 020): authentication, areas by role, hash routing (#/…) and
// the global "go to" bar. Area contents live in ops.js, dev.js and admin.js.
"use strict";
(function () {
  const API = window.AnaApi;
  const { $, $$, el, toast } = window.AnaUI;
  const R = window.AnaRunner;

  const ROLE_LEVEL = { user: 1, developer: 2, admin: 3 };
  const ADMIN_SECTIONS = {
    users: "Usuários", groups: "Grupos de acesso", limits: "Limites e cotas", company: "Empresa",
    settings: "Parâmetros", accounts: "Contas padrão", commands: "Comandos", remote: "Sistemas remotos",
    scheduler: "Agendamento", monitor: "Monitor", consumption: "Consumo", audit: "Auditoria", retention: "Retenção",
    health: "Saúde", sqlperf: "Desempenho do SQL", advice: "Dicas de otimização", updates: "Atualizações do produto",
    integrations: "Integrações", checks: "Verificações", transports: "Transportes", datacopy: "Cópia de dados para testes",
    publicapi: "API pública",
  };
  const state = { user: null, targets: new Map(), trail: [] };

  // ------------------------------------------------------------------ shell menus (spec 029)
  function closeMenus() {
    $("#user-menu").hidden = true;
    $("#user-avatar").setAttribute("aria-expanded", "false");
  }
  function toggle(button, open) {
    const wasOpen = button.getAttribute("aria-expanded") === "true";
    closeMenus();
    if (!wasOpen) { open(); button.setAttribute("aria-expanded", "true"); }
  }
  async function refreshNotices() {
    if (!window.AnaScheduler || isExternal()) return;
    try {
      const n = await window.AnaScheduler.notifications(document.createElement("div"), true);
      // Spec 033: administrators also see the system's notices (new critical findings of the checks).
      const sys = canSee("admin") ? (await API.admin.notices(true).catch(() => [])).length : 0;
      state.systemNotices = sys;
      $("#notices-dot").hidden = !(n || sys);
      const parts = [n ? `${n} aviso(s) das rotinas agendadas` : "", sys ? `${sys} aviso(s) das verificações do sistema` : ""].filter(Boolean);
      $("#notices-btn").title = parts.length ? parts.join(" · ") : "Nenhum aviso";
      const badge = $("#checks-count");
      if (badge) { badge.hidden = !sys; badge.textContent = String(sys); }
    } catch (_) { /* notices are a convenience */ }
  }

  const canSee = (minRole) => (ROLE_LEVEL[state.user.role] || 0) >= (ROLE_LEVEL[minRole] || 1);
  const isExternal = () => state.user && state.user.role === "external";

  // ------------------------------------------------------------------ screens
  function showScreen(id) {
    for (const s of ["#login-screen", "#password-screen", "#app-screen"]) $(s).hidden = s !== id;
  }

  function showLogin() {
    showScreen("#login-screen");
    $("#login-form").elements.namedItem("username").focus();
  }

  function showPassword(forced) {
    $("#password-title").textContent = forced ? "Troque sua senha" : "Trocar senha";
    $("#password-hint").hidden = !forced;
    $("#password-cancel").hidden = forced;
    $("#password-error").textContent = "";
    $("#password-form").reset();
    showScreen("#password-screen");
    $("#password-form").elements.namedItem("current").focus();
  }

  async function start() {
    try { state.user = await API.me(); } catch (_) { showLogin(); return; }
    if (state.user.must_change_password) { showPassword(true); return; }
    document.body.classList.toggle("is-admin", state.user.role === "admin");
    // Spec 016: an external portal account sees only Files and Portal.
    for (const b of $$(".area")) {
      b.hidden = isExternal() ? !["files", "portal"].includes(b.dataset.area)
                              : b.dataset.only === "external" || !canSee(b.dataset.minRole || "user");
    }
    $("#command-form").hidden = isExternal();
    const display = state.user.name || state.user.username;
    const initials = display.split(/\s+/).filter(Boolean).slice(0, 2).map((w) => w[0].toUpperCase()).join("") || "?";
    $("#user-name").textContent = display;
    $("#user-role").textContent = { admin: "administrador", developer: "desenvolvedor", user: "usuário", external: "portal" }[state.user.role] || state.user.role;
    $("#avatar-initials").textContent = initials;
    $("#avatar-initials-big").textContent = initials;
    $("#user-avatar").title = `${display} — minha conta`;
    $("#notices-btn").hidden = isExternal();
    refreshNotices();
    refreshTitle(state.user.company);
    // Spec 034 (RF-034-01): development and test instances are marked on every screen.
    const inst = state.user.instance || {};
    const band = $("#instance-band");
    band.hidden = !inst.role || inst.role === "production";
    band.textContent = { development: "DESENVOLVIMENTO", test: "TESTES" }[inst.role] || "";
    band.className = "instance-band " + (inst.role || "");
    band.title = inst.name ? `Instância ${inst.name} — não é a produção` : "";
    document.body.dataset.instance = inst.role || "production";
    showScreen("#app-screen");
    if (!isExternal()) await buildTargets();
    route();
  }

  function refreshTitle(company) {
    $("#brand-company").textContent = company || "ERP";
    document.title = company ? `ANA — ${company}` : "ANA";
  }

  // ------------------------------------------------------------------ routing (RF-020-07)
  function go(hash) {
    if (location.hash === hash) route(); else location.hash = hash;
  }

  // ------------------------------------------------------------------ back (F3, as in classic ERP screens)
  // The trail follows the screens visited in this tab; Back returns to the previous one
  // (a routine comes back with its parameters filled in). With nothing behind, it goes up
  // one level: routine → module → Operation → Home.
  function noteNav(hash) {
    const t = state.trail;
    if (t.length >= 2 && t[t.length - 2] === hash) t.pop();
    else if (t[t.length - 1] !== hash) t.push(hash);
    if (t.length > 50) t.splice(0, t.length - 50);
    const parent = parentOf(hash);
    $("#back").hidden = t.length < 2 && !parent;
  }

  function parentOf(hash) {
    const [path] = hash.replace(/^#\/?/, "").split("?");
    const parts = path.split("/").filter(Boolean);
    if (!parts.length || parts[0] === "home") return null;
    if (parts[0] === "ops") return parts.length > 2 ? `#/ops/${parts[1]}` : parts.length === 2 ? "#/ops" : "#/home";
    if (parts[0] === "dev") return parts.length > 1 ? "#/dev" : "#/home";
    if (parts[0] === "files") return parts.length > 1 ? "#/files" : isExternal() ? null : "#/home";
    if (parts[0] === "portal") return null;
    return "#/home";
  }

  function back() {
    if (state.trail.length >= 2) history.back();
    else { const p = parentOf(location.hash); if (p) go(p); }
  }

  function replace(hash) {
    history.replaceState(null, "", hash);
  }

  async function route() {
    if ($("#app-screen").hidden) return;
    noteNav(location.hash || "#/home");
    // RF-020-12: "#/ops/m/routine?project=PRJ-001" carries routine parameters.
    const [path, search] = location.hash.replace(/^#\/?/, "").split("?");
    const query = Object.fromEntries(new URLSearchParams(search || ""));
    const parts = path.split("/").filter(Boolean).map(decodeURIComponent);
    let [area, ...rest] = parts;
    const allowed = { home: "user", ops: "user", files: "user", dev: "developer", admin: "admin" };
    const ok = isExternal() ? ["files", "portal"].includes(area) : (allowed[area] && canSee(allowed[area]));
    if (!ok) {
      area = isExternal() ? "portal" : "home";
      rest = [];
      replace("#/" + area);
    }
    for (const b of $$(".area")) b.classList.toggle("active", b.dataset.area === area);
    closeMenus();
    for (const a of ["home", "ops", "files", "portal", "dev", "admin"]) $("#area-" + a).hidden = a !== area;
    try {
      if (area === "files") await window.AnaFiles.show(rest);
      else if (area === "portal") await window.AnaFiles.portal(rest);
      else if (area === "home") await window.AnaOps.home();
      else if (area === "ops") await window.AnaOps.ops(rest[0], rest[1], query);
      else if (area === "dev") await window.AnaDev.show(rest);
      else if (area === "admin") window.AnaAdmin.show(rest[0] || "users");
    } catch (e) { toast(window.AnaUI.errorText(e), true); }
  }

  // ------------------------------------------------------------------ go-to bar
  async function buildTargets() {
    state.targets.clear();
    const add = (label, hash) => state.targets.set(label, hash);
    const routines = await window.AnaOps.loadRoutines().catch(() => []);
    for (const r of routines) {
      const hash = `#/ops/${R.moduleOf(r.name)}/${r.name}`;
      if (r.command) add(r.command, hash);
      add(`${r.description || r.name} — ${R.moduleLabel(R.moduleOf(r.name))}`, hash);
    }
    if (canSee("developer")) {
      const programs = await API.programs(false).catch(() => []);
      for (const p of programs) add(p.name, `#/dev/program/${p.name}`);
      const tables = await API.catalog().catch(() => []);
      for (const t of tables) add(`${t.schema}.${t.name}`, `#/dev/data/${t.schema}/${t.name}`);
    }
    if (canSee("admin")) for (const [k, label] of Object.entries(ADMIN_SECTIONS)) add(`Administração: ${label}`, `#/admin/${k}`);
    $("#command-list").replaceChildren(...[...state.targets.keys()].map((label) => el("option", { value: label })));
  }

  function goTo(text) {
    const t = text.trim();
    if (!t) return;
    const exact = state.targets.get(t) || state.targets.get(t.toLowerCase());
    if (exact) return go(exact);
    const lower = t.toLowerCase();
    const match = [...state.targets.entries()].find(([label]) => label.toLowerCase().includes(lower));
    if (match) return go(match[1]);
    toast(`Nada encontrado para "${t}".`, true);
  }

  // ------------------------------------------------------------------ events
  function wire() {
    API.onExpired = showLogin;
    API.onPasswordRequired = () => showPassword(true);
    window.AnaAdmin.wire();

    $("#login-form").addEventListener("submit", async (e) => {
      e.preventDefault();
      const f = e.currentTarget;
      $("#login-error").textContent = "";
      try {
        await API.login(f.elements.namedItem("username").value.trim(), f.elements.namedItem("password").value);
        f.elements.namedItem("password").value = "";
        start();
      } catch (err) { $("#login-error").textContent = err.message; }
    });
    $("#password-form").addEventListener("submit", async (e) => {
      e.preventDefault();
      const f = e.currentTarget;
      const next = f.elements.namedItem("new").value;
      if (next !== f.elements.namedItem("confirm").value) { $("#password-error").textContent = "As senhas não conferem."; return; }
      try {
        await API.changePassword(f.elements.namedItem("current").value, next);
        f.reset();
        toast("Senha alterada.");
        start();
      } catch (err) { $("#password-error").textContent = err.message; }
    });
    $("#password-cancel").addEventListener("click", () => showScreen("#app-screen"));
    $("#change-password").addEventListener("click", () => showPassword(false));
    $("#back").addEventListener("click", back);
    document.addEventListener("keydown", (e) => {
      if (e.key === "F3" && !$("#app-screen").hidden) { e.preventDefault(); back(); }
    });
    // Resizable side panels (drag the divider; double click restores).
    for (const [area, key] of [["#area-ops", "ops-nav"], ["#area-admin", "admin-nav"], ["#area-dev", "dev-tree"]]) {
      const host = $(area);
      host.insertBefore(window.AnaUI.splitter(host, "--side-w", { min: 160, max: 600, key }), host.children[1]);
    }
    $("#logout").addEventListener("click", async () => { await API.logout(); location.hash = ""; location.reload(); });
    for (const b of $$(".area")) b.addEventListener("click", () => go("#/" + b.dataset.area));
    $("#user-avatar").addEventListener("click", (e) => { e.stopPropagation(); toggle($("#user-avatar"), () => { $("#user-menu").hidden = false; }); });
    $("#notices-btn").addEventListener("click", () => go(state.systemNotices ? "#/admin/checks" : "#/home"));
    document.addEventListener("click", (e) => { if (!e.target.closest("#user-menu")) closeMenus(); });
    document.addEventListener("keydown", (e) => { if (e.key === "Escape") closeMenus(); });
    $("#command-form").addEventListener("submit", (e) => {
      e.preventDefault();
      goTo($("#command").value);
      $("#command").value = "";
    });
    window.addEventListener("hashchange", route);
  }

  window.AnaStudio = { go, replace, back, noteNav, refreshTitle, user: () => state.user, refreshTargets: buildTargets };

  document.addEventListener("DOMContentLoaded", () => {
    wire();
    if (API.authenticated) start(); else showLogin();
  });
})();
