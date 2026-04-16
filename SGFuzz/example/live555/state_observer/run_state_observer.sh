#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CORPUS_DIR="${1:?usage: run_state_observer.sh <corpus_dir> <output_dir> <port> [corpus_format]}"
OUTPUT_DIR="${2:?}"
PORT="${3:?}"
CORPUS_FORMAT="${4:-auto}"
RUN_START_EPOCH="${5:-${STATE_OBSERVER_RUN_START_EPOCH:-0}}"

PARSER_BIN="${SCRIPT_DIR}/bin/rtsp_state_parser"
if [[ ! -x "${PARSER_BIN}" ]]; then
  "${SCRIPT_DIR}/build_state_observer.sh" >/dev/null
fi

mkdir -p "${OUTPUT_DIR}"

exec python3 "${SCRIPT_DIR}/replay_and_observe.py" \
  "${CORPUS_DIR}" \
  "${OUTPUT_DIR}" \
  --parser-bin "${PARSER_BIN}" \
  --port "${PORT}" \
  --corpus-format "${CORPUS_FORMAT}" \
  --trim "${STATE_OBSERVER_TRIM:-triple}" \
  --socket-timeout "${STATE_OBSERVER_SOCKET_TIMEOUT:-0.2}" \
  --inter-message-delay "${STATE_OBSERVER_INTER_MESSAGE_DELAY:-0.05}" \
  --startup-delay "${STATE_OBSERVER_STARTUP_DELAY:-0.05}" \
  --server-ready-timeout "${STATE_OBSERVER_SERVER_READY_TIMEOUT:-1.5}" \
  --server-kill-delay "${STATE_OBSERVER_SERVER_KILL_DELAY:-1.0}" \
  --input-timeout "${STATE_OBSERVER_INPUT_TIMEOUT:-4.0}" \
  --run-start-epoch "${RUN_START_EPOCH}" \
  --server-cmd "cd ${LIVE_GCOV_DIR:-/home/ubuntu/experiments/live-gcov}/testProgs && exec timeout -k ${STATE_OBSERVER_SERVER_KILL_DELAY:-1}s -s SIGUSR1 ${STATE_OBSERVER_SERVER_TIMEOUT:-3}s ./testOnDemandRTSPServer ${PORT}"
