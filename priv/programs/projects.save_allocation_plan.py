# ana:description Grava as alterações da grade de alocação de horas (regras da alocação, controle de edição concorrente)
# ana:menu no
# ana:category Projetos/Planejamento
"""Spec 020 (RF-020-15) on spec 021 (RF-021-03). changes: [{"key": {"who": "e:<pessoa>" | "p:<perfil>" | "<pessoa>",
"activity"}, "values": {"AAAA-MM-DD": horas|null}}]. Each cell goes through projects.allocate (manager, team,
overallocation warnings); empty = 0 (removes the allocation of that week)."""

import datetime
from decimal import Decimal, InvalidOperation

from ana_lib.projects import access
from ana_lib.projects import consulting as C

PARAMS = {
    "changes": {"type": "list", "required": True, "label": "alterações"},
    "version": {"type": "str", "label": "versão lida"},
    "project": {"type": "str", "required": True, "label": "projeto"},
    "start": {"type": "date", "required": True, "label": "primeira semana"},
    "weeks": {"type": "int", "required": True, "label": "semanas"},
}


def main(changes, project, start, weeks, version=None):
    p = access.project(project, lock=True)
    access.require_manager(p)
    first = C.monday(start)
    last = first + datetime.timedelta(weeks=int(weeks))
    current = ana.sql_value("SELECT md5(COALESCE(string_agg(concat_ws(';', task_id, week, employee_id, profile, hours), '|' "
                            "ORDER BY task_id, week, employee_id, profile), '')) FROM projects.allocation "
                            "WHERE project_id = $1 AND week >= $2 AND week < $3", p["id"], first, last)
    if version and current != version:
        raise ana.Error("CONFLICT", "a alocação foi alterada por outra pessoa depois que você abriu a grade: recarregue e refaça")
    n = 0
    for ch in changes:
        k = ch.get("key") or {}
        who, activity = str(k.get("who") or ""), str(k.get("activity") or "")
        target = {"profile": who[2:]} if who.startswith("p:") else {"employee": int(who[2:] if who.startswith("e:") else who)}
        for week, v in (ch.get("values") or {}).items():
            d = datetime.date.fromisoformat(str(week)[:10])
            if not first <= d < last:
                raise ana.Error("INVALID_PARAMETER", f"semana fora da grade: {week}")
            try:
                hours = Decimal("0") if v is None or str(v).strip() == "" else Decimal(str(v))
            except InvalidOperation:
                raise ana.Error("INVALID_PARAMETER", f"{who} · {activity} · {week}: horas inválidas ({v})") from None
            if hours < 0:
                raise ana.Error("INVALID_PARAMETER", f"{who} · {activity} · {week}: horas não podem ser negativas")
            ana.call("projects.allocate", project=p["code"], activity=activity, hours=str(hours), week=d.isoformat(), **target)
            n += 1
    after = ana.sql_value("SELECT md5(COALESCE(string_agg(concat_ws(';', task_id, week, employee_id, profile, hours), '|' "
                          "ORDER BY task_id, week, employee_id, profile), '')) FROM projects.allocation "
                          "WHERE project_id = $1 AND week >= $2 AND week < $3", p["id"], first, last)
    return {"saved": n, "version": after}
