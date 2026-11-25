// SPDX-FileCopyrightText: 2026 André Luis Pereira dos Santos
// SPDX-License-Identifier: AGPL-3.0-or-later
// Spec 050 phase 3 (D8, RF-050-09, CA-050-05): every screen of the Studio, not only the ones the smoke test
// walks through, is checked against the premium-experience rules. Starting at the home page, the crawler follows
// every in-app link ("#/…") it finds, for an administrator and for an operation user, and on every routine that
// only reads it also runs the routine with its default values, so the result screen is checked too. A routine that
// writes is never run (its form is checked). New screens are covered without anyone listing them.
// Run: make teste-estudio (another port: ANA_URL=http://localhost:8081 make teste-estudio).
import { JSDOM, VirtualConsole } from "jsdom";
import { Verifier } from "./ux_check.mjs";
import { ANA_URL, ensureAna } from "./target.mjs";

await ensureAna();
const PASSWORD = process.env.ANA_ADMIN_PASSWORD || "admin";
const MAX_SCREENS = Number(process.env.CRAWL_MAX || 800);
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
const verifier = new Verifier({ baseline: process.env.CRAWL_BASELINE === "1" });
const failures = [];
const timings = [];

async function session(username, password) {
  const r = await fetch(ANA_URL + "/api/session", { method: "POST", headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ username, password }) });
  return (await r.json()).token;
}

async function open(username, password) {
  const jsErrors = [];
  const vc = new VirtualConsole();
  vc.on("jsdomError", (e) => jsErrors.push(String(e.message || e)));
  let inflight = 0;
  const html = await (await fetch(ANA_URL + "/")).text();
  const dom = new JSDOM(html, {
    url: ANA_URL + "/", runScripts: "dangerously", resources: "usable", pretendToBeVisual: true, virtualConsole: vc,
    beforeParse(w) {
      w.fetch = async (u, o) => { inflight++; try { return await fetch(new URL(u, ANA_URL), o); } finally { inflight--; } };
      w.document.execCommand = () => false;
      w.confirm = () => false;                       // the crawler never confirms anything
      w.EventSource = undefined;                      // live updates are not needed to look at a screen
    },
  });
  const w = dom.window;
  await new Promise((r) => w.addEventListener("load", r));
  const d = w.document;
  await waitFor(() => !d.querySelector("#login-screen").hidden);
  const f = d.querySelector("#login-form");
  f.elements.namedItem("username").value = username;
  f.elements.namedItem("password").value = password;
  f.dispatchEvent(new w.Event("submit", { cancelable: true }));
  await waitFor(() => !d.querySelector("#app-screen").hidden);
  // A screen is ready when no request has been in flight for a moment.
  const settle = async () => {
    const end = Date.now() + 15000;
    let quiet = 0;
    while (Date.now() < end && quiet < 4) { quiet = inflight === 0 ? quiet + 1 : 0; await sleep(75); }
  };
  return { w, d, jsErrors, settle };
}

async function waitFor(cond, ms = 15000) {
  const end = Date.now() + ms;
  while (Date.now() < end) { if (cond()) return; await sleep(50); }
  throw new Error("timed out");
}

const normal = (hash) => hash.split("?")[0].replace(/\/\d+(?=\/|$)/g, "/:id");
// Links whose only job is to leave the screen or the session.
const SKIP = /^#\/(logout|exit)\b/;

async function crawl(who, password, roleLabel) {
  const s = await open(who, password);
  const { w, d, settle } = s;
  await settle();
  const queue = ["#/home", "#/ops", "#/bpm", "#/master", "#/files", "#/dev", "#/admin", "#/portal"];
  // The same destinations as the "Ir para…" bar and the command palette, already filtered by role and licence.
  await waitFor(() => w.AnaStudio.targets && w.AnaStudio.targets().size > 0).catch(() => {});
  for (const h of (w.AnaStudio.targets ? w.AnaStudio.targets() : new Map()).values()) queue.push(h);
  const seen = new Set();
  const sameKind = new Map();
  const routines = new Map();
  let visited = 0;
  while (queue.length && visited < MAX_SCREENS) {
    let hash = queue.shift();
    // Routine pages are opened by name only: values in the address would run the routine.
    if (hash.startsWith("#/ops/")) hash = hash.split("?")[0];
    const key = normal(hash);
    if (seen.has(key) || SKIP.test(hash)) continue;
    seen.add(key);
    // Every program and every table opens the same screen: a few of each are enough.
    const kind = (hash.match(/^#\/dev\/(program|data)\//) || [])[1];
    if (kind) { const n = (sameKind.get(kind) || 0) + 1; sameKind.set(kind, n); if (n > 4) continue; }
    const t0 = Date.now();
    w.location.hash = hash;
    await sleep(60);
    await settle();
    timings.push([Date.now() - t0, `${roleLabel} ${key}`]);
    if (!w.location.hash.startsWith(hash.split("?")[0])) continue;      // redirected: not a screen for this user
    visited++;
    const screen = `${roleLabel} ${normal(w.location.hash || "#/home")}`;
    verifier.check(d, screen);
    for (const a of d.querySelectorAll('a[href^="#/"]')) {
      const h = a.getAttribute("href");
      if (!seen.has(normal(h))) queue.push(h);
    }
    if (!routines.size && w.AnaOps && w.AnaOps.routines) for (const r of w.AnaOps.routines() || []) routines.set(r.name, r);
    const m = hash.match(/^#\/ops\/[^/]+\/([^/?]+)$/);
    const r = m && routines.get(m[1]);
    if (r && !r.writes) {
      const btn = [...d.querySelectorAll("#ops-main button")].find((b) => /^Executar( \(F8\))?$/.test(b.textContent.trim()));
      if (btn) {
        btn.click();
        await sleep(60);
        await settle();
        verifier.check(d, `${screen} (resultado)`);
        for (const a of d.querySelectorAll('a[href^="#/"]')) if (!seen.has(normal(a.getAttribute("href")))) queue.push(a.getAttribute("href"));
      }
    }
  }
  if (s.jsErrors.length) failures.push(`${roleLabel}: erros de JavaScript: ${[...new Set(s.jsErrors)].slice(0, 10).join("; ")}`);
  console.log(`✔ ${roleLabel}: ${visited} tela(s) verificada(s)`);
  w.close();
}

await crawl("admin", PASSWORD, "admin");
const admin = await session("admin", PASSWORD);
const uname = "cr" + Date.now().toString().slice(-7);
await fetch(ANA_URL + "/api/admin/users", { method: "POST", headers: { "Content-Type": "application/json", Authorization: "Bearer " + admin },
  body: JSON.stringify({ username: uname, password: "Operator-pass-1", role: "user", must_change_password: false }) });
try {
  await crawl(uname, "Operator-pass-1", "user");
} finally {
  await fetch(`${ANA_URL}/api/admin/users/${uname}`, { method: "PUT", headers: { "Content-Type": "application/json", Authorization: "Bearer " + admin },
    body: JSON.stringify({ active: false }) });
}

timings.sort((a, b) => b[0] - a[0]);
console.log("telas mais lentas para assentar: " + timings.slice(0, 8).map(([ms, k]) => `${k} ${ms} ms`).join("; "));
const ux = verifier.finish();
if (ux.written !== undefined) console.log(`linha de base gravada: ${ux.written}`);
if (ux.fresh.length) failures.push("telas fora do padrão de experiência (spec 050):\n  " + ux.fresh.join("\n  "));
if (failures.length) { console.error("✘ " + failures.join("\n✘ ")); process.exit(1); }
console.log("✔ todas as telas alcançáveis dentro do padrão de experiência (CA-050-05)");
process.exit(0);
