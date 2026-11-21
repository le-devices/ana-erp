// SPDX-FileCopyrightText: 2026 André Luis Pereira dos Santos
// SPDX-License-Identifier: AGPL-3.0-or-later
// Categories of routines (spec 020, RF-020-20..23): personal and company categories holding shortcuts,
// "Copiar para categoria…" for one or more routines, sections on Início and Operação, drag to reorder and move.
"use strict";
(function () {
  const API = window.AnaApi;
  const { el, toast, errorText } = window.AnaUI;

  const state = { list: [] };

  async function load() {
    try { state.list = await API.categories(); } catch (_) { state.list = []; }
    return state.list;
  }

  const editable = () => state.list.filter((c) => c.editable);
  const isAdmin = () => (window.AnaStudio.user() || {}).role === "admin";

  /** Dialog: copy the given routines (names) to an existing category or to a new one. Resolves true when done. */
  function copyDialog(programs) {
    return new Promise((resolve) => {
      const dlg = el("dialog", { class: "md-dialog cat-dialog", "aria-label": "Copiar para categoria" });
      const choices = el("div", { class: "cat-choices", role: "radiogroup" });
      const radio = (value, label, checked) => {
        const input = el("input", { type: "radio", name: "cat", value: String(value) });
        input.checked = !!checked;
        return el("label", { class: "check" }, input, label);
      };
      const mine = editable();
      mine.forEach((c, i) => choices.append(radio(c.id, `${c.name}${c.personal ? "" : " (da empresa)"}`, i === 0)));
      choices.append(radio("new", "Nova categoria…", mine.length === 0));
      const name = el("input", { placeholder: "nome da nova categoria (ex.: Fechamento do mês)", "aria-label": "Nome da nova categoria" });
      const company = el("input", { type: "checkbox" });
      const groups = el("input", { placeholder: "grupos que veem (vazio = todos), separados por vírgula", "aria-label": "Grupos" });
      const newBox = el("div", { class: "cat-new" }, name,
        isAdmin() ? el("label", { class: "check" }, company, "da empresa (todos ou os grupos abaixo veem)") : null,
        isAdmin() ? groups : null);
      const sync = () => { newBox.hidden = (choices.querySelector("input:checked") || {}).value !== "new"; };
      choices.addEventListener("change", sync);
      const close = (ok) => { if (typeof dlg.close === "function") dlg.close(); dlg.remove(); resolve(ok); };
      dlg.append(
        el("h3", { text: programs.length === 1 ? "Copiar rotina para categoria" : `Copiar ${programs.length} rotinas para categoria` }),
        el("p", { class: "muted", text: "A rotina continua a mesma (versão, permissões e histórico): a categoria ganha um atalho para ela." }),
        choices, newBox,
        el("div", { class: "row-buttons" },
          el("button", { type: "button", class: "primary", text: "Copiar", onclick: async () => {
            try {
              let id = (choices.querySelector("input:checked") || {}).value;
              if (!id) return;
              if (id === "new") {
                const r = await API.createCategory({ name: name.value.trim(), company: company.checked,
                  groups: groups.value.split(",").map((g) => g.trim()).filter(Boolean) });
                id = r.id;
              }
              const r = await API.addShortcuts(Number(id), programs.map((p) => ({ program: p })));
              toast(`${r.added} atalho(s) na categoria.`);
              await load();
              close(true);
            } catch (e) { toast(errorText(e), true); }
          } }),
          el("button", { type: "button", text: "Cancelar", onclick: () => close(false) })));
      document.body.append(dlg);
      sync();
      if (dlg.showModal) dlg.showModal(); else dlg.setAttribute("open", "");
      (choices.querySelector("input:checked") || name).focus();
    });
  }

  /** Sections with the visible categories; `tile(shortcut, routine)` draws each shortcut; `routine(name)` resolves
   *  only routines the user may run (RF-020-23). `onChange` redraws after an edit. */
  function sections(routine, tile, onChange) {
    return state.list.map((c, idx) => {
      const items = c.shortcuts.filter((s) => routine(s.program));
      const grid = el("div", { class: "tiles cat-tiles", dataset: { category: String(c.id) } },
        items.map((s) => {
          const t = tile(s, routine(s.program));
          if (c.editable) {
            t.draggable = true;
            t.dataset.shortcut = String(s.id);
            t.addEventListener("dragstart", (e) => { e.dataTransfer.setData("text/plain", String(s.id)); t.classList.add("dragging"); });
            t.addEventListener("dragend", () => t.classList.remove("dragging"));
          }
          return t;
        }));
      if (c.editable) {
        grid.addEventListener("dragover", (e) => { e.preventDefault(); grid.classList.add("drop"); });
        grid.addEventListener("dragleave", () => grid.classList.remove("drop"));
        grid.addEventListener("drop", async (e) => {
          e.preventDefault();
          grid.classList.remove("drop");
          const sid = Number(e.dataTransfer.getData("text/plain"));
          if (!sid) return;
          // Final order of this category: the dropped shortcut goes before the tile it was dropped on (or last).
          const before = e.target.closest("[data-shortcut]");
          const order = [...grid.querySelectorAll("[data-shortcut]")].map((x) => Number(x.dataset.shortcut)).filter((x) => x !== sid);
          const at = before && Number(before.dataset.shortcut) !== sid ? order.indexOf(Number(before.dataset.shortcut)) : order.length;
          order.splice(at < 0 ? order.length : at, 0, sid);
          try {
            await Promise.all(order.map((x, i) => API.updateShortcut(x, x === sid ? { category_id: c.id, position: i } : { position: i })));
            await load(); onChange();
          } catch (err) { toast(errorText(err), true); }
        });
      }
      const tools = c.editable ? el("span", { class: "cat-tools" },
        el("button", { type: "button", class: "quiet small", title: "Subir", "aria-label": `Subir ${c.name}`, disabled: idx === 0,
          onclick: () => move(c, -1, onChange) }, "↑"),
        el("button", { type: "button", class: "quiet small", title: "Descer", "aria-label": `Descer ${c.name}`,
          disabled: idx === state.list.length - 1, onclick: () => move(c, 1, onChange) }, "↓"),
        el("button", { type: "button", class: "quiet small", text: "Renomear", onclick: async () => {
          const n = prompt("Novo nome da categoria", c.name);
          if (!n || n.trim() === c.name) return;
          try { await API.updateCategory(c.id, { name: n.trim() }); await load(); onChange(); } catch (e) { toast(errorText(e), true); }
        } }),
        el("button", { type: "button", class: "quiet small danger", text: "Excluir", onclick: async () => {
          if (!confirm(`Excluir a categoria ${c.name}? As rotinas continuam no ERP; só os atalhos desta categoria saem.`)) return;
          try { await API.deleteCategory(c.id); await load(); onChange(); } catch (e) { toast(errorText(e), true); }
        } })) : null;
      const details = el("details", { class: "tile-group cat-group", open: true },
        el("summary", {}, el("span", { class: "cat-name", text: c.name }),
          el("span", { class: "cat-kind muted", text: c.personal ? "minha" : "da empresa" }),
          el("span", { class: "table-count", text: ` (${items.length})` }), tools),
        items.length ? grid : el("p", { class: "muted cat-empty", text: c.editable ? "Arraste atalhos para cá ou use “Copiar para categoria…” nas rotinas." : "Nenhuma rotina sua nesta categoria." }));
      if (!items.length && c.editable) details.append(grid);
      return details;
    });
  }

  async function move(c, delta, onChange) {
    const ids = state.list.filter((x) => x.editable && x.personal === c.personal).map((x) => x.id);
    const i = ids.indexOf(c.id), j = i + delta;
    if (i < 0 || j < 0 || j >= ids.length) return;
    [ids[i], ids[j]] = [ids[j], ids[i]];
    try { await API.orderCategories(ids); await load(); onChange(); } catch (e) { toast(errorText(e), true); }
  }

  /** Shortcuts as targets of the top search ("Ir para…"): label → hash (RF-020-23). */
  function targets(routine, hashOf) {
    const out = [];
    for (const c of state.list) for (const s of c.shortcuts) {
      if (!routine(s.program)) continue;
      out.push([`${s.label || routine(s.program).description || s.program} — ${c.name}`, hashOf(s.program, s.params || {})]);
    }
    return out;
  }

  window.AnaCategories = { load, copyDialog, sections, targets, list: () => state.list };
})();
