// SPDX-FileCopyrightText: 2026 LE Devices
// SPDX-License-Identifier: AGPL-3.0-or-later
// Interface performance (spec 050, T-050-03; P18 budget: a screen opens within 1 s). Measures how long
// each screen takes to open, how long its calls to the server take and the long tasks that freeze the
// page, and sends them in batches every 30 s. Never blocks or fails the screen it measures.
(function () {
  "use strict";
  const buf = [];
  let screen = "home", longTasks = 0, t0 = 0;

  /** "#/master/party/123?x=1" → "master/party/:id": the same screen whatever the record. */
  function keyOf(hash) {
    const path = (hash || "#/home").replace(/^#\/?/, "").split("?")[0];
    const parts = path.split("/").filter(Boolean).slice(0, 3).map((p) => (/^\d+$/.test(p) ? ":id" : p));
    return (parts.join("/") || "home").replace(/[^A-Za-z0-9_./:#-]/g, "_").slice(0, 120);
  }

  function push(kind, ms, extra = {}) {
    if (buf.length < 1000) buf.push({ screen, kind, ms: Math.round(ms), ...extra });
  }

  try {
    new PerformanceObserver((list) => { longTasks += list.getEntries().length; }).observe({ type: "longtask", buffered: false });
  } catch (_) { /* not supported (some browsers): long tasks stay 0 */ }

  const AnaPerf = {
    /** A screen starts opening (the router calls it before rendering). */
    opening(hash) { screen = keyOf(hash); longTasks = 0; t0 = performance.now(); },
    /** The screen finished rendering. */
    opened() { if (t0) { push("open", performance.now() - t0, { long_tasks: longTasks }); t0 = 0; } },
    /** One call to the server from the current screen (api.js). */
    api(ms, path) { if (!String(path).startsWith("/api/ui/perf")) push("api", ms); },
    flush() {
      if (!buf.length || !window.AnaApi || !window.AnaApi.authenticated) return;
      const samples = buf.splice(0, 200);
      window.AnaApi.request("POST", "/api/ui/perf", { samples }).catch(() => {});
    },
    keyOf,
  };
  setInterval(() => AnaPerf.flush(), 30000);
  window.AnaPerf = AnaPerf;
})();
