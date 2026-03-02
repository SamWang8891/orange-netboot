#!/bin/bash
# setup-host.sh — Install NFS server on the host (TFTP handled by Docker)
set -euo pipefail

echo "=== orange-netboot host setup ==="
echo "    (NFS server only — TFTP + web UI run in Docker)"

[[ $EUID -ne 0 ]] && { echo "Error: Run as root"; exit 1; }

# Install NFS
echo "[1/4] Installing NFS server..."
apt-get update
apt-get install -y nfs-kernel-server

# Create NFS directory
echo "[2/4] Creating /srv/nfs/..."
mkdir -p /srv/nfs

# Firewall
echo "[3/4] Configuring firewall..."
if command -v ufw &>/dev/null; then
    ufw allow 2049/tcp
    ufw allow 2049/udp
fi

systemctl enable nfs-kernel-server
systemctl restart nfs-kernel-server

# ── netboot-agent ────────────────────────────────────────────────────

REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"

echo "[4/4] Installing netboot-agent..."

# Ensure python3 is available
if ! command -v python3 &>/dev/null; then
    apt-get install -y python3
fi

# Copy agent script
cp "$REPO_DIR/server/netboot-agent.py" /usr/local/bin/netboot-agent
chmod 755 /usr/local/bin/netboot-agent

# Create data dir and touch token file so Docker bind-mount works before first run
mkdir -p "$REPO_DIR/data"
touch "$REPO_DIR/data/agent.token"
chmod 600 "$REPO_DIR/data/agent.token"

# Write systemd unit (bake in REPO_DIR)
cat > /etc/systemd/system/netboot-agent.service << EOF
[Unit]
Description=netboot privileged agent
After=network.target

[Service]
Type=simple
ExecStart=/usr/local/bin/netboot-agent --repo-dir ${REPO_DIR} --host 127.0.0.1 --port 7777
Restart=always
User=root
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable --now netboot-agent

echo ""
echo "=== Host setup complete ==="
echo ""
echo "netboot-agent status: $(systemctl is-active netboot-agent)"
echo "Agent token:          $REPO_DIR/data/agent.token"
echo ""
echo "Next: docker compose up -d"
echo "Then deploy via the web UI Deploy button, or on the host:"
echo "      sudo ./server/deploy-rootfs.sh <armbian.img> <node-name>"
