#!/bin/bash
set -euo pipefail

# ── 1. Host setup ─────────────────────────────────────────────────────────────
echo "==> Running setup-host.sh..."
sudo ./server/setup-host.sh

# ── 2. Detect server IP ───────────────────────────────────────────────────────
echo "==> Detecting server IP..."
SERVER_IP=""
while IFS= read -r ip; do
    if [[ "$ip" != 127.* && "$ip" != 172.* ]]; then
        SERVER_IP="$ip"
        break
    fi
done < <(hostname -I | tr ' ' '\n')

if [[ -z "$SERVER_IP" ]]; then
    echo "ERROR: Could not detect a non-loopback, non-Docker IP. Set SERVER_IP manually in .env." >&2
    exit 1
fi

echo "==> Server IP: $SERVER_IP"
echo "SERVER_IP=$SERVER_IP" > .env

# ── 3. Force rebuild + start ──────────────────────────────────────────────────
echo "==> Building and starting containers..."
docker compose build --no-cache
docker compose up -d

echo ""
echo "Done. Web UI: http://${SERVER_IP}:8080"
