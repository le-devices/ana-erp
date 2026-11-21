// SPDX-FileCopyrightText: 2026 LE Devices
// SPDX-License-Identifier: AGPL-3.0-or-later
// Minimal, safe Python syntax highlighter (produces escaped HTML).
"use strict";
(function () {
  const KEYWORDS = new Set(("False None True and as assert async await break class continue def del elif else " +
    "except finally for from global if import in is lambda nonlocal not or pass raise return try while with yield match case").split(" "));
  const BUILTINS = new Set(("abs all any bool dict enumerate filter float format int isinstance len list map max min " +
    "next object open print range repr reversed round set sorted str sum super tuple type zip ana self main PARAMS").split(" "));
  // Order matters: triple strings, strings, comments, decorators, numbers, identifiers.
  const RE = /("""[\s\S]*?(?:"""|$)|'''[\s\S]*?(?:'''|$))|([rRbBfFuU]{0,2}"(?:\\.|[^"\\\n])*"?|[rRbBfFuU]{0,2}'(?:\\.|[^'\\\n])*'?)|(#[^\n]*)|(@[A-Za-z_][\w.]*)|(\b\d[\d_]*\.?[\d_]*(?:[eE][+-]?\d+)?j?\b|\b0[xXoObB][\da-fA-F_]+\b)|([A-Za-z_]\w*)/g;

  function escape(s) {
    return s.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;");
  }

  function highlight(source) {
    let html = "", last = 0, m, afterDef = false;
    RE.lastIndex = 0;
    while ((m = RE.exec(source)) !== null) {
      if (m[0] === "") { RE.lastIndex++; continue; }
      html += escape(source.slice(last, m.index));
      const t = escape(m[0]);
      let cls = null;
      if (m[1] || m[2]) cls = "t-s";
      else if (m[3]) cls = "t-c";
      else if (m[4]) cls = "t-d";
      else if (m[5]) cls = "t-n";
      else if (m[6]) {
        if (afterDef) cls = "t-f";
        else if (KEYWORDS.has(m[6])) cls = "t-k";
        else if (BUILTINS.has(m[6])) cls = "t-b";
      }
      afterDef = !!m[6] && (m[6] === "def" || m[6] === "class");
      html += cls ? `<span class="${cls}">${t}</span>` : t;
      last = RE.lastIndex;
    }
    return html + escape(source.slice(last)) + "\n";
  }

  window.AnaHighlight = { highlight, escape };
})();
