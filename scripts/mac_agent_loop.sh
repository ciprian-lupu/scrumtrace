#!/usr/bin/env bash
# Pull latest implementation and publish logs. Rebuild only on an explicit
# request (agent.request_rebuild or SCRUMTRACE_FORCE) or a missing app —
# never because HEAD moved. Auto-rebuild mints a new TCC client.
set -euo pipefail

if [[ "$(uname -s)" != "Darwin" ]]; then
  echo "mac_agent_loop.sh must run on macOS" >&2
  exit 2
fi

REPO="${SCRUMTRACE_REPO:-$HOME/development/scrumtrace}"
BRANCH="${SCRUMTRACE_BRANCH:-develop}"
STABLE="${SCRUMTRACE_STABLE:-$HOME/Applications/ScrumTrace.app}"
LOG_DIR="${HOME}/Library/Logs/ScrumTrace"
RECORD_LOCK="${LOG_DIR}/recording.lock"
LOOP_LOCK="${LOG_DIR}/loop.lock"
STATUS="${LOG_DIR}/loop-status.txt"
REQUEST_REBUILD="${LOG_DIR}/agent.request_rebuild"
FORCE="${SCRUMTRACE_FORCE:-${1:-}}"

mkdir -p "$LOG_DIR"
if ! mkdir "$LOOP_LOCK" 2>/dev/null; then
  echo "mac_agent_loop already running" | tee -a "$STATUS"
  exit 0
fi
cleanup() { rmdir "$LOOP_LOCK" 2>/dev/null || true; }
trap cleanup EXIT

stamp() { date -u +"%Y-%m-%dT%H:%M:%SZ"; }
log_status() {
  echo "$(stamp) $*" | tee -a "$STATUS"
}

if [[ -f "$RECORD_LOCK" ]]; then
  lock_pid="$(sed -n '2p' "$RECORD_LOCK" | tr -d '[:space:]')"
  if [[ -n "$lock_pid" ]] && kill -0 "$lock_pid" 2>/dev/null; then
    log_status "skip: recording.lock live pid=$lock_pid"
    bash "$(dirname "$0")/mac_publish_agent_log.sh" || true
    exit 0
  fi
  rm -f "$RECORD_LOCK"
  log_status "cleared stale recording.lock (pid ${lock_pid:-unknown} not running)"
fi

cd "$REPO"

if [[ -n "$(git status --porcelain)" ]]; then
  log_status "skip pull: dirty tree in $REPO"
else
  REMOTE="origin"
  if git remote get-url origin 2>/dev/null | grep -q 'github.com'; then
    REMOTE="origin"
  elif git remote | grep -qx github; then
    REMOTE="github"
  fi
  git fetch "$REMOTE" "$BRANCH"
  OLD="$(git rev-parse HEAD)"
  git checkout "$BRANCH"
  git pull --ff-only "$REMOTE" "$BRANCH"
  NEW="$(git rev-parse HEAD)"
  log_status "git $OLD -> $NEW via $REMOTE $BRANCH"
fi

NEED_BUILD=0
if [[ "${FORCE}" == "--force" || "${FORCE}" == "1" ]]; then
  NEED_BUILD=1
fi
if [[ -f "$REQUEST_REBUILD" ]]; then
  NEED_BUILD=1
fi
if [[ ! -x "$STABLE/Contents/MacOS/ScrumTrace" ]]; then
  NEED_BUILD=1
fi
if [[ -n "${NEW:-}" && -n "${OLD:-}" && "$OLD" != "$NEW" && "$NEED_BUILD" != "1" ]]; then
  log_status "new commit $NEW available; not rebuilding (touch $REQUEST_REBUILD)"
fi

if [[ "$NEED_BUILD" == "1" ]]; then
  osascript -e 'tell application "ScrumTrace" to quit' >/dev/null 2>&1 || true
  sleep 1
  pkill -x ScrumTrace >/dev/null 2>&1 || true
  sleep 1
  log_status "building (explicit request or missing app)"
  bash "$(dirname "$0")/mac_gate01.sh"
  rm -f "$REQUEST_REBUILD"
  log_status "build ok"
else
  log_status "build skipped (no request_rebuild / FORCE; app exists)"
fi

if ! pgrep -x ScrumTrace >/dev/null 2>&1; then
  open "$STABLE"
  log_status "opened $STABLE"
  sleep 3
else
  log_status "app already running"
fi

bash "$(dirname "$0")/mac_publish_agent_log.sh" || log_status "publish failed"
log_status "loop ok"
