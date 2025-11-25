#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'
trap 'echo "Interrupted"; exit 1' INT TERM

usage() {
  echo "Usage: $0 --domain <DOMAIN> --email <EMAIL> [--enable-basic-auth] [--reset-acme]"
}

DOMAIN=""
EMAIL=""
ENABLE_BASIC_AUTH=false
RESET_ACME=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --domain)
      DOMAIN="$2"
      shift 2
      ;;
    --email)
      EMAIL="$2"
      shift 2
      ;;
    --enable-basic-auth)
      ENABLE_BASIC_AUTH=true
      shift
      ;;
    --reset-acme)
      RESET_ACME=true
      shift
      ;;
    *)
      usage
      exit 1
      ;;
  esac
done

if [[ -z "$DOMAIN" || -z "$EMAIL" ]]; then
  usage
  exit 1
fi

# DNS lookup
if command -v dig >/dev/null 2>&1; then
  dns=$(dig @8.8.8.8 A "$DOMAIN" +short)
else
  dns=$(getent hosts "$DOMAIN" | awk '{print $1}')
fi
if [[ -z "$dns" ]]; then
  echo "DNS lookup failed for $DOMAIN" >&2
  exit 1
fi

# Port checks
for port in 80 443; do
  if lsof -i :"$port" -sTCP:LISTEN -t >/dev/null 2>&1; then
    echo "Port $port is already in use" >&2
    exit 1
  fi
 done

# Prepare .env
cp .env.example .env
sed -i "s|^DOMAIN=.*|DOMAIN=${DOMAIN}|" .env
sed -i "s|^EMAIL=.*|EMAIL=${EMAIL}|" .env
if grep -q '^POSTGRES_PASSWORD=$' .env; then
  sed -i "s|^POSTGRES_PASSWORD=$|POSTGRES_PASSWORD=$(openssl rand -hex 16)|" .env
fi
if grep -q '^N8N_ENCRYPTION_KEY=$' .env; then
  sed -i "s|^N8N_ENCRYPTION_KEY=$|N8N_ENCRYPTION_KEY=$(openssl rand -hex 32)|" .env
fi
sed -i '/^# N8N_BASIC_AUTH_USER/d' .env
sed -i '/^# N8N_BASIC_AUTH_PASSWORD/d' .env
if $ENABLE_BASIC_AUTH; then
  read -rp "N8N basic auth user: " N8N_BASIC_AUTH_USER
  read -rsp "N8N basic auth password: " N8N_BASIC_AUTH_PASSWORD; echo
  {
    echo "N8N_BASIC_AUTH_ACTIVE=true"
    echo "N8N_BASIC_AUTH_USER=$N8N_BASIC_AUTH_USER"
    echo "N8N_BASIC_AUTH_PASSWORD=$N8N_BASIC_AUTH_PASSWORD"
  } >> .env
else
  echo "N8N_BASIC_AUTH_ACTIVE=false" >> .env
fi
chmod 600 .env

# Prepare acme.json
if ! docker volume inspect traefik_letsencrypt >/dev/null 2>&1; then
  docker volume create traefik_letsencrypt >/dev/null
fi
acme_path=$(docker volume inspect traefik_letsencrypt -f '{{ .Mountpoint }}')
acme_file="${acme_path}/acme.json"
if [[ ! -f "$acme_file" || $RESET_ACME == true ]]; then
  echo '{}' > "$acme_file"
  chmod 600 "$acme_file"
fi

# Start services
docker compose up -d n8n-traefik n8n

# Trigger certificate request
curl -skI "https://${DOMAIN}" >/dev/null || true

echo "Waiting for certificate..."
success=false
for i in {1..30}; do
  logs=$(docker logs n8n-traefik 2>&1 | tail -n 20)
  if echo "$logs" | grep -qi 'obtained certificates'; then
    success=true
    break
  fi
  if echo "$logs" | grep -qi 'unable to obtain ACME certificate'; then
    break
  fi
  sleep 3
done
if ! $success; then
  echo "Certificate request may have failed. Check logs." >&2
fi

# Verify redirect
http_code=$(curl -sI "http://${DOMAIN}" | head -n 1 | awk '{print $2}')
if [[ "$http_code" == "308" ]]; then
  echo "HTTP redirect to HTTPS confirmed"
else
  echo "HTTP redirect check failed (expected 308, got $http_code)" >&2
fi

# Verify certificate issuer
if openssl s_client -connect "${DOMAIN}:443" -servername "${DOMAIN}" -showcerts </dev/null 2>/dev/null \
  | openssl x509 -noout -issuer | grep -qi "Let's Encrypt"; then
  echo "Let's Encrypt certificate detected"
else
  echo "Certificate issuer is not Let's Encrypt" >&2
fi

echo "Done. Troubleshooting:"
echo "- Ensure DNS A record for ${DOMAIN} points to this server"
echo "- Verify ports 80 and 443 are open"
echo "- Check 'docker logs n8n-traefik' for details"
