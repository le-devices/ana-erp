# ana:description Política de atendimento dos pedidos: modo padrão, transferir antes, alçada da compra e exceções
# ana:role admin
# ana:category Vendas/Atendimento
"""Spec 041 (RF-041-01, CA-041-05). Without an action shows the policy and its exceptions. "test" with a customer
and an item tells which rule applies and why (the most specific wins: customer + item > item > item group >
customer > policy)."""

from decimal import Decimal

from ana_lib.sales import fulfillment as F

PARAMS = {
    "action": {"type": "str", "label": "ação", "order": 1,
               "choices": [["policy", "Alterar a política"], ["rule", "Incluir ou trocar exceção"], ["remove", "Apagar exceção"],
                           ["test", "Qual regra vale?"]]},
    "mode": {"type": "str", "label": "modo quando falta estoque", "order": 2, "choices": [["refuse", "Só com estoque — recusar"], ["hold", "Só com estoque — reter até chegar"], ["purchase", "Suprir pela compra"], ["produce", "Suprir pela produção"], ["by_item", "Suprir conforme o item (fabricado ou comprado)"], ["accept", "Aceitar sem estoque definido"]]},
    "transfer_first": {"type": "bool", "label": "transferir de outro depósito antes de suprir", "order": 3},
    "auto_order_max": {"type": "decimal", "label": "compra vira ordem sozinha até (R$; 0 = nunca)", "order": 4},
    "allowed_modes": {"type": "list", "label": "modos que quem digita pode escolher", "order": 5},
    "confirm_cancel": {"type": "bool", "label": "mostrar o efeito e confirmar ao cancelar", "order": 6},
    "customer": {"type": "int", "label": "cliente (exceção ou teste)", "order": 7, "lookup": {"program": "sales.lookup", "params": {"kind": "customers"}}},
    "product": {"type": "str", "label": "item (exceção ou teste)", "order": 8, "lookup": {"program": "sales.lookup", "params": {"kind": "products"}}},
    "item_group": {"type": "str", "label": "grupo de itens (exceção)", "order": 9},
    "rule": {"type": "int", "label": "exceção (nº, para apagar)", "order": 10},
    "note": {"type": "str", "label": "observação", "order": 11},
}
CODES = [m for m, _ in F.MODES]


def main(action=None, mode=None, transfer_first=None, auto_order_max=None, allowed_modes=None, confirm_cancel=None,
         customer=None, product=None, item_group=None, rule=None, note=None):
    who = ana.context.user
    if action == "policy":
        if mode is not None and mode not in CODES:
            raise ana.Error("INVALID_PARAMETER", f"modo desconhecido: {mode}")
        bad = [m for m in (allowed_modes or []) if m not in CODES]
        if bad:
            raise ana.Error("INVALID_PARAMETER", f"modos desconhecidos: {', '.join(bad)}")
        if auto_order_max is not None and Decimal(str(auto_order_max)) < 0:
            raise ana.Error("INVALID_PARAMETER", "alçada não pode ser negativa")
        ana.sql_exec("UPDATE sales.fulfillment_policy SET mode = COALESCE($1, mode), transfer_first = COALESCE($2, transfer_first), "
                     "auto_order_max = COALESCE($3, auto_order_max), allowed_modes = COALESCE($4, allowed_modes), "
                     "confirm_cancel = COALESCE($5, confirm_cancel), updated_by = $6, updated_at = now() WHERE id = 1",
                     mode, transfer_first, auto_order_max, allowed_modes, confirm_cancel, who)
    elif action == "rule":
        if mode not in CODES:
            raise ana.Error("INVALID_PARAMETER", "informe o modo da exceção")
        pid = product_id(product)
        grp = (item_group or "").strip().upper() or None
        if not (customer or pid or grp):
            raise ana.Error("INVALID_PARAMETER", "a exceção vale para um cliente, um item ou um grupo de itens")
        if pid and grp:
            raise ana.Error("INVALID_PARAMETER", "a exceção é de um item ou de um grupo, não dos dois")
        ana.sql_exec("INSERT INTO sales.fulfillment_rule (customer_id, product_id, item_group, mode, transfer_first, note, created_by) "
                     "VALUES ($1, $2, $3, $4, $5, COALESCE($6, ''), $7) "
                     "ON CONFLICT (COALESCE(customer_id, 0), COALESCE(product_id, 0), COALESCE(item_group, '')) DO UPDATE SET "
                     "mode = EXCLUDED.mode, transfer_first = EXCLUDED.transfer_first, note = EXCLUDED.note",
                     customer, pid, grp, mode, transfer_first, note, who)
    elif action == "remove":
        if not ana.sql_exec("DELETE FROM sales.fulfillment_rule WHERE id = $1", rule):
            raise ana.Error("NOT_FOUND", f"exceção {rule} não encontrada")
    elif action == "test":
        p = ana.sql_one("SELECT id, code, item_group FROM base.product WHERE code = $1", (product or "").strip().upper())
        if not p or not customer:
            raise ana.Error("INVALID_PARAMETER", "informe o cliente e o item para testar")
        e = F.effective(customer, [p])[p["id"]]
        ana.metrics([{"label": "Vale", "value": F.LABEL[e["mode"]]}, {"label": "Por quê", "value": e["source"]},
                     {"label": "Transferir antes", "value": "sim" if e["transfer_first"] else "não"}], title=f"Atendimento de {p['code']}")
        return {"mode": e["mode"], "source": e["source"], "transfer_first": e["transfer_first"]}
    elif action:
        raise ana.Error("INVALID_PARAMETER", f"ação desconhecida: {action}")

    pol = F.policy()
    ana.metrics([{"label": "Quando falta estoque", "value": F.LABEL[pol["mode"]]},
                 {"label": "Transferir antes de suprir", "value": "sim" if pol["transfer_first"] else "não"},
                 {"label": "Compra vira ordem sozinha até", "value": f"R$ {pol['auto_order_max']}" if pol["auto_order_max"] else "nunca"},
                 {"label": "Quem digita pode escolher", "value": ", ".join(F.LABEL[m] for m in pol["allowed_modes"]) or "só os modos mais rígidos"}],
                title="Política de atendimento da empresa")
    rules = ana.sql("SELECT r.id, r.mode, r.transfer_first, r.item_group, r.note, c.name AS customer, p.code AS product "
                    "FROM sales.fulfillment_rule r LEFT JOIN base.party c ON c.id = r.customer_id LEFT JOIN base.product p ON p.id = r.product_id "
                    "ORDER BY (r.customer_id IS NOT NULL AND r.product_id IS NOT NULL) DESC, r.product_id IS NOT NULL DESC, "
                    "r.item_group IS NOT NULL DESC, r.id LIMIT 1000")
    ana.table([{"nº": r["id"], "cliente": r["customer"] or "todos", "item ou grupo": r["product"] or (f"grupo {r['item_group']}" if r["item_group"] else "todos"),
                "quando falta": F.LABEL[r["mode"]], "transferir antes": "política" if r["transfer_first"] is None else "sim" if r["transfer_first"] else "não",
                "observação": r["note"], "_actions": [{"label": "Apagar", "program": "sales.fulfillment_policy", "params": {"action": "remove", "rule": r["id"]},
                                                        "confirm": f"Apagar a exceção {r['id']}?"}]} for r in rules],
              title="Exceções (a mais específica vale)",
              empty="Nenhuma exceção: a política vale para todos os clientes e itens.",
              empty_action={"label": "Incluir uma exceção", "program": "sales.fulfillment_policy", "params": {"action": "rule"}})
    return {"policy": pol, "rules": len(rules)}


def product_id(code):
    if not code:
        return None
    pid = ana.sql_value("SELECT id FROM base.product WHERE code = $1", code.strip().upper())
    if not pid:
        raise ana.Error("PRODUCT_NOT_FOUND", f"item {code} não encontrado")
    return pid
