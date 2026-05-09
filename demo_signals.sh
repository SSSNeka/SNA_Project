#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"
RUNTIME_DIR="$SCRIPT_DIR/runtime/demo"
PID_FILE="$RUNTIME_DIR/demo_monitor.pid"
LOG_FILE="$SCRIPT_DIR/logs/demo_monitor.log"
mkdir -p "$RUNTIME_DIR" "$SCRIPT_DIR/logs"

echo "[1/4] Starting headless monitor for signal demo..."
# Enable job control while starting the background Bash process so SIGINT is not inherited as ignored.
# This makes the scripted demo behave like pressing Ctrl+C in an interactive terminal.
set -m
./monitor.sh --headless --runtime-dir "$RUNTIME_DIR" --pid-file "$PID_FILE" --log-file "$LOG_FILE" &
MONITOR_PID=$!
set +m
sleep 3

echo "[2/4] Sending SIGUSR1 to force immediate refresh..."
kill -USR1 "$MONITOR_PID"
sleep 2

echo "[3/4] Sending SIGINT for graceful shutdown..."
kill -INT "$MONITOR_PID"
wait "$MONITOR_PID" || true

echo "[4/4] Demo complete. Monitor status and recent log lines:"
cat "$RUNTIME_DIR/status.txt" 2>/dev/null || true
tail -n 5 "$LOG_FILE" || true
