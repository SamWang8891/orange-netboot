# orange-netboot

Network boot manager for ARM boards (Orange Pi, NanoPi, etc.) with a web UI.

Boards boot from a **stock Armbian SD card** — no custom bootloader needed. U-Boot's built-in PXE boot finds your server via DHCP, downloads kernel + initrd + DTB via TFTP, and mounts the rootfs via NFS.

## Architecture

```
┌──────────────────┐         ┌──────────────┐         ┌──────────────────────────┐
│ Orange Pi        │  DHCP   │ pfSense      │         │ Server (VM/host)         │
│                  │◄───────►│              │         │                          │
│ Stock Armbian SD │         │ TFTP server ─┼────────►│ Docker container         │
│ (unchanged)      │  TFTP   │ set to       │         │ ├─ TFTP (:69)            │
│                  │────────►│ server IP    │         │ └─ Web UI (:8080)        │
│ U-Boot PXE boot  │         └──────────────┘         │                          │
│ finds config by  │  NFS                             │ Host                     │
│ MAC address      │─────────────────────────────────►│ ├─ NFS server            │
└──────────────────┘                                  │ │   └─ /srv/nfs/<node>   │
                                                      │ └─ netboot-agent (:7777) │
                                                      └──────────────────────────┘
```

## Quick Start

### 1. Server Setup

```bash
git clone https://github.com/SamWang8891/orange-netboot
cd orange-netboot

# Install NFS + netboot-agent on the host (one-time)
sudo ./server/setup-host.sh

# Start Docker (TFTP + Web UI)
docker compose up -d

# Open web UI
open http://YOUR_SERVER_IP:8080
```

### 2. Upload an Image

Go to **Images** and upload an Armbian `.img` or `.img.xz` file.

### 3. Add and Deploy a Node

Go to **Add Node**, fill in the name and board type, then open the node's page and click **Deploy**. Select the image and watch the live output — rootfs extraction, NFS export, and TFTP file setup all happen automatically with no SSH required.

### 4. Configure pfSense

Set **TFTP Server** to your server's IP in DHCP settings. The web UI shows exact instructions per node.

### 5. Boot

Flash a **stock Armbian image** to an SD card (`dd` or Etcher). No modifications needed — U-Boot's PXE boot will find the server automatically.

## How It Works

1. Board boots U-Boot from SD card
2. U-Boot gets IP + TFTP server from DHCP
3. U-Boot requests `pxelinux.cfg/01-<mac-address>` from TFTP
4. Config points to the node's kernel, initrd, DTB, and NFS root
5. Kernel boots and mounts the NFS rootfs

Each board gets its own config by MAC address — completely independent rootfs per board.

## What Runs Where

| Component | Where | Purpose |
|---|---|---|
| TFTP | Docker (:69) | Serves PXE config, kernel, initrd, DTB |
| Web UI | Docker (:8080) | Manage nodes, upload images, deploy, terminal |
| NFS | Host | Exports rootfs per node |
| netboot-agent | Host (:7777) | Executes privileged operations on behalf of the web UI |
| DHCP | pfSense | Points boards to TFTP server |

## netboot-agent

`setup-host.sh` installs a small stdlib-only HTTP daemon (`netboot-agent`) that runs as root on the host via systemd. The web UI calls it to perform operations that require host-level access.

- Listens on `0.0.0.0:7777` — accessible from Docker containers via `host.docker.internal`; protected by token auth
- All requests authenticated with a Bearer token in `data/agent.token` (chmod 600, bind-mounted read-only into Docker)
- Streams `deploy-rootfs.sh` and `setup-host.sh` output as Server-Sent Events for live progress in the browser
- Handles rootfs removal (`rm -rf /srv/nfs/<node> && exportfs -ra`) synchronously

**Operations available from the web UI:**

| Action | Where |
|---|---|
| Deploy / re-deploy rootfs + boot files | Node page → Deploy button |
| Remove NFS rootfs | Node page → Host Commands → Run |
| Re-run setup-host.sh | Setup page (when agent is running) |
| Remove node + rootfs | Node page → Remove button |

## Web Terminal

The node detail page has a built-in SSH terminal. Credentials are exchanged for a short-lived session token before the WebSocket connects — passwords never appear in server logs or browser history.

## Creating Netboot SD Cards

You don't need a custom SD card — just flash a **stock Armbian image**. U-Boot's PXE boot finds the TFTP server automatically via DHCP.

For a minimal SD card (U-Boot only), use `make-netboot-sd.sh` (see `sdcard/README.md`).

## License

APACHE2
