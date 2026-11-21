# ana:description Estrutura do item (componentes, quantidades, perda, fantasma) em nova versão
# ana:exposed yes
# ana:command estrutura
# ana:category Produção/Engenharia do produto
"""RF-014-01. Each save creates a new version and makes it the active one; the previous stays
in the history. A cycle at any depth is refused by the database (CA-014-02)."""

from ana_lib.production import common

PARAMS = {
    "product": {"type": "str", "required": True, "label": "item fabricado", "lookup": {"program": "production.lookup", "params": {"kind": "products"}}},
    "lines": {"type": "list", "required": True, "label": "componentes", "add_label": "Adicionar componente", "columns": {
        "component": {"type": "str", "required": True, "label": "componente", "lookup": {"program": "production.lookup", "params": {"kind": "products"}}},
        "quantity": {"type": "decimal", "required": True, "default": 1, "label": "quantidade por unidade"},
        "scrap_pct": {"type": "decimal", "label": "perda (%)"},
        "phantom": {"type": "bool", "label": "fantasma (explode direto)"}}},
    "notes": {"type": "str", "label": "observação"},
}


def main(product, lines, notes=None):
    p = common.product(product)
    if not 0 < len(lines) <= 1000:
        raise ana.Error("INVALID_LINES", "a estrutura deve ter de 1 a 1000 componentes")
    comps = common.products(l.get("component", "") for l in lines)
    version = ana.sql_value("SELECT COALESCE(max(version), 0) + 1 FROM production.structure WHERE product_id = $1", p["id"])
    ana.sql_exec("UPDATE production.structure SET active = false WHERE product_id = $1 AND active", p["id"])
    sid = ana.sql_value("INSERT INTO production.structure (product_id, version, notes, created_by) VALUES ($1, $2, $3, $4) "
                        "RETURNING id", p["id"], version, notes or "", ana.context.user)
    batch = []
    for n, l in enumerate(lines, start=1):
        c = comps[str(l["component"]).strip().upper()]
        if c["id"] == p["id"]:
            raise ana.Error("STRUCTURE_CYCLE", "o item não pode ser componente de si mesmo")
        batch.append([sid, n, c["id"], l.get("quantity"), l.get("scrap_pct") or 0, bool(l.get("phantom", False))])
    ana.sql_batch("INSERT INTO production.structure_line (structure_id, line, component_id, quantity, scrap_pct, phantom) "
                  "VALUES ($1, $2, $3, $4, $5, $6)", batch)
    ana.table([{"componente": f"{comps[str(l['component']).strip().upper()]['code']} — {comps[str(l['component']).strip().upper()]['description']}",
                "quantidade": l.get("quantity"), "perda %": l.get("scrap_pct") or 0, "fantasma": "sim" if l.get("phantom") else ""}
               for l in lines], title=f"Estrutura de {p['code']} — versão {version}")
    return {"product": p["code"], "version": version, "lines": len(batch)}
