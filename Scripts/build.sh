#!/bin/bash
# Compiles the package. Extra arguments are passed to `swift build` (e.g. -c release).
set -euo pipefail
cd "$(dirname "$0")/.."
source Scripts/toolchain.sh
exec swift build "${SWIFT_FLAGS[@]}" "$@"
