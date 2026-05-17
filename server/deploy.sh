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

# 2. .env for docker compose
echo "SYNC_TOKEN=$TOKEN" > "$ENV_FILE"
chmod 600 "$ENV_FILE"
ok ".env written"

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

# 7. Final report
cat <<EOF

═══════════════════════════════════════════════════════════
 Life OS sync deployed successfully
═══════════════════════════════════════════════════════════

 URL    https://$DOMAIN
 Token  $TOKEN

 Add these in Life OS → Paramètres → Synchronisation
 on every device you want synced.

 Verify HTTPS once DNS has propagated:
   curl https://$DOMAIN/api/health

═══════════════════════════════════════════════════════════
EOF
