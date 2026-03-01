# Netboot SD Card

## How It Works

```
Normal Armbian SD:
  U-Boot → boot.scr → load kernel from SD → boot from SD rootfs

Netboot SD:
  U-Boot → boot.scr → DHCP (pfSense) → TFTP <node>/boot.scr → kernel via TFTP → NFS rootfs
```

The `make-netboot-sd.sh` script takes a full Armbian image and produces a tiny (~32MB) image that only contains:
- U-Boot bootloader (from the original image)
- A `boot.scr` that does DHCP → TFTP chain-load

## Usage (Linux)

```bash
sudo apt install u-boot-tools dosfstools
sudo ./make-netboot-sd.sh Armbian_bookworm_orangepione.img
# → Armbian_bookworm_orangepione-netboot-sd.img (32MB)

sudo dd if=*-netboot-sd.img of=/dev/sdX bs=4M status=progress
```

## Usage (macOS / Windows — via Docker)

If you're not on Linux, use Docker to run the script. The image needs loop device access, so we use `--privileged`:

```bash
# From the netboot-manager repo root:

# Build the helper image (one-time)
docker build -t netboot-tools -f sdcard/Dockerfile.tools .

# Place your Armbian .img in the current directory, then:
docker run --rm --privileged \
  -v "$(pwd)":/work \
  netboot-tools \
  /work/sdcard/make-netboot-sd.sh /work/Armbian_bookworm_orangepione.img /work/netboot-sd.img

# Output: netboot-sd.img in your current directory
# Flash with balenaEtcher or dd
```

### What `--privileged` does

The script needs loop devices (`losetup`) and mount to create the SD image. This is safe — it only touches the image file, not your host disks. If you're uncomfortable with `--privileged`, run on a Linux VM instead.

## Boot Chain

1. **SoC BROM** reads SPL from SD card (sector 16)
2. **SPL** loads U-Boot from SD card (sector 80)
3. **U-Boot** finds `boot.scr` on the FAT partition
4. **boot.scr** runs `dhcp` → pfSense gives IP + TFTP server + filename
5. **boot.scr** TFTPs `<node>/boot.scr` from the server
6. **Node boot.scr** loads kernel + DTB via TFTP, boots with NFS root

## One SD Per Board Type

U-Boot is board-specific, so you need one SD image per board **type** (One vs PC vs Lite). But all boards of the same type share the same SD image — node identity comes from pfSense's MAC → filename mapping.
