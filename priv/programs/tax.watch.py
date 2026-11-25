# ana:description Vigilância fiscal: pacote não aplicado, vigência terminando, indicador perto do limite, conflitos
# ana:exposed yes
# ana:category Fiscal/Regras e pacotes
"""Daily routine (spec 049, P19): computes what needs the tax officer (writing nothing, P15). The same list
heads the tax area home (tax.overview)."""

from ana_lib.tax import admin

PARAMS = {}


def main():
    alerts = admin.alerts()
    ana.table([{"aviso": a["text"]} for a in alerts] or [{"aviso": "nada pendente"}], title="Vigilância fiscal")
    if alerts:
        ana.actions([{"label": "Abrir Impostos", "program": "tax.overview", "open": True}], title=f"{len(alerts)} aviso(s)")
    return {"alerts": alerts}
