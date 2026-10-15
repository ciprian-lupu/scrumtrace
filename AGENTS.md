# ScrumTrace — agent handbook

Read this before changing product code, gates, remotes, or TCC/signing. The working spec is [IMPLEMENTATION_PLAN.md](IMPLEMENTATION_PLAN.md). Mac debug loop: [AGENT_DEBUG.md](AGENT_DEBUG.md). Hardware results: [samples/GATE_LOG.md](samples/GATE_LOG.md) (empty until a Mac run).

Snapshot date: **2026-10-15** (processing panel with Finish later on `feature/processing-panel`; display selection before Start, processing progress, simplified recording menus and incomplete-session recovery/status corrections implemented on `develop`; Mac-to-Mac transfer, Codex handoff, bounded local procedure export and subscription-backed analysis integrated earlier). Hardware gates still open. Update the snapshot when status in this file changes.

## What this is

Native **macOS menu-bar recorder** (`com.str8minds.ScrumTrace`, App Sandbox **OFF**). It captures screen, system audio, and microphone on one host clock, then writes:

- `archive/` — private master (movie, WAV, full transcript, raw events). Never hand the live folder to an agent. Explicitly approved exception: Open archive in Codex copies the full source into that recording's shared Codex project after confirmation.
- `export/` — the default handoff folder (brief, context, stills, clips, measured zip); CLI and provider handoffs remain export-only.

Primary consumer is a filesystem-aware coding agent (Cursor / Claude Code) that reads `export/`. Web chat and `SESSION_BRIEF.html` are secondary.

Direction is approved. The spec is **not locked** and **not production-ready**. No new product surface until contracts C1–C5 are gated on a Mac, except the user-approved exceptions listed under Honest status.

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

On 2026-10-15 the user approved three refinements without new features: consistent local speech preparation, reuse of clip sources, and clearer processing progress. A shared local speech target now carries model, source and language through recording preload, Overview/Settings readiness and preload, voice notes, profile preparation and comparison. The main Speech selectors edit the selected local profile when present; cloud selection retains the local fallback for voice notes. Readiness requires the exact model/source pair, and the processor carries that source through a cold load instead of reverting to the standard catalog. Separate technical-only prewarm/load timings are logged. Each serial clip batch lazily prepares one private movie and one room/call audio composition, reuses both across clips, caches preparation failures, rejects cross-session reuse and cleans up on scope exit; cancellation propagates before publishing a cancelled clip. Main and floating processing panels put the current stage, elapsed time and measured stage percentage/count first, mute the other stages and visibly explain that Finish later preserves completed stages but restarts the unfinished stage on Retry. No whole-pipeline percentage is invented. Validation: 130 distinct targeted native tests passed across the final runs, with two explicit real-audio/speaker probes skipped; the full Linux contract suite passed. Tests include custom-source cold load/preload reuse, active-profile settings, multiple real synthetic clip exports with microphone offset checks, source cleanup/refusal/cancellation, recovery, local export, mute controls and window/panel layouts. The native progress control was checked through indeterminate → 30% → done transitions. Light/dark main-window and floating-panel snapshots were inspected; cached native material/progress rendering still needs a live visual check. The full native suite, live long-audio/multi-GB benchmark and capture gates were not run. The installed app, signing and TCC were not changed, and no real recording or provider upload was used.

On 2026-10-13 the user approved the first three implementation priorities from the read-only Claude CLI Fable 5.1 review, without new features. A `.transcribing` session whose existing timing metadata records an incomplete finished pass now waits for manual Retry Analysis rather than restarting at every launch; a fresh pass clears that outcome before model preparation/transcription, preserving recovery after a real interruption. Completed transcription stages remain resumable despite older incomplete timing. Pipeline progress keeps one clock per non-speech stage as messages change, clip/analysis messages stay stable around each item, the redundant Whisper message ticker is removed, and nested speech activities restore their still-active parent without accepting callbacks from ended operations. Inactive recordings now show Incomplete · retry or Interrupted in Recordings, Overview, Contexts and Recent recordings; failed runs show Export ready · AI failed only when synthesis completed and both local handoff documents exist, otherwise Needs attention. Startup and attention text distinguish these outcomes. Validation: 105 distinct targeted native tests passed across the final runs (recovery, progress/HUD, menu, comparison, Settings, library, relevant main-window tests and snapshots); the full Linux contract suite passed. Recordings light/dark, Overview, progress banner and HUD snapshots were inspected; cached Liquid Glass limitations still apply. The full native suite and live multi-GB processing/capture acceptance were not run. The installed app, signing and permissions were not changed; hardware gates remain open.

Later on 2026-10-13, at the user's request, `c871ee9` was built with `scripts/mac_gate01.sh`, installed at `~/Applications/ScrumTrace.app` using the local ScrumTrace Debug identity and launched. Before replacement, the running instance was idle, its previous processor had emitted `processor_ok` and its recording lock was absent; it was quit normally. Signature verification passed, and built/installed executable SHA-256 values matched. The installed app's launch reported Screen Recording and Microphone allowed, and did not resume the older finished-incomplete transcription. The existing seven local movies were all below 56 MB, so a clearly named synthetic 1,126,139,596-byte, three-minute 4K H.264/AAC fixture was prepared with a test pattern and synthesized speech, without captured meeting data or a fabricated capture environment. It appeared in Recordings. Native UI automation disconnected during selection and remained unavailable after reconnection attempts; no `processor_begin` was observed for the fixture. Live progress verification is therefore still pending manual Retry analysis (local-only), not passed. No original recording was reprocessed or uploaded and no capture/hardware gate was run. Local installation/fixture observations are outside the repository at `/private/tmp/scrumtrace-large-progress-check/`.

On 2026-10-13 the user requested processing percentages and a short status. The main window, menu and recording HUD now share operation progress with elapsed time; the minified HUD shows the operation percentage or elapsed time instead of the previous recording clock. WhisperKit download callbacks, native transcription progress and audio extraction supply measured percentages. Model specialization/loading and other operations without measurable progress show an indeterminate indicator and elapsed time. Clip generation and AI comparison count completed work; percentages describe the current operation, not an estimated whole-pipeline percentage. Progress also covers speech preparation before `SessionProcessor.process`, including automatic resume, without logging transcript text. Validation: 70 targeted native tests and the full Linux contract suite pass; banner and HUD snapshots were inspected. A locally signed build was installed at `~/Applications/ScrumTrace.app`; the live main window displayed speech loading with elapsed time during automatic resume. The resumed old recording emitted `processor_ok` but still had incomplete transcription; this is not a successful transcription acceptance. The final installed build passed signing verification and its CDHash matched the built app. Final relaunch resumed that old session and displayed the AI upload-consent dialog; it was left for the user's decision. No new recording or multi-GB performance acceptance was run, and hardware gates remain open.

Speaker review, Settings and menu stabilization were explicitly requested by the user on 2026-09-12 and are implemented and locally verified. Session-local diarization, manual names/corrections, timed clip transcripts and room/call mixing are within that approved scope. Native tests, Linux contracts, Settings and speaker-review UI checks pass; real multi-person accuracy and hardware gates remain open. The status-bar menu still needs a complete visual walkthrough. Still deferred: 60-minute drift claims and unrelated new product surfaces.

The user approved recording-bar audio mute controls on 2026-10-07. Implemented locally: independent Mute all (system audio plus microphone) and Mute mic controls remain available in the minified HUD, with orange muted-state labels. Unmuting all preserves the separate mic choice; each new recording resets both controls. Muting writes silent audio without pausing video or compressing the media timeline, covers ScreenCaptureKit and AVAudioEngine fallback inputs, and retains host-time intervals to silence delayed buffers after unmute. Effective mic mute also blocks/aborts Hold-to-Talk. The controls affect ScrumTrace capture only, not other apps or Mac volume. Fifteen focused native tests pass, covering PCM silence, timestamps, delayed buffers, independent state, Hold-to-Talk gating and HUD interaction/layout; the expanded HUD snapshot was inspected. Live capture acceptance remains open. After the user resumed work on 2026-10-07, the earlier run had emitted processor_ok and released its recording lock. The mute build was installed at ~/Applications/ScrumTrace.app with the local debug identity and reopened; signing verification passed and the installed executable matched the built executable. The live main window reported Ready to record, Speech model Ready, and Screen Recording/Microphone allowed. No new recording was started, so real captured-audio mute acceptance remains open. This is a user-approved recording-control exception to the surface deferral, not a hardware-gate pass.

The user asked on 2026-10-13 to choose the monitor before Start ([DISPLAY_SELECTION_PLAN.md](DISPLAY_SELECTION_PLAN.md), tasks D01–D07; reviewed by Codex CLI before implementation). Implemented: a full-display `CaptureArea` carries the display id (0 = main display, `CGMainDisplayID()`) and a label; the Start overlay's Entire Display button, Return and Space record the screen that overlay covers and each overlay shows its screen name; the menu's Capture area submenu and Settings → Capture list the connected displays plus Main display; the recorder resolves the pinned display by id only and fails the start when it is gone (no fallback to another display, so a region can no longer widen); Shots come from the pinned display with no main-display fallback and a failed crop fails the Shot; window titles and URLs are sampled only from the focused window whose centre is on the pinned display (app name only otherwise); `archive/capture-layout.json` records display id, name and configured capture size. A saved display that is not connected is shown greyed in the menu and Settings and as a notice on every overlay, and the user confirms a connected screen. The privacy pause, audio, Pause and single-window mode are unchanged. Verification: the full native run passed 454 tests and skipped 15, with seven `MainWindowTests` failures (retry/delete/drag/overview rows naming a session id from another test) that reproduce identically on unmodified `develop` at `ec3bedb` on this host, so the full native suite is not green here independently of this change; the new `CaptureDisplayTests`, updated `TimelineTests`/`MainWindowTests` strings and the Linux contract suite pass. The two-display Mac checks in the plan's §3 (Return on the external overlay, Shot from the external display, Safari on the unrecorded display, unplug during Start/recording/pause, Keynote focus) have **not** been run. This is a user-approved capture-control exception of the same class as single-window mode, not a hardware-gate pass.

The user asked on 2026-10-13 for processing to be transparent and animated after a launch resumed a 23-second recording from 22 September and showed "Loading Whisper model…" for ten minutes with Start disabled ([PROCESSING_PANEL_PLAN.md](PROCESSING_PANEL_PLAN.md), tasks P01–P06; reviewed by Codex CLI before implementation, four blockers and nine revisions applied). Implemented: `SessionController.processing` is one `ProcessingStatus` per run, fed by typed `ProcessingEvent`s from `SessionProcessor.process` and shown by a compact `ProcessingPanelView` under the live banner in the main window and by `ProcessingPanelWindow`, a non-activating floating panel with the HUD's focus rules that stands in for the recording pill during a run. Both name the recording and its date, list Resuming last recording → Loading speech model → Transcribing → Slicing → Evaluating → Packaging → Done with the current row highlighted and timed, say what to expect under the slow rows from measured loads (`UserDefaults`) and `stage_seconds` in `archive/pipeline-timing.json`, falling back to the measured range on this Mac (9 min 52 s to 11 min 27 s for a slow load, a few seconds for a fast one), and show seconds of audio decoded, clips cut and provider calls made. **Finish later** (panel button and menu item) cancels the run's inner task; the pipeline checks cancellation after every await and before every write, so a deferred recording keeps its manifest status, loses no file, stays resumable from Recordings, the menu and the next launch, and a speech model still loading keeps loading for the next run (`WhisperTranscriber.prepare` waits through a cancellation-aware waiter). A run that returns an incomplete manifest keeps Retry. The agent log names every stage (`processing_stage`, `processing_skip`, `processing_defer`, `processor_deferred`, `panel_retry`, `panel_close`; ids, enums and integers only). Verification: the full native run on the branch passed 486 tests and skipped 9 with five `MainWindowTests` failures, and after the merge with `develop` passed 491 and skipped 16 with eight; every failure is of the class the display-selection paragraph records (`main_*` rows filtered or naming a session id from another test in the same process) and every one not in the baseline passed when rerun alone. Unmodified `develop` at `b3bed2c` fails four on this host (the retry-with-consent-alert, two delete and the drag-folder `MainWindowTests`), so the full native suite is not green here independently of this change; the 24 new native tests in `ProcessingStatusTests`, `ProcessingPipelineTests`, `ProcessingPanelTests` and the new `MainWindowTests` case pass, as does the full Linux contract suite. Snapshot PNGs of the main window with the panel and of the floating panel in five states were rendered and inspected. The Mac checks in the plan's §3 (a real launch resume with the model cold, Finish later during the load, Retry reusing the load, Keynote focus with the floating panel, the deferred run's `mac_gate01.sh` behaviour) have **not** been run, and the installed app was not replaced. Integrated with the processing-progress, simplified-menu and incomplete-session commits that reached `develop` the same day: the operation-percentage banner and the pill's percentage stay for busy work that is not a pipeline run and step aside while the panel shows; *Finish later* sits under the simplified menu's status row; a pipeline run still resets the timing file's incomplete flag before any slow work. This is a user-approved processing-visibility change, not a hardware-gate pass.

On 2026-10-13 the user also approved simplifying the status-bar menu. The status row sits first and stays compact, preserving operation percentage/time and exposing full text in its tooltip. Capture controls and the capture-area chooser remain directly available. Last recording groups brief/export, coding-agent handoff, retry and transcription actions; the private archive action remains separately grouped and keeps its existing confirmation. Recent recordings lists five metadata-only date/duration/status labels with a Show all recordings action that opens the Recordings section. Settings opens directly in one click. Logs, permission tools, relaunch and updates live under Diagnostics; a missing required permission still exposes its remedy at the top level. Every submenu disables AppKit auto-enabling, and progress updates in place while menus are open. Validation: 28 targeted native tests and the full Linux contract suite pass, including empty/recent menus, session-bound actions, export-only brief access, busy/paused controls, Settings/log window reuse, handoff actions and progress without menu replacement. The locally signed build was installed and reopened; signing verification passed and its CDHash matched the built app. The live window showed allowed Screen Recording/Microphone and returned to Ready after resuming the old incomplete session. The UI automation surface exposed the main window/HUD but not the status-bar popup, so a full visual walkthrough of the actual popup remains open. No capture or hardware gate was run. Before publication, these changes were integrated with the display-selection commits already on `develop`; 89 targeted native tests and the full Linux contract suite passed on the combined tree. The installed app was not replaced during this publication step.

On 2026-10-07 the user requested subscription-only AI settings. The AI service editor now offers only Claude Code and Codex / ChatGPT, with sign-in checks, an optional model and a connection test. Endpoint, API-key and legacy-provider controls were removed from the AI tab. Legacy saved API services remain decodable/stored but are hidden and excluded from comparisonServiceConfigurations, including before the user opens Settings; opening the AI tab moves a legacy editor selection to an available subscription or no service. It does not automatically enable a subscription or upload. Speech settings remain separate. Validation: 73 targeted native tests passed, with two opt-in live subscription tests skipped; the full Linux contract suite passed.

The user approved subscription-backed automatic analysis on 2026-10-02. Settings → AI can select Claude Code or Codex using their existing local subscription sign-ins without an API key. The clients invoke the installed CLI in an isolated temporary working folder with prepared text/JPEG inputs and return results through the existing provider/comparison contract. Subscription analysis still goes to the provider’s servers and retains upload consent; video is excluded. API-key logins are rejected for these services, and application code never reads or copies auth tokens. Validation on this Mac on 2026-10-03: all 58 focused native tests passed, including live text connections and synthetic JPEG/JSON responses using both signed-in subscriptions; no tests were skipped. Settings persistence, analysis without an API key, authentication rejection, cancellation, timeouts and output limits passed. The full Linux contract suite also passed. The installed recording app has not been replaced; hardware gates remain open.

On 2026-10-03 an opt-in recording workflow check exercised all seven local recordings with WhisperKit, followed by text-only Claude Code and Codex subscription reviews. Five recordings produced usable transcripts and all ten review calls returned structured results; one recording produced no usable text, and the oldest recording failed because its MP4 is incomplete (`moov atom not found`). The batch test therefore failed on source integrity, not on subscription authentication. The test used the existing compressed turbo model on CPU/GPU with locally staged tokenizer files after observing Neural Engine compilation and Documents-file access stalls. This is a test configuration, not a production fallback. Original recordings and the installed app were not replaced. These are transcript reviews, not independent audio transcriptions or evidence of improved word accuracy. The opt-in harness is `RecordingSubscriptionWorkflowTests`; real transcripts and reports remain outside the repository. Linux contracts pass; hardware gates remain open.

On 2026-10-07, at the user’s request, commit `f808b6b` was built with `scripts/mac_gate01.sh`, installed at `~/Applications/ScrumTrace.app` using the local debug signing identity, and launched. The main window opened and reported Screen Recording and Microphone allowed. Startup resumed an unfinished recording and showed Whisper loading; completion was not established during this launch check. This installation supersedes the earlier notes that the installed app had not been replaced. No capture or hardware gate was run.

The user approved multi-provider comparison on 2026-09-13. Selected services evaluate identical prompt/JPEG/transcript inputs serially, with per-pair destination and SHA-256 provenance. Comparison excludes video. Retry preserves unchanged successes and refuses changed inputs. Live provider and hardware acceptance remain open.

The main window was explicitly requested by the user on 2026-09-13 and is an approved exception of the same class ([MAIN_WINDOW_PLAN.md](MAIN_WINDOW_PLAN.md), tasks H01–H07). Opening ScrumTrace from Finder, Launchpad, Spotlight or the Dock, clicking its icon or choosing **Open ScrumTrace…** in the menu opens one window with four sections: **Overview** (readiness, Start recording, needs attention, last recording, storage), **Recordings** (a metadata-only session table with search, filters, details and the Recent-menu actions), **Contexts** (saved contexts with usage counts and Record with this context…) and **Settings** (the existing six tabs). A Login Item launch, the agent loop (`--background`) and **Relaunch ScrumTrace** with the window closed keep ScrumTrace in the menu bar. While the window is open, ScrumTrace has a Dock tile and a ⌘-Tab entry, unless *Show ScrumTrace in the Dock while its window is open* is off in Settings → General. After the window closes, the tile stays until no other titled ScrumTrace window (such as the first-run permissions window) is open. The window does not change capture, pause, clock, Whisper, slicing, provider or export behaviour. Outside `App/`, `UI/` and the new `Storage/SessionLibrary.swift`, the branch adds only a read-only `recording.lock` reader in `Capture/AgentLog.swift`, a read-only `activeSessionId`, `forgetSession(id:newestRemaining:)` for a session the window deletes, and test hooks in `Processing/SessionController.swift`, and makes `listedSessionIds` internal in `Storage/SessionVault.swift`. The main window is not gate evidence: Xcode tests and Linux contracts pass, but none of its Mac checks (item 6 under *Next work*: Keynote focus with the window open, the focus hand-back after closing it, the real sidebar and toolbar) has been run.

The user approved Mac-to-Mac session transfer on 2026-09-15, including a separate, explicitly confirmed complete transfer of private originals. Recordings offers Import recordings and Export for another Mac, with native Command/Shift multi-selection and Select all listed recordings. Multiple exports use one destination folder and a separate package per recording; the import panel accepts several packages or folders. Each transfer commits independently, duplicates and existing destinations are skipped, and cancellation keeps completed transfers. A per-item result list reports partial completion. A .scrumtrace Finder package contains a versioned SHA-256 index; complete packages carry original media and results, while evidence packages contain only the existing export allow-list. Old session/export folders remain importable without claiming verified source checksums. Imported rows carry provenance; an old recording never acquires a fabricated capture environment from its exporter. Analyze a copy and Transcribe a new copy preserve the imported session and reset upload consent. TRANSFER_REVIEW.md reports technical observations and measured outcomes, not inferred accuracy or hardware-gate passes. On 2026-09-24 the user personally verified the Mac-to-Mac export/import happy path. Batch partial-failure/cancellation and full reanalysis across two Macs still require acceptance.

Transfer verification on macOS 26.6.2: 24 transfer tests, 18 library tests, both transfer snapshot tests and the native multi-selection tests pass, including local reprocessing of a synthetic imported copy, partial failure, duplicates, cancellation cleanup and private-data consent before any batch output. Linux contracts pass; light/dark transfer layouts were inspected. The final broader native run passed 385 tests and skipped 5, with two existing MainWindowTests failures (three assertions) while minimizing windows. Both failures reproduce on unmodified develop commit 173c6d3; the full native suite is therefore not green on this host. The existing Command-R/Delete/Escape test passed both its targeted rerun and the final full run after an intermittent first-run failure. No hardware-gate result is inferred.

Open in Codex was repaired and expanded at the user's request on 2026-09-15. Settings → AI saves Codex app (default) or Codex CLI in Terminal; menu, Overview and Recordings share this preference. The app route opens the documented local-workspace draft with a prepared prompt, without auto-submission. Both destinations accept a full transcript only when the export projection opts it in and it is not omitted. Terminal errors use fixed messages, and the now-used Automation entitlement is present for hardened builds. TCC grants remain unchanged. All 21 handoff tests (13 existing plus 8 regressions), five main-window snapshot tests and Linux contracts pass; light/dark destination layouts were inspected. The same two local window-minimization failures remain in the full native run. The earlier transfer commit passed both GitHub CI jobs. Hardware gates remain open.

The user clarified Codex handoff on 2026-09-15: offer Open export in Codex and Open archive in Codex in one project per recording, with a descriptive project name and simple Analyze export / Analyze archive task titles. First open offers an editable name; a persisted workspace binding and PR #11 adoption preserve the same path across subsequent opens, metadata changes and scope switches. Export refresh replaces only export/; the explicit archive action adds/refreshes source/ (canonical manifest, archive and corresponding export), keeping notes outside both. Archive copies run off the UI actor while session-changing actions are held busy. Once added, source/ remains accessible to later project tasks; prompt scope is not access isolation, and Codex analysis is not promised to be offline. Existing separate private workspaces are not deleted. Transfers/reanalysis exclude both legacy and shared workspace parents. Verification: 174 distinct targeted native tests pass across the final runs (workspace, handoff, CLI, transfer, library, main-window and snapshots), plus the full Linux contract suite. The two previously reproduced baseline minimization tests were excluded from this targeted run, not fixed. Recordings/Settings and the light naming/archive dialogs were visually inspected. Cached dark NSAlert images omit text/buttons on this host, so a live dark-dialog check remains; macOS Liquid Glass is also absent from cached sidebar/toolbar snapshots. The installed app and TCC were not changed. This is an approved handoff improvement, not a hardware-gate pass.

The bounded local procedure export is implemented from PR #14, with PR #12's useful command/prerequisite recognition retained and its overlapping implementation superseded. It stores review-only excerpts, chapters and Shot/Pin anchors, selects at most twelve media windows, and supports local-only regeneration without provider calls or transcription reloads. An imported original cannot be regenerated in place; use Analyze a copy to preserve its results. The combined tree passes the Linux contract suite and compiles the app and native tests on macOS; the integrated native tests have not been executed locally while the installed app is in use. PR #14's guarded four-copy mechanical replay passed before integration, but human-reviewed semantic step accuracy and an export-only consumer exercise remain open. This is not capture hardware-gate evidence. Details: [docs/local-export/VALIDATION.md](docs/local-export/VALIDATION.md).

## Where to work

```text
IMPLEMENTATION_PLAN.md     working spec (C1–C5, phases, disk, pause math)
MAIN_WINDOW_PLAN.md        main window tasks H01–H07 and implementation notes
AGENTS.md                  this file — remotes, status, next work
AGENT_DEBUG.md             JSONL loop, rebuild policy, log triage
README.md                  human runbook
samples/GATE_LOG.md        fill on a Mac; Linux green ≠ gate pass
samples/mock-session/      Phase -1 export pack + HANDOFF_LOG.md
ScrumTrace/                Swift app (sandbox off)
  App/                     settings, delegate + MainWindowPresenter, entry
  UI/                      menu bar, HUD, Shot, hotkeys, settings
    RecordingHUDWindow.swift draggable, edge-resizable, minifiable recording pill, hidden from screen sharing (frame in `scrumtrace.hud.frame`)
    MainWindow.swift       sections, split view, live banner, Dock seam
    OverviewView.swift     readiness, Start recording, needs attention
    RecordingsView.swift   session table, detail, actions, export/ drag
    ContextsView.swift     saved contexts, usage, Record with context
  Capture/                 SCKit, clock, pause, permissions, AgentLog
  Storage/                 vault, manifest models
    SessionLibrary.swift   metadata-only session index, delete, sizes
  Speech/                  WhisperKit
  Slicing/                 windows + clip export
  AI/                      providers, schema, evidence
  Export/                  projector, zip, brief, AGENT_CONTEXT
  Processing/              stop → transcribe → slice → evaluate → pack
ScrumTraceTests/           Xcode tests (Mac)
  MainWindowTests.swift    window, sections, Dock, focus, keyboard
  SessionLibraryTests.swift  session index, privacy allow-list, delete
  MainWindowSnapshotTests.swift  layout PNGs for a visual review; skipped unless SCRUMTRACE_SNAPSHOT_DIR is set
scripts/                   Linux tests, mock pack, Mac build, gate inspect
.cursor/environment.json   Linux: regenerate mock pack, preview :43147
```

Linux / cloud agents **cannot** compile ScreenCaptureKit or close Gate 0/1. They can change Swift, run Python contract tests, and serve the mock brief. After a Mac run, `scripts/inspect_all_gates.py` runs every inspector that has artifacts (Phase −1 mock, −0, 0, 1, Phase 2 Shot-pause log, 3–6). Those scripts fail closed on the signals they can see. They do not write `samples/GATE_LOG.md`.

## Commands

Linux / cloud (do this after Swift or script edits that the tests cover):

```bash
python3 -m pip install -r scripts/requirements.txt   # Pillow for generate_mock_session.py
# test_evidence.py also needs ffprobe on PATH (apt/brew install ffmpeg)
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

Xcode tests: `bash scripts/mac_xcode_test.sh`. For a visual layout review, `TEST_RUNNER_SCRUMTRACE_SNAPSHOT_DIR=/absolute/dir bash scripts/mac_xcode_test.sh` also writes PNGs of the main window (xcodebuild passes `TEST_RUNNER_` variables to the test process without the prefix). `ScrumTraceTests/MainWindowSnapshotTests.swift` renders every section over a fixture vault as `<section>-<variant>-<light|dark>.png`, and some `MainWindowTests` and `ProductContextTests` add `main-*.png`. Without the variable the two snapshot tests are skipped and the others write nothing. Nothing is asserted about pixels. On macOS 26 `NSView.cacheDisplay` cannot draw Liquid Glass, so the sidebar and, in the dark appearance, the toolbar items and the Settings tab strip come out blank: check those areas in the real window, not in the PNGs. Details: [MAIN_WINDOW_PLAN.md](MAIN_WINDOW_PLAN.md) §7.

Xcode resolves WhisperKit **0.11.0** from the committed `Package.resolved`. First WhisperKit launch downloads `openai_whisper-large-v3-v20240930_turbo_632MB`. Processing shows the processing panel ([PROCESSING_PANEL_PLAN.md](PROCESSING_PANEL_PLAN.md)): Resuming last recording → Loading speech model → Transcribing → Slicing → Evaluating → Packaging → Done, with Finish later and Retry. The speech model's first load after a restart took 9 min 52 s to 11 min 27 s on the development Mac and a few seconds afterwards; the panel says so. Archive capture is 3840×2160 at 4 fps / 16 Mbps.

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

Useful events: `launch`, `permission_probe`, `start_control_state`, `menu_start` (the status-bar menu; the window logs `main_start` and ⌘N `command_start`), `capture_area_picker` (display id only, never a display name), `menu_area_display`, `recorder_display_missing`, `start_*`, `recorder_sckit_*`, `mic_*`, `stop_requested`, `halt`, `terminate`, `claude_handoff`, `claude_handoff_fail`, `chatgpt_handoff`, `chatgpt_handoff_fail`. Processing panel: `processing_stage` (session id, `stage` enum, `prev`, `prev_seconds`, `origin` on the first row), `processing_skip` (`stage`, `reason` from a closed set), `processing_defer` (Finish later: `stage`, `elapsed`), `processor_deferred` (the run ended at a stage boundary; the manifest keeps its status), `panel_retry`, `panel_close`. Never a title, note, transcript or path. Main window: `main_open` (source and section only), `main_dock` (policy), `main_focus_return` (activated), and `main_*` actions that carry at most a session id or one small enum (`section`, `action`, `kind`).

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

The user-approved 2026-09-12 speaker/Settings/menu work, the 2026-09-13 main window (Overview, Recordings, Contexts, Settings), saved product contexts with selection before recording, and usable session briefs with transcript recovery and multi-provider comparison, plus the 2026-09-15 Mac-to-Mac transfer and 2026-09-23 local procedure export, are exceptions to the product-surface deferral. Keep other new surfaces deferred. Prefer work that can be verified in this environment.

### On a Mac (blocks “done”)

1. Force-quit ScrumTrace, `git checkout develop && git pull`, `bash scripts/mac_all_gates.sh` (or `mac_gate01.sh`), open `~/Applications/ScrumTrace.app`.
2. Grant Screen Recording + Microphone for **that** CDHash, Relaunch, get a **stable Record** (seconds, not 20 min). Gate −0: 30 s, then `inspect_all_gates.py`.
3. Gate 0: Keynote full-screen; Shot / Pin / Pause must not steal focus. Watch `ShotNoteWindow.canBecomeKey` — it is `true` today and can steal focus.
4. Gate 1: ≥ 20 min, three pauses, token `ST-G1-PAUSE-TOKEN-9F3C`, passphrase `orchid lantern seven`. Fill [samples/GATE_LOG.md](samples/GATE_LOG.md).
5. Only then treat Whisper / slicer / AI as gateable (Gates 3–6). Re-run `inspect_all_gates.py --strict` on that folder.
6. Main window walkthrough (not a gate; never write it into `GATE_LOG.md`): §7 and *Manual checks still open* in §8 of [MAIN_WINDOW_PLAN.md](MAIN_WINDOW_PLAN.md). None has been run. The ones that matter most: the switch to a Dock app when the window opens and the focus hand-back when it closes, on macOS 14 and on macOS 26; Gate 0 in Keynote full screen with the window closed and with it open behind the presentation, Shot included; what the older `NSApp.activate` calls (meeting notice, Cannot start recording, update result, capture-area picker, window chooser, recording-context window, upload consent, quit confirmation, Recording did not start, first-run permissions window, transcription review window) do while the window is open, because each may bring the window forward with it; the real sidebar, toolbar and Settings tab strip, which the snapshot PNGs leave blank in places; and the cost of the visible window's refresh with hundreds of recordings.

### In Swift (Linux-testable; do not call them “gated”)

Code leftovers from `SCRUMTRACE_AUDIT.md` that can be done without a Mac or Apple secrets are implemented. Still open only because they need hardware or secrets: Gate −0 through 6, Developer ID team + notary Apple ID, first Whisper download, Sparkle EdDSA keys, a paid license private key. Do not invent `GATE_LOG.md` cells.

Product contexts are a saved library in General. Start/⌘N confirms one (or No context) before capture-area selection. Copy the confirmed value into the session; never look up a current profile when retrying old sessions. The previous single context migrates once. Automatic selection is deferred to v2.

AI keys are a saved library of named services in Settings → AI. The active service controls editing/test; explicitly checked services supply provider, endpoint, model, and key for comparison. The previous single provider setting migrates once. Keys stay on the service id, not the endpoint host. Never log keys.

Settings is a six-tab section of the main window (Speech, Capture, Logs, Permissions, AI, General), not a window of its own; see the next paragraph. Start recording opens a macOS-style overlay on every screen (dashed rectangle, move/resize, Record / Entire Display / Cancel; each overlay shows its screen name; Return, Space and Entire Display confirm the screen that overlay covers, and the key overlay is the saved display, else the main display) and does not request Screen Recording from that click. Capture → Display and the menu's Capture area submenu pre-select a connected display or Main display; a saved display that is not connected is greyed there and announced on the overlay, never replaced silently. Only that display's screen is recorded, Shots come from it and titles/URLs are sampled only from windows on it; the recorder fails the start if it disappears between the overlay and the first frame. Capture can turn the pointer and microphone off for the next session.

The main window is one retained window owned by `MainWindowPresenter` in `AppDelegate.swift`; Settings is its fourth section, so ⌘, and the menu's Settings items open that section. The app icon (`applicationShouldHandleReopen`) shows this window, never a Settings-only window. The main window activates ScrumTrace only in `MainWindowPresenter.show()`, after an explicit user action. This rule covers the main window's code only: onboarding, the capture-area picker, the recording-context window, the menu's alerts (meeting notice, readiness, updates) and the processing alerts (upload consent, a failed start) keep their own `NSApp.activate` calls. While the main window is open ScrumTrace is a regular app, so those calls may bring the window forward with their alert or panel; that is an open Mac check, not verified behaviour. A launch that finds the newest recording mid-pipeline (`SessionController.resumeInterruptedSession`, called once from `applicationDidFinishLaunching`) retries it without a click and the processing panel names that recording and its date; never quit, kill or reinstall the app while `~/Library/Logs/ScrumTrace/agent.jsonl` shows a `processor_begin` without its `processor_ok`/`processor_fail`/`processor_deferred`, and `mac_gate01.sh` refuses to (it reads the newest manifest and, for a mid-pipeline status, the log's last `processor_*` row for that session). **Finish later** (panel button and menu item) cancels the run's inner task; the pipeline checks cancellation after every await and before every write, so a deferred run never writes a partial transcript, a slice without its clip or a cancelled provider result, and packaging is never interrupted. A speech model still loading keeps loading in the background and the next `prepare` for the same model reuses it. Hotkeys, the HUD, the processing panel, recording start and stop, processing and timers never open or front the main window, and main-menu commands act only while ScrumTrace is already active. `SessionLibrary.swift` indexes manifest metadata only: no transcript text, Shot notes, task titles, window titles, URLs or provider responses in lists, search or AgentLog. Thumbnails come from `export/shots/` only, and `archive/` is revealed only after a warning. `scripts/test_contracts.py` pins these rules. `mac_agent_loop.sh` opens the app with `--args --background`, so the loop never shows the window. A Login Item launch stays in the menu bar too, and **Relaunch ScrumTrace** passes `--background` on unless the window is open, and always when this instance was started with it (`MainWindowLaunchPolicy`).

### Plan-deferred (leave alone)

60-minute drift. Redesigning C1–C5. Sparkle SPM (v1 uses GitHub Releases). Gating Record on a license.

Briefs include per-stage processing status, evidence-backed highlights/decisions/actions/open questions, visible review-only results, timed passages next to clips and export links. Full transcript text may enter HTML only through the explicitly included export/full_transcript.json; omission removes it from both HTML and the pack. Local-only review rows must not say API Offline. Decoder prefill caching stays off (WhisperKit 0.11 empty-window regression); non-silent empty transcripts stay retryable.

## What “done” is not

- Green `run_linux_tests.sh` is not Gate 0–6.
- Code existing for Whisper / slicing / AI is not Gate 3–5.
- Settings showing ScrumTrace ON is not a grant for the current CDHash.
- A GitHub compare from `main` to `develop` is not a merge plan.

When you change status (gates filled, Record proven, branch policy), update the snapshot date and the Honest status section in this file.
