# ana:description Parâmetros de distância: fator rodoviário, velocidade média e serviço de geocodificação
# ana:role admin
# ana:category Cadastros/Distâncias
"""RF-032-02, RF-032-04. Without parameters, shows the current values. The geocoder is an
integration connector (spec 017): nothing is sent outside unless one is chosen here."""

PARAMS = {
    "road_factor": {"type": "decimal", "label": "fator rodoviário (reta × fator; padrão 1,3)"},
    "avg_speed_kmh": {"type": "decimal", "label": "velocidade média (km/h)"},
    "geocoder_connector": {"type": "str", "label": "conector de geocodificação (vazio = nenhum)"},
    "clear_geocoder": {"type": "bool", "default": False, "label": "não usar geocodificação"},
}


def main(road_factor=None, avg_speed_kmh=None, geocoder_connector=None, clear_geocoder=False):
    if geocoder_connector and not ana.sql_value("SELECT count(*) FROM integration.connector WHERE name = $1 AND kind = 'http_api'",
                                                geocoder_connector):
        raise ana.Error("CONNECTOR_NOT_FOUND", f"conector {geocoder_connector} não existe (Administração → Integrações)")
    ana.sql_exec("UPDATE base.geo_policy SET road_factor = COALESCE($1, road_factor), avg_speed_kmh = COALESCE($2, avg_speed_kmh), "
                 "geocoder_connector = CASE WHEN $4 THEN NULL ELSE COALESCE($3, geocoder_connector) END WHERE id = 1",
                 road_factor, avg_speed_kmh, geocoder_connector, clear_geocoder)
    p = ana.sql_one("SELECT road_factor, avg_speed_kmh, geocoder_connector FROM base.geo_policy WHERE id = 1")
    ana.metrics([{"label": "Fator rodoviário", "value": str(p["road_factor"]).replace(".", ",")},
                 {"label": "Velocidade média", "value": f"{p['avg_speed_kmh']} km/h".replace(".", ",")},
                 {"label": "Geocodificação", "value": p["geocoder_connector"] or "desligada"}], title="Distâncias")
    return p
