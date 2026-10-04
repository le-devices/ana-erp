# ana:description Cria ou altera fase ou atividade do projeto (responsável, horas, datas, dependências)
# ana:exposed yes
"""RF-021-01. Predecessors: list of codes, optionally with lag in working
days ("1.2+3"). Cycles are refused. Only the project manager or an admin."""

import re

from ana_lib.projects import access
from ana_lib.projects import consulting as C
from ana_lib.projects import views as V

PARAMS = {
    "project": {"type": "str", "required": True, "label": "projeto"},
    "code": {"type": "str", "required": True, "label": "código"},
    "name": {"type": "str", "label": "nome"},
    "kind": {"type": "str", "label": "phase ou activity"},
    "phase": {"type": "str", "label": "fase (código)"},
    "owner": {"type": "int", "label": "responsável (colaborador)"},
    "profile": {"type": "str", "label": "perfil"},
    "planned_hours": {"type": "decimal", "label": "horas planejadas"},
    "duration_days": {"type": "int", "label": "duração (dias úteis)"},
    "planned_start": {"type": "date", "label": "início planejado"},
    "planned_finish": {"type": "date", "label": "término planejado"},
    "predecessors": {"type": "list", "label": "predecessoras", "default": None},
    "deliverable": {"type": "str", "label": "entregável"},
    "acceptance_criteria": {"type": "str", "label": "critério de aceite"},
    "billable": {"type": "bool"},
    "client_visible": {"type": "bool"},
    "active": {"type": "bool"},
}

FIELDS = ["name", "kind", "owner_employee_id", "profile", "planned_hours", "duration_days", "planned_start",
          "planned_finish", "deliverable", "acceptance_criteria", "billable", "client_visible", "active"]


def main(project, code, phase=None, owner=None, predecessors=None, **f):
    p = access.project(project, lock=True)
    access.require_manager(p)
    code = str(code).strip()
    f["owner_employee_id"] = owner
    if f.get("profile"):
        f["profile"] = f["profile"].upper()
    if f.get("kind") not in (None, "phase", "activity"):
        raise ana.Error("INVALID_PARAMETER", "kind deve ser phase ou activity")
    parent_id = None
    if phase:
        ph = V.activity(p, phase)
        if ph["kind"] != "phase":
            raise ana.Error("INVALID_PARAMETER", f"{phase} não é uma fase")
        parent_id = ph["id"]
    current = ana.sql_one("SELECT * FROM projects.task WHERE project_id = $1 AND code = $2 FOR UPDATE", p["id"], code)
    if current is None:
        if not f.get("name"):
            raise ana.Error("INVALID_PARAMETER", "atividade nova exige nome")
        seq = ana.sql_value("SELECT COALESCE(max(seq), 0) + 1 FROM projects.task WHERE project_id = $1", p["id"])
        task_id = ana.sql_value(
            "INSERT INTO projects.task (project_id, code, name, kind, parent_id, seq, owner_employee_id, profile, "
            "  planned_hours, duration_days, planned_start, planned_finish, deliverable, acceptance_criteria, "
            "  billable, client_visible, active) "
            "VALUES ($1, $2, $3, COALESCE($4, 'activity'), $5, $6, $7, $8, $9, $10, $11, $12, $13, $14, "
            "        COALESCE($15::boolean, true), COALESCE($16::boolean, true), COALESCE($17::boolean, true)) RETURNING id",
            p["id"], code, f["name"], f.get("kind"), parent_id, seq, owner, f.get("profile"), f.get("planned_hours"),
            f.get("duration_days"), f.get("planned_start"), f.get("planned_finish"), f.get("deliverable"),
            f.get("acceptance_criteria"), f.get("billable"), f.get("client_visible"), f.get("active"))
    else:
        task_id = current["id"]
        sets = [f"{c} = COALESCE(${n + 2}, {c})" for n, c in enumerate(FIELDS)]
        ana.sql_exec(f"UPDATE projects.task SET {', '.join(sets)}, updated_at = now() WHERE id = $1",
                     task_id, *[f.get(c) for c in FIELDS])
        if phase is not None:
            ana.sql_exec("UPDATE projects.task SET parent_id = $2 WHERE id = $1", task_id, parent_id)
    if owner is not None:
        ensure_member(p, owner)
    if predecessors is not None:
        ana.sql_exec("DELETE FROM projects.task_dependency WHERE task_id = $1", task_id)
        rows = []
        for pre in predecessors:
            m = re.fullmatch(r"\s*([0-9A-Za-z._-]{1,20})\s*(?:([+-])\s*(\d+))?\s*", str(pre))
            if not m:
                raise ana.Error("INVALID_PARAMETER", f"predecessora inválida: {pre}")
            lag = int(m.group(3) or 0) * (-1 if m.group(2) == "-" else 1)
            pred = V.activity(p, m.group(1))
            rows.append([task_id, pred["id"], lag])
        if rows:
            ana.sql_batch("INSERT INTO projects.task_dependency (task_id, predecessor_id, lag_days) "
                          "VALUES ($1, $2, $3)", rows)
    C.schedule(p)            # refuses cycles (DEPENDENCY_CYCLE) and rolls everything back
    return {"project": p["code"], "code": code, "id": task_id, "created": current is None}


def ensure_member(p, employee):
    prof = ana.sql_value("SELECT profile FROM projects.employee WHERE id = $1 AND active", employee)
    if prof is None:
        raise ana.Error("EMPLOYEE_NOT_FOUND", f"colaborador {employee} não existe")
    ana.sql_exec("INSERT INTO projects.project_member (project_id, employee_id, profile) VALUES ($1, $2, $3) "
                 "ON CONFLICT DO NOTHING", p["id"], employee, prof)
