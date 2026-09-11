#!/usr/bin/env bash
# Copy the local agent JSONL onto cursor/scrumtrace-agent-logs-0397 so the
# cloud agent can `git fetch` it without sitting on the Mac.
set -euo pipefail

if [[ "$(uname -s)" != "Darwin" ]]; then
  echo "mac_publish_agent_log.sh must run on macOS" >&2
  exit 2
fi

REPO="${SCRUMTRACE_REPO:-$HOME/development/scrumtrace}"
BRANCH="${SCRUMTRACE_LOG_BRANCH:-cursor/scrumtrace-agent-logs-0397}"
LOG_DIR="${HOME}/Library/Logs/ScrumTrace"
SRC="${LOG_DIR}/agent.jsonl"
STATUS="${LOG_DIR}/loop-status.txt"
WORKDIR="${SCRUMTRACE_LOG_WORKDIR:-${TMPDIR:-/tmp}/scrumtrace-agent-logs}"

mkdir -p "$LOG_DIR"
if [[ ! -f "$SRC" ]]; then
  echo "no agent.jsonl yet at $SRC"
  exit 0
fi

cd "$REPO"
REMOTE="origin"
if git remote get-url origin 2>/dev/null | grep -q 'github.com'; then
  REMOTE="origin"
elif git remote | grep -qx github; then
  REMOTE="github"
fi
URL="$(git remote get-url "$REMOTE")"

if [[ -d "$WORKDIR/.git" ]]; then
  git -C "$WORKDIR" fetch "$REMOTE" "$BRANCH" 2>/dev/null || git -C "$WORKDIR" fetch origin "$BRANCH" 2>/dev/null || true
  git -C "$WORKDIR" checkout -B "$BRANCH" 2>/dev/null || true
  git -C "$WORKDIR" reset --hard "FETCH_HEAD" 2>/dev/null || true
else
  rm -rf "$WORKDIR"
  if git ls-remote --exit-code "$URL" "refs/heads/$BRANCH" >/dev/null 2>&1; then
    git clone --depth 1 --branch "$BRANCH" "$URL" "$WORKDIR"
  else
    git clone --depth 1 "$URL" "$WORKDIR"
    git -C "$WORKDIR" checkout --orphan "$BRANCH"
    git -C "$WORKDIR" rm -rf . >/dev/null 2>&1 || true
  fi
fi

mkdir -p "$WORKDIR"
scrub_home() {
  sed "s|$HOME|~|g"
}
tail -n 4000 "$SRC" | scrub_home > "$WORKDIR/agent.jsonl"
if [[ -f "$STATUS" ]]; then
  tail -n 80 "$STATUS" | scrub_home > "$WORKDIR/loop-status.txt"
fi
uname -srm > "$WORKDIR/machine.txt"
sw_vers > "$WORKDIR/sw_vers.txt" 2>/dev/null || true
date -u +"published=%Y-%m-%dT%H:%M:%SZ" > "$WORKDIR/published.txt"

git -C "$WORKDIR" add agent.jsonl loop-status.txt machine.txt sw_vers.txt published.txt
if git -C "$WORKDIR" diff --cached --quiet; then
  echo "log branch unchanged"
  exit 0
fi
git -C "$WORKDIR" -c user.email="scrumtrace-agentloop@local" -c user.name="ScrumTrace Agent Loop" \
  commit -m "agent log $(date -u +%Y-%m-%dT%H:%M:%SZ)"
git -C "$WORKDIR" push -u "$REMOTE" "$BRANCH" 2>/dev/null || git -C "$WORKDIR" push -u origin "$BRANCH"
echo "published $BRANCH"
