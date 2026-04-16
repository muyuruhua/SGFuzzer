#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIVE_BUILD_DIR="${LIVE_BUILD_DIR:-${SCRIPT_DIR}/live555-sgfuzz}"
TARGET_BIN="${TARGET_BIN:-${LIVE_BUILD_DIR}/testProgs/testOnDemandRTSPServer}"
DICT_FILE="${DICT_FILE:-${SCRIPT_DIR}/rtsp.dict}"
CORPUS_DIR="${CORPUS_DIR:-${SCRIPT_DIR}/in-rtsp}"
ASAN_OPTIONS_VALUE="${ASAN_OPTIONS:-alloc_dealloc_mismatch=0:detect_leaks=0}"
HFND_TCP_PORT_VALUE="${HFND_TCP_PORT:-8554}"
RUN_PARALLELISM_VALUE="${RUN_PARALLELISM:-1}"

fatal() {
  echo "[precheck] $*" >&2
  exit 1
}

check_file() {
  [[ -f "$1" ]] || fatal "Missing file: $1"
}

check_dir() {
  [[ -d "$1" ]] || fatal "Missing directory: $1"
}

check_port() {
  if ! [[ "${HFND_TCP_PORT_VALUE}" =~ ^[0-9]+$ ]]; then
    fatal "HFND_TCP_PORT must be numeric, got: ${HFND_TCP_PORT_VALUE}"
  fi
  if (( HFND_TCP_PORT_VALUE < 1 || HFND_TCP_PORT_VALUE > 65535 )); then
    fatal "HFND_TCP_PORT must be between 1 and 65535, got: ${HFND_TCP_PORT_VALUE}"
  fi
}

check_port_available() {
  if [[ "${LIVE555_ASSUME_ISOLATED_NAMESPACE:-0}" == "1" ]]; then
    echo "[precheck] Skipping TCP port availability probe because the run is isolated in its own namespace."
    return 0
  fi

  if command -v ss >/dev/null 2>&1; then
    if ss -H -ltnp "sport = :${HFND_TCP_PORT_VALUE}" 2>/dev/null | grep -q .; then
      echo "[precheck] TCP port ${HFND_TCP_PORT_VALUE} is already in use:" >&2
      ss -H -ltnp "sport = :${HFND_TCP_PORT_VALUE}" 2>/dev/null >&2
      fatal "Please stop the process above or choose another HFND_TCP_PORT"
    fi
    return 0
  fi

  if command -v lsof >/dev/null 2>&1; then
    if lsof -nP -iTCP:"${HFND_TCP_PORT_VALUE}" -sTCP:LISTEN 2>/dev/null | grep -q .; then
      echo "[precheck] TCP port ${HFND_TCP_PORT_VALUE} is already in use:" >&2
      lsof -nP -iTCP:"${HFND_TCP_PORT_VALUE}" -sTCP:LISTEN 2>/dev/null >&2
      fatal "Please stop the process above or choose another HFND_TCP_PORT"
    fi
    return 0
  fi

  fatal "Neither 'ss' nor 'lsof' is available to verify TCP port ${HFND_TCP_PORT_VALUE}"
}

echo "[precheck] Checking Live555 SGFuzz setup..."

if [[ "${RUN_PARALLELISM_VALUE}" =~ ^[0-9]+$ ]] && (( RUN_PARALLELISM_VALUE > 1 )) && [[ "${LIVE555_ALLOW_PARALLEL:-0}" != "1" ]]; then
  echo "[precheck] Warning: Live555 parallel startup is disabled by default because the server can stall in the TCP-ready phase when multiple instances share the same namespace." >&2
  echo "[precheck] For reliable results, use --parallelism 1, or set LIVE555_ALLOW_PARALLEL=1 only when each run is fully isolated." >&2
fi

check_file "${TARGET_BIN}"
check_file "${DICT_FILE}"
check_dir "${CORPUS_DIR}"
check_port
check_port_available

if ! command -v conda >/dev/null 2>&1; then
  echo "[precheck] conda not found; make sure sgfuzz_env is already active."
else
  current_env="${CONDA_DEFAULT_ENV:-}"
  if [[ "${current_env}" != "sgfuzz_env" ]]; then
    echo "[precheck] Current conda env: ${current_env:-<none>}"
    echo "[precheck] Recommended env: sgfuzz_env"
  fi
fi

if [[ "${ASAN_OPTIONS_VALUE}" != *"alloc_dealloc_mismatch=0"* ]]; then
  echo "[precheck] Warning: ASAN_OPTIONS does not include alloc_dealloc_mismatch=0"
fi

if [[ "${ASAN_OPTIONS_VALUE}" != *"detect_leaks=0"* ]]; then
  echo "[precheck] Warning: ASAN_OPTIONS does not include detect_leaks=0"
fi

echo "[precheck] OK"
echo "[precheck] Binary: ${TARGET_BIN}"
echo "[precheck] Dict:   ${DICT_FILE}"
echo "[precheck] Corpus: ${CORPUS_DIR}"
echo "[precheck] Port:   ${HFND_TCP_PORT_VALUE}"
