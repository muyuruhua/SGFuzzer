#!/usr/bin/env bash
# build_profraw_flush_preload.sh — Build the LD_PRELOAD library for profraw flush.
#
# This is an OCP-compliant extension: it creates a shared library that can be
# injected via LD_PRELOAD at runtime, ensuring LLVM profraw data is flushed
# even when the process terminates via _Exit().  No SGFuzz core source code
# is modified.
#
# Usage:
#   ./build_profraw_flush_preload.sh [output_dir]
#
# Default output: ./profraw_flush_preload.so (next to this script)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC="${SCRIPT_DIR}/profraw_flush_preload.c"
OUT_DIR="${1:-${SCRIPT_DIR}}"
OUT="${OUT_DIR}/profraw_flush_preload.so"

if [[ ! -f "${SRC}" ]]; then
    echo "ERROR: source file not found: ${SRC}" >&2
    exit 1
fi

# Prefer the same compiler used to build the fuzzer target; fall back to gcc.
CC="${CC:-gcc}"
if ! command -v "${CC}" &>/dev/null; then
    CC="gcc"
fi

mkdir -p "${OUT_DIR}"
echo "[build_profraw_flush_preload] Compiling ${SRC} -> ${OUT}"
"${CC}" -shared -fPIC -O2 -Wall -Wextra -o "${OUT}" "${SRC}" -ldl
echo "[build_profraw_flush_preload] Done: ${OUT} ($(stat -c '%s' "${OUT}") bytes)"
