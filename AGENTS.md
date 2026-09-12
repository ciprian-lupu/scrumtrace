# ScrumTrace — agent handbook

Read this before changing product code, gates, remotes, or TCC/signing. The working spec is [IMPLEMENTATION_PLAN.md](IMPLEMENTATION_PLAN.md). Mac debug loop: [AGENT_DEBUG.md](AGENT_DEBUG.md). Hardware results: [samples/GATE_LOG.md](samples/GATE_LOG.md) (empty until a Mac run).

Snapshot date: **2026-09-12** (audit TASK-01–17 plus leftover *code* items closed; all-gate inspectors: `inspect_all_gates.py` / `mac_all_gates.sh`). Hardware gates still open. Update the snapshot when status in this file changes.

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

**Software for phases -1 through 6 and contracts C1–C5 is in the tree.** The `SCRUMTRACE_AUDIT.md` Part E queue (TASK-01–17) and the remaining Part C/G *code* leftovers that can be done without a Mac or Apple secrets are implemented on `develop`. Linux contract tests pass: `bash scripts/run_linux_tests.sh`.

**Hardware gates are not closed.** `samples/GATE_LOG.md` has no PASS rows. No Mac has run Gate −0 after these fixes. Treat Record, pause, Whisper, and drift as **unproven** until that log is filled.

Speaker review, Settings and menu stabilization were explicitly requested by the user on 2026-09-12 and are implemented and locally verified. Session-local diarization, manual names/corrections, timed clip transcripts and room/call mixing are within that approved scope. Native tests, Linux contracts, Settings and speaker-review UI checks pass; real multi-person accuracy and hardware gates remain open. The status-bar menu still needs a complete visual walkthrough. Still deferred: 60-minute drift claims and unrelated new product surfaces.

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

Linux / cloud agents **cannot** compile ScreenCaptureKit or close Gate 0/1. They can change Swift, run Python contract tests, and serve the mock brief. After a Mac run, `scripts/inspect_all_gates.py` runs every inspector that has artifacts (Phase −1 mock, −0, 0, 1, Phase 2 Shot-pause log, 3–6). Those scripts fail closed on the signals they can see. They do not write `samples/GATE_LOG.md`.

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

Xcode resolves WhisperKit **0.11.0** from the committed `Package.resolved`. First WhisperKit launch downloads `openai_whisper-large-v3-v20240930_turbo_632MB`. HUD: Loading Whisper model… then Transcribing. Archive capture is 3840×2160 at 4 fps / 16 Mbps.

All-gate inspect (after a real session folder exists). Gate 1 still needs the Part F.2 token and three closed pauses / ≥ 20 min of `t_media`:

```bash
python3 scripts/inspect_all_gates.py --session /path/to/session \
  --log ~/Library/Logs/ScrumTrace/agent.jsonl --log-start-line N \
  --token 'ST-G1-PAUSE-TOKEN-9F3C' \
  --passphrase 'orchid lantern seven' \
  --manual-video-scrub-ok --manual-audio-scrub-ok \
  --av-offset-ms 12 --ptt-temp-deleted-ok
# Strict all-gate acceptance:
# python3 scripts/inspect_all_gates.py --artifact-map path/to/map.json --strict
```

On a Mac, `bash scripts/mac_all_gates.sh --begin` then `bash scripts/mac_all_gates.sh --latest` builds Debug (unless `--no-build`) and runs that inspector against the newest session folder with `--guided`. Strict acceptance needs `--artifact-map`. It never writes GATE_LOG.md.

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

Useful events: `launch`, `permission_probe`, `start_control_state`, `menu_start`, `capture_area_picker`, `start_*`, `recorder_sckit_*`, `mic_*`, `stop_requested`, `halt`, `terminate`.

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

The user-approved 2026-09-12 speaker/Settings/menu work, saved product contexts with selection before recording, and usable session briefs with transcript recovery are exceptions to the product-surface deferral. Keep other new surfaces deferred. Prefer work that can be verified in this environment.

### On a Mac (blocks “done”)

1. Force-quit ScrumTrace, `git checkout develop && git pull`, `bash scripts/mac_all_gates.sh` (or `mac_gate01.sh`), open `~/Applications/ScrumTrace.app`.
2. Grant Screen Recording + Microphone for **that** CDHash, Relaunch, get a **stable Record** (seconds, not 20 min). Gate −0: 30 s, then `inspect_all_gates.py`.
3. Gate 0: Keynote full-screen; Shot / Pin / Pause must not steal focus. Watch `ShotNoteWindow.canBecomeKey` — it is `true` today and can steal focus.
4. Gate 1: ≥ 20 min, three pauses, token `ST-G1-PAUSE-TOKEN-9F3C`, passphrase `orchid lantern seven`. Fill [samples/GATE_LOG.md](samples/GATE_LOG.md).
5. Only then treat Whisper / slicer / AI as gateable (Gates 3–6). Re-run `inspect_all_gates.py --strict` on that folder.

### In Swift (Linux-testable; do not call them “gated”)

Code leftovers from `SCRUMTRACE_AUDIT.md` that can be done without a Mac or Apple secrets are implemented. Still open only because they need hardware or secrets: Gate −0 through 6, Developer ID team + notary Apple ID, first Whisper download, Sparkle EdDSA keys, a paid license private key. Do not invent `GATE_LOG.md` cells.

Product contexts are a saved library in General. Start/⌘N confirms one (or No context) before capture-area selection. Copy the confirmed value into the session; never look up a current profile when retrying old sessions. The previous single context migrates once. Automatic selection is deferred to v2.

Settings is a six-tab window (Speech, Capture, Logs, Permissions, AI, General). Start recording opens a macOS-style overlay (dashed rectangle, move/resize, Record / Entire Display / Cancel; Return confirms the key display) and does not request Screen Recording from that click. Capture can turn the pointer and microphone off for the next session.

### Plan-deferred (leave alone)

60-minute drift. Redesigning C1–C5. Sparkle SPM (v1 uses GitHub Releases). Gating Record on a license.

Briefs include per-stage processing status, evidence-backed highlights/decisions/actions/open questions, visible review-only results, timed passages next to clips and export links. Full transcript text may enter HTML only through the explicitly included export/full_transcript.json; omission removes it from both HTML and the pack. Local-only review rows must not say API Offline. Decoder prefill caching stays off (WhisperKit 0.11 empty-window regression); non-silent empty transcripts stay retryable.

## What “done” is not

- Green `run_linux_tests.sh` is not Gate 0–6.
- Code existing for Whisper / slicing / AI is not Gate 3–5.
- Settings showing ScrumTrace ON is not a grant for the current CDHash.
- A GitHub compare from `main` to `develop` is not a merge plan.

When you change status (gates filled, Record proven, branch policy), update the snapshot date and the Honest status section in this file.
