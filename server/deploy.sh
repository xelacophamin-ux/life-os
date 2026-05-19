#!/bin/bash
# Life OS sync — one-shot deployment on the qavonn VPS
# Idempotent: safe to re-run.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
TOKEN_FILE="$HERE/.token"
ENV_FILE="$HERE/.env"
CADDYFILE="$HOME/n8n/Caddyfile"
N8N_DIR="$HOME/n8n"
DOMAIN="sync.qavonn.fr"
NETWORK="n8n_default"
CADDY_CTNR="n8n-caddy-1"

err(){ echo "✗ $*" >&2; exit 1; }
ok(){  echo "✓ $*"; }

# 0. Sanity checks
command -v docker >/dev/null || err "Docker not installed"
command -v openssl >/dev/null || err "openssl not installed"
docker info >/dev/null 2>&1 || err "Docker daemon not running (try: sudo systemctl start docker)"
[ -f "$CADDYFILE" ] || err "Caddyfile not found at $CADDYFILE"
docker network inspect "$NETWORK" >/dev/null 2>&1 || err "Docker network '$NETWORK' not found — is n8n running? (cd ~/n8n && docker compose up -d)"
docker ps --format '{{.Names}}' | grep -q "^$CADDY_CTNR$" || err "Caddy container '$CADDY_CTNR' not running"
ok "Pre-flight checks passed"

# 1. Token (idempotent — keep existing if present)
if [ ! -f "$TOKEN_FILE" ]; then
  openssl rand -hex 32 > "$TOKEN_FILE"
  chmod 600 "$TOKEN_FILE"
  ok "Generated new sync token"
else
  ok "Using existing sync token"
fi
TOKEN=$(cat "$TOKEN_FILE")

# 2. .env for docker compose — preserve existing Garmin creds if any
GARMIN_EMAIL_VAL=""
GARMIN_PASSWORD_VAL=""
if [ -f "$ENV_FILE" ]; then
  GARMIN_EMAIL_VAL=$(grep -E '^GARMIN_EMAIL=' "$ENV_FILE" | sed 's/^GARMIN_EMAIL=//' || true)
  GARMIN_PASSWORD_VAL=$(grep -E '^GARMIN_PASSWORD=' "$ENV_FILE" | sed 's/^GARMIN_PASSWORD=//' || true)
fi
{
  echo "SYNC_TOKEN=$TOKEN"
  echo "GARMIN_EMAIL=$GARMIN_EMAIL_VAL"
  echo "GARMIN_PASSWORD=$GARMIN_PASSWORD_VAL"
} > "$ENV_FILE"
chmod 600 "$ENV_FILE"
ok ".env written (Garmin creds preserved if previously set)"

# 3. Caddyfile block (idempotent)
if ! grep -q "^$DOMAIN" "$CADDYFILE"; then
  cp "$CADDYFILE" "$CADDYFILE.bak.$(date +%s)"
  cat >> "$CADDYFILE" <<EOF

$DOMAIN {
  reverse_proxy lifeos-sync:3001
  header X-Robots-Tag "noindex, nofollow"
}
EOF
  ok "Appended $DOMAIN to Caddyfile (backup saved)"
else
  ok "$DOMAIN already in Caddyfile"
fi

# 4. Build & start sync container
cd "$HERE"
docker compose up -d --build
ok "lifeos-sync container running"

# 5. Restart Caddy (more reliable than caddy reload across mount configs)
docker restart "$CADDY_CTNR" >/dev/null
ok "Caddy restarted — SSL cert auto-issued on first https request"

# 6. Wait for sync container to be healthy
echo -n "Waiting for sync to respond"
for i in $(seq 1 20); do
  if docker exec lifeos-sync wget -q -O - http://localhost:3001/api/health 2>/dev/null | grep -q ok; then
    echo " ✓"; break
  fi
  echo -n "."; sleep 1
done

# 7. Garmin status report
GARMIN_STATUS="(not configured)"
if [ -n "$GARMIN_EMAIL_VAL" ] && [ -n "$GARMIN_PASSWORD_VAL" ]; then
  GARMIN_STATUS="✓ enabled — first fetch starting now (check: docker logs lifeos-garmin)"
fi

# 8. Final report
cat <<EOF

═══════════════════════════════════════════════════════════
 Life OS sync deployed successfully
═══════════════════════════════════════════════════════════

 URL    https://$DOMAIN
 Token  $TOKEN
 Garmin $GARMIN_STATUS

 Add URL+Token in Life OS → Paramètres → Synchronisation
 on every device you want synced.

 To enable Garmin:
   nano $ENV_FILE          (set GARMIN_EMAIL and GARMIN_PASSWORD)
   ./deploy.sh             (re-run to apply)

 Verify endpoints:
   curl https://$DOMAIN/api/health
   curl -H "Authorization: Bearer $TOKEN" https://$DOMAIN/api/garmin

═══════════════════════════════════════════════════════════
EOF
