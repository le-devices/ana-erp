// SPDX-FileCopyrightText: 2026 André Luis Pereira dos Santos
// SPDX-License-Identifier: AGPL-3.0-or-later
// Premium-experience verifier (spec 050, T-050-02; constitution P18).
// Runs on every screen the Studio test visits. Violations already known are listed in
// ux_baseline.json (they are fixed area by area in phase 3, T-050-09..16); anything NEW fails the battery.
// UX_BASELINE=write node smoke.mjs   rewrites the baseline with what exists today.
import fs from "fs";

const BASELINE = new URL("./ux_baseline.json", import.meta.url);
// Text an operation user must never see (P18: no technical code on screen).
const TECHNICAL = /\bundefined\b|\[object Object\]|\bNaN\b|Traceback|SQLSTATE|sqlstate|badmatch|function_clause|\{"error"/;
// Areas where technical text is legitimate (developers and administrators look at code, SQL and traces).
const TECH_OK = "#area-dev, #area-admin";

const visible = (el) => !el.closest("[hidden]") && !(el.style && el.style.display === "none") && !el.closest("template");
const nameOf = (el) => {
  const d = el.ownerDocument;
  if ((el.getAttribute("aria-label") || "").trim() || (el.getAttribute("title") || "").trim()) return true;
  const by = el.getAttribute("aria-labelledby");
  if (by && by.split(/\s+/).some((id) => (d.getElementById(id) || {}).textContent)) return true;
  if (el.labels && el.labels.length) return true;
  return false;
};
const hint = (el) => {
  const id = el.id ? `#${el.id}` : "";
  const cls = typeof el.className === "string" && el.className.trim() ? "." + el.className.trim().split(/\s+/)[0] : "";
  const label = (el.getAttribute("name") || el.getAttribute("placeholder") || el.textContent || "").trim().slice(0, 30);
  return `${el.tagName.toLowerCase()}${id}${cls}${label ? `[${label}]` : ""}`;
};

/** Violations of the visible screen: [{rule, element}]. */
export function audit(d) {
  const out = [];
  const add = (rule, el) => out.push({ rule, element: hint(el) });
  const scope = [...d.querySelectorAll(".area:not([hidden]), #app-screen:not([hidden]) .page-main")].filter(visible);
  const roots = scope.length ? scope : [d.body];
  for (const root of roots) {
    for (const f of root.querySelectorAll("input:not([type=hidden]), select, textarea")) {
      if (visible(f) && !nameOf(f)) add("field-name", f);
    }
    for (const b of root.querySelectorAll("button, [role=button], a[href]")) {
      if (visible(b) && !b.textContent.trim() && !nameOf(b)) add("control-name", b);
    }
    for (const i of root.querySelectorAll("img")) if (visible(i) && !i.hasAttribute("alt")) add("image-alt", i);
    for (const e of root.querySelectorAll(".empty-state")) {
      if (visible(e) && !e.querySelector("button, a[href]")) add("empty-without-action", e);
    }
    if (!root.matches(TECH_OK) && TECHNICAL.test(visibleText(root))) add("technical-text", root);
  }
  const ids = {};
  for (const e of d.querySelectorAll("[id]")) ids[e.id] = (ids[e.id] || 0) + 1;
  for (const [id, n] of Object.entries(ids)) if (n > 1) out.push({ rule: "duplicate-id", element: `#${id} (${n}×)` });
  return out;
}

function visibleText(root) {
  let t = "";
  const walk = (n) => {
    if (n.nodeType === 3) { t += n.nodeValue + " "; return; }
    if (n.nodeType !== 1 || !visible(n) || n.matches("script, style, code, pre, textarea, .code, .params-json")) return;
    for (const c of n.childNodes) walk(c);
  };
  walk(root);
  return t;
}

/** Collects violations per screen and judges them against the baseline at the end. */
export class Verifier {
  constructor({ baseline = true } = {}) {
    this.seen = new Map();          // key "screen|rule|element" → true
    this.screens = new Set();
    let base = [];
    if (baseline) try { base = JSON.parse(fs.readFileSync(BASELINE, "utf8")); } catch (_) { /* no baseline yet */ }
    this.baseline = new Set(base);
  }
  check(d, screen) {
    this.screens.add(screen);
    for (const v of audit(d)) this.seen.set(`${screen}|${v.rule}|${v.element}`, true);
  }
  /** {fresh: [...], fixed: [...]}. UX_BASELINE=write adds what exists now to the baseline and never drops
   *  an entry: a run does not reach every state of every screen, so an entry missing from one run is not
   *  proof of a fix (an entry left after a real fix is harmless; remove it by hand when the area is audited). */
  finish() {
    const now = [...this.seen.keys()].sort();
    if (process.env.UX_BASELINE === "write") {
      const all = [...new Set([...this.baseline, ...now])].sort();
      fs.writeFileSync(BASELINE, JSON.stringify(all, null, 1) + "\n");
      return { fresh: [], fixed: [], written: all.length };
    }
    const fresh = now.filter((k) => !this.baseline.has(k));
    const fixed = [...this.baseline].filter((k) => this.screens.has(k.split("|")[0]) && !this.seen.has(k));
    return { fresh, fixed };
  }
}
