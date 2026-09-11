# ScrumTrace

Mac menu-bar recorder for sprint demos and design reviews. It captures screen, system audio, and microphone on one clock, then writes an **`export/`** folder for Cursor / Claude Code — not the private archive.

The working spec is [IMPLEMENTATION_PLAN.md](IMPLEMENTATION_PLAN.md) (contracts revised 2026-09-09). Direction is approved; the spec is **not locked** and is **not production-ready**.

## What exists in this tree

- Native Swift menu-bar app (`com.str8minds.ScrumTrace`, sandbox off)
- Pause gate shared by screen, system audio, microphone, metadata, Shot, and Hold-to-Talk
- WhisperKit transcribes the room-mic WAV **and** system audio in `archive/session.mp4`, then merges on `t_media`
- Gate 3/6 timings written to `archive/pipeline-timing.json` (never in the export zip)
- Session disk layout: `archive/` (private) vs `export/` (handoff, export-relative paths)
- Measured 35 MB `session-pack.zip` with `OMITTED.md` when the cap drops files
- Pluggable AI adapters behind one internal contract (MVP: OpenAI-compatible + JSON Schema)
- Timeline / contract / transcript-merge / pack-budget / evidence tests (no Mac required): `bash scripts/run_linux_tests.sh`

## Open in Cursor

Working branch is **`develop`**. GitHub `main` is an older spec-only history — do not merge or force-push it. Agents: start at [AGENTS.md](AGENTS.md).

This repo is the Cursor project. On a Mac:

```bash
git clone -b develop https://github.com/ciprian-lupu/scrumtrace.git
cd scrumtrace
cursor .
```

Or **File → Open Folder** on that clone. Run **Linux tests** / **Serve SESSION_BRIEF preview** from the Command Palette tasks. The menu-bar app still needs Xcode on macOS 14+.

Cloud / Linux agents use `.cursor/environment.json` (regenerate the mock pack, serve the brief on port 43147). They cannot compile ScreenCaptureKit or run Gate 0/1.

## Build (macOS 14+, Apple Silicon recommended)

```bash
bash scripts/mac_gate01.sh
open ~/Applications/ScrumTrace.app
```

The script copies the Debug build to `~/Applications/ScrumTrace.app` and signs it with a local **ScrumTrace Debug** identity (created once in your login keychain). Ad-hoc Xcode builds look like a new app to macOS on every rebuild, which is why Screen Recording and Microphone keep asking after you already flipped the toggle.

Open **that** copy only. In System Settings, remove extra ScrumTrace rows, enable Screen Recording and Microphone for this app, then **Relaunch** from the menu. A grant never applies to the process that was already running. Accessibility is optional.

Xcode resolves WhisperKit **0.11.0** on first open (`Package.resolved` is not checked in). First WhisperKit launch downloads `large-v3_turbo`.

Inspect a Gate 1 session folder (token and passphrase are the Part F.2 values):

```bash
python3 scripts/inspect_gate1_session.py --session /path/to/session \
  --token 'ST-G1-PAUSE-TOKEN-9F3C' \
  --passphrase 'orchid lantern seven' \
  --shot-before-pause "$BEFORE"
```

## Hotkeys

| Action | Key | While paused |
|---|---|---|
| Shot | ⌥⌘S | Disabled (no new frame) |
| Pin | ⌥⌘Space | Ignored |
| Pause | ⌥⌘P | Toggles. No new bytes from any capture source. In-flight Hold-to-Talk is aborted. |

## Handoff

Give the agent **`export/`** only. Never drop the session root or `archive/` (master `session.mp4`, `audio.wav`, full transcript, raw events). Paths inside the pack are relative to that folder (`shots/…`, `media/…`).

Phase -1 mock pack (open in a browser or drop into Cursor):

```bash
python3 scripts/generate_mock_session.py
python3 scripts/serve_preview.py --port 43147
```

Then open `samples/mock-session/export/SESSION_BRIEF.html`. The image-only failure code and the clip-only recovery sequence are **not** in `AGENT_CONTEXT.md` — they live in `shots/` and `media/task-02/clip.mp4`. See `samples/mock-session/HANDOFF_LOG.md`.

## Agent debug loop

The Mac writes `~/Library/Logs/ScrumTrace/agent.jsonl` and a LaunchAgent can pull `develop`, rebuild **only on request**, and publish that log to `cursor/scrumtrace-agent-logs-0397`. Cloud agents read it with `bash scripts/fetch_agent_log.sh`. See [AGENT_DEBUG.md](AGENT_DEBUG.md).

## Next gates (must run on a Mac)

Use the fill-in log at [`samples/GATE_LOG.md`](samples/GATE_LOG.md). Linux tests do **not** prove these.

1. Phase 0–1: 20 min record, 3 pauses, all-source pause token test (screen, system audio, mic, Shot, Hold-to-Talk)
2. Phase 3: WhisperKit elapsed time on a named Mac; confirm `full_transcript.json` `sources` includes room and system when both were captured
3. Phase 5–6: invalid key does not crash; measured zip ≤ 35 MB; remaining `AGENT_CONTEXT.md` paths exist
