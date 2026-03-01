#!/bin/bash
# make-netboot-sd.sh — Take an Armbian image and convert it to a netboot SD image
#
# Keeps U-Boot and partition layout intact, replaces boot.scr with a netboot
# version that does DHCP → TFTP → loads node-specific boot.scr from server.
#
# The resulting image is tiny — you can dd it to any SD card.
#
# Usage: ./make-netboot-sd.sh <input-armbian.img> [output.img]
set -euo pipefail

usage() {
    echo "Usage: $0 <armbian-image.img> [output-netboot.img]"
    echo ""
    echo "Takes a full Armbian image and produces a minimal netboot SD image."
    echo "The output image has U-Boot + a netboot boot.scr that loads"
    echo "everything else from the network via TFTP."
    echo ""
    echo "Examples:"
    echo "  $0 Armbian_bookworm_orangepione.img"
    echo "  $0 Armbian_bookworm_orangepione.img netboot-sd.img"
    exit 1
}

[[ $# -lt 1 ]] && usage

INPUT="$1"
[[ ! -f "$INPUT" ]] && { echo "Error: Image not found: $INPUT"; exit 1; }

# Handle .xz
if [[ "$INPUT" == *.xz ]]; then
    DECOMPRESSED="${INPUT%.xz}"
    if [[ ! -f "$DECOMPRESSED" ]]; then
        echo "Decompressing $INPUT..."
        xz -dk "$INPUT"
    fi
    INPUT="$DECOMPRESSED"
fi

BASENAME=$(basename "$INPUT" .img)
OUTPUT="${2:-${BASENAME}-netboot-sd.img}"

# Check for mkimage
if ! command -v mkimage &>/dev/null; then
    echo "Error: mkimage not found. Install u-boot-tools:"
    echo "  sudo apt-get install u-boot-tools"
    exit 1
fi

echo "=== Creating netboot SD image ==="
echo "Input:  $INPUT"
echo "Output: $OUTPUT"
echo ""

# 1. Create a small image — just need U-Boot (first 4MB) + boot partition (~16MB)
#    Total: 32MB is plenty
IMG_SIZE_MB=32
echo "[1/5] Creating ${IMG_SIZE_MB}MB image..."
dd if=/dev/zero of="$OUTPUT" bs=1M count=$IMG_SIZE_MB status=none

# 2. Copy U-Boot from the original image (first 4MB covers SPL + U-Boot proper)
echo "[2/5] Copying U-Boot from source image..."
dd if="$INPUT" of="$OUTPUT" bs=1k skip=8 seek=8 count=4088 conv=notrunc status=none

# 3. Create partition table + FAT partition
echo "[3/5] Creating boot partition..."
# Partition starts at 1MB (sector 2048), uses rest of image
cat <<EOF | sfdisk "$OUTPUT" --quiet 2>/dev/null
label: dos
start=2048, type=c
EOF

# Format the partition as FAT16
LOOP=$(losetup --find --show --partscan "$OUTPUT")
trap "umount /tmp/netboot-sd-mnt 2>/dev/null; losetup -d $LOOP 2>/dev/null; rm -rf /tmp/netboot-sd-mnt 2>/dev/null" EXIT

# Wait for partition to appear
sleep 1
if [[ ! -b "${LOOP}p1" ]]; then
    # Try partx (works in containers), fall back to partprobe, then losetup re-read
    partx -a "$LOOP" 2>/dev/null || partprobe "$LOOP" 2>/dev/null || losetup -P "$LOOP" 2>/dev/null
    sleep 1
fi

# If still no partition device, use kpartx
if [[ ! -b "${LOOP}p1" ]]; then
    kpartx -av "$LOOP" 2>/dev/null
    sleep 1
    # kpartx creates /dev/mapper/loopXp1
    LOOP_BASE=$(basename "$LOOP")
    PART_DEV="/dev/mapper/${LOOP_BASE}p1"
    if [[ -b "$PART_DEV" ]]; then
        KPARTX_USED=1
    else
        echo "Error: Could not create partition device for $OUTPUT"
        exit 1
    fi
fi

PART="${PART_DEV:-${LOOP}p1}"
mkfs.vfat -F 16 -n NETBOOT "$PART" >/dev/null

# 4. Generate netboot boot.scr
echo "[4/5] Writing netboot boot.scr..."
TMPDIR=$(mktemp -d)
cat > "$TMPDIR/boot.cmd" << 'BOOTCMD'
echo ""
echo "==============================="
echo "  netboot-manager SD loader"
echo "==============================="
echo ""

# Get IP and boot info from DHCP (pfSense)
# pfSense provides: IP, next-server (TFTP), filename (node/boot.scr)
echo "Getting network config from DHCP..."
dhcp

if test -n "$filename"; then
    echo "DHCP filename: ${filename}"
    echo "TFTP server:   ${serverip}"
    echo ""
    echo "Loading boot script from TFTP..."
    tftp 0x44000000 ${filename}
    if test $? -eq 0; then
        echo "Running node boot script..."
        source 0x44000000
    else
        echo "ERROR: Failed to load ${filename} from ${serverip}"
    fi
else
    echo "WARNING: DHCP did not provide a boot filename."
    echo "Check pfSense DHCP static mapping for this board's MAC."
    echo ""
    echo "Expected: filename = <node-name>/boot.scr"
fi

echo ""
echo "Network boot failed. Dropping to U-Boot shell."
BOOTCMD

mkimage -C none -A arm -T script -d "$TMPDIR/boot.cmd" "$TMPDIR/boot.scr" >/dev/null

# Mount and copy
mkdir -p /tmp/netboot-sd-mnt
mount "$PART" /tmp/netboot-sd-mnt
cp "$TMPDIR/boot.scr" /tmp/netboot-sd-mnt/
cp "$TMPDIR/boot.cmd" /tmp/netboot-sd-mnt/

# Also copy original boot files as backup
echo "  (including boot.cmd source for reference)"
sync
umount /tmp/netboot-sd-mnt

rm -rf "$TMPDIR"

# 5. Done
if [[ "${KPARTX_USED:-}" == "1" ]]; then
    kpartx -d "$LOOP" 2>/dev/null
fi
losetup -d "$LOOP"
trap - EXIT

SIZE=$(stat -c%s "$OUTPUT")
echo ""
echo "[5/5] Done!"
echo ""
echo "Output: $OUTPUT ($(( SIZE / 1024 / 1024 )) MB)"
echo ""
echo "Flash to SD card:"
echo "  sudo dd if=$OUTPUT of=/dev/sdX bs=4M status=progress"
echo "  # or use balenaEtcher"
echo ""
echo "The SD card will:"
echo "  1. Boot U-Boot"
echo "  2. Run boot.scr → DHCP → get TFTP server + filename from pfSense"
echo "  3. Download <node>/boot.scr from TFTP server"
echo "  4. That script loads kernel + DTB + mounts NFS rootfs"
