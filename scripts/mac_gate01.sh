#!/usr/bin/env bash
# Build ScrumTrace on a Mac and print Gate 0 static facts.
# GUI / Keynote / 20-minute capture still have to run on the machine.
set -euo pipefail
cd "$(dirname "$0")/.."

if [[ "$(uname -s)" != "Darwin" ]]; then
  echo "mac_gate01.sh must run on macOS" >&2
  exit 2
fi

if [[ "${1:-}" == *Release* || "${SCRUMTRACE_CONFIGURATION:-Debug}" == "Release" ]]; then
  echo "mac_gate01.sh is Debug-only. Never sign a Release/Developer ID build with ScrumTrace Debug." >&2
  exit 2
fi

echo "machine=$(scutil --get ComputerName 2>/dev/null || uname -n)"
echo "macos=$(sw_vers -productVersion)"
echo "chip=$(sysctl -n machdep.cpu.brand_string)"
echo "bundle=com.str8minds.ScrumTrace"

if grep -q 'ENABLE_APP_SANDBOX = NO' ScrumTrace.xcodeproj/project.pbxproj; then
  echo "sandbox_project=off"
else
  echo "sandbox_project=UNKNOWN"
fi

DERIVED="${SCRUMTRACE_DERIVED:-$HOME/Library/Developer/Xcode/DerivedData/ScrumTraceGate}"
LOG="${TMPDIR:-/tmp}/scrumtrace-xcodebuild.log"
echo "building scheme ScrumTrace -> $DERIVED"
set +e
xcodebuild \
  -project ScrumTrace.xcodeproj \
  -scheme ScrumTrace \
  -configuration Debug \
  -derivedDataPath "$DERIVED" \
  -destination 'platform=macOS,arch=arm64' \
  CODE_SIGN_IDENTITY=- \
  CODE_SIGNING_REQUIRED=NO \
  ENABLE_DEBUG_DYLIB=NO \
  build 2>&1 | tee "$LOG"
status=${PIPESTATUS[0]}
set -e
if [[ "$status" -ne 0 ]]; then
  echo "---- swift diagnostics ----"
  grep -E 'error:|warning:.*this is an error' "$LOG" || true
  exit "$status"
fi

APP="$DERIVED/Build/Products/Debug/ScrumTrace.app"
echo "app=$APP"
if [[ ! -x "$APP/Contents/MacOS/ScrumTrace" ]]; then
  echo "build produced no executable at $APP/Contents/MacOS/ScrumTrace" >&2
  exit 1
fi
defaults read "$APP/Contents/Info.plist" LSUIElement || true

# Ad-hoc (`-`) signing keys TCC to the binary hash. Re-sign the build and
# the stable copy with one local identity so Screen Recording / Microphone
# survive the next rebuild.
SIGN_NAME="${SCRUMTRACE_SIGN_IDENTITY:-ScrumTrace Debug}"
IDENTITY=""
if IDENTITY="$(bash "$(dirname "$0")/ensure_debug_signing_identity.sh")"; then
  echo "sign_identity=$IDENTITY"
else
  echo "warning: could not create '$SIGN_NAME' signing identity; TCC will reset on every rebuild" >&2
  if [[ "${SCRUMTRACE_ALLOW_ADHOC:-}" != "1" ]]; then
    exit 1
  fi
  IDENTITY=""
fi

ENTITLEMENTS="$(dirname "$0")/../ScrumTrace/App/ScrumTrace.entitlements"

sign_app() {
  local target="$1"
  local identity="${IDENTITY:--}"
  # macOS /bin/bash is 3.2: `set -u` treats an empty array as unbound, so
  # pass --deep only on the Frameworks branch instead of an optional array.
  # Xcode Debug can leave a stub + ScrumTrace.debug.dylib under MacOS.
  # Those are not Contents/Frameworks, so --deep never sees them.
  if [[ -f "$target/Contents/MacOS/ScrumTrace.debug.dylib" ]]; then
    codesign --force --sign "$identity" --identifier com.str8minds.ScrumTrace \
      --entitlements "$ENTITLEMENTS" \
      "$target/Contents/MacOS/ScrumTrace.debug.dylib"
  fi
  if [[ -d "$target/Contents/Frameworks" ]]; then
    codesign --force --deep --sign "$identity" --identifier com.str8minds.ScrumTrace \
      --entitlements "$ENTITLEMENTS" "$target"
  else
    codesign --force --sign "$identity" --identifier com.str8minds.ScrumTrace \
      --entitlements "$ENTITLEMENTS" "$target"
  fi
}

sign_app "$APP"

STABLE="${SCRUMTRACE_STABLE:-$HOME/Applications/ScrumTrace.app}"
mkdir -p "$(dirname "$STABLE")"
rm -rf "$STABLE"
ditto "$APP" "$STABLE"
sign_app "$STABLE"
codesign -d --entitlements - "$STABLE" 2>/dev/null | grep -E 'app-sandbox|audio-input|microphone' || true
echo "stable_app=$STABLE"
codesign -dv --verbose=2 "$STABLE" 2>&1 | grep -E 'Authority|Identifier|Signature' || true
echo "Force-quit every other ScrumTrace, wait a second, then open this copy only:"
echo "  sleep 1 && open -n \"$STABLE\""

echo "sessions_root=$HOME/Movies/ScrumTrace/sessions"
ls -1 "$HOME/Movies/ScrumTrace/sessions" 2>/dev/null | tail -5 || echo "no sessions yet"
echo "mac_gate01 build step ok"
