# ana:description Cadastros: onde um registro mestre é usado (pedidos, títulos, movimentos…), com a quantidade
# ana:exposed yes
# ana:category Cadastros/Dados mestres
"""Spec 040 (RF-040-03). From the foreign keys of the database: nothing to keep in sync by hand."""

from ana_lib.master import core

PARAMS = {"entity": {"type": "str", "required": True, "label": "cadastro"},
          "key": {"type": "str", "required": True, "label": "código"}}
NAMES = {"sales.sales_order": "Pedidos de venda", "finance.bill": "Títulos", "inventory.stock_movement": "Movimentos de estoque",
         "supply.purchase_order": "Ordens de compra", "supply.purchase_order_line": "Linhas de ordens de compra",
         "supply.purchase_request_line": "Solicitações de compra", "sales.sales_order_item": "Itens de pedidos de venda",
         "field.service_order": "Ordens de serviço", "projects.project": "Projetos", "logistics.shipment": "Expedições",
         "logistics.customer_return": "Devoluções", "finance.journal_line": "Lançamentos contábeis",
         "production.work_order": "Ordens de produção", "projects.time_entry": "Horas apontadas"}


def main(entity, key):
    d = core.entity(entity)
    core.require(d, "view")
    row = core.read_main(d, key)
    used = core.references(d, row["_id"])
    return {"entity": entity, "key": row["_key"],
            "used": [{**u, "label": NAMES.get(u["table"], u["table"])} for u in used]}
