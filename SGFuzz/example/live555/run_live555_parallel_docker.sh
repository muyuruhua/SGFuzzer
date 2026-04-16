#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEFAULT_IMAGE="${LIVE555_DOCKER_IMAGE:-live555-sgfuzz:latest}"
DEFAULT_PROFILE_IMAGE="${LIVE555_DOCKER_PROFILE_IMAGE:-live555-sgfuzz-profraw}"
METRIC_ADAPTER_SCRIPT="${SCRIPT_DIR}/export_chatAFL_metrics.py"
RUN_COUNT=2
RUN_PARALLELISM=2
RUN_TIMEOUT_SECONDS=""
PORT_START_VALUE="${HFND_TCP_PORT:-8554}"
IMAGE_NAME="${DEFAULT_IMAGE}"
TRACE_WORKER_INDEX="${LIVE555_TRACE_WORKER:-}"
RSS_LIMIT_MB_VALUE="${LIBFUZZER_RSS_LIMIT_MB:-8192}"
# --- OCP extension: optional Docker memory limit per container ---
# E.g. DOCKER_MEMORY_LIMIT="8g" to cap each worker at 8 GB.
# Empty = no limit (Docker default). Set via env or --docker-memory flag.
DOCKER_MEMORY_LIMIT="${DOCKER_MEMORY_LIMIT:-}"
LIBFUZZER_RSS_LIMIT_MB="${RSS_LIMIT_MB_VALUE}"
GCOV_REPLAY_ENABLED="${LIVE555_GCOV_REPLAY:-0}"
GCOV_REPLAY_IMAGE="${LIVE555_GCOV_REPLAY_IMAGE:-live555-sgfuzz-gcov-replay:latest}"
GCOV_REPLAY_STEP="${LIVE555_GCOV_REPLAY_STEP:-5}"
GCOV_REPLAY_SCRIPT="${SCRIPT_DIR}/replay_gcov_coverage.sh"
STATE_OBSERVER_ENABLED="${LIVE555_STATE_OBSERVER:-0}"
STATE_OBSERVER_IMAGE="${LIVE555_STATE_OBSERVER_IMAGE:-${GCOV_REPLAY_IMAGE}}"
STATE_OBSERVER_SCRIPT_DIR="${SCRIPT_DIR}/state_observer"

usage() {
  cat <<'EOF'
Usage: run_live555_parallel_docker.sh [--runs N] [--parallelism N] [--timeout SECONDS] [--port-start PORT] [--image IMAGE] [--docker-memory LIMIT] [--rss-limit-mb MB] [--gcov-replay] [--gcov-step N] [--state-observer]

Defaults:
  runs         -> 2
  parallelism  -> 2
  timeout      -> unlimited (bare numbers are treated as minutes)
  port-start   -> 8554
  image        -> prefer live555-sgfuzz-profraw, else live555-sgfuzz:latest
  docker-memory -> unset (e.g. --docker-memory 8g to cap each container at 8 GB)
  rss-limit-mb -> ${LIBFUZZER_RSS_LIMIT_MB:-8192} (0 disables libFuzzer RSS limit)
  trace-worker -> unset (set LIVE555_TRACE_WORKER=2 to strace only worker02)
  gcov-replay  -> disabled (enable to replay corpus through gcov-instrumented binary)
  gcov-step    -> 5 (collect gcovr data every N corpus files during replay)
  state-observer -> disabled (enable external observable state node/edge replay)

Each round runs in its own Docker container with `--network none`, so the TCP-ready phase is isolated.
After completion, the script also tries to export ChatAFL-style metrics CSVs
(`l_abs`, `b_abs`, `nodes`, `edges`, etc.) via `export_chatAFL_metrics.py`.
`nodes` / `edges` remain blank when SGFuzz cannot provide IPSM-equivalent data.
EOF
}

fatal() {
  echo "[parallel] $*" >&2
  exit 1
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  usage
  exit 0
fi

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
    --docker-memory)
      shift
      [[ $# -gt 0 ]] || { usage >&2; exit 1; }
      DOCKER_MEMORY_LIMIT="$1"
      ;;
    --docker-memory=*)
      DOCKER_MEMORY_LIMIT="${1#*=}"
      ;;
    --rss-limit-mb)
      shift
      [[ $# -gt 0 ]] || { usage >&2; exit 1; }
      LIBFUZZER_RSS_LIMIT_MB="$1"
      ;;
    --rss-limit-mb=*)
      LIBFUZZER_RSS_LIMIT_MB="${1#*=}"
      ;;
    --image)
      shift
      [[ $# -gt 0 ]] || { usage >&2; exit 1; }
      IMAGE_NAME="$1"
      ;;
    --image=*)
      IMAGE_NAME="${1#*=}"
      ;;
    --gcov-replay)
      GCOV_REPLAY_ENABLED=1
      ;;
    --gcov-step)
      shift
      [[ $# -gt 0 ]] || { usage >&2; exit 1; }
      GCOV_REPLAY_STEP="$1"
      ;;
    --gcov-step=*)
      GCOV_REPLAY_STEP="${1#*=}"
      ;;
    --state-observer)
      STATE_OBSERVER_ENABLED=1
      ;;
    *)
      usage >&2
      exit 1
      ;;
  esac
  shift
done

if ! [[ "${RUN_COUNT}" =~ ^[0-9]+$ ]] || (( RUN_COUNT < 1 )); then
  fatal "Invalid runs value: ${RUN_COUNT}"
fi

if ! [[ "${RUN_PARALLELISM}" =~ ^[0-9]+$ ]] || (( RUN_PARALLELISM < 1 )); then
  fatal "Invalid parallelism value: ${RUN_PARALLELISM}"
fi

if (( RUN_PARALLELISM > RUN_COUNT )); then
  RUN_PARALLELISM="${RUN_COUNT}"
fi

if ! [[ "${PORT_START_VALUE}" =~ ^[0-9]+$ ]] || (( PORT_START_VALUE < 1 || PORT_START_VALUE > 65535 )); then
  fatal "Invalid port-start value: ${PORT_START_VALUE}"
fi

if [[ -n "${RUN_TIMEOUT_SECONDS}" ]]; then
  if [[ "${RUN_TIMEOUT_SECONDS}" =~ ^[0-9]+$ ]]; then
    RUN_TIMEOUT_SECONDS="${RUN_TIMEOUT_SECONDS}m"
  elif ! [[ "${RUN_TIMEOUT_SECONDS}" =~ ^[0-9]+([smhd])$ ]]; then
    fatal "Invalid timeout value: ${RUN_TIMEOUT_SECONDS}"
  fi
fi

if ! [[ "${LIBFUZZER_RSS_LIMIT_MB}" =~ ^[0-9]+$ ]]; then
  fatal "Invalid rss-limit-mb value: ${LIBFUZZER_RSS_LIMIT_MB}"
fi

if ! command -v docker >/dev/null 2>&1; then
  fatal "docker is not available on this host"
fi

if [[ -z "${LIVE555_DOCKER_IMAGE:-}" ]] && docker image inspect "${DEFAULT_PROFILE_IMAGE}" >/dev/null 2>&1; then
  IMAGE_NAME="${DEFAULT_PROFILE_IMAGE}"
fi

if ! docker image inspect "${IMAGE_NAME}" >/dev/null 2>&1; then
  if docker image inspect "${DEFAULT_PROFILE_IMAGE}" >/dev/null 2>&1; then
    echo "[parallel] Image '${IMAGE_NAME}' not found; falling back to '${DEFAULT_PROFILE_IMAGE}'" >&2
    IMAGE_NAME="${DEFAULT_PROFILE_IMAGE}"
  elif docker image inspect live555-sgfuzz:latest >/dev/null 2>&1; then
    echo "[parallel] Image '${IMAGE_NAME}' not found; falling back to 'live555-sgfuzz:latest'" >&2
    IMAGE_NAME="live555-sgfuzz:latest"
  else
    fatal "Docker image '${IMAGE_NAME}' not found. Build or load it first, or pass --image <name>."
  fi
fi

# ---------------------------------------------------------------------------
# Auto-detect the live555 build directory inside the Docker image.
# The path depends on which Dockerfile was used to build the image:
#   Dockerfile        -> /home/ubuntu/experiments/live555-sgfuzz
#   Dockerfile.profraw -> /home/ubuntu/experiments/live555-sgfuzz-profraw
# We probe the image once rather than guessing from the image name.
# ---------------------------------------------------------------------------
detect_live_build_dir() {
  local image="$1"
  local detected
  detected="$(docker run --rm "${image}" bash -c '
    for d in /home/ubuntu/experiments/live555-sgfuzz-profraw \
             /home/ubuntu/experiments/live555-sgfuzz; do
      if [[ -d "$d/testProgs" ]]; then echo "$d"; exit 0; fi
    done
    echo "__NOTFOUND__"; exit 1
  ' 2>/dev/null)" || true
  printf '%s' "${detected}"
}

DETECTED_LIVE_BUILD_DIR="$(detect_live_build_dir "${IMAGE_NAME}")"
if [[ -z "${DETECTED_LIVE_BUILD_DIR}" || "${DETECTED_LIVE_BUILD_DIR}" == "__NOTFOUND__" ]]; then
  fatal "Cannot locate live555 build directory inside image '${IMAGE_NAME}'. Expected live555-sgfuzz or live555-sgfuzz-profraw under /home/ubuntu/experiments/."
fi
echo "[parallel] Detected build dir : ${DETECTED_LIVE_BUILD_DIR}"

# ---------------------------------------------------------------------------
# Gcov-replay: detect image availability
# ---------------------------------------------------------------------------
if [[ "${GCOV_REPLAY_ENABLED}" == "1" ]]; then
  if ! docker image inspect "${GCOV_REPLAY_IMAGE}" >/dev/null 2>&1; then
    echo "[parallel] WARNING: gcov-replay image '${GCOV_REPLAY_IMAGE}' not found." >&2
    echo "[parallel] Build it with: docker build -f Dockerfile.gcov-replay -t ${GCOV_REPLAY_IMAGE} ." >&2
    echo "[parallel] Disabling gcov-replay for this run." >&2
    GCOV_REPLAY_ENABLED=0
  else
    echo "[parallel] Gcov-replay  : ENABLED (image=${GCOV_REPLAY_IMAGE}, step=${GCOV_REPLAY_STEP})"
  fi
fi

if [[ "${STATE_OBSERVER_ENABLED}" == "1" ]]; then
  if ! docker image inspect "${STATE_OBSERVER_IMAGE}" >/dev/null 2>&1; then
    echo "[parallel] WARNING: state-observer image '${STATE_OBSERVER_IMAGE}' not found." >&2
    echo "[parallel] Build it with: docker build -f Dockerfile.gcov-replay -t ${STATE_OBSERVER_IMAGE} ." >&2
    echo "[parallel] Disabling state-observer for this run." >&2
    STATE_OBSERVER_ENABLED=0
  else
    echo "[parallel] State-observer: ENABLED (image=${STATE_OBSERVER_IMAGE})"
  fi
fi

timestamp="$(date +%b-%d_%H-%M-%S)"
parallel_root="${SCRIPT_DIR}/artifacts/parallel-results-live555_${timestamp}"
mkdir -p "${parallel_root}"

# Directory on the host to receive container gcov `.gcda` files. Can be
# overridden via environment: export HOST_GCOV_DIR=/path/to/dir
HOST_GCOV_DIR="${HOST_GCOV_DIR:-${SCRIPT_DIR}/../temp_gcda/live-gcov}"
mkdir -p "${HOST_GCOV_DIR}"
echo "[parallel] Host gcov collection dir: ${HOST_GCOV_DIR}"

echo "[parallel] Using image: ${IMAGE_NAME}"
echo "[parallel] Launch root : ${parallel_root}"
echo "[parallel] Rounds      : ${RUN_COUNT}"
echo "[parallel] Parallelism : ${RUN_PARALLELISM}"

declare -a worker_roots=()
cleanup_containers() {
  local id_file
  while IFS= read -r -d '' id_file; do
    if [[ -s "${id_file}" ]]; then
      docker rm -f "$(<"${id_file}")" >/dev/null 2>&1 || true
    fi
  done < <(find "${parallel_root}" -type f -name container.id -print0 2>/dev/null)
}

trap cleanup_containers EXIT INT TERM

wait_for_worker_exit_code() {
  local worker_root="$1"
  local worker_exit_code=""
  local worker_result_dir=""
  local worker_run_exit_file=""

  for _ in $(seq 1 120); do
    worker_result_dir="$(find "${worker_root}" -type d -name 'results-live555_*' | head -n 1 || true)"
    worker_run_exit_file="$(find "${worker_result_dir:-${worker_root}}" -type f -name 'run.exit_code' | head -n 1 || true)"
    if [[ -n "${worker_run_exit_file}" ]]; then
      printf '%s\n' "${worker_result_dir}"
      printf '%s\n' "$(<"${worker_run_exit_file}")"
      return 0
    fi
    sleep 0.5
  done

  worker_result_dir="$(find "${worker_root}" -type d -name 'results-live555_*' | head -n 1 || true)"
  if [[ -n "${worker_result_dir}" ]]; then
    worker_run_exit_file="$(find "${worker_result_dir}" -type f -name 'run.exit_code' | head -n 1 || true)"
    if [[ -n "${worker_run_exit_file}" ]]; then
      worker_exit_code="$(<"${worker_run_exit_file}")"
    fi
    printf '%s\n' "${worker_result_dir}"
    printf '%s\n' "${worker_exit_code}"
    return 0
  fi

  if [[ -f "${worker_root}/container.exit_code" ]]; then
    printf '%s\n' ""
    printf '%s\n' "$(<"${worker_root}/container.exit_code")"
    return 0
  fi

  printf '%s\n' ""
  printf '%s\n' "unknown"
}

read_final_exit_code() {
  local worker_root="$1"
  local worker_result_dir=""
  local worker_run_exit_file=""

  worker_result_dir="$(find "${worker_root}" -type d -name 'results-live555_*' | head -n 1 || true)"
  worker_run_exit_file="$(find "${worker_result_dir:-${worker_root}}" -type f -name 'run.exit_code' | head -n 1 || true)"
  if [[ -n "${worker_run_exit_file}" ]]; then
    cat "${worker_run_exit_file}"
    return 0
  fi

  if [[ -f "${worker_root}/container.exit_code" ]]; then
    cat "${worker_root}/container.exit_code"
    return 0
  fi

  printf '%s\n' "unknown"
}

generate_normalized_metrics_csv() {
  local search_root="$1"
  local output_csv="$2"
  local scope_label="$3"
  local log_file="${output_csv}.log"

  if [[ ! -d "${search_root}" ]]; then
    echo "[parallel] Skipping ${scope_label} metric export; search root not found: ${search_root}" >&2
    return 1
  fi

  if [[ ! -f "${METRIC_ADAPTER_SCRIPT}" ]]; then
    echo "[parallel] Skipping ${scope_label} metric export; adapter not found: ${METRIC_ADAPTER_SCRIPT}" >&2
    return 1
  fi

  if ! command -v python3 >/dev/null 2>&1; then
    echo "[parallel] Skipping ${scope_label} metric export; python3 is unavailable" >&2
    return 1
  fi

  if python3 "${METRIC_ADAPTER_SCRIPT}" "${search_root}" -o "${output_csv}" > "${log_file}" 2>&1; then
    echo "[parallel] ${scope_label} ChatAFL-style metrics: ${output_csv}"
    return 0
  fi

  echo "[parallel] ${scope_label} metric export failed; see ${log_file}" >&2
  return 1
}

validate_run_export_jsons() {
  local search_root="$1"
  local scope_label="$2"
  local -a run_dirs=()
  local run_dir=""
  local export_json=""
  local gcov_csv=""
  local failed=0

  if [[ ! -d "${search_root}" ]]; then
    echo "[parallel] ${scope_label} coverage validation skipped; root not found: ${search_root}" >&2
    return 1
  fi

  mapfile -t run_dirs < <(find "${search_root}" -maxdepth 4 -type d -name '*_run*_port*' | sort)
  if (( ${#run_dirs[@]} == 0 )); then
    echo "[parallel] ${scope_label} coverage validation failed; no run directories found under ${search_root}" >&2
    return 1
  fi

  for run_dir in "${run_dirs[@]}"; do
    export_json="${run_dir}/artifacts/llvm-cov/export.json"
    gcov_csv="${run_dir}/artifacts/gcov/cov_over_time.csv"
    # Accept either llvm-cov export.json OR gcov cov_over_time.csv as valid
    # coverage data.  export_chatAFL_metrics.py prefers gcov when available,
    # so the gcov CSV alone is sufficient for l_abs/b_abs extraction.
    if [[ ! -s "${export_json}" ]] && [[ ! -s "${gcov_csv}" ]]; then
      echo "[parallel] ${scope_label} missing coverage data in $(basename "${run_dir}"): no llvm-cov export.json and no gcov cov_over_time.csv" >&2
      failed=1
    fi
  done

  if (( failed == 0 )); then
    echo "[parallel] ${scope_label} coverage data validation passed"
    return 0
  fi

  return 1
}

validate_normalized_metrics_csv() {
  local output_csv="$1"
  local scope_label="$2"
  local validation_log="${output_csv}.validation.log"

  if [[ ! -s "${output_csv}" ]]; then
    echo "[parallel] ${scope_label} metrics validation failed; CSV missing: ${output_csv}" >&2
    return 1
  fi

  if ! command -v python3 >/dev/null 2>&1; then
    echo "[parallel] ${scope_label} metrics validation failed; python3 is unavailable" >&2
    return 1
  fi

  if python3 - "${output_csv}" > "${validation_log}" 2>&1 <<'PY'
import csv
import sys
from pathlib import Path

csv_path = Path(sys.argv[1])
with csv_path.open("r", encoding="utf-8", newline="") as handle:
    reader = csv.DictReader(handle)
    rows = list(reader)

if not rows:
    print("no_rows")
    raise SystemExit(1)

missing = []
for index, row in enumerate(rows, start=1):
    run = (row.get("run") or row.get("run_index") or str(index)).strip() or str(index)
    l_abs = (row.get("l_abs") or "").strip()
    b_abs = (row.get("b_abs") or "").strip()
    if not l_abs or not b_abs:
        missing.append((run, l_abs, b_abs))

if missing:
    for run, l_abs, b_abs in missing:
        print(f"run={run} missing_l_abs={int(not bool(l_abs))} missing_b_abs={int(not bool(b_abs))}")
    raise SystemExit(1)

print(f"validated_rows={len(rows)}")
PY
  then
    echo "[parallel] ${scope_label} l_abs/b_abs validation passed"
    return 0
  fi

  echo "[parallel] ${scope_label} metrics validation failed; see ${validation_log}" >&2
  return 1
}

check_worker_result_integrity() {
  local worker_root="$1"
  local result_info=""
  local result_dir=""
  local -a missing=()
  local -a run_dirs=()
  local run_dir=""
  local run_exit_file=""
  local run_tarball=""

  result_info="$(wait_for_worker_exit_code "${worker_root}")"
  result_dir="$(printf '%s\n' "${result_info}" | sed -n '1p')"

  if [[ -z "${result_dir}" ]]; then
    missing+=("result_dir")
  elif [[ ! -d "${result_dir}" ]]; then
    missing+=("result_dir(missing on disk)")
  fi

  if [[ -n "${result_dir}" ]]; then
    if [[ ! -f "${result_dir}/summary.csv" ]]; then
      missing+=("summary.csv")
    fi

    mapfile -t run_dirs < <(find "${result_dir}" -maxdepth 1 -type d -name '*_run*_port*' | sort)
    if (( ${#run_dirs[@]} == 0 )); then
      missing+=("run_dir")
    else
      for run_dir in "${run_dirs[@]}"; do
        run_exit_file="${run_dir}/run.exit_code"
        run_tarball="${run_dir}.tar.gz"

        if [[ ! -f "${run_exit_file}" ]]; then
          missing+=("$(basename "${run_dir}")/run.exit_code")
        fi
        if [[ ! -f "${run_tarball}" ]]; then
          missing+=("$(basename "${run_dir}").tar.gz")
        fi
        if [[ ! -f "${run_dir}/run.log" ]]; then
          missing+=("$(basename "${run_dir}")/run.log")
        fi
        if [[ ! -d "${run_dir}/artifacts" ]]; then
          missing+=("$(basename "${run_dir}")/artifacts")
        fi
      done
    fi
  fi

  if (( ${#missing[@]} > 0 )); then
    printf '[parallel] Incomplete worker output: %s\n' "${worker_root}" >&2
    printf '[parallel]   result_dir: %s\n' "${result_dir:-<missing>}" >&2
    for run_dir in "${missing[@]}"; do
      printf '[parallel]   missing: %s\n' "${run_dir}" >&2
    done
    return 1
  fi

  return 0
}

launch_worker() {
  local run_index="$1"
  local worker_port="$2"
  local worker_root="${parallel_root}/worker$(printf '%02d' "${run_index}")"
  local worker_log_file="${worker_root}/docker.log"
  local worker_artifact_dir_rel="/results/worker$(printf '%02d' "${run_index}")"
  local container_name="live555-worker-$(printf '%02d' "${run_index}")-${timestamp//[: ]/-}"
  local container_script
  local container_id
  local container_exit_code="unknown"
  local log_pid
  local trace_prefix=""

  mkdir -p "${worker_root}"

  if [[ -n "${TRACE_WORKER_INDEX}" && "${TRACE_WORKER_INDEX}" == "${run_index}" ]]; then
    trace_prefix='mkdir -p "$WORKER_ARTIFACT_DIR/trace" && exec strace -ff -o "$WORKER_ARTIFACT_DIR/trace/live555"'
  fi

  container_script='cd /work && '
  # --- OCP extension: build profraw_flush_preload.so inside container ---
  # Build to /tmp to avoid write conflicts on the shared /work mount.
  # run_live555_fuzz.sh auto-detects PROFRAW_FLUSH_PRELOAD_SO if set.
  container_script+='if [ -f profraw_flush_preload.c ] && [ ! -f /tmp/profraw_flush_preload.so ]; then gcc -shared -fPIC -O2 -o /tmp/profraw_flush_preload.so profraw_flush_preload.c -ldl 2>/dev/null || true; fi && export PROFRAW_FLUSH_PRELOAD_SO=/tmp/profraw_flush_preload.so && '
  if [[ -n "${trace_prefix}" ]]; then
    container_script+="${trace_prefix} "
  fi
  container_script+='./run_live555_fuzz.sh ./in-rtsp "$WORKER_ARTIFACT_DIR" --runs 1 --parallelism 1 --port-start "$HFND_TCP_PORT"'
  if [[ -n "${RUN_TIMEOUT_SECONDS}" ]]; then
    container_script+=' --timeout "$RUN_TIMEOUT_SECONDS"'
  fi
  container_script+=' --rss-limit-mb "$LIBFUZZER_RSS_LIMIT_MB"'

  # Use the auto-detected build directory (probed once at startup).
  local profile_env_args=(
    -e LIVE_BUILD_DIR="${DETECTED_LIVE_BUILD_DIR}"
    -e TARGET_DIR="${DETECTED_LIVE_BUILD_DIR}/testProgs"
    -e TARGET_BIN="${DETECTED_LIVE_BUILD_DIR}/testProgs/testOnDemandRTSPServer"
    -e DICT_FILE="/home/ubuntu/experiments/rtsp.dict"
    -e CORPUS_DIR="/home/ubuntu/experiments/in-rtsp"
  )

  # --- OCP extension: Docker memory limit + libFuzzer RSS limit passthrough ---
  local memory_args=()
  if [[ -n "${DOCKER_MEMORY_LIMIT}" ]]; then
    memory_args+=(--memory "${DOCKER_MEMORY_LIMIT}")
  fi
  if [[ -n "${LIBFUZZER_RSS_LIMIT_MB}" ]]; then
    memory_args+=(-e "LIBFUZZER_RSS_LIMIT_MB=${LIBFUZZER_RSS_LIMIT_MB}")
  fi

  container_id="$(docker run -d \
    --name "${container_name}" \
    --network none \
    --privileged \
    "${memory_args[@]+${memory_args[@]}}" \
    -e HFND_TCP_PORT="${worker_port}" \
    -e WORKER_ARTIFACT_DIR="${worker_artifact_dir_rel}" \
    -e RUN_TIMEOUT_SECONDS="${RUN_TIMEOUT_SECONDS}" \
    -e LIVE555_ALLOW_PARALLEL=1 \
    -e LIVE555_ASSUME_ISOLATED_NAMESPACE=1 \
    "${profile_env_args[@]}" \
    -v "${SCRIPT_DIR}:/work" \
    -v "${parallel_root}:/results" \
    -v "${HOST_GCOV_DIR}:/home/ubuntu/experiments/live-gcov" \
    -w /work \
    "${IMAGE_NAME}" \
    bash -lc "${container_script}")"

  printf '[parallel] worker%02d container id: %.12s\n' "${run_index}" "${container_id}"
  printf '[parallel] worker%02d container id: %s\n' "${run_index}" "${container_id}" >> "${worker_log_file}"
  printf '%s\n' "${container_id}" > "${worker_root}/container.id"
  docker logs -f "${container_id}" >> "${worker_log_file}" 2>&1 &
  log_pid=$!

  container_exit_code="$(docker wait "${container_id}")"
  wait "${log_pid}" || true
  printf '%s\n' "${container_exit_code}" > "${worker_root}/container.exit_code"

  # Backup any gcov outputs from the container into the per-worker folder as
  # redundancy in case the mount did not work or for historical inspection.
  mkdir -p "${worker_root}/live-gcov" || true
  docker cp "${container_id}:/home/ubuntu/experiments/live-gcov" "${worker_root}/live-gcov" >/dev/null 2>&1 || true

  # ── OCP addition: save evolved corpus (in-rtsp/) from the fuzzer container ─
  # Honggfuzz/libfuzzer writes new discovered inputs back into in-rtsp/ during
  # fuzzing.  We must capture this evolved corpus BEFORE docker rm so that the
  # gcov-replay phase can replay the same corpus the fuzzer actually explored,
  # matching ChatAFL's methodology of replaying the fuzzer's output queue.
  mkdir -p "${worker_root}/corpus" || true
  docker cp "${container_id}:/home/ubuntu/experiments/in-rtsp" "${worker_root}/corpus/in-rtsp" >/dev/null 2>&1 || true

  docker rm -f "${container_id}" >/dev/null 2>&1 || true

  local result_info
  result_info="$(wait_for_worker_exit_code "${worker_root}")"
  local result_dir
  local result_exit_code
  result_dir="$(printf '%s\n' "${result_info}" | sed -n '1p')"
  result_exit_code="$(printf '%s\n' "${result_info}" | sed -n '2p')"
  if [[ -n "${result_dir}" ]]; then
    printf '%s\n' "${result_dir}" > "${worker_root}/result_dir"
  fi
  if [[ -n "${result_exit_code}" && "${result_exit_code}" != "unknown" ]]; then
    container_exit_code="${result_exit_code}"
  fi

  if [[ "${container_exit_code}" =~ ^[0-9]+$ ]]; then
    return "${container_exit_code}"
  fi

  return 1
}

running_count=0

for ((run_index = 1; run_index <= RUN_COUNT; run_index++)); do
  worker_port="${PORT_START_VALUE}"
  worker_root="${parallel_root}/worker$(printf '%02d' "${run_index}")"
  worker_roots+=("${worker_root}")

  (
    launch_worker "${run_index}" "${worker_port}"
  ) &
  running_count=$((running_count + 1))

  if (( running_count >= RUN_PARALLELISM )); then
    wait -n || true
    running_count=$((running_count - 1))
  fi
done

while (( running_count > 0 )); do
  wait -n || true
  running_count=$((running_count - 1))
done

for worker_root in "${worker_roots[@]}"; do
  result_info="$(wait_for_worker_exit_code "${worker_root}")"
  result_dir="$(printf '%s\n' "${result_info}" | sed -n '1p')"
  result_exit_code="$(printf '%s\n' "${result_info}" | sed -n '2p')"
  if [[ -n "${result_dir}" ]]; then
    printf '%s\n' "${result_dir}" > "${worker_root}/result_dir"
  fi
  if [[ -n "${result_exit_code}" && "${result_exit_code}" != "unknown" ]]; then
    printf '%s\n' "${result_exit_code}" > "${worker_root}/resolved.exit_code"
  fi
done

summary_csv="${parallel_root}/summary.csv"
printf 'run_index,port,worker_root,worker_log,container_exit_code,result_dir\n' > "${summary_csv}"
overall_status=0
for worker_root in "${worker_roots[@]}"; do
  run_index="$(basename "${worker_root}" | sed -E 's/^worker0*([0-9]+)$/\1/')"
  worker_port="${PORT_START_VALUE}"
  worker_log_file="${worker_root}/docker.log"
  result_info="$(wait_for_worker_exit_code "${worker_root}")"
  result_dir="$(printf '%s\n' "${result_info}" | sed -n '1p')"
  result_exit_code="$(printf '%s\n' "${result_info}" | sed -n '2p')"
  container_exit_code="unknown"

  if [[ -n "${result_dir}" ]]; then
    printf '%s\n' "${result_dir}" > "${worker_root}/result_dir"
    result_run_exit_file="$(find "${result_dir}" -type f -name 'run.exit_code' | head -n 1 || true)"
    if [[ -n "${result_run_exit_file}" ]]; then
      result_exit_code="$(<"${result_run_exit_file}")"
    fi
  fi
  if [[ -n "${result_exit_code}" && "${result_exit_code}" != "unknown" ]]; then
    printf '%s\n' "${result_exit_code}" > "${worker_root}/resolved.exit_code"
    container_exit_code="${result_exit_code}"
  fi

  if [[ "${container_exit_code}" == "unknown" ]]; then
    container_exit_code="$(read_final_exit_code "${worker_root}")"
  fi

  if [[ -n "${result_exit_code}" ]]; then
    if [[ "${result_exit_code}" != "0" ]]; then
      overall_status=1
    fi
  fi

  printf '%s,%s,%s,%s,%s,%s\n' "${run_index}" "${worker_port}" "${worker_root}" "${worker_log_file}" "${container_exit_code}" "${result_dir}" >> "${summary_csv}"
done

echo "[parallel] Summary written to ${summary_csv}"
echo "[parallel] Done. Each worker produced its own results-live555_* folder under ${parallel_root}."

integrity_failed=0
for worker_root in "${worker_roots[@]}"; do
  if ! check_worker_result_integrity "${worker_root}"; then
    integrity_failed=1
  fi
done

if (( integrity_failed != 0 )); then
  echo "[parallel] Result integrity check failed; incomplete outputs remain in the artifact tree." >&2
  overall_status=1
fi

# ─────────────────────────────────────────────────────────────────────────────
# Phase: Gcov-replay  (OCP: entirely new block, no existing logic modified)
#
# For each worker, replay the EVOLVED corpus (captured from the fuzzing
# container) through a gcov-instrumented live555 server inside a separate
# Docker container.  This mirrors ChatAFL's methodology:
#   - ChatAFL replays its fuzzer's output queue (replayable-queue/id*)
#   - We replay SGFuzz/honggfuzz's evolved in-rtsp/ corpus
# Produces <run_dir>/artifacts/gcov/cov_over_time.csv which
# export_chatAFL_metrics.py will automatically prefer over llvm-cov.
# ─────────────────────────────────────────────────────────────────────────────
if [[ "${GCOV_REPLAY_ENABLED}" == "1" ]]; then
  echo "[parallel] ── Gcov-replay phase ──────────────────────────────────────"
  for worker_root in "${worker_roots[@]}"; do
    result_dir_file="${worker_root}/result_dir"
    [[ -f "${result_dir_file}" ]] || continue
    result_dir="$(<"${result_dir_file}")"
    [[ -d "${result_dir}" ]] || continue

    # Locate the saved evolved corpus from the fuzzing container.
    # If the corpus wasn't captured (e.g. container crashed before docker cp),
    # fall back to the in-image static seeds.
    saved_corpus_dir="${worker_root}/corpus/in-rtsp"
    if [[ -d "${saved_corpus_dir}" ]]; then
      corpus_source="saved"
      corpus_file_count="$(find "${saved_corpus_dir}" -maxdepth 1 -type f | wc -l)"
    else
      saved_corpus_dir=""
      corpus_source="in-image"
      corpus_file_count="(static seeds)"
    fi

    mapfile -t run_dirs < <(find "${result_dir}" -maxdepth 1 -type d -name '*_run*_port*' | sort)
    for run_dir in "${run_dirs[@]}"; do
      gcov_out_dir="${run_dir}/artifacts/gcov"
      run_start_epoch_file="${run_dir}/run.start_epoch"
      run_start_epoch=""
      if [[ -f "${run_start_epoch_file}" ]]; then
        run_start_epoch="$(<"${run_start_epoch_file}")"
      fi

      mkdir -p "${gcov_out_dir}"
      echo "[parallel] gcov-replay: $(basename "${worker_root}")/$(basename "${run_dir}") (corpus=${corpus_source}, files=${corpus_file_count}, step=${GCOV_REPLAY_STEP})"

      gcov_replay_log="${gcov_out_dir}/replay.log"
      replay_port=9554

      # Build docker run arguments.  If we have a saved corpus, mount it
      # over the in-image directory so the replay script uses the evolved
      # corpus.  Otherwise the in-image static seeds are used as fallback.
      local_docker_args=(
        --rm
        --privileged
        --user root
        -v "${gcov_out_dir}:/gcov-out"
        -v "${GCOV_REPLAY_SCRIPT}:/usr/local/bin/replay_gcov_coverage.sh:ro"
        -e HFND_TCP_PORT="${replay_port}"
      )
      if [[ -n "${saved_corpus_dir}" ]]; then
        # Mount the evolved corpus over the in-image seed directory
        local_docker_args+=( -v "${saved_corpus_dir}:/home/ubuntu/experiments/in-rtsp:ro" )
      fi

      if docker run \
        "${local_docker_args[@]}" \
        "${GCOV_REPLAY_IMAGE}" \
        bash -c "replay_gcov_coverage.sh /home/ubuntu/experiments/in-rtsp /home/ubuntu/experiments/live-gcov ${replay_port} ${GCOV_REPLAY_STEP} /gcov-out/cov_over_time.csv ${run_start_epoch}" \
        > "${gcov_replay_log}" 2>&1; then
        echo "[parallel] gcov-replay: ✓ $(basename "${run_dir}") → ${gcov_out_dir}/cov_over_time.csv"
      else
        echo "[parallel] gcov-replay: ✗ $(basename "${run_dir}") failed (see ${gcov_replay_log})" >&2
      fi
    done
  done
  echo "[parallel] ── Gcov-replay phase complete ────────────────────────────"
fi

if [[ "${STATE_OBSERVER_ENABLED}" == "1" ]]; then
  echo "[parallel] ── State-observer phase ───────────────────────────────────"
  for worker_root in "${worker_roots[@]}"; do
    result_dir_file="${worker_root}/result_dir"
    [[ -f "${result_dir_file}" ]] || continue
    result_dir="$(<"${result_dir_file}")"
    [[ -d "${result_dir}" ]] || continue

    saved_corpus_dir="${worker_root}/corpus/in-rtsp"
    if [[ -d "${saved_corpus_dir}" ]]; then
      corpus_source="saved"
      corpus_file_count="$(find "${saved_corpus_dir}" -maxdepth 1 -type f | wc -l)"
    else
      saved_corpus_dir=""
      corpus_source="in-image"
      corpus_file_count="(static seeds)"
    fi

    mapfile -t run_dirs < <(find "${result_dir}" -maxdepth 1 -type d -name '*_run*_port*' | sort)
    for run_dir in "${run_dirs[@]}"; do
      state_out_dir="${run_dir}/artifacts/state-observer"
      state_log="${state_out_dir}/observe.log"
      replay_port=9654
      run_start_epoch_file="${run_dir}/run.start_epoch"
      run_start_epoch="0"
      if [[ -f "${run_start_epoch_file}" ]]; then
        run_start_epoch="$(<"${run_start_epoch_file}")"
      fi

      mkdir -p "${state_out_dir}"
      echo "[parallel] state-observer: $(basename "${worker_root}")/$(basename "${run_dir}") (corpus=${corpus_source}, files=${corpus_file_count})"

      local_docker_args=(
        --rm
        --privileged
        --user root
        -v "${state_out_dir}:/state-out"
        -v "${STATE_OBSERVER_SCRIPT_DIR}:/state-observer"
        -e LIVE_GCOV_DIR=/home/ubuntu/experiments/live-gcov
      )
      if [[ -n "${saved_corpus_dir}" ]]; then
        local_docker_args+=( -v "${saved_corpus_dir}:/home/ubuntu/experiments/in-rtsp:ro" )
      fi

      if docker run \
        "${local_docker_args[@]}" \
        "${STATE_OBSERVER_IMAGE}" \
        bash -lc "/state-observer/run_state_observer.sh /home/ubuntu/experiments/in-rtsp /state-out ${replay_port} auto ${run_start_epoch}" \
        > "${state_log}" 2>&1; then
        echo "[parallel] state-observer: ✓ $(basename "${run_dir}") → ${state_out_dir}/state_over_time.csv"
      else
        echo "[parallel] state-observer: ✗ $(basename "${run_dir}") failed (see ${state_log})" >&2
      fi
    done
  done
  echo "[parallel] ── State-observer phase complete ──────────────────────────"
fi

for worker_root in "${worker_roots[@]}"; do
  result_dir_file="${worker_root}/result_dir"
  if [[ -f "${result_dir_file}" ]]; then
    result_dir="$(<"${result_dir_file}")"
    if [[ -n "${result_dir}" ]]; then
      worker_metrics_csv="${result_dir}/chatAFL_compatible_metrics.csv"
      worker_scope_label="$(basename "${worker_root}")"

      if ! generate_normalized_metrics_csv \
        "${result_dir}" \
        "${worker_metrics_csv}" \
        "${worker_scope_label}"; then
        overall_status=1
        continue
      fi

      if ! validate_run_export_jsons "${result_dir}" "${worker_scope_label}"; then
        overall_status=1
      fi

      if ! validate_normalized_metrics_csv "${worker_metrics_csv}" "${worker_scope_label}"; then
        overall_status=1
      fi
    fi
  fi
done

aggregate_metrics_csv="${parallel_root}/chatAFL_compatible_metrics.csv"
if ! generate_normalized_metrics_csv \
  "${parallel_root}" \
  "${aggregate_metrics_csv}" \
  "parallel aggregate"; then
  overall_status=1
else
  if ! validate_run_export_jsons "${parallel_root}" "parallel aggregate"; then
    overall_status=1
  fi
  if ! validate_normalized_metrics_csv "${aggregate_metrics_csv}" "parallel aggregate"; then
    overall_status=1
  fi
fi

# Trigger coverage postprocessing: prefer the user-provided `/tmp/validate_coverage.sh`
# (it performs repeated lcov/genhtml runs and packaging). If not present, do a
# single lcov/genhtml pass on the host gcov dir (if tools are available).
if [[ -x /tmp/validate_coverage.sh ]]; then
  echo "[parallel] Triggering /tmp/validate_coverage.sh in background..."
  /tmp/validate_coverage.sh &> "${parallel_root}/validate_coverage.log" &
else
  if command -v lcov >/dev/null 2>&1 && command -v genhtml >/dev/null 2>&1; then
    gcda_count="$(find "${HOST_GCOV_DIR}" -type f -name '*.gcda' 2>/dev/null | wc -l | tr -d ' ')"
    if [[ "${gcda_count}" -eq 0 ]]; then
      echo "[parallel] No .gcda files found in ${HOST_GCOV_DIR}; skipping lcov/genhtml coverage generation"
    else
      echo "[parallel] Running one-shot lcov/genhtml on ${HOST_GCOV_DIR}"
      lcov --capture --directory "${HOST_GCOV_DIR}" -o "${parallel_root}/coverage.info" 2>&1 | tee "${parallel_root}/coverage.lcov.log" || true
      genhtml "${parallel_root}/coverage.info" -o "${parallel_root}/coverage-html" 2>&1 | tee "${parallel_root}/coverage.genhtml.log" || true
      if [[ -d "${parallel_root}/coverage-html" ]]; then
        tar -C "${parallel_root}/coverage-html" -czf "${parallel_root}/coverage-html.tar.gz" . || true
        echo "[parallel] coverage tarball: ${parallel_root}/coverage-html.tar.gz"
      fi
    fi
  else
    echo "[parallel] lcov/genhtml not available on host; skipping coverage generation"
  fi
fi

exit "${overall_status}"