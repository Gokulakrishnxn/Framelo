#!/bin/bash
# Runs the test suite. With Command Line Tools only (no Xcode), the Swift Testing macro plugin
# is not on the default plugin path, so it is added explicitly when present.
set -euo pipefail
cd "$(dirname "$0")/.."
PLUGINS="/Library/Developer/CommandLineTools/usr/lib/swift/host/plugins/testing"
if [ -d "$PLUGINS" ] && ! xcode-select -p | grep -q "Xcode"; then
  exec swift test -Xswiftc -plugin-path -Xswiftc "$PLUGINS" "$@"
fi
exec swift test "$@"
