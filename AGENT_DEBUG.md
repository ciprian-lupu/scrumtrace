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
- Interrupted processing: `interrupted_session` at launch names the last unfinished status; `resume_interrupted` follows when the launch finishes it on its own (then the usual `retry_begin` / `processor_*` rows), `resume_interrupted_skipped` when a start was in flight, `menu_quit` with `busy=1` and `menu_quit_cancelled` for the Quit confirmation. `mac_gate01.sh` exits 3 instead of replacing a processing app unless `SCRUMTRACE_FORCE_INSTALL=1`.
- Pipeline: `processor_begin`, `processor_ok`, `processor_fail`, `processor_deferred` (Finish later ended the run at a stage boundary; the manifest keeps its status and Retry analysis continues it), `pipeline_status` (every HUD line after Stop — this is how to debug a stuck “Transcribing” state), `processing_stage` (the processing panel's rows: `stage` is `resuming`, `loading_model`, `transcribing`, `slicing`, `evaluating`, `packaging` or `done`; `prev` and `prev_seconds` name the row that just ended; the first row carries `origin` = `stop`, `launch_resume`, `retry` or `local_export`), `processing_skip` (`stage` and a `reason` from a closed set: `already_loaded`, `already_done`, `consent`, `local_only`, `model_refused`, `key_missing`, `transcription_incomplete`, `no_anchors`), `processing_defer` (Finish later clicked: `stage`, `elapsed`), `panel_retry`, `panel_close`, `whisper_prepare_*`, `whisper_model_phase` (separate `prewarm`/`load` elapsed milliseconds; no paths or transcript text), `whisper_file_*`, `whisper_pass_*`, `extract_audio_*`, `slice_done`, `eval_*`, `zip_ok`, `consent_result`, `retry_*`. A ten-minute gap between `whisper_prepare_begin` and `whisper_prepare_ok` with `reuse=0` is the speech model compiling after a restart (9 min 52 s to 11 min 27 s on the development Mac); the same model loads in a few seconds afterwards.
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
