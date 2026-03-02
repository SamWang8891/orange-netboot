#!/usr/bin/env python3
"""netboot-agent — host-side privileged helper for orange-netboot.

Runs as root on the host. Streams deploy-rootfs.sh / setup-host.sh output
as Server-Sent Events (SSE).

Usage:
    sudo python3 netboot-agent.py --repo-dir /path/to/repo [--port 7777] [--host 127.0.0.1]
"""

import argparse
import json
import os
import re
import secrets
import subprocess
import sys
from http.server import BaseHTTPRequestHandler, HTTPServer
from pathlib import Path

repo_dir: Path
token: str


def load_or_create_token(path: Path) -> str:
    if path.exists():
        tok = path.read_text().strip()
        if tok:
            return tok
    tok = secrets.token_urlsafe(32)
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(tok + "\n")
    os.chmod(path, 0o600)
    print(f"[netboot-agent] Created token at {path}", flush=True)
    return tok


class Handler(BaseHTTPRequestHandler):

    def log_message(self, fmt, *args):
        # Suppress default access log to avoid leaking tokens in server logs
        method = self.command
        path = self.path.split("?")[0]  # strip any query params
        print(f"[netboot-agent] {method} {path}", flush=True)

    def send_sse_headers(self):
        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream")
        self.send_header("Cache-Control", "no-cache")
        self.send_header("X-Accel-Buffering", "no")
        self.end_headers()

    def auth_ok(self) -> bool:
        auth = self.headers.get("Authorization", "")
        return auth == f"Bearer {token}"

    def send_json(self, code: int, obj: dict):
        body = json.dumps(obj).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def stream_script(self, cmd: list):
        """Spawn cmd, stream stdout+stderr line-by-line as SSE, send done event."""
        self.send_sse_headers()
        try:
            proc = subprocess.Popen(
                cmd,
                stdout=subprocess.PIPE,
                stderr=subprocess.STDOUT,
                bufsize=1,
                text=True,
            )
            for line in proc.stdout:
                line = line.rstrip("\n")
                self.wfile.write(f"data: {line}\n\n".encode())
                self.wfile.flush()
            proc.wait()
            done = json.dumps({"exit_code": proc.returncode})
            self.wfile.write(f"event: done\ndata: {done}\n\n".encode())
            self.wfile.flush()
        except BrokenPipeError:
            pass
        except Exception as e:
            try:
                self.wfile.write(f"data: ERROR: {e}\n\n".encode())
                done = json.dumps({"exit_code": 1})
                self.wfile.write(f"event: done\ndata: {done}\n\n".encode())
                self.wfile.flush()
            except Exception:
                pass

    def do_GET(self):
        if self.path == "/status":
            self.send_json(200, {"ok": True})
        else:
            self.send_json(404, {"error": "Not found"})

    def do_POST(self):
        if not self.auth_ok():
            self.send_json(401, {"error": "Unauthorized"})
            return

        if self.path == "/run/deploy-rootfs":
            length = int(self.headers.get("Content-Length", 0))
            body = self.rfile.read(length)
            try:
                params = json.loads(body)
            except Exception:
                self.send_json(400, {"error": "Invalid JSON"})
                return

            image = params.get("image", "")
            node = params.get("node", "")
            mac = params.get("mac", "")
            dtb = params.get("dtb", "")

            # Validate image: no path separators, must exist in uploads
            if not image or "/" in image or "\\" in image or ".." in image:
                self.send_json(400, {"error": "Invalid image filename"})
                return
            image_path = repo_dir / "data" / "uploads" / image
            if not image_path.exists():
                self.send_json(400, {"error": f"Image not found: {image}"})
                return

            # Validate node name
            if not node or not re.fullmatch(r"[a-zA-Z0-9_-]+", node):
                self.send_json(400, {"error": "Invalid node name"})
                return

            script = repo_dir / "server" / "deploy-rootfs.sh"
            cmd = ["bash", str(script), str(image_path), node]
            if mac:
                cmd.append(mac)
            if dtb:
                cmd.append(dtb)
            self.stream_script(cmd)

        elif self.path == "/run/setup-host":
            script = repo_dir / "server" / "setup-host.sh"
            self.stream_script(["bash", str(script)])

        elif self.path == "/run/remove-rootfs":
            length = int(self.headers.get("Content-Length", 0))
            body = self.rfile.read(length)
            try:
                params = json.loads(body)
            except Exception:
                self.send_json(400, {"error": "Invalid JSON"})
                return

            node = params.get("node", "")
            if not node or not re.fullmatch(r"[a-zA-Z0-9_-]+", node):
                self.send_json(400, {"error": "Invalid node name"})
                return

            try:
                result = subprocess.run(
                    ["bash", "-c", f"rm -rf -- /srv/nfs/{node} && exportfs -ra"],
                    capture_output=True, text=True, timeout=300,
                )
                ok = result.returncode == 0
                self.send_json(200 if ok else 500, {
                    "ok": ok,
                    "exit_code": result.returncode,
                    "output": (result.stdout + result.stderr)[-2000:],
                })
            except subprocess.TimeoutExpired:
                self.send_json(500, {"error": "Timed out removing rootfs"})
            except Exception as e:
                self.send_json(500, {"error": str(e)})

        else:
            self.send_json(404, {"error": "Not found"})


def main():
    global repo_dir, token

    parser = argparse.ArgumentParser(description="netboot privileged agent")
    parser.add_argument(
        "--repo-dir",
        required=True,
        help="Path to the orange-netboot repository root",
    )
    parser.add_argument("--port", type=int, default=7777)
    parser.add_argument("--host", default="127.0.0.1")
    args = parser.parse_args()

    repo_dir = Path(args.repo_dir).resolve()
    token_path = repo_dir / "data" / "agent.token"
    token = load_or_create_token(token_path)

    server = HTTPServer((args.host, args.port), Handler)
    print(f"[netboot-agent] Listening on {args.host}:{args.port}", flush=True)
    print(f"[netboot-agent] Repo: {repo_dir}", flush=True)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass


if __name__ == "__main__":
    main()
