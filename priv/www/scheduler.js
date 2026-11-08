// Scheduler UI (spec 018): job list, job form, occurrences and preview. Used in
// the program's "Agendamentos" tab and in Administração → Agendamento.
"use strict";
(function () {
  const API = window.AnaApi;
  const { el, fmtDate, errorText, toast, table, pill } = window.AnaUI;

  const STATUS = { success: ["sucesso", "ok"], error: ["erro", "off"], skipped: ["pulada", ""],
                   pending: ["pendente", "warn"], running: ["executando", "warn"], cancelled: ["cancelada", ""] };
  const statusPill = (s) => (s ? pill((STATUS[s] || [s])[0], (STATUS[s] || [])[1] || "") : "—");

  function describeTrigger(t) {
    switch (t.kind) {
      case "cron": return `cron "${t.cron}"${t.business_days_only ? " · só dias úteis" : ""}`;
      case "interval": return `a cada ${t.interval_s} s`;
      case "once": return `uma vez em ${fmtDate(t.fire_at)}`;
      case "calendar": return t.rule === "last_business_day" ? `último dia útil às ${t.at_time.slice(0, 5)}`
                                                              : `${t.nth}º dia útil às ${t.at_time.slice(0, 5)}`;
      case "after_job": return `após "${t.after_job}" (${{ success: "sucesso", failure: "falha", always: "sempre" }[t.after_condition]})`;
      default: return t.kind;
    }
  }

  /** Renders the job list (optionally of one program) with a side form. */
  async function render(container, options = {}) {
    const jobs = await API.scheduler.jobs(options.program);
    const side = el("div");
    const showJob = async (j) => side.replaceChildren(await jobDetail(j.id, () => render(container, options)));
    const showForm = (job) => side.replaceChildren(jobForm(job, options, () => render(container, options)));
    container.replaceChildren(
      el("div", { class: "admin-toolbar" },
        el("button", { class: "primary", text: "+ Nova rotina agendada", onclick: () => showForm(null) }),
        options.program ? el("span", { class: "muted", text: `Rotinas que executam ${options.program}.` }) : null),
      el("div", { class: "admin-columns" },
        el("div", {}, table([
          { label: "Rotina", value: (j) => el("div", {}, el("strong", { text: j.name }), el("div", { class: "muted", text: j.description || "" })) },
          options.program ? null : { label: "Programa", value: (j) => j.program },
          { label: "Situação", value: (j) => j.active ? pill("ativa", "ok") : pill("pausada", "off") },
          { label: "Próxima", value: (j) => fmtDate(j.next_at) || "—" },
          { label: "Última", value: (j) => el("span", {}, statusPill(j.last_status), " ", fmtDate(j.last_run)) },
          { label: "Avisos", value: (j) => (j.unread ? pill(String(j.unread), "warn") : ""), class: "num" },
        ].filter(Boolean), jobs, { onRow: showJob, empty: "Nenhuma rotina agendada." })),
        side));
    if (!jobs.length) showForm(null);
  }

  async function jobDetail(id, refresh) {
    const [job, occ, preview] = await Promise.all([API.scheduler.job(id), API.scheduler.occurrences(id),
                                                   API.scheduler.preview(id).catch(() => [])]);
    const act = (label, fn, cls = "") => el("button", { class: cls, text: label, onclick: async () => {
      try { await fn(); toast("Feito."); refresh(); } catch (e) { toast(errorText(e), true); }
    } });
    return el("div", { class: "form-card" },
      el("h3", { text: job.name }),
      el("div", { class: "muted", text: `${job.program} · executa como ${job.run_as} · fuso ${job.timezone}` }),
      el("div", {}, job.triggers.map((t) => el("div", { text: "• " + describeTrigger(t) }))),
      el("div", { class: "row-buttons" },
        act("Executar agora", () => API.scheduler.run(id)),
        job.active ? act("Pausar", () => API.scheduler.pause(id)) : act("Retomar", () => API.scheduler.resume(id)),
        act("Pular a próxima", () => API.scheduler.skipNext(id)),
        el("button", { text: "Editar", onclick: (e) => e.currentTarget.closest(".form-card").replaceWith(jobForm(job, {}, refresh)) }),
        act("Excluir", async () => {
          if (!confirm(`Excluir a rotina ${job.name}? O histórico também será removido.`)) throw new Error("cancelado");
          await API.scheduler.remove(id);
        }, "danger")),
      el("div", {}, el("div", { class: "muted", text: "Próximas execuções" }),
        preview.length ? el("div", { class: "chips" }, preview.slice(0, 6).map((p) => pill(fmtDate(p)))) : el("span", { class: "muted", text: "—" })),
      el("div", {}, el("div", { class: "muted", text: "Histórico" }), table([
        { label: "Prevista", value: (o) => fmtDate(o.scheduled_at) },
        { label: "Tent.", value: (o) => o.attempt, class: "num" },
        { label: "Status", value: (o) => statusPill(o.status) },
        { label: "ms", value: (o) => o.duration_ms ?? "", class: "num" },
        { label: "Obs.", value: (o) => (o.error && o.error.code) || o.reason || "" },
      ], occ.slice(0, 20), { empty: "Ainda não executou." })));
  }

  function jobForm(job, options, refresh) {
    const isNew = !job;
    const v = job || {};
    const t0 = (v.triggers && v.triggers[0]) || { kind: "cron", cron: "0 6 * * mon-fri" };
    const name = el("input", { value: v.name || "", placeholder: "ex.: importar-extratos" });
    const description = el("input", { value: v.description || "" });
    const program = el("input", { value: v.program || options.program || "", placeholder: "ex.: finance.trial_balance" });
    const params = el("textarea", { rows: 3, spellcheck: "false" });
    params.value = JSON.stringify(v.params || {}, null, 1);
    const runAs = el("input", { value: v.run_as || window.AnaStudio.user().username });
    const kind = el("select", {}, [["cron", "expressão cron"], ["interval", "intervalo fixo"], ["once", "uma única vez"],
      ["calendar", "calendário de dias úteis"], ["after_job", "após outra rotina"]].map(([k, l]) => el("option", { value: k, text: l })));
    kind.value = t0.kind;
    const cron = el("input", { value: t0.cron || "0 6 * * mon-fri", placeholder: "min hora dia mês dia-semana" });
    const businessOnly = el("input", { type: "checkbox", checked: t0.business_days_only });
    const interval = el("input", { type: "number", min: 1, value: t0.interval_s || 3600 });
    const fireAt = el("input", { type: "datetime-local" });
    const rule = el("select", {}, el("option", { value: "last_business_day", text: "último dia útil do mês" }),
                                  el("option", { value: "nth_business_day", text: "n-ésimo dia útil do mês" }));
    rule.value = t0.rule || "last_business_day";
    const nth = el("input", { type: "number", min: 1, max: 23, value: t0.nth || 1 });
    const atTime = el("input", { type: "time", value: (t0.at_time || "18:00").slice(0, 5) });
    const afterJob = el("input", { value: t0.after_job || "", placeholder: "nome da rotina de origem" });
    const afterCond = el("select", {}, [["success", "sucesso"], ["failure", "falha"], ["always", "sempre"]].map(([k, l]) => el("option", { value: k, text: l })));
    afterCond.value = t0.after_condition || "success";
    const resultParam = el("input", { value: t0.result_param || "", placeholder: "parâmetro que recebe o resultado (opcional)" });
    const concurrency = el("select", {}, [["skip", "pular se ainda estiver rodando"], ["queue", "enfileirar uma"], ["parallel", "em paralelo"]].map(([k, l]) => el("option", { value: k, text: l })));
    concurrency.value = v.concurrency || "skip";
    const missed = el("select", {}, [["run_once", "executar uma vez ao voltar"], ["run_all", "executar todas (limite)"], ["skip", "ignorar"]].map(([k, l]) => el("option", { value: k, text: l })));
    missed.value = v.missed || "run_once";
    const retries = el("input", { type: "number", min: 0, max: 20, value: v.retries ?? 0 });
    const backoff = el("input", { type: "number", min: 1, value: v.retry_backoff_s ?? 60 });
    const exhausted = el("select", {}, el("option", { value: "notify", text: "só avisar" }), el("option", { value: "pause", text: "avisar e pausar" }));
    exhausted.value = v.on_exhausted || "notify";
    const winStart = el("input", { type: "time", value: (v.window_start || "").slice(0, 5) });
    const winEnd = el("input", { type: "time", value: (v.window_end || "").slice(0, 5) });
    const active = el("input", { type: "checkbox", checked: v.active !== false });

    const groups = {
      cron: el("div", {}, el("label", {}, "Expressão cron", cron), el("label", { class: "check" }, businessOnly, "só em dias úteis (feriados cadastrados)")),
      interval: el("label", {}, "Intervalo (segundos)", interval),
      once: el("label", {}, "Data e hora", fireAt),
      calendar: el("div", {}, el("label", {}, "Regra", rule), el("label", {}, "N (n-ésimo)", nth), el("label", {}, "Horário", atTime)),
      after_job: el("div", {}, el("label", {}, "Rotina de origem", afterJob), el("label", {}, "Condição", afterCond), el("label", {}, "Passar resultado em", resultParam)),
    };
    const showKind = () => { for (const [k, g] of Object.entries(groups)) g.hidden = k !== kind.value; };
    kind.addEventListener("change", showKind);
    showKind();

    const save = async (e) => {
      e.preventDefault();
      let p;
      try { p = JSON.parse(params.value || "{}"); } catch (_) { toast("Parâmetros: JSON inválido.", true); return; }
      const trigger = { kind: kind.value };
      if (kind.value === "cron") Object.assign(trigger, { cron: cron.value.trim(), business_days_only: businessOnly.checked });
      if (kind.value === "interval") trigger.interval_s = parseInt(interval.value, 10);
      if (kind.value === "once") trigger.fire_at = fireAt.value ? new Date(fireAt.value).toISOString() : t0.fire_at;
      if (kind.value === "calendar") Object.assign(trigger, { rule: rule.value, nth: parseInt(nth.value, 10), at_time: atTime.value });
      if (kind.value === "after_job") Object.assign(trigger, { after_job: afterJob.value.trim(), after_condition: afterCond.value, result_param: resultParam.value.trim() || null });
      const body = {
        name: name.value.trim(), description: description.value, program: program.value.trim(), params: p,
        run_as: runAs.value.trim(), triggers: [trigger], concurrency: concurrency.value, missed: missed.value,
        retries: parseInt(retries.value, 10), retry_backoff_s: parseInt(backoff.value, 10), on_exhausted: exhausted.value,
        window_start: winStart.value || null, window_end: winEnd.value || null, active: active.checked,
      };
      try {
        if (isNew) await API.scheduler.create(body); else await API.scheduler.update(v.id, body);
        toast("Rotina salva.");
        refresh();
      } catch (err) { toast(errorText(err), true); }
    };

    return el("form", { class: "form-card", onsubmit: save },
      el("h3", { text: isNew ? "Nova rotina agendada" : `Editar ${v.name}` }),
      el("label", {}, "Nome", name), el("label", {}, "Descrição", description),
      el("label", {}, "Programa", program),
      el("label", {}, "Parâmetros (JSON; aceita {{today}}, {{yesterday}}, {{month_start}}, {{last_month_start}}, {{last_month_end}})", params),
      el("label", {}, "Executar como (usuário técnico)", runAs),
      el("label", {}, "Quando", kind), ...Object.values(groups),
      el("details", {}, el("summary", { text: "Execução e falhas" }),
        el("label", {}, "Se a anterior ainda estiver rodando", concurrency),
        el("label", {}, "Execuções perdidas (sistema fora do ar)", missed),
        el("div", { class: "row-buttons" }, el("label", {}, "Novas tentativas", retries), el("label", {}, "Espera inicial (s)", backoff)),
        el("label", {}, "Ao esgotar as tentativas", exhausted),
        el("div", { class: "row-buttons" }, el("label", {}, "Janela: início", winStart), el("label", {}, "fim", winEnd))),
      el("label", { class: "check" }, active, "Ativa"),
      el("div", { class: "row-buttons" }, el("button", { class: "primary", type: "submit", text: "Salvar" })));
  }

  async function holidays(container) {
    const list = await API.scheduler.holidays();
    const day = el("input", { type: "date", "aria-label": "Dia do feriado", required: true });
    const desc = el("input", { placeholder: "descrição", "aria-label": "Descrição do feriado" });
    container.replaceChildren(
      el("form", { class: "inline-form", onsubmit: async (e) => {
        e.preventDefault();
        try { await API.scheduler.saveHoliday(day.value, desc.value); holidays(container); } catch (err) { toast(errorText(err), true); }
      } }, day, desc, el("button", { type: "submit", text: "Adicionar feriado" })),
      table([
        { label: "Dia", value: (h) => h.day },
        { label: "Descrição", value: (h) => h.description },
        { label: "", value: (h) => el("div", { class: "cell-actions" }, el("button", { class: "danger small", text: "Remover", onclick: async () => {
            await API.scheduler.deleteHoliday(h.day); holidays(container);
          } })) },
      ], list, { empty: "Nenhum feriado cadastrado (dias úteis = segunda a sexta).",
                 emptyAction: { label: "Cadastrar o primeiro feriado", onClick: () => day.focus() } }));
  }

  async function notifications(container, unreadOnly) {
    const list = await API.scheduler.notifications(unreadOnly).catch(() => []);
    const kinds = { failure: ["falha", "off"], late: ["atraso", "warn"], anomaly: ["duração anômala", "warn"], paused: ["pausada", "off"] };
    container.replaceChildren(list.length ? table([
      { label: "Quando", value: (n) => fmtDate(n.created_at) },
      { label: "Tipo", value: (n) => pill((kinds[n.kind] || [n.kind])[0], (kinds[n.kind] || [])[1] || "") },
      { label: "Aviso", value: (n) => n.message },
      { label: "", value: (n) => n.read ? "" : el("button", { class: "small", text: "Marcar como lido", onclick: async () => {
          await API.scheduler.markRead(n.id); notifications(container, unreadOnly);
        } }) },
    ], list) : el("p", { class: "muted", text: unreadOnly ? "Nenhum aviso pendente." : "Nenhum aviso." }));
    return list.length;
  }

  window.AnaScheduler = { render, holidays, notifications };
})();
