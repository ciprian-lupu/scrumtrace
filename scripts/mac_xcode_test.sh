#!/usr/bin/env bash
# TEST-03: run the Xcode test target. mac_gate01.sh builds only.
set -euo pipefail
cd "$(dirname "$0")/.."

if [[ "$(uname -s)" != "Darwin" ]]; then
  echo "mac_xcode_test.sh must run on macOS" >&2
  exit 2
fi

DERIVED="${SCRUMTRACE_DERIVED:-$HOME/Library/Developer/Xcode/DerivedData/ScrumTraceGate}"
LOG="${TMPDIR:-/tmp}/scrumtrace-xcodebuild-test.log"

xcodebuild \
  -project ScrumTrace.xcodeproj \
  -scheme ScrumTrace \
  -configuration Debug \
  -derivedDataPath "$DERIVED" \
  -destination 'platform=macOS,arch=arm64' \
  CODE_SIGN_IDENTITY=- \
  CODE_SIGNING_REQUIRED=NO \
  ENABLE_DEBUG_DYLIB=NO \
  test 2>&1 | tee "$LOG"
status=${PIPESTATUS[0]}
if [[ "$status" -ne 0 ]]; then
  echo "---- test diagnostics ----"
  grep -E 'error:|failed|TEST FAILED' "$LOG" || true
  exit "$status"
fi
echo "xcodebuild test ok"
