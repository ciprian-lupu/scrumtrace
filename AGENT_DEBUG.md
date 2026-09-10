# Agent debug loop

Cloud agents cannot compile ScreenCaptureKit. Ciprian’s Mac can. This loop lets an agent pull, rebuild, restart, and read logs without a human in the middle.

## What the app writes

JSONL at `~/Library/Logs/ScrumTrace/agent.jsonl` (also `NSLog` under `[ScrumTrace]`).

Each line has `ts`, `event`, `pid`, plus technical fields only: bundle path, Screen Recording at launch vs now, microphone TCC, Accessibility trusted flag, readiness, macOS version. No window titles, URLs, notes, transcripts, or API keys.

While a session is live the app also writes `~/Library/Logs/ScrumTrace/recording.lock` so the loop will not quit Record.

Useful events: `launch`, `start_requested`, `start_blocked`, `start_ok`, `start_fail`, `recorder_sckit_*`, `mic_*`, `stop_requested`, `halt`, `terminate`, `relaunch_requested`.

Menu / Settings → **Reveal agent log**.

## What the Mac loop does

`scripts/mac_agent_loop.sh` (every 3 minutes after `scripts/mac_install_agent_loop.sh`, or on demand):

1. Skip if `recording.lock` exists.
2. Skip `git pull` if the working tree is dirty.
3. Fast-forward `cursor/scrumtrace-implementation-0397`.
4. Rebuild and relaunch `~/Applications/ScrumTrace.app` only when HEAD changed, the app is missing, or `SCRUMTRACE_FORCE=1`.
5. Publish the last 4000 log lines to GitHub branch `cursor/scrumtrace-agent-logs-0397`.

## What the cloud agent does

```bash
bash scripts/fetch_agent_log.sh
```

That fetches the logs branch. After a push to the implementation branch, wait one loop (~3 minutes) or kick the LaunchAgent:

```bash
launchctl kickstart -k "gui/$(id -u)/com.str8minds.ScrumTrace.agentloop"
```

The self-hosted worker `~/development/scrumtrace @ Ciprian's MacBook Pro` can run the same scripts directly and `cat` the local JSONL.
