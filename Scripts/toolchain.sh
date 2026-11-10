#!/bin/bash
# Shared build flags. Sourced by the other scripts.
#
# With Command Line Tools only (no Xcode):
#  - the newest SDK implements SwiftUI's @State as a macro whose plugin ships only with Xcode,
#    so the newest bundled SDK that does not need it (macOS 26.x) is used instead;
#  - the Swift Testing macro plugin is not on the default plugin path and is added explicitly.
# With Xcode selected, no extra flags are needed.
SWIFT_FLAGS=()
CLT="/Library/Developer/CommandLineTools"
if ! xcode-select -p 2>/dev/null | grep -q "Xcode"; then
  for candidate in MacOSX26.5.sdk MacOSX26.sdk; do
    if [ -d "$CLT/SDKs/$candidate" ]; then
      SWIFT_FLAGS+=(--sdk "$CLT/SDKs/$candidate")
      break
    fi
  done
  if [ -d "$CLT/usr/lib/swift/host/plugins/testing" ]; then
    SWIFT_FLAGS+=(-Xswiftc -plugin-path -Xswiftc "$CLT/usr/lib/swift/host/plugins/testing")
  fi
fi
export SWIFT_FLAGS
