# ana:description Desempenho de fornecedores: pontualidade, prazo real × prometido, divergências
# ana:command fornecedores
# ana:category Compras/Fornecedores
"""RF-013-09. A line is on time when the receipt that completed it happened on or before the
promised date. Divergences: received quantity × ordered (closed lines) and invoice price × order price."""

import datetime

PARAMS = {
    "start": {"type": "date", "label": "de (vazio = últimos 12 meses)"},
    "end": {"type": "date", "label": "até (vazio = hoje)"},
    "supplier": {"type": "int", "label": "fornecedor", "lookup": {"program": "supply.lookup", "params": {"kind": "suppliers"}}},
}


def main(start=None, end=None, supplier=None):
    end = end or datetime.date.today()
    start = start or end - datetime.timedelta(days=365)
    rows = ana.sql(
        "WITH rl AS (SELECT r.order_id, rl.order_line, max(r.received_at)::date AS last_date, "
        "              sum(rl.quantity) AS qty, sum(rl.quantity * rl.price) / sum(rl.quantity) AS avg_price "
        "            FROM supply.receipt r JOIN supply.receipt_line rl ON rl.receipt_id = r.id "
        "            WHERE r.received_at::date BETWEEN $1 AND $2 GROUP BY 1, 2), "
        "lines AS (SELECT o.supplier_id, l.quantity, l.price, l.promised_date, o.sent_at::date AS sent, rl.last_date, "
        "            rl.qty, rl.avg_price, l.received_qty >= l.quantity AS complete "
        "          FROM rl JOIN supply.purchase_order_line l ON l.order_id = rl.order_id AND l.line = rl.order_line "
        "          JOIN supply.purchase_order o ON o.id = l.order_id WHERE $3::int IS NULL OR o.supplier_id = $3) "
        "SELECT p.name, count(*) AS lines, "
        "  round(100.0 * count(*) FILTER (WHERE complete AND (promised_date IS NULL OR last_date <= promised_date)) "
        "        / NULLIF(count(*) FILTER (WHERE complete), 0), 1) AS on_time_pct, "
        "  round(avg(last_date - sent) FILTER (WHERE complete), 1) AS actual_days, "
        "  round(avg(promised_date - sent) FILTER (WHERE complete), 1) AS promised_days, "
        "  count(*) FILTER (WHERE complete AND qty <> quantity) AS qty_divergences, "
        "  count(*) FILTER (WHERE avg_price <> price) AS price_divergences, "
        "  round(sum(qty * avg_price), 2) AS purchased "
        "FROM lines JOIN base.party p ON p.id = lines.supplier_id GROUP BY p.name ORDER BY purchased DESC NULLS LAST",
        start, end, supplier)
    table = [{"fornecedor": r["name"], "linhas recebidas": r["lines"], "no prazo %": r["on_time_pct"],
              "prazo real (dias)": r["actual_days"], "prazo prometido (dias)": r["promised_days"],
              "divergências de quantidade": r["qty_divergences"], "divergências de preço": r["price_divergences"],
              "comprado": r["purchased"]} for r in rows]
    rated = [r for r in rows if r["on_time_pct"] is not None][:12]
    if rated:
        ana.chart(type="bar", title="Pontualidade por fornecedor", subtitle=f"{start:%d/%m/%Y} a {end:%d/%m/%Y}",
                  format="percent", x=[r["name"] for r in rated], series=[{"name": "No prazo", "values": [r["on_time_pct"] for r in rated]}])
    ana.table(table, title="Desempenho de fornecedores", empty="Nenhum recebimento no período para medir.",
              empty_action={"label": "Receber mercadoria", "program": "supply.receive"})
    return {"start": start, "end": end, "suppliers": table}
