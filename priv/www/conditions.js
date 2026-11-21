// SPDX-FileCopyrightText: 2026 LE Devices
// SPDX-License-Identifier: AGPL-3.0-or-later
// Condition builder (spec 020, RF-020-14): lines "campo · operador · valor" with value help and the operators
// of the field's type; criteria in tabs (lines of a criterion hold together — E; between criteria one is
// enough — OU) and separate exceptions ("exceto…"). The result is the restricted rule the core evaluates
// (ana_flows:condition/2, util.conditions) — never code — and its text in Portuguese.
"use strict";
(function () {
  const { el } = window.AnaUI;

  const OPS = {
    "=": "é", "!=": "não é", "<": "menor que", "<=": "até", ">": "maior que", ">=": "a partir de",
    in: "é um de", not_in: "não é nenhum de", between: "entre", contains: "contém", not_contains: "não contém",
    starts: "começa com", empty: "está vazio", not_empty: "está preenchido",
  };
  const BY_TYPE = {
    number: ["=", "!=", ">", ">=", "<", "<=", "between", "in", "not_in", "empty", "not_empty"],
    date: ["=", "!=", ">", ">=", "<", "<=", "between", "empty", "not_empty"],
    text: ["=", "!=", "contains", "not_contains", "starts", "in", "not_in", "empty", "not_empty"],
    choice: ["=", "!=", "in", "not_in", "empty", "not_empty"],
    bool: ["=", "!="],
  };
  const NO_VALUE = new Set(["empty", "not_empty"]);
  const LISTS = new Set(["in", "not_in"]);

  /** {any: [[rule]], except: [rule]} from either shape (a list is one criterion). */
  function normalize(c) {
    if (Array.isArray(c)) return { any: c.length ? [c.map((r) => ({ ...r }))] : [], except: [] };
    if (c && typeof c === "object") {
      return { any: (c.any || []).filter(Array.isArray).map((x) => x.map((r) => ({ ...r }))),
               except: (c.except || []).filter((r) => r && typeof r === "object").map((r) => ({ ...r })) };
    }
    return { any: [], except: [] };
  }
  /** The stored rule: a plain list when there is one criterion and no exception (the first format). */
  function compact(n) {
    const any = n.any.map((c) => c.filter((r) => r.field)).filter((c) => c.length);
    const except = n.except.filter((r) => r.field);
    if (!except.length && any.length <= 1) return any[0] || [];
    return { any, except };
  }

  const fmtNum = (v) => (typeof v === "number" ? v.toLocaleString("pt-BR", { maximumFractionDigits: 6 }) : String(v));
  function valueText(v, f) {
    if (f && f.choices) { const c = f.choices.find(([k]) => String(k) === String(v)); if (c) return c[1]; }
    if (typeof v === "boolean") return v ? "sim" : "não";
    return fmtNum(v);
  }
  function ruleText(r, fields) {
    const f = fields.find((x) => x.name === r.field);
    const name = f ? f.label : r.field;
    const v = r.value;
    if (NO_VALUE.has(r.op)) return `${name} ${OPS[r.op]}`;
    if (LISTS.has(r.op) && Array.isArray(v)) {
      const vals = v.map((x) => valueText(x, f));
      const joined = vals.length === 1 ? vals[0] : vals.slice(0, -1).join(", ") + " ou " + vals[vals.length - 1];
      return `${name} ${r.op === "in" ? "é" : "não é"} ${joined}`;
    }
    if (r.op === "between" && Array.isArray(v)) return `${name} entre ${valueText(v[0], f)} e ${valueText(v[1], f)}`;
    return `${name} ${OPS[r.op] || r.op} ${valueText(v, f)}`;
  }
  /** "Filial é AK01 ou AK02, exceto Cliente bloqueado é sim" (same text as util.conditions.text). */
  function describe(c, fields = []) {
    const n = normalize(c);
    const crit = n.any.map((x) => x.filter((r) => r.field)).filter((x) => x.length).map((x) => x.map((r) => ruleText(r, fields)).join(" e "));
    let out = !crit.length ? "sempre" : crit.length === 1 ? crit[0] : crit.map((x) => `(${x})`).join(" ou ");
    const ex = n.except.filter((r) => r.field);
    if (ex.length) out += ", exceto " + ex.map((r) => ruleText(r, fields)).join(" ou ");
    return out;
  }

  /** Typed value from what the person wrote: numbers in the Brazilian format, sim/não for yes/no. */
  function parse(s, f) {
    const t = String(s ?? "").trim();
    const type = f ? f.type : null;
    if (type === "bool") return t === "true" || t === "sim";
    if (type === "number" || (!type && /^-?\d{1,3}(\.\d{3})*(,\d+)?$|^-?\d+(,\d+)?$/.test(t))) {
      const n = Number(t.replace(/\./g, "").replace(",", "."));
      if (t !== "" && !Number.isNaN(n)) return n;
    }
    return t;
  }
  const show = (v) => (v === null || v === undefined ? "" : typeof v === "number" ? fmtNum(v) : typeof v === "boolean" ? (v ? "true" : "false") : String(v));

  let seq = 0;
  /**
   * fields: [{name, label, type: text|number|date|bool|choice, choices?: [[value, label]], lookup?: (text) → Promise<[[value, label]]>}]
   * (no fields or free: the field is typed, the fields come as suggestions). Returns {node, get(), set(c), text()}.
   */
  function builder({ fields = [], value, onChange, editable = true, free = false } = {}) {
    let n = normalize(value);
    const starter = () => { if (!n.any.length) n.any.push([]); if (!n.any[0].length) n.any[0].push({ field: "", op: "" }); };
    starter();
    let tab = 0;
    const id = "cond" + (++seq);
    const node = el("div", { class: "cond-builder" });
    const preview = el("p", { class: "cond-text", "aria-live": "polite" });
    const fieldOf = (name) => fields.find((f) => f.name === name);
    const changed = () => { preview.textContent = "Regra: " + describe(n, fields); if (onChange) onChange(compact(n)); };

    function valueBox(r, f) {
      if (NO_VALUE.has(r.op)) return el("span", { class: "cond-novalue" });
      const listId = `${id}-v-${Math.random().toString(36).slice(2, 8)}`;
      const datalist = el("datalist", { id: listId });
      const fill = (opts) => datalist.replaceChildren(...opts.slice(0, 50).map(([v, l]) => el("option", { value: String(v), label: l || "" })));
      if (f && f.choices) fill(f.choices);
      const help = (input) => {
        if (!f || !f.lookup) return;
        let t = null;
        input.addEventListener("input", () => {
          clearTimeout(t);
          t = setTimeout(async () => { try { fill(await f.lookup(input.value.split(",").pop().trim())); } catch (_) { /* no help */ } }, 200);
        });
      };
      const input = (val, set, label) => {
        if (f && f.type === "bool") {
          const s = el("select", { disabled: !editable, "aria-label": label }, el("option", { value: "true", text: "sim" }), el("option", { value: "false", text: "não" }));
          s.value = val === false ? "false" : "true";
          if (val === undefined || val === null || val === "") set(true);
          s.addEventListener("change", () => { set(s.value === "true"); changed(); });
          return s;
        }
        const i = el("input", { value: show(val), disabled: !editable, list: listId, "aria-label": label,
                                type: f && f.type === "date" ? "date" : "text", placeholder: f && f.type === "number" ? "ex.: 1.500,00" : "valor" });
        i.addEventListener("change", () => { set(parse(i.value, f)); changed(); });
        help(i);
        return i;
      };
      if (r.op === "between") {
        const v = Array.isArray(r.value) ? r.value : ["", ""];
        r.value = v;
        return el("span", { class: "cond-between" }, input(v[0], (x) => { r.value[0] = x; }, "de"), el("span", { text: " e " }), input(v[1], (x) => { r.value[1] = x; }, "até"), datalist);
      }
      if (LISTS.has(r.op)) {
        const v = Array.isArray(r.value) ? r.value : r.value === undefined || r.value === "" ? [] : [r.value];
        r.value = v;
        const i = el("input", { value: v.map(show).join(", "), disabled: !editable, list: listId, "aria-label": "valores separados por vírgula",
                                placeholder: "valores separados por vírgula" });
        i.addEventListener("change", () => { r.value = i.value.split(",").map((x) => x.trim()).filter(Boolean).map((x) => parse(x, f)); changed(); });
        help(i);
        return el("span", { class: "cond-list" }, i, datalist);
      }
      if (Array.isArray(r.value)) r.value = r.value[0] ?? "";
      return el("span", {}, input(r.value, (x) => { r.value = x; }, "valor"), datalist);
    }

    function line(r, list, i) {
      const f = fieldOf(r.field);
      const ops = (f && BY_TYPE[f.type]) || Object.keys(OPS);
      if (!r.op || !ops.includes(r.op)) r.op = ops[0];
      let fieldCtl;
      if (fields.length && !free) {
        fieldCtl = el("select", { disabled: !editable, "aria-label": "campo" }, el("option", { value: "", text: "campo…" }),
          fields.map((x) => el("option", { value: x.name, text: x.label })));
        fieldCtl.value = r.field || "";
        if (r.field && !f) fieldCtl.append(el("option", { value: r.field, text: r.field, selected: true }));
      } else {
        fieldCtl = el("input", { value: r.field || "", placeholder: "campo", disabled: !editable, "aria-label": "campo", list: id + "-fields" });
      }
      fieldCtl.addEventListener("change", () => { r.field = fieldCtl.value.trim(); r.value = ""; draw(); changed(); });
      const opCtl = el("select", { disabled: !editable, "aria-label": "operador" }, ops.map((k) => el("option", { value: k, text: OPS[k] })));
      opCtl.value = r.op;
      opCtl.addEventListener("change", () => { r.op = opCtl.value; if (NO_VALUE.has(r.op)) delete r.value; draw(); changed(); });
      return el("div", { class: "cond-line" }, fieldCtl, opCtl, valueBox(r, f),
        editable ? el("button", { type: "button", class: "quiet small", "aria-label": "Acrescentar linha abaixo", title: "Acrescentar linha (E)",
          onclick: () => { list.splice(i + 1, 0, { field: "", op: "" }); draw(); focusLine(list, i + 1); } }, "+") : null,
        editable ? el("button", { type: "button", class: "quiet small", "aria-label": "Remover a linha", title: "Remover a linha",
          onclick: () => { list.splice(i, 1); draw(); changed(); } }, "−") : null);
    }
    function focusLine(list, i) {
      const target = list === n.except ? node.querySelector(".cond-except") : node.querySelector(".cond-criterion");
      const ln = target && target.querySelectorAll(".cond-line")[i];
      if (ln) ln.querySelector("select,input").focus();
    }

    function draw() {
      if (tab >= n.any.length) tab = n.any.length - 1;
      const tabs = el("div", { class: "cond-tabs-row" },
        el("div", { class: "sub-tabs cond-tabs" },
          n.any.map((_, i) => el("button", { type: "button", class: i === tab ? "active" : "", text: `Critério ${i + 1}`, onclick: () => { tab = i; draw(); } }))),
        editable ? el("button", { type: "button", class: "quiet small cond-add", text: "+ critério (OU)", title: "Outro conjunto de linhas: basta um critério valer",
          onclick: () => { n.any.push([{ field: "", op: "" }]); tab = n.any.length - 1; draw(); changed(); } }) : null);
      const crit = n.any[tab];
      const critBox = el("div", { class: "cond-criterion" },
        el("p", { class: "muted small", text: "Todas as linhas deste critério valem juntas (E)." }),
        crit.map((r, i) => line(r, crit, i)),
        editable ? el("div", { class: "row-buttons" },
          el("button", { type: "button", class: "quiet small", text: "+ linha", onclick: () => { crit.push({ field: "", op: "" }); draw(); focusLine(crit, crit.length - 1); } }),
          n.any.length > 1 ? el("button", { type: "button", class: "quiet small danger", text: "Remover este critério",
            onclick: () => { n.any.splice(tab, 1); draw(); changed(); } }) : null) : null);
      const exBox = el("div", { class: "cond-except" },
        el("strong", { text: "Exceto…" }), el("span", { class: "muted small", text: " basta uma destas linhas valer para ficar de fora" }),
        n.except.map((r, i) => line(r, n.except, i)),
        editable ? el("button", { type: "button", class: "quiet small", text: "+ exceção", onclick: () => { n.except.push({ field: "", op: "" }); draw(); focusLine(n.except, n.except.length - 1); } }) : null);
      const names = el("datalist", { id: id + "-fields" }, fields.map((x) => el("option", { value: x.name, label: x.label })));
      node.replaceChildren(tabs, critBox, exBox, preview, names);
      preview.textContent = "Regra: " + describe(n, fields);
    }
    draw();
    return {
      node,
      get: () => compact(n),
      set: (c) => { n = normalize(c); starter(); tab = 0; draw(); },
      text: () => describe(n, fields),
    };
  }

  window.AnaConditions = { builder, describe, normalize, compact, OPS };
})();
