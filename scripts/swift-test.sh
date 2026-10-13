#!/usr/bin/env bash
# Runs `swift test` with swift-testing. On Command-Line-Tools-only machines (no Xcode) the Testing
# framework is not on the default search path, so add it explicitly. Extra args pass through.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
DEV_DIR="$(xcode-select -p 2>/dev/null || true)"
EXTRA=()
if [[ "$DEV_DIR" == *CommandLineTools* ]]; then
  F="$DEV_DIR/Library/Developer/Frameworks"
  if [ -d "$F/Testing.framework" ]; then
    EXTRA=(-Xswiftc -F -Xswiftc "$F" -Xlinker -F -Xlinker "$F" -Xlinker -rpath -Xlinker "$F"
           -Xswiftc -Xfrontend -Xswiftc -disable-cross-import-overlays)
  fi
fi
exec swift test --disable-xctest ${EXTRA[@]+"${EXTRA[@]}"} "$@"
