#!/usr/bin/env python3
from __future__ import annotations

import atexit
import json
import os
import signal
import subprocess
import sys
import threading
import time
from http import HTTPStatus
from http.server import SimpleHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import parse_qs, urlparse

BASE_DIR = Path(__file__).resolve().parent
STATIC_DIR = BASE_DIR / "static"
RUNTIME_DIR = BASE_DIR / "runtime"
LOG_DIR = BASE_DIR / "logs"
MONITOR_SCRIPT = BASE_DIR / "monitor.sh"
PID_FILE = RUNTIME_DIR / "monitor.pid"
LOG_FILE = LOG_DIR / "system_health.log"
HOST = os.environ.get("SHM_HOST", "127.0.0.1")
PORT = int(os.environ.get("SHM_PORT", "8000"))
REFRESH_INTERVAL = int(os.environ.get("SHM_INTERVAL", "2"))

monitor_process: subprocess.Popen[str] | None = None
process_lock = threading.Lock()


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


def pid_from_file() -> int | None:
    if not PID_FILE.exists():
        return None
    try:
        return int(PID_FILE.read_text(encoding="utf-8").strip())
    except ValueError:
        return None


def is_pid_alive(pid: int | None) -> bool:
    if not pid:
        return False
    try:
        os.kill(pid, 0)
        return True
    except OSError:
        return False


def ensure_monitor_running() -> None:
    global monitor_process
    with process_lock:
        file_pid = pid_from_file()
        if is_pid_alive(file_pid):
            return
        if monitor_process is not None and monitor_process.poll() is None:
            return

        RUNTIME_DIR.mkdir(parents=True, exist_ok=True)
        LOG_DIR.mkdir(parents=True, exist_ok=True)

        cmd = [
            str(MONITOR_SCRIPT),
            "--headless",
            "--interval",
            str(REFRESH_INTERVAL),
            "--runtime-dir",
            str(RUNTIME_DIR),
            "--log-file",
            str(LOG_FILE),
            "--pid-file",
            str(PID_FILE),
        ]
        monitor_process = subprocess.Popen(
            cmd,
            cwd=str(BASE_DIR),
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            text=True,
            preexec_fn=os.setsid,
        )
        time.sleep(1.2)


def stop_monitor() -> None:
    global monitor_process
    with process_lock:
        target_pid = pid_from_file()
        if target_pid and is_pid_alive(target_pid):
            try:
                os.kill(target_pid, signal.SIGINT)
            except OSError:
                pass
        if monitor_process is not None:
            try:
                monitor_process.wait(timeout=3)
            except subprocess.TimeoutExpired:
                try:
                    os.killpg(os.getpgid(monitor_process.pid), signal.SIGTERM)
                except OSError:
                    pass
            monitor_process = None


def trigger_refresh(source: str = "api") -> bool:
    ensure_monitor_running()
    target_pid = pid_from_file()
    timestamp = time.strftime("%Y-%m-%d %H:%M:%S")

    if not is_pid_alive(target_pid):
        print(
            f"[{timestamp}] SIGUSR1 requested from {source}, but the Bash monitor is not running.",
            flush=True,
        )
        return False

    try:
        os.kill(target_pid, signal.SIGUSR1)
        print(
            f"[{timestamp}] SIGUSR1 requested from {source}: "
            f"sent SIGUSR1 to Bash monitor PID {target_pid} for immediate refresh/log save.",
            flush=True,
        )
        return True
    except OSError as exc:
        print(
            f"[{timestamp}] SIGUSR1 requested from {source}, "
            f"but sending the signal failed: {exc}",
            flush=True,
        )
        return False


def metrics_payload() -> dict:
    ensure_monitor_running()
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
            query = parse_qs(parsed.query)
            source = query.get("source", ["api"])[0] or "api"
            ok = trigger_refresh(source=source)
            self._json_response({"ok": ok, "message": "SIGUSR1 sent" if ok else "Monitor is not running"})
            return
        if parsed.path == "/api/health":
            ensure_monitor_running()
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
                "Stop the existing process or set another port, for example: "
                "SHM_PORT=8001 ./run.sh",
                file=sys.stderr,
                flush=True,
            )
            raise SystemExit(98) from exc
        raise

    atexit.register(stop_monitor)
    ensure_monitor_running()

    def shutdown_handler(signum, frame):  # noqa: ARG001
        # ThreadingHTTPServer.shutdown() must not run directly inside the signal
        # handler/main serve_forever thread, otherwise Ctrl+C can deadlock.
        threading.Thread(target=server.shutdown, daemon=True).start()

    signal.signal(signal.SIGINT, shutdown_handler)
    signal.signal(signal.SIGTERM, shutdown_handler)

    print(f"System Health Dashboard running at http://{HOST}:{PORT}", flush=True)
    print("Press Ctrl+C to stop the web server and gracefully terminate the monitor.", flush=True)
    print("Press the dashboard SIGUSR1 button to show a visible terminal event and refresh/log save action.", flush=True)
    print("You can also send SIGUSR1 to run.sh manually for the same Bash-level demonstration.", flush=True)
    try:
        server.serve_forever()
    finally:
        server.server_close()
        stop_monitor()


if __name__ == "__main__":
    serve()
