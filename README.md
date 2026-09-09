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

## Build (macOS 14+, Apple Silicon recommended)

```bash
open ScrumTrace.xcodeproj
```

Grant Screen Recording and Microphone. First WhisperKit launch downloads `large-v3-turbo`.

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

## Next gates (must run on a Mac)

Use the fill-in log at [`samples/GATE_LOG.md`](samples/GATE_LOG.md). Linux tests do **not** prove these.

1. Phase 0–1: 20 min record, 3 pauses, all-source pause token test (screen, system audio, mic, Shot, Hold-to-Talk)
2. Phase 3: WhisperKit elapsed time on a named Mac; confirm `full_transcript.json` `sources` includes room and system when both were captured
3. Phase 5–6: invalid key does not crash; measured zip ≤ 35 MB; remaining `AGENT_CONTEXT.md` paths exist
