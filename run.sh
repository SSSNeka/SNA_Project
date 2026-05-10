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

RESET='\033[0m'
YELLOW='\033[33m'
GREEN='\033[32m'
CYAN='\033[36m'
RED='\033[31m'

show_help() {
  cat <<HELP
Usage: ./run.sh [OPTIONS]

OPTIONS:
  --host HOST       Server host (default: 127.0.0.1)
  --port PORT       Server port (default: 8000)
  --interval SEC    Refresh interval in seconds (default: 2)
  --help            Show this help message

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
  printf '%b\n' "${RED}Port ${HOST}:${PORT} is already in use.${RESET}"
  echo
  echo "Find and stop the existing process:"
  echo "  ss -ltnp 'sport = :${PORT}'"
  echo "  lsof -nP -iTCP:${PORT} -sTCP:LISTEN"
  echo
  echo "Or use another port:"
  echo "  ./run.sh --port 8001"
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
  printf '%b\n' "${YELLOW}Caught SIGINT/SIGTERM. Stopping gracefully...${RESET}"

  # Processes already got SIGINT, just wait with timeout
  if [[ -n "${SERVER_PID:-}" ]]; then
    timeout 2 wait "$SERVER_PID" 2>/dev/null || kill -9 "$SERVER_PID" 2>/dev/null || true
  fi

  if [[ -n "${MONITOR_PID:-}" ]]; then
    timeout 2 wait "$MONITOR_PID" 2>/dev/null || kill -9 "$MONITOR_PID" 2>/dev/null || true
  fi

  cleanup_pid_files
  printf '%b\n' "${GREEN}Dashboard stopped cleanly.${RESET}"
  exit 0
}

handle_usr1() {
  local now
  now="$(date '+%Y-%m-%d %H:%M:%S')"
  echo
  printf '%b\n' "${CYAN}[${now}] run.sh received SIGUSR1, forwarding to monitor...${RESET}"

  if [[ -n "${MONITOR_PID:-}" ]] && kill -0 "$MONITOR_PID" 2>/dev/null; then
    kill -USR1 "$MONITOR_PID" 2>/dev/null || true
    printf '%b\n' "${GREEN}Sent SIGUSR1 to monitor PID ${MONITOR_PID}.${RESET}"
  else
    printf '%b\n' "${YELLOW}Monitor not running.${RESET}"
  fi
}

trap handle_usr1 USR1
trap stop_server INT TERM
trap cleanup_pid_files EXIT

parse_args "$@"

if ! check_port_available; then
  print_port_help
  exit 98
fi

echo "Starting System Health Dashboard on http://${HOST}:${PORT}"
printf '%b\n' "${CYAN}run.sh PID: $$${RESET}"

# Start server.py
SHM_HOST="$HOST" SHM_PORT="$PORT" SHM_INTERVAL="$INTERVAL" ./server.py &
SERVER_PID=$!
printf '%b\n' "${CYAN}server.py PID: ${SERVER_PID}${RESET}"

# Start monitor.sh
./monitor.sh --headless --interval "$INTERVAL" --runtime-dir "$RUNTIME_DIR" --log-file "$SCRIPT_DIR/logs/system_health.log" &
MONITOR_PID=$!
printf '%b\n' "${CYAN}monitor.sh PID: ${MONITOR_PID}${RESET}"

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
