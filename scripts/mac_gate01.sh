#!/usr/bin/env bash
# Build ScrumTrace on a Mac and print Gate 0 static facts.
# GUI / Keynote / 20-minute capture still have to run on the machine.
set -euo pipefail
cd "$(dirname "$0")/.."

if [[ "$(uname -s)" != "Darwin" ]]; then
  echo "mac_gate01.sh must run on macOS" >&2
  exit 2
fi

echo "machine=$(scutil --get ComputerName 2>/dev/null || uname -n)"
echo "macos=$(sw_vers -productVersion)"
echo "chip=$(sysctl -n machdep.cpu.brand_string)"
echo "bundle=com.str8minds.ScrumTrace"

if rg -q 'ENABLE_APP_SANDBOX = NO' ScrumTrace.xcodeproj/project.pbxproj; then
  echo "sandbox_project=off"
else
  echo "sandbox_project=UNKNOWN"
fi

DERIVED="${SCRUMTRACE_DERIVED:-$HOME/Library/Developer/Xcode/DerivedData/ScrumTraceGate}"
echo "building scheme ScrumTrace -> $DERIVED"
xcodebuild \
  -project ScrumTrace.xcodeproj \
  -scheme ScrumTrace \
  -configuration Debug \
  -derivedDataPath "$DERIVED" \
  -destination 'platform=macOS' \
  CODE_SIGN_IDENTITY=- \
  CODE_SIGNING_REQUIRED=NO \
  build

APP="$DERIVED/Build/Products/Debug/ScrumTrace.app"
echo "app=$APP"
if [[ -d "$APP" ]]; then
  defaults read "$APP/Contents/Info.plist" LSUIElement || true
  codesign -d --entitlements - "$APP" 2>/dev/null | rg -n 'app-sandbox|audio-input|microphone' || true
fi

echo "sessions_root=$HOME/Movies/ScrumTrace/sessions"
ls -1 "$HOME/Movies/ScrumTrace/sessions" 2>/dev/null | tail -5 || echo "no sessions yet"
echo "mac_gate01 build step ok"
