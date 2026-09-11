# ScrumTrace — agent handbook

Read this before changing product code, gates, remotes, or TCC/signing. The working spec is [IMPLEMENTATION_PLAN.md](IMPLEMENTATION_PLAN.md). Mac debug loop: [AGENT_DEBUG.md](AGENT_DEBUG.md). Hardware results: [samples/GATE_LOG.md](samples/GATE_LOG.md) (empty until a Mac run).

Snapshot date: **2026-09-11** (audit TASK-01–17 plus Whisper 632 MB default, Settings/logs, consent/leak hardening; hardware still open). Update the snapshot when status in this file changes.

## What this is

Native **macOS menu-bar recorder** (`com.str8minds.ScrumTrace`, App Sandbox **OFF**). It captures screen, system audio, and microphone on one host clock, then writes:

- `archive/` — private master (movie, WAV, full transcript, raw events). Never hand this to an agent.
- `export/` — the only handoff folder (brief, context, stills, clips, measured zip).

Primary consumer is a filesystem-aware coding agent (Cursor / Claude Code) that reads `export/`. Web chat and `SESSION_BRIEF.html` are secondary.

Direction is approved. The spec is **not locked** and **not production-ready**. No new product surface until contracts C1–C5 are gated on a Mac.

## Remotes and branches

Public repo: `https://github.com/ciprian-lupu/scrumtrace`

| Ref | Role |
|---|---|
| **`develop`** | Working implementation. All product work lands here. |
| `github` `main` | Older **spec/docs** history. **Unrelated** to `develop`. Do not merge, rebase, or force-push it. |
| `cursor/scrumtrace-agent-logs-0397` | Optional published Mac `agent.jsonl` bus. Not source of truth. |
| Cloud `origin` | Cursor workspace remote. May also have a `main` that tracks this implementation. Public source of truth is GitHub `develop`. |

Clone / continue on a Mac:

```bash
git clone -b develop https://github.com/ciprian-lupu/scrumtrace.git
cd scrumtrace
# existing clone that was on cursor/scrumtrace-implementation-0397:
git fetch origin
git checkout develop
git pull --ff-only origin develop
```

Compare (do not auto-merge): `https://github.com/ciprian-lupu/scrumtrace/compare/main...develop`

Hard rules:

- Push implementation to **`develop`**.
- Leave GitHub `main` untouched unless a human explicitly plans a history rewrite.
- Leave `samples/mock-session/export/session-pack.zip` uncommitted when `generate_mock_session.py` only rewrites its hash.

## Honest status

**Software for phases -1 through 6 and contracts C1–C5 is in the tree.** The `SCRUMTRACE_AUDIT.md` Part E queue (TASK-01–17) is implemented on `develop`. Linux contract tests pass: `bash scripts/run_linux_tests.sh`.

**Hardware gates are not closed.** `samples/GATE_LOG.md` has no PASS rows. No Mac has run Gate −0 after these fixes. Treat Record, pause, Whisper, and drift as **unproven** until that log is filled.

Explicitly deferred by the plan: speaker diarization, 60-minute drift claims, new product surfaces.

## Where to work

```text
IMPLEMENTATION_PLAN.md     working spec (C1–C5, phases, disk, pause math)
AGENTS.md                  this file — remotes, status, next work
AGENT_DEBUG.md             JSONL loop, rebuild policy, log triage
README.md                  human runbook
samples/GATE_LOG.md        fill on a Mac; Linux green ≠ gate pass
samples/mock-session/      Phase -1 export pack + HANDOFF_LOG.md
ScrumTrace/                Swift app (sandbox off)
  App/                     settings, delegate, entry
  UI/                      menu bar, HUD, Shot, hotkeys, settings
  Capture/                 SCKit, clock, pause, permissions, AgentLog
  Storage/                 vault, manifest models
  Speech/                  WhisperKit
  Slicing/                 windows + clip export
  AI/                      providers, schema, evidence
  Export/                  projector, zip, brief, AGENT_CONTEXT
  Processing/              stop → transcribe → slice → evaluate → pack
ScrumTraceTests/           Xcode tests (Mac)
scripts/                   Linux tests, mock pack, Mac build, gate inspect
.cursor/environment.json   Linux: regenerate mock pack, preview :43147
```

Linux / cloud agents **cannot** compile ScreenCaptureKit or close Gate 0/1. They can change Swift, run Python contract tests, and serve the mock brief.

## Commands

Linux / cloud (do this after Swift or script edits that the tests cover):

```bash
bash scripts/run_linux_tests.sh
python3 scripts/generate_mock_session.py   # only commit if mock *content* changed
python3 scripts/serve_preview.py --host 127.0.0.1 --port 43147
```

`scripts/test_contracts.py` is **string-based**: keep the snippets it greps for.

macOS 14+ (Apple Silicon recommended):

```bash
# quit every ScrumTrace process first
bash scripts/mac_gate01.sh
open ~/Applications/ScrumTrace.app
```

That copies a Debug build to `~/Applications/ScrumTrace.app` and signs it with a local **ScrumTrace Debug** identity. Open **that** copy. Enable Screen Recording and Microphone for it, then **Relaunch**. A grant never applies to the already-running process. Accessibility is optional.

Xcode resolves WhisperKit **0.11.0** on first open (`Package.resolved` is not checked in). First WhisperKit launch downloads `openai_whisper-large-v3-v20240930_turbo_632MB`. HUD: Loading Whisper model… then Transcribing.

Gate 1 inspect (after a real session folder exists):

```bash
python3 scripts/inspect_gate1_session.py --session /path/to/session \
  --token 'ST-G1-PAUSE-TOKEN-9F3C' \
  --passphrase 'orchid lantern seven' \
  --shot-before-pause "$BEFORE"
```

## TCC and Record (Mac)

Ad-hoc Debug rebuilds are a **new TCC client**. System Settings can show ScrumTrace ON for a **stale binary**. Compare the running app’s `cdhash` in `~/Library/Logs/ScrumTrace/agent.jsonl` to the row in Settings.

Rebuild **only on request**. Auto-rebuild on every `develop` push mints a new client and breaks grants.

Request one rebuild on the Mac:

```bash
touch ~/Library/Logs/ScrumTrace/agent.request_rebuild
bash scripts/mac_agent_loop.sh
```

Or `SCRUMTRACE_FORCE=1`. The loop default branch is `develop` (`SCRUMTRACE_BRANCH`).

Do not call `SCShareableContent` unless Screen Recording is already granted. Do not `requestTrust(prompt: true)` on Record. Preflight is in `CapturePermissions.swift`.

Until Record stays up, do not start the 20-minute Gate 1 run.

## Agent debug loop

The app writes `~/Library/Logs/ScrumTrace/agent.jsonl` (technical fields only: no titles, URLs, notes, transcripts, or keys). Live session: `recording.lock` (ignored if its pid is dead).

Useful events: `launch`, `permission_probe`, `start_control_state`, `start_*`, `recorder_sckit_*`, `mic_*`, `stop_requested`, `halt`, `terminate`.

Cloud read:

```bash
bash scripts/fetch_agent_log.sh
```

A generic Task subagent does **not** land on the self-hosted Mac worker. Prefer `cat` of the JSONL on the Mac when that worker is actually targeted. Details: [AGENT_DEBUG.md](AGENT_DEBUG.md).

## Contracts (do not redesign)

Close these in code **and** on a Mac. Full text: [IMPLEMENTATION_PLAN.md](IMPLEMENTATION_PLAN.md).

| ID | Meaning |
|---|---|
| C1 | Pause applies to screen, system audio, mic, metadata, Shot, Hold-to-Talk |
| C2 | `archive/` vs `export/`; explicit upload consent before any provider call |
| C3 | Pack size is **measured**, then enforced. Zip ≤ 35 MB. Archive uncapped |
| C4 | One internal eval contract; adapters declare text/images/video. MVP = one provider |
| C5 | Kept candidates have validatable evidence. HTML escaped. `confirmed` has a rule |

C4 wire truth today: Google may upload a size-capped inline MP4. OpenAI-compatible and Anthropic send stills + transcript only (`ProviderWireMedia`). If a slice has no still and the adapter will not upload video, the task is `needs_review`.

`confirmed` requires keep + confidence ≥ 0.55 + existing export evidence + quotes that hit the transcript. `inferred` never becomes `confirmed` alone.

## Next work (priority)

Do **not** add product surfaces. Prefer the first item you can actually finish in this environment.

### On a Mac (blocks “done”)

1. Force-quit ScrumTrace, `git checkout develop && git pull`, `bash scripts/mac_gate01.sh`, open `~/Applications/ScrumTrace.app`.
2. Grant Screen Recording + Microphone for **that** CDHash, Relaunch, get a **stable Record** (seconds, not 20 min).
3. Gate 0: Keynote full-screen; Shot / Pin / Pause must not steal focus. Watch `ShotNoteWindow.canBecomeKey` — it is `true` today and can steal focus.
4. Gate 1: ≥ 20 min, three pauses, token `ST-G1-PAUSE-TOKEN-9F3C`, passphrase `orchid lantern seven`. Fill [samples/GATE_LOG.md](samples/GATE_LOG.md).
5. Only then treat Whisper / slicer / AI as gateable (Gates 3–6).

### In Swift (Linux-testable; do not call them “gated”)

Fix-first list from the last implementation audit:

1. `SessionProcessor.transcribe` — if one Whisper pass throws, the other surviving pass is discarded (`requiredFailed` → empty transcript). Keep the surviving pass.
2. Gate 0 — Shot note window `canBecomeKey` can steal Keynote focus.
3. Confirmed tasks — remap leftover `*.png` evidence onto export `*.jpg` twins the same way review tasks do.
4. `forceReview` when no still actually left the Mac (including a Google clip over the inline size cap).
5. Smaller: privacy overlay not `frontmost` during `startCapture`; AVAudioEngine WAV has no host-clock PTS; `AgentLog` `localizedDescription` may leak paths; clip-only + no-video labeled `skipped` instead of `needs_review`.

### Plan-deferred (leave alone)

Diarization. 60-minute drift. New modules / new product UI. Redesigning C1–C5.

## What “done” is not

- Green `run_linux_tests.sh` is not Gate 0–6.
- Code existing for Whisper / slicing / AI is not Gate 3–5.
- Settings showing ScrumTrace ON is not a grant for the current CDHash.
- A GitHub compare from `main` to `develop` is not a merge plan.

When you change status (gates filled, Record proven, branch policy), update the snapshot date and the Honest status section in this file.
