#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"
RUNTIME_DIR="$SCRIPT_DIR/runtime/demo"
PID_FILE="$RUNTIME_DIR/demo_monitor.pid"
LOG_FILE="$SCRIPT_DIR/logs/demo_monitor.log"
mkdir -p "$RUNTIME_DIR" "$SCRIPT_DIR/logs"

echo "Starting demo…"
set -m
./monitor.sh --headless --runtime-dir "$RUNTIME_DIR" --pid-file "$PID_FILE" --log-file "$LOG_FILE" &
MONITOR_PID=$!
set +m
sleep 3

echo "Sending SIGUSR1 (refresh signal)…"
kill -USR1 "$MONITOR_PID"
sleep 2

echo "Sending SIGINT (shutdown signal)…"
kill -INT "$MONITOR_PID"
wait "$MONITOR_PID" || true

echo ""
echo "Demo complete."
cat "$RUNTIME_DIR/status.txt" 2>/dev/null || true
tail -n 5 "$LOG_FILE" || true
