#!/bin/bash
# extract-boot-files.sh — Extract kernel + DTB from Armbian image
# Usage: extract-boot-files.sh <image.img> <output-dir> <dtb-name>
set -e

IMG="$1"
OUTDIR="$2"
DTB_NAME="$3"

[ -z "$IMG" ] || [ -z "$OUTDIR" ] && { echo "Usage: $0 <image> <outdir> [dtb-name]"; exit 1; }
[ ! -f "$IMG" ] && { echo "Error: $IMG not found"; exit 1; }

TMPDIR=$(mktemp -d)
trap "umount $TMPDIR 2>/dev/null; losetup -D 2>/dev/null; rm -rf $TMPDIR" EXIT

LOOP=$(losetup --find --show --partscan "$IMG")
# Wait for partition device to appear
sleep 1

mount "${LOOP}p1" "$TMPDIR"

# Kernel
if [ -f "$TMPDIR/boot/zImage" ]; then
    cp "$TMPDIR/boot/zImage" "$OUTDIR/zImage"
elif ls "$TMPDIR/boot/vmlinuz-"* >/dev/null 2>&1; then
    cp "$(ls "$TMPDIR/boot/vmlinuz-"* | head -1)" "$OUTDIR/zImage"
else
    echo "No kernel found"
    exit 1
fi
echo "Kernel: OK"

# DTB
if [ -n "$DTB_NAME" ]; then
    DTB=$(find "$TMPDIR/boot/dtb" -name "$DTB_NAME" 2>/dev/null | head -1)
    [ -n "$DTB" ] && cp "$DTB" "$OUTDIR/$DTB_NAME" && echo "DTB: $DTB_NAME"
fi

# Copy all H3/H2+ DTBs
for dtb in "$TMPDIR"/boot/dtb/sun8i-h*.dtb; do
    [ -f "$dtb" ] && cp "$dtb" "$OUTDIR/" 2>/dev/null
done

echo "Done"
