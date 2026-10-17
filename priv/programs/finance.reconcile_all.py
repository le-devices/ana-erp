# ana:description Concilia todas as contas bancárias ativas e compensa créditos (rotina diária)
# ana:exposed yes
# ana:role admin
"""Spec 038 (RF-038-06, phase 4). Runs finance.reconcile for every active bank account (each in its own
savepoint: one failing account never stops the others), then own transfers between accounts and the
offset of credits. What is not certain stays in the workbench, with its suggestions."""

PARAMS = {}


def main():
    accounts = [r["code"] for r in ana.sql("SELECT code FROM finance.bank_account WHERE active ORDER BY code")]
    done, failed = [], []
    for code in accounts:
        try:
            with ana.savepoint():
                r = ana.call("finance.reconcile", bank_account=code) or {}
            rules = r.get("rules") or 0
            done.append({"conta": code, "baixadas": r.get("settled", 0), "vinculadas": r.get("linked", 0),
                         "repasses": r.get("payouts", 0), "transferências": r.get("transfers", 0),
                         "por regra": sum(rules.values()) if isinstance(rules, dict) else rules,
                         "pendentes": len(r.get("suggestions") or {})})
        except ana.Error as e:
            failed.append({"conta": code, "erro": e.code, "mensagem": e.message})
    offsets = ana.call("finance.offset_credits") or {}
    if done:
        ana.table(done, title="Contas conciliadas")
    if failed:
        ana.table(failed, title="Contas com erro")
    return {"accounts": done, "failed": failed, "offsets": offsets.get("offsets", 0)}
