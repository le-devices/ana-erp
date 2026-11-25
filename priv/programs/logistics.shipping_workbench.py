# ana:description Bancada de expedição: pedidos a expedir, expedições em trânsito e transferências
# ana:command expedicao
# ana:category Logística e campo/Expedição
"""H1–H3: what waits for picking, what is on the road and the transfers in transit."""

from ana_lib.docs.common import link as doc_link

PARAMS = {}


def main():
    c = ana.sql_one(
        "SELECT (SELECT count(*) FROM logistics.order_shipping s JOIN sales.sales_order o ON o.id = s.sales_order_id "
        "        WHERE o.status <> 'CANCELLED' AND s.state <> 'full' AND o.order_date > current_date - 180) AS to_ship, "
        "  (SELECT count(*) FROM logistics.shipment WHERE status = 'shipped') AS on_road, "
        "  (SELECT count(*) FROM logistics.shipment WHERE status = 'shipped' AND expected_date < current_date) AS late, "
        "  (SELECT count(*) FROM logistics.transfer WHERE status = 'shipped') AS transfers")
    ana.metrics([{"label": "Pedidos a expedir", "value": c["to_ship"], "status": "warn" if c["to_ship"] else "ok"},
                 {"label": "Em trânsito", "value": c["on_road"]},
                 {"label": "Entregas atrasadas", "value": c["late"], "status": "bad" if c["late"] else "ok"},
                 {"label": "Transferências em trânsito", "value": c["transfers"]}])
    rows = ana.sql("SELECT o.number, p.name, p.state, s.ordered, s.shipped, s.state FROM logistics.order_shipping s "
                   "JOIN sales.sales_order o ON o.id = s.sales_order_id JOIN base.party p ON p.id = o.customer_id "
                   "WHERE o.status <> 'CANCELLED' AND s.state <> 'full' AND o.order_date > current_date - 180 "
                   "ORDER BY o.number LIMIT 200")
    ana.table([{"pedido": r["number"], "_open": doc_link("order", r["number"]), "cliente": r["name"], "UF": r["state"], "pedido (qtd)": r["ordered"], "expedido": r["shipped"],
                "_actions": [{"label": "Expedir tudo", "program": "logistics.ship", "params": {"order": r["number"]}, "style": "primary",
                              "ask": {"carrier": {"type": "int", "label": "transportadora", "required": True,
                                                  "lookup": {"program": "logistics.lookup", "params": {"kind": "carriers"}}},
                                      "tracking": {"type": "str", "label": "rastreio"},
                                      "weight_kg": {"type": "decimal", "label": "peso (kg)"}}}]}
               for r in rows], title="Pedidos a expedir",
              empty="Nenhum pedido esperando expedição.", empty_action={"label": "Novo pedido de venda", "program": "sales.create_order"})
    road = ana.sql("SELECT s.number, o.number AS order_number, p.name, c.name AS carrier, s.tracking, s.expected_date "
                   "FROM logistics.shipment s JOIN sales.sales_order o ON o.id = s.sales_order_id JOIN base.party p ON p.id = o.customer_id "
                   "LEFT JOIN logistics.carrier c ON c.id = s.carrier_id WHERE s.status = 'shipped' ORDER BY s.expected_date LIMIT 200")
    ana.table([{"expedição": r["number"], "_open": doc_link("shipment", r["number"]), "pedido": r["order_number"], "cliente": r["name"], "transportadora": r["carrier"],
                "rastreio": r["tracking"], "previsão": r["expected_date"],
                "_actions": [{"label": "Entregue", "program": "logistics.deliver", "params": {"shipment": r["number"]}, "style": "primary",
                              "ask": {"received_by": {"type": "str", "label": "recebido por", "required": True}}},
                             {"label": "Voltou", "program": "logistics.deliver", "params": {"shipment": r["number"], "returned": True},
                              "confirm": "A mercadoria voltou para o depósito?"}]} for r in road], title="Em trânsito",
              empty="Nada em trânsito.", empty_good=True)
    return {"counts": c}
