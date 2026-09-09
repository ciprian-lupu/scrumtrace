# ScrumTrace

Mac menu-bar recorder for sprint demos and design reviews. It captures screen, system audio, and microphone on one clock, then writes an **`export/`** folder for Cursor / Claude Code — not the private archive.

The working spec is [IMPLEMENTATION_PLAN.md](IMPLEMENTATION_PLAN.md) (contracts revised 2026-09-09). Direction is approved; the spec is **not locked** and is **not production-ready**.

## What exists in this tree

- Native Swift menu-bar app (`com.str8minds.ScrumTrace`, sandbox off)
- Pause gate shared by screen, system audio, microphone, metadata, Shot, and Hold-to-Talk
- Session disk layout: `archive/` (private) vs `export/` (handoff)
- Pluggable AI adapters behind one internal contract (MVP: OpenAI-compatible)
- Timeline math tests: `python3 scripts/test_timeline.py`

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
| Pause | ⌥⌘P | Toggles. No new bytes from any capture source |

## Handoff

Give the agent **`export/`** only. Never drop the session root or `archive/` (master `session.mp4`, `audio.wav`, full transcript, raw events).

## Next gates

1. Phase -1 mock `export/` + `HANDOFF_LOG.md`
2. Phase 0–1 on a Mac: 20 min record, 3 pauses, all-source pause token test
3. Phase 5–6 only after consent, measured 35 MB pack, evidence validation
