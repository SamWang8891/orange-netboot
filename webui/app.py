#!/usr/bin/env python3
"""netboot-manager web UI — PXE/TFTP + NFS node management"""
import json
import os
import paramiko
import shutil
import subprocess
import threading
import time
from datetime import datetime
from flask import (
    Flask, render_template, request, redirect, url_for,
    flash, jsonify, send_file,
)
from flask_sock import Sock
from pathlib import Path

app = Flask(__name__)
app.secret_key = os.environ.get("SECRET_KEY", os.urandom(24))
app.config["MAX_CONTENT_LENGTH"] = 8 * 1024 * 1024 * 1024  # 8GB
sock = Sock(app)

TFTP_DIR = Path(os.environ.get("TFTP_DIR", "/srv/tftp"))
NFS_DIR = Path(os.environ.get("NFS_DIR", "/srv/nfs"))
UPLOAD_DIR = Path(os.environ.get("UPLOAD_DIR", "/uploads"))
DB_DIR = Path(os.environ.get("DB_DIR", "/db"))
SERVER_IP = os.environ.get("SERVER_IP", "")

BOARD_TYPES = {
    "orangepi-one": {"dtb": "sun8i-h3-orangepi-one.dtb", "soc": "H3"},
    "orangepi-pc": {"dtb": "sun8i-h3-orangepi-pc.dtb", "soc": "H3"},
    "orangepi-lite": {"dtb": "sun8i-h3-orangepi-lite.dtb", "soc": "H3"},
    "orangepi-plus": {"dtb": "sun8i-h3-orangepi-plus.dtb", "soc": "H3"},
    "orangepi-plus2e": {"dtb": "sun8i-h3-orangepi-plus2e.dtb", "soc": "H3"},
    "orangepi-zero": {"dtb": "sun8i-h2-plus-orangepi-zero.dtb", "soc": "H2+"},
    "nanopi-neo": {"dtb": "sun8i-h3-nanopi-neo.dtb", "soc": "H3"},
    "custom": {"dtb": "", "soc": "?"},
}


def db_path():
    return DB_DIR / "nodes.json"


def load_nodes_db():
    p = db_path()
    return json.loads(p.read_text()) if p.exists() else {}


def save_nodes_db(data):
    DB_DIR.mkdir(parents=True, exist_ok=True)
    db_path().write_text(json.dumps(data, indent=2))


def get_server_ip():
    if SERVER_IP:
        return SERVER_IP
    try:
        result = subprocess.run(["hostname", "-I"], capture_output=True, text=True, timeout=5)
        ips = result.stdout.strip().split() if result.returncode == 0 else []
        for ip in ips:
            if not ip.startswith("172.") and not ip.startswith("127."):
                return ip
        return ips[0] if ips else "YOUR_SERVER_IP"
    except Exception:
        return "YOUR_SERVER_IP"


def get_nodes():
    db = load_nodes_db()
    nodes = []
    all_names = set(db.keys())
    if NFS_DIR.exists():
        all_names.update(d.name for d in NFS_DIR.iterdir() if d.is_dir())
    if TFTP_DIR.exists():
        all_names.update(
            d.name for d in TFTP_DIR.iterdir()
            if d.is_dir() and d.name != "pxelinux.cfg"
        )

    for name in sorted(all_names):
        info = db.get(name, {})
        node = {
            "name": name,
            "board_type": info.get("board_type", "unknown"),
            "mac": info.get("mac", ""),
            "ip": info.get("ip", ""),
            "notes": info.get("notes", ""),
            "created": info.get("created", ""),
        }
        tftp_node = TFTP_DIR / name
        node["has_kernel"] = (tftp_node / "zImage").exists()
        node["has_initrd"] = (tftp_node / "uInitrd").exists()

        # DTB — show the one matching board type
        board_dtb = BOARD_TYPES.get(info.get("board_type", ""), {}).get("dtb", "")
        dtbs = list(tftp_node.glob("*.dtb")) if tftp_node.exists() else []
        matching = [d for d in dtbs if d.name == board_dtb]
        node["dtb"] = matching[0].name if matching else (dtbs[0].name if dtbs else "none")
        node["has_dtb"] = len(dtbs) > 0

        # PXE config
        mac = info.get("mac", "")
        if mac:
            mac_dashes = mac.replace(":", "-")
            node["has_pxe"] = (TFTP_DIR / "pxelinux.cfg" / f"01-{mac_dashes}").exists()
        else:
            node["has_pxe"] = False

        # NFS
        nfs_node = NFS_DIR / name
        node["has_rootfs"] = nfs_node.exists() and (nfs_node / "etc").exists()

        if node["has_rootfs"]:
            try:
                result = subprocess.run(
                    ["du", "-sh", str(nfs_node)], capture_output=True, text=True, timeout=30
                )
                node["size"] = result.stdout.split()[0] if result.returncode == 0 else "?"
            except Exception:
                node["size"] = "?"
        else:
            node["size"] = "-"

        hostname_file = nfs_node / "etc" / "hostname"
        node["hostname"] = hostname_file.read_text().strip() if hostname_file.exists() else name

        boot_cmd = tftp_node / "boot.cmd"
        node["boot_cmd"] = boot_cmd.read_text() if boot_cmd.exists() else None

        # PXE config content
        if mac:
            pxe_file = TFTP_DIR / "pxelinux.cfg" / f"01-{mac.replace(':', '-')}"
            node["pxe_config"] = pxe_file.read_text() if pxe_file.exists() else None
        else:
            node["pxe_config"] = None

        nodes.append(node)
    return nodes


def get_images(include_netboot=False):
    UPLOAD_DIR.mkdir(parents=True, exist_ok=True)
    images = sorted(UPLOAD_DIR.glob("*.img")) + sorted(UPLOAD_DIR.glob("*.img.xz"))
    if not include_netboot:
        images = [i for i in images if "-netboot-sd" not in i.name]
    return images


def generate_pxe_config(node_name, dtb_name, server_ip, nfs_path):
    return f"""default netboot
label netboot
  kernel {node_name}/zImage
  initrd {node_name}/uInitrd
  fdt {node_name}/{dtb_name}
  append root=/dev/nfs nfsroot={server_ip}:{nfs_path},vers=3,tcp rw ip=dhcp console=ttyS0,115200 console=tty1 earlyprintk panic=10"""


# ── Routes ──────────────────────────────────────────────────────────

@app.route("/")
def index():
    return render_template("index.html", nodes=get_nodes(), server_ip=get_server_ip())


@app.route("/setup")
def setup():
    return render_template("setup.html", server_ip=get_server_ip())


@app.route("/deploy", methods=["GET", "POST"])
def deploy():
    if request.method == "GET":
        return render_template("deploy.html", images=get_images(), board_types=BOARD_TYPES)

    node_name = request.form.get("node_name", "").strip()
    board_type = request.form.get("board_type", "orangepi-one")
    mac = request.form.get("mac", "").strip().lower()
    ip = request.form.get("ip", "").strip()
    notes = request.form.get("notes", "").strip()

    if not node_name or not all(c.isalnum() or c in "-_" for c in node_name):
        flash("Node name required (alphanumeric, hyphens, underscores).", "error")
        return redirect(url_for("deploy"))

    board_info = BOARD_TYPES.get(board_type, BOARD_TYPES["custom"])
    dtb_name = board_info["dtb"] or request.form.get("custom_dtb", "sun8i-h3-orangepi-one.dtb")
    nfs_path = f"/srv/nfs/{node_name}"
    server_ip = get_server_ip()

    # Create PXE config if MAC is provided
    if mac:
        pxe_dir = TFTP_DIR / "pxelinux.cfg"
        pxe_dir.mkdir(parents=True, exist_ok=True)
        pxe_content = generate_pxe_config(node_name, dtb_name, server_ip, nfs_path)
        mac_dashes = mac.replace(":", "-")
        (pxe_dir / f"01-{mac_dashes}").write_text(pxe_content)
        flash(f"PXE config created: pxelinux.cfg/01-{mac_dashes}", "success")

    # Save to DB
    db = load_nodes_db()
    db[node_name] = {
        "board_type": board_type,
        "dtb": dtb_name,
        "mac": mac,
        "ip": ip,
        "notes": notes,
        "created": datetime.now().isoformat(),
    }
    save_nodes_db(db)

    flash(f"Node '{node_name}' registered.", "success")

    # Check what's missing
    tftp_node = TFTP_DIR / node_name
    nfs_node = NFS_DIR / node_name
    missing = []
    if not (tftp_node / "zImage").exists():
        missing.append("kernel")
    if not (tftp_node / "uInitrd").exists():
        missing.append("initrd")
    if not (nfs_node / "etc").exists():
        missing.append("rootfs")

    if missing:
        flash(
            f"Missing: {', '.join(missing)}. Run on the host:\n"
            f"sudo ./server/deploy-rootfs.sh <armbian.img> {node_name}"
            + (f" {mac}" if mac else "") + f" {dtb_name}",
            "warning",
        )

    return redirect(url_for("node_detail", name=node_name))


@app.route("/upload", methods=["POST"])
def upload():
    if "image" not in request.files:
        return jsonify({"error": "No file"}), 400
    f = request.files["image"]
    if not f.filename:
        return jsonify({"error": "No filename"}), 400
    UPLOAD_DIR.mkdir(parents=True, exist_ok=True)
    dest = UPLOAD_DIR / f.filename
    f.save(str(dest))
    size_mb = dest.stat().st_size // 1024 // 1024
    if request.headers.get("X-Requested-With") == "XMLHttpRequest":
        return jsonify({"ok": True, "filename": f.filename, "size_mb": size_mb})
    flash(f"Uploaded {f.filename} ({size_mb} MB)", "success")
    return redirect(url_for("deploy"))


@app.route("/images/<name>/delete", methods=["POST"])
def delete_image(name):
    img = UPLOAD_DIR / name
    if img.exists():
        img.unlink()
    return redirect(url_for("deploy"))


@app.route("/generate-sd", methods=["POST"])
def generate_sd():
    image_path = request.form.get("image_path", "")
    if not image_path or not Path(image_path).exists():
        flash("Select an image first.", "error")
        return redirect(url_for("deploy"))
    stem = Path(image_path).stem
    if stem.endswith(".img"):
        stem = stem[:-4]
    stem = stem.replace("-netboot-sd", "")
    output_name = stem + "-netboot-sd.img"
    output_path = UPLOAD_DIR / output_name
    for old in UPLOAD_DIR.glob("*-netboot-sd.img"):
        old.unlink()
    result = subprocess.run(
        ["/scripts/make-netboot-sd.sh", image_path, str(output_path)],
        capture_output=True, text=True, timeout=120,
    )
    if result.returncode != 0:
        flash(f"SD image generation failed: {result.stderr or result.stdout}", "error")
        return redirect(url_for("deploy"))
    return send_file(str(output_path), as_attachment=True, download_name=output_name)


@app.route("/node/<name>")
def node_detail(name):
    nodes = [n for n in get_nodes() if n["name"] == name]
    if not nodes:
        flash(f"Node '{name}' not found.", "error")
        return redirect(url_for("index"))
    return render_template("node.html", node=nodes[0], server_ip=get_server_ip())


@app.route("/node/<name>/edit", methods=["POST"])
def edit_node(name):
    db = load_nodes_db()
    if name not in db:
        db[name] = {}

    old_mac = db[name].get("mac", "")
    new_mac = request.form.get("mac", "").strip().lower()
    ip = request.form.get("ip", "").strip()
    notes = request.form.get("notes", "").strip()

    db[name]["mac"] = new_mac
    db[name]["ip"] = ip
    db[name]["notes"] = notes
    save_nodes_db(db)

    # Update PXE config if MAC changed
    board_type = db[name].get("board_type", "orangepi-one")
    dtb_name = db[name].get("dtb", BOARD_TYPES.get(board_type, {}).get("dtb", "sun8i-h3-orangepi-one.dtb"))
    server_ip = get_server_ip()
    nfs_path = f"/srv/nfs/{name}"
    pxe_dir = TFTP_DIR / "pxelinux.cfg"
    pxe_dir.mkdir(parents=True, exist_ok=True)

    # Remove old MAC config
    if old_mac and old_mac != new_mac:
        old_file = pxe_dir / f"01-{old_mac.replace(':', '-')}"
        old_file.unlink(missing_ok=True)

    # Write new MAC config
    if new_mac:
        pxe_content = generate_pxe_config(name, dtb_name, server_ip, nfs_path)
        (pxe_dir / f"01-{new_mac.replace(':', '-')}").write_text(pxe_content)
        flash(f"PXE config updated for MAC {new_mac}", "success")

    flash(f"Node '{name}' updated.", "success")
    return redirect(url_for("node_detail", name=name))


@app.route("/node/<name>/remove", methods=["POST"])
def remove_node(name):
    # Remove TFTP files
    tftp_path = TFTP_DIR / name
    if tftp_path.exists():
        shutil.rmtree(tftp_path)

    # Remove PXE config
    db = load_nodes_db()
    mac = db.get(name, {}).get("mac", "")
    if mac:
        pxe_file = TFTP_DIR / "pxelinux.cfg" / f"01-{mac.replace(':', '-')}"
        pxe_file.unlink(missing_ok=True)

    db.pop(name, None)
    save_nodes_db(db)

    nfs_path = NFS_DIR / name
    if nfs_path.exists():
        flash(
            f"TFTP + PXE config removed. Run on host to remove rootfs: "
            f"sudo rm -rf /srv/nfs/{name} && sudo exportfs -ra",
            "warning",
        )
    else:
        flash(f"Node '{name}' removed.", "success")
    return redirect(url_for("index"))


@app.route("/node/<name>/terminal")
def node_terminal(name):
    nodes = [n for n in get_nodes() if n["name"] == name]
    if not nodes:
        flash(f"Node '{name}' not found.", "error")
        return redirect(url_for("index"))
    node = nodes[0]
    if not node["ip"]:
        flash("Set the node's IP address first.", "error")
        return redirect(url_for("node_detail", name=name))
    return render_template("terminal.html", node=node)


@sock.route("/ws/terminal/<name>")
def terminal_ws(ws, name):
    """WebSocket endpoint that proxies to SSH on the node."""
    db = load_nodes_db()
    info = db.get(name, {})
    ip = info.get("ip", "")
    if not ip:
        ws.send("\r\n\x1b[31mError: No IP address set for this node.\x1b[0m\r\n")
        return

    # Get credentials from query params or defaults
    username = request.args.get("user", "root")
    password = request.args.get("pass", "1234")

    try:
        ws.send(f"\x1b[33mConnecting to {username}@{ip}...\x1b[0m\r\n")

        client = paramiko.SSHClient()
        client.set_missing_host_key_policy(paramiko.AutoAddPolicy())
        client.connect(ip, username=username, password=password, timeout=10)

        chan = client.invoke_shell(term="xterm-256color", width=120, height=40)
        chan.settimeout(0.1)

        ws.send(f"\x1b[32mConnected to {name} ({ip})\x1b[0m\r\n")

        # Read thread: SSH → WebSocket
        stop_event = threading.Event()

        def read_ssh():
            while not stop_event.is_set():
                try:
                    data = chan.recv(4096)
                    if not data:
                        break
                    ws.send(data.decode("utf-8", errors="replace"))
                except paramiko.buffered_pipe.PipeTimeout:
                    continue
                except Exception:
                    break
            try:
                ws.send("\r\n\x1b[31mConnection closed.\x1b[0m\r\n")
            except Exception:
                pass

        reader = threading.Thread(target=read_ssh, daemon=True)
        reader.start()

        # Write loop: WebSocket → SSH
        while True:
            try:
                data = ws.receive(timeout=1)
                if data is None:
                    break
                # Handle resize messages
                if isinstance(data, str) and data.startswith("\x1b[8;"):
                    # Parse resize: \x1b[8;rows;colst
                    try:
                        parts = data[4:-1].split(";")
                        rows, cols = int(parts[0]), int(parts[1])
                        chan.resize_pty(width=cols, height=rows)
                    except Exception:
                        pass
                else:
                    chan.send(data)
            except Exception:
                break

        stop_event.set()
        chan.close()
        client.close()

    except paramiko.AuthenticationException:
        ws.send(f"\r\n\x1b[31mAuthentication failed for {username}@{ip}\x1b[0m\r\n")
        ws.send("\x1b[33mTry default password: 1234 or orangepi\x1b[0m\r\n")
    except paramiko.SSHException as e:
        ws.send(f"\r\n\x1b[31mSSH error: {e}\x1b[0m\r\n")
    except Exception as e:
        ws.send(f"\r\n\x1b[31mConnection failed: {e}\x1b[0m\r\n")


@app.route("/api/nodes")
def api_nodes():
    return jsonify(get_nodes())


if __name__ == "__main__":
    import argparse

    parser = argparse.ArgumentParser()
    parser.add_argument("--host", default="0.0.0.0")
    parser.add_argument("--port", type=int, default=8080)
    parser.add_argument("--debug", action="store_true")
    args = parser.parse_args()
    app.run(host=args.host, port=args.port, debug=args.debug)
