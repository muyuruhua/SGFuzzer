#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SGFUZZ_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
WORKDIR="${SCRIPT_DIR}"
SOURCE_ARCHIVE="${WORKDIR}/live.2021.08.13.tar.gz"
PATCH_FILE="${WORKDIR}/fuzzing.patch"
BLOCKED_FILE="${WORKDIR}/blocked_variables.txt"
HFUZZ_DIR="${WORKDIR}/honggfuzz"
LIVE_SRC_DIR="${WORKDIR}/live"
LIVE_BUILD_DIR="${WORKDIR}/live555-sgfuzz"
LOCAL_LIB_DIR="${WORKDIR}/local_libs"

CLANG_BIN="${CLANG_BIN:-clang-10}"
CLANGXX_BIN="${CLANGXX_BIN:-clang++-10}"
STEP_INDEX=0
STEP_TOTAL=9

log_step() {
  STEP_INDEX=$((STEP_INDEX + 1))
  printf '\n[%d/%d] %s\n' "${STEP_INDEX}" "${STEP_TOTAL}" "$1"
}

done_step() {
  printf '[%d/%d] Done\n' "${STEP_INDEX}" "${STEP_TOTAL}"
}

check_inputs() {
  log_step "Checking inputs"

  for path in "${SOURCE_ARCHIVE}" "${PATCH_FILE}" "${BLOCKED_FILE}"; do
    if [[ ! -f "${path}" ]]; then
      echo "Missing required file: ${path}" >&2
      exit 1
    fi
  done

  if [[ ! -d "${HFUZZ_DIR}" ]]; then
    echo "Missing honggfuzz source directory: ${HFUZZ_DIR}" >&2
    exit 1
  fi

  if [[ ! -f "${SGFUZZ_ROOT}/build.sh" ]]; then
    echo "Missing SGFuzz root: ${SGFUZZ_ROOT}" >&2
    exit 1
  fi

  done_step
}

build_sgfuzz_driver() {
  log_step "Building SGFuzz driver library"
  cd "${SGFUZZ_ROOT}"
  ./build.sh
  done_step
}

build_honggfuzz_libraries() {
  log_step "Building honggfuzz static libraries"
  cd "${HFUZZ_DIR}"
  if [[ -d .git ]]; then
    git checkout 6f89ccc9c43c6c1d9f938c81a47b72cd5ada61ba >/dev/null 2>&1 || true
  fi
  make clean >/dev/null 2>&1 || true
  CC="${CLANG_BIN}" CFLAGS="-g -fsanitize=fuzzer-no-link -fsanitize=address" make libhfcommon/libhfcommon.a
  CC="${CLANG_BIN}" CFLAGS="-g -fsanitize=fuzzer-no-link -fsanitize=address -DHFND_RECVTIME=1" make libhfnetdriver/libhfnetdriver.a
  done_step
}

prepare_local_libraries() {
  log_step "Preparing local link libraries"
  mkdir -p "${LOCAL_LIB_DIR}"
  cp -f "${SGFUZZ_ROOT}/libsfuzzer.a" "${LOCAL_LIB_DIR}/libsFuzzer.a"
  cp -f "${HFUZZ_DIR}/libhfcommon/libhfcommon.a" "${LOCAL_LIB_DIR}/libhfcommon.a"
  cp -f "${HFUZZ_DIR}/libhfnetdriver/libhfnetdriver.a" "${LOCAL_LIB_DIR}/libhfnetdriver.a"
  done_step
}

prepare_live555_source() {
  log_step "Preparing Live555 source tree"
  cd "${WORKDIR}"
  if [[ ! -d "${LIVE_SRC_DIR}" ]]; then
    tar -zxvf "${SOURCE_ARCHIVE}"
  fi
  rm -rf "${LIVE_BUILD_DIR}"
  cp -r "${LIVE_SRC_DIR}" "${LIVE_BUILD_DIR}"
  chmod -R u+w "${LIVE_BUILD_DIR}"
  done_step
}

instrument_live555() {
  log_step "Applying SGFuzz patch and instrumentation"
  cd "${LIVE_BUILD_DIR}"
  patch -p1 < "${PATCH_FILE}"
  sed -i "s/int main(/extern \"C\" int HonggfuzzNetDriver_main(/g" testProgs/testOnDemandRTSPServer.cpp
  python3 "${SGFUZZ_ROOT}/sanitizer/State_machine_instrument.py" "${LIVE_BUILD_DIR}/" -b "${BLOCKED_FILE}"
  done_step
}

generate_live555_makefiles() {
  log_step "Generating Live555 makefiles"
  cd "${LIVE_BUILD_DIR}"
  ./genMakefiles linux-no-openssl
  done_step
}

build_live555_objects() {
  log_step "Building Live555 libraries and objects"
  cd "${LIVE_BUILD_DIR}"
  make -C liveMedia
  make -C groupsock
  make -C UsageEnvironment
  make -C BasicUsageEnvironment
  make -C testProgs testOnDemandRTSPServer.o announceURL.o
  done_step
}

link_target_binary() {
  log_step "Linking target binary"
  export LIBRARY_PATH="${LOCAL_LIB_DIR}:${LIBRARY_PATH:-}"
  export LD_LIBRARY_PATH="${LOCAL_LIB_DIR}:${LD_LIBRARY_PATH:-}"
  cd "${LIVE_BUILD_DIR}/testProgs"
  "${CLANGXX_BIN}" -fsanitize=fuzzer-no-link -fsanitize=address -o testOnDemandRTSPServer \
    -L"${LOCAL_LIB_DIR}" \
    testOnDemandRTSPServer.o announceURL.o \
    ../liveMedia/libliveMedia.a ../groupsock/libgroupsock.a \
    ../BasicUsageEnvironment/libBasicUsageEnvironment.a ../UsageEnvironment/libUsageEnvironment.a \
    -lsFuzzer -lhfnetdriver -lhfcommon
  done_step
}

if ! command -v "${CLANG_BIN}" >/dev/null 2>&1; then
  CLANG_BIN="clang"
fi

if ! command -v "${CLANGXX_BIN}" >/dev/null 2>&1; then
  CLANGXX_BIN="clang++"
fi

printf 'SGFuzz Live555 setup\n'
printf '====================\n'

check_inputs
build_sgfuzz_driver
build_honggfuzz_libraries
prepare_local_libraries
prepare_live555_source
instrument_live555
generate_live555_makefiles
build_live555_objects
link_target_binary

printf '\nAll done. Binary location:\n  %s\n' "${LIVE_BUILD_DIR}/testProgs/testOnDemandRTSPServer"
