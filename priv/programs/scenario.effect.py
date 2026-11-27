# ana:description Cenários: o que mudou em relação à base e o caminho de cada efeito até o choque que o causou
# ana:kind library
"""Spec 069 (T-069-04, RF-069-03, D3; plan §3). The scenario is the base built again from shocked sources, so every
event of one has its twin in the other: same kind, document, item and party (and order of appearance). What changed
is what differs in date or amount, or exists only on one side.

The path of an effect walks the events it waits for (`after`) while they changed too, down to the seed — the first
changed event whose parents did not change — and names the shock behind the seed: the one whose projection alone
also changes that seed. "caixa −R$ 82 mil ← faturamento do pedido 1.204 adiado 12 dias ← OP 88 atrasada ← OC-51
atrasada 10 dias ← fornecedor X entrega 10 dias depois"."""

from decimal import Decimal

ZERO = Decimal(0)
TOP = 15
NAMES = {"cash_in": "recebimento", "cash_out": "pagamento", "receipt": "chegada da compra", "make": "produção",
         "delivery": "entrega", "invoice": "faturamento", "bank_balance": "saldo"}


def keyed(g):
    """{key: event} — the key is stable between base and scenario."""
    seen, out = {}, {}
    for e in g.events:
        k = (e["kind"], e["doc"], e.get("item"), e.get("party"))
        n = seen.get(k, 0)
        seen[k] = n + 1
        out[k + (n,)] = e
    return out


def changes(base, scen):
    """{key: (base event or None, scenario event or None)} for what differs."""
    b, s = keyed(base), keyed(scen)
    out = {}
    for k in b.keys() | s.keys():
        x, y = b.get(k), s.get(k)
        if x is None or y is None or x["date"] != y["date"] or x["amount"] != y["amount"] or x.get("cost") != y.get("cost"):
            out[k] = (x, y)
    return out


def describe(x, y):
    """One link of the path, in words."""
    e = y or x
    what = "impostos" if e.get("tax") else NAMES.get(e["kind"], e["kind"])
    head = f"{what} {e['doc']}" if not e.get("tax") else f"{e['doc']}"
    if y is None:
        return f"{head} não acontece"
    if x is None:
        return f"{head} passa a existir ({y['date']:%d/%m/%Y})"
    parts = []
    days = (y["date"] - x["date"]).days
    if days:
        parts.append(f"{'adiado' if days > 0 else 'antecipado'} {abs(days)} dias")
    if y["amount"] != x["amount"]:
        parts.append(f"{'+' if y['amount'] > x['amount'] else '−'}R$ {abs(y['amount'] - x['amount']):,.2f}")
    if x.get("cost") is not None and y.get("cost") != x.get("cost"):
        parts.append(f"custo {'+' if y['cost'] > x['cost'] else '−'}R$ {abs(y['cost'] - x['cost']):,.2f}")
    return f"{head} {', '.join(parts)}"


def explain(base, scen, shocks, singles=None, top=TOP, cash=True):
    """The effects that weigh most on cash and margin, each with its path to the shock(s).
    `singles`: {index of shock: its projection alone} — to name the shock of a seed when there are several.
    Without `cash` (who may not see the company's cash, plan §7), only the effects on invoicing and margin."""
    shown = ("cash_in", "cash_out", "invoice") if cash else ("invoice",)
    ch = changes(base, scen)
    by_id = {e["id"]: k for k, e in keyed(scen).items()}
    single_ch = {i: changes(base, g) for i, g in (singles or {}).items()}

    def seed_shocks(k):
        if len(shocks) == 1:
            return [shocks[0]["label"]]
        return [shocks[i]["label"] for i, c in sorted(single_ch.items()) if k in c] or [s["label"] for s in shocks]

    def path(k, depth=0):
        x, y = ch[k]
        links = [describe(x, y)]
        e = y or x
        parents = [by_id.get(pid) for pid, _slack in (e.get("after") or [])] if y is not None else []
        moved = [p for p in parents if p in ch]
        if moved and depth < 20:
            # The parent that moved the most is the reason (the latest one decides the date).
            p = max(moved, key=lambda pk: ((ch[pk][1] or ch[pk][0])["date"], str(pk)))
            sub, cause = path(p, depth + 1)
            return links + sub, cause
        return links, seed_shocks(k)

    def weight(k):
        x, y = ch[k]
        if (y or x)["kind"] in ("cash_in", "cash_out"):
            amount = abs((y["amount"] if y else ZERO) - (x["amount"] if x else ZERO))
            shift = abs(((y["date"] - x["date"]).days if x and y else 0))
            return amount + abs((y or x)["amount"]) * min(shift, 365) / 365
        if (y or x)["kind"] == "invoice":
            return abs((y.get("cost") if y else ZERO) - (x.get("cost") if x else ZERO)) + \
                abs(((y["date"] - x["date"]).days if x and y else 0)) * abs((y or x)["amount"]) / 365
        return Decimal(-1)

    effects = []
    for k in sorted((k for k in ch if (ch[k][1] or ch[k][0])["kind"] in shown),
                    key=lambda k: (-weight(k), str(k)))[:top]:
        links, cause = path(k)
        # The event may also change by itself (a cost, an amount): the shocks that change it alone join the cause.
        cause += [c for c in (seed_shocks(k) if singles else []) if c not in cause]
        x, y = ch[k]
        effects.append({"doc": (y or x)["doc"], "kind": (y or x)["kind"], "path": links, "shocks": cause,
                        "text": " ← ".join(links + [" + ".join(cause)]),
                        "base_date": x["date"] if x else None, "date": y["date"] if y else None,
                        "change": (y["amount"] if y else ZERO) - (x["amount"] if x else ZERO)})
    return {"changed": len(ch), "effects": effects}
