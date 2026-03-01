#!/bin/bash
# deploy-rootfs.sh — Deploy an Armbian image as a netboot node
#
# This script does everything needed on the HOST:
#   1. Extracts rootfs to /srv/nfs/<node>/
#   2. Copies kernel + initrd + DTBs to data/tftp/<node>/
#   3. Creates PXE boot config at data/tftp/pxelinux.cfg/01-<mac>
#   4. Patches rootfs for NFS boot
#   5. Adds NFS export
#
# Usage: sudo ./server/deploy-rootfs.sh <armbian.img> <node-name> [mac] [board-dtb]
set -euo pipefail

NFS_DIR="/srv/nfs"

usage() {
    echo "Usage: $0 <armbian-image.img> <node-name> [mac-address] [board-dtb]"
    echo ""
    echo "  node-name:   Unique name (e.g. worker1, sensor1)"
    echo "  mac-address: Board MAC for PXE config (e.g. 02:81:d7:f0:44:df)"
    echo "  board-dtb:   DTB filename (default: sun8i-h3-orangepi-one.dtb)"
    echo ""
    echo "Examples:"
    echo "  $0 Armbian_bookworm.img worker1"
    echo "  $0 Armbian_bookworm.img worker1 02:81:d7:f0:44:df"
    echo "  $0 Armbian_bookworm.img worker1 02:81:d7:f0:44:df sun8i-h3-orangepi-pc.dtb"
    exit 1
}

[[ $# -lt 2 ]] && usage
[[ $EUID -ne 0 ]] && { echo "Error: Run as root"; exit 1; }

for cmd in kpartx rsync mkimage; do
    command -v "$cmd" &>/dev/null || { echo "Error: $cmd not found. Install with: apt install kpartx rsync u-boot-tools"; exit 1; }
done

IMG="$1"
NODE="$2"
MAC="${3:-}"
DTB_NAME="${4:-sun8i-h3-orangepi-one.dtb}"
NODE_DIR="$NFS_DIR/$NODE"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_DIR="$(dirname "$SCRIPT_DIR")"
TFTP_NODE="$REPO_DIR/data/tftp/$NODE"

[[ ! -f "$IMG" ]] && { echo "Error: Image not found: $IMG"; exit 1; }

# Handle .xz
if [[ "$IMG" == *.xz ]]; then
    DECOMPRESSED="${IMG%.xz}"
    if [[ ! -f "$DECOMPRESSED" ]]; then
        echo "Decompressing $IMG..."
        xz -dk "$IMG"
    fi
    IMG="$DECOMPRESSED"
fi

# Detect server IP
SERVER_IP=$(grep -oP 'SERVER_IP=\K.*' "$REPO_DIR/.env" 2>/dev/null || hostname -I | awk '{print $1}')

echo "=== Deploying node: $NODE ==="
echo "    Image:  $IMG"
echo "    DTB:    $DTB_NAME"
echo "    MAC:    ${MAC:-not set (set later via web UI)}"
echo "    Server: $SERVER_IP"
echo ""

# Set up loop device + kpartx
LOOP=$(losetup --find --show "$IMG")

BOOT_MNT=$(mktemp -d)
ROOT_MNT=$(mktemp -d)

cleanup() {
    umount "$BOOT_MNT" 2>/dev/null || true
    umount "$ROOT_MNT" 2>/dev/null || true
    kpartx -d "$LOOP" 2>/dev/null || true
    losetup -d "$LOOP" 2>/dev/null || true
    rmdir "$BOOT_MNT" "$ROOT_MNT" 2>/dev/null || true
}
trap cleanup EXIT

kpartx -av "$LOOP"
sleep 1

LOOP_BASE=$(basename "$LOOP")

# Detect partitions
echo "[1/6] Scanning partitions..."
ROOTFS_PART=""
BOOT_PART=""

for p in /dev/mapper/${LOOP_BASE}p*; do
    [[ ! -b "$p" ]] && continue
    TMP=$(mktemp -d)
    if mount -o ro "$p" "$TMP" 2>/dev/null; then
        if [[ -d "$TMP/etc" && -d "$TMP/usr" ]]; then
            ROOTFS_PART="$p"
            echo "  $p → rootfs"
        elif [[ -f "$TMP/uInitrd" || -f "$TMP/zImage" ]] || ls "$TMP"/vmlinuz-* &>/dev/null 2>&1; then
            BOOT_PART="$p"
            echo "  $p → boot"
        else
            echo "  $p → other"
        fi
        umount "$TMP"
    fi
    rmdir "$TMP" 2>/dev/null || true
done

[[ -z "$ROOTFS_PART" ]] && { echo "Error: Could not find rootfs partition"; exit 1; }

mount -o ro "$ROOTFS_PART" "$ROOT_MNT"
[[ -n "$BOOT_PART" ]] && mount -o ro "$BOOT_PART" "$BOOT_MNT"

# Copy rootfs
echo "[2/6] Copying rootfs to $NODE_DIR..."
mkdir -p "$NODE_DIR"
rsync -a --info=progress2 --delete "$ROOT_MNT/" "$NODE_DIR/"

# Merge boot partition
if [[ -n "$BOOT_PART" ]]; then
    echo "  Merging boot partition..."
    mkdir -p "$NODE_DIR/boot"
    rsync -a "$BOOT_MNT/" "$NODE_DIR/boot/"
fi
echo "  Size: $(du -sh "$NODE_DIR" | cut -f1)"

# Copy kernel + initrd + DTB to TFTP
echo "[3/6] Copying boot files to TFTP..."
mkdir -p "$TFTP_NODE"

# Kernel
for kpath in "$NODE_DIR/boot/zImage" "$NODE_DIR/boot"/vmlinuz-*; do
    if [[ -f "$kpath" ]]; then
        cp "$kpath" "$TFTP_NODE/zImage"
        echo "  Kernel: $(basename "$kpath") → zImage"
        break
    fi
done

# Initrd (required for NFS boot)
for ipath in "$NODE_DIR/boot/uInitrd" "$NODE_DIR/boot"/initrd.img-*; do
    if [[ -f "$ipath" ]]; then
        cp "$ipath" "$TFTP_NODE/uInitrd"
        echo "  Initrd: $(basename "$ipath") → uInitrd"
        break
    fi
done

# DTBs
DTB_COUNT=0
for dtbdir in "$NODE_DIR/boot/dtb" "$NODE_DIR/boot/dtb/allwinner" "$NODE_DIR/usr/lib/linux-image-"*; do
    [[ ! -d "$dtbdir" ]] && continue
    for dtb in "$dtbdir"/sun8i-h*.dtb; do
        [[ -f "$dtb" ]] || continue
        cp "$dtb" "$TFTP_NODE/"
        DTB_COUNT=$((DTB_COUNT + 1))
    done
    [[ $DTB_COUNT -gt 0 ]] && break
done
echo "  DTBs: $DTB_COUNT files"

# Create PXE boot config
echo "[4/6] Creating PXE boot config..."
mkdir -p "$REPO_DIR/data/tftp/pxelinux.cfg"

PXE_CONFIG="default netboot
label netboot
  kernel $NODE/zImage
  initrd $NODE/uInitrd
  fdt $NODE/$DTB_NAME
  append root=/dev/nfs nfsroot=$SERVER_IP:$NODE_DIR,vers=3,tcp rw ip=dhcp console=ttyS0,115200 console=tty1 earlyprintk panic=10"

# Per-MAC config (highest priority — U-Boot requests this first)
if [[ -n "$MAC" ]]; then
    MAC_DASHES=$(echo "$MAC" | tr ':' '-')
    echo "$PXE_CONFIG" > "$REPO_DIR/data/tftp/pxelinux.cfg/01-$MAC_DASHES"
    echo "  PXE config: pxelinux.cfg/01-$MAC_DASHES"
fi

# Also write as default fallback (for when MAC is not set)
echo "$PXE_CONFIG" > "$REPO_DIR/data/tftp/pxelinux.cfg/default"
echo "  Fallback:   pxelinux.cfg/default"

# Also create boot.scr.uimg (U-Boot tries this too)
cat > "$TFTP_NODE/boot.cmd" << EOF
echo "=== netboot: $NODE ==="
dhcp
setenv bootargs "root=/dev/nfs nfsroot=\${serverip}:$NODE_DIR,vers=3,tcp rw ip=dhcp console=ttyS0,115200 console=tty1 earlyprintk panic=10"
tftp 0x46000000 $NODE/zImage
tftp 0x44000000 $NODE/uInitrd
tftp 0x49000000 $NODE/$DTB_NAME
bootz 0x46000000 0x44000000 0x49000000
EOF
mkimage -C none -A arm -T script -d "$TFTP_NODE/boot.cmd" "$REPO_DIR/data/tftp/boot.scr.uimg" >/dev/null 2>&1 || true

# Patch rootfs for NFS boot
echo "[5/6] Patching rootfs for NFS boot..."
[[ -f "$NODE_DIR/etc/fstab" ]] && cp "$NODE_DIR/etc/fstab" "$NODE_DIR/etc/fstab.bak"
cat > "$NODE_DIR/etc/fstab" << 'EOF'
# NFS boot — local mounts only
proc            /proc   proc    defaults        0 0
tmpfs           /tmp    tmpfs   defaults,nosuid 0 0
tmpfs           /var/log tmpfs  defaults,nosuid,size=50M 0 0
EOF

echo "$NODE" > "$NODE_DIR/etc/hostname"
sed -i "s/127.0.1.1.*/127.0.1.1\t$NODE/" "$NODE_DIR/etc/hosts" 2>/dev/null || true

for svc in armbian-firstrun armbian-resize-filesystem; do
    rm -f "$NODE_DIR/etc/systemd/system/multi-user.target.wants/${svc}.service" 2>/dev/null
done

ssh-keygen -t ed25519 -f "$NODE_DIR/etc/ssh/ssh_host_ed25519_key" -N "" -q -C "$NODE" 2>/dev/null || true
ssh-keygen -t rsa -b 2048 -f "$NODE_DIR/etc/ssh/ssh_host_rsa_key" -N "" -q -C "$NODE" 2>/dev/null || true

# NFS export
echo "[6/6] Adding NFS export..."
EXPORT_LINE="$NODE_DIR  *(rw,sync,no_subtree_check,no_root_squash)"
if ! grep -qF "$NODE_DIR" /etc/exports 2>/dev/null; then
    echo "$EXPORT_LINE" >> /etc/exports
fi
exportfs -ra

echo ""
echo "========================================"
echo "  Node '$NODE' deployed successfully!"
echo "========================================"
echo ""
echo "  Rootfs:  $NODE_DIR ($(du -sh "$NODE_DIR" | cut -f1))"
echo "  TFTP:    $TFTP_NODE/"
echo "  Kernel:  $(ls "$TFTP_NODE/zImage" 2>/dev/null && echo '✓' || echo '✗ MISSING')"
echo "  Initrd:  $(ls "$TFTP_NODE/uInitrd" 2>/dev/null && echo '✓' || echo '✗ MISSING')"
echo "  DTB:     $DTB_NAME"
if [[ -n "$MAC" ]]; then
    echo "  PXE:     pxelinux.cfg/01-$(echo "$MAC" | tr ':' '-')"
fi
echo ""
echo "Next steps:"
echo "  1. Open web UI: http://$SERVER_IP:8080/node/$NODE"
echo "  2. Set pfSense DHCP 'TFTP Server' to: $SERVER_IP"
echo "  3. Flash stock Armbian to SD card and boot"
if [[ -z "$MAC" ]]; then
    echo "  4. Find MAC in pfSense DHCP leases, then run:"
    echo "     sudo $0 $IMG $NODE <mac-address> $DTB_NAME"
fi
