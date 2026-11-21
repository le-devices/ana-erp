# ana:description Processos: cenários de simulação guardados de um processo, para comparar lado a lado
# ana:exposed yes
# ana:category Processos/Simulação e descoberta
"""Spec 039 (RF-039-09)."""

PARAMS = {"process": {"type": "str", "required": True, "label": "processo"},
          "remove": {"type": "int", "label": "apagar o cenário (id)"}}


def main(process, remove=None):
    if remove:
        ana.sql_exec("DELETE FROM bpm.simulation WHERE id = $1 AND process_code = $2 AND (created_by = $3 OR $4)",
                     remove, process, ana.context.user, ana.context.role == "admin")
    return {"scenarios": ana.sql("SELECT id, name, version, params, result, seed, created_by, created_at FROM bpm.simulation "
                                 "WHERE process_code = $1 ORDER BY id DESC LIMIT 50", process)}
