// Live screens (spec 062, D3): one event stream per signed-in screen; "something changed" events make
// the bell and "Minhas tarefas" read again. Reconnects by itself; never blocks the screen.
(function () {
  "use strict";
  let running = false, timer = null;
  const later = (fn, ms) => { clearTimeout(timer); timer = setTimeout(fn, ms); };
  function changed() {
    later(() => {
      if (window.AnaStudio && window.AnaStudio.refreshNotices) window.AnaStudio.refreshNotices();
      const box = document.querySelector("#home-tasks");
      if (box && !document.querySelector("#area-home").hidden && window.AnaBpm) window.AnaBpm.homeWidget(box);
    }, 300);
  }
  async function connect(delay = 2000) {
    if (!running || !window.AnaApi || !window.AnaApi.authenticated) { running = false; return; }
    try {
      const resp = await window.AnaApi.stream("/api/events");
      if (!resp.ok || !resp.body) throw new Error(String(resp.status));
      const reader = resp.body.getReader(), dec = new TextDecoder();
      let buf = "";
      delay = 2000;
      for (;;) {
        const { value, done } = await reader.read();
        if (done) break;
        buf += dec.decode(value, { stream: true });
        let i;
        while ((i = buf.indexOf("\n\n")) >= 0) {
          const block = buf.slice(0, i); buf = buf.slice(i + 2);
          if (/^event: (notices|tasks)$/m.test(block)) changed();
        }
      }
    } catch (_) { /* reconnect below */ }
    setTimeout(() => connect(Math.min(delay * 2, 30000)), delay);
  }
  window.AnaLive = { start() { if (!running) { running = true; connect(); } } };
})();
