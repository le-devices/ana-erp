"""A small SMTP server for the e-mail tests (spec 044), standard library only.

Runs in a container on the compose network as host "smtp-sink":
  python smtp_sink.py <port> <cert.pem|-> <key.pem|-> <user> <password>
STARTTLS is offered when a certificate is given; AUTH only after TLS. A recipient containing
"recusado" gets 550 (permanent); "lento" gets 451 (temporary). Each accepted message is
appended as one JSON line to /data/mail.log: {"from", "to", "auth", "tls", "data"}.
"""
import base64
import json
import socketserver
import ssl
import sys

PORT, CERT, KEY, USER, PASSWORD = int(sys.argv[1]), sys.argv[2], sys.argv[3], sys.argv[4], sys.argv[5]
CTX = None
if CERT != "-":
    CTX = ssl.create_default_context(ssl.Purpose.CLIENT_AUTH)
    CTX.load_cert_chain(CERT, KEY)


class Session(socketserver.StreamRequestHandler):
    def reply(self, line):
        self.wfile.write((line + "\r\n").encode())
        self.wfile.flush()

    def handle(self):
        tls, auth, sender, rcpt = False, None, None, []
        self.reply("220 smtp-sink ESMTP")
        while True:
            raw = self.rfile.readline()
            if not raw:
                return
            line = raw.decode("utf-8", "replace").rstrip("\r\n")
            cmd = line.upper()
            if cmd.startswith("EHLO"):
                ext = ["250-smtp-sink"]
                if CTX and not tls:
                    ext.append("250-STARTTLS")
                if tls:
                    ext.append("250-AUTH PLAIN LOGIN")
                ext.append("250 8BITMIME")
                for e in ext:
                    self.reply(e)
            elif cmd == "STARTTLS" and CTX and not tls:
                self.reply("220 go ahead")
                self.connection = CTX.wrap_socket(self.connection, server_side=True)
                self.rfile = self.connection.makefile("rb")
                self.wfile = self.connection.makefile("wb")
                tls = True
            elif cmd.startswith("AUTH PLAIN") and tls:
                parts = base64.b64decode(line.split(" ", 2)[2]).split(b"\0")
                ok = parts[1].decode() == USER and parts[2].decode() == PASSWORD
                auth = USER if ok else None
                self.reply("235 ok" if ok else "535 credenciais recusadas")
            elif cmd.startswith("MAIL FROM:"):
                sender, rcpt = line[10:].strip("<> "), []
                self.reply("250 ok")
            elif cmd.startswith("RCPT TO:"):
                addr = line[8:].strip("<> ")
                if "recusado" in addr:
                    self.reply("550 caixa inexistente")
                elif "lento" in addr:
                    self.reply("451 tente mais tarde")
                else:
                    rcpt.append(addr)
                    self.reply("250 ok")
            elif cmd == "DATA":
                self.reply("354 fim com <CRLF>.<CRLF>")
                lines = []
                while True:
                    d = self.rfile.readline().decode("utf-8", "replace")
                    if d in (".\r\n", ".\n", ""):
                        break
                    lines.append(d[1:] if d.startswith("..") else d)
                with open("/data/mail.log", "a", encoding="utf-8") as f:
                    f.write(json.dumps({"from": sender, "to": rcpt, "auth": auth, "tls": tls, "data": "".join(lines)}) + "\n")
                self.reply("250 2.0.0 Ok: queued as SINK%d" % (hash("".join(lines)) % 100000))
            elif cmd == "QUIT":
                self.reply("221 bye")
                return
            else:
                self.reply("502 comando não suportado")


class Server(socketserver.ThreadingTCPServer):
    allow_reuse_address = True
    daemon_threads = True


Server(("0.0.0.0", PORT), Session).serve_forever()
