#!/usr/bin/env python3
"""ANA license tool for the vendor (spec 009, RF-009-10).

  license.py keygen --out DIR --kid KID       Ed25519 pair: DIR/KID.key (private, keep it safe, never
                                               in the repository) and the line for priv/license/keys.json
  license.py issue --key FILE --kid KID --customer NAME --until AAAA-MM-DD --max-version 0.9
                   [--modules sales,projects,...|all] [--users N] [--environment production|non_production]
                   [--from AAAA-MM-DD] [--id ID]   prints the signed license text
  license.py verify --keys priv/license/keys.json FILE   checks a license text (signature and fields)

The license is base64url(JSON) "." base64url(Ed25519 signature of the base64url JSON), between
BEGIN/END lines. Requires the `cryptography` package."""

import argparse
import base64
import datetime
import json
import os
import sys
import uuid

from cryptography.hazmat.primitives import serialization
from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey, Ed25519PublicKey

MODULES = ["sales", "supply", "production", "logistics_field", "projects", "bpm", "analytics", "public_api", "portal"]
BEGIN, END = "-----BEGIN ANA LICENSE-----", "-----END ANA LICENSE-----"


def b64u(b):
    return base64.urlsafe_b64encode(b).rstrip(b"=").decode()


def b64d(s):
    return base64.urlsafe_b64decode(s + "=" * (-len(s) % 4))


def keygen(args):
    key = Ed25519PrivateKey.generate()
    os.makedirs(args.out, exist_ok=True)
    path = os.path.join(args.out, f"{args.kid}.key")
    fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    with os.fdopen(fd, "wb") as f:
        f.write(key.private_bytes(serialization.Encoding.PEM, serialization.PrivateFormat.PKCS8, serialization.NoEncryption()))
    pub = key.public_key().public_bytes(serialization.Encoding.Raw, serialization.PublicFormat.Raw)
    print(f"chave privada: {path} (guarde fora do repositório)")
    print("acrescente em priv/license/keys.json:")
    print(json.dumps({args.kid: {"public": base64.b64encode(pub).decode()}}))


def sign(payload, key_file):
    with open(key_file, "rb") as f:
        key = serialization.load_pem_private_key(f.read(), password=None)
    body = b64u(json.dumps(payload, ensure_ascii=False, sort_keys=True, separators=(",", ":")).encode())
    return f"{BEGIN}\n{body}.{b64u(key.sign(body.encode()))}\n{END}\n"


def issue(args):
    modules = MODULES if args.modules == "all" else [m.strip() for m in args.modules.split(",") if m.strip()]
    unknown = sorted(set(modules) - set(MODULES))
    if unknown:
        sys.exit(f"módulos desconhecidos: {', '.join(unknown)} (válidos: {', '.join(MODULES)})")
    payload = {"id": args.id or str(uuid.uuid4()), "kid": args.kid, "customer": args.customer,
               "issued_at": datetime.date.today().isoformat(), "valid_from": args.valid_from or datetime.date.today().isoformat(),
               "valid_until": args.until, "max_version": args.max_version, "modules": modules,
               "limits": {"named_users": args.users}, "environment": args.environment}
    sys.stdout.write(sign(payload, args.key))


def verify(args):
    with open(args.keys) as f:
        keys = json.load(f)
    text = open(args.file).read()
    body, sig = text.split(BEGIN, 1)[1].split(END, 1)[0].strip().split(".")
    payload = json.loads(b64d(body))
    k = keys.get(payload.get("kid"))
    if not k:
        sys.exit(f"chave desconhecida: {payload.get('kid')}")
    Ed25519PublicKey.from_public_bytes(base64.b64decode(k["public"])).verify(b64d(sig), body.encode())
    print(json.dumps(payload, ensure_ascii=False, indent=2))
    print("assinatura válida" + (" (chave de teste: vale só como não produção)" if k.get("test") else ""))


def main():
    p = argparse.ArgumentParser(description="Licenças do ANA (fornecedor)")
    sub = p.add_subparsers(dest="cmd", required=True)
    g = sub.add_parser("keygen")
    g.add_argument("--out", required=True)
    g.add_argument("--kid", required=True)
    g.set_defaults(fn=keygen)
    i = sub.add_parser("issue")
    i.add_argument("--key", required=True)
    i.add_argument("--kid", required=True)
    i.add_argument("--customer", required=True)
    i.add_argument("--until", required=True)
    i.add_argument("--from", dest="valid_from")
    i.add_argument("--max-version", required=True)
    i.add_argument("--modules", default="all")
    i.add_argument("--users", type=int, default=10)
    i.add_argument("--environment", default="production", choices=["production", "non_production"])
    i.add_argument("--id")
    i.set_defaults(fn=issue)
    v = sub.add_parser("verify")
    v.add_argument("--keys", default="priv/license/keys.json")
    v.add_argument("file")
    v.set_defaults(fn=verify)
    a = p.parse_args()
    a.fn(a)


if __name__ == "__main__":
    main()
