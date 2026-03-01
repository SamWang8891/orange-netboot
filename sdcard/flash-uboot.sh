#!/bin/bash
# flash-uboot.sh — Write only U-Boot to an SD card (runs on HOST)
set -euo pipefail

[[ $# -lt 2 ]] && { echo "Usage: $0 <armbian-image.img> <sd-device>"; exit 1; }
[[ $EUID -ne 0 ]] && { echo "Error: Run as root"; exit 1; }

IMG="$1"
DEVICE="$2"

[[ ! -f "$IMG" ]] && { echo "Error: Image not found: $IMG"; exit 1; }
[[ ! -b "$DEVICE" ]] && { echo "Error: Not a block device: $DEVICE"; exit 1; }

echo "Writing U-Boot from $IMG to $DEVICE"
echo "WARNING: First ~2MB of $DEVICE will be overwritten."
read -rp "Continue? [y/N] " confirm
[[ "$confirm" != "y" && "$confirm" != "Y" ]] && exit 0

dd if="$IMG" of="$DEVICE" bs=1k skip=8 seek=8 count=2040 conv=notrunc status=progress
sync
echo "Done. SD card ready for netboot."
