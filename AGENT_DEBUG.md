# Agent debug loop

Cloud agents cannot compile ScreenCaptureKit. Ciprian’s Mac can. After the Composer debate, the loop is **log-first**. Rebuild is opt-in so we do not mint a new TCC client on every push.

## Consensus (Composer refine + attack)

- Keep JSONL at a fixed path. Add **CDHash / signing identity** so “Settings ON” can be checked against *this* binary.
- LaunchAgent may **pull and publish logs**. It must **not** `xcodebuild` because HEAD moved.
- Rebuild only if the app is missing, `~/Library/Logs/ScrumTrace/agent.request_rebuild` exists, or `SCRUMTRACE_FORCE=1`.
- `recording.lock` is ignored when its pid is dead.
- A generic cloud subagent does **not** land on the self-hosted Mac worker. Until a Mac-placed run is proven, `fetch_agent_log.sh` is how Linux reads logs.
- The logs branch is a fallback bus, not a second source of truth. Prefer `cat ~/Library/Logs/ScrumTrace/agent.jsonl` on the Mac when that worker is actually targeted.

## What the app writes

`~/Library/Logs/ScrumTrace/agent.jsonl` (also `NSLog` under `[ScrumTrace]`).

Fields: `ts`, `event`, `pid`, path, Screen Recording at launch vs now, mic, Accessibility, readiness, macOS, `cdhash`, `sign_id`, `sign_format`, `adhoc`. No window titles, URLs, notes, transcripts, or API keys.

Live session: `recording.lock` (session id + pid).

Useful events (technical fields only — no titles, URLs, notes, transcripts, or keys):

- Launch: `launch`, `permission_probe`, `screen_request`, `relaunch_requested`, `terminate`
- Start / stop: `start_control_state`, `menu_start`, `capture_area_picker`, `start_*`, `start_blocked_sheet`, `stop_clicked`, `stop_requested`, `stop_capture_ok`, `stop_capture_fail`, `stop_manifest_missing`, `stop_ignored`, `halt`, `halt_stop_*`
- Capture: `recorder_sckit_*`, `recorder_first_sample`, `mic_*`, `capture_write_fail`, `capture_stream_failed`, `wav_ahead_frames`
- Pause / privacy: `hotkey_pause`, `pause_ok`, `resume_ok`, `resume_blocked`, `privacy_trip`, `privacy_clear`, `privacy_pause`, `privacy_resume`
- Shot / pin / PTT: `hotkey_shot`, `hotkey_pin`, `shot_*`, `pin_*`, `talk_press`, `talk_release`, `talk_start_fail`, `talk_abort`, `talk_transcribe_*`
- Pipeline: `processor_begin`, `processor_ok`, `processor_fail`, `pipeline_status` (every HUD line after Stop — this is how to debug a stuck “Transcribing” state), `whisper_prepare_*`, `whisper_file_*`, `whisper_pass_*`, `extract_audio_*`, `slice_done`, `eval_*`, `zip_ok`, `consent_result`, `retry_*`
- UI: `menu_*`, `hud_*`, `settings_open`, `settings_action`, `meeting_notice`, `meta_frontmost` (bundle id + has_url only)

Menu / Settings: **Log permission probe** (same checks as Record, no capture) and **Reveal agent log**. Settings → Logs tails `agent.jsonl` live.

## Mac loop

`scripts/mac_agent_loop.sh` every 3 minutes after `scripts/mac_install_agent_loop.sh`, or on demand:

1. Drop a stale `recording.lock` if that pid is gone. Skip restart if the pid is live.
2. Skip `git pull` if the working tree is dirty.
3. Fast-forward **`develop`**.
4. Rebuild `~/Applications/ScrumTrace.app` only on explicit request or a missing app.
5. Publish the last 4000 log lines to `cursor/scrumtrace-agent-logs-0397`.

To rebuild once from the Mac:

```bash
touch ~/Library/Logs/ScrumTrace/agent.request_rebuild
bash scripts/mac_agent_loop.sh
```

## Cloud agent

```bash
bash scripts/fetch_agent_log.sh
```

Triage the last `launch` → `start_*` / `stop_clicked` → `pipeline_status` / `whisper_*` / `talk_*` lines. Compare `cdhash` across launches. One diagnosed bucket, then one action (grant this CDHash, relaunch, or request a rebuild).

After a session exists, score every plan gate that has artifacts (does not write `samples/GATE_LOG.md`):

```bash
bash scripts/mac_all_gates.sh --no-build --latest
```
