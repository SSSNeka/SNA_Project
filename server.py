#!/usr/bin/env python3
from __future__ import annotations

import json
import os
import signal
from http import HTTPStatus
from http.server import SimpleHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import parse_qs, urlparse

BASE_DIR = Path(__file__).resolve().parent
STATIC_DIR = BASE_DIR / "static"
RUNTIME_DIR = BASE_DIR / "runtime"
LOG_DIR = BASE_DIR / "logs"
LOG_FILE = LOG_DIR / "system_health.log"
HOST = os.environ.get("SHM_HOST", "127.0.0.1")
PORT = int(os.environ.get("SHM_PORT", "8000"))


def parse_env_file(path: Path) -> dict[str, str]:
    data: dict[str, str] = {}
    if not path.exists():
        return data
    for line in path.read_text(encoding="utf-8").splitlines():
        if "=" not in line:
            continue
        key, value = line.split("=", 1)
        data[key.strip()] = value.strip().strip("'")
    return data


def read_csv_rows(path: Path) -> list[dict[str, str]]:
    rows: list[dict[str, str]] = []
    if not path.exists():
        return rows
    for line in path.read_text(encoding="utf-8").splitlines():
        parts = [part.strip() for part in line.split(",")]
        if len(parts) != 4:
            continue
        rows.append({"pid": parts[0], "command": parts[1], "cpu": parts[2], "mem": parts[3]})
    return rows


def read_cpu_rows(path: Path) -> list[dict[str, str]]:
    rows: list[dict[str, str]] = []
    if not path.exists():
        return rows
    for line in path.read_text(encoding="utf-8").splitlines():
        parts = [part.strip() for part in line.split(",")]
        if len(parts) != 2:
            continue
        rows.append({"core": parts[0], "usage": parts[1]})
    return rows


def read_alerts(path: Path) -> list[str]:
    if not path.exists():
        return []
    alerts = [line.strip() for line in path.read_text(encoding="utf-8").splitlines() if line.strip()]
    return alerts


def read_recent_logs(path: Path, limit: int = 12) -> list[str]:
    if not path.exists():
        return []
    lines = path.read_text(encoding="utf-8", errors="replace").splitlines()
    return lines[-limit:]


def get_monitor_pid() -> int | None:
    """Read monitor PID from runtime file."""
    pid_file = RUNTIME_DIR / "monitor.pid"
    if not pid_file.exists():
        return None
    try:
        return int(pid_file.read_text(encoding="utf-8").strip())
    except ValueError:
        return None


def send_refresh_signal() -> bool:
    """Send SIGUSR1 to monitor process."""
    pid = get_monitor_pid()
    if not pid:
        return False
    try:
        os.kill(pid, signal.SIGUSR1)
        return True
    except OSError:
        return False





def metrics_payload() -> dict:
    metrics = parse_env_file(RUNTIME_DIR / "metrics.env")
    status = parse_env_file(RUNTIME_DIR / "status.txt")
    payload = {
        "metrics": metrics,
        "cpu_cores": read_cpu_rows(RUNTIME_DIR / "cpu_cores.csv"),
        "top_cpu": read_csv_rows(RUNTIME_DIR / "top_cpu.csv"),
        "top_mem": read_csv_rows(RUNTIME_DIR / "top_mem.csv"),
        "alerts": read_alerts(RUNTIME_DIR / "alerts.txt"),
        "logs": read_recent_logs(LOG_FILE),
        "status": {
            "running": status.get("running", "unknown"),
            "pid": status.get("pid", "n/a"),
            "last_refresh": status.get("last_refresh", "n/a"),
        },
    }
    return payload


class DashboardHandler(SimpleHTTPRequestHandler):
    def __init__(self, *args, **kwargs):
        super().__init__(*args, directory=str(STATIC_DIR), **kwargs)

    def _json_response(self, payload: dict, status: int = HTTPStatus.OK) -> None:
        body = json.dumps(payload).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self) -> None:  # noqa: N802
        parsed = urlparse(self.path)
        if parsed.path == "/api/metrics":
            self._json_response(metrics_payload())
            return
        if parsed.path == "/api/refresh":
            ok = send_refresh_signal()
            self._json_response({"ok": ok, "message": "SIGUSR1 sent to monitor" if ok else "Monitor not running"})
            return
        if parsed.path == "/api/health":
            self._json_response({"ok": True, "host": HOST, "port": PORT})
            return
        return super().do_GET()

    def log_message(self, format: str, *args) -> None:  # noqa: A003
        return


def serve() -> None:
    try:
        server = ThreadingHTTPServer((HOST, PORT), DashboardHandler)
    except OSError as exc:
        if exc.errno == 98:
            print(
                f"Port {HOST}:{PORT} is already in use. "
                "Stop the existing process or use another port: --port 8001",
                flush=True,
            )
            raise SystemExit(98) from exc
        raise

    print(f"System Health Dashboard running at http://{HOST}:{PORT}", flush=True)
    try:
        server.serve_forever()
    finally:
        server.server_close()


if __name__ == "__main__":
    serve()
