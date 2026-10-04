// Studio code editor (RF-005-02): transparent textarea over a highlighted
// <pre>, gutter with line numbers and breakpoints, bands for the paused line
// and the error line.
"use strict";
(function () {
  const LINE_HEIGHT = 20; // must match --lh in the CSS
  const INDENT = "    ";

  class Editor {
    constructor(root) {
      this.root = root;
      this.breakpoints = new Set();
      this.currentLine = null;
      this.errorLine = null;
      this.onChange = () => {};
      this.onBreakpointsChange = () => {};

      this.gutter = el("div", "gutter");
      this.gutterContent = el("div", "gutter-content");
      this.gutter.appendChild(this.gutterContent);
      this.area = el("div", "area");
      this.currentBand = el("div", "band current"); this.currentBand.hidden = true;
      this.errorBand = el("div", "band error"); this.errorBand.hidden = true;
      this.pre = el("pre", "highlight");
      this.pre.setAttribute("aria-hidden", "true");
      this.textarea = document.createElement("textarea");
      this.textarea.spellcheck = false;
      this.textarea.setAttribute("autocapitalize", "off");
      this.textarea.setAttribute("autocomplete", "off");
      this.textarea.setAttribute("aria-label", "Código-fonte");
      this.textarea.wrap = "off";
      this.area.append(this.errorBand, this.currentBand, this.pre, this.textarea);
      root.append(this.gutter, this.area);

      this._scheduled = false;
      this.textarea.addEventListener("input", () => { this._schedule(); this.onChange(); });
      this.textarea.addEventListener("scroll", () => this._scroll());
      this.textarea.addEventListener("keydown", (e) => this._key(e));
      this.gutter.addEventListener("click", (e) => {
        const n = e.target.closest(".num");
        if (n) this.toggleBreakpoint(Number(n.dataset.line));
      });
      this._render();
    }

    get value() { return this.textarea.value; }
    set value(v) {
      this.textarea.value = v;
      this.textarea.scrollTop = 0;
      this.textarea.setSelectionRange(0, 0);
      this.markError(null);
      this._render();
    }
    set readOnly(v) { this.textarea.readOnly = !!v; }
    focus() { this.textarea.focus(); }

    cursorLine() {
      return this.textarea.value.slice(0, this.textarea.selectionStart).split("\n").length;
    }

    toggleBreakpoint(line) {
      if (this.breakpoints.has(line)) this.breakpoints.delete(line); else this.breakpoints.add(line);
      this._renderGutter();
      this.onBreakpointsChange([...this.breakpoints].sort((a, b) => a - b));
    }

    setBreakpoints(lines) { this.breakpoints = new Set(lines); this._renderGutter(); }

    markCurrent(line) {
      this.currentLine = line;
      this._placeBands();
      this._renderGutter();
      if (line) this._reveal(line);
    }

    markError(line) {
      this.errorLine = line;
      this._placeBands();
      if (line) this._reveal(line);
    }

    _reveal(line) {
      const y = (line - 1) * LINE_HEIGHT;
      const t = this.textarea;
      if (y < t.scrollTop || y > t.scrollTop + t.clientHeight - LINE_HEIGHT * 2) {
        t.scrollTop = Math.max(0, y - t.clientHeight / 3);
      }
    }

    _schedule() {
      if (this._scheduled) return;
      this._scheduled = true;
      requestAnimationFrame(() => { this._scheduled = false; this._render(); });
    }

    _render() {
      // Content escaped by the highlighter: safe for innerHTML.
      this.pre.innerHTML = window.AnaHighlight.highlight(this.textarea.value);
      this._renderGutter();
      this._scroll();
    }

    _renderGutter() {
      const total = this.textarea.value.split("\n").length;
      const frag = document.createDocumentFragment();
      for (let i = 1; i <= total; i++) {
        const d = el("div", "num");
        if (this.breakpoints.has(i)) d.classList.add("bp");
        if (this.currentLine === i) d.classList.add("current");
        d.dataset.line = i;
        d.textContent = i;
        frag.appendChild(d);
      }
      this.gutterContent.replaceChildren(frag);
    }

    _placeBands() {
      const top = this.textarea.scrollTop;
      for (const [band, line] of [[this.currentBand, this.currentLine], [this.errorBand, this.errorLine]]) {
        band.hidden = !line;
        if (line) band.style.transform = `translateY(${6 + (line - 1) * LINE_HEIGHT - top}px)`;
      }
    }

    _scroll() {
      const { scrollTop, scrollLeft } = this.textarea;
      this.pre.style.transform = `translate(${-scrollLeft}px, ${-scrollTop}px)`;
      this.gutterContent.style.transform = `translateY(${-scrollTop}px)`;
      this._placeBands();
    }

    // Insertion that keeps the browser undo history.
    _insert(text) {
      if (!document.execCommand("insertText", false, text)) {
        this.textarea.setRangeText(text, this.textarea.selectionStart, this.textarea.selectionEnd, "end");
        this._schedule(); this.onChange();
      }
    }

    _key(e) {
      const t = this.textarea;
      if (t.readOnly) return;
      if (e.key === "Tab") {
        e.preventDefault();
        const start = t.selectionStart, end = t.selectionEnd, v = t.value;
        const lineStart = v.lastIndexOf("\n", start - 1) + 1;
        if (start === end && !e.shiftKey) { this._insert(INDENT); return; }
        // Indent/dedent the selected block.
        const blockEnd = end > start && v[end - 1] === "\n" ? end - 1 : end;
        const block = v.slice(lineStart, blockEnd);
        const updated = e.shiftKey
          ? block.replace(/^ {1,4}/gm, "")
          : block.replace(/^/gm, INDENT);
        t.setSelectionRange(lineStart, blockEnd);
        this._insert(updated);
        t.setSelectionRange(lineStart, lineStart + updated.length);
      } else if (e.key === "Enter" && !e.ctrlKey && !e.metaKey) {
        e.preventDefault();
        const v = t.value, start = t.selectionStart;
        const lineText = v.slice(v.lastIndexOf("\n", start - 1) + 1, start);
        let indent = (lineText.match(/^\s*/) || [""])[0];
        if (/:\s*(#.*)?$/.test(lineText)) indent += INDENT;
        this._insert("\n" + indent);
      } else if (e.key === "Backspace" && t.selectionStart === t.selectionEnd) {
        const v = t.value, start = t.selectionStart;
        const lineText = v.slice(v.lastIndexOf("\n", start - 1) + 1, start);
        if (lineText.length > 0 && /^ +$/.test(lineText) && lineText.length % 4 === 0) {
          e.preventDefault();
          t.setSelectionRange(start - 4, start);
          this._insert("");
        }
      }
    }
  }

  function el(tag, classe) {
    const e = document.createElement(tag);
    if (classe) e.className = classe;
    return e;
  }

  window.AnaEditor = Editor;
})();
