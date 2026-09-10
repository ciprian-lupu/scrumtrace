#!/usr/bin/env bash
# Read the published Mac agent log from GitHub (cloud / Linux safe).
set -euo pipefail
cd "$(dirname "$0")/.."

BRANCH="${SCRUMTRACE_LOG_BRANCH:-cursor/scrumtrace-agent-logs-0397}"
REMOTE="github"
if git remote | grep -qx github; then
  REMOTE="github"
elif git remote get-url origin 2>/dev/null | grep -q 'github.com'; then
  REMOTE="origin"
fi

git fetch "$REMOTE" "$BRANCH"
echo "---- published.txt ----"
git show "FETCH_HEAD:published.txt" 2>/dev/null || true
echo "---- loop-status.txt ----"
git show "FETCH_HEAD:loop-status.txt" 2>/dev/null || true
echo "---- agent.jsonl (last 80) ----"
git show "FETCH_HEAD:agent.jsonl" | tail -n 80
