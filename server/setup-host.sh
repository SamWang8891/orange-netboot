#!/bin/bash
# setup-host.sh — Install NFS server on the host (TFTP handled by Docker)
set -euo pipefail

echo "=== netboot-manager host setup ==="
echo "    (NFS server only — TFTP + web UI run in Docker)"

[[ $EUID -ne 0 ]] && { echo "Error: Run as root"; exit 1; }

# Install NFS
echo "[1/3] Installing NFS server..."
apt-get update
apt-get install -y nfs-kernel-server

# Create NFS directory
echo "[2/3] Creating /srv/nfs/..."
mkdir -p /srv/nfs

# Firewall
echo "[3/3] Configuring firewall..."
if command -v ufw &>/dev/null; then
    ufw allow 2049/tcp
    ufw allow 2049/udp
fi

systemctl enable nfs-kernel-server
systemctl restart nfs-kernel-server

echo ""
echo "=== Host setup complete ==="
echo ""
echo "Next: docker compose up -d"
echo "Then: sudo ./server/deploy-rootfs.sh <armbian.img> <node-name>"
