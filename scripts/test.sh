#!/usr/bin/env bash
# Runs the unit tests with SwiftPM. With only the Command Line Tools installed (no Xcode),
# Swift Testing lives outside the default search paths, so point the compiler and loader at it.
set -euo pipefail
cd "$(dirname "$0")/.."

DEV="$(xcode-select -p)"
if [[ "$DEV" == *CommandLineTools* ]]; then
  LIB="$DEV/Library/Developer"
  exec swift test \
    -Xswiftc -F -Xswiftc "$LIB/Frameworks" \
    -Xlinker -F -Xlinker "$LIB/Frameworks" \
    -Xlinker -rpath -Xlinker "$LIB/Frameworks" \
    -Xlinker -rpath -Xlinker "$LIB/usr/lib" "$@"
fi
exec swift test "$@"
