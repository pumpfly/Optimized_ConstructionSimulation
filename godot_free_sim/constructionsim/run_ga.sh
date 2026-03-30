#!/usr/bin/env bash
# =============================================================================
# run_ga.sh — Launch a full GA optimisation run with N headless Go workers
# =============================================================================
#
# Usage
# -----
#   chmod +x run_ga.sh
#   ./run_ga.sh --heightmap terrain.png [OPTIONS]
#
# Options
#   -n, --workers     <N>     Number of simultaneous workers (default: 20)
#   -p, --population  <N>     GA population size (default: 20)
#   -g, --generations <N>     Number of GA generations (default: 50)
#   -m, --heightmap   <path>  Path to heightmap PNG (required)
#   -h, --help                Show this help and exit
#
# What it does
# ------------
# 1. Builds the orchestrator and worker binaries if not present.
# 2. Starts the Go orchestrator in the background.
# 3. Launches N workers in --fast (headless) mode, each logging to logs/.
# 4. Waits for all workers to finish (they exit when the GA is complete).
# 5. Cleans up the orchestrator on exit (including Ctrl-C).
#
# Output (written to ga_results/)
# --------------------------------
#   best_schedule.json      — Best spawn schedule found by the GA
#   generation_history.json — Per-generation best/avg/worst fitness
#   orchestrator.log        — Full orchestrator log
#
# Worker logs are written to logs/worker_<NN>.log
# =============================================================================

set -euo pipefail

# ---------------------------------------------------------------------------
# Defaults
# ---------------------------------------------------------------------------
WORKER_COUNT=20
POPULATION=20
GENERATIONS=50
HEIGHTMAP=""
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOG_DIR="${SCRIPT_DIR}/logs"
ORCH_LOG="${LOG_DIR}/orchestrator_stdout.log"
ORCH_ADDR="127.0.0.1:7050"

# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------
print_help() {
    sed -n '/^# Usage/,/^# ====*/p' "$0" | sed 's/^# \?//'
    exit 0
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        -n|--workers)     WORKER_COUNT="$2";  shift 2 ;;
        -p|--population)  POPULATION="$2";    shift 2 ;;
        -g|--generations) GENERATIONS="$2";   shift 2 ;;
        -m|--heightmap)   HEIGHTMAP="$2";     shift 2 ;;
        -h|--help)        print_help ;;
        *) echo "[ERROR] Unknown option: $1"; print_help ;;
    esac
done

if [[ -z "$HEIGHTMAP" ]]; then
    echo "[ERROR] --heightmap is required."
    echo "        Usage: $0 --heightmap <path> [OPTIONS]"
    exit 1
fi

if [[ ! -f "$HEIGHTMAP" ]]; then
    echo "[ERROR] Heightmap not found: ${HEIGHTMAP}"
    exit 1
fi

# ---------------------------------------------------------------------------
# Build binaries if needed
# ---------------------------------------------------------------------------
ORCH_BIN="${SCRIPT_DIR}/orchestrator"
WORKER_BIN="${SCRIPT_DIR}/worker"

echo "[build] Checking binaries..."
cd "${SCRIPT_DIR}"

if [[ ! -x "$ORCH_BIN" ]]; then
    echo "[build] Building orchestrator..."
    go build -o orchestrator ./cmd/orchestrator
fi

if [[ ! -x "$WORKER_BIN" ]]; then
    echo "[build] Building worker..."
    go build -o worker ./cmd/worker
fi

echo "[build] Binaries ready."

# ---------------------------------------------------------------------------
# Setup
# ---------------------------------------------------------------------------
mkdir -p "${LOG_DIR}"
mkdir -p "${SCRIPT_DIR}/ga_results"

echo "============================================================"
echo " GA Run"
echo "  Workers      : ${WORKER_COUNT}"
echo "  Population   : ${POPULATION}"
echo "  Generations  : ${GENERATIONS}"
echo "  Heightmap    : ${HEIGHTMAP}"
echo "  Log dir      : ${LOG_DIR}"
echo "  Results dir  : ${SCRIPT_DIR}/ga_results"
echo "============================================================"

# ---------------------------------------------------------------------------
# Process management
# ---------------------------------------------------------------------------
WORKER_PIDS=()
ORCH_PID=""

cleanup() {
    echo ""
    echo "[cleanup] Stopping all processes..."

    if [[ -n "$ORCH_PID" ]] && kill -0 "$ORCH_PID" 2>/dev/null; then
        kill "$ORCH_PID" 2>/dev/null && echo "[cleanup] Killed orchestrator PID ${ORCH_PID}"
    fi

    for pid in "${WORKER_PIDS[@]}"; do
        if kill -0 "$pid" 2>/dev/null; then
            kill "$pid" 2>/dev/null && echo "[cleanup] Killed worker PID ${pid}"
        fi
    done

    local remaining
    remaining=$(jobs -p 2>/dev/null || true)
    if [[ -n "$remaining" ]]; then
        echo "$remaining" | xargs -r kill 2>/dev/null || true
    fi

    echo "[cleanup] Done."
}

trap cleanup EXIT INT TERM

# ---------------------------------------------------------------------------
# Start orchestrator
# ---------------------------------------------------------------------------
echo "[start] Launching orchestrator..."
"${ORCH_BIN}" \
    -addr "${ORCH_ADDR}" \
    -population "${POPULATION}" \
    -generations "${GENERATIONS}" \
    > "${ORCH_LOG}" 2>&1 &
ORCH_PID=$!
echo "[start] Orchestrator PID: ${ORCH_PID}  (log: ${ORCH_LOG})"

# Stream orchestrator log to terminal with prefix
tail -f "${ORCH_LOG}" | awk '{print "[ORCH] " $0; fflush()}' &

# Wait for orchestrator to become ready (up to 30s)
echo "[start] Waiting for orchestrator to be ready..."
MAX_WAIT=30
WAITED=0
until curl -sf "http://${ORCH_ADDR}/" > /dev/null 2>&1; do
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
# Launch workers
# ---------------------------------------------------------------------------
echo "[start] Launching ${WORKER_COUNT} workers..."

for i in $(seq 1 "${WORKER_COUNT}"); do
    WORKER_LOG="${LOG_DIR}/worker_$(printf '%02d' "$i").log"

    "${WORKER_BIN}" \
        --heightmap "${HEIGHTMAP}" \
        --fast \
        > "${WORKER_LOG}" 2>&1 &

    WORKER_PIDS+=($!)
    echo "[start] Worker ${i} PID: ${WORKER_PIDS[-1]}  (log: ${WORKER_LOG})"

    # Stagger startup slightly so workers don't all hit the server at once
    sleep 0.2
done

echo "[start] All ${WORKER_COUNT} workers launched."
echo ""
echo "Follow progress:"
echo "  tail -f ${ORCH_LOG}"
echo "  tail -f ${LOG_DIR}/worker_01.log"
echo ""

# ---------------------------------------------------------------------------
# Wait for all workers to finish
# Workers exit cleanly when the orchestrator sends "end" (all generations done)
# ---------------------------------------------------------------------------
echo "[wait] Waiting for all workers to finish..."
for pid in "${WORKER_PIDS[@]}"; do
    wait "$pid" 2>/dev/null || true
done

echo ""
echo "============================================================"
echo " GA optimisation complete!"
echo "  Best schedule : ${SCRIPT_DIR}/ga_results/best_schedule.json"
echo "  History       : ${SCRIPT_DIR}/ga_results/generation_history.json"
echo "  Full log      : ${ORCH_LOG}"
echo "============================================================"
