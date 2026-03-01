#!/bin/sh
set -e

echo "=== netboot-manager ==="
echo "TFTP dir: ${TFTP_DIR:-/srv/tftp}"
echo "NFS dir:  ${NFS_DIR:-/srv/nfs}"

# Start TFTP server in background
echo "Starting TFTP server on :69..."
in.tftpd -L -s "${TFTP_DIR:-/srv/tftp}" -v &

# Start web UI
echo "Starting web UI on :8080..."
exec python3 /app/app.py --host 0.0.0.0 --port 8080
