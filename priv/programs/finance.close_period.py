# ana:description Fechamento contábil: fecha os lançamentos até uma data (ou reabre), com histórico
# ana:exposed yes
# ana:role admin
# ana:command fechamento
# ana:category Contabilidade/Lançamentos e fechamento
"""Spec 038 (RF-038-09, CA-038-11). After closing, the database refuses any entry dated on or before
the closed date, from any program. Reopening asks for a reason; every change stays in
finance.period_close (who, when, why). Without parameters: shows the situation and the history."""

import datetime

from ana_lib.util import validation as v

PARAMS = {
    "action": {"type": "str", "label": "ação", "choices": [["close", "Fechar até a data"], ["reopen", "Reabrir até a data"]]},
    "until": {"type": "date", "label": "data (vazio ao fechar = último dia do mês anterior)"},
    "reason": {"type": "str", "label": "motivo (obrigatório para reabrir)"},
}


def main(action=None, until=None, reason=None):
    current = ana.sql_value("SELECT finance.closed_until()")
    if action:
        v.require(action in ("close", "reopen"), "INVALID_PARAMETER", "ação deve ser fechar ou reabrir")
        if until is None and action == "close":
            until = datetime.date.today().replace(day=1) - datetime.timedelta(days=1)
        v.require(until is not None, "INVALID_PARAMETER", "informe a data")
        if action == "close":
            if current is not None and until <= current:
                raise ana.Error("INVALID_PARAMETER", f"já está fechado até {current:%d/%m/%Y}; para voltar, use reabrir")
            v.require(until < datetime.date.today(), "INVALID_PARAMETER", "só se fecha um período que já terminou")
        else:
            v.require(current is not None and until < current, "INVALID_PARAMETER", "a data deve ser anterior à data fechada atual")
            v.require(len((reason or "").strip()) >= 5, "INVALID_PARAMETER", "diga por que reabrir (fica no histórico)")
        ana.sql_exec("INSERT INTO finance.period_close (closed_until, action, reason, done_by) VALUES ($1, $2, $3, $4)",
                     until, action, (reason or "").strip() or None, ana.context.user)
        current = until
        # Spec 065 (CA-065-02): the open period follows the closing; variants and schedules that read it move with it.
        ana.set_value("financeiro.periodo_aberto", f"{current + datetime.timedelta(days=1):%Y-%m}",
                      reason=("fechamento" if action == "close" else "reabertura") + f" até {current:%d/%m/%Y}")
    hist = ana.sql("SELECT closed_until, action, reason, done_by, done_at FROM finance.period_close ORDER BY id DESC LIMIT 50")
    ana.metrics([{"label": "Fechado até", "value": f"{current:%d/%m/%Y}" if current else "nada fechado",
                  "status": "ok" if current else "warn"}])
    ana.table([{"até": h["closed_until"], "ação": "fechou" if h["action"] == "close" else "reabriu", "motivo": h["reason"] or "",
                "por": h["done_by"], "quando": h["done_at"]} for h in hist], title="Histórico do fechamento")
    if not action:
        ana.actions([{"label": "Conferir conciliações antes de fechar", "program": "finance.reconciliations", "open": True},
                     {"label": "Fechar o mês anterior", "program": "finance.close_period", "params": {"action": "close"}, "style": "primary",
                      "confirm": "Fechar os lançamentos até o último dia do mês anterior?"}], title="Próximo passo")
    return {"closed_until": current}
