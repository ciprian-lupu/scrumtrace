#!/usr/bin/env bash
# Print the local Mac agent log (run on the Mac or via the self-hosted worker).
set -euo pipefail
LOG="${HOME}/Library/Logs/ScrumTrace/agent.jsonl"
STATUS="${HOME}/Library/Logs/ScrumTrace/loop-status.txt"
if [[ -f "$STATUS" ]]; then
  echo "---- loop-status ----"
  tail -n 40 "$STATUS"
fi
if [[ ! -f "$LOG" ]]; then
  echo "no agent log at $LOG"
  exit 0
fi
echo "---- agent.jsonl ----"
tail -n "${1:-120}" "$LOG"
