# netboot-manager

Network boot manager for ARM boards (Orange Pi, NanoPi, etc.) with a web UI.

Boards boot from a **stock Armbian SD card** — no custom bootloader needed. U-Boot's built-in PXE boot finds your server via DHCP, downloads kernel + initrd + DTB via TFTP, and mounts the rootfs via NFS.

## Architecture

```
┌──────────────────┐         ┌──────────────┐         ┌──────────────────────┐
│ Orange Pi        │  DHCP   │ pfSense      │         │ Server (VM/host)     │
│                  │◄───────►│              │         │                      │
│ Stock Armbian SD │         │ TFTP server ─┼────────►│ Docker container     │
│ (unchanged)      │  TFTP   │ set to       │         │ ├─ TFTP (:69)        │
│                  │────────►│ server IP    │         │ └─ Web UI (:8080)    │
│ U-Boot PXE boot  │         └──────────────┘         │                      │
│ finds config by  │  NFS                             │ Host                 │
│ MAC address      │─────────────────────────────────►│ └─ NFS server        │
└──────────────────┘                                  │    └─ /srv/nfs/<node>│
                                                      └──────────────────────┘
```

## Quick Start

### 1. Server Setup

```bash
git clone https://github.com/SamWang8891/netboot-manager
cd netboot-manager

# Install NFS on the host
sudo ./server/setup-host.sh

# Start Docker (TFTP + Web UI)
docker compose up -d

# Open web UI
open http://YOUR_SERVER_IP:8080
```

### 2. Deploy a Node

```bash
# Deploy rootfs + kernel + DTB (run on host)
sudo ./server/deploy-rootfs.sh <armbian.img> <node-name>
```

### 3. Configure pfSense

Set **TFTP Server** to your server's IP in DHCP settings. The web UI shows exact instructions per node.

### 4. Boot

Flash a **stock Armbian image** to an SD card (normal `dd` or Etcher). No modifications needed — U-Boot's PXE boot will find the server automatically.

## How It Works

1. Board boots U-Boot from SD card
2. U-Boot gets IP + TFTP server from pfSense DHCP
3. U-Boot requests `pxelinux.cfg/01-<mac-address>` from TFTP
4. Config tells it which kernel, initrd, DTB, and NFS root to use
5. Kernel boots with NFS rootfs

Each board gets its own config by MAC address → completely independent rootfs per board.

## What Runs Where

| Component | Where | Purpose |
|-----------|-------|---------|
| TFTP | Docker (:69) | Serves PXE config, kernel, initrd, DTB |
| Web UI | Docker (:8080) | Manage nodes, view setup instructions |
| NFS | Host | Exports rootfs per node |
| DHCP | pfSense | Points boards to TFTP server |

## Creating Netboot SD Cards

You don't need a custom SD card! Just flash a **stock Armbian image** — U-Boot's PXE boot will find the TFTP server via DHCP automatically.

If you want a minimal SD card, use `make-netboot-sd.sh` (see `sdcard/README.md`).

## License

APACHE2
