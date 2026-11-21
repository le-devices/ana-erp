// SPDX-FileCopyrightText: 2026 André Luis Pereira dos Santos
// SPDX-License-Identifier: AGPL-3.0-or-later
// BPM diagrams (spec 039): renderer and editor in plain SVG — no external library (spec 020, strict CSP).
// The same renderer shows a model to edit, a published version, a case's path, the heat map of the
// process panel, the difference between versions and the animation of a simulation.
"use strict";
(function () {
  const SVGNS = "http://www.w3.org/2000/svg";
  const LANE_Y0 = 20, LANE_H = 130, LANE_HEAD = 34, GRID = 10;
  const SIZE = { start: [36, 36], end: [36, 36], timer: [36, 36], event_fact: [36, 36], gw_xor: [50, 50], gw_and: [50, 50],
                 gw_or: [50, 50], annotation: [140, 44] };
  const TASK = [124, 60];
  const ICON = { task_human: "👤", task_approval: "✔", task_auto: "⚙", task_send: "✉", task_rule: "▦", subprocess: "⊞" };
  const GW = { gw_xor: "×", gw_and: "+", gw_or: "○" };
  const SHORT = { end: "Fim", timer: "Espera", event_fact: "Fato do ERP", task_human: "Pessoa", task_approval: "Aprovação",
                  task_auto: "Automática", task_send: "Envio", task_rule: "Regra", subprocess: "Subprocesso", gw_xor: "Decisão",
                  gw_and: "Paralelo", gw_or: "Inclusivo", annotation: "Nota" };

  const s = (tag, attrs = {}, ...children) => {
    const e = document.createElementNS(SVGNS, tag);
    for (const [k, v] of Object.entries(attrs)) if (v !== null && v !== undefined && v !== false) e.setAttribute(k, v);
    for (const c of children.flat()) if (c !== null && c !== undefined && c !== false) e.append(typeof c === "string" ? document.createTextNode(c) : c);
    return e;
  };
  const size = (n) => SIZE[n.type] || TASK;
  const center = (n) => { const [w, h] = size(n); return [n.x + w / 2, n.y + h / 2]; };
  const clone = (x) => JSON.parse(JSON.stringify(x));
  const snap = (v) => Math.round(v / GRID) * GRID;
  const laneIndex = (model, id) => (model.lanes || []).findIndex((l) => l.id === id);

  function wrap(text, max) {
    const words = String(text || "").split(/\s+/);
    const lines = [""];
    for (const w of words) {
      const cur = lines[lines.length - 1];
      if ((cur + " " + w).trim().length > max && cur) lines.push(w); else lines[lines.length - 1] = (cur + " " + w).trim();
    }
    if (lines.length > 3) { lines.length = 3; lines[2] = lines[2].slice(0, max - 1) + "…"; }
    return lines;
  }

  /** Ports and an orthogonal route between two nodes. */
  function route(a, b) {
    const [aw, ah] = size(a), [bw, bh] = size(b);
    const ax = a.x + aw, ay = a.y + ah / 2, bx = b.x, by = b.y + bh / 2;
    if (bx >= ax + 20) {
      const mx = snap((ax + bx) / 2);
      return [[ax, ay], [mx, ay], [mx, by], [bx, by]];
    }
    // Going back (a loop): leave from the bottom, run below both and enter from the left.
    const low = Math.max(a.y + ah, b.y + bh) + 26;
    return [[a.x + aw / 2, a.y + ah], [a.x + aw / 2, low], [bx - 18, low], [bx - 18, by], [bx, by]];
  }
  const pathOf = (pts) => "M" + pts.map((p) => p.join(",")).join(" L");
  const mid = (pts) => { const i = Math.floor((pts.length - 1) / 2); return [(pts[i][0] + pts[i + 1][0]) / 2, (pts[i][1] + pts[i + 1][1]) / 2]; };

  function bounds(model) {
    let x1 = 0, y1 = 0, x2 = 600, y2 = 260;
    for (const n of model.nodes || []) {
      const [w, h] = size(n);
      x1 = Math.min(x1, n.x - 40); y1 = Math.min(y1, n.y - 40); x2 = Math.max(x2, n.x + w + 60); y2 = Math.max(y2, n.y + h + 60);
    }
    if ((model.lanes || []).length) y2 = Math.max(y2, LANE_Y0 + model.lanes.length * LANE_H + 10);
    return { x: x1, y: Math.min(y1, 0), w: x2 - x1, h: y2 - Math.min(y1, 0) };
  }

  /**
   * Draws the model into an <svg>. opts: { selected: {kind, id}, issues: [..], heat: {node: {avg_h, count, late}},
   * path: {done: [], current: [], failed: []}, diff: {nodes: {added, changed}, edges: {...}}, names }.
   */
  function draw(svg, model, opts = {}) {
    const issues = {};
    for (const i of opts.issues || []) if (i.node) (issues[i.node] = issues[i.node] || []).push(i);
    const edgeIssues = {};
    for (const i of opts.issues || []) if (i.edge) (edgeIssues[i.edge] = edgeIssues[i.edge] || []).push(i);
    const byId = Object.fromEntries((model.nodes || []).map((n) => [n.id, n]));
    const b = bounds(model);
    const width = Math.max(b.w, 600) + (b.x < 0 ? -b.x : 0);
    const root = s("g", { class: "bpm-root" });
    const defs = s("defs", {},
      s("marker", { id: "bpm-arrow", viewBox: "0 0 10 10", refX: "9", refY: "5", markerWidth: "8", markerHeight: "8", orient: "auto-start-reverse" },
        s("path", { d: "M0,0 L10,5 L0,10 z", class: "bpm-arrowhead" })));
    // Lanes
    (model.lanes || []).forEach((l, i) => {
      const y = LANE_Y0 + i * LANE_H;
      const sel = opts.selected && opts.selected.kind === "lane" && opts.selected.id === l.id;
      const head = s("g", { class: "bpm-lane-head" + (sel ? " selected" : ""), "data-lane": l.id, tabindex: opts.editable ? "0" : null,
                            role: "button", "aria-label": `Raia ${l.name}` },
        s("rect", { x: b.x, y, width: LANE_HEAD, height: LANE_H, class: "bpm-lane-label" }),
        s("text", { x: b.x + LANE_HEAD / 2, y: y + LANE_H / 2, class: "bpm-lane-text",
                    transform: `rotate(-90 ${b.x + LANE_HEAD / 2} ${y + LANE_H / 2})` }, l.name + (l.role || l.group ? ` · ${l.group || ROLE[l.role] || l.role}` : "")));
      root.append(s("rect", { x: b.x, y, width: width, height: LANE_H, class: "bpm-lane" + (i % 2 ? " odd" : "") }), head);
    });
    // Heat map scale (one hue, light → dark: magnitude)
    const heatMax = opts.heat ? Math.max(0.0001, ...Object.values(opts.heat).map((h) => h.avg_h || 0)) : 0;
    // Edges
    for (const e of model.edges || []) {
      const a = byId[e.from], t = byId[e.to];
      if (!a || !t) continue;
      const pts = route(a, t);
      const sel = opts.selected && opts.selected.kind === "edge" && opts.selected.id === e.id;
      const cls = ["bpm-edge", e.on === "error" ? "error" : e.on === "timeout" ? "timeout" : "", sel ? "selected" : "",
                   edgeIssues[e.id] ? "invalid" : "", diffCls(opts.diff, "edges", e.id),
                   opts.path && opts.path.done.includes(e.from) && (opts.path.done.includes(e.to) || opts.path.current.includes(e.to)) ? "walked" : ""].join(" ");
      const g = s("g", { class: cls, "data-edge": e.id, tabindex: opts.editable ? "0" : null, role: opts.editable ? "button" : null,
                         "aria-label": `Ligação de ${a.name} para ${t.name}${e.name ? ": " + e.name : ""}` },
        s("path", { d: pathOf(pts), class: "bpm-edge-hit" }),
        s("path", { d: pathOf(pts), class: "bpm-edge-line", "marker-end": "url(#bpm-arrow)" }));
      if (e.default) { const [x, y] = pts[0]; g.append(s("path", { d: `M${x + 6},${y - 6} L${x + 14},${y + 6}`, class: "bpm-default-mark" })); }
      const label = e.name || (e.on === "error" ? "erro" : e.on === "timeout" ? "atraso" : hasCondition(e.condition) ? condText(e.condition) : "");
      if (label) { const [x, y] = mid(pts); g.append(s("text", { x: x + 4, y: y - 6, class: "bpm-edge-label" }, label.length > 30 ? label.slice(0, 29) + "…" : label)); }
      root.append(g);
    }
    // Nodes
    for (const n of model.nodes || []) {
      const [w, h] = size(n);
      const sel = opts.selected && opts.selected.kind === "node" && opts.selected.id === n.id;
      const st = opts.path ? (opts.path.failed.includes(n.id) ? "failed" : opts.path.current.includes(n.id) ? "current" : opts.path.done.includes(n.id) ? "done" : "") : "";
      const heat = opts.heat && opts.heat[n.id];
      const g = s("g", { class: ["bpm-node", n.type, sel ? "selected" : "", st, diffCls(opts.diff, "nodes", n.id), issues[n.id] ? "invalid" : ""].join(" "),
                         "data-node": n.id, transform: `translate(${n.x},${n.y})`, tabindex: "0", role: "button",
                         "aria-label": `${TYPE_LABEL[n.type] || n.type}: ${n.name || n.id}${issues[n.id] ? " — com problema" : ""}` });
      const level = heat && heat.avg_h ? Math.min(1, heat.avg_h / heatMax) : 0;
      const heatStyle = heat ? `--heat:${(0.12 + level * 0.78).toFixed(2)}` : null;
      if (n.type === "start" || n.type === "end" || n.type === "timer" || n.type === "event_fact") {
        g.append(s("circle", { cx: w / 2, cy: h / 2, r: w / 2, class: "bpm-shape", style: heatStyle }));
        if (n.type === "timer" || n.type === "event_fact") g.append(s("circle", { cx: w / 2, cy: h / 2, r: w / 2 - 4, class: "bpm-inner" }));
        if (n.type === "timer") g.append(s("path", { d: `M${w / 2},${h / 2} L${w / 2},${h / 2 - 9} M${w / 2},${h / 2} L${w / 2 + 7},${h / 2}`, class: "bpm-glyph-line" }));
        if (n.type === "event_fact") g.append(s("text", { x: w / 2, y: h / 2 + 5, class: "bpm-glyph" }, "≡"));
        g.append(...wrap(n.name, 18).map((t, i) => s("text", { x: w / 2, y: h + 14 + i * 13, class: "bpm-label-out" }, t)));
      } else if (GW[n.type]) {
        g.append(s("path", { d: `M${w / 2},0 L${w},${h / 2} L${w / 2},${h} L0,${h / 2} z`, class: "bpm-shape", style: heatStyle }),
          s("text", { x: w / 2, y: h / 2 + 7, class: "bpm-glyph gw" }, GW[n.type]));
        g.append(...wrap(n.name, 20).map((t, i) => s("text", { x: w / 2, y: -8 - (wrap(n.name, 20).length - 1 - i) * 13, class: "bpm-label-out" }, t)));
      } else if (n.type === "annotation") {
        g.append(s("path", { d: `M14,0 L0,0 L0,${h} L14,${h}`, class: "bpm-annotation" }),
          ...wrap(n.name, 22).map((t, i) => s("text", { x: 8, y: 16 + i * 13, class: "bpm-annotation-text" }, t)));
      } else {
        g.append(s("rect", { width: w, height: h, rx: 9, class: "bpm-shape", style: heatStyle }),
          s("text", { x: 9, y: 16, class: "bpm-icon" }, ICON[n.type] || ""),
          ...wrap(n.name, 17).map((t, i, arr) => s("text", { x: w / 2, y: h / 2 + 5 + (i - (arr.length - 1) / 2) * 14, class: "bpm-label" }, t)));
        if (n.type === "subprocess") g.append(s("rect", { x: w / 2 - 7, y: h - 14, width: 14, height: 11, class: "bpm-sub-mark" }),
                                               s("text", { x: w / 2, y: h - 5, class: "bpm-sub-plus" }, "+"));
      }
      if (heat) g.append(s("text", { x: w + 4, y: -2, class: "bpm-heat-badge" }, `${heat.count || 0}× · ${fmtH(heat.avg_h)}${heat.late ? ` · ${heat.late} atras.` : ""}`));
      if (issues[n.id]) {
        const t = s("title", {}, issues[n.id].map((i) => i.message).join("\n"));
        g.append(s("g", { class: "bpm-issue" }, s("circle", { cx: w - 2, cy: 2, r: 8 }), s("text", { x: w - 2, y: 6 }, "!"), t));
      }
      if (opts.editable && n.type !== "end" && n.type !== "annotation") {
        g.append(s("circle", { cx: w + 9, cy: h / 2, r: 6, class: "bpm-handle", "data-handle": n.id }, s("title", {}, "Arraste para ligar")));
      }
      root.append(g);
    }
    if (opts.extra) root.append(opts.extra);
    svg.replaceChildren(defs, root);
    return b;
  }
  const ROLE = { user: "usuários", developer: "desenvolvedores", admin: "administradores" };
  const TYPE_LABEL = { start: "Início", end: "Fim", timer: "Espera por tempo", event_fact: "Espera por fato do ERP", task_human: "Tarefa de pessoa",
                       task_approval: "Aprovação", task_auto: "Tarefa automática", task_send: "Envio", task_rule: "Regra de decisão",
                       subprocess: "Subprocesso", gw_xor: "Decisão", gw_and: "Paralelo", gw_or: "Inclusivo", annotation: "Anotação" };
  const condText = (c) => window.AnaConditions.describe(c);
  const hasCondition = (c) => (Array.isArray(c) ? c.length > 0 : !!c && ((c.any || []).some((x) => x.length) || (c.except || []).length > 0));
  const fmtH = (h) => (h === null || h === undefined ? "—" : h >= 24 ? `${(h / 24).toLocaleString("pt-BR", { maximumFractionDigits: 1 })} d`
                       : `${Number(h).toLocaleString("pt-BR", { maximumFractionDigits: 1 })} h`);
  function diffCls(diff, kind, id) {
    if (!diff || !diff[kind]) return "";
    if (diff[kind].added.includes(id)) return "diff-added";
    if (diff[kind].changed.includes(id)) return "diff-changed";
    return "";
  }

  // ------------------------------------------------------------------ viewer (pan + zoom, read only)
  /** A diagram box with zoom and pan. Returns { svg, redraw(opts), fit(), setModel(m) }. */
  function viewer(container, model, opts = {}) {
    const svg = s("svg", { class: "bpm-svg", role: "img", "aria-label": opts.label || "Diagrama do processo" });
    const box = document.createElement("div");
    box.className = "bpm-canvas" + (opts.compact ? " compact" : "");
    box.append(svg);
    container.append(box);
    let view = null, current = opts, m = model;
    const apply = () => svg.setAttribute("viewBox", `${view.x} ${view.y} ${view.w} ${view.h}`);
    const fit = () => { const b = bounds(m); view = { x: b.x - 10, y: b.y - 10, w: b.w + 20, h: b.h + 20 }; apply(); };
    const redraw = (o) => { current = o || current; draw(svg, m, current); if (!view) fit(); };
    svg.addEventListener("wheel", (ev) => {
      ev.preventDefault();
      const r = svg.getBoundingClientRect();
      const fx = (ev.clientX - r.left) / r.width, fy = (ev.clientY - r.top) / r.height;
      const k = ev.deltaY > 0 ? 1.12 : 1 / 1.12;
      const nw = Math.min(8000, Math.max(200, view.w * k)), nh = view.h * (nw / view.w);
      view = { x: view.x + (view.w - nw) * fx, y: view.y + (view.h - nh) * fy, w: nw, h: nh };
      apply();
    }, { passive: false });
    let pan = null;
    svg.addEventListener("pointerdown", (ev) => {
      if (opts.onPointerDown && opts.onPointerDown(ev, toModel)) return;
      pan = { x: ev.clientX, y: ev.clientY, v: { ...view } };
      svg.setPointerCapture(ev.pointerId);
    });
    svg.addEventListener("pointermove", (ev) => {
      if (opts.onPointerMove && opts.onPointerMove(ev, toModel)) return;
      if (!pan) return;
      const r = svg.getBoundingClientRect();
      view = { ...pan.v, x: pan.v.x - (ev.clientX - pan.x) * (view.w / r.width), y: pan.v.y - (ev.clientY - pan.y) * (view.h / r.height) };
      apply();
    });
    svg.addEventListener("pointerup", (ev) => { if (opts.onPointerUp) opts.onPointerUp(ev, toModel); pan = null; });
    function toModel(ev) {
      const r = svg.getBoundingClientRect();
      return [view.x + (ev.clientX - r.left) * (view.w / r.width), view.y + (ev.clientY - r.top) * (view.h / r.height)];
    }
    const zoom = (k) => { const nw = view.w * k, nh = view.h * k; view = { x: view.x + (view.w - nw) / 2, y: view.y + (view.h - nh) / 2, w: nw, h: nh }; apply(); };
    redraw(opts);
    return { svg, box, redraw, fit, zoom, setModel: (x) => { m = x; }, view: () => view, toModel };
  }

  // ------------------------------------------------------------------ export
  function svgText(svg) {
    const c = svg.cloneNode(true);
    const cs = getComputedStyle(document.body);
    const vars = ["--surface", "--text", "--text-2", "--border", "--border-strong", "--accent", "--danger", "--warn", "--ok", "--surface-2", "--band"];
    c.setAttribute("xmlns", SVGNS);
    c.setAttribute("style", vars.map((v) => `${v}:${cs.getPropertyValue(v)}`).join(";") + ";background:" + cs.getPropertyValue("--surface"));
    const style = document.createElementNS(SVGNS, "style");
    style.textContent = [...document.styleSheets].flatMap((sh) => { try { return [...sh.cssRules]; } catch (_) { return []; } })
      .map((r) => r.cssText).filter((t) => t.includes(".bpm-")).join("\n");
    c.prepend(style);
    return new XMLSerializer().serializeToString(c);
  }
  function download(name, blob) {
    const a = document.createElement("a");
    a.href = URL.createObjectURL(blob); a.download = name; document.body.append(a); a.click(); a.remove();
    setTimeout(() => URL.revokeObjectURL(a.href), 5000);
  }
  function exportSvg(svg, name) { download(name + ".svg", new Blob([svgText(svg)], { type: "image/svg+xml" })); }
  function exportPng(svg, name) {
    const vb = svg.viewBox.baseVal;
    const img = new Image();
    const url = URL.createObjectURL(new Blob([svgText(svg)], { type: "image/svg+xml" }));
    img.onload = () => {
      const k = 2, cv = document.createElement("canvas");
      cv.width = Math.ceil(vb.width * k); cv.height = Math.ceil(vb.height * k);
      const g = cv.getContext("2d");
      g.fillStyle = getComputedStyle(document.body).getPropertyValue("--surface") || "#fff";
      g.fillRect(0, 0, cv.width, cv.height);
      g.drawImage(img, 0, 0, cv.width, cv.height);
      URL.revokeObjectURL(url);
      cv.toBlob((b) => download(name + ".png", b), "image/png");
    };
    img.src = url;
  }

  // ------------------------------------------------------------------ editor
  const NEW_PROPS = { start: { trigger: "manual" }, task_human: {}, task_approval: {}, task_auto: {}, task_send: {}, task_rule: { assign: [] },
                      timer: { hours: 1 }, event_fact: {}, subprocess: {}, gw_xor: {}, gw_and: {}, gw_or: {}, end: {}, annotation: {} };

  /**
   * Editor: container gets toolbar + canvas + side panel. ctx: { model, issues, options, editable, onChange(model),
   * onSave(), onSelect(sel), readonlyReason }.
   */
  function editor(container, ctx) {
    let model = clone(ctx.model);
    let sel = null;
    const undo = [], redo = [];
    const narrow = window.matchMedia ? window.matchMedia("(max-width: 720px)").matches : false;
    const editable = ctx.editable && !narrow;
    const el = window.AnaUI.el;
    const panel = el("aside", { class: "bpm-panel", "aria-label": "Propriedades" });
    const left = el("div", { class: "bpm-left" });
    const toolbar = el("div", { class: "bpm-toolbar", role: "toolbar", "aria-label": "Ferramentas do diagrama" });
    const issuesBox = el("div", { class: "bpm-issues" });
    const wrapEl = el("div", { class: "bpm-editor" + (editable ? "" : " readonly") }, el("div", { class: "bpm-main" }, toolbar, left, issuesBox), panel);
    container.replaceChildren(wrapEl);
    let drag = null, link = null;
    const v = viewer(left, model, {
      editable, issues: ctx.issues, selected: sel, label: "Editor do diagrama",
      onPointerDown: (ev, toModel) => {
        const handle = ev.target.closest("[data-handle]");
        const nodeG = ev.target.closest("[data-node]");
        const edgeG = ev.target.closest("[data-edge]");
        const laneG = ev.target.closest("[data-lane]");
        if (handle && editable) {
          link = { from: handle.dataset.handle, line: null };
          v.svg.setPointerCapture(ev.pointerId);
          return true;
        }
        if (nodeG) {
          select({ kind: "node", id: nodeG.dataset.node });
          if (editable) {
            const n = model.nodes.find((x) => x.id === nodeG.dataset.node);
            const [mx, my] = toModel(ev);
            drag = { n, dx: mx - n.x, dy: my - n.y, moved: false, before: clone(model) };
            v.svg.setPointerCapture(ev.pointerId);
          }
          return true;
        }
        if (edgeG) { select({ kind: "edge", id: edgeG.dataset.edge }); return true; }
        if (laneG) { select({ kind: "lane", id: laneG.dataset.lane }); return true; }
        select(null);
        return false;
      },
      onPointerMove: (ev, toModel) => {
        if (link) {
          const from = model.nodes.find((x) => x.id === link.from);
          const [x1, y1] = center(from), [x2, y2] = toModel(ev);
          if (!link.line) { link.line = document.createElementNS(SVGNS, "path"); link.line.setAttribute("class", "bpm-link-preview"); v.svg.append(link.line); }
          link.line.setAttribute("d", `M${x1},${y1} L${x2},${y2}`);
          return true;
        }
        if (drag) {
          const [mx, my] = toModel(ev);
          drag.n.x = snap(mx - drag.dx); drag.n.y = snap(my - drag.dy);
          drag.moved = true;
          v.redraw({ ...opts(), selected: sel });
          return true;
        }
        return false;
      },
      onPointerUp: (ev, toModel) => {
        if (link) {
          const target = document.elementsFromPoint(ev.clientX, ev.clientY).map((x) => x.closest && x.closest("[data-node]")).find(Boolean);
          if (link.line) link.line.remove();
          if (target && target.dataset.node !== link.from) addEdge(link.from, target.dataset.node);
          link = null;
        }
        if (drag) {
          if (drag.moved) {
            undo.push(drag.before); redo.length = 0;
            assignLane(drag.n);
            changed(false);
          }
          drag = null;
        }
        return false;
      },
    });
    const opts = () => ({ editable, issues: ctx.issues, selected: sel });
    v.box.tabIndex = 0;

    // Toolbar
    const tb = (label, title, fn, cls = "") => el("button", { type: "button", class: "quiet small " + cls, text: label, title, onclick: fn });
    if (editable) {
      const palette = el("div", { class: "bpm-palette", role: "group", "aria-label": "Adicionar elemento" });
      for (const t of ctx.options.types) {
        if (t.type === "start") continue;
        palette.append(el("button", { type: "button", class: "bpm-pal " + t.type, title: `Adicionar: ${t.label} (liga ao elemento selecionado)`,
          "aria-label": `Adicionar ${t.label}`,
          text: (ICON[t.type] || GW[t.type] || { end: "◉", timer: "◷", event_fact: "≡", annotation: "❝" }[t.type] || "?") + " " + (SHORT[t.type] || t.label),
          onclick: () => addNode(t.type) }));
      }
      toolbar.append(palette);
    }
    const save = editable ? tb("Salvar (Ctrl+S)", "Salvar o rascunho", () => ctx.onSave && ctx.onSave(model), "primary-text") : null;
    toolbar.append(el("div", { class: "bpm-actions" },
      editable ? tb("↶", "Desfazer (Ctrl+Z)", doUndo) : null, editable ? tb("↷", "Refazer (Ctrl+Y)", doRedo) : null,
      editable ? tb("Alinhar", "Organizar o desenho automaticamente", autoLayout) : null,
      tb("−", "Afastar (−)", () => v.zoom(1.2)), tb("+", "Aproximar (+)", () => v.zoom(1 / 1.2)), tb("Ajustar", "Ver tudo (0)", () => v.fit()),
      tb("SVG", "Baixar a imagem em SVG", () => exportSvg(v.svg, ctx.name || "processo")),
      tb("PNG", "Baixar a imagem em PNG", () => exportPng(v.svg, ctx.name || "processo")),
      tb("PDF", "Imprimir ou salvar em PDF", () => printSvg(v.svg, ctx.name || "processo")),
      save));
    const dirtyMark = el("span", { class: "bpm-dirty", text: "" });
    toolbar.append(dirtyMark);
    if (!editable && ctx.readonlyReason) toolbar.append(el("span", { class: "muted small", text: narrow ? "No celular o diagrama é só para ver." : ctx.readonlyReason }));

    function changed(redrawOnly) {
      v.setModel(model);
      v.redraw({ ...opts(), selected: sel });
      if (!redrawOnly) { dirtyMark.textContent = "● não salvo"; if (ctx.onChange) ctx.onChange(model); }
      drawPanel();
    }
    function push() { undo.push(clone(model)); if (undo.length > 100) undo.shift(); redo.length = 0; }
    function doUndo() { if (!undo.length) return; redo.push(clone(model)); model = undo.pop(); sel = null; changed(false); }
    function doRedo() { if (!redo.length) return; undo.push(clone(model)); model = redo.pop(); sel = null; changed(false); }
    function select(x) { sel = x; v.redraw({ ...opts(), selected: sel }); drawPanel(); if (ctx.onSelect) ctx.onSelect(sel); }
    function newId(prefix) { let i = 1; while (model.nodes.some((n) => n.id === `${prefix}${i}`) || model.edges.some((e) => e.id === `${prefix}${i}`)) i++; return `${prefix}${i}`; }
    function addNode(type) {
      push();
      const vw = v.view();
      const lane = sel && sel.kind === "lane" ? sel.id : (model.lanes[0] || {}).id;
      const li = Math.max(0, laneIndex(model, lane));
      const [w, h] = size({ type });
      const n = { id: newId(type.startsWith("gw") ? "g" : type.startsWith("task") ? "t" : "n"), type, name: TYPE_LABEL[type],
                  x: snap(vw.x + vw.w / 2 - w / 2), y: model.lanes.length ? snap(LANE_Y0 + li * LANE_H + (LANE_H - h) / 2) : snap(vw.y + vw.h / 2),
                  lane, props: clone(NEW_PROPS[type] || {}) };
      if (sel && sel.kind === "node") {
        const from = model.nodes.find((x) => x.id === sel.id);
        if (from && from.type !== "end") {
          n.x = snap(from.x + size(from)[0] + 60); n.y = snap(from.y + (size(from)[1] - h) / 2); n.lane = from.lane;
          model.edges.push({ id: newId("e"), from: from.id, to: n.id });
        }
      }
      model.nodes.push(n);
      sel = { kind: "node", id: n.id };
      changed(false);
    }
    function addEdge(from, to) {
      if (model.edges.some((e) => e.from === from && e.to === to && !e.on)) return;
      push();
      model.edges.push({ id: newId("e"), from, to });
      sel = { kind: "edge", id: model.edges[model.edges.length - 1].id };
      changed(false);
    }
    function assignLane(n) {
      if (!model.lanes.length) return;
      const [, cy] = center(n);
      const i = Math.min(model.lanes.length - 1, Math.max(0, Math.floor((cy - LANE_Y0) / LANE_H)));
      n.lane = model.lanes[i].id;
    }
    function removeSel() {
      if (!sel) return;
      push();
      if (sel.kind === "node") {
        const n = model.nodes.find((x) => x.id === sel.id);
        if (n && n.type === "start") { model = undo.pop(); window.AnaUI.toast("O início não pode ser removido.", true); return; }
        model.nodes = model.nodes.filter((x) => x.id !== sel.id);
        model.edges = model.edges.filter((e) => e.from !== sel.id && e.to !== sel.id);
      } else if (sel.kind === "edge") model.edges = model.edges.filter((e) => e.id !== sel.id);
      else if (sel.kind === "lane") {
        if (model.lanes.length <= 1) { model = undo.pop(); window.AnaUI.toast("Mantenha ao menos uma raia.", true); return; }
        const i = laneIndex(model, sel.id);
        model.lanes.splice(i, 1);
        for (const n of model.nodes) { if (n.lane === sel.id) n.lane = model.lanes[Math.max(0, i - 1)].id; else if (laneIndex(model, n.lane) >= i) n.y -= LANE_H; }
      }
      sel = null;
      changed(false);
    }
    function duplicate() {
      if (!sel || sel.kind !== "node") return;
      const n = model.nodes.find((x) => x.id === sel.id);
      if (!n || n.type === "start") return;
      push();
      const c = clone(n); c.id = newId(n.type.startsWith("gw") ? "g" : "t"); c.x += 30; c.y += 30; c.name += " (cópia)";
      model.nodes.push(c); sel = { kind: "node", id: c.id }; changed(false);
    }
    function nudge(dx, dy) {
      if (!sel || sel.kind !== "node") return;
      const n = model.nodes.find((x) => x.id === sel.id);
      push(); n.x += dx; n.y += dy; assignLane(n); changed(false);
    }
    /** Layered layout: column = longest path from the start; rows = lanes (or stacked when no lanes). */
    function autoLayout() {
      push();
      const out = {};
      for (const e of model.edges) if (!e.on) (out[e.from] = out[e.from] || []).push(e.to);
      const start = model.nodes.find((n) => n.type === "start");
      const rank = {};
      if (start) {
        const q = [[start.id, 0]], seen = {};
        while (q.length) {
          const [id, r] = q.shift();
          if ((rank[id] ?? -1) >= r || (seen[id] = (seen[id] || 0) + 1) > model.nodes.length) continue;
          rank[id] = r;
          for (const t of out[id] || []) q.push([t, r + 1]);
        }
      }
      const slots = {};
      for (const n of model.nodes) {
        const r = rank[n.id] ?? 0;
        const li = Math.max(0, laneIndex(model, n.lane));
        const key = `${r}:${li}`;
        const k = slots[key] = (slots[key] || 0) + 1;
        const [w, h] = size(n);
        n.x = snap(LANE_HEAD + 40 + r * 175 + (TASK[0] - w) / 2);
        n.y = model.lanes.length ? snap(LANE_Y0 + li * LANE_H + (LANE_H - h) / 2 + (k - 1) * 18) : snap(80 + (k - 1) * 90);
      }
      changed(false);
      v.fit();
    }
    function printSvg(svg, name) {
      const w = window.open("", "_blank");
      if (!w) { window.AnaUI.toast("Permita a janela para imprimir.", true); return; }
      w.document.title = name;
      w.document.body.innerHTML = svgText(svg);
      const sv = w.document.querySelector("svg");
      sv.setAttribute("width", "100%");
      w.setTimeout(() => w.print(), 300);
    }

    // Keyboard (RNF-039-01)
    wrapEl.addEventListener("keydown", (ev) => {
      if (/^(INPUT|SELECT|TEXTAREA)$/.test(ev.target.tagName)) {
        if ((ev.ctrlKey || ev.metaKey) && ev.key.toLowerCase() === "s" && editable) { ev.preventDefault(); ctx.onSave && ctx.onSave(model); }
        return;
      }
      const k = ev.key, ctrl = ev.ctrlKey || ev.metaKey;
      if (ctrl && k.toLowerCase() === "s" && editable) { ev.preventDefault(); ctx.onSave && ctx.onSave(model); }
      else if (ctrl && k.toLowerCase() === "z" && editable) { ev.preventDefault(); doUndo(); }
      else if (ctrl && (k.toLowerCase() === "y" || (ev.shiftKey && k.toLowerCase() === "z")) && editable) { ev.preventDefault(); doRedo(); }
      else if (ctrl && k.toLowerCase() === "d" && editable) { ev.preventDefault(); duplicate(); }
      else if ((k === "Delete" || k === "Backspace") && editable) { ev.preventDefault(); removeSel(); }
      else if (k.startsWith("Arrow") && editable && sel && sel.kind === "node") {
        ev.preventDefault();
        const d = ev.shiftKey ? 50 : GRID;
        nudge(k === "ArrowLeft" ? -d : k === "ArrowRight" ? d : 0, k === "ArrowUp" ? -d : k === "ArrowDown" ? d : 0);
      } else if (k === "+" || k === "=") v.zoom(1 / 1.2);
      else if (k === "-") v.zoom(1.2);
      else if (k === "0") v.fit();
      else if (k === "Tab" && document.activeElement && document.activeElement.closest && document.activeElement.closest(".bpm-canvas")) {
        ev.preventDefault();
        const ids = model.nodes.map((n) => n.id);
        const i = sel && sel.kind === "node" ? ids.indexOf(sel.id) : -1;
        select({ kind: "node", id: ids[(i + (ev.shiftKey ? ids.length - 1 : 1)) % ids.length] });
      } else if (k === "Escape") select(null);
    });
    v.svg.addEventListener("focusin", (ev) => {
      const g = ev.target.closest && ev.target.closest("[data-node]");
      if (g && (!sel || sel.id !== g.dataset.node)) select({ kind: "node", id: g.dataset.node });
    });
    v.svg.addEventListener("keydown", (ev) => {
      if (ev.key === "Enter") { const f = panel.querySelector("input,select,textarea"); if (f) { ev.preventDefault(); f.focus(); } }
    });

    // ---------------------------------------------------------------- properties panel
    const field = (label, input, hint) => el("label", { class: "bpm-field" }, el("span", { text: label }), input, hint ? el("span", { class: "muted small", text: hint }) : null);
    const inp = (value, onInput, attrs = {}) => {
      const i = el("input", { type: "text", value: value ?? "", ...attrs, disabled: !editable });
      i.addEventListener("change", () => { push(); onInput(i.value); changed(false); });
      return i;
    };
    const sel_ = (value, options, onChange, empty = "—") => {
      const i = el("select", { disabled: !editable }, el("option", { value: "", text: empty }),
        ...options.map((o) => Array.isArray(o) ? el("option", { value: o[0], text: o[1] }) : el("option", { value: o, text: o })));
      i.value = value ?? "";
      i.addEventListener("change", () => { push(); onChange(i.value || null); changed(false); });
      return i;
    };
    const listOf = (id, values) => el("datalist", { id }, ...values.map((x) => el("option", { value: x })));
    // The condition builder shared by the whole ERP (RF-020-14): criteria, exceptions, operators by type.
    function rulesEditor(rules, onChange, hint) {
      const TYPES = { int: "number", float: "number", decimal: "number", bool: "bool", date: "date", datetime: "date" };
      const fields = (model.variables || []).filter((x) => x.name).map((x) => ({ name: x.name, label: x.label || x.name, type: TYPES[x.type] || "text" }));
      const b = window.AnaConditions.builder({ fields, value: rules, editable, free: true,
        onChange: (c) => { push(); onChange(c); changed(false); } });
      return el("div", { class: "bpm-rules" }, b.node, hint ? el("p", { class: "muted small", text: hint }) : null);
    }
    function parseValue(v, op) {
      if (op === "in") return v.split(",").map((x) => x.trim()).filter(Boolean);
      const n = Number(String(v).replace(",", "."));
      return v.trim() !== "" && !Number.isNaN(n) ? n : v.trim() === "true" ? true : v.trim() === "false" ? false : v;
    }
    function drawPanel() {
      const o = ctx.options;
      const parts = [];
      if (!sel) {
        parts.push(el("h3", { text: "Processo" }),
          field("Documento que o caso segue", sel_(model.document || "none", o.documents.map((d) => [d.entity, d.label]), (x) => { model.document = x || "none"; })),
          field("Robô que executa as tarefas automáticas", inp(model.run_as || "system", (x) => { model.run_as = x || "system"; })));
        const start = model.nodes.find((n) => n.type === "start");
        if (start) {
          const sp = start.props;
          parts.push(field("Como o caso começa", sel_(sp.trigger || "manual", [["manual", "Manualmente (ou pela API)"], ["document", "Quando o documento é criado"],
            ["schedule", "Por agendamento"], ["message", "Por mensagem de integração"]],
            (x) => { sp.trigger = x || "manual"; if (x === "document") sp.entity = model.document; })));
          // T-039-17b: when (cron) or through which connector the case starts.
          if (sp.trigger === "schedule") {
            parts.push(field("Quando (formato do agendador)", inp(sp.cron || "", (x) => { sp.cron = x.trim(); })),
              el("p", { class: "muted small", text: "Minuto hora dia mês dia-da-semana. Ex.: 0 8 * * 1 = segundas às 8h; 0 7 1 * * = dia 1 às 7h. Ao publicar, vira uma rotina do agendador." }));
          } else if (sp.trigger === "message") {
            parts.push(field("Conector por onde a mensagem chega", sel_(sp.connector || "", (o.connectors || []).map((c) => [c.name, c.name + (c.inbound_program ? "" : " (sem programa de entrada)")]),
                (x) => { sp.connector = x || undefined; })),
              field("Tipo da mensagem (vazio = qualquer)", inp(sp.event_type || "", (x) => { sp.event_type = x.trim() || undefined; })),
              model.document && model.document !== "none"
                ? field("Campo da mensagem com a chave do documento", inp(sp.document_field || "", (x) => { sp.document_field = x.trim() || undefined; })) : null,
              el("p", { class: "muted small", text: "A mensagem vira os dados do caso. O conector entrega as mensagens a bpm.message_start (defina-o como programa de entrada em Administração → Integrações)." }));
          }
        }
        parts.push(el("h4", { text: "Dados do caso" }));
        const vars = model.variables || (model.variables = []);
        parts.push(el("div", { class: "bpm-vars" }, ...vars.map((x, i) => el("div", { class: "bpm-rule" },
          el("input", { type: "text", value: x.name, placeholder: "nome", disabled: !editable, onchange: (ev) => { push(); x.name = ev.target.value.trim(); changed(false); } }),
          el("input", { type: "text", value: x.label || "", placeholder: "rótulo", disabled: !editable, onchange: (ev) => { push(); x.label = ev.target.value; changed(false); } }),
          el("select", { disabled: !editable, onchange: (ev) => { push(); x.type = ev.target.value; changed(false); } },
            ...[["text", "texto"], ["decimal", "número"], ["bool", "sim/não"], ["date", "data"]].map(([k, l]) => { const op = el("option", { value: k, text: l }); if (k === (x.type || "text")) op.selected = true; return op; })),
          editable ? el("button", { type: "button", class: "quiet small", text: "×", onclick: () => { push(); vars.splice(i, 1); changed(false); } }) : null)),
          editable ? el("button", { type: "button", class: "quiet small", text: "+ dado", onclick: () => { push(); vars.push({ name: "", label: "", type: "text" }); changed(false); } }) : null));
        if (editable) parts.push(el("h4", { text: "Raias" }), el("button", { type: "button", class: "quiet small", text: "+ raia",
          onclick: () => { push(); const i = model.lanes.length + 1; model.lanes.push({ id: newId("l"), name: `Raia ${i}`, role: "user" }); changed(false); } }));
        parts.push(el("p", { class: "muted small", text: editable
          ? "Clique num elemento para editar. Arraste o círculo à direita de um elemento até outro para ligar. Atalhos: Del remove, Ctrl+Z desfaz, Ctrl+D duplica, setas movem, + e − aproximam, 0 ajusta."
          : "Clique num elemento para ver os detalhes." }));
      } else if (sel.kind === "lane") {
        const l = model.lanes.find((x) => x.id === sel.id);
        if (!l) return;
        parts.push(el("h3", { text: "Raia" }), field("Nome", inp(l.name, (x) => { l.name = x; })),
          field("Papel responsável", sel_(l.role, o.roles, (x) => { l.role = x; })),
          field("Grupo responsável", sel_(l.group, o.groups, (x) => { l.group = x; })),
          el("p", { class: "muted small", text: "Tarefas de pessoa sem responsável próprio vão para o papel ou grupo da raia." }),
          editable ? el("button", { type: "button", class: "danger small", text: "Remover a raia", onclick: removeSel }) : null);
      } else if (sel.kind === "edge") {
        const e = model.edges.find((x) => x.id === sel.id);
        if (!e) return;
        const from = model.nodes.find((n) => n.id === e.from) || {};
        parts.push(el("h3", { text: "Ligação" }), field("Nome (aparece no desenho)", inp(e.name, (x) => { e.name = x || undefined; })));
        if (from.type && from.type.startsWith("task") || ["timer", "event_fact", "subprocess"].includes(from.type)) {
          parts.push(field("Quando", sel_(e.on || "", [["error", "Em caso de erro"], ["timeout", "Em caso de atraso (escalonamento)"]],
            (x) => { if (x) e.on = x; else delete e.on; }, "Ao concluir")));
        }
        if (!e.on) {
          const def = el("input", { type: "checkbox", disabled: !editable });
          def.checked = !!e.default;
          def.addEventListener("change", () => { push(); e.default = def.checked || undefined; changed(false); });
          parts.push(el("label", { class: "check" }, def, " Caminho padrão (quando nenhuma condição valer)"),
            el("h4", { text: "Condição" }),
            rulesEditor(e.condition || (e.condition = []), (r) => { e.condition = r; },
              "Linhas de um critério valem juntas (E); entre critérios basta um (OU). Use campos do documento (ex.: total) ou dados do caso. Decisões de aprovação: <id da tarefa>_decision = approved."));
        }
        if (editable) parts.push(el("button", { type: "button", class: "danger small", text: "Remover a ligação", onclick: removeSel }));
      } else {
        const n = model.nodes.find((x) => x.id === sel.id);
        if (!n) return;
        const p = n.props || (n.props = {});
        parts.push(el("h3", { text: TYPE_LABEL[n.type] || n.type }),
          field("Nome", inp(n.name, (x) => { n.name = x; }, { "aria-label": "Nome do elemento" })),
          field("Identificador", el("input", { type: "text", value: n.id, disabled: true })));
        if (!["start", "end"].includes(n.type) && editable) {
          parts.push(field("Tipo", sel_(n.type, o.types.filter((t) => !["start"].includes(t.type)).map((t) => [t.type, t.label]),
            (x) => { if (x) { n.type = x; n.props = { ...(NEW_PROPS[x] || {}), ...p }; } })));
        }
        if ((model.lanes || []).length) parts.push(field("Raia", sel_(n.lane, model.lanes.map((l) => [l.id, l.name]), (x) => {
          const li = laneIndex(model, x), [, h] = size(n);
          n.lane = x; if (li >= 0) n.y = snap(LANE_Y0 + li * LANE_H + (LANE_H - h) / 2);
        })));
        const num = (key, label, hint) => field(label, inp(p[key], (x) => { const v2 = Number(String(x).replace(",", ".")); if (x === "") delete p[key]; else p[key] = Number.isNaN(v2) ? x : v2; }, { inputmode: "decimal" }), hint);
        const program = (key = "program") => {
          parts.push(field("Programa", inp(p[key], (x) => { p[key] = x || undefined; }, { list: "bpm-programs", placeholder: "ex.: sales.invoice_order" })),
            listOf("bpm-programs", o.programs));
          const pa = el("textarea", { rows: 3, disabled: !editable, placeholder: '{"number": "{{number}}"}' });
          pa.value = p.params && Object.keys(p.params).length ? JSON.stringify(p.params, null, 1) : "";
          const err = el("span", { class: "md-err" });
          pa.addEventListener("change", () => {
            try { const v2 = pa.value.trim() ? JSON.parse(pa.value) : {}; push(); p.params = v2; err.textContent = ""; changed(false); }
            catch (_) { err.textContent = "JSON inválido"; }
          });
          parts.push(field("Parâmetros (use {{campo}} para dados do documento ou do caso)", pa), err);
        };
        if (["task_human", "task_approval"].includes(n.type)) {
          parts.push(field("Pessoa (usuário; vazio = papel ou grupo)", inp(p.assignee, (x) => { p.assignee = x || undefined; }, { placeholder: "ex.: maria ou {{requester}}" })),
            field("Papel", sel_(p.role, o.roles, (x) => { p.role = x || undefined; }, "o da raia")),
            field("Grupo", sel_(p.group, o.groups, (x) => { p.group = x || undefined; }, "o da raia")));
          if (n.type === "task_human") program();
          parts.push(field("Concluída quando (fato do ERP; vazio = a pessoa conclui)", sel_(p.done_fact, o.facts.map((f) => [f.code, `${f.name} (${f.entity})`]), (x) => { p.done_fact = x || undefined; })),
            num("sla_hours", "Prazo (horas úteis)"), num("warn_hours", "Avisar antes (horas)"),
            field("Escalonar para (usuário)", inp((p.escalate || {}).to, (x) => { p.escalate = { ...(p.escalate || {}), to: x || undefined }; })),
            field("Ao vencer", sel_((p.escalate || {}).mode || "notify", [["notify", "Avisar"], ["reassign", "Passar a tarefa"], ["path", "Seguir o caminho de atraso"]],
              (x) => { p.escalate = { ...(p.escalate || {}), mode: x || "notify" }; })),
            field("Prioridade (1 = mais alta)", sel_(String(p.priority || 3), ["1", "2", "3", "4", "5"], (x) => { p.priority = Number(x || 3); })));
          const ins = el("textarea", { rows: 3, disabled: !editable });
          ins.value = p.instructions || "";
          ins.addEventListener("change", () => { push(); p.instructions = ins.value; changed(false); });
          parts.push(field("Instruções para quem faz", ins));
        }
        if (["task_auto", "task_send"].includes(n.type)) { program(); parts.push(num("max_attempts", "Tentativas em falha técnica")); }
        if (n.type === "subprocess") parts.push(field("Processo chamado", sel_(p.process, o.processes.map((x) => [x.code, x.name]), (x) => { p.process = x || undefined; })));
        if (n.type === "timer") parts.push(num("hours", "Esperar (horas)"));
        if (n.type === "event_fact") parts.push(field("Fato do ERP", sel_(p.fact, o.facts.map((f) => [f.code, `${f.name} (${f.entity})`]), (x) => { p.fact = x || undefined; })));
        if (n.type === "task_rule") {
          const assign = p.assign || (p.assign = []);
          parts.push(el("h4", { text: "Atribuições" }), el("div", {}, ...assign.map((a, i) => el("div", { class: "bpm-assign" },
            el("input", { type: "text", value: a.var || "", placeholder: "dado", disabled: !editable, onchange: (ev) => { push(); a.var = ev.target.value.trim(); changed(false); } }),
            el("span", { text: "=" }),
            el("input", { type: "text", value: a.value ?? "", placeholder: "valor ou {{campo}}", disabled: !editable, onchange: (ev) => { push(); a.value = parseValue(ev.target.value, "="); changed(false); } }),
            el("span", { class: "muted small", text: "quando:" }),
            rulesEditor(a.when || (a.when = []), (r) => { a.when = r; }),
            editable ? el("button", { type: "button", class: "quiet small", text: "×", onclick: () => { push(); assign.splice(i, 1); changed(false); } }) : null))),
            editable ? el("button", { type: "button", class: "quiet small", text: "+ atribuição", onclick: () => { push(); assign.push({ var: "", value: "", when: [] }); changed(false); } }) : null);
        }
        const nIssues = (ctx.issues || []).filter((i) => i.node === n.id);
        if (nIssues.length) parts.push(el("div", { class: "notice-box" }, ...nIssues.map((i) => el("div", { text: (i.level === "error" ? "⚠ " : "• ") + i.message }))));
        if (editable && n.type !== "start") parts.push(el("div", { class: "row-buttons" },
          el("button", { type: "button", class: "quiet small", text: "Duplicar", onclick: duplicate }),
          el("button", { type: "button", class: "danger small", text: "Remover", onclick: removeSel })));
      }
      panel.replaceChildren(...parts.filter(Boolean));
    }
    function drawIssues() {
      const list = ctx.issues || [];
      const errs = list.filter((i) => i.level === "error").length;
      issuesBox.replaceChildren(
        el("div", { class: "bpm-issues-head" }, list.length
          ? el("strong", { class: errs ? "error" : "", text: `${errs} erro(s), ${list.length - errs} aviso(s)` + (errs ? " — corrija para publicar" : "") })
          : el("span", { class: "ok-text", text: "✓ Modelo sem problemas" })),
        list.length ? el("ul", {}, ...list.slice(0, 50).map((i) => el("li", {},
          el("button", { type: "button", class: "link", text: `${i.level === "error" ? "⚠" : "•"} ${i.node ? (model.nodes.find((n) => n.id === i.node) || {}).name || i.node : i.edge ? "ligação" : "processo"}: ${i.message}`,
                         onclick: () => i.node ? select({ kind: "node", id: i.node }) : i.edge ? select({ kind: "edge", id: i.edge }) : select(null) })))) : null);
    }
    drawPanel();
    drawIssues();
    return {
      model: () => model,
      setIssues: (list) => { ctx.issues = list; v.redraw({ ...opts(), selected: sel }); drawIssues(); drawPanel(); },
      saved: () => { dirtyMark.textContent = "✓ salvo"; },
      dirty: () => dirtyMark.textContent.startsWith("●"),
      viewer: v,
    };
  }

  // ------------------------------------------------------------------ simulation animation
  function animate(v, model, trace, seconds = 12) {
    if (!trace || !trace.length) return () => {};
    const byId = Object.fromEntries(model.nodes.map((n) => [n.id, n]));
    const tMax = Math.max(...trace.map((t) => t[3])) || 1;
    const layer = s("g", { class: "bpm-anim" });
    v.svg.querySelector(".bpm-root").append(layer);
    const dots = {};
    let raf = null;
    const t0 = performance.now();
    const step = (now) => {
      const t = ((now - t0) / 1000) / seconds * tMax;
      const active = trace.filter((x) => x[2] <= t && t < x[3]);
      const seen = new Set();
      for (const [c, node] of active) {
        const n = byId[node];
        if (!n) continue;
        const key = c;
        seen.add(key);
        const [cx, cy] = center(n);
        let d = dots[key];
        if (!d) { d = dots[key] = s("circle", { r: 5, class: "bpm-token" }); layer.append(d); }
        const j = (c % 7) - 3;
        d.setAttribute("cx", cx + j * 4); d.setAttribute("cy", cy + ((c * 3) % 7 - 3) * 4);
      }
      for (const k of Object.keys(dots)) if (!seen.has(Number(k))) { dots[k].remove(); delete dots[k]; }
      if (t < tMax) raf = requestAnimationFrame(step); else layer.remove();
    };
    raf = requestAnimationFrame(step);
    return () => { cancelAnimationFrame(raf); layer.remove(); };
  }

  window.AnaBpmDiagram = { draw, viewer, editor, animate, exportSvg, exportPng, bounds, fmtH, TYPE_LABEL, condText };
})();
