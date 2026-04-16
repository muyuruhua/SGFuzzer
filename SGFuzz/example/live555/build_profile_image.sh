#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
IMAGE_TAG="${1:-live555-sgfuzz-profraw}"

cd "${SCRIPT_DIR}"
docker build -f Dockerfile.profraw -t "${IMAGE_TAG}" .

printf 'Built image: %s\n' "${IMAGE_TAG}"