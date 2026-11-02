#!/usr/bin/env bash
# Instalador do Minha Automação: um comando, numa máquina com Debian, Ubuntu
# ou Raspberry Pi OS (64 bits). Instala o Docker (se faltar), baixa o compose,
# gera os segredos (ficam só nesta máquina, em $DIR/.env, chmod 600) e sobe.
# No fim, abra o endereço que ele mostra: a primeira configuração cria a conta
# do dono. Rodar de novo é seguro: não troca segredo nem apaga dado.
#
#   curl -fsSL https://raw.githubusercontent.com/minhasuite/minha-automacao/master/install.sh | sudo bash
#
# Variáveis (opcionais): MA_DIR (/opt/minha-automacao), MA_TAG (latest),
# MA_PORT (80), MA_REPO_RAW (de onde vem o compose), MA_IMAGE (imagem).
set -euo pipefail

DIR="${MA_DIR:-/opt/minha-automacao}"
TAG="${MA_TAG:-latest}"
PORT="${MA_PORT:-80}"
RAW="${MA_REPO_RAW:-https://raw.githubusercontent.com/minhasuite/minha-automacao/master}"
IMAGE="${MA_IMAGE:-ghcr.io/minhasuite/minha-automacao}:$TAG"

say() { printf '\n\033[1;35m==>\033[0m %s\n' "$*"; }
die() { printf '\n\033[1;31mErro:\033[0m %s\n' "$*" >&2; exit 1; }

[ "$(id -u)" -eq 0 ] || die "rode como root (curl ... | sudo bash)."
[ -r /etc/os-release ] && . /etc/os-release
case "${ID:-}${ID_LIKE:-}" in *debian*|*ubuntu*|*raspbian*) ;; *) die "sistema não suportado (${PRETTY_NAME:-desconhecido}); use Debian, Ubuntu ou Raspberry Pi OS." ;; esac
case "$(uname -m)" in x86_64|aarch64|arm64) ;; *) die "processador $(uname -m) não suportado; use 64 bits (x86_64 ou arm64)." ;; esac

say "Pacotes básicos"
apt-get update -qq
DEBIAN_FRONTEND=noninteractive apt-get install -y -qq curl ca-certificates openssl >/dev/null

if ! command -v docker >/dev/null 2>&1; then
  say "Instalando o Docker (get.docker.com)"
  curl -fsSL https://get.docker.com | sh >/dev/null
fi
docker compose version >/dev/null 2>&1 || die "o Docker Compose (plugin) não está disponível."
systemctl enable --now docker >/dev/null 2>&1 || true

say "Pasta $DIR"
mkdir -p "$DIR/backups" "$DIR/secrets"
cd "$DIR"
curl -fsSL "$RAW/docker-compose.local.yml" -o docker-compose.yml.new || die "não deu para baixar o compose de $RAW."
mv docker-compose.yml.new docker-compose.yml

say "Segredos (só nesta máquina)"
touch .env && chmod 600 .env
gen() { grep -q "^$1=" .env || echo "$1=$(openssl rand -hex "${2:-32}")" >> .env; }
gen SECRET_KEY_BASE 64
gen DB_PASSWORD 24
gen AR_ENCRYPTION_PRIMARY_KEY
gen AR_ENCRYPTION_DETERMINISTIC_KEY
gen AR_ENCRYPTION_KEY_DERIVATION_SALT
gen MQTT_PASSWORD 24
gen Z2M_FRONTEND_TOKEN 16
gen SUPERVISOR_TOKEN 32
# Web Push (PWA): par VAPID P-256, uma vez só.
if ! grep -q '^VAPID_PRIVATE_KEY=.' .env; then
  b64url() { base64 -w0 | tr '+/' '-_' | tr -d '='; }
  pem=$(openssl ecparam -name prime256v1 -genkey -noout 2>/dev/null)
  echo "VAPID_PUBLIC_KEY=$(printf '%s\n' "$pem" | openssl ec -pubout -outform DER 2>/dev/null | tail -c 65 | b64url)" >> .env
  echo "VAPID_PRIVATE_KEY=$(printf '%s\n' "$pem" | openssl ec -outform DER 2>/dev/null | tail -c +8 | head -c 32 | b64url)" >> .env
fi
IP=$(hostname -I 2>/dev/null | awk '{print $1}')
grep -q '^APP_HOST=' .env || echo "APP_HOST=${IP:-127.0.0.1}" >> .env
grep -q '^WEB_PORT=' .env || echo "WEB_PORT=$PORT" >> .env
sed -i '/^IMAGE=/d' .env && echo "IMAGE=$IMAGE" >> .env

say "Baixando e subindo ($IMAGE)"
profiles=()
grep -q '^CF_TUNNEL_TOKEN=.' .env && profiles+=(--profile tunnel)
docker compose "${profiles[@]}" pull -q
docker compose "${profiles[@]}" up -d --remove-orphans

say "Esperando o servidor responder"
for _ in $(seq 1 60); do
  if curl -fsS -o /dev/null "http://127.0.0.1:$PORT/up"; then
    url="http://${IP:-127.0.0.1}$([ "$PORT" = 80 ] || echo ":$PORT")/"
    printf '\n\033[1;32mPronto!\033[0m Abra %s no navegador para a primeira configuração.\n' "$url"
    printf 'Atualizações: Configurações → Sistema. Pasta: %s (segredos em .env).\n' "$DIR"
    exit 0
  fi
  sleep 5
done
docker compose logs --tail 40 web
die "o servidor não respondeu em 5 minutos (veja o log acima)."
