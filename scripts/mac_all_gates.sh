#!/usr/bin/env bash
# Build ScrumTrace (optional) and run every gate inspector that has artifacts.
# Never writes samples/GATE_LOG.md. Do not invent PASS cells.
set -euo pipefail
cd "$(dirname "$0")/.."

SESSION=""
LOG="${SCRUMTRACE_LOG:-$HOME/Library/Logs/ScrumTrace/agent.jsonl}"
TOKEN="${SCRUMTRACE_G1_TOKEN:-ST-G1-PAUSE-TOKEN-9F3C}"
PASSPHRASE="${SCRUMTRACE_G1_PASSPHRASE:-orchid lantern seven}"
ARTIFACT_MAP="${SCRUMTRACE_ARTIFACT_MAP:-}"
MANUAL_VIDEO=0
MANUAL_AUDIO=0
AV_OFFSET_MS="${SCRUMTRACE_G1_AV_OFFSET_MS:-}"
PTT_TEMP_OK=0
TARGET_MEDIA_SECONDS="${SCRUMTRACE_G3_TARGET_MEDIA_SECONDS:-}"
TARGET_WALL_SECONDS="${SCRUMTRACE_G3_TARGET_WALL_SECONDS:-}"
CHROME_PLAYBACK_OK=0
NO_BUILD=0
LATEST=0
STRICT=0
MOCK_ONLY=0
BEGIN=0
GATE_RUN_JSON="${SCRUMTRACE_GATE_RUN_JSON:-$HOME/Library/Logs/ScrumTrace/gate-run.json}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --session)
      SESSION="$2"
      shift 2
      ;;
    --log)
      LOG="$2"
      shift 2
      ;;
    --token)
      TOKEN="$2"
      shift 2
      ;;
    --passphrase)
      PASSPHRASE="$2"
      shift 2
      ;;
    --artifact-map)
      ARTIFACT_MAP="$2"
      shift 2
      ;;
    --manual-video-scrub-ok)
      MANUAL_VIDEO=1
      shift
      ;;
    --manual-audio-scrub-ok)
      MANUAL_AUDIO=1
      shift
      ;;
    --av-offset-ms)
      AV_OFFSET_MS="$2"
      shift 2
      ;;
    --ptt-temp-deleted-ok)
      PTT_TEMP_OK=1
      shift
      ;;
    --target-media-seconds)
      TARGET_MEDIA_SECONDS="$2"
      shift 2
      ;;
    --target-wall-seconds)
      TARGET_WALL_SECONDS="$2"
      shift 2
      ;;
    --chrome-playback-ok)
      CHROME_PLAYBACK_OK=1
      shift
      ;;
    --no-build)
      NO_BUILD=1
      shift
      ;;
    --latest)
      LATEST=1
      shift
      ;;
    --strict)
      STRICT=1
      shift
      ;;
    --mock-only)
      MOCK_ONLY=1
      shift
      ;;
    --begin)
      BEGIN=1
      shift
      ;;
    *)
      echo "unknown argument: $1" >&2
      echo "usage: bash scripts/mac_all_gates.sh [--begin] [--no-build] [--latest] [--session PATH] [--log PATH] [--artifact-map PATH] [--strict] [--mock-only]" >&2
      exit 2
      ;;
  esac
done

if [[ "$MOCK_ONLY" -eq 1 ]]; then
  python3 scripts/inspect_all_gates.py --mock-only
  exit $?
fi

if [[ "$BEGIN" -eq 1 ]]; then
  if [[ "$(uname -s)" != "Darwin" ]]; then
    echo "mac_all_gates.sh --begin requires macOS" >&2
    exit 2
  fi
  mkdir -p "$(dirname "$GATE_RUN_JSON")"
  if [[ ! -f "$LOG" ]]; then
    lines=0
  else
    lines="$(wc -l < "$LOG" | tr -d ' ')"
  fi
  start_line=$((lines + 1))
  GATE_RUN_JSON="$GATE_RUN_JSON" LOG="$LOG" START_LINE="$start_line" python3 - <<'PY'
import json
import os
import platform
import subprocess
from datetime import datetime, timezone
from pathlib import Path

out = Path(os.environ["GATE_RUN_JSON"])
log = Path(os.environ["LOG"])
start_line = int(os.environ["START_LINE"])
head = subprocess.run(
    ["git", "rev-parse", "HEAD"], capture_output=True, text=True
).stdout.strip()
machine = subprocess.run(
    ["scutil", "--get", "ComputerName"], capture_output=True, text=True
).stdout.strip() or platform.node()
macos = subprocess.run(
    ["sw_vers", "-productVersion"], capture_output=True, text=True
).stdout.strip()
chip = subprocess.run(
    ["sysctl", "-n", "machdep.cpu.brand_string"], capture_output=True, text=True
).stdout.strip()
cdhash = ""
app = Path.home() / "Applications/ScrumTrace.app"
if app.exists():
    codesign = subprocess.run(
        ["codesign", "-dvvv", str(app)], capture_output=True, text=True
    )
    for line in (codesign.stderr + codesign.stdout).splitlines():
        if "CDHash=" in line:
            cdhash = line.split("CDHash=", 1)[1].strip()
            break
payload = {
    "log_path": str(log),
    "log_start_line": start_line,
    "created_at": datetime.now(timezone.utc).isoformat(),
    "git_head": head,
    "app_cdhash": cdhash,
    "machine": machine,
    "macos": macos,
    "chip": chip,
}
out.write_text(json.dumps(payload, indent=2) + "\n", encoding="utf-8")
print(json.dumps({"ok": True, "gate_run": str(out), "log_start_line": start_line}))
PY
  exit 0
fi

if [[ "$(uname -s)" != "Darwin" ]]; then
  echo "mac_all_gates.sh build steps need macOS. Use --mock-only on Linux, or python3 scripts/inspect_all_gates.py --session …" >&2
  exit 2
fi

echo "machine=$(scutil --get ComputerName 2>/dev/null || uname -n)"
echo "macos=$(sw_vers -productVersion)"
echo "chip=$(sysctl -n machdep.cpu.brand_string)"
echo "bundle=com.str8minds.ScrumTrace"
echo "Do not invent GATE_LOG.md PASS cells from this script."

if [[ "$NO_BUILD" -eq 0 ]]; then
  bash scripts/mac_gate01.sh
fi

if [[ "$LATEST" -eq 1 && -z "$SESSION" && -z "$ARTIFACT_MAP" ]]; then
  SESSION="$(ls -1dt "$HOME/Movies/ScrumTrace/sessions"/* 2>/dev/null | head -1 || true)"
fi

LOG_START_LINE=""
if [[ -f "$GATE_RUN_JSON" ]]; then
  LOG_START_LINE="$(python3 -c "import json,sys; print(json.load(open(sys.argv[1]))['log_start_line'])" "$GATE_RUN_JSON")"
fi

ARGS=(python3 scripts/inspect_all_gates.py --guided)
if [[ -n "$ARTIFACT_MAP" ]]; then
  ARGS+=(--artifact-map "$ARTIFACT_MAP")
fi
if [[ -n "$SESSION" ]]; then
  ARGS+=(--session "$SESSION")
fi
if [[ -f "$LOG" ]]; then
  ARGS+=(--log "$LOG")
  if [[ -n "$LOG_START_LINE" ]]; then
    ARGS+=(--log-start-line "$LOG_START_LINE")
  elif [[ -z "$ARTIFACT_MAP" ]]; then
    echo "missing gate-run marker; run: bash scripts/mac_all_gates.sh --begin" >&2
    exit 2
  fi
fi
if [[ -n "$TOKEN" && -n "$PASSPHRASE" ]]; then
  ARGS+=(--token "$TOKEN" --passphrase "$PASSPHRASE")
fi
if [[ "$MANUAL_VIDEO" -eq 1 ]]; then
  ARGS+=(--manual-video-scrub-ok)
fi
if [[ "$MANUAL_AUDIO" -eq 1 ]]; then
  ARGS+=(--manual-audio-scrub-ok)
fi
if [[ -n "$AV_OFFSET_MS" ]]; then
  ARGS+=(--av-offset-ms "$AV_OFFSET_MS")
fi
if [[ "$PTT_TEMP_OK" -eq 1 ]]; then
  ARGS+=(--ptt-temp-deleted-ok)
fi
if [[ -n "$TARGET_MEDIA_SECONDS" ]]; then
  ARGS+=(--target-media-seconds "$TARGET_MEDIA_SECONDS")
fi
if [[ -n "$TARGET_WALL_SECONDS" ]]; then
  ARGS+=(--target-wall-seconds "$TARGET_WALL_SECONDS")
fi
if [[ "$CHROME_PLAYBACK_OK" -eq 1 ]]; then
  ARGS+=(--chrome-playback-ok)
fi
if [[ "$STRICT" -eq 1 ]]; then
  if [[ -z "$ARTIFACT_MAP" ]]; then
    echo "--strict requires --artifact-map so one session cannot satisfy unrelated gates" >&2
    exit 2
  fi
  ARGS+=(--strict)
fi

echo "inspect=${ARGS[*]}"
set +e
"${ARGS[@]}"
status=$?
set -e

echo
echo "Fill samples/GATE_LOG.md by hand from the JSON above plus the Keynote / media scrub."
echo "This script does not write GATE_LOG.md."
echo "Order: Gate −0, then 0, then 1 (20 min / three pauses), then 3–6."
echo "Strict acceptance needs a multi-session --artifact-map (especially Gate 5 scenarios)."
echo "Boot out the LaunchAgent before a manual gate run:"
echo "  launchctl bootout gui/\$(id -u)/com.str8minds.ScrumTrace.agentloop 2>/dev/null || true"
exit "$status"
