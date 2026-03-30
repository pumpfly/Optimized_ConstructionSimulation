#!/usr/bin/env bash
# =============================================================================
# run_ga_headless.sh — Launch a full GA optimisation run with 20 headless workers
# =============================================================================
#
# Usage
# -----
#   chmod +x run_ga_headless.sh
#   ./run_ga_headless.sh [OPTIONS]
#
# Options
#   -n, --workers    <N>      Number of simultaneous Godot workers (default: 20)
#   -s, --speed      <N>      Simulation time-scale factor (default: 10)
#   -b, --binary     <path>   Path to Godot binary (auto-detected if omitted)
#   -m, --heightmap  <path>   Path to heightmap image passed to every worker
#   -h, --help                Show this help message and exit
#
# What it does
# ------------
# 1. Verifies that the orchestrator (orchestrator.py) and the Godot binary exist.
# 2. Starts the Python GA orchestrator server in the background.
# 3. Launches N Godot instances in headless mode, each connecting to the server.
#    Each worker logs to logs/worker_<N>.log.
# 4. Waits for the orchestrator to finish (all GA generations complete).
# 5. Cleans up all Godot worker processes on exit (including Ctrl-C).
#
# Output files (written to ga_results/)
# --------------------------------------
#   best_schedule.json      — Best spawn schedule found by the GA
#   generation_history.json — Per-generation best/avg/worst fitness
#   orchestrator.log        — Full orchestrator log
#
# Worker logs are written to logs/worker_<N>.log
#
# Requirements
# ------------
#   - Python venv at venv/ with Flask installed  (pip install flask)
#   - The Godot Linux export binary (.x86_64) in the same directory or PATH
#   - Xvfb is NOT required — Godot runs in headless mode (--headless flag)
# =============================================================================

set -euo pipefail

# ---------------------------------------------------------------------------
# Defaults
# ---------------------------------------------------------------------------
WORKER_COUNT=20
SIM_SPEED=10
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GODOT_BINARY=""       # auto-detect below
HEIGHTMAP=""          # optional; passed to each worker via --heightmap
LOG_DIR="${SCRIPT_DIR}/logs"
ORCH_LOG="${LOG_DIR}/orchestrator_stdout.log"

# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------
print_help() {
    sed -n '/^# Usage/,/^# =\+$/p' "$0" | sed 's/^# \?//'
    exit 0
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        -n|--workers)   WORKER_COUNT="$2"; shift 2 ;;
        -s|--speed)     SIM_SPEED="$2";    shift 2 ;;
        -b|--binary)    GODOT_BINARY="$2"; shift 2 ;;
        -m|--heightmap) HEIGHTMAP="$2";    shift 2 ;;
        -h|--help)      print_help ;;
        *) echo "Unknown option: $1"; print_help ;;
    esac
done

# ---------------------------------------------------------------------------
# Auto-detect the Godot binary
# ---------------------------------------------------------------------------
if [[ -z "$GODOT_BINARY" ]]; then
    # Look for any .x86_64 file in the script directory (export build)
    FOUND="$(find "${SCRIPT_DIR}" -maxdepth 1 -name "*.x86_64" | head -1)"
    if [[ -n "$FOUND" ]]; then
        GODOT_BINARY="$FOUND"
    else
        echo "[ERROR] No .x86_64 Godot binary found in ${SCRIPT_DIR}."
        echo "        Export the project from Godot Editor (Linux/X11 headless),"
        echo "        or pass the path with --binary <path>."
        exit 1
    fi
fi

# ---------------------------------------------------------------------------
# Sanity checks
# ---------------------------------------------------------------------------
if [[ ! -f "${SCRIPT_DIR}/orchestrator.py" ]]; then
    echo "[ERROR] orchestrator.py not found in ${SCRIPT_DIR}."
    exit 1
fi

if [[ ! -x "${GODOT_BINARY}" ]]; then
    echo "[ERROR] Godot binary not executable: ${GODOT_BINARY}"
    echo "        Run: chmod +x ${GODOT_BINARY}"
    exit 1
fi

if [[ -n "$HEIGHTMAP" && ! -f "$HEIGHTMAP" ]]; then
    echo "[ERROR] Heightmap file not found: ${HEIGHTMAP}"
    exit 1
fi

VENV_PYTHON="${SCRIPT_DIR}/venv/bin/python"
if [[ ! -x "$VENV_PYTHON" ]]; then
    echo "[ERROR] venv not found at ${SCRIPT_DIR}/venv."
    echo "        Create it with: python3 -m venv venv && venv/bin/pip install flask"
    exit 1
fi

if ! "$VENV_PYTHON" -c "import flask" &>/dev/null; then
    echo "[ERROR] Flask is not installed in the venv."
    echo "        Run: ${SCRIPT_DIR}/venv/bin/pip install flask"
    exit 1
fi

# ---------------------------------------------------------------------------
# Setup
# ---------------------------------------------------------------------------
mkdir -p "${LOG_DIR}"
mkdir -p "${SCRIPT_DIR}/ga_results"

echo "============================================================"
echo " GA Headless Run"
echo "  Workers      : ${WORKER_COUNT}"
echo "  Sim speed    : ${SIM_SPEED}x"
echo "  Godot binary : ${GODOT_BINARY}"
echo "  Heightmap    : ${HEIGHTMAP:-<none>}"
echo "  Log dir      : ${LOG_DIR}"
echo "  Results dir  : ${SCRIPT_DIR}/ga_results"
echo "============================================================"

# ---------------------------------------------------------------------------
# Process management — track all child PIDs for cleanup
# ---------------------------------------------------------------------------
# IMPORTANT: processes are started with plain > redirection (no pipes) so that
# $! always captures the PID of the real process (Python / Godot), not an
# intermediate tee/awk stage.  Separate tail -f | awk pipelines handle the
# prefixed terminal output.  On cleanup we kill the real processes by PID and
# then kill any remaining background jobs (the display pipelines) via jobs -p.
# ---------------------------------------------------------------------------
WORKER_PIDS=()
ORCH_PID=""

cleanup() {
    echo ""
    echo "[cleanup] Stopping all processes..."

    # Kill the orchestrator by its real PID
    if [[ -n "$ORCH_PID" ]] && kill -0 "$ORCH_PID" 2>/dev/null; then
        kill "$ORCH_PID" 2>/dev/null && echo "[cleanup] Killed orchestrator PID $ORCH_PID"
    fi

    # Kill all Godot workers by their real PIDs
    for pid in "${WORKER_PIDS[@]}"; do
        if kill -0 "$pid" 2>/dev/null; then
            kill "$pid" 2>/dev/null && echo "[cleanup] Killed worker PID $pid"
        fi
    done

    # Kill any remaining background jobs (tail / awk display pipelines)
    # jobs -p lists every background job PID still known to this shell
    local remaining
    remaining=$(jobs -p 2>/dev/null)
    if [[ -n "$remaining" ]]; then
        echo "$remaining" | xargs -r kill 2>/dev/null || true
        echo "[cleanup] Killed remaining background jobs"
    fi

    echo "[cleanup] Done."
}

# Run cleanup on normal exit, Ctrl-C (SIGINT), and SIGTERM
trap cleanup EXIT INT TERM

# ---------------------------------------------------------------------------
# Start the GA orchestrator
# ---------------------------------------------------------------------------
echo "[start] Launching orchestrator..."
# Write directly to log file — $! is the real Python PID
"$VENV_PYTHON" "${SCRIPT_DIR}/orchestrator.py" > "${ORCH_LOG}" 2>&1 &
ORCH_PID=$!
echo "[start] Orchestrator PID: ${ORCH_PID}  (log: ${ORCH_LOG})"
# Stream the log to the terminal with a prefix (display only — not tracked for cleanup)
tail -f "${ORCH_LOG}" | awk '{print "[ORCH] " $0; fflush()}' &

# Wait for the Flask server to become ready before spawning workers.
# Poll the health-check endpoint with a 30 s overall timeout.
echo "[start] Waiting for orchestrator to be ready..."
MAX_WAIT=30
WAITED=0
until curl -sf "http://127.0.0.1:7999/" > /dev/null 2>&1; do
    sleep 1
    WAITED=$((WAITED + 1))
    if [[ $WAITED -ge $MAX_WAIT ]]; then
        echo "[ERROR] Orchestrator did not start within ${MAX_WAIT}s."
        echo "        Check ${ORCH_LOG} for details."
        exit 1
    fi
done
echo "[start] Orchestrator ready after ${WAITED}s."

# ---------------------------------------------------------------------------
# Launch Godot worker instances
# ---------------------------------------------------------------------------
echo "[start] Launching ${WORKER_COUNT} Godot workers..."

for i in $(seq 1 "${WORKER_COUNT}"); do
    WORKER_LOG="${LOG_DIR}/worker_$(printf '%02d' "$i").log"

    # Each worker runs the Godot binary in headless mode.
    # --headless   — no window, no GPU context required
    # --speed N    — N× simulation time-scale (handled by simulation_main.gd)
    # The export .pck is loaded automatically from the binary's directory.
    # Arguments after -- are treated as user args by Godot (OS.get_cmdline_user_args())
    # and are read by simulation_main.gd for --speed and --heightmap.
    EXTRA_ARGS=()
    if [[ -n "$HEIGHTMAP" ]]; then
        EXTRA_ARGS=(--heightmap "${HEIGHTMAP}")
    fi

    # Write directly to log file — $! is the real Godot PID
    "${GODOT_BINARY}" \
        --headless \
        -- \
        --speed "${SIM_SPEED}" \
        "${EXTRA_ARGS[@]+"${EXTRA_ARGS[@]}"}" \
        > "${WORKER_LOG}" 2>&1 &

    WORKER_PIDS+=($!)
    echo "[start] Worker ${i} PID: ${WORKER_PIDS[-1]}  (log: ${WORKER_LOG})"

    # Small stagger to avoid all workers hammering the server simultaneously
    # at startup.  0.2 s × 20 workers = 4 s total ramp-up.
    sleep 0.2
done

echo "[start] All ${WORKER_COUNT} workers launched."
echo ""
echo "Follow progress:"
echo "  tail -f ${ORCH_LOG}"
echo "  tail -f ${LOG_DIR}/worker_01.log"
echo ""

# ---------------------------------------------------------------------------
# Wait for the orchestrator to finish
# ---------------------------------------------------------------------------
# The orchestrator process exits once all GA generations are complete.
# We wait for it here; the trap will clean up the workers afterwards.

echo "[wait] Waiting for orchestrator to complete all generations..."
wait "$ORCH_PID"
ORCH_EXIT=$?

if [[ $ORCH_EXIT -eq 0 ]]; then
    echo ""
    echo "============================================================"
    echo " GA optimisation complete!"
    echo "  Best schedule : ${SCRIPT_DIR}/ga_results/best_schedule.json"
    echo "  History       : ${SCRIPT_DIR}/ga_results/generation_history.json"
    echo "  Full log      : ${ORCH_LOG}"
    echo "============================================================"
else
    echo "[ERROR] Orchestrator exited with code ${ORCH_EXIT}."
    echo "        Check ${ORCH_LOG} for details."
fi
