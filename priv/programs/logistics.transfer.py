# ana:description Transferência entre depósitos com trânsito: criar, despachar e receber
# ana:exposed yes
# ana:command transferir
"""RF-015-01, CA-015-01. ship: origin → TRANSITO; receive: TRANSITO → destination, with the
received quantities (divergence = shipped − received, recorded; the difference stays in
transit until an adjustment)."""

from decimal import Decimal

from ana_lib.logistics import common

PARAMS = {
    "action": {"type": "str", "default": "ship", "label": "ação",
               "choices": [["create", "Criar (rascunho)"], ["ship", "Criar e despachar"], ["dispatch", "Despachar rascunho"],
                           ["receive", "Receber"]]},
    "number": {"type": "int", "label": "transferência (despachar/receber)", "lookup": {"program": "logistics.lookup", "params": {"kind": "transfers"}}},
    "from_wh": {"type": "str", "label": "depósito de origem", "lookup": {"program": "logistics.lookup", "params": {"kind": "warehouses"}}},
    "to_wh": {"type": "str", "label": "depósito de destino", "lookup": {"program": "logistics.lookup", "params": {"kind": "warehouses"}}},
    "items": {"type": "list", "label": "itens", "add_label": "Adicionar item", "columns": {
        "product": {"type": "str", "required": True, "label": "item",
                    "lookup": {"program": "sales.lookup", "params": {"kind": "products"}, "depends": ["from_wh"]}},
        "quantity": {"type": "decimal", "required": True, "default": 1, "label": "quantidade"}}},
    "received": {"type": "list", "label": "recebido (vazio = tudo)", "columns": {
        "line": {"type": "int", "required": True, "label": "linha"},
        "quantity": {"type": "decimal", "required": True, "label": "quantidade recebida"},
        "note": {"type": "str", "label": "observação (ex.: 1 avariada)"}}},
    "notes": {"type": "str", "label": "observação"},
}


def main(action="ship", number=None, from_wh=None, to_wh=None, items=None, received=None, notes=None):
    transit = common.warehouse("TRANSITO")
    if action in ("create", "ship"):
        src, dst = common.warehouse(from_wh or ""), common.warehouse(to_wh or "")
        if src["id"] == dst["id"] or transit["id"] in (src["id"], dst["id"]):
            raise ana.Error("INVALID_WAREHOUSE", "origem e destino devem ser depósitos diferentes (e não o de trânsito)")
        if not items:
            raise ana.Error("INVALID_ITEMS", "informe os itens")
        prods = common.products(i.get("product", "") for i in items)
        t = ana.sql_one("INSERT INTO logistics.transfer (from_wh, to_wh, notes, created_by) VALUES ($1, $2, $3, $4) RETURNING id, number",
                        src["id"], dst["id"], notes or "", ana.context.user)
        ana.sql_batch("INSERT INTO logistics.transfer_line (transfer_id, line, product_id, quantity) VALUES ($1, $2, $3, $4)",
                      [[t["id"], n, prods[str(i["product"]).strip().upper()]["id"], i["quantity"]] for n, i in enumerate(items, 1)])
        number = t["number"]
        if action == "create":
            return {"number": number, "status": "draft"}
    t = ana.sql_one("SELECT id, number, from_wh, to_wh, status FROM logistics.transfer WHERE number = $1 FOR UPDATE", number)
    if not t:
        raise ana.Error("TRANSFER_NOT_FOUND", f"transferência {number} não encontrada")
    lines = ana.sql("SELECT line, product_id, quantity FROM logistics.transfer_line WHERE transfer_id = $1 ORDER BY line", t["id"])
    doc = f"TR-{t['number']}"
    if action in ("ship", "dispatch"):
        if t["status"] != "draft":
            raise ana.Error("INVALID_STATE", f"transferência {t['number']} não está em rascunho")
        wanted = {}
        for l in lines:
            wanted[l["product_id"]] = wanted.get(l["product_id"], Decimal(0)) + l["quantity"]
        common.take_stock(t["from_wh"], wanted, doc, "transfer")
        common.put_stock(transit["id"], wanted, doc, "transfer")
        ana.sql_exec("UPDATE logistics.transfer SET status = 'shipped', shipped_at = now() WHERE id = $1", t["id"])
        return {"number": t["number"], "status": "shipped"}
    if action == "receive":
        if t["status"] != "shipped":
            raise ana.Error("INVALID_STATE", f"transferência {t['number']} não foi despachada")
        got = {int(r["line"]): r for r in (received or [])}
        rows, back, divergences = [], {}, []
        for l in lines:
            r = got.get(l["line"], {})
            q = Decimal(str(r.get("quantity", l["quantity"])))
            if q < 0 or q > l["quantity"]:
                raise ana.Error("INVALID_VALUE", f"linha {l['line']}: recebido deve estar entre 0 e {l['quantity']}")
            rows.append([t["id"], l["line"], q, r.get("note") if q != l["quantity"] else None])
            back[l["product_id"]] = back.get(l["product_id"], Decimal(0)) + q
            if q != l["quantity"]:
                divergences.append({"linha": l["line"], "enviado": l["quantity"], "recebido": q, "observação": r.get("note")})
        common.take_stock(transit["id"], {p: q for p, q in back.items() if q > 0}, doc, "transfer")
        common.put_stock(t["to_wh"], back, doc, "transfer")
        ana.sql_exec("UPDATE logistics.transfer_line l SET received_qty = x.q::numeric, divergence = x.note "
                     "FROM unnest($2::int[], $3::text[], $4::text[]) AS x(line, q, note) WHERE l.transfer_id = $1 AND l.line = x.line",
                     t["id"], [r[1] for r in rows], [str(r[2]) for r in rows], [r[3] for r in rows])
        ana.sql_exec("UPDATE logistics.transfer SET status = 'received', received_at = now() WHERE id = $1", t["id"])
        if divergences:
            ana.table(divergences, title="Divergências (a diferença segue no depósito de trânsito)")
        return {"number": t["number"], "status": "received", "divergences": len(divergences)}
    raise ana.Error("INVALID_PARAMETER", f"ação desconhecida: {action}")
