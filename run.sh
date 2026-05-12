#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

HOST="127.0.0.1"
PORT=8000
INTERVAL=2
RUNTIME_DIR="$SCRIPT_DIR/runtime"
RUN_PID_FILE="$RUNTIME_DIR/run.pid"
SERVER_PID_FILE="$RUNTIME_DIR/server.pid"
SERVER_PID=""
MONITOR_PID=""
STOPPING=0
SIGNAL_RECEIVED=""

RESET='\033[0m'
YELLOW='\033[33m'
GREEN='\033[32m'
CYAN='\033[36m'
RED='\033[31m'

show_help() {
  cat <<HELP
Usage: ./run.sh [OPTIONS]

Options:
  --host HOST       Host (default: 127.0.0.1)
  --port PORT       Port (default: 8000)
  --interval SEC    Interval in seconds (default: 2)
  --help            Help

HELP
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --help)
        show_help
        exit 0
        ;;
      --host)
        if [[ -z "${2:-}" ]]; then
          printf '%b\n' "${RED}Error: --host requires a hostname/IP${RESET}"
          exit 1
        fi
        HOST="$2"
        shift 2
        ;;
      --port)
        if [[ -z "${2:-}" ]]; then
          printf '%b\n' "${RED}Error: --port requires a port number${RESET}"
          exit 1
        fi
        PORT="$2"
        shift 2
        ;;
      --interval)
        if [[ -z "${2:-}" ]]; then
          printf '%b\n' "${RED}Error: --interval requires a number (seconds)${RESET}"
          exit 1
        fi
        INTERVAL="$2"
        shift 2
        ;;
      -*)
        printf '%b\n' "${RED}Error: unknown option '$1'${RESET}"
        show_help
        exit 1
        ;;
      *)
        printf '%b\n' "${RED}Error: unknown argument '$1'${RESET}"
        show_help
        exit 1
        ;;
    esac
  done
}

mkdir -p "$RUNTIME_DIR"
printf '%s\n' "$$" > "$RUN_PID_FILE"

cleanup_pid_files() {
  rm -f "$RUN_PID_FILE" "$SERVER_PID_FILE"
}

print_port_help() {
  printf '%b\n' "${RED}Error: Port ${HOST}:${PORT} is in use${RESET}"
  echo
  echo "Find the process: ss -ltnp 'sport = :${PORT}'"
  echo "Use another port: ./run.sh --port 8001"
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
  printf '%b\n' "${YELLOW}Received signal: $SIGNAL_RECEIVED. Stopping…${RESET}"

  # Processes already got SIGINT, just wait with timeout
  if [[ -n "${SERVER_PID:-}" ]]; then
    timeout 2 wait "$SERVER_PID" 2>/dev/null || kill -9 "$SERVER_PID" 2>/dev/null || true
  fi

  if [[ -n "${MONITOR_PID:-}" ]]; then
    timeout 2 wait "$MONITOR_PID" 2>/dev/null || kill -9 "$MONITOR_PID" 2>/dev/null || true
  fi

  cleanup_pid_files
  printf '%b\n' "${GREEN}Stopped.${RESET}"
  exit 0
}

handle_usr1() {
  if [[ -n "${MONITOR_PID:-}" ]] && kill -0 "$MONITOR_PID" 2>/dev/null; then
    kill -USR1 "$MONITOR_PID" 2>/dev/null || true
  fi
}

handle_sigint() {
  SIGNAL_RECEIVED="SIGINT"
  stop_server
}

handle_sigterm() {
  SIGNAL_RECEIVED="SIGTERM"
  stop_server
}

trap handle_usr1 USR1
trap handle_sigint INT
trap handle_sigterm TERM
trap cleanup_pid_files EXIT

parse_args "$@"

if ! check_port_available; then
  print_port_help
  exit 98
fi

echo "Starting dashboard at http://${HOST}:${PORT}"

# Start server
SHM_HOST="$HOST" SHM_PORT="$PORT" SHM_INTERVAL="$INTERVAL" ./server.py &
SERVER_PID=$!

# Start monitor
./monitor.sh --headless --interval "$INTERVAL" --runtime-dir "$RUNTIME_DIR" --log-file "$SCRIPT_DIR/logs/system_health.log" &
MONITOR_PID=$!

printf '%s\n' "$SERVER_PID" > "$SERVER_PID_FILE"

status=0
while (( STOPPING == 0 )); do
  if ! kill -0 "$SERVER_PID" 2>/dev/null && ! kill -0 "$MONITOR_PID" 2>/dev/null; then
    break
  fi
  sleep 0.5
done

cleanup_pid_files
exit "$status"
