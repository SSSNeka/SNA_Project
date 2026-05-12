#!/usr/bin/env bash
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RUNTIME_DIR="$SCRIPT_DIR/runtime"
LOG_DIR="$SCRIPT_DIR/logs"
INTERVAL=2
HEADLESS=0
LOG_ENABLED=1
LOG_FILE="$LOG_DIR/system_health.log"
PID_FILE="$RUNTIME_DIR/monitor.pid"
REFRESH_PENDING=1
RUNNING=1
TICKER_PID=""
DISPLAY_WIDTH=36
FORCE_NO_CLEAR=0
MAIN_PID="$$"
SIGNAL_RECEIVED=""

mkdir -p "$RUNTIME_DIR" "$LOG_DIR"

usage() {
  cat <<USAGE
Usage: ./monitor.sh [options]

Options:
  --headless       Run without output (background mode)
  --interval N     Update interval in seconds (default: 2)
  --log-file PATH  Log file path
  --no-log         Disable logging
  --pid-file PATH  PID file path
  --runtime-dir    Runtime directory
  --no-clear       Don't clear terminal
  --help           Help
USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --headless)
      HEADLESS=1
      shift
      ;;
    --interval)
      INTERVAL="$2"
      shift 2
      ;;
    --log-file)
      LOG_FILE="$2"
      shift 2
      ;;
    --no-log)
      LOG_ENABLED=0
      shift
      ;;
    --pid-file)
      PID_FILE="$2"
      shift 2
      ;;
    --runtime-dir)
      RUNTIME_DIR="$2"
      shift 2
      ;;
    --no-clear)
      FORCE_NO_CLEAR=1
      shift
      ;;
    --help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown option: $1" >&2
      usage
      exit 1
      ;;
  esac
done

mkdir -p "$RUNTIME_DIR" "$(dirname "$LOG_FILE")"

METRICS_FILE="$RUNTIME_DIR/metrics.env"
CPU_FILE="$RUNTIME_DIR/cpu_cores.csv"
TOP_CPU_FILE="$RUNTIME_DIR/top_cpu.csv"
TOP_MEM_FILE="$RUNTIME_DIR/top_mem.csv"
ALERTS_FILE="$RUNTIME_DIR/alerts.txt"
STATUS_FILE="$RUNTIME_DIR/status.txt"

RESET='\033[0m'
BOLD='\033[1m'
DIM='\033[2m'
RED='\033[31m'
GREEN='\033[32m'
YELLOW='\033[33m'
BLUE='\033[34m'
MAGENTA='\033[35m'
CYAN='\033[36m'

# Global snapshots
CPU_SUMMARY=""
MEM_TOTAL_MB=0
MEM_USED_MB=0
MEM_FREE_MB=0
MEM_USAGE_PERCENT=0
SWAP_TOTAL_MB=0
SWAP_USED_MB=0
SWAP_FREE_MB=0
ROOT_TOTAL_HR="0"
ROOT_USED_HR="0"
ROOT_FREE_HR="0"
ROOT_USAGE_PERCENT=0
DISK_READ_KBPS=0
DISK_WRITE_KBPS=0
PROCESS_COUNT=0
TOTAL_PROCESS_COUNT=0
RUNNING_PROCESS_COUNT=0
LOADAVG_1="0.00"
LOADAVG_5="0.00"
LOADAVG_15="0.00"
UPTIME_SECONDS=0
UPTIME_HUMAN="0m"
TIMESTAMP_ISO=""
TIMESTAMP_DISPLAY=""
ALERT_MESSAGES=()

# Stateful counters for deltas
LAST_DISK_READ=0
LAST_DISK_WRITE=0
LAST_DISK_TS=0

declare -A PREV_TOTAL
declare -A PREV_IDLE

color_for_percent() {
  local value="${1:-0}"
  if (( value >= 90 )); then
    printf '%b' "$RED"
  elif (( value >= 75 )); then
    printf '%b' "$YELLOW"
  else
    printf '%b' "$GREEN"
  fi
}

human_uptime() {
  local total="${1:-0}"
  local days=$(( total / 86400 ))
  local hours=$(( (total % 86400) / 3600 ))
  local mins=$(( (total % 3600) / 60 ))
  if (( days > 0 )); then
    printf '%sd %sh %sm' "$days" "$hours" "$mins"
  elif (( hours > 0 )); then
    printf '%sh %sm' "$hours" "$mins"
  else
    printf '%sm' "$mins"
  fi
}

bar() {
  local percent="${1:-0}"
  local width="${2:-20}"
  local filled=$(( percent * width / 100 ))
  local empty=$(( width - filled ))
  printf '['
  printf '%*s' "$filled" '' | tr ' ' '#'
  printf '%*s' "$empty" '' | tr ' ' '.'
  printf ']'
}

write_pid() {
  echo "$$" > "$PID_FILE"
}

safe_rm() {
  local path="$1"
  [[ -n "$path" && -e "$path" ]] && rm -f "$path"
}

handle_refresh_signal() {
  REFRESH_PENDING=1
}

cleanup() {
  RUNNING=0
  if [[ -n "${TICKER_PID:-}" ]] && kill -0 "$TICKER_PID" 2>/dev/null; then
    kill "$TICKER_PID" 2>/dev/null || true
    wait "$TICKER_PID" 2>/dev/null || true
  fi
  printf 'stopped=%s\n' "$(date '+%Y-%m-%d %H:%M:%S')" > "$STATUS_FILE"
  safe_rm "$PID_FILE"
}

handle_interrupt() {
  if (( HEADLESS == 0 )); then
    echo
    echo -e "${YELLOW}Received signal: $SIGNAL_RECEIVED. Exiting…${RESET}"
  fi
  cleanup
  exit 0
}

handle_sigint() {
  SIGNAL_RECEIVED="SIGINT"
  handle_interrupt
}

handle_sigterm() {
  SIGNAL_RECEIVED="SIGTERM"
  handle_interrupt
}

trap handle_refresh_signal USR1
trap handle_sigint INT
trap handle_sigterm TERM
trap cleanup EXIT

start_ticker() {
  (
    while kill -0 "$MAIN_PID" 2>/dev/null; do
      sleep "$INTERVAL"
      kill -USR1 "$MAIN_PID" 2>/dev/null || exit 0
    done
  ) &
  TICKER_PID=$!
}

init_cpu_state() {
  while read -r cpu user nice system idle iowait irq softirq steal guest guest_nice; do
    [[ "$cpu" =~ ^cpu[0-9]+$ ]] || continue
    local total=$(( user + nice + system + idle + iowait + irq + softirq + steal ))
    local idle_all=$(( idle + iowait ))
    PREV_TOTAL["$cpu"]=$total
    PREV_IDLE["$cpu"]=$idle_all
  done < /proc/stat
}

refresh_cpu_usage() {
  local tmp_file="$CPU_FILE.tmp"
  : > "$tmp_file"
  local total_usage=0
  local core_count=0

  while read -r cpu user nice system idle iowait irq softirq steal guest guest_nice; do
    [[ "$cpu" =~ ^cpu[0-9]+$ ]] || continue
    local total=$(( user + nice + system + idle + iowait + irq + softirq + steal ))
    local idle_all=$(( idle + iowait ))
    local prev_total="${PREV_TOTAL[$cpu]:-0}"
    local prev_idle="${PREV_IDLE[$cpu]:-0}"
    local diff_total=$(( total - prev_total ))
    local diff_idle=$(( idle_all - prev_idle ))
    local usage=0
    if (( diff_total > 0 )); then
      usage=$(( (100 * (diff_total - diff_idle)) / diff_total ))
    fi
    PREV_TOTAL["$cpu"]=$total
    PREV_IDLE["$cpu"]=$idle_all
    total_usage=$(( total_usage + usage ))
    core_count=$(( core_count + 1 ))
    printf '%s,%s\n' "$cpu" "$usage" >> "$tmp_file"
  done < /proc/stat

  mv "$tmp_file" "$CPU_FILE"
  if (( core_count > 0 )); then
    CPU_SUMMARY=$(( total_usage / core_count ))
  else
    CPU_SUMMARY=0
  fi
}

refresh_memory_usage() {
  local mem_total_kb=0 mem_available_kb=0 swap_total_kb=0 swap_free_kb=0
  while IFS=':' read -r key value; do
    value="${value//[!0-9]/}"
    case "$key" in
      MemTotal) mem_total_kb="$value" ;;
      MemAvailable) mem_available_kb="$value" ;;
      SwapTotal) swap_total_kb="$value" ;;
      SwapFree) swap_free_kb="$value" ;;
    esac
  done < /proc/meminfo

  local mem_used_kb=$(( mem_total_kb - mem_available_kb ))
  MEM_TOTAL_MB=$(( mem_total_kb / 1024 ))
  MEM_USED_MB=$(( mem_used_kb / 1024 ))
  MEM_FREE_MB=$(( mem_available_kb / 1024 ))
  if (( mem_total_kb > 0 )); then
    MEM_USAGE_PERCENT=$(( mem_used_kb * 100 / mem_total_kb ))
  else
    MEM_USAGE_PERCENT=0
  fi

  SWAP_TOTAL_MB=$(( swap_total_kb / 1024 ))
  SWAP_FREE_MB=$(( swap_free_kb / 1024 ))
  SWAP_USED_MB=$(( SWAP_TOTAL_MB - SWAP_FREE_MB ))
}

refresh_disk_usage() {
  read -r _ root_total root_used root_free root_pct _ < <(df -Pm / | awk 'NR==2 {print $1, $2, $3, $4, $5, $6}')
  ROOT_TOTAL_HR="${root_total}MB"
  ROOT_USED_HR="${root_used}MB"
  ROOT_FREE_HR="${root_free}MB"
  ROOT_USAGE_PERCENT="${root_pct%%%}"
}

refresh_disk_io() {
  local now_ts
  now_ts=$(date +%s)
  local total_read=0 total_write=0

  if [[ -r /proc/diskstats ]]; then
    while read -r major minor device reads_completed reads_merged sectors_read ms_reading writes_completed writes_merged sectors_written ms_writing ios_in_progress ms_io weighted_ms_io; do
      if [[ "$device" =~ ^(sd[a-z]+|vd[a-z]+|xvd[a-z]+|nvme[0-9]n[0-9]|mmcblk[0-9]+)$ ]]; then
        total_read=$(( total_read + sectors_read ))
        total_write=$(( total_write + sectors_written ))
      fi
    done < /proc/diskstats
  else
    DISK_READ_KBPS=0
    DISK_WRITE_KBPS=0
    LAST_DISK_READ=0
    LAST_DISK_WRITE=0
    LAST_DISK_TS=$now_ts
    return 0
  fi

  if (( LAST_DISK_TS > 0 )); then
    local delta_t=$(( now_ts - LAST_DISK_TS ))
    (( delta_t <= 0 )) && delta_t=1
    local delta_read=$(( total_read - LAST_DISK_READ ))
    local delta_write=$(( total_write - LAST_DISK_WRITE ))
    (( delta_read < 0 )) && delta_read=0
    (( delta_write < 0 )) && delta_write=0
    DISK_READ_KBPS=$(( delta_read * 512 / 1024 / delta_t ))
    DISK_WRITE_KBPS=$(( delta_write * 512 / 1024 / delta_t ))
  else
    DISK_READ_KBPS=0
    DISK_WRITE_KBPS=0
  fi

  LAST_DISK_READ=$total_read
  LAST_DISK_WRITE=$total_write
  LAST_DISK_TS=$now_ts
}

refresh_processes() {
  TOTAL_PROCESS_COUNT=$(ps -e --no-headers | wc -l | tr -d ' ')
  RUNNING_PROCESS_COUNT=$(ps -eo stat --no-headers | awk '$1 ~ /^R/ {count++} END {print count + 0}')

  # Keep PROCESS_COUNT for backward compatibility with the web UI/API.
  PROCESS_COUNT="$RUNNING_PROCESS_COUNT"

  ps -eo pid,comm,%cpu,%mem --sort=-%cpu | awk 'NR>1 && $2 !~ /^(ps|awk|head|sleep)$/ {printf "%s,%s,%s,%s\n", $1, $2, $3, $4}' | head -5 > "$TOP_CPU_FILE"
  ps -eo pid,comm,%cpu,%mem --sort=-%mem | awk 'NR>1 && $2 !~ /^(ps|awk|head|sleep)$/ {printf "%s,%s,%s,%s\n", $1, $2, $3, $4}' | head -5 > "$TOP_MEM_FILE"
}

refresh_load_and_uptime() {
  read -r LOADAVG_1 LOADAVG_5 LOADAVG_15 _ < /proc/loadavg
  read -r uptime_float _ < /proc/uptime
  UPTIME_SECONDS=${uptime_float%.*}
  UPTIME_HUMAN=$(human_uptime "$UPTIME_SECONDS")
}

refresh_alerts() {
  ALERT_MESSAGES=()
  (( CPU_SUMMARY >= 85 )) && ALERT_MESSAGES+=("High CPU (${CPU_SUMMARY}%)")
  (( MEM_USAGE_PERCENT >= 80 )) && ALERT_MESSAGES+=("High memory (${MEM_USAGE_PERCENT}%)")
  (( ROOT_USAGE_PERCENT >= 85 )) && ALERT_MESSAGES+=("Low disk space (${ROOT_USAGE_PERCENT}%)")

  local tmp_file="$ALERTS_FILE.tmp"
  : > "$tmp_file"
  if (( ${#ALERT_MESSAGES[@]} == 0 )); then
    echo "All systems nominal" > "$tmp_file"
  else
    printf '%s\n' "${ALERT_MESSAGES[@]}" > "$tmp_file"
  fi
  mv "$tmp_file" "$ALERTS_FILE"
}

write_runtime_files() {
  TIMESTAMP_ISO=$(date -Is)
  TIMESTAMP_DISPLAY=$(date '+%Y-%m-%d %H:%M:%S')

  local tmp_file="$METRICS_FILE.tmp"
  cat > "$tmp_file" <<METRICS
TIMESTAMP_ISO='$TIMESTAMP_ISO'
TIMESTAMP_DISPLAY='$TIMESTAMP_DISPLAY'
CPU_SUMMARY='$CPU_SUMMARY'
MEM_TOTAL_MB='$MEM_TOTAL_MB'
MEM_USED_MB='$MEM_USED_MB'
MEM_FREE_MB='$MEM_FREE_MB'
MEM_USAGE_PERCENT='$MEM_USAGE_PERCENT'
SWAP_TOTAL_MB='$SWAP_TOTAL_MB'
SWAP_USED_MB='$SWAP_USED_MB'
SWAP_FREE_MB='$SWAP_FREE_MB'
ROOT_TOTAL_HR='$ROOT_TOTAL_HR'
ROOT_USED_HR='$ROOT_USED_HR'
ROOT_FREE_HR='$ROOT_FREE_HR'
ROOT_USAGE_PERCENT='$ROOT_USAGE_PERCENT'
DISK_READ_KBPS='$DISK_READ_KBPS'
DISK_WRITE_KBPS='$DISK_WRITE_KBPS'
PROCESS_COUNT='$PROCESS_COUNT'
TOTAL_PROCESS_COUNT='$TOTAL_PROCESS_COUNT'
RUNNING_PROCESS_COUNT='$RUNNING_PROCESS_COUNT'
LOADAVG_1='$LOADAVG_1'
LOADAVG_5='$LOADAVG_5'
LOADAVG_15='$LOADAVG_15'
UPTIME_SECONDS='$UPTIME_SECONDS'
UPTIME_HUMAN='$UPTIME_HUMAN'
METRICS
  mv "$tmp_file" "$METRICS_FILE"

  printf 'running=%s\npid=%s\nlast_refresh=%s\n' "yes" "$$" "$TIMESTAMP_DISPLAY" > "$STATUS_FILE"
}

log_snapshot() {
  (( LOG_ENABLED == 0 )) && return 0
  printf '%s | cpu=%s%% mem=%s%% disk=%s%% proc_running=%s proc_total=%s load=%s,%s,%s io=read %sKB/s write %sKB/s\n' \
    "$TIMESTAMP_DISPLAY" "$CPU_SUMMARY" "$MEM_USAGE_PERCENT" "$ROOT_USAGE_PERCENT" "$RUNNING_PROCESS_COUNT" "$TOTAL_PROCESS_COUNT" \
    "$LOADAVG_1" "$LOADAVG_5" "$LOADAVG_15" "$DISK_READ_KBPS" "$DISK_WRITE_KBPS" >> "$LOG_FILE"
}

render_cli_dashboard() {
  (( HEADLESS == 1 )) && return 0
  (( FORCE_NO_CLEAR == 0 )) && clear

  local cpu_color mem_color disk_color
  cpu_color=$(color_for_percent "$CPU_SUMMARY")
  mem_color=$(color_for_percent "$MEM_USAGE_PERCENT")
  disk_color=$(color_for_percent "$ROOT_USAGE_PERCENT")

  echo -e "${BOLD}${CYAN}System Dashboard${RESET}"
  echo -e "${TIMESTAMP_DISPLAY} | ${INTERVAL}s interval"
  echo
  echo -e "${BOLD}Metrics${RESET}"
  printf '  CPU Usage     : %b%s%%%b %s\n' "$cpu_color" "$CPU_SUMMARY" "$RESET" "$(bar "$CPU_SUMMARY" "$DISPLAY_WIDTH")"
  printf '  Memory Usage  : %b%s%%%b %s (%sMB / %sMB)\n' "$mem_color" "$MEM_USAGE_PERCENT" "$RESET" "$(bar "$MEM_USAGE_PERCENT" "$DISPLAY_WIDTH")" "$MEM_USED_MB" "$MEM_TOTAL_MB"
  printf '  Disk Usage    : %b%s%%%b %s (%s / %s)\n' "$disk_color" "$ROOT_USAGE_PERCENT" "$RESET" "$(bar "$ROOT_USAGE_PERCENT" "$DISPLAY_WIDTH")" "$ROOT_USED_HR" "$ROOT_TOTAL_HR"
  printf '  Disk I/O      : read %s KB/s, write %s KB/s\n' "$DISK_READ_KBPS" "$DISK_WRITE_KBPS"
  printf '  Processes     : %s active, %s total\n' "$RUNNING_PROCESS_COUNT" "$TOTAL_PROCESS_COUNT"
  printf '  Load Average  : %s %s %s\n' "$LOADAVG_1" "$LOADAVG_5" "$LOADAVG_15"
  printf '  Uptime        : %s\n' "$UPTIME_HUMAN"
  echo

  echo -e "${BOLD}CPU Usage per Core${RESET}"
  while IFS=',' read -r core usage; do
    local core_color
    core_color=$(color_for_percent "$usage")
    printf '  %-6s : %b%3s%%%b %s\n' "$core" "$core_color" "$usage" "$RESET" "$(bar "$usage" 28)"
  done < "$CPU_FILE"
  echo

  echo -e "${BOLD}Top CPU${RESET}"
  printf '  %-8s %-24s %-8s %-8s\n' 'PID' 'COMMAND' 'CPU%' 'MEM%'
  while IFS=',' read -r pid comm cpu mem; do
    printf '  %-8s %-24s %-8s %-8s\n' "$pid" "$comm" "$cpu" "$mem"
  done < "$TOP_CPU_FILE"
  echo

  echo -e "${BOLD}Top Memory${RESET}"
  printf '  %-8s %-24s %-8s %-8s\n' 'PID' 'COMMAND' 'CPU%' 'MEM%'
  while IFS=',' read -r pid comm cpu mem; do
    printf '  %-8s %-24s %-8s %-8s\n' "$pid" "$comm" "$cpu" "$mem"
  done < "$TOP_MEM_FILE"
  echo

  echo -e "${BOLD}Status${RESET}"
  if (( ${#ALERT_MESSAGES[@]} == 0 )); then
    echo -e "  ${GREEN}All systems nominal${RESET}"
  else
    for message in "${ALERT_MESSAGES[@]}"; do
      echo -e "  ${YELLOW}⚠${RESET}  $message"
    done
  fi
  echo -e "${DIM}Ctrl+C to exit${RESET}"
}

refresh_all() {
  refresh_cpu_usage
  refresh_memory_usage
  refresh_disk_usage
  refresh_disk_io
  refresh_processes
  refresh_load_and_uptime
  refresh_alerts
  write_runtime_files
  log_snapshot
  render_cli_dashboard
}

main() {
  write_pid
  init_cpu_state
  refresh_disk_io
  sleep 1
  refresh_all
  REFRESH_PENDING=0
  start_ticker

  while (( RUNNING )); do
    if (( REFRESH_PENDING == 1 )); then
      REFRESH_PENDING=0
      refresh_all
    fi
    sleep 0.2
  done
}

main
