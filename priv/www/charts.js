// SPDX-FileCopyrightText: 2026 André Luis Pereira dos Santos
// SPDX-License-Identifier: AGPL-3.0-or-later
// Charts (spec 026): SVG drawn in the browser, no dependencies, strict-CSP safe
// (colors come from classes .s1….s8 over CSS variables; no style attributes).
// Every chart has a legend (2+ series), selective direct labels, a hover/focus
// tooltip and a table view, so nothing depends on color alone.
"use strict";
(function () {
  const { el, dataTable } = window.AnaUI;
  const NS = "http://www.w3.org/2000/svg";
  const CHAR = 7;                       // ~px per character at 12px

  function svg(tag, attrs = {}, ...children) {
    const e = document.createElementNS(NS, tag);
    for (const [k, v] of Object.entries(attrs)) if (v !== undefined && v !== null) e.setAttribute(k, v);
    for (const c of children.flat()) if (c) e.append(c);
    return e;
  }
  const text = (x, y, s, cls, anchor = "start") => { const t = svg("text", { x, y, class: cls, "text-anchor": anchor }); t.textContent = s; return t; };

  // ------------------------------------------------------------------ numbers (pt-BR)
  const nf = (d) => new Intl.NumberFormat("pt-BR", { minimumFractionDigits: d, maximumFractionDigits: d });
  function fmt(v, format, unit) {
    if (v === null || v === undefined || isNaN(v)) return "—";
    const abs = Math.abs(v);
    let s;
    if (format === "money") s = nf(2).format(v);
    else if (format === "percent") s = nf(abs < 10 ? 1 : 0).format(v) + "%";
    else if (format === "hours") s = nf(abs < 100 ? 1 : 0).format(v) + " h";
    else s = nf(Number.isInteger(v) ? 0 : abs < 10 ? 2 : 1).format(v);
    return unit ? (format === "money" ? unit + " " + s : s + " " + unit) : s;
  }
  function compact(v, format) {
    const abs = Math.abs(v);
    const suffix = format === "percent" ? "%" : format === "hours" ? " h" : "";
    if (abs >= 1e9) return nf(abs >= 1e10 ? 0 : 1).format(v / 1e9) + " bi" + suffix;
    if (abs >= 1e6) return nf(abs >= 1e7 ? 0 : 1).format(v / 1e6) + " mi" + suffix;
    if (abs >= 1e4) return nf(0).format(v / 1e3) + " mil" + suffix;
    return nf(Number.isInteger(v) ? 0 : 1).format(v) + suffix;
  }

  // "Round" ticks: 0 / 1.000 / 2.000…
  function niceTicks(min, max, count = 5) {
    if (min === max) { max = min + 1; }
    const span = max - min;
    const raw = span / count;
    const mag = Math.pow(10, Math.floor(Math.log10(raw)));
    const step = [1, 2, 2.5, 5, 10].map((m) => m * mag).find((s) => span / s <= count) || 10 * mag;
    const lo = Math.floor(min / step) * step, hi = Math.ceil(max / step) * step;
    const ticks = [];
    for (let v = lo; v <= hi + step / 2; v += step) ticks.push(+v.toFixed(10));
    return ticks;
  }

  const MONTHS = ["jan", "fev", "mar", "abr", "mai", "jun", "jul", "ago", "set", "out", "nov", "dez"];
  function xLabels(x) {
    const iso = x.every((v) => typeof v === "string" && /^\d{4}-\d{2}-\d{2}/.test(v));
    if (!iso) return x.map(String);
    const monthly = x.every((v) => v.slice(8, 10) === "01");
    return x.map((v) => monthly ? `${MONTHS[+v.slice(5, 7) - 1]}/${v.slice(2, 4)}` : `${v.slice(8, 10)}/${v.slice(5, 7)}`);
  }

  // Bar with a 4px rounded data-end and a square baseline.
  function barPath(x, y0, w, y1, horizontal) {
    const r = Math.min(4, w / 2, Math.abs(y1 - y0));
    if (!horizontal) {
      const up = y1 < y0, top = y1;
      return up
        ? `M${x},${y0}V${top + r}Q${x},${top} ${x + r},${top}H${x + w - r}Q${x + w},${top} ${x + w},${top + r}V${y0}Z`
        : `M${x},${y0}V${top - r}Q${x},${top} ${x + r},${top}H${x + w - r}Q${x + w},${top} ${x + w},${top - r}V${y0}Z`;
    }
    // horizontal: x is the baseline position (y0 param is the row top), y1 the tip x
    const yTop = x, h = w, base = y0, tip = y1;
    const right = tip > base;
    return right
      ? `M${base},${yTop}H${tip - r}Q${tip},${yTop} ${tip},${yTop + r}V${yTop + h - r}Q${tip},${yTop + h} ${tip - r},${yTop + h}H${base}Z`
      : `M${base},${yTop}H${tip + r}Q${tip},${yTop} ${tip},${yTop + r}V${yTop + h - r}Q${tip},${yTop + h} ${tip + r},${yTop + h}H${base}Z`;
  }

  // ------------------------------------------------------------------ public
  function render(spec) {
    const root = el("div", { class: "chart" });
    const plot = el("div", { class: "chart-plot", tabindex: "0", "aria-label": spec.title || "gráfico" });
    const tip = el("div", { class: "chart-tip", hidden: true, role: "status" });
    const tableBox = el("div", { class: "chart-table", hidden: true });
    const toggle = el("button", { type: "button", class: "quiet small", text: "Ver tabela", onclick: () => {
      tableBox.hidden = !tableBox.hidden;
      toggle.textContent = tableBox.hidden ? "Ver tabela" : "Ver gráfico";
      plot.hidden = !tableBox.hidden;
    } });
    const series = spec.series || [];
    const labels = xLabels(spec.x || []);
    root.append(
      el("div", { class: "chart-head" },
        el("div", {}, spec.title ? el("strong", { text: spec.title }) : null,
          spec.subtitle ? el("span", { class: "muted", text: " " + spec.subtitle }) : null),
        el("div", { class: "chart-tools" }, toggle)),
      ...[legend(spec, series, labels)].filter(Boolean), plot, tableBox);
    plot.append(tip);
    tableBox.append(dataTable([spec.type === "donut" ? "item" : "", ...series.map((s) => s.name)],
      labels.map((l, i) => [l, ...series.map((s) => fmt(s.values[i], spec.format, spec.unit))]), spec.title || "dados"));

    let lastW = 0;
    const draw = () => {
      const w = Math.max(280, Math.floor(plot.clientWidth || root.clientWidth || 640));
      if (w === lastW && plot.querySelector("svg")) return;
      lastW = w;
      const old = plot.querySelector("svg");
      const node = (spec.type === "donut" ? donut : spec.type === "bar" ? bars : cartesian)(spec, series, labels, w, tip, plot);
      if (old) old.replaceWith(node); else plot.prepend(node);
    };
    draw();
    if (window.ResizeObserver) new ResizeObserver(() => draw()).observe(plot);
    return root;
  }

  function legend(spec, series, labels) {
    // The donut carries its own labelled list (name, value, share) beside or below it.
    const items = spec.type === "donut" ? []
      : series.length >= 2 ? series.map((s, i) => [s.name, i, spec.type === "line" ? "line" : "box"]) : [];
    if (!items.length) return null;
    const alertKey = spec.alert && series[spec.alert.series] ? el("span", { class: "chart-key" },
      svg("svg", { width: 14, height: 10, class: "key", "aria-hidden": "true" }, svg("rect", { x: 1, y: 1, width: 12, height: 8, rx: 2, class: "fill alert" })),
      el("span", { text: `${series[spec.alert.series].name} ${spec.alert.label || "negativo"}` })) : null;
    return el("div", { class: "chart-legend" }, items.map(([name, i, kind]) =>
      el("span", { class: "chart-key" }, svgKey(i, kind), el("span", { text: name }))), alertKey);
  }
  function svgKey(i, kind) {
    return svg("svg", { width: 14, height: 10, class: "key", "aria-hidden": "true" },
      kind === "line" ? svg("line", { x1: 0, y1: 5, x2: 14, y2: 5, class: `line s${i + 1}` })
                      : svg("rect", { x: 1, y: 1, width: 12, height: 8, rx: 2, class: `fill s${i + 1}` }));
  }

  function showTip(tip, plot, x, y, title, rows) {
    tip.replaceChildren(el("div", { class: "tip-title", text: title }), ...rows.map(([name, value, i]) =>
      el("div", { class: "tip-row" }, svgKey(i, "line"), el("strong", { text: value }), el("span", { class: "muted", text: " " + name }))));
    tip.hidden = false;
    const pw = plot.clientWidth || 640;
    tip.style.left = Math.min(Math.max(0, x + 12), Math.max(0, pw - 200)) + "px";      // CSSOM: allowed by CSP
    tip.style.top = Math.max(0, y - 10) + "px";
  }

  // ------------------------------------------------------------------ line / area / column / stacked
  function cartesian(spec, series, labels, W, tip, plot) {
    const kind = spec.type, n = labels.length;
    const stacked = kind === "stacked";
    let lo = 0, hi = 0;
    for (let i = 0; i < n; i++) {
      if (stacked) {
        let pos = 0, neg = 0;
        for (const s of series) { const v = s.values[i] || 0; if (v >= 0) pos += v; else neg += v; }
        hi = Math.max(hi, pos); lo = Math.min(lo, neg);
      } else for (const s of series) { const v = s.values[i]; if (v !== null && !isNaN(v)) { hi = Math.max(hi, v); lo = Math.min(lo, v); } }
    }
    const ticks = niceTicks(lo, hi);
    const yMin = ticks[0], yMax = ticks[ticks.length - 1];
    const tickLabels = ticks.map((t) => compact(t, spec.format));
    const endLabels = (kind === "line" || kind === "area") && series.length <= 4;
    const left = 12 + Math.max(...tickLabels.map((s) => s.length)) * CHAR;
    const right = endLabels ? Math.min(140, 16 + Math.max(...series.map((s) => (series.length > 1 ? s.name.length + 1 : 0) + 8)) * CHAR) : 12;
    const H = 260, top = 12, bottom = 28;
    const pw = W - left - right, ph = H - top - bottom;
    const Y = (v) => top + ph - ((v - yMin) / (yMax - yMin || 1)) * ph;
    const banded = kind === "column" || stacked;
    const band = pw / Math.max(n, 1);
    const X = (i) => banded ? left + band * (i + 0.5) : left + (n <= 1 ? pw / 2 : (pw * i) / (n - 1));
    const g = svg("svg", { viewBox: `0 0 ${W} ${H}`, width: W, height: H, class: "chart-svg", role: "img" });

    // grid and axes (hairline, solid, recessive)
    for (let k = 0; k < ticks.length; k++) {
      g.append(svg("line", { x1: left, x2: left + pw, y1: Y(ticks[k]), y2: Y(ticks[k]), class: ticks[k] === 0 ? "axis" : "grid" }),
               text(left - 6, Y(ticks[k]) + 4, tickLabels[k], "tick", "end"));
    }
    const maxLabels = Math.max(1, Math.floor(pw / (Math.max(...labels.map((l) => l.length), 3) * CHAR + 14)));
    const stepX = Math.ceil(n / maxLabels);
    labels.forEach((l, i) => { if (i % stepX === 0) g.append(text(X(i), H - 8, l, "tick", "middle")); });

    if (banded) {
      const groupW = stacked ? Math.min(24, band * 0.7) : Math.min(band * 0.8, series.length * 24 + (series.length - 1) * 2);
      const bw = stacked ? groupW : Math.min(24, (groupW - (series.length - 1) * 2) / series.length);
      for (let i = 0; i < n; i++) {
        const x0 = X(i) - (stacked ? bw / 2 : (series.length * bw + (series.length - 1) * 2) / 2);
        let pos = 0, neg = 0;
        const lastPos = stacked ? series.map((s) => s.values[i] || 0).map((v, k) => (v > 0 ? k : -1)).filter((k) => k >= 0).pop() : -1;
        series.forEach((s, k) => {
          const v = s.values[i];
          if (v === null || v === undefined || isNaN(v) || v === 0) return;
          let path;
          if (stacked) {
            const base = v >= 0 ? pos : neg, end = base + v;
            if (v >= 0) pos = end; else neg = end;
            const yb = Y(base), ye = Y(end);
            const gap = base === 0 ? 0 : (v >= 0 ? -2 : 2);   // 2px surface gap between segments
            path = k === lastPos || v < 0 ? barPath(x0, yb + gap, bw, ye) : `M${x0},${yb + gap}H${x0 + bw}V${ye}H${x0}Z`;
          } else {
            path = barPath(x0 + k * (bw + 2), Y(0), bw, Y(v));
          }
          // RF-020-16: a series whose negatives are an alert (e.g. available < 0) — status color plus a label.
          const alert = !stacked && spec.alert && spec.alert.series === k && v < 0;
          g.append(svg("path", { d: path, class: `bar fill s${k + 1}${alert ? " alert" : ""}` }));
          if (alert) g.append(text(x0 + k * (bw + 2) + bw / 2, Math.min(Y(v) + 14, top + ph - 2), "⚠ " + compact(v, spec.format), "neg-label", "middle"));
        });
        const hit = svg("rect", { x: X(i) - band / 2, y: top, width: band, height: ph, class: "hit", tabindex: "-1" });
        const show = (ev) => {
          const r = plot.getBoundingClientRect ? plot.getBoundingClientRect() : { left: 0, top: 0 };
          showTip(tip, plot, (ev.clientX || 0) - r.left, (ev.clientY || 0) - r.top, labels[i],
                  series.map((s, k) => [s.name, fmt(s.values[i], spec.format, spec.unit), k]));
        };
        hit.addEventListener("pointermove", show);
        hit.addEventListener("pointerleave", () => { tip.hidden = true; });
        g.append(hit);
      }
      return g;
    }

    // lines / areas
    const pathOf = (vals, closeTo) => {
      let d = "", open = false, firstX = null, lastX = null;
      vals.forEach((v, i) => {
        if (v === null || v === undefined || isNaN(v)) { open = false; return; }
        d += (open ? "L" : "M") + X(i).toFixed(1) + "," + Y(v).toFixed(1);
        if (firstX === null) firstX = X(i);
        lastX = X(i); open = true;
      });
      if (closeTo !== undefined && firstX !== null) d += `L${lastX.toFixed(1)},${closeTo}L${firstX.toFixed(1)},${closeTo}Z`;
      return d;
    };
    series.forEach((s, k) => {
      if (kind === "area") g.append(svg("path", { d: pathOf(s.values, Y(Math.max(0, yMin))), class: `area s${k + 1}` }));
      g.append(svg("path", { d: pathOf(s.values), class: `line s${k + 1}` }));
    });
    // end markers and direct labels (pushed apart when they collide)
    const ends = series.map((s, k) => {
      let i = s.values.length - 1;
      while (i >= 0 && (s.values[i] === null || isNaN(s.values[i]))) i--;
      return i < 0 ? null : { k, i, y: Y(s.values[i]), v: s.values[i], name: s.name };
    }).filter(Boolean);
    for (const e of ends) g.append(svg("circle", { cx: X(e.i), cy: e.y, r: 4, class: `dot s${e.k + 1}` }));
    if (endLabels) {
      const placed = [...ends].sort((a, b) => a.y - b.y);
      for (let j = 1; j < placed.length; j++) placed[j].ly = Math.max(placed[j].y, (placed[j - 1].ly ?? placed[j - 1].y) + 14);
      for (const e of placed) {
        g.append(text(X(e.i) + 8, (e.ly ?? e.y) + 4, (series.length > 1 ? e.name + " " : "") + fmt(e.v, spec.format, spec.unit), "end-label"));
      }
    }
    // crosshair + tooltip with every series at the X
    const cross = svg("line", { x1: 0, x2: 0, y1: top, y2: top + ph, class: "crosshair", visibility: "hidden" });
    const hit = svg("rect", { x: left, y: top, width: pw, height: ph, class: "hit" });
    const at = (i, px, py) => {
      cross.setAttribute("x1", X(i)); cross.setAttribute("x2", X(i)); cross.setAttribute("visibility", "visible");
      showTip(tip, plot, px, py, labels[i], series.map((s, k) => [s.name, fmt(s.values[i], spec.format, spec.unit), k]));
    };
    hit.addEventListener("pointermove", (ev) => {
      const r = plot.getBoundingClientRect ? plot.getBoundingClientRect() : { left: 0, top: 0 };
      const px = (ev.clientX || 0) - r.left;
      const i = n <= 1 ? 0 : Math.max(0, Math.min(n - 1, Math.round(((px - left) / pw) * (n - 1))));
      at(i, px, (ev.clientY || 0) - r.top);
    });
    hit.addEventListener("pointerleave", () => { cross.setAttribute("visibility", "hidden"); tip.hidden = true; });
    let focusI = n - 1;
    plot.addEventListener("keydown", (ev) => {
      if (ev.key !== "ArrowLeft" && ev.key !== "ArrowRight") return;
      ev.preventDefault();
      focusI = Math.max(0, Math.min(n - 1, focusI + (ev.key === "ArrowRight" ? 1 : -1)));
      at(focusI, X(focusI), top);
    });
    g.append(cross, hit);
    return g;
  }

  // ------------------------------------------------------------------ horizontal bars (ranking)
  function bars(spec, series, labels, W, tip, plot) {
    const s0 = series[0], n = labels.length;
    const row = 30, top = 6, H = top * 2 + n * row;
    const left = Math.min(240, 16 + Math.max(...labels.map((l) => l.length), 4) * CHAR);
    const valueW = 16 + Math.max(...s0.values.map((v) => fmt(v, spec.format, spec.unit).length)) * CHAR;
    const lo = Math.min(0, ...s0.values.map((v) => v || 0)), hi = Math.max(0, ...s0.values.map((v) => v || 0));
    const pw = W - left - valueW;
    const Xv = (v) => left + ((v - lo) / ((hi - lo) || 1)) * pw;
    const g = svg("svg", { viewBox: `0 0 ${W} ${H}`, width: W, height: H, class: "chart-svg", role: "img" });
    g.append(svg("line", { x1: Xv(0), x2: Xv(0), y1: top, y2: H - top, class: "axis" }));
    labels.forEach((l, i) => {
      const y = top + i * row, v = s0.values[i] || 0, bh = Math.min(24, row - 8);
      g.append(text(left - 8, y + row / 2 + 4, l, "tick", "end"));
      if (v !== 0) g.append(svg("path", { d: barPath(y + (row - bh) / 2, Xv(0), bh, Xv(v), true), class: "bar fill s1" }));
      g.append(text(v >= 0 ? Xv(v) + 6 : Xv(0) + 6, y + row / 2 + 4, fmt(s0.values[i], spec.format, spec.unit), "value-label"));
      const hit = svg("rect", { x: 0, y, width: W, height: row, class: "hit" });
      hit.addEventListener("pointermove", (ev) => {
        const r = plot.getBoundingClientRect ? plot.getBoundingClientRect() : { left: 0, top: 0 };
        showTip(tip, plot, (ev.clientX || 0) - r.left, (ev.clientY || 0) - r.top, l, [[s0.name, fmt(s0.values[i], spec.format, spec.unit), 0]]);
      });
      hit.addEventListener("pointerleave", () => { tip.hidden = true; });
      g.append(hit);
    });
    return g;
  }

  // ------------------------------------------------------------------ donut (part of the whole, ≤ 6 slices)
  function donut(spec, series, labels, W, tip, plot) {
    const vals = series[0].values.map((v) => Math.max(0, v || 0));
    const sum = vals.reduce((a, b) => a + b, 0);
    const total = sum || 1;
    const R = 90, r = 58, side = W >= 2 * R + 40 + 260;     // list beside the ring when it fits, else below
    const H = side ? Math.max(220, 24 + labels.length * 26) : 220 + labels.length * 24;
    const cx = side ? Math.min(W / 2, 140) : W / 2, cy = 110;
    const g = svg("svg", { viewBox: `0 0 ${W} ${H}`, width: W, height: H, class: "chart-svg", role: "img" });
    let a0 = -Math.PI / 2;
    vals.forEach((v, i) => {
      const a1 = a0 + (v / total) * Math.PI * 2;
      if (v > 0) {
        const large = a1 - a0 > Math.PI ? 1 : 0;
        const p = (rad, a) => `${(cx + rad * Math.cos(a)).toFixed(2)},${(cy + rad * Math.sin(a)).toFixed(2)}`;
        const d = vals.filter((x) => x > 0).length === 1
          ? `M${cx - R},${cy}A${R},${R} 0 1 1 ${cx + R},${cy}A${R},${R} 0 1 1 ${cx - R},${cy}M${cx - r},${cy}A${r},${r} 0 1 0 ${cx + r},${cy}A${r},${r} 0 1 0 ${cx - r},${cy}Z`
          : `M${p(R, a0)}A${R},${R} 0 ${large} 1 ${p(R, a1)}L${p(r, a1)}A${r},${r} 0 ${large} 0 ${p(r, a0)}Z`;
        const slice = svg("path", { d, class: `slice fill s${i + 1}` });
        slice.addEventListener("pointermove", (ev) => {
          const b = plot.getBoundingClientRect ? plot.getBoundingClientRect() : { left: 0, top: 0 };
          showTip(tip, plot, (ev.clientX || 0) - b.left, (ev.clientY || 0) - b.top, labels[i],
                  [[nf(1).format((v / total) * 100) + "%", fmt(series[0].values[i], spec.format, spec.unit), i]]);
        });
        slice.addEventListener("pointerleave", () => { tip.hidden = true; });
        g.append(slice);
      }
      a0 = a1;
    });
    g.append(text(cx, cy - 2, fmt(sum, spec.format, spec.unit), "donut-total", "middle"),
             text(cx, cy + 16, "total", "tick", "middle"));
    // labelled list beside it (identity never by color alone)
    labels.forEach((l, i) => {
      const x = side ? cx + R + 24 : 16, y = side ? 24 + i * 26 : 232 + i * 24;
      g.append(svg("rect", { x, y: y - 9, width: 12, height: 8, rx: 2, class: `fill s${i + 1}` }),
               text(x + 18, y, `${l} — ${fmt(series[0].values[i], spec.format, spec.unit)} (${nf(0).format((vals[i] / total) * 100)}%)`, "value-label"));
    });
    return g;
  }

  window.AnaCharts = { render, fmt, niceTicks };
})();
