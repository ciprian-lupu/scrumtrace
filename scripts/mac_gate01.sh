#!/usr/bin/env bash
# Gate 0 + Gate 1 Mac driver — Keynote hotkeys then Capture Area + overlays.
# Requires a built, signed-or-local, non-sandboxed agent bundle.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="${SCRUMTRACE_APP:-$HOME/Applications/ScrumTrace.app}"
PLIST="$APP/Contents/Info.plist"
ENTITLEMENTS="$APP/Contents/Resources/ScrumTrace.entitlements"
BUNDLE_ID="com.str8minds.ScrumTrace"

if [[ ! -d "$APP" ]]; then
  echo "missing app: $APP" >&2
  echo "Build and install ScrumTrace.app first (Xcode Archive → Applications)." >&2
  exit 1
fi

if [[ ! -f "$PLIST" ]]; then
  echo "missing Info.plist: $PLIST" >&2
  exit 1
fi

ACTUAL_ID="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$PLIST" 2>/dev/null || true)"
if [[ "$ACTUAL_ID" != "$BUNDLE_ID" ]]; then
  echo "wrong bundle id: got '${ACTUAL_ID:-missing}', want $BUNDLE_ID" >&2
  exit 1
fi

LSUI="$(/usr/libexec/PlistBuddy -c 'Print :LSUIElement' "$PLIST" 2>/dev/null || echo false)"
if [[ "$LSUI" != "true" && "$LSUI" != "1" ]]; then
  echo "LSUIElement must be true for agent hotkeys (got: $LSUI)" >&2
  exit 1
fi

# App Sandbox must be OFF for global hotkeys / capture helpers.
if [[ -f "$ENTITLEMENTS" ]]; then
  if /usr/libexec/PlistBuddy -c 'Print :com.apple.security.app-sandbox' "$ENTITLEMENTS" 2>/dev/null | grep -qi true; then
    echo "App Sandbox entitlement is enabled — Gate 0/1 require an unsandboxed agent build" >&2
    exit 1
  fi
fi
# Also scan embedded provisioning / codesign entitlements when available.
if command -v codesign >/dev/null 2>&1; then
  if codesign -d --entitlements :- "$APP" 2>/dev/null | grep -q 'com.apple.security.app-sandbox</key>[[:space:]]*<true'; then
    echo "codesign reports App Sandbox enabled — refuse Gate 0/1" >&2
    exit 1
  fi
fi

LOG="${SCRUMTRACE_AGENT_LOG:-$HOME/Library/Logs/ScrumTrace/agent.jsonl}"
mkdir -p "$(dirname "$LOG")"
: >"$LOG"

echo "Launching $APP …"
open -a "$APP"
sleep 2

echo ""
echo "=== Gate 0 — Keynote hotkeys ==="
echo "1. Open Keynote (or Pages) and make a slide the frontmost window."
echo "2. Click AWAY from ScrumTrace so it is NOT the frontmost app."
echo "3. Press ⌥⌘S (Shot), ⌥⌘P (Pause), ⌥⌘Space (Pin)."
echo "4. Confirm overlay + pin without focusing ScrumTrace."
echo ""
echo "=== Gate 1 — Capture Area ==="
echo "5. Open Capture Area from the menu; draw a region; Esc cancel once."
echo "6. Draw again and Confirm; verify dim + marching ants + handles."
echo "7. Resize/move; Confirm; start a short capture; confirm crop in export."
echo ""
read -r -p "Press Enter when finished (or Ctrl-C to abort) …"

# Truncated log above → window starts at line 1.
python3 "$ROOT/scripts/inspect_gate0_log.py" --log "$LOG" --log-start-line 1
python3 "$ROOT/scripts/inspect_gate1_log.py" --log "$LOG" --log-start-line 1
echo "Gate 0 + Gate 1 inspectors finished — see GATE_LOG.md"
