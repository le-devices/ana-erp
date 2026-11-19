# ana:description Opções para campos de escolha da área fiscal
# ana:kind program
# ana:menu no
"""Lookup for forms of the tax area: taxes, rules, packages, attributes, test cases."""

PARAMS = {"kind": {"type": "str", "required": True, "label": "tipo",
                   "choices": ["taxes", "rules", "packages", "attributes", "cases", "tables"]}}


def main(kind):
    if kind == "taxes":
        return [{"value": r["code"], "label": f"{r['name']} ({r['code']})"}
                for r in ana.sql("SELECT code, name FROM tax.tax WHERE active ORDER BY sequence, code")]
    if kind == "rules":
        return [{"value": r["id"], "label": f"{r['id']} — {r['name']} ({r['status']})"}
                for r in ana.sql("SELECT id, name, status FROM tax.rule WHERE status <> 'retired' ORDER BY tax, id")]
    if kind == "packages":
        return [{"value": r["name"], "label": r["description"] or r["name"]} for r in ana.sql("SELECT name, description FROM tax.packages()")]
    if kind == "attributes":
        return [{"value": f"{r['entity']}.{r['code']}", "label": f"{r['entity']}.{r['code']} — {r['description']}"}
                for r in ana.sql("SELECT entity, code, description FROM tax.attribute ORDER BY entity, code")]
    if kind == "cases":
        return [{"value": r["id"], "label": r["name"]} for r in ana.sql("SELECT id, name FROM tax.test_case WHERE active ORDER BY id")]
    return [{"value": r["table_name"], "label": r["table_name"]}
            for r in ana.sql("SELECT DISTINCT table_name FROM tax.table_row ORDER BY 1")]
