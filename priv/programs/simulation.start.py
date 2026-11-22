# ana:description Uso simulado: começa uma simulação (personas percorrendo as esteiras) — para agendar à noite na instância de testes
# ana:role admin
# ana:category Administração/Qualidade
"""Spec 067 (D6, RF-067-05). Starts the simulation in the background and returns at once: the run goes on by itself and
its report is in Administração → Uso simulado. Refused in production. One run at a time."""

PARAMS = {
    "days": {"type": "int", "default": 1, "label": "dias simulados"},
    "per_day": {"type": "int", "default": 6, "label": "cenários por dia"},
    "seed": {"type": "int", "label": "semente (vazio = uma nova; a de um achado o reproduz)"},
    "flows": {"type": "bool", "default": False, "label": "ligar os passos automáticos das esteiras durante a simulação"},
}


def main(days=1, per_day=6, seed=None, flows=False):
    return ana.simulate(days=days, per_day=per_day, seed=seed, flows=flows)
