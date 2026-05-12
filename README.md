# System Dashboard

Live system monitoring with web UI, CLI mode, and signal handling.

## What is it?

A lightweight Linux system monitor that shows you what's happening on your machine in real-time. Open a browser, check CPU/memory/disk usage, see which processes are hogging resources. Built with Bash and Python, no bloat.

Key points:
- Real-time metrics (CPU, memory, disk, I/O, processes, load, uptime)
- Web dashboard + JSON API
- Signal-based refresh (SIGUSR1)
- Graceful shutdown (SIGINT/SIGTERM)
- Works in terminal too (headless mode)

## Options

```bash
./run.sh --help

--host HOST       Host to bind (default: 127.0.0.1)
--port PORT       HTTP port (default: 8000)
--interval SEC    Metric refresh interval (default: 2)
```

## Web Interface

Dashboard shows:
- CPU usage + load average
- Memory/swap usage
- Disk I/O rates
- Active processes count
- System uptime
- Per-core CPU breakdown
- Top 5 by CPU and memory
- System alerts (high CPU/memory/disk)

## Quick Start

```bash
./run.sh
```

Open `http://127.0.0.1:8000` in browser. Done.

## Signal Handling

The dashboard handles signals for refresh and graceful shutdown.

### run.sh (orchestrator)

Manages both server and monitor processes.

**SIGUSR1** — forwards refresh signal to monitor
```bash
kill -USR1 $(cat runtime/run.pid)
```

**SIGINT** — graceful shutdown (Ctrl+C)
```bash
kill -INT $(cat runtime/run.pid)
# Output: Received signal: SIGINT. Stopping…
```

**SIGTERM** — terminate gracefully
```bash
kill -TERM $(cat runtime/run.pid)
# Output: Received signal: SIGTERM. Stopping…
```

### monitor.sh (metrics collector)

Responds to refresh and shutdown signals independently.

**SIGUSR1** — immediate metric refresh (don't wait for interval)
```bash
kill -USR1 $(cat runtime/monitor.pid)
# Triggers refresh_all() immediately
```

**SIGINT** — exit with status
```bash
kill -INT $(cat runtime/monitor.pid)
# Output: Received signal: SIGINT. Exiting…
```

**SIGTERM** — exit with status
```bash
kill -TERM $(cat runtime/monitor.pid)
# Output: Received signal: SIGTERM. Exiting…
```

### API Endpoints

```bash
# Get metrics
curl http://127.0.0.1:8000/api/metrics | jq

# Trigger refresh
curl http://127.0.0.1:8000/api/refresh | jq

# Health check
curl http://127.0.0.1:8000/api/health | jq
```

## Testing Signals

### Run the demo

```bash
./demo_signals.sh
```

Shows signal handling in action:
1. Start monitor in background
2. Send SIGUSR1 (refresh)
3. Send SIGINT (shutdown)
4. Show results

### Manual test

Terminal 1:
```bash
./run.sh --port 8083
```

Terminal 2:
```bash
# Get PIDs
MONITOR_PID=$(cat runtime/monitor.pid)
RUN_PID=$(cat runtime/run.pid)

# Test SIGUSR1 on run.sh (forwards to monitor)
kill -USR1 $RUN_PID

# Test SIGINT on monitor directly
kill -INT $MONITOR_PID

# Or use run.sh orchestrator
kill -INT $RUN_PID
```

Watch the console output to see which signals are received.

## Headless Mode

Run monitor without dashboard (background operation):

```bash
./monitor.sh --headless --interval 2 --log-file logs/system_health.log
```

Writes metrics to files only, no terminal output.

## Files

### Runtime (auto-generated)
- `runtime/monitor.pid` — monitor process ID
- `runtime/run.pid` — orchestrator process ID  
- `runtime/metrics.env` — current system snapshot
- `runtime/cpu_cores.csv` — per-core CPU usage
- `runtime/top_cpu.csv` / `top_mem.csv` — top processes
- `runtime/alerts.txt` — active alerts
- `logs/system_health.log` — metric history

### Alerts trigger when
- CPU ≥ 85%
- Memory ≥ 80%
- Disk ≥ 85%

## Troubleshooting

**Port in use?**
```bash
./run.sh --port 8001
```

**Metrics not updating?**
```bash
tail -f logs/system_health.log
kill -USR1 $(cat runtime/monitor.pid)
```

**Won't shut down cleanly?**
```bash
pkill -9 -f monitor.sh
pkill -9 -f server.py
```

**Need to see what's running?**
```bash
ps aux | grep -E '(run|monitor|server)'
```
