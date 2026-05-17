#!/bin/bash
# Life OS sync — one-shot deployment on the qavonn VPS
# Assumes:
#   - Docker + docker compose installed
#   - n8n stack already running with Caddy container named "n8n-caddy-1"
#   - Caddyfile lives at ~/n8n/Caddyfile
#   - DNS A record for sync.qavonn.fr → 91.148.135.157 already created
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
TOKEN_FILE="$HERE/.token"
ENV_FILE="$HERE/.env"
CADDYFILE="$HOME/n8n/Caddyfile"
DOMAIN="sync.qavonn.fr"

# 1. Generate token (idempotent — keeps existing if present)
if [ ! -f "$TOKEN_FILE" ]; then
  openssl rand -hex 32 > "$TOKEN_FILE"
  chmod 600 "$TOKEN_FILE"
  echo "✓ Generated new sync token"
else
  echo "✓ Using existing sync token"
fi
TOKEN=$(cat "$TOKEN_FILE")

# 2. Write .env for docker compose
echo "SYNC_TOKEN=$TOKEN" > "$ENV_FILE"
chmod 600 "$ENV_FILE"

# 3. Append Caddyfile block if missing
if [ ! -f "$CADDYFILE" ]; then
  echo "✗ Caddyfile not found at $CADDYFILE — aborting"
  exit 1
fi
if ! grep -q "$DOMAIN" "$CADDYFILE"; then
  cat >> "$CADDYFILE" <<EOF

$DOMAIN {
  reverse_proxy lifeos-sync:3001
  header {
    X-Robots-Tag "noindex, nofollow"
  }
}
EOF
  echo "✓ Added $DOMAIN block to Caddyfile"
else
  echo "✓ $DOMAIN block already in Caddyfile"
fi

# 4. Build & start container
cd "$HERE"
docker compose up -d --build
echo "✓ lifeos-sync container running"

# 5. Reload Caddy to pick up new domain (issues SSL cert on first run)
docker exec n8n-caddy-1 caddy reload --config /etc/caddy/Caddyfile --adapter caddyfile
echo "✓ Caddy reloaded (SSL cert will be issued on first request)"

# 6. Final report
cat <<EOF

═══════════════════════════════════════════════════════════
 Life OS sync deployed
═══════════════════════════════════════════════════════════

 URL    https://$DOMAIN
 Token  $TOKEN

 Next: open Life OS → Paramètres → Sync
       paste URL and Token, save on every device

 Health check (no auth):
   curl https://$DOMAIN/api/health

═══════════════════════════════════════════════════════════
EOF
