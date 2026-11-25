# ana:description Exclui apontamento pendente ou rejeitado
# ana:exposed yes
# ana:category Projetos/Meu trabalho
# ana:confirm O apontamento de horas é excluído de vez. Não há desfazer: para corrigir, aponte de novo.
from ana_lib.projects import access
from ana_lib.util.format import status_text

PARAMS = {
    "id": {"type": "int", "required": True, "label": "apontamento (id)"},
}


def main(id):
    e = ana.sql_one("SELECT t.id, t.status, t.employee_id, p.code FROM projects.time_entry t "
                    "JOIN projects.project p ON p.id = t.project_id WHERE t.id = $1", id)
    if not e:
        raise ana.Error("ENTRY_NOT_FOUND", f"apontamento {id} não encontrado")
    me = access.current_employee()
    if not ((me and me["id"] == e["employee_id"]) or access.can_manage(access.project(e["code"]))):
        raise ana.Error("FORBIDDEN", "só o autor ou o gestor podem excluir")
    if e["status"] not in ("pending", "rejected"):
        raise ana.Error("ENTRY_LOCKED", f"apontamento está {status_text(e['status'])}")
    ana.sql_exec("DELETE FROM projects.time_entry WHERE id = $1", id)
    return {"id": id, "deleted": True}
