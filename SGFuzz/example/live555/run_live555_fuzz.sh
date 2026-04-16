#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PRECHECK_SCRIPT="${SCRIPT_DIR}/precheck_live555.sh"
LIVE_BUILD_DIR="${LIVE_BUILD_DIR:-${SCRIPT_DIR}/live555-sgfuzz}"
TARGET_DIR="${LIVE_BUILD_DIR}/testProgs"
TARGET_BIN="${TARGET_BIN:-${TARGET_DIR}/testOnDemandRTSPServer}"
DICT_FILE="${DICT_FILE:-${SCRIPT_DIR}/rtsp.dict}"
CORPUS_DIR="${CORPUS_DIR:-${SCRIPT_DIR}/in-rtsp}"
ARTIFACT_DIR="${ARTIFACT_DIR:-${SCRIPT_DIR}/artifacts}"
PORT_START_VALUE="${HFND_TCP_PORT:-8554}"
RUN_TIMEOUT_SECONDS=""
RUN_COUNT=1
RUN_PARALLELISM=2
RSS_LIMIT_MB_VALUE="${LIBFUZZER_RSS_LIMIT_MB:-8192}"
# --- OCP extension: configurable libFuzzer RSS limit ---
# libFuzzer default is 2048 MB, but live555 seed loading alone uses ~1 GB and normal
# fuzzing grows to ~2 GB within 30-50 min, causing premature OOM on long (24h) runs.
# Default 8192 MB (8 GB): high enough for 24h normal operation, low enough to still
# detect true memory-bomb vulnerabilities (infinite allocation bugs).
# Set to 0 for unlimited (NOT recommended — loses OOM detection capability).
LIBFUZZER_RSS_LIMIT_MB="${RSS_LIMIT_MB_VALUE}"

usage() {
  cat <<'EOF'
Usage: run_live555_fuzz.sh [corpus_dir] [artifact_dir] [--runs N] [--parallelism N] [--timeout SECONDS] [--port-start PORT] [--rss-limit-mb MB]

Defaults:
  corpus_dir   -> ./in-rtsp
  artifact_dir -> ./artifacts
  runs         -> 1
  parallelism  -> 2
  timeout      -> unlimited (bare numbers are treated as minutes)
  port-start   -> 8554
  rss-limit-mb -> ${LIBFUZZER_RSS_LIMIT_MB:-8192} (0 disables libFuzzer RSS limit)
EOF
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  usage
  exit 0
fi

if [[ $# -gt 13 ]]; then
  usage >&2
  exit 1
fi

POSITIONAL_ARGS=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --timeout)
      shift
      [[ $# -gt 0 ]] || { usage >&2; exit 1; }
      RUN_TIMEOUT_SECONDS="$1"
      ;;
    --timeout=*)
      RUN_TIMEOUT_SECONDS="${1#*=}"
      ;;
    --runs)
      shift
      [[ $# -gt 0 ]] || { usage >&2; exit 1; }
      RUN_COUNT="$1"
      ;;
    --runs=*)
      RUN_COUNT="${1#*=}"
      ;;
    --parallelism)
      shift
      [[ $# -gt 0 ]] || { usage >&2; exit 1; }
      RUN_PARALLELISM="$1"
      ;;
    --parallelism=*)
      RUN_PARALLELISM="${1#*=}"
      ;;
    --port-start)
      shift
      [[ $# -gt 0 ]] || { usage >&2; exit 1; }
      PORT_START_VALUE="$1"
      ;;
    --port-start=*)
      PORT_START_VALUE="${1#*=}"
      ;;
    --rss-limit-mb)
      shift
      [[ $# -gt 0 ]] || { usage >&2; exit 1; }
      LIBFUZZER_RSS_LIMIT_MB="$1"
      ;;
    --rss-limit-mb=*)
      LIBFUZZER_RSS_LIMIT_MB="${1#*=}"
      ;;
    *)
      POSITIONAL_ARGS+=("$1")
      ;;
  esac
  shift
done

if [[ ${#POSITIONAL_ARGS[@]} -ge 1 ]]; then
  CORPUS_DIR="$(cd "${POSITIONAL_ARGS[0]}" && pwd)"
fi

if [[ ${#POSITIONAL_ARGS[@]} -ge 2 ]]; then
  ARTIFACT_DIR="$(mkdir -p "${POSITIONAL_ARGS[1]}" && cd "${POSITIONAL_ARGS[1]}" && pwd)"
fi

if [[ ${#POSITIONAL_ARGS[@]} -gt 2 ]]; then
  usage >&2
  exit 1
fi

if ! [[ "${RUN_COUNT}" =~ ^[0-9]+$ ]] || (( RUN_COUNT < 1 )); then
  echo "[run] Invalid runs value: ${RUN_COUNT}" >&2
  exit 1
fi

if ! [[ "${RUN_PARALLELISM}" =~ ^[0-9]+$ ]] || (( RUN_PARALLELISM < 1 )); then
  echo "[run] Invalid parallelism value: ${RUN_PARALLELISM}" >&2
  exit 1
fi

if (( RUN_PARALLELISM > RUN_COUNT )); then
  RUN_PARALLELISM="${RUN_COUNT}"
fi

if (( RUN_PARALLELISM > 1 )) && [[ "${LIVE555_ALLOW_PARALLEL:-0}" != "1" ]]; then
  echo "[run] Live555 parallel startup is disabled by default because multiple instances share network-facing resources." >&2
  echo "[run] Falling back to RUN_PARALLELISM=1. Set LIVE555_ALLOW_PARALLEL=1 only if each run is isolated in its own container or network namespace." >&2
  RUN_PARALLELISM=1
fi

if ! [[ "${PORT_START_VALUE}" =~ ^[0-9]+$ ]] || (( PORT_START_VALUE < 1 || PORT_START_VALUE > 65535 )); then
  echo "[run] Invalid port-start value: ${PORT_START_VALUE}" >&2
  exit 1
fi

if [[ -n "${RUN_TIMEOUT_SECONDS}" ]]; then
  if [[ "${RUN_TIMEOUT_SECONDS}" =~ ^[0-9]+$ ]]; then
    RUN_TIMEOUT_SECONDS="${RUN_TIMEOUT_SECONDS}m"
  elif ! [[ "${RUN_TIMEOUT_SECONDS}" =~ ^[0-9]+([smhd])$ ]]; then
    echo "[run] Invalid timeout value: ${RUN_TIMEOUT_SECONDS}" >&2
    exit 1
  fi
fi

if ! [[ "${LIBFUZZER_RSS_LIMIT_MB}" =~ ^[0-9]+$ ]]; then
  echo "[run] Invalid rss-limit-mb value: ${LIBFUZZER_RSS_LIMIT_MB}" >&2
  exit 1
fi

find_free_port() {
  local candidate_port="$1"
  local probe_port

  if [[ "${LIVE555_ASSUME_ISOLATED_NAMESPACE:-0}" == "1" ]]; then
    echo "${candidate_port}"
    return 0
  fi

  for ((probe_port = candidate_port; probe_port <= 65535; probe_port++)); do
    if command -v ss >/dev/null 2>&1; then
      if ! ss -H -ltn "sport = :${probe_port}" 2>/dev/null | grep -q .; then
        echo "${probe_port}"
        return 0
      fi
      continue
    fi

    if command -v lsof >/dev/null 2>&1; then
      if ! lsof -nP -iTCP:"${probe_port}" -sTCP:LISTEN 2>/dev/null | grep -q .; then
        echo "${probe_port}"
        return 0
      fi
      continue
    fi

    echo "[run] Neither 'ss' nor 'lsof' is available to find a free TCP port." >&2
    exit 1
  done

  echo "[run] No free TCP port found from ${candidate_port} to 65535" >&2
  exit 1
}

extract_metric_from_log() {
  local log_file="$1"
  local metric_name="$2"

  grep -Eo "${metric_name}:[[:space:]]*[0-9]+" "${log_file}" 2>/dev/null \
    | tail -n 1 \
    | sed -E 's/.*:[[:space:]]*([0-9]+)$/\1/' || true
}

extract_honggfuzz_summary_metric() {
  local log_file="$1"
  local metric_name="$2"

  grep -Eo "${metric_name}:[[:space:]]*[0-9]+" "${log_file}" 2>/dev/null \
    | tail -n 1 \
    | sed -E 's/.*:[[:space:]]*([0-9]+)$/\1/' || true
}

extract_loaded_counter_count() {
  local log_file="$1"

  grep -Eo 'Loaded[[:space:]]+[0-9]+ modules[[:space:]]+\(([0-9]+) inline 8-bit counters\)' "${log_file}" 2>/dev/null \
    | tail -n 1 \
    | sed -E 's/.*\(([0-9]+) inline 8-bit counters\).*/\1/' || true
}

extract_pc_table_count() {
  local log_file="$1"

  grep -Eo 'Loaded[[:space:]]+[0-9]+ PC tables \(([0-9]+) PCs\): ([0-9]+)' "${log_file}" 2>/dev/null \
    | tail -n 1 \
    | sed -E 's/.*\(([0-9]+) PCs\): ([0-9]+).*/\2/' || true
}

llvm_cov_tools_available() {
  command -v llvm-profdata >/dev/null 2>&1 && command -v llvm-cov >/dev/null 2>&1
}

postprocess_llvm_coverage() {
  local run_root="$1"
  local run_artifact_dir="${run_root}/artifacts"
  local run_profraw_dir="${run_artifact_dir}/llvm-profraw"
  local run_llvm_cov_dir="${run_artifact_dir}/llvm-cov"
  local run_profdata_file="${run_llvm_cov_dir}/merged.profdata"
  local run_export_json_file="${run_llvm_cov_dir}/export.json"
  local run_manifest_file="${run_llvm_cov_dir}/profraw-files.txt"
  local run_status_file="${run_llvm_cov_dir}/status.txt"

  mkdir -p "${run_llvm_cov_dir}"

  if [[ ! -d "${run_profraw_dir}" ]]; then
    printf 'status=no_profraw_dir\n' > "${run_status_file}"
    return 0
  fi

  mapfile -t run_profraw_files < <(find "${run_profraw_dir}" -type f -name '*.profraw' | sort)
  if (( ${#run_profraw_files[@]} == 0 )); then
    printf 'status=no_profraw_files\n' > "${run_status_file}"
    return 0
  fi

  # Inspect profraw sizes and filter out zero-byte files (they cause llvm-profdata to fail)
  local -a profraw_nonzero=()
  local -a profraw_zero=()
  for p in "${run_profraw_files[@]}"; do
    if [[ -f "$p" ]]; then
      sz=$(stat -c '%s' "$p" 2>/dev/null || echo 0)
      if [[ "$sz" -gt 0 ]]; then
        profraw_nonzero+=("$p")
      else
        profraw_zero+=("$p")
      fi
    fi
  done

  # write detailed manifest with sizes
  printf '%s\n' "# profraw files (size path)" > "${run_manifest_file}"
  if (( ${#profraw_nonzero[@]} > 0 )); then
    for p in "${profraw_nonzero[@]}"; do echo "$(stat -c '%s %n' "$p")" >> "${run_manifest_file}" || true; done
  fi
  if (( ${#profraw_zero[@]} > 0 )); then
    for p in "${profraw_zero[@]}"; do echo "0 $p" >> "${run_manifest_file}" || true; done
  fi

  if (( ${#profraw_nonzero[@]} == 0 )); then
    printf 'status=profraw_all_zero\nzero_count=%s\n' "${#profraw_zero[@]}" > "${run_status_file}"
    return 0
  fi

  printf '%s\n' "${run_profraw_files[@]}" > "${run_manifest_file}"

  if ! llvm_cov_tools_available; then
    printf 'status=llvm_tools_missing\n' > "${run_status_file}"
    return 0
  fi

  if ! llvm-profdata merge -sparse "${profraw_nonzero[@]}" -o "${run_profdata_file}"; then
    printf 'status=profdata_merge_failed\n' > "${run_status_file}"
    return 0
  fi

  if ! llvm-cov export "${TARGET_BIN}" -instr-profile="${run_profdata_file}" > "${run_export_json_file}"; then
    printf 'status=llvm_cov_export_failed\n' > "${run_status_file}"
    return 0
  fi

  printf 'status=exported\nprofraw_count=%s\nprofdata=%s\nexport_json=%s\n' \
    "${#run_profraw_files[@]}" \
    "${run_profdata_file}" \
    "${run_export_json_file}" > "${run_status_file}"
}

compute_branch_coverage_percent() {
  local covered_edges="$1"
  local guard_nb="$2"

  if [[ -z "${covered_edges}" || -z "${guard_nb}" || "${guard_nb}" == "0" ]]; then
    echo ""
    return 0
  fi

  awk -v covered_edges="${covered_edges}" -v guard_nb="${guard_nb}" 'BEGIN {
    printf("%.2f", (covered_edges * 100.0) / guard_nb)
  }'
}

is_timeout_exit_code() {
  local exit_code="$1"

  case "${exit_code}" in
    124|137|143)
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

duration_to_seconds() {
  local duration="$1"
  local value=""
  local unit=""

  if [[ -z "${duration}" ]]; then
    echo ""
    return 0
  fi

  if [[ "${duration}" =~ ^([0-9]+)([smhd])$ ]]; then
    value="${BASH_REMATCH[1]}"
    unit="${BASH_REMATCH[2]}"
  elif [[ "${duration}" =~ ^[0-9]+$ ]]; then
    value="${duration}"
    unit="s"
  else
    echo ""
    return 0
  fi

  case "${unit}" in
    s) echo "$((value))" ;;
    m) echo "$((value * 60))" ;;
    h) echo "$((value * 3600))" ;;
    d) echo "$((value * 86400))" ;;
  esac
}

compute_timeout_watchdog_seconds() {
  local duration="$1"
  local timeout_seconds=""
  # The watchdog timeout must be SIGNIFICANTLY larger than -max_total_time
  # because the fuzzer process includes substantial overhead BEFORE and DURING
  # the -max_total_time window:
  #
  # Phase 1 - Server startup (NOT counted by -max_total_time):
  #   1. Network namespace creation (CLONE_NEWUSER|CLONE_NEWNET|...)
  #   2. Live555 RTSP server thread startup
  #   3. Server readiness polling (500ms intervals)
  #   Total: 30-60+ seconds in Docker.
  #
  # Phase 2 - Seed corpus loading (counted by -max_total_time timer, but
  #   TimedOut() is only checked in the main fuzzing loop AFTER corpus loading):
  #   - 15164 seed files at ~56 exec/s = ~270 seconds
  #   - The -max_total_time timer expires during this phase, but the fuzzer
  #     won't notice until it enters the main loop.
  #
  # Phase 3 - Main fuzzing loop: TimedOut() is finally checked, loop breaks,
  #   FuzzerDriver calls exit(0) which triggers atexit() handlers including
  #   LLVM's __llvm_profile_write_file() → profraw is flushed.
  #
  # If the watchdog fires during Phase 2 (seed corpus loading), it sends
  # SIGINT which triggers InterruptCallback() → _Exit() → NO atexit →
  # profraw stays 0 bytes WITHOUT the LD_PRELOAD profraw flush library.
  # With profraw_flush_preload.so via LD_PRELOAD, _Exit() is intercepted
  # and profraw is flushed even in this case.
  #
  # Therefore the watchdog must cover: Phase1 + Phase2 + Phase3 + margin.
  # With 60s startup + 300s corpus + 30s fuzz + 60s margin = 450s minimum.
  #
  # Default margin: 600s (override via WATCHDOG_STARTUP_MARGIN env var).
  local startup_margin="${WATCHDOG_STARTUP_MARGIN:-600}"

  timeout_seconds="$(duration_to_seconds "${duration}")"
  if [[ -z "${timeout_seconds}" ]]; then
    echo ""
    return 0
  fi

  echo "$((timeout_seconds + startup_margin))"
}

count_crash_artifacts() {
  local artifact_dir="$1"

  count_artifacts_by_prefix "${artifact_dir}" "crash-"
}

count_graph_edges() {
  local graph_file="$1"

  if [[ -f "${graph_file}" ]]; then
    grep -c ' -> ' "${graph_file}" || true
  else
    echo ""
  fi
}

count_artifacts_by_prefix() {
  local artifact_dir="$1"
  local prefix="$2"

  if [[ -d "${artifact_dir}" ]]; then
    find "${artifact_dir}" -type f -name "${prefix}*" | wc -l | tr -d ' '
  else
    echo ""
  fi
}

count_unique_failure_signatures() {
  local artifact_dir="$1"

  if [[ -d "${artifact_dir}" ]]; then
    find "${artifact_dir}" -type f \( -name 'crash-*' -o -name 'oom-*' -o -name 'leak-*' \) -print0 \
      | xargs -0 -r sha1sum 2>/dev/null \
      | awk '{print $1}' \
      | sort -u \
      | wc -l \
      | tr -d ' '
  else
    echo ""
  fi
}

log_has_entered_fuzzing() {
  local log_file="$1"

  grep -Eq 'Fuzzing starts now!|INITED|states:' "${log_file}"
}

log_has_server_ready() {
  local log_file="$1"

  grep -Eq 'The server process is ready to accept connections' "${log_file}"
}

log_has_server_waiting() {
  local log_file="$1"

  grep -Eq 'Waiting for the TCP server process to start accepting connections' "${log_file}"
}

classify_startup_reason() {
  local exit_code="$1"
  local server_ready="$2"
  local server_waiting="$3"

  if [[ "${server_ready}" == "yes" ]]; then
    echo "ready"
    return 0
  fi

  if [[ "${server_waiting}" == "yes" ]]; then
    case "${exit_code}" in
      124)
        echo "timeout_waiting_for_server"
        ;;
      137|143)
        echo "killed_waiting_for_server"
        ;;
      *)
        echo "waiting_for_server"
        ;;
    esac
    return 0
  fi

  case "${exit_code}" in
    124)
      echo "timeout_before_server_ready"
      ;;
    137|143)
      echo "killed_before_server_ready"
      ;;
    0)
      echo "no_server_ready"
      ;;
    *)
      echo "server_start_failed"
      ;;
  esac
}

classify_failure_reason() {
  local exit_code="$1"
  local startup_ready="$2"
  local fuzz_started="$3"
  local timeout_triggered="$4"

  if [[ "${timeout_triggered}" == "yes" ]]; then
    if [[ "${fuzz_started}" == "yes" ]]; then
      echo "timeout_triggered_after_fuzz_start"
    else
      echo "timeout_triggered_before_fuzz"
    fi
    return 0
  fi

  if [[ "${fuzz_started}" == "yes" ]]; then
    if [[ "${exit_code}" -eq 0 ]]; then
      echo "none"
    else
      echo "fuzzing_exited_nonzero"
    fi
    return 0
  fi

  if [[ "${startup_ready}" != "yes" ]]; then
    case "${exit_code}" in
      124)
        echo "timeout_before_fuzz"
        ;;
      137|143)
        echo "killed_before_fuzz"
        ;;
      0)
        echo "exited_before_server_ready"
        ;;
      *)
        echo "server_not_ready"
        ;;
    esac
    return 0
  fi

  case "${exit_code}" in
    124)
      echo "timeout_after_server_ready"
      ;;
    137|143)
      echo "killed_after_server_ready"
      ;;
    0)
      echo "server_ready_but_no_fuzz"
      ;;
    *)
      echo "startup_ok_but_no_fuzz"
      ;;
  esac
}

# --- OCP extension: refine failure_reason by scanning log and artifacts ---
# Called AFTER classify_failure_reason() when it returns "none" (exit_code=0, fuzz_started=yes).
# Detects OOM / crash / leak that libFuzzer reports as exit(0) after writing an artifact.
# Does NOT modify classify_failure_reason(); it is a separate post-classification refinement.
detect_log_based_failure_reason() {
  local base_reason="$1"
  local run_log_file="$2"
  local run_artifact_dir="$3"

  # Only refine when the base classifier found no failure but fuzzing actually ran.
  if [[ "${base_reason}" != "none" ]]; then
    echo "${base_reason}"
    return 0
  fi

  # 1) Check log for libFuzzer OOM summary (highest priority — explains early exit).
  if [[ -f "${run_log_file}" ]] && grep -Fq 'SUMMARY: libFuzzer: out-of-memory' "${run_log_file}"; then
    echo "oom_detected"
    return 0
  fi

  # 2) Check for OOM artifacts on disk.
  if [[ -d "${run_artifact_dir}" ]]; then
    local oom_count
    oom_count="$(find "${run_artifact_dir}" -maxdepth 1 -name 'oom-*' -type f 2>/dev/null | wc -l)"
    if (( oom_count > 0 )); then
      echo "oom_detected"
      return 0
    fi
  fi

  # 3) Check log for libFuzzer deadly signal (crash after exit 0 is rare but possible).
  if [[ -f "${run_log_file}" ]] && grep -Fq 'SUMMARY: libFuzzer: deadly signal' "${run_log_file}"; then
    echo "crash_detected"
    return 0
  fi

  # 4) Check for crash artifacts on disk.
  if [[ -d "${run_artifact_dir}" ]]; then
    local crash_count
    crash_count="$(find "${run_artifact_dir}" -maxdepth 1 -name 'crash-*' -type f 2>/dev/null | wc -l)"
    if (( crash_count > 0 )); then
      echo "crash_detected"
      return 0
    fi
  fi

  # 5) Check log for memory leak summary.
  if [[ -f "${run_log_file}" ]] && grep -Fq 'SUMMARY: AddressSanitizer: detected memory leaks' "${run_log_file}"; then
    echo "leak_detected"
    return 0
  fi

  # 6) Check for leak artifacts on disk.
  if [[ -d "${run_artifact_dir}" ]]; then
    local leak_count
    leak_count="$(find "${run_artifact_dir}" -maxdepth 1 -name 'leak-*' -type f 2>/dev/null | wc -l)"
    if (( leak_count > 0 )); then
      echo "leak_detected"
      return 0
    fi
  fi

  echo "${base_reason}"
}

classify_run_phase() {
  local exit_code="$1"
  local fuzz_started="$2"

  if [[ "${fuzz_started}" == "yes" ]]; then
    if [[ "${exit_code}" -eq 0 ]]; then
      echo "fuzzing"
    else
      echo "fuzzing_error"
    fi
    return 0
  fi

  case "${exit_code}" in
    124)
      echo "timeout_before_fuzz"
      ;;
    137|143)
      echo "killed_before_fuzz"
      ;;
    0)
      echo "no_fuzz_start"
      ;;
    *)
      echo "failed_before_fuzz"
      ;;
  esac
}

write_run_metadata_files() {
  local run_root="$1"
  local run_log_file="$2"
  local run_exit_code="$3"
  local run_status_file="${run_root}/run.status"
  local run_exit_code_file="${run_root}/run.exit_code"
  local run_timeout_triggered_file="${run_root}/run.timeout_triggered"
  local run_startup_ready_file="${run_root}/run.startup_ready"
  local run_startup_reason_file="${run_root}/run.startup_reason"
  local run_failure_reason_file="${run_root}/run.failure_reason"
  local run_phase_file="${run_root}/run.phase"
  local run_fuzz_started_file="${run_root}/run.fuzz_started"
  local run_timeout_triggered="no"
  local run_fuzz_started="no"
  local run_startup_ready="no"
  local run_startup_reason="unknown"
  local run_failure_reason="unknown"
  local run_phase="unknown"
  local run_start_epoch_file="${run_root}/run.start_epoch"
  local run_end_epoch_file="${run_root}/run.end_epoch"
  local timeout_seconds=""
  local run_start_epoch=""
  local run_end_epoch=""
  local run_elapsed_seconds=""

  if [[ -n "${RUN_TIMEOUT_SECONDS}" ]] && is_timeout_exit_code "${run_exit_code}"; then
    run_timeout_triggered="yes"
  fi

  timeout_seconds="$(duration_to_seconds "${RUN_TIMEOUT_SECONDS}")"
  if [[ "${run_timeout_triggered}" == "no" && -n "${timeout_seconds}" ]]; then
    if [[ -f "${run_start_epoch_file}" ]]; then
      run_start_epoch="$(<"${run_start_epoch_file}")"
    fi
    if [[ -f "${run_end_epoch_file}" ]]; then
      run_end_epoch="$(<"${run_end_epoch_file}")"
    fi
    if [[ "${run_start_epoch}" =~ ^[0-9]+$ && "${run_end_epoch}" =~ ^[0-9]+$ && "${run_end_epoch}" -ge "${run_start_epoch}" ]]; then
      run_elapsed_seconds="$((run_end_epoch - run_start_epoch))"
    fi
    if [[ -n "${run_elapsed_seconds}" && "${run_elapsed_seconds}" -ge "$((timeout_seconds - 1))" ]] \
      && [[ -f "${run_log_file}" ]] \
      && grep -Fq 'libFuzzer: run interrupted; exiting' "${run_log_file}"; then
      run_timeout_triggered="yes"
      if [[ "${run_exit_code}" == "0" ]]; then
        run_exit_code="124"
      fi
    fi
  fi

  if [[ -f "${run_log_file}" ]] && log_has_entered_fuzzing "${run_log_file}"; then
    run_fuzz_started="yes"
  fi

  if [[ -f "${run_log_file}" ]] && log_has_server_ready "${run_log_file}"; then
    run_startup_ready="yes"
  fi

  if [[ -f "${run_log_file}" ]] && log_has_server_waiting "${run_log_file}"; then
    run_startup_reason="$(classify_startup_reason "${run_exit_code}" "${run_startup_ready}" "yes")"
  else
    run_startup_reason="$(classify_startup_reason "${run_exit_code}" "${run_startup_ready}" "no")"
  fi

  run_failure_reason="$(classify_failure_reason "${run_exit_code}" "${run_startup_ready}" "${run_fuzz_started}" "${run_timeout_triggered}")"
  # --- OCP extension: refine failure_reason via log/artifact scanning ---
  local run_artifact_dir="${run_root}/artifacts"
  run_failure_reason="$(detect_log_based_failure_reason "${run_failure_reason}" "${run_log_file}" "${run_artifact_dir}")"
  run_phase="$(classify_run_phase "${run_exit_code}" "${run_fuzz_started}")"

  printf '%s\n' "${run_exit_code}" > "${run_status_file}"
  printf '%s\n' "${run_exit_code}" > "${run_exit_code_file}"
  printf '%s\n' "${run_timeout_triggered}" > "${run_timeout_triggered_file}"
  printf '%s\n' "${run_startup_ready}" > "${run_startup_ready_file}"
  printf '%s\n' "${run_startup_reason}" > "${run_startup_reason_file}"
  printf '%s\n' "${run_failure_reason}" > "${run_failure_reason_file}"
  printf '%s\n' "${run_phase}" > "${run_phase_file}"
  printf '%s\n' "${run_fuzz_started}" > "${run_fuzz_started_file}"
}

write_summary_csv() {
  local summary_csv="$1"
  shift

  printf 'run_index,port,status,exit_code,timeout_triggered,startup_ready,startup_reason,failure_reason,phase,fuzz_started,cov,ft,states,leaves,exec_per_sec,guard_nb,branch_coverage_percent,inline_8bit_counters,pc_tables,crash_artifacts,timeout_artifacts,oom_artifacts,leak_artifacts,bug_artifacts,unique_bug_signatures,mutation_graph_edges,run_root,log_file,artifact_dir\n' > "${summary_csv}"

  for run_root in "$@"; do
    local run_index_file="${run_root}/run.index"
    local run_port_file="${run_root}/run.port"
    local run_status_file="${run_root}/run.status"
    local run_exit_code_file="${run_root}/run.exit_code"
    local run_timeout_triggered_file="${run_root}/run.timeout_triggered"
    local run_startup_ready_file="${run_root}/run.startup_ready"
    local run_startup_reason_file="${run_root}/run.startup_reason"
    local run_failure_reason_file="${run_root}/run.failure_reason"
    local run_phase_file="${run_root}/run.phase"
    local run_fuzz_started_file="${run_root}/run.fuzz_started"
    local run_mutation_graph_file="${run_root}/artifacts/mutation_graph.dot"
    local run_log_file="${run_root}/run.log"
    local run_artifact_dir="${run_root}/artifacts"
    local run_index=""
    local run_port=""
    local run_status=""
    local run_exit_code=""
    local run_timeout_triggered="no"
    local run_startup_ready="no"
    local run_startup_reason="unknown"
    local run_failure_reason="unknown"
    local run_phase=""
    local run_fuzz_started="no"
    local run_cov=""
    local run_ft=""
    local run_states=""
    local run_leaves=""
    local run_exec_per_sec=""
    local run_guard_nb=""
    local run_branch_coverage_percent=""
    local run_inline_8bit_counters=""
    local run_pc_tables=""
    local run_crash_artifacts=""
    local run_timeout_artifacts=""
    local run_oom_artifacts=""
    local run_leak_artifacts=""
    local run_bug_artifacts=""
    local run_unique_bug_signatures=""
    local run_mutation_graph_edges=""

    if [[ -f "${run_index_file}" ]]; then
      run_index="$(<"${run_index_file}")"
    fi
    if [[ -f "${run_port_file}" ]]; then
      run_port="$(<"${run_port_file}")"
    fi
    if [[ -f "${run_status_file}" ]]; then
      run_status="$(<"${run_status_file}")"
    else
      run_status="unknown"
    fi

    if [[ -f "${run_exit_code_file}" ]]; then
      run_exit_code="$(<"${run_exit_code_file}")"
    else
      run_exit_code="unknown"
    fi

    if [[ -f "${run_timeout_triggered_file}" ]]; then
      run_timeout_triggered="$(<"${run_timeout_triggered_file}")"
    fi

    if [[ -f "${run_startup_ready_file}" ]]; then
      run_startup_ready="$(<"${run_startup_ready_file}")"
    fi

    if [[ -f "${run_startup_reason_file}" ]]; then
      run_startup_reason="$(<"${run_startup_reason_file}")"
    fi

    if [[ -f "${run_failure_reason_file}" ]]; then
      run_failure_reason="$(<"${run_failure_reason_file}")"
    fi

    if [[ -f "${run_phase_file}" ]]; then
      run_phase="$(<"${run_phase_file}")"
    else
      run_phase="unknown"
    fi

    if [[ -f "${run_fuzz_started_file}" ]]; then
      run_fuzz_started="$(<"${run_fuzz_started_file}")"
    fi

    if [[ -f "${run_log_file}" && "${run_fuzz_started}" == "yes" ]]; then
      run_cov="$(extract_metric_from_log "${run_log_file}" "cov")"
      run_ft="$(extract_metric_from_log "${run_log_file}" "ft")"
      run_states="$(extract_metric_from_log "${run_log_file}" "states")"
      run_leaves="$(extract_metric_from_log "${run_log_file}" "leaves")"
      run_exec_per_sec="$(extract_metric_from_log "${run_log_file}" "exec/s")"
      run_guard_nb="$(extract_honggfuzz_summary_metric "${run_log_file}" "guard_nb")"
      run_branch_coverage_percent="$(extract_honggfuzz_summary_metric "${run_log_file}" "branch_coverage_percent")"
      run_inline_8bit_counters="$(extract_loaded_counter_count "${run_log_file}")"
      run_pc_tables="$(extract_pc_table_count "${run_log_file}")"
      if [[ -z "${run_branch_coverage_percent}" ]]; then
        run_branch_coverage_percent="$(compute_branch_coverage_percent "${run_cov:-}" "${run_guard_nb:-}")"
      fi
    fi

    run_crash_artifacts="$(count_crash_artifacts "${run_artifact_dir}")"
    run_timeout_artifacts="$(count_artifacts_by_prefix "${run_artifact_dir}" "timeout-")"
    run_oom_artifacts="$(count_artifacts_by_prefix "${run_artifact_dir}" "oom-")"
    run_leak_artifacts="$(count_artifacts_by_prefix "${run_artifact_dir}" "leak-")"
    run_bug_artifacts="$(( ${run_crash_artifacts:-0} + ${run_oom_artifacts:-0} + ${run_leak_artifacts:-0} ))"
    run_unique_bug_signatures="$(count_unique_failure_signatures "${run_artifact_dir}")"
    run_mutation_graph_edges="$(count_graph_edges "${run_mutation_graph_file}")"

    printf '%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s\n' \
      "${run_index:-unknown}" \
      "${run_port:-unknown}" \
      "${run_status}" \
      "${run_exit_code}" \
      "${run_timeout_triggered}" \
      "${run_startup_ready}" \
      "${run_startup_reason}" \
      "${run_failure_reason}" \
      "${run_phase}" \
      "${run_fuzz_started}" \
      "${run_cov:-}" \
      "${run_ft:-}" \
      "${run_states:-}" \
        "${run_leaves:-}" \
        "${run_exec_per_sec:-}" \
      "${run_guard_nb:-}" \
      "${run_branch_coverage_percent:-}" \
      "${run_inline_8bit_counters:-}" \
      "${run_pc_tables:-}" \
        "${run_crash_artifacts:-}" \
      "${run_timeout_artifacts:-}" \
      "${run_oom_artifacts:-}" \
      "${run_leak_artifacts:-}" \
      "${run_bug_artifacts:-}" \
      "${run_unique_bug_signatures:-}" \
      "${run_mutation_graph_edges:-}" \
      "${run_root}" \
      "${run_log_file}" \
      "${run_artifact_dir}" >> "${summary_csv}"
  done
}

run_round_impl() {
  local run_index="$1"
  local run_port="$2"
  local run_root="$3"
  local run_artifact_dir="${run_root}/artifacts"
  local run_features_dir="${run_artifact_dir}/features"
  local run_profraw_dir="${run_artifact_dir}/llvm-profraw"
  local run_mutation_graph_file="${run_artifact_dir}/mutation_graph.dot"
  local run_log_file="${run_root}/run.log"
  local fuzz_max_total_time_seconds=""
  local watchdog_timeout_seconds=""

  mkdir -p "${run_artifact_dir}"
  mkdir -p "${run_features_dir}"
  mkdir -p "${run_profraw_dir}"

  export HFND_TCP_PORT="${run_port}"
  export LLVM_PROFILE_FILE="${run_profraw_dir}/${run_index}_%p.profraw"

  # --- OCP extension: LD_PRELOAD profraw flush ---
  # Instead of patching FuzzerLoop.cpp, we inject a preload library that
  # intercepts _Exit()/_exit() to flush LLVM profraw data before termination.
  # Check PROFRAW_FLUSH_PRELOAD_SO env var first (set by parallel Docker launcher),
  # then fall back to looking next to this script.
  local preload_so="${PROFRAW_FLUSH_PRELOAD_SO:-${SCRIPT_DIR}/profraw_flush_preload.so}"
  if [[ -f "${preload_so}" ]]; then
    export LD_PRELOAD="${preload_so}${LD_PRELOAD:+:${LD_PRELOAD}}"
    echo "[run ${run_index}/${RUN_COUNT}] LD_PRELOAD: ${LD_PRELOAD}"
  fi

  echo "[run ${run_index}/${RUN_COUNT}] Starting Live555 SGFuzz target..."
  echo "[run ${run_index}/${RUN_COUNT}] Binary   : ${TARGET_BIN}"
  echo "[run ${run_index}/${RUN_COUNT}] Corpus   : ${CORPUS_DIR}"
  echo "[run ${run_index}/${RUN_COUNT}] Artifacts: ${run_artifact_dir}"
  echo "[run ${run_index}/${RUN_COUNT}] Log      : ${run_log_file}"
  echo "[run ${run_index}/${RUN_COUNT}] Port     : ${HFND_TCP_PORT}"
  echo "[run ${run_index}/${RUN_COUNT}] LLVM profraw: ${LLVM_PROFILE_FILE}"

  if [[ -n "${RUN_TIMEOUT_SECONDS}" ]]; then
    echo "[run ${run_index}/${RUN_COUNT}] Timeout  : ${RUN_TIMEOUT_SECONDS}"
  fi

  fuzz_max_total_time_seconds="$(duration_to_seconds "${RUN_TIMEOUT_SECONDS}")"
  watchdog_timeout_seconds="$(compute_timeout_watchdog_seconds "${RUN_TIMEOUT_SECONDS}")"

  if [[ -n "${watchdog_timeout_seconds}" ]]; then
    echo "[run ${run_index}/${RUN_COUNT}] -max_total_time : ${fuzz_max_total_time_seconds}s (from Fuzzer object creation)"
    echo "[run ${run_index}/${RUN_COUNT}] Watchdog timeout: ${watchdog_timeout_seconds}s (from process start, margin=${WATCHDOG_STARTUP_MARGIN:-600}s)"
    echo "[run ${run_index}/${RUN_COUNT}] NOTE: Watchdog must exceed startup (~60s) + seed corpus loading (~270s) + max_total_time."
    echo "[run ${run_index}/${RUN_COUNT}] NOTE: Normal exit path: TimedOut() break → exit(0) → atexit → profraw flush."
    echo "[run ${run_index}/${RUN_COUNT}] NOTE: If watchdog fires first: SIGINT → _Exit() → profraw flush via LD_PRELOAD (if loaded)."
  fi

  export HFND_TCP_PORT
  local precheck_exit_code=0
  set +e
  "${PRECHECK_SCRIPT}"
  precheck_exit_code=$?
  set -e

  if (( precheck_exit_code != 0 )); then
    echo "[run ${run_index}/${RUN_COUNT}] Precheck failed with exit code ${precheck_exit_code}"
    return "${precheck_exit_code}"
  fi

  local target_cmd=(
    "${TARGET_BIN}"
    -close_fd_mask=3
    -detect_leaks=0
    -dict="${DICT_FILE}"
    -only_ascii=1
    -features_dir="${run_features_dir}"
    -mutation_graph_file="${run_mutation_graph_file}"
    "${CORPUS_DIR}"
    -artifact_prefix="${run_artifact_dir}/"
  )

  if [[ -n "${fuzz_max_total_time_seconds}" ]]; then
    target_cmd+=("-max_total_time=${fuzz_max_total_time_seconds}")
  fi

  # --- OCP extension: inject rss_limit_mb to prevent premature OOM ---
  if [[ -n "${LIBFUZZER_RSS_LIMIT_MB}" ]]; then
    target_cmd+=("-rss_limit_mb=${LIBFUZZER_RSS_LIMIT_MB}")
  fi

  if [[ -n "${RUN_TIMEOUT_SECONDS}" ]]; then
    if command -v timeout >/dev/null 2>&1; then
      if [[ -n "${watchdog_timeout_seconds}" ]]; then
        timeout --signal=INT --kill-after=5s "${watchdog_timeout_seconds}s" "${target_cmd[@]}"
      else
        timeout --signal=INT --kill-after=5s "${RUN_TIMEOUT_SECONDS}" "${target_cmd[@]}"
      fi
    else
      echo "[run ${run_index}/${RUN_COUNT}] Warning: 'timeout' command not found, running without time limit."
      "${target_cmd[@]}"
    fi
  else
    "${target_cmd[@]}"
  fi

  echo "[run ${run_index}/${RUN_COUNT}] Finished"

  # Unset LD_PRELOAD so downstream tools (llvm-profdata, etc.) aren't affected.
  unset LD_PRELOAD 2>/dev/null || true

  # Small delay to allow instrumented runtime to flush profile outputs (if any)
  sleep 1

  # Log profraw files and sizes for debugging/diagnostics
  echo "[run ${run_index}/${RUN_COUNT}] Profraw listing for ${run_profraw_dir}:"
  if compgen -G "${run_profraw_dir}/*.profraw" >/dev/null 2>&1; then
    for f in "${run_profraw_dir}"/*.profraw; do
      if [[ -e "$f" ]]; then
        stat --format='%s %n' "$f" || ls -l "$f" || true
      fi
    done
  else
    echo "[run ${run_index}/${RUN_COUNT}] (no profraw files found)"
  fi
}

if [[ ! -x "${PRECHECK_SCRIPT}" ]]; then
  chmod +x "${PRECHECK_SCRIPT}" >/dev/null 2>&1 || true
fi

export ASAN_OPTIONS="${ASAN_OPTIONS:-alloc_dealloc_mismatch=0:detect_leaks=0}"
export LIVE555_ASSUME_ISOLATED_NAMESPACE
export RUN_PARALLELISM

cd "${TARGET_DIR}"

final_results_dir="${ARTIFACT_DIR}/results-live555_$(date +%b-%d_%H-%M-%S)"
archive_suffix=0
while [[ -e "${final_results_dir}" ]]; do
  archive_suffix=$((archive_suffix + 1))
  final_results_dir="${ARTIFACT_DIR}/results-live555_$(date +%b-%d_%H-%M-%S)_${archive_suffix}"
done
mkdir -p "${final_results_dir}"

echo "[run] Launching ${RUN_COUNT} rounds with parallelism ${RUN_PARALLELISM}"
echo "[run] Final results dir: ${final_results_dir}"

overall_status=0
running_count=0
declare -a run_roots=()

for ((run_index = 1; run_index <= RUN_COUNT; run_index++)); do
  run_port_candidate=$((PORT_START_VALUE + run_index - 1))
  run_port="$(find_free_port "${run_port_candidate}")"
  run_stamp="$(date +%b-%d_%H-%M-%S)"
  run_root="${final_results_dir}/${run_stamp}_run$(printf '%02d' "${run_index}")_port${run_port}"
  run_log_file="${run_root}/run.log"
  run_index_file="${run_root}/run.index"
  run_port_file="${run_root}/run.port"
  run_status_file="${run_root}/run.status"
  run_exit_code_file="${run_root}/run.exit_code"
  run_timeout_triggered_file="${run_root}/run.timeout_triggered"
  run_startup_ready_file="${run_root}/run.startup_ready"
  run_startup_reason_file="${run_root}/run.startup_reason"
  run_failure_reason_file="${run_root}/run.failure_reason"
  run_phase_file="${run_root}/run.phase"
  run_fuzz_started_file="${run_root}/run.fuzz_started"
  run_start_epoch_file="${run_root}/run.start_epoch"
  run_end_epoch_file="${run_root}/run.end_epoch"

  mkdir -p "${run_root}"
  : > "${run_log_file}"
  printf '%s\n' "${run_index}" > "${run_index_file}"
  printf '%s\n' "${run_port}" > "${run_port_file}"
  date +%s > "${run_start_epoch_file}"

  echo "[run] Queueing round ${run_index}/${RUN_COUNT} -> ${run_root}"
  run_roots+=("${run_root}")

  (
    exec >"${run_log_file}" 2>&1
    run_exit_code=0
    metadata_written=0

    finalize_run_metadata() {
      local finalize_status="${1:-${run_exit_code:-0}}"

      if [[ "${metadata_written}" == "1" ]]; then
        return 0
      fi

      if [[ -z "${run_exit_code:-}" || "${run_exit_code}" == "0" ]] && [[ "${finalize_status}" != "0" ]]; then
        run_exit_code="${finalize_status}"
      fi

      date +%s > "${run_end_epoch_file}"
      write_run_metadata_files "${run_root}" "${run_log_file}" "${run_exit_code}"
      metadata_written=1
    }

    trap 'trap_status=$?; finalize_run_metadata "${trap_status}"' EXIT
    trap 'if [[ -n "${RUN_TIMEOUT_SECONDS}" ]]; then run_exit_code=124; exit 124; else run_exit_code=143; exit 143; fi' TERM
    trap 'run_exit_code=130; exit 130' INT

    if run_round_impl "${run_index}" "${run_port}" "${run_root}"; then
      run_exit_code=0
    else
      run_exit_code=$?
    fi

    postprocess_llvm_coverage "${run_root}" || true

    finalize_run_metadata "${run_exit_code}"
    exit "${run_exit_code}"
  ) &

  running_count=$((running_count + 1))

  if (( running_count >= RUN_PARALLELISM )); then
    if ! wait -n; then
      overall_status=1
    fi
    running_count=$((running_count - 1))
  fi
done

while (( running_count > 0 )); do
  if ! wait -n; then
    overall_status=1
  fi
  running_count=$((running_count - 1))
done

summary_csv="${final_results_dir}/summary.csv"
write_summary_csv "${summary_csv}" "${run_roots[@]}"

for run_root in "${run_roots[@]}"; do
  if [[ -d "${run_root}" ]]; then
    if ! tar -czf "${run_root}.tar.gz" -C "${final_results_dir}" "$(basename "${run_root}")"; then
      echo "[run] Warning: failed to archive ${run_root}" >&2
    fi
  fi
done

echo "[run] Final results archived to ${final_results_dir}"

exit "${overall_status}"
