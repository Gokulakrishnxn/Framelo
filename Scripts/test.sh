#!/bin/bash
# Runs the test suite. Extra arguments are passed to `swift test` (e.g. --filter ExportTests).
set -euo pipefail
cd "$(dirname "$0")/.."
source Scripts/toolchain.sh
exec swift test "${SWIFT_FLAGS[@]}" "$@"
