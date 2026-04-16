#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUT_DIR="${SCRIPT_DIR}/bin"
mkdir -p "${OUT_DIR}"

cc \
  -O2 \
  -std=c11 \
  -Wall \
  -Wextra \
  -pedantic \
  "${SCRIPT_DIR}/rtsp_state_parser.c" \
  -o "${OUT_DIR}/rtsp_state_parser"

echo "built ${OUT_DIR}/rtsp_state_parser"
