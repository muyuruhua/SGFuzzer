#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# replay_gcov_coverage.sh
#
# Replay SGFuzz corpus files through a GCC-gcov-instrumented live555 server
# and produce a `cov_over_time.csv` in the exact ChatAFL format:
#
#   Time,elapsed_seconds,l_per,l_abs,b_per,b_abs
#
# This is a NEW external adapter script (OCP-compliant: no modification to
# any existing SGFuzz file).
#
# ── Caliber-alignment with ChatAFL cov_script.sh ──
#   1. Replay method:  RTSP-protocol-aware (split on \r\n\r\n, send each
#      message separately with a short delay) — equivalent to aflnet-replay.
#   2. Server lifecycle: replay in background + timeout server in foreground
#      + wait — exactly mirroring ChatAFL's pattern.
#   3. Sampling:  Seed files (*.raw) get coverage collected for EVERY file.
#      Discovered inputs (all other files) use step-based sampling.
#   4. gcovr invocation:  cumulative (no -d after initial clear) — same as
#      ChatAFL.
#
# Usage:
#   replay_gcov_coverage.sh <corpus_dir> <gcov_build_dir> <port> <step> <output_csv> [run_start_epoch]
#
# Arguments:
#   corpus_dir     Directory containing corpus files (seeds + discovered inputs)
#   gcov_build_dir Path to the live-gcov build root (contains testProgs/)
#   port           TCP port for the gcov-instrumented RTSP server
#   step           Collect gcovr data every N test cases for non-seed files
#   output_csv     Output path for cov_over_time.csv
#   run_start_epoch Optional fuzz start epoch; if set, emit elapsed_seconds
# ─────────────────────────────────────────────────────────────────────────────
set -euo pipefail

corpus_dir="${1:?Usage: replay_gcov_coverage.sh <corpus_dir> <gcov_build_dir> <port> <step> <output_csv>}"
gcov_build_dir="${2:?}"
port="${3:?}"
step="${4:-5}"
output_csv="${5:?}"
run_start_epoch="${6:-}"

testprogs_dir="${gcov_build_dir}/testProgs"
server_bin="${testprogs_dir}/testOnDemandRTSPServer"

if [[ ! -x "${server_bin}" ]]; then
  echo "[replay-gcov] ERROR: server binary not found: ${server_bin}" >&2
  exit 1
fi

if [[ ! -d "${corpus_dir}" ]]; then
  echo "[replay-gcov] ERROR: corpus directory not found: ${corpus_dir}" >&2
  exit 1
fi

if ! command -v gcovr >/dev/null 2>&1; then
  echo "[replay-gcov] ERROR: gcovr not found in PATH" >&2
  exit 1
fi

# ── Helper: RTSP-protocol-aware replay ──────────────────────────────────────
# Equivalent to ChatAFL's `aflnet-replay $f RTSP $pno 1`.
# Splits the file on RTSP message boundaries (\r\n\r\n) and sends each
# message separately with a short inter-message delay so the server has
# time to process each request.  Falls back to sendall for non-parseable
# files (binary / fuzz-mutated data without clear boundaries).
replay_one_file() {
  local file="$1"
  local target_port="$2"

  python3 -c "
import socket, sys, time

PORT = int(sys.argv[1])
FILE = sys.argv[2]

with open(FILE, 'rb') as fh:
    data = fh.read()

# Split on RTSP message boundary (\\r\\n\\r\\n)
DELIM = b'\\r\\n\\r\\n'
parts = data.split(DELIM)

try:
    s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    s.settimeout(2)
    s.connect(('127.0.0.1', PORT))

    if len(parts) <= 1:
        # No clear RTSP boundaries — send raw (fuzz-mutated binary)
        s.sendall(data)
    else:
        # Send each RTSP message individually, re-appending the delimiter
        for i, part in enumerate(parts):
            if not part:
                continue
            msg = part + DELIM
            try:
                s.sendall(msg)
            except Exception:
                break
            # Brief pause to let server read & process
            time.sleep(0.05)
            # Try to receive response (non-blocking drain)
            try:
                s.recv(4096)
            except Exception:
                pass

    s.shutdown(socket.SHUT_WR)
    try:
        s.recv(4096)
    except Exception:
        pass
except Exception:
    pass
finally:
    try:
        s.close()
    except Exception:
        pass
" "${target_port}" "${file}" 2>/dev/null &
}

# ── Helper: run gcovr and append one row ────────────────────────────────────
normalize_elapsed_seconds() {
  local ts="$1"
  if [[ -z "${run_start_epoch}" ]] || ! [[ "${run_start_epoch}" =~ ^[0-9]+$ ]]; then
    printf '0'
    return 0
  fi

  if [[ "${ts}" =~ ^[0-9]+$ ]] && (( ts >= run_start_epoch )); then
    printf '%s' "$((ts - run_start_epoch))"
  else
    printf '0'
  fi
}

collect_coverage() {
  local ts="$1"
  local elapsed_seconds
  local cov_data
  cov_data="$(gcovr -r .. -s 2>/dev/null | grep "[lb][a-z]*:" || true)"

  local l_per l_abs b_per b_abs
  l_per="$(echo "${cov_data}" | grep lines  | cut -d" " -f2 | rev | cut -c2- | rev || true)"
  l_abs="$(echo "${cov_data}" | grep lines  | cut -d" " -f3 | cut -c2- || true)"
  b_per="$(echo "${cov_data}" | grep branch | cut -d" " -f2 | rev | cut -c2- | rev || true)"
  b_abs="$(echo "${cov_data}" | grep branch | cut -d" " -f3 | cut -c2- || true)"
  elapsed_seconds="$(normalize_elapsed_seconds "${ts}")"

  echo "${ts},${elapsed_seconds},${l_per:-0},${l_abs:-0},${b_per:-0},${b_abs:-0}" >> "${output_csv}"
}

# ── Initialise ──────────────────────────────────────────────────────────────
cd "${testprogs_dir}"

# Clear existing gcov data (initial reset, same as ChatAFL's first gcovr -d)
gcovr -r .. -s -d > /dev/null 2>&1 || true

# Create fresh output CSV with ChatAFL header
rm -f "${output_csv}"
echo "Time,elapsed_seconds,l_per,l_abs,b_per,b_abs" > "${output_csv}"

# ── Separate seed files from discovered inputs (ChatAFL caliber) ────────────
# ChatAFL processes *.raw (seeds) first with per-file gcovr, then id* files
# with step-based sampling.  For SGFuzz: we treat files whose name matches
# common seed patterns as seeds, everything else as discovered inputs.
mapfile -t seed_files < <(
  find "${corpus_dir}" -maxdepth 1 -type f \( -name '*.raw' -o -name 'seed*' \) \
    -printf '%T@ %p\n' 2>/dev/null | sort -n | awk '{print $2}'
)

mapfile -t discovered_files < <(
  find "${corpus_dir}" -maxdepth 1 -type f \
    ! -name '*.raw' ! -name 'seed*' \
    -printf '%T@ %p\n' 2>/dev/null | sort -n | awk '{print $2}'
)

total=$(( ${#seed_files[@]} + ${#discovered_files[@]} ))
if (( total == 0 )); then
  echo "[replay-gcov] WARNING: no corpus files found in ${corpus_dir}" >&2
  exit 0
fi

echo "[replay-gcov] Corpus: ${#seed_files[@]} seed(s), ${#discovered_files[@]} discovered inputs (step=${step})"
echo "[replay-gcov] Total: ${total} files to replay through gcov server on port ${port}"

# ── Phase 1: replay seed files — gcovr after EVERY file (ChatAFL pattern) ──
for f in "${seed_files[@]}"; do
  ts="$(stat -c '%Y' "${f}" 2>/dev/null || date +%s)"

  # Kill any leftover server
  pkill -f "testOnDemandRTSPServer.*${port}" 2>/dev/null || true
  sleep 0.1

  # ChatAFL pattern: replayer runs in background, server in foreground with
  # timeout that sends SIGUSR1 (triggers gcov flush) then SIGKILL.
  replay_one_file "${f}" "${port}"
  timeout -k 1s -s SIGUSR1 3s "${server_bin}" "${port}" > /dev/null 2>&1 || true

  wait 2>/dev/null || true

  # Collect gcovr for every seed (ChatAFL does this)
  collect_coverage "${ts}"
done

echo "[replay-gcov] Phase 1 done: ${#seed_files[@]} seed(s) replayed with per-file coverage"

# ── Phase 2: replay discovered inputs — step-based sampling (ChatAFL) ──────
count=0
for f in "${discovered_files[@]}"; do
  ts="$(stat -c '%Y' "${f}" 2>/dev/null || date +%s)"

  # Kill any leftover server
  pkill -f "testOnDemandRTSPServer.*${port}" 2>/dev/null || true
  sleep 0.1

  # Same lifecycle: replayer background + timeout server foreground
  replay_one_file "${f}" "${port}"
  timeout -k 1s -s SIGUSR1 3s "${server_bin}" "${port}" > /dev/null 2>&1 || true

  wait 2>/dev/null || true

  count=$((count + 1))

  # Step-based sampling (same as ChatAFL's `rem=$(expr $count % $step)`)
  if (( count % step != 0 )); then continue; fi

  collect_coverage "${ts}"

  # Progress indicator every 100 snapshots
  if (( (count / step) % 20 == 0 )); then
    echo "[replay-gcov] Progress: ${count}/${#discovered_files[@]} discovered inputs replayed"
  fi
done

# Final coverage snapshot for remainder (same as ChatAFL's trailing block)
if (( ${#discovered_files[@]} > 0 && count % step != 0 )); then
  ts="$(stat -c '%Y' "${f}" 2>/dev/null || date +%s)"
  collect_coverage "${ts}"
fi

rows="$(wc -l < "${output_csv}")"
rows=$((rows - 1))  # exclude header
echo "[replay-gcov] Done. ${rows} coverage snapshots written to ${output_csv}"
