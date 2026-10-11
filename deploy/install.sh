#!/usr/bin/env bash
# ANA ERP — installer for production, on-premise or cloud VM (spec 036). Guide: deploy/INSTALL.md
#
#   sudo ./deploy/install.sh --domain erp.empresa.com.br --email ti@empresa.com.br
#   sudo ./deploy/install.sh --ip 192.168.0.10                  (internal network, internal certificate)
#
# Options
#   --domain NAME        public name (automatic certificate when --email is given)
#   --email ADDRESS      e-mail for the automatic certificate (Let's Encrypt / ZeroSSL)
#   --ip ADDRESS         no DNS name: HTTPS with an internal certificate on this address
#   --cert FILE --key FILE   the company's own certificate (copied to <dir>/certs)
#   --nodes 1|2          core nodes (2 = updates without stopping; default 2)
#   --dir DIR            installation directory (default /opt/ana-erp)
#   --project NAME       Docker project name (default ana-erp)
#   --http-port N --https-port N   public ports (default 80 and 443)
#   --db-host HOST       managed PostgreSQL (see INSTALL.md); default: database in a container
#   --db-port N --db-name NAME
#   --timezone ZONE      default America/Sao_Paulo
#   --image TAG          use an image already built/pulled instead of building from this package
#   --no-cron            do not schedule backups (do it yourself: ana-ctl backup / restore-test)
#   --non-interactive    never ask; fail on missing options
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DOMAIN=""; EMAIL=""; IP=""; CERT=""; KEY=""; NODES=2; DIR=/opt/ana-erp; PROJECT=ana-erp
HTTP_PORT=80; HTTPS_PORT=443; DB_HOST=""; DB_PORT=5432; DB_NAME=ana; TZ_NAME=America/Sao_Paulo
IMAGE=""; CRON=1; INTERACTIVE=1

while [ $# -gt 0 ]; do
  case "$1" in
    --domain) DOMAIN="$2"; shift 2 ;;
    --email) EMAIL="$2"; shift 2 ;;
    --ip) IP="$2"; shift 2 ;;
    --cert) CERT="$2"; shift 2 ;;
    --key) KEY="$2"; shift 2 ;;
    --nodes) NODES="$2"; shift 2 ;;
    --dir) DIR="$2"; shift 2 ;;
    --project) PROJECT="$2"; shift 2 ;;
    --http-port) HTTP_PORT="$2"; shift 2 ;;
    --https-port) HTTPS_PORT="$2"; shift 2 ;;
    --db-host) DB_HOST="$2"; shift 2 ;;
    --db-port) DB_PORT="$2"; shift 2 ;;
    --db-name) DB_NAME="$2"; shift 2 ;;
    --timezone) TZ_NAME="$2"; shift 2 ;;
    --image) IMAGE="$2"; shift 2 ;;
    --no-cron) CRON=0; shift ;;
    --non-interactive) INTERACTIVE=0; shift ;;
    -h|--help) sed -n '2,25p' "$0"; exit 0 ;;
    *) echo "opção desconhecida: $1" >&2; exit 2 ;;
  esac
done

step() { printf '\n== %s\n' "$*"; }
fail() { printf 'ERRO: %s\n' "$*" >&2; exit 1; }
ask() {  # ask VAR "pergunta" [padrão]
  local v
  [ "$INTERACTIVE" = 1 ] || return 0
  read -r -p "$2${3:+ [$3]}: " v; printf -v "$1" '%s' "${v:-${3:-}}"
}
# Finite reads only: "tr < /dev/urandom | head" dies of SIGPIPE under pipefail.
rand_alnum() { head -c 2048 /dev/urandom | LC_ALL=C tr -dc 'A-Za-z0-9' | cut -c "1-$1"; }
rand_key() { head -c 32 /dev/urandom | base64 | tr -d '\n'; }

# ---------------------------------------------------------------- 1. prerequisites
step "1/7 Pré-requisitos"
[ "$(uname -s)" = "Linux" ] || fail "o instalador roda em Linux (servidor ou VM)"
command -v docker >/dev/null || fail "Docker não encontrado: instale o Docker Engine 24+ (https://docs.docker.com/engine/install/)"
docker info >/dev/null 2>&1 || fail "sem acesso ao Docker: rode como root (sudo) ou entre no grupo docker"
docker compose version >/dev/null 2>&1 || fail "plugin 'docker compose' (v2) não encontrado"
dv=$(docker version -f '{{.Server.Version}}' | cut -d. -f1)
[ "${dv:-0}" -ge 24 ] || fail "Docker $dv encontrado; é preciso a versão 24 ou mais nova"
mem_mb=$(awk '/MemTotal/ {print int($2/1024)}' /proc/meminfo)
[ "$mem_mb" -ge 1800 ] || fail "memória de ${mem_mb} MB; o mínimo é 2 GB (recomendado 4 GB ou mais)"
[ "$mem_mb" -ge 3800 ] || echo "  aviso: ${mem_mb} MB de memória; recomendado 4 GB ou mais"
mkdir -p "$DIR"
free_gb=$(df -Pk "$DIR" | awk 'NR==2 {print int($4/1048576)}')
[ "$free_gb" -ge 10 ] || fail "${free_gb} GB livres em $DIR; o mínimo é 10 GB (recomendado 50 GB)"
for p in "$HTTP_PORT" "$HTTPS_PORT"; do
  if (exec 3<>"/dev/tcp/127.0.0.1/$p") 2>/dev/null; then fail "a porta $p já está em uso (use --http-port/--https-port)"; fi
done
[ -f "$ROOT/Dockerfile" ] || [ -n "$IMAGE" ] || fail "rode o instalador a partir do pacote do ANA (Dockerfile não encontrado em $ROOT)"
[ "$NODES" = 1 ] || [ "$NODES" = 2 ] || fail "--nodes deve ser 1 ou 2"
echo "  Linux, Docker $dv, ${mem_mb} MB, ${free_gb} GB livres: ok"

# ---------------------------------------------------------------- 2. address and certificate
step "2/7 Endereço e certificado"
if [ -z "$DOMAIN$IP" ]; then ask DOMAIN "Nome do servidor (ex.: erp.empresa.com.br; vazio = usar IP)"; fi
if [ -z "$DOMAIN$IP" ]; then ask IP "Endereço IP do servidor"; fi
[ -n "$DOMAIN$IP" ] || fail "informe --domain ou --ip"
# The proxy listens on 443 inside its container (the public port only maps to it): no port here.
if [ -n "$DOMAIN" ]; then
  HOSTNAME_="$DOMAIN"; SITE="$DOMAIN"
else
  HOSTNAME_="$IP"; SITE="https://$IP"
fi
mkdir -p "$DIR/certs"
if [ -n "$CERT" ]; then
  [ -f "$CERT" ] && [ -f "$KEY" ] || fail "--cert e --key devem apontar para arquivos existentes"
  install -m 644 "$CERT" "$DIR/certs/fullchain.pem"; install -m 600 "$KEY" "$DIR/certs/privkey.pem"
  TLS="/certs/fullchain.pem /certs/privkey.pem"; tls_text="certificado da empresa"
elif [ -n "$DOMAIN" ] && [ -n "$EMAIL" ] && [ "$DOMAIN" != localhost ]; then
  TLS="$EMAIL"; tls_text="certificado automático para $DOMAIN (portas 80/443 abertas para a internet)"
else
  TLS="internal"; tls_text="certificado interno (instale a autoridade do Caddy nos navegadores ou use --cert)"
fi
echo "  $SITE — $tls_text"

# ---------------------------------------------------------------- 3. secrets
step "3/7 Senhas e chaves"
if [ -f "$DIR/.env" ]; then
  echo "  $DIR/.env já existe: mantendo as senhas e chaves atuais (reinstalação)"
  # shellcheck disable=SC1091
  set -a; . "$DIR/.env"; set +a
else
  POSTGRES_PASSWORD=$(rand_alnum 32); ANA_DB_PASSWORD=$(rand_alnum 32)
  ANA_DB_EXEC_PASSWORD=$(rand_alnum 32); ANA_DB_READ_PASSWORD=$(rand_alnum 32)
  ANA_MASTER_KEY=$(rand_key); ANA_COOKIE=$(rand_alnum 48); ANA_ADMIN_PASSWORD="$(rand_alnum 20)"
  echo "  geradas (nenhuma senha de exemplo é usada)"
fi
if [ -n "$DB_HOST" ]; then
  # Managed database: the role "ana" is created by you (INSTALL.md); its password comes from the
  # environment (ANA_DB_PASSWORD_MANAGED) or is asked here.
  if [ -n "${ANA_DB_PASSWORD_MANAGED:-}" ]; then ANA_DB_PASSWORD="$ANA_DB_PASSWORD_MANAGED"
  elif [ "$INTERACTIVE" = 1 ]; then read -r -s -p "Senha do usuário 'ana' no banco gerenciado: " ANA_DB_PASSWORD; echo
  else fail "banco gerenciado: defina ANA_DB_PASSWORD_MANAGED"; fi
  PROFILES=""; DBH="$DB_HOST"
else
  PROFILES="localdb"; DBH="db"
fi
[ "$NODES" = 2 ] && PROFILES="${PROFILES:+$PROFILES,}ha"
UPSTREAMS="ana1:8080"; [ "$NODES" = 2 ] && UPSTREAMS="ana1:8080 ana2:8080"

# ---------------------------------------------------------------- 4. image
step "4/7 Imagem do ERP"
if [ -z "$IMAGE" ]; then
  vsn=$(sed -n 's/.*{vsn, *"\([^"]*\)".*/\1/p' "$ROOT/src/ana.app.src" | head -1)
  IMAGE="ana-erp:${vsn:-0}-$(date -u +%Y%m%d%H%M%S)"
  echo "  construindo $IMAGE (alguns minutos na primeira vez)…"
  docker build -q -t "$IMAGE" "$ROOT" >/dev/null
else
  docker image inspect "$IMAGE" >/dev/null 2>&1 || docker pull "$IMAGE"
fi
echo "  $IMAGE"

# ---------------------------------------------------------------- 5. files
step "5/7 Arquivos da instalação em $DIR"
install -m 644 "$ROOT/deploy/docker-compose.prod.yml" "$DIR/docker-compose.prod.yml"
install -m 644 "$ROOT/deploy/Caddyfile" "$DIR/Caddyfile"
install -m 644 "$ROOT/deploy/initdb.sql" "$DIR/initdb.sql"
install -m 755 "$ROOT/deploy/ana-ctl" "$DIR/ana-ctl"
umask 077
cat > "$DIR/.env" <<ENV
# ANA ERP — installation settings and secrets (spec 036). Keep a copy in a safe place:
# without ANA_MASTER_KEY the connector secrets cannot be read.
ANA_PROJECT="$PROJECT"
COMPOSE_PROFILES="$PROFILES"
ANA_IMAGE="$IMAGE"
ANA_IMAGE_PREVIOUS="${ANA_IMAGE_PREVIOUS:-}"
ANA_SITE="$SITE"
ANA_HOSTNAME="$HOSTNAME_"
ANA_PUBLIC_URL="https://$HOSTNAME_$( [ "$HTTPS_PORT" = 443 ] || echo ":$HTTPS_PORT" )"
ANA_TLS="$TLS"
ANA_UPSTREAMS="$UPSTREAMS"
ANA_HTTP_PORT_PUBLIC="$HTTP_PORT"
ANA_HTTPS_PORT_PUBLIC="$HTTPS_PORT"
ANA_INSTANCE="production"
ANA_INSTANCE_NAME="${ANA_INSTANCE_NAME:-ana-$(hostname -s | tr 'A-Z' 'a-z' | tr -cd 'a-z0-9-' | head -c 40)}"
ANA_TIMEZONE="$TZ_NAME"
ANA_DB_HOST="$DBH"
ANA_DB_PORT="$DB_PORT"
ANA_DB_NAME="$DB_NAME"
POSTGRES_PASSWORD="$POSTGRES_PASSWORD"
ANA_DB_PASSWORD="$ANA_DB_PASSWORD"
ANA_DB_EXEC_PASSWORD="$ANA_DB_EXEC_PASSWORD"
ANA_DB_READ_PASSWORD="$ANA_DB_READ_PASSWORD"
ANA_MASTER_KEY="$ANA_MASTER_KEY"
ANA_COOKIE="$ANA_COOKIE"
ANA_ADMIN_PASSWORD="$ANA_ADMIN_PASSWORD"
ENV
chmod 600 "$DIR/.env"
umask 022
echo "  docker-compose.prod.yml, Caddyfile, initdb.sql, ana-ctl, .env (600)"

# ---------------------------------------------------------------- 6. start
step "6/7 Subindo"
"$DIR/ana-ctl" --dir "$DIR" up
for _ in $(seq 1 60); do
  curl -fsSk --max-time 3 --resolve "$HOSTNAME_:$HTTPS_PORT:127.0.0.1" "https://$HOSTNAME_:$HTTPS_PORT/health" >/dev/null 2>&1 && break
  sleep 2
done
curl -fsSk --max-time 3 --resolve "$HOSTNAME_:$HTTPS_PORT:127.0.0.1" "https://$HOSTNAME_:$HTTPS_PORT/health" >/dev/null \
  || fail "o ERP subiu mas o HTTPS não responde: ana-ctl --dir $DIR logs proxy"
echo "  HTTPS ok"

# ---------------------------------------------------------------- 7. backups
step "7/7 Cópias de segurança"
if [ -z "$DB_HOST" ]; then
  "$DIR/ana-ctl" --dir "$DIR" backup >/dev/null && echo "  primeira cópia completa feita"
  if [ "$CRON" = 1 ]; then
    if [ "$(id -u)" = 0 ]; then "$DIR/ana-ctl" --dir "$DIR" install-cron; else echo "  agende: ana-ctl backup (diário) e ana-ctl restore-test (mensal)"; fi
  fi
else
  echo "  banco gerenciado: use as cópias automáticas do provedor (com recuperação a um instante)"
fi

URL="https://$HOSTNAME_"; [ "$HTTPS_PORT" = 443 ] || URL="$URL:$HTTPS_PORT"
cat <<DONE

ANA ERP instalado.
  Endereço:        $URL
  Usuário:         admin
  Senha inicial:   $ANA_ADMIN_PASSWORD   (troca obrigatória no primeiro acesso)
  Configuração:    $DIR/.env  — guarde uma cópia em local seguro (contém a chave mestra)
  Operação:        $DIR/ana-ctl status | doctor | backup | upgrade | logs

Próximos passos: dados da empresa (Administração → Empresa), usuários, e o diagnóstico:
  $DIR/ana-ctl doctor
DONE
