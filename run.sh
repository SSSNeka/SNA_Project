#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

HOST="${SHM_HOST:-127.0.0.1}"
PORT="${SHM_PORT:-${1:-8000}}"
RUNTIME_DIR="$SCRIPT_DIR/runtime"
RUN_PID_FILE="$RUNTIME_DIR/run.pid"
SERVER_PID_FILE="$RUNTIME_DIR/server.pid"
MONITOR_PID_FILE="$RUNTIME_DIR/monitor.pid"
SERVER_PID=""
STOPPING=0

RESET='\033[0m'
YELLOW='\033[33m'
GREEN='\033[32m'
CYAN='\033[36m'
RED='\033[31m'

mkdir -p "$RUNTIME_DIR"
printf '%s\n' "$$" > "$RUN_PID_FILE"

cleanup_pid_files() {
  rm -f "$RUN_PID_FILE" "$SERVER_PID_FILE"
}

print_port_help() {
  printf '%b\n' "${RED}Port ${HOST}:${PORT} is already in use.${RESET}"
  echo
  echo "Another copy of the dashboard or another web server is probably still running."
  echo "Find the process with one of these commands:"
  echo "  ss -ltnp 'sport = :${PORT}'"
  echo "  lsof -nP -iTCP:${PORT} -sTCP:LISTEN"
  echo
  echo "Then either stop that process or start this dashboard on another port:"
  echo "  SHM_PORT=8001 ./run.sh"
  echo "  ./run.sh 8001"
}

check_port_available() {
  python3 - "$HOST" "$PORT" <<'PY'
import socket
import sys

host = sys.argv[1]
port = int(sys.argv[2])

sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
try:
    sock.bind((host, port))
except OSError:
    sys.exit(1)
finally:
    sock.close()
PY
}

stop_server() {
  STOPPING=1
  echo
  printf '%b\n' "${YELLOW}Caught SIGINT/SIGTERM in run.sh. Stopping web server and monitor gracefully...${RESET}"

  if [[ -n "${SERVER_PID:-}" ]] && kill -0 "$SERVER_PID" 2>/dev/null; then
    kill -INT "$SERVER_PID" 2>/dev/null || true
    wait "$SERVER_PID" 2>/dev/null || true
  fi

  cleanup_pid_files
  printf '%b\n' "${GREEN}Dashboard stopped cleanly.${RESET}"
  exit 0
}

handle_usr1() {
  local now monitor_pid
  now="$(date '+%Y-%m-%d %H:%M:%S')"
  echo
  printf '%b\n' "${CYAN}[${now}] run.sh received SIGUSR1.${RESET}"

  if [[ ! -s "$MONITOR_PID_FILE" ]]; then
    printf '%b\n' "${YELLOW}Bash monitor PID is not ready yet; try again after the dashboard finishes starting.${RESET}"
    return 0
  fi

  monitor_pid="$(cat "$MONITOR_PID_FILE" 2>/dev/null || true)"
  if [[ "$monitor_pid" =~ ^[0-9]+$ ]] && kill -0 "$monitor_pid" 2>/dev/null; then
    kill -USR1 "$monitor_pid" 2>/dev/null || true
    printf '%b\n' "${GREEN}Forwarded SIGUSR1 directly to Bash monitor PID ${monitor_pid}: refresh/log save requested.${RESET}"
  else
    printf '%b\n' "${RED}Bash monitor PID file exists, but the process is not running.${RESET}"
  fi
}

trap handle_usr1 USR1
trap stop_server INT TERM
trap cleanup_pid_files EXIT

if ! check_port_available; then
  print_port_help
  exit 98
fi

export SHM_HOST="$HOST"
export SHM_PORT="$PORT"

echo "Starting System Health Dashboard on http://${HOST}:${PORT}"
printf '%b\n' "${CYAN}run.sh PID: $$${RESET}"
printf '%b\n' "${CYAN}To demonstrate SIGUSR1 visually in web mode:${RESET} kill -USR1 $$"

./server.py &
SERVER_PID=$!
printf '%s\n' "$SERVER_PID" > "$SERVER_PID_FILE"
printf '%b\n' "${CYAN}server.py PID: ${SERVER_PID}${RESET}"

status=0
while true; do
  set +e
  wait "$SERVER_PID"
  status=$?
  set -e

  # Bash wait is interrupted after a trapped signal such as SIGUSR1.
  # In that case the child is still alive, so keep waiting instead of
  # accidentally ending run.sh and orphaning the monitor.
  if (( STOPPING == 0 )) && [[ -n "${SERVER_PID:-}" ]] && kill -0 "$SERVER_PID" 2>/dev/null; then
    continue
  fi

  break
done

cleanup_pid_files
exit "$status"
