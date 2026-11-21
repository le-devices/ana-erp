// SPDX-FileCopyrightText: 2026 LE Devices
// SPDX-License-Identifier: AGPL-3.0-or-later
// Planning grid by period (spec 020, RF-020-15) and the chart that follows it (RF-020-16). Rows are
// combinations of dimensions, fixed on the left; one column per period (horizontal scroll); totals per
// period and per row; in-place editing with Brazilian numbers (negatives refused where they make no sense);
// paste a block from a spreadsheet; row selection for batch actions; export and import a spreadsheet; save
// sends only what changed, with the version that was read (someone else saved in between → refused).
// Below it, planned × consumed × available of the selected row (or the sum of the selection), one axis.
"use strict";
(function () {
  const { el, toast, errorText, icon } = window.AnaUI;

  const active = new Set();          // grids on screen with unsaved changes ask before leaving
  window.AnaLeave = {
    dirty: () => [...active].some((g) => g.node.isConnected && g.changes() > 0),
    message: () => "Há alterações não salvas na grade. Sair mesmo assim?",
  };
  window.addEventListener("beforeunload", (e) => { if (window.AnaLeave.dirty()) { e.preventDefault(); e.returnValue = ""; } });

  /** "1.234,56" / "1234,5" / "1234.5" / "1.000" → number; "" → null; anything else → NaN. */
  function parseBr(s) {
    const t = String(s ?? "").trim().replace(/^R\$\s*/, "");
    if (t === "") return null;
    if (/^-?\d{1,3}(\.\d{3})+(,\d+)?$/.test(t) || /^-?\d+,\d+$/.test(t)) return Number(t.replace(/\./g, "").replace(",", "."));
    return /^-?\d+(\.\d+)?$/.test(t) ? Number(t) : NaN;
  }
  const num = (v) => (v === null || v === undefined || v === "" ? null : Number(v));

  /**
   * d: the "grid" output of a program (ana.grid); ctx: {run(program, params), lookup?(program, params)}.
   */
  function render(d, ctx) {
    const dec = d.decimals ?? 2;
    const nf = new Intl.NumberFormat("pt-BR", { minimumFractionDigits: dec, maximumFractionDigits: dec });
    const fmt = (v) => (v === null || v === undefined || isNaN(v) ? "" : nf.format(v));
    const periods = d.periods, dims = d.dimensions;
    const statuses = d.statuses || null;
    const statusLabel = (s) => ((statuses || []).find(([k]) => k === s) || [null, s || ""])[1];
    let version = d.version;
    // Working copy: original values kept to know what changed.
    let rows = d.rows.map((r) => ({ key: r.key, labels: r.labels || {}, orig: { ...mapNum(r.values) }, values: { ...mapNum(r.values) },
                                    consumed: mapNum(r.consumed || {}), status: r.status, origStatus: r.status,
                                    comment: r.comment || "", origComment: r.comment || "", added: false }));
    const selected = new Set();
    let focusRow = rows.length ? 0 : -1;
    let filter = "";

    const node = el("div", { class: "grid-box" });
    const me = { node, changes: () => changedRows().length };
    active.add(me);

    function mapNum(o) { const out = {}; for (const [k, v] of Object.entries(o || {})) out[k] = num(v); return out; }
    const dimText = (r, k) => r.labels[k] || String(r.key[k] ?? "");
    const rowTotal = (r) => periods.reduce((s, p) => s + (r.values[p.key] || 0), 0);
    const cellChanged = (r, p) => (r.values[p] ?? null) !== (r.orig[p] ?? null);
    const rowChanged = (r) => r.added || periods.some((p) => cellChanged(r, p.key)) || r.status !== r.origStatus || r.comment !== r.origComment;
    function changedRows() { return rows.filter(rowChanged); }
    const visibleRows = () => rows.filter((r) => !filter || dims.some((k) => dimText(r, k.key).toLowerCase().includes(filter)));

    // ---------------------------------------------------------------- table
    const table = el("table", { class: "grid-table plan-grid", role: "grid", "aria-label": d.title || "Grade de planejamento" });
    const scroller = el("div", { class: "plan-scroll" }, table);
    const count = el("span", { class: "table-count" });
    const dirtyNote = el("span", { class: "plan-dirty", "aria-live": "polite" });
    const saveBtn = el("button", { type: "button", class: "primary small", text: "Salvar alterações", disabled: true, onclick: save });
    const search = el("input", { type: "search", class: "table-search", placeholder: "Buscar linha", "aria-label": "Buscar linha da grade" });
    search.addEventListener("input", () => { filter = search.value.trim().toLowerCase(); draw(); });
    const bulk = el("div", { class: "table-bulk", hidden: true });
    const chartBox = el("div", { class: "plan-chart" });

    function draw() {
      const vis = visibleRows();
      const head = el("tr", {},
        el("th", { class: "sel sticky-col", "data-col": "0" }, (() => {
          const all = el("input", { type: "checkbox", "aria-label": "Selecionar todas as linhas" });
          all.checked = vis.length > 0 && vis.every((r) => selected.has(r));
          all.addEventListener("change", () => { for (const r of vis) all.checked ? selected.add(r) : selected.delete(r); draw(); drawChart(); });
          return all;
        })()),
        dims.map((k, i) => el("th", { class: "sticky-col dim", "data-col": String(i + 1), text: k.label })),
        periods.map((p) => el("th", { class: "num period", text: p.label, scope: "col" })),
        el("th", { class: "num total", text: "Total" }),
        statuses ? el("th", { text: "Situação" }) : null,
        d.comments ? el("th", { text: "Comentário" }) : null);
      const body = vis.map((r) => {
        const ri = rows.indexOf(r);
        const box = el("input", { type: "checkbox", "aria-label": `Selecionar ${dims.map((k) => dimText(r, k.key)).join(" · ")}` });
        box.checked = selected.has(r);
        box.addEventListener("change", () => { box.checked ? selected.add(r) : selected.delete(r); drawBulk(); drawChart(); });
        const tr = el("tr", { class: (ri === focusRow ? "focus " : "") + (r.added ? "added" : ""), dataset: { row: String(ri) } },
          el("td", { class: "sel sticky-col", "data-col": "0" }, box),
          dims.map((k, i) => el("td", { class: "sticky-col dim", "data-col": String(i + 1), text: dimText(r, k.key), title: dimText(r, k.key) })),
          periods.map((p) => el("td", { class: "num cell" + (cellChanged(r, p.key) ? " changed" : "") + ((r.values[p.key] || 0) < 0 ? " negative" : ""),
                                        tabindex: "-1", role: "gridcell", dataset: { period: p.key }, text: fmt(r.values[p.key]),
                                        "aria-label": `${p.label}: ${fmt(r.values[p.key]) || "vazio"}` })),
          el("td", { class: "num total", text: fmt(rowTotal(r)) }),
          statuses ? el("td", { class: r.status !== r.origStatus ? "changed" : "" }, statusSelect(r)) : null,
          d.comments ? el("td", { class: "comment" + (r.comment !== r.origComment ? " changed" : "") }, commentInput(r)) : null);
        tr.addEventListener("click", (e) => {
          if (e.target.closest("input,select,button")) return;
          focusRow = ri;
          for (const x of table.querySelectorAll("tr.focus")) x.classList.remove("focus");
          tr.classList.add("focus");
          drawChart();
        });
        return tr;
      });
      const foot = el("tr", { class: "totals" },
        el("td", { class: "sticky-col", "data-col": "0" }),
        dims.map((k, i) => el("td", { class: "sticky-col dim", "data-col": String(i + 1), text: i === 0 ? "Total" : "" })),
        periods.map((p) => el("td", { class: "num", text: fmt(vis.reduce((s, r) => s + (r.values[p.key] || 0), 0)) })),
        el("td", { class: "num total", text: fmt(vis.reduce((s, r) => s + rowTotal(r), 0)) }),
        statuses ? el("td") : null, d.comments ? el("td") : null);
      table.replaceChildren(el("thead", {}, head), el("tbody", {}, body.length ? body
        : el("tr", {}, el("td", { colspan: String(dims.length + periods.length + 4), class: "muted",
          text: rows.length ? "Nenhuma linha com essa busca." : "Nenhuma linha ainda. Use “Incluir linha”." }))), el("tfoot", {}, foot));
      stickOffsets();
      count.textContent = `(${vis.length}${vis.length !== rows.length ? " de " + rows.length : ""})`;
      drawDirty();
      drawBulk();
    }

    // Fixed columns: left offsets measured from the header (widths vary with the labels).
    function stickOffsets() {
      setTimeout(() => {
        const ths = [...table.querySelectorAll("thead th.sticky-col")];
        let left = 0;
        ths.forEach((th, i) => {
          for (const c of table.querySelectorAll(`.sticky-col[data-col="${i}"]`)) c.style.left = left + "px";   // CSSOM (CSP-safe)
          left += th.getBoundingClientRect().width || 0;
        });
      }, 0);
    }

    function statusSelect(r) {
      const s = el("select", { "aria-label": "Situação", class: "small" }, statuses.map(([k, l]) => el("option", { value: k, text: l })));
      s.value = r.status || statuses[0][0];
      s.addEventListener("change", () => { r.status = s.value; draw(); });
      return s;
    }
    function commentInput(r) {
      const i = el("input", { value: r.comment, maxlength: "500", "aria-label": "Comentário", class: "small" });
      i.addEventListener("change", () => { r.comment = i.value; draw(); });
      return i;
    }

    // ---------------------------------------------------------------- editing (one input at a time)
    let editor = null;
    function cellAt(ri, pi) {
      const tr = table.querySelector(`tbody tr[data-row="${ri}"]`);
      return tr && tr.querySelectorAll("td.cell")[pi];
    }
    function position(td) {
      const tr = td.closest("tr");
      return { ri: Number(tr.dataset.row), pi: [...tr.querySelectorAll("td.cell")].indexOf(td) };
    }
    function focusCell(ri, pi) {
      const vis = visibleRows().map((r) => rows.indexOf(r));
      if (!vis.length) return;
      const at = Math.max(0, Math.min(vis.length - 1, vis.indexOf(ri) < 0 ? 0 : vis.indexOf(ri)));
      const td = cellAt(vis[at], Math.max(0, Math.min(periods.length - 1, pi)));
      if (td) { td.tabIndex = 0; td.focus(); }
    }
    function setValue(ri, pi, raw) {
      const v = parseBr(raw);
      const label = `${dims.map((k) => dimText(rows[ri], k.key)).join(" · ")} · ${periods[pi].label}`;
      if (Number.isNaN(v)) { toast(`${label}: valor inválido (${raw})`, true); return false; }
      if (v !== null && v < 0 && !d.negative) { toast(`${label}: negativo não é aceito aqui`, true); return false; }
      rows[ri].values[periods[pi].key] = v === null ? null : Math.round(v * 10 ** dec) / 10 ** dec;
      return true;
    }
    function edit(td, initial) {
      if (editor) editor.commit();
      const { ri, pi } = position(td);
      const r = rows[ri];
      const input = el("input", { class: "cell-editor", inputmode: "decimal", "aria-label": td.getAttribute("aria-label") || "valor",
                                  value: initial !== undefined ? initial : fmt(r.values[periods[pi].key]) });
      td.replaceChildren(input);
      input.focus();
      if (initial === undefined) input.select();
      let done = false;
      const commit = (move) => {
        if (done) return;
        done = true;
        editor = null;
        const ok = setValue(ri, pi, input.value);
        draw(); drawChart();
        if (move) focusCell(ri + (move === "down" ? 1 : move === "up" ? -1 : 0), pi + (move === "right" ? 1 : move === "left" ? -1 : 0));
        else if (!ok) focusCell(ri, pi);
      };
      editor = { commit: () => commit() };
      input.addEventListener("keydown", (e) => {
        if (e.key === "Enter") { e.preventDefault(); commit("down"); }
        else if (e.key === "Tab") { e.preventDefault(); commit(e.shiftKey ? "left" : "right"); }
        else if (e.key === "Escape") { done = true; editor = null; draw(); focusCell(ri, pi); }
        else if (e.key === "ArrowDown" || e.key === "ArrowUp") { e.preventDefault(); commit(e.key === "ArrowDown" ? "down" : "up"); }
      });
      input.addEventListener("blur", () => commit());
      input.addEventListener("paste", (e) => { if (pasteBlock(e, ri, pi)) { done = true; editor = null; } });
    }
    table.addEventListener("dblclick", (e) => { const td = e.target.closest("td.cell"); if (td) edit(td); });
    table.addEventListener("keydown", (e) => {
      const td = e.target.closest && e.target.closest("td.cell");
      if (!td || e.target !== td) return;
      const { ri, pi } = position(td);
      const vis = visibleRows().map((r) => rows.indexOf(r));
      const at = vis.indexOf(ri);
      const go = { ArrowDown: [1, 0], ArrowUp: [-1, 0], ArrowRight: [0, 1], ArrowLeft: [0, -1] }[e.key];
      if (go) { e.preventDefault(); focusCell(vis[Math.max(0, Math.min(vis.length - 1, at + go[0]))], pi + go[1]); }
      else if (e.key === "Enter" || e.key === "F2") { e.preventDefault(); edit(td); }
      else if (e.key === "Delete" || e.key === "Backspace") { e.preventDefault(); setValue(ri, pi, ""); draw(); drawChart(); focusCell(ri, pi); }
      else if (e.key.length === 1 && /[\d,.\-]/.test(e.key) && !e.ctrlKey && !e.metaKey) { e.preventDefault(); edit(td, e.key); }
    });
    table.addEventListener("click", (e) => { const td = e.target.closest("td.cell"); if (td && !e.target.closest("input")) { td.tabIndex = 0; td.focus(); } });
    table.addEventListener("paste", (e) => {
      const td = e.target.closest && e.target.closest("td.cell");
      if (td && e.target === td) { const { ri, pi } = position(td); pasteBlock(e, ri, pi); }
    });

    /** A block copied from a spreadsheet (tabs and lines) fills from this cell to the right and down. */
    function pasteBlock(e, ri, pi) {
      const text = (e.clipboardData || window.clipboardData || { getData: () => "" }).getData("text");
      if (!/[\t\n]/.test(text.trim())) return false;
      e.preventDefault();
      const vis = visibleRows().map((r) => rows.indexOf(r));
      const start = vis.indexOf(ri);
      const lines = text.replace(/\r/g, "").replace(/\n$/, "").split("\n");
      let n = 0, bad = 0;
      lines.forEach((line, li) => {
        const target = vis[start + li];
        if (target === undefined) return;
        line.split("\t").forEach((raw, ci) => {
          if (pi + ci >= periods.length) return;
          if (setValue(target, pi + ci, raw)) n++; else bad++;
        });
      });
      draw(); drawChart();
      toast(`${n} célula(s) coladas${bad ? `, ${bad} recusada(s)` : ""}.`, bad > 0);
      focusCell(ri, pi);
      return true;
    }

    // ---------------------------------------------------------------- batch, include, export/import
    function drawBulk() {
      const picked = rows.filter((r) => selected.has(r));
      bulk.hidden = !picked.length;
      if (!picked.length) { bulk.replaceChildren(); return; }
      const statusPick = statuses ? el("select", { class: "small", "aria-label": "Nova situação" },
        el("option", { value: "", text: "Mudar situação…" }), statuses.map(([k, l]) => el("option", { value: k, text: l }))) : null;
      if (statusPick) statusPick.addEventListener("change", () => { if (!statusPick.value) return; for (const r of picked) r.status = statusPick.value; draw(); });
      bulk.replaceChildren(el("span", { text: `${picked.length} linha(s) selecionada(s)` }), statusPick,
        el("button", { type: "button", class: "quiet small", text: "Copiar", title: "Copia as linhas para colar numa planilha", onclick: () => copyRows(picked) }),
        el("button", { type: "button", class: "quiet small", text: "Repetir 1º período", title: "Copia o valor do primeiro período para os demais",
          onclick: () => { for (const r of picked) for (const p of periods) r.values[p.key] = r.values[periods[0].key] ?? null; draw(); drawChart(); } }),
        el("button", { type: "button", class: "quiet small danger", text: "Excluir valores", onclick: () => {
          if (!confirm(`Apagar os valores de ${picked.length} linha(s)? Só vale ao salvar.`)) return;
          for (const r of picked) for (const p of periods) r.values[p.key] = null;
          draw(); drawChart();
        } }),
        el("button", { type: "button", class: "quiet small", text: "Limpar seleção", onclick: () => { selected.clear(); draw(); drawChart(); } }));
    }

    const tsv = (list) => list.map((r) => [...dims.map((k) => dimText(r, k.key)), ...periods.map((p) => fmt(r.values[p.key]))].join("\t")).join("\n");
    function copyRows(list) {
      const text = tsv(list);
      const fallback = () => { const t = el("textarea", { value: text }); document.body.append(t); t.select(); document.execCommand && document.execCommand("copy"); t.remove(); };
      if (navigator.clipboard && navigator.clipboard.writeText) navigator.clipboard.writeText(text).then(() => toast(`${list.length} linha(s) copiadas.`), fallback);
      else { fallback(); toast(`${list.length} linha(s) copiadas.`); }
    }

    function exportCsv() {
      const q = (s) => (/[";\n]/.test(s) ? `"${s.replace(/"/g, '""')}"` : s);
      const head = [...dims.map((k) => k.label), ...periods.map((p) => p.label), "Total", ...(statuses ? ["Situação"] : []), ...(d.comments ? ["Comentário"] : [])];
      const lines = [head.map(q).join(";"), ...rows.map((r) => [...dims.map((k) => dimText(r, k.key)), ...periods.map((p) => fmt(r.values[p.key])),
        fmt(rowTotal(r)), ...(statuses ? [statusLabel(r.status)] : []), ...(d.comments ? [r.comment] : [])].map((x) => q(String(x ?? ""))).join(";"))];
      const a = el("a", { href: "data:text/csv;charset=utf-8," + encodeURIComponent("﻿" + lines.join("\n")),
                          download: (d.title || "grade").replace(/[^\w\- ]+/g, "").trim().replace(/\s+/g, "_") + ".csv" });
      document.body.append(a); a.click(); a.remove();
    }

    /** A spreadsheet in the export's layout (dimension columns, then periods by their label). The code before the
     *  first space identifies each dimension ("ADM Administração" → ADM). Unknown rows come in as new ones. */
    function importText(text) {
      const lines = text.replace(/^﻿/, "").replace(/\r/g, "").split("\n").filter((l) => l.trim());
      if (lines.length < 2) { toast("A planilha precisa do cabeçalho e de ao menos uma linha.", true); return; }
      const sep = lines[0].includes("\t") ? "\t" : ";";
      const split = (l) => { const out = []; let cur = "", q = false; for (const ch of l) { if (ch === '"') q = !q; else if (ch === sep && !q) { out.push(cur); cur = ""; } else cur += ch; } out.push(cur); return out.map((x) => x.trim()); };
      const head = split(lines[0]);
      const pcol = periods.map((p) => head.findIndex((h) => h.toLowerCase() === p.label.toLowerCase() || h === p.key));
      if (pcol.every((i) => i < 0)) { toast("Nenhuma coluna de período reconhecida (use o cabeçalho da exportação).", true); return; }
      const code = (s) => String(s).split(/\s+/)[0];
      let n = 0, created = 0, bad = 0;
      for (const l of lines.slice(1)) {
        const c = split(l);
        const key = Object.fromEntries(dims.map((k, i) => [k.key, code(c[i] || "")]));
        if (dims.some((k) => !key[k.key])) { bad++; continue; }
        let r = rows.find((x) => dims.every((k) => String(x.key[k.key]).toUpperCase() === key[k.key].toUpperCase()));
        if (!r) {
          if (!d.add) { bad++; continue; }
          r = newRow(key, Object.fromEntries(dims.map((k, i) => [k.key, c[i]])));
          created++;
        }
        const ri = rows.indexOf(r);
        pcol.forEach((ci, pi) => { if (ci >= 0 && c[ci] !== undefined) { if (setValue(ri, pi, c[ci])) n++; else bad++; } });
      }
      draw(); drawChart();
      toast(`${n} valor(es) importado(s)${created ? `, ${created} linha(s) nova(s)` : ""}${bad ? `, ${bad} recusado(s)` : ""}. Confira e salve.`, bad > 0);
    }
    function newRow(key, labels) {
      const r = { key, labels: labels || {}, orig: {}, values: {}, consumed: {}, status: statuses ? statuses[0][0] : undefined,
                  origStatus: statuses ? statuses[0][0] : undefined, comment: "", origComment: "", added: true };
      rows.push(r);
      return r;
    }

    function includeDialog() {
      const dlg = el("dialog", { class: "md-dialog", "aria-label": "Incluir linha" });
      const pickers = dims.map((k) => {
        const lk = d.add && d.add[k.key];
        const input = el("input", { list: `grid-add-${k.key}`, placeholder: k.label, "aria-label": k.label });
        const list = el("datalist", { id: `grid-add-${k.key}` });
        if (lk && ctx && ctx.lookup) ctx.lookup(lk.program, lk.params || {}).then((opts) =>
          list.replaceChildren(...(opts || []).slice(0, 500).map((o) => el("option", { value: String(o.value), label: o.label }))));
        return { k, input, list, lk };
      });
      const close = () => { if (typeof dlg.close === "function") dlg.close(); dlg.remove(); };
      dlg.append(el("h3", { text: "Incluir linha" }), ...pickers.map((p) => el("label", { class: "md-field" }, el("span", { text: p.k.label }), p.input, p.list)),
        el("div", { class: "row-buttons" },
          el("button", { type: "button", class: "primary", text: "Incluir", onclick: () => {
            const key = Object.fromEntries(pickers.map((p) => [p.k.key, p.input.value.trim().split(/\s+/)[0]]));
            if (pickers.some((p) => !key[p.k.key])) { toast("Informe todas as dimensões.", true); return; }
            if (rows.some((x) => dims.every((k) => String(x.key[k.key]).toUpperCase() === String(key[k.key]).toUpperCase()))) { toast("Essa linha já está na grade.", true); return; }
            const labels = Object.fromEntries(pickers.map((p) => {
              const o = [...p.list.options].find((x) => x.value === key[p.k.key]);
              return [p.k.key, o && o.label ? `${key[p.k.key]} ${o.label}` : key[p.k.key]];
            }));
            const r = newRow(key, labels);
            close(); filter = ""; search.value = ""; focusRow = rows.indexOf(r); draw(); drawChart();
            focusCell(rows.indexOf(r), 0);
          } }),
          el("button", { type: "button", text: "Cancelar", onclick: close })));
      document.body.append(dlg);
      if (dlg.showModal) dlg.showModal(); else dlg.setAttribute("open", "");
      pickers[0].input.focus();
    }

    // ---------------------------------------------------------------- save
    function drawDirty() {
      const n = changedRows().length;
      saveBtn.disabled = !n || !d.save;
      saveBtn.textContent = n ? `Salvar alterações (${n})` : "Salvar alterações";
      dirtyNote.textContent = n ? `${n} linha(s) alterada(s), não salvas` : "";
    }
    async function save() {
      if (editor) editor.commit();
      const list = changedRows();
      if (!list.length || !d.save) return;
      const changes = list.map((r) => {
        const values = {};
        for (const p of periods) if (r.added ? r.values[p.key] !== undefined : cellChanged(r, p.key)) {
          values[p.key] = r.values[p.key] === null || r.values[p.key] === undefined ? null : r.values[p.key].toFixed(dec);
        }
        const ch = { key: r.key, values };
        if (statuses && (r.added || r.status !== r.origStatus || r.comment !== r.origComment)) { ch.status = r.status; ch.comment = r.comment; }
        else if (d.comments && r.comment !== r.origComment) ch.comment = r.comment;
        return ch;
      });
      saveBtn.disabled = true;
      try {
        const res = await ctx.run(d.save.program, { ...(d.save.params || {}), changes, version });
        const result = res && res.result !== undefined ? res.result : res;
        if (res && res.error) throw Object.assign(new Error(res.error.message || res.error.code), { code: res.error.code });
        version = (result && result.version) || version;
        for (const r of rows) { r.orig = { ...r.values }; r.origStatus = r.status; r.origComment = r.comment; r.added = false; }
        rows = rows.filter((r) => periods.some((p) => r.values[p.key] !== null && r.values[p.key] !== undefined) || statuses || d.comments);
        toast(`Grade salva: ${changes.length} linha(s).`);
      } catch (e) {
        toast(e.code === "CONFLICT" || /CONFLICT/.test(errorText(e)) ? e.message || errorText(e) : errorText(e), true);
      }
      draw(); drawChart();
    }

    // ---------------------------------------------------------------- chart (RF-020-16)
    function drawChart() {
      if (!window.AnaCharts || !d.consumed_label) { chartBox.hidden = true; return; }
      const picked = rows.filter((r) => selected.has(r));
      const base = picked.length ? picked : focusRow >= 0 && rows[focusRow] ? [rows[focusRow]] : [];
      if (!base.length) { chartBox.replaceChildren(el("p", { class: "muted", text: "Selecione uma linha para ver o gráfico." })); return; }
      const sum = (f) => periods.map((p) => base.reduce((s, r) => s + (f(r, p.key) || 0), 0));
      const planned = sum((r, k) => r.values[k]);
      const consumed = sum((r, k) => r.consumed[k]);
      const available = planned.map((v, i) => Math.round((v - consumed[i]) * 100) / 100);
      const who = base.length === 1 ? dims.map((k) => dimText(base[0], k.key)).join(" · ") : `soma de ${base.length} linhas`;
      const negatives = available.filter((v) => v < 0).length;
      const chart = window.AnaCharts.render({
        type: "column", title: `${d.value_label} × ${d.consumed_label} × ${d.available_label || "Disponível"}`, subtitle: who,
        x: periods.map((p) => p.label), format: d.unit === "R$" ? "money" : undefined, alert: { series: 2, label: "negativo" },
        series: [{ name: d.value_label, values: planned }, { name: d.consumed_label, values: consumed },
                 { name: d.available_label || "Disponível", values: available }],
      });
      const full = el("button", { type: "button", class: "quiet small icon-text", title: "Tela cheia (Esc sai)", onclick: () => {
        chartBox.classList.toggle("full");
        full.lastChild.textContent = chartBox.classList.contains("full") ? "Sair da tela cheia" : "Tela cheia";
        window.dispatchEvent(new Event("resize"));
      } }, icon("expand", 16), el("span", { text: chartBox.classList.contains("full") ? "Sair da tela cheia" : "Tela cheia" }));
      const tools = chart.querySelector(".chart-tools");
      if (tools) tools.append(full);
      chartBox.replaceChildren(chart, negatives ? el("p", { class: "plan-alert", role: "status" },
        `⚠ ${d.available_label || "Disponível"} negativo em ${negatives} período(s).`) : null);
    }
    chartBox.addEventListener("keydown", (e) => { if (e.key === "Escape" && chartBox.classList.contains("full")) { chartBox.classList.remove("full"); drawChart(); } });

    const fileInput = el("input", { type: "file", accept: ".csv,.txt,text/csv", hidden: true });
    fileInput.addEventListener("change", async () => { const f = fileInput.files[0]; if (f) importText(await f.text()); fileInput.value = ""; });
    node.append(
      el("div", { class: "table-box work-box" },
        el("div", { class: "table-head" }, el("strong", { class: "table-title", text: d.title || "Planejamento" }), count,
          el("div", { class: "table-tools" }, search,
            d.add ? el("button", { type: "button", class: "quiet small icon-text", onclick: includeDialog }, icon("plus", 16), el("span", { text: "Incluir linha" })) : null,
            el("button", { type: "button", class: "quiet small icon-text", title: "Exportar para planilha (CSV)", onclick: exportCsv }, icon("download", 16), el("span", { text: "CSV" })),
            el("button", { type: "button", class: "quiet small", text: "Importar planilha", title: "CSV no formato da exportação", onclick: () => fileInput.click() }),
            fileInput)),
        bulk, scroller,
        el("div", { class: "plan-foot" }, el("span", { class: "muted small", text: "Clique numa célula e digite; Enter desce, Tab vai ao lado; cole um bloco da planilha." }),
          dirtyNote, saveBtn)),
      chartBox);
    draw();
    drawChart();
    return node;
  }

  window.AnaGrid = { render, parseBr };
})();
