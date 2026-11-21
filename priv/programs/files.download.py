# ana:description Abre um arquivo do repositório para baixar (o repositório confere a permissão de quem pede)
# ana:portal yes
# ana:menu no
"""Spec 037. Returns {"_download": {"file"}}; the download itself goes through the repository,
which checks the user's level on the file (a portal account only reaches what was shared)."""

PARAMS = {"file": {"type": "int", "required": True, "label": "arquivo"}}


def main(file):
    return {"file": int(file), "_download": {"file": int(file)}}
