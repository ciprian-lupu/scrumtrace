# ScrumTrace — Processing Panel Plan (see what is being worked on, and finish it later)

Status: **implemented on `feature/processing-panel`** (tasks P01–P06; P07 not done), written 2026-10-13, branched
from `develop` at `b3bed2c`. Revision 2 folds in the Codex CLI review of revision 1 (§6: four blockers,
nine revisions, all verified against the code); §7 records where the build differs from the task text.
The Mac checks in §3 have not been run.

Request (2026-10-13): "it gets stuck in transcription or doing last session work, that process
should be more transparent and animated." Approved shape: one panel, opened automatically when
processing starts, in the main window and the HUD; it names the recording and its date; a stage list
with the current stage highlighted and animated (Resuming last recording → Loading speech model →
Transcribing → Slicing → Evaluating → Packaging → Done); an elapsed timer per stage plus a plain
expectation under the slow ones; real progress where it exists (seconds of audio, clips, provider
calls); a **Finish later** button that defers the old recording so Start recording is not blocked;
a **Retry** button on failure with the reason; the same stage names in the agent log.

This document follows the task format of [MAIN_WINDOW_PLAN.md](MAIN_WINDOW_PLAN.md) and
[DISPLAY_SELECTION_PLAN.md](DISPLAY_SELECTION_PLAN.md) (Files / Implementation / Tests / Done when /
Commit). Tasks P01–P07 are ordered so each one compiles and passes on its own, **including the
contract tests it changes**.

---

## 0. What happens today

The 2026-10-13 launch at 14:39 (`~/Library/Logs/ScrumTrace/agent.jsonl`, UTC in the file):

| Time | Event | What the user saw |
|---|---|---|
| 11:39:29Z | `launch`, `interrupted_session status=transcribing`, `resume_interrupted`, `processor_begin` (session `2026-09-22-1255-8f816e`, 23 s recorded on 22 September) | HUD pill: "Finishing the interrupted session…", then "Loading Whisper model…". No recording named, no date. Start recording disabled. |
| 11:39:29Z | `whisper_prepare_begin` | "Loading Whisper model… 2s (first run downloads ~632 MB)" ticking every 2 s. The model was downloaded weeks ago; the time goes to CoreML/ANE compilation. |
| 11:49:15Z | `whisper_prepare_ok elapsed_ms=585493` | Nine minutes forty-five seconds later. |
| 11:49:16Z | `whisper_file_ok ms=865`, `pipeline_status` ×n, `incomplete_handoff`, `processor_ok` | Transcribed, sliced and packaged in about a second. |

The same recording was resumed on 7 October (10 min 27 s load), on 8 October (`terminate` 27 s
after `processor_begin`: the user quit during the load) and twice more today by a test build. On
this Mac the compressed turbo model (`openai_whisper-large-v3-v20240930_turbo_632MB`, WhisperKit
0.11.0, macOS 26.6.2) has loaded in 9 min 52 s to 11 min 27 s on six "cold" launches and in 4 to
7 s on four "warm" ones (`whisper_prepare_ok reuse=0 elapsed_ms`, 12 September to 13 October). The
slow case is not the download; it recurs after a restart or a long idle period.

| Surface | Behaviour on `develop` today | Where |
|---|---|---|
| Launch with the newest recording mid-pipeline | `resumeInterruptedSession()` retries it without a click and sets the status line to "Finishing the interrupted session…". Nothing says which recording or how old. | `SessionController.swift:148–159` |
| HUD during processing | The pill shows `controller.statusLine` only; Shot/Pin/Pause/Stop hidden; dot turns blue. No stage, no timer, no button. | `RecordingHUDWindow.swift:181–200` `refresh()` |
| Main window during processing | The live banner is hidden (`isVisible = controller.isRecording`); Overview's "Needs attention" leaves the held session out ("it is in progress") while its *Last recording* card shows the recording with its status label ("Transcribing") and no stage detail; the Start card says analysis is running. Nothing shows which stage, how long, or what to expect. | `MainWindow.swift:357`, `OverviewView.swift:430`, `:912–928` |
| Status-bar menu | A disabled status item with the same line; *Retry analysis* and Start disabled while `isBusy`. | `MenuBarController.swift:117`, `:144`, `:211` |
| Model load | `waitForPrepare` ticks "Loading Whisper model… Ns (first run downloads ~632 MB)" every 2 s and gives up after 12 min. The load itself is a `Task.detached` inside `WhisperTranscriber.prepare`; a second `prepare` call waits on it (`.wait`). | `SessionProcessor.swift:1083–1115`, `WhisperTranscriber.swift:70–142` |
| Transcription progress | None. WhisperKit 0.11 keeps a `Progress` whose unit is audio samples (`TranscribeTask.swift:101`, `:254`) and resets it per call (`WhisperKit.swift:933`); ScrumTrace ignores it. | `WhisperTranscriber.swift:159`, `LoadedModel` |
| Slices / provider calls | Slicing persists its inventory once after the loop; evaluation persists after every slice. No count reaches the UI. A clip-export error is swallowed (the slice keeps its stills); a provider error becomes an `offline_failed` slice. | `SessionProcessor.swift:257–289`, `:390–415`, `:1214–1237`, `:1455–1471` |
| Stopping a run | Impossible. Retry and the launch resume run `runProcessor` in an unstructured `Task` nobody holds, and Stop awaits it inside its own task. Even with a handle, cancellation would not return: `WhisperTranscriber.prepare` awaits the detached load's `.value` (`:82`, `:88`), and `waitForPrepare`'s task group has a child doing the same, so the group's teardown waits for the whole load. The only exit is Quit, which the menu confirms with "Quitting stops it", and the next launch resumes the same recording again. | `SessionController.swift:387`, `:984`, `WhisperTranscriber.swift:82–88`, `SessionProcessor.swift:1106–1125`, `MenuBarController.swift:644–665` |
| Failure | `lastError`, `phase = .offlineFailed`, status line = the error; Retry lives in the menu, Recordings and Overview's Needs attention. | `SessionController.swift:1174–1180` |
| Agent log | `pipeline_status` carries the status enum and the sanitized line; `whisper_prepare_*`, `whisper_file_*`, `slice_done`, `eval_done`, `zip_ok` exist. No per-stage elapsed, no "resuming", no deferral event. | `SessionController.swift:1156`, `AGENT_DEBUG.md:30` |
| Stage timing on disk | `archive/pipeline-timing.json` holds `whisper_wall_seconds` (model load **plus** transcription), zip bytes, omitted count. No per-stage seconds, no model-load seconds. | `SessionModels.swift:2850–2915` |

So: a ten-minute wait with a static label, no way to see what or whose recording is being processed,
no way to get Start back without quitting, and the next launch repeats the wait.

`mac_gate01.sh:20–43` refuses to replace a running app while the newest manifest is mid-pipeline; it reads the
manifest, not the log, so it cannot tell a deferred run from an active one (§1.5 step 6).

---

## 1. Design

### 1.1 One status, two surfaces

`SessionController` publishes one value, `processing: ProcessingStatus?`, set by `runProcessor` and
nothing else. Two views render it and never derive anything from `statusLine` parsing:

1. **Main window:** `ProcessingPanelView` (SwiftUI) directly under `MainLiveBanner` in the detail
   column of `MainWindowView`, above every section. It is a view inside the window, so it can never
   open or front the window (AGENTS.md: processing and timers never do). It appears when
   `controller.processing` is set and goes away when it is cleared.
2. **HUD:** `ProcessingPanelWindow` (AppKit `NSPanel`, same flags as `RecordingHUDWindow`:
   `[.borderless, .nonactivatingPanel]`, `canBecomeKey/Main = false`, `sharingType = .none`, level
   `.statusBar`, `collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]`,
   `isFloatingPanel = true`, `hidesOnDeactivate = false`, `becomesKeyOnlyIfNeeded = false`, every control
   `refusesFirstResponder` and `acceptsFirstMouse`, no `NSHostingView`, no `import SwiftUI`, no
   `NSApp.activate`, no `makeKey`). `MenuBarController.sync()` shows it while
   `controller.processingPanelShouldShow` and hides the pill only for an **active** pipeline run:
   `hudShouldShow` becomes `(isRecording || startInFlight || (isBusy && processing?.isRunning != true)) &&
   !suppressHUD`, so transfers, speaker updates and Codex archive copies keep today's pill, and a run shows
   the panel instead. A finished, failed or deferred status stays on screen until Close, auto-clear or the
   next run, but is hidden while another busy operation runs (`processingPanelShouldShow = processing != nil
   && !(isBusy && processing?.isRunning == false) && !suppressHUD`). Frame remembered in
   `scrumtrace.processing.frame`; default top-right of the main display's visible frame, 18 pt inset;
   `ProcessingPanelLayout.restoredFrame(saved:size:screens:)` keeps only the "a usable part is still on a
   screen" rule (the HUD's version also forces the pill's aspect ratio, so it is not reused). The menu's
   `sync()` signature includes `canFinishLater` so the *Finish later* item follows the stage.

   The panel's own buttons never activate ScrumTrace. **Retry** starts a normal Retry analysis, and that
   run may show the existing upload-consent alert, which activates ScrumTrace as it does today from the
   menu; the panel adds no activation of its own.

Both show the same `ProcessingPanelState` (pure struct, like `MainLiveBannerState`): title, subtitle,
seven rows, progress, buttons. Tests cover the struct; the views are thin. The HUD panel lists the seven
rows vertically. The main window panel is compact so Settings plus the banner plus the panel still fit the
840×620 minimum (the detail column clips overflow, `MainWindow.swift:260–264`): a header line (title,
total elapsed, buttons), one horizontal strip of the seven stages (mark, title, elapsed), and one detail
line for the active stage (expectation or progress, with a bar when determinate). `MainWindowView` keeps
not observing the controller; only the panel view does, like the banner.

### 1.2 Model (`ScrumTrace/Processing/ProcessingStatus.swift`)

```swift
enum ProcessingStage: String, CaseIterable, Codable, Sendable {
    case resuming, loadingModel = "loading_model", transcribing, slicing, evaluating, packaging, done
    var title: String   // "Resuming last recording", "Loading speech model", "Transcribing", "Slicing",
                        // "Evaluating", "Packaging", "Done"
}
enum ProcessingOrigin: String, Sendable { case stop, launchResume = "launch_resume", retry, localExport = "local_export" }
enum ProcessingProgressValue: Equatable, Sendable {
    case indeterminate
    case audioSeconds(done: Double, total: Double, passes: Int = 1)   // transcription; label says "(2 passes)"
    case count(done: Int, total: Int, unit: String)                   // "clips", "provider calls"
}
struct ProcessingStageRecord: Equatable { let stage; let startedAt: Date; var endedAt: Date?; var skipReason: String?; var progress: ProcessingProgressValue }
enum ProcessingOutcome: Equatable { case running, done(String), incomplete(String), failed(String), deferred }
struct ProcessingStatus: Equatable {
    let runID: UUID                  // ticker, auto-clear and deferral are scoped to it
    let sessionId: String
    let recordedAt: Date?            // manifest.createdAt
    let mediaSeconds: TimeInterval   // manifest.duration.mediaSeconds
    let origin: ProcessingOrigin
    let startedAt: Date
    var now: Date                    // ticked once a second while running; frozen at the end
    var records: [ProcessingStageRecord]   // in the order entered; the last open one is current
    var outcome: ProcessingOutcome
    var history: ProcessingTimingHistory   // §1.4, filled in when the off-main read finishes
    var canFinishLater: Bool         // running and not yet packaging
}
```

The resuming row's title follows the origin: "Resuming last recording" (launch resume), "Retrying
analysis" (menu, Recordings, Overview or panel Retry), "Saving recording" (Stop), "Regenerating local
export" (Analyze locally). The stage enum value in the log is always `resuming`.

Title: "Processing the recording from 22 Sep 2026, 12:55 · 0:23 recorded" (`SessionSummary.formattedDate`,
`SessionController.clock`). Subtitle for a launch resume: "This recording never finished. ScrumTrace picked
it up when it opened." For a retry: "Retry analysis." For Stop: nothing. The session id is shown in the
HUD panel's tooltip only. No product name, context name, title, note or transcript text anywhere in the
panel (the panel reads metadata the Recordings index already shows, nothing more).

Row states: pending (dimmed), active (accent dot pulsing, elapsed ticking, expectation line, progress bar
when the value is not indeterminate), done (check, final elapsed), skipped (dash, reason: "Already loaded",
"Already done", "Local export only", "Upload not approved", "Transcription incomplete", "No clips"), failed
(red mark, reason). Skip reasons are a closed set of technical values (`ProcessingStageRecord.skipText`
maps them to words); nothing else is ever logged as `reason`. Done row: "Session pack ready" or the
processor's final line.

Outcome after `processor_ok` follows the returned manifest, not the event: `pipelineStatus == .completed`
is `.done(line)`; `.transcribing` (the incomplete handoff, `SessionProcessor.swift:433–445`) and
`.offlineFailed` (`:713–727`) are `.incomplete(line)`, which keeps **Retry** and never auto-clears.
`processor_fail` is `.failed(reason)`.

Buttons: **Finish later** while `canFinishLater` (running and not yet packaging); **Retry** for `.failed`
and `.incomplete`; **Close** for every ended outcome. The HUD panel's buttons are `HUDTextButton`-style
(`refusesFirstResponder`, `acceptsFirstMouse`), so a click does not activate ScrumTrace (Gate 0; the
Retry qualification in §1.1 applies). A `.done` status clears itself after 8 s
(`ProcessingStatus.doneAutoClearSeconds`) on both surfaces, checked against its `runID`; `.incomplete`,
`.failed` and `.deferred` stay until Close, a new Retry or a new recording.

### 1.3 Events from the processor, state in the controller

`SessionProcessor.process(...)` gains `onEvent: @escaping @MainActor (ProcessingEvent) -> Void = { _ in }`
next to `onStatus`; `onStatus` is unchanged and still feeds `statusLine` and `pipeline_status`.

```swift
enum ProcessingEvent: Equatable, Sendable {
    case stage(ProcessingStage)
    case skipped(ProcessingStage, reason: String)   // short technical reason, logged as `reason`
    case progress(ProcessingProgressValue)
}
```

Emission points (all inside `process`):

- **loadingModel:** `transcribe` sends `.stage(.loadingModel)` when `!transcriber.isReady(for:)` and
  calls `waitForPrepare`, else `.skipped(.loadingModel, reason: "already_loaded")`. When the controller
  loads a saved local speech profile before `process` (`prepareLocalTranscriptionIfNeeded`,
  `SessionController.swift:1138`), the controller enters the same stage itself around that await.
  A transcription that is already complete on disk sends `.skipped(.loadingModel, "already_done")` and
  `.skipped(.transcribing, "already_done")`; local-only runs send `.skipped(.transcribing, "local_only")`.
- **transcribing:** `.stage(.transcribing)` after the load; `.progress(.audioSeconds(done:total:passes:))`
  from `WhisperTranscriber.transcribeFile(at:sessionURL:onProgress:)`. The transcriber reads the private
  temp copy's duration (`AVURLAsset.load(.duration)`), reports `0` of it before the decode, polls
  `LoadedModel.fraction()` (new closure over `WhisperKit.progress.fractionCompleted`, a thread-safe
  `Progress` read; the `progress` property itself is replaced per call, `WhisperKit.swift:933`, `:941`, so the
  poller reads it through the kit each time) every 500 ms, ignores readings that equal the pre-call value
  or are ≥ 1 (a short decode can finish and reset between polls; an error leaves a stale figure,
  `WhisperKit.swift:931–941`), and reports the full duration after the decode returns. Progress advances
  per decoded 30-second window (`TranscribeTask.swift:254`), so the bar steps rather than glides; the panel
  says "of audio". The processor computes the total from the inputs it will decode (WAV duration plus movie
  duration when the layout selects both, `SessionProcessor.swift:1013–1054`), passes an offset for the
  second pass, labels a dual-pass total "(2 passes)", and forwards the sink through `transcribeMovieAudio`'s
  extraction and its movie-copy fallback (extraction itself stays indeterminate). A silent, missing or failed
  pass contributes its duration as done. Diarization keeps the transcribing row active with the existing
  status line.
- **slicing:** `.stage(.slicing)` then `.progress(.count(done: i, total: slices.count, unit: "clips"))`
  after each exported slice; `.skipped(.slicing, reason: "no_anchors")` when the stage does not run and
  `"already_done"` when a retry finds it complete.
- **evaluating:** `.stage(.evaluating)` + `.progress(.count(done:total:unit: "provider calls"))` after
  each `evaluateSlice` in the single-provider and comparison loops (comparison total = services × slices);
  the local-only, no-consent, retired-model, missing-key, incomplete-transcription and already-complete
  branches send `.skipped(.evaluating, reason: "local_only" | "consent" | "model_refused" | "key_missing" |
  "transcription_incomplete" | "already_done")`.
- **packaging:** `.stage(.packaging)` before `finishExport` and before `writeIncompleteHandoff`.
- **done:** the controller derives it from the returned manifest (§1.2).

`SessionController` keeps the status: `beginProcessing(sessionId:origin:manifest:)` at the top of
`runProcessor` (after the missing-session check), `apply(_ event:)`, `finishProcessing(_ outcome:)`. A one-second
`Task` ticks `processing.now` while running and stops when its `runID` is no longer current (it is the only
timer; the recording timer is not reused). Every stage transition logs `processing_stage` with `session`,
`stage`, `prev` and `prev_seconds` (integer); the first one also carries `origin`. Skips log
`processing_skip` with `session`, `stage`, `reason`. The end logs nothing new on success (`processor_ok`
already) and `processor_deferred` on a deferral (§1.5). The event-specific keys (`stage`, `prev`,
`prev_seconds`, `origin`, `reason`, `elapsed`) pass both forbidden-key filters (`AgentLog.swift:295–306`,
`inspect_agent_log_privacy.py:62–74`); values are enums, ids and integers, never a title, note, transcript
or path. The common diagnostic fields (`run_id`, `cdhash`, …) are added by `AgentLog` as on every row; the
tests assert the event-specific extras only. `scripts/local_export_replay.py:188` learns
`processor_deferred` as a run end.

Per-stage seconds also go to `archive/pipeline-timing.json`: `PipelineTiming.stageSeconds: [String: Double]`
(`stage_seconds`, optional, old files decode) written by the processor at its existing write points (after
transcription, after the zip, in the incomplete handoff) plus `whisper_load_seconds` for the model load.
Archive-only; the zip allow-list is untouched (`test_pipeline_timing_stays_in_archive` keeps passing).

### 1.4 Expectations: measured first, plain words second

`ProcessingTimingHistory` is read once per run, off the main actor (`Task.detached`), and merged into the
status when it arrives; until then the rows use the plain-language fallback:

- **Model loads:** `ProcessingTimingHistory.recordModelLoad(seconds:)` appends to `UserDefaults`
  `scrumtrace.processing.modelLoadSeconds` (last 12 values), called from `WhisperTranscriber.prepare` through an
  injectable sink on every `whisper_prepare_ok reuse=0` that this process **started** (the `.start` branch; a
  caller that only waited on another caller's load measures nothing), so the load at recording start counts
  too. Zero, negative and non-finite values are dropped.
- **Stages:** `stage_seconds` and `whisper_load_seconds` from the `pipeline-timing.json` of the newest 20
  session folders by id (ids are date-stamped, so no manifest is decoded to sort; `recentSessions` would
  decode every manifest, `SessionVault.swift:244–249`). Sessions with an `importOrigin` are skipped: their
  timing describes another Mac. Media seconds come from the same manifests for the transcription rate.

`ProcessingExpectation.line(stage:history:mediaSeconds:elapsed:)` is pure:

- loadingModel, with history: "On this Mac a slow load took 9 min 52 s to 11 min 27 s and a fast one about
  5 s (9 loads). The first load after a restart is usually the slow kind." (slow = loads of 60 s or more;
  fast = the rest; whichever set is empty is left out; the count is the sample size). Without history: "The
  first load after a restart usually takes 5 to 11 minutes on this Mac; later loads take a few seconds."
  Past 12 min: "Longer than the 12-minute wait. The run will go on without a transcript, the model keeps
  loading, and Retry analysis can finish the recording." (that is what `waitForPrepare`'s timeout does today;
  nothing stops the detached load).
- transcribing, with history: "About 5 s for this 00:23 recording, judging by 3 earlier recordings." (median
  audio-seconds-per-wall-second from `stage_seconds.transcribing` and media seconds; rates vary with model,
  pass count and diarization, which the wording leaves as an estimate). Without: "Usually under a minute for a
  short recording, and about as long as the recording for a long one."
- slicing: "Usually a few seconds per clip." evaluating: "One call per clip; each usually takes 10 to 60 seconds."
  packaging: "Usually under a minute." With history these use the median of `stage_seconds` and name the count.

### 1.5 Finish later, and what it does to a half-loaded model

**Task ownership.** `runProcessor` keeps its signature for its four callers (Stop awaits it inside
`stopRecordingAsync`, `SessionController.swift:984`; Retry, the launch resume and the local export start it in a
`Task`, `:387`). Inside, everything from the speech-profile prepare to `process` runs in one inner
`Task { @MainActor in … }` that the controller holds as `processingTask`, awaited by `runProcessor`. Cancelling
that inner task is the deferral; the caller's own task keeps running and finishes its cleanup as today
(`clearSessionContext` in the `defer`, `:1042–1044`; Stop's `recorder = nil`, `captureFreeze.attach(nil)` and
`AgentLog.setRecording(false, …)`, `:994–996`). `isBusy` goes false only after the inner task has unwound, so no
pipeline operation can still write.

`finishLater()`:

1. Guards `processing?.canFinishLater == true` (running and not yet packaging); logs `processing_defer` with
   `session`, `stage`, `elapsed`.
2. Cancels `processingTask`. Cancellation reaches every wait and is checked before every write:
   - **Model load.** `WhisperTranscriber.prepare` awaits the detached load through a cancellation-aware
     waiter (`CancellableAwait.value(of:)`: a checked continuation resumed once, by the task's result or by
     `withTaskCancellationHandler`'s `onCancel`), so a cancelled caller gets `CancellationError` at once while
     the load keeps running. `waitForPrepare` runs `transcriber.prepare` as a **structured** child of its task
     group instead of awaiting an unstructured `prepareTask`, so cancelling the group releases it; the 12-minute
     timeout child is unchanged. The controller's `prepareLocalTranscriptionIfNeeded` route goes through the same
     `prepare`, so it is released too. `prepare`'s `.wait` branch rethrows `CancellationError` instead of
     swallowing it as "another model was loading" (and compares cache keys, not a cache key with a bare model
     name, `WhisperTranscriber.swift:83`, an existing mismatch).
   - **Transcription.** `transcribe` becomes `async throws` for cancellation only: a `CancellationError` from
     any pass is rethrown, not folded into `requiredFailed`, so a successful first pass followed by a cancelled
     second one never becomes a persistable partial transcript (`SessionProcessor.swift:147–188`).
     `transcribeMovieAudio` rethrows cancellation instead of starting the movie-copy fallback
     (`WhisperTranscriber.swift:267–280`); AAC extraction's export session is not cancellable and simply
     finishes (seconds). `process` calls `try Task.checkCancellation()` right after `transcribe` returns and
     right after diarization returns (`:191–196`), before any transcript, timing or manifest write: WhisperKit
     checks cancellation per window but not after the last one (`TranscribeTask.swift:130–159`, `:254–259`), so
     a decode can return "ok" after the request. The transcriber logs a cancelled decode as `whisper_file_fail`
     with `error=cancelled`.
   - **Slicing.** Checked before the stage and before each `exporter.export`; the clip-export `catch` rethrows
     `CancellationError` instead of keeping the slice without its clip (`:273–293`), so slicing is never marked
     complete with a clip missing because of a deferral. `ClipExporter`'s own continuation waits finish their
     current export (seconds).
   - **Evaluation.** Checked before the stage and, in both loops, **after** `evaluateSlice` returns and before
     its result is persisted (`:402–428`, `:1230–1244`): a cancelled provider call leaves the slice `pending`
     instead of writing an `offline_failed` result, and `evaluating` is not marked complete. A successful call
     that completed before the request is persisted as usual.
   - **Packaging.** Checked once before `finishExport` / `writeIncompleteHandoff`. From then on
     `canFinishLater` is false, the button and menu item disappear, and a request that arrived between the
     last check and the stage start lets the run finish normally with its real outcome.
3. `runProcessor`'s catch sees `CancellationError`: `phase` = the manifest's status on disk (still
   `transcribing`, `slicing` …), `statusLine` = "Finish later — Retry analysis finishes this recording",
   `lastError` untouched, `AgentLog processor_deferred {session, stage}`, `isBusy = false`, outcome `.deferred`.
   The manifest keeps `pipeline_status` as it was written by the stage that ran; `completed_stages` keeps what
   finished. Recordings lists it as unfinished with *Retry analysis*; the menu's *Retry analysis* and Recent
   row work; `lastSessionId` still names it; Overview's Needs attention lists it again because the controller no
   longer holds it. Start recording is enabled (`canChangeCaptureSettings` is true again).
4. **The speech model.** A load in flight is a `Task.detached` inside `WhisperTranscriber`; CoreML compilation
   cannot be interrupted part-way, and cancelling the task would throw away whatever the ten minutes have
   built. So `finishLater` stops *waiting* and leaves the load running: `preparing` stays set, and the next
   `prepare` call for the **same model and source** (Start recording's detached prepare, or the next Retry)
   `.wait`s on the same load (`WhisperTranscriber.swift:82`); a different model or source waits for it and
   then loads its own, as today. If it had already finished, it is simply ready. The panel's deferred state
   says so: "The speech model keeps loading in the background; Retry analysis or your next recording will use
   it." `interruptedSessionId` is not set again; the next launch resumes the newest unfinished recording as
   today (`:121–130`), which may be this one.
5. Nothing is deleted or rewritten by a deferral: no manifest write, no export write, no transcript write.
6. `scripts/mac_gate01.sh` keeps refusing to replace a running app whose newest manifest is mid-pipeline. It
   additionally reads the last `processor_*` row for that session in `agent.jsonl`: `processor_deferred` (or
   `processor_ok`/`processor_fail`) means no pipeline is writing, so the install goes ahead; a trailing
   `processor_begin` still blocks. The AGENTS.md rule stays as written.

Finish later is a panel button and a status-bar menu item (*Finish later*, enabled while `canFinishLater`),
because the HUD panel can be closed with the main window shut.

### 1.6 Retry and failure

On `processor_fail` the status keeps its rows (the failed one stays marked with a red mark and its elapsed),
`outcome = .failed(reason)` with `error.localizedDescription` as today's `lastError`, and the panel shows
**Retry** → `retryAnalysis(sessionId:)` (same checks, logs `panel_retry` then the usual `retry_begin`). A
`processor_ok` whose manifest is not `.completed` is `.incomplete(line)` with the same **Retry** (§1.2). A new
run replaces the status. Nothing in `SessionProcessor`'s failure handling changes.

### 1.7 Out of scope (deliberately)

- Cancelling the CoreML compile itself, or evicting a loaded model.
- A progress figure for the model load (CoreML gives none; the timer and the measured range stand in).
- Re-ordering or shortening the pipeline; changing what any stage writes.
- A notification when processing ends; the Dock; the menu-bar icon (it already turns into a gear).
- Pausing a run (Finish later is a stop with a clean resume, not a pause).

---

## 2. Tasks

Each task updates `scripts/test_contracts.py` for the strings and patterns it changes, in the same commit,
so the Linux suite stays green after every task.

### P01 — Status model, stages, expectations, timing history

**Files:** new `ScrumTrace/Processing/ProcessingStatus.swift`, `ScrumTrace/Storage/SessionModels.swift`
(`PipelineTiming.stageSeconds`, `whisperLoadSeconds`), new `ScrumTraceTests/ProcessingStatusTests.swift`.

**Implementation:** §1.2, §1.4. `ProcessingPanelState.make(status:)` turns a status into rows, labels and
button visibility. `ProcessingTimingHistory` with injectable defaults and a `[PipelineTiming]` + media seconds
input. `ProcessingExpectation` pure. `PipelineTiming` decodes files without the new keys.

**Tests:** stage order and titles; entering a stage closes the previous record; elapsed per row from `now`;
skipped rows; outcomes and buttons; the title and subtitle for each origin; `doneAutoClearSeconds`; expectation
lines with and without history, cold/warm split, median rate, the 12-minute line; history trimming to 12 loads;
`PipelineTiming` round-trip with and without `stage_seconds`.

**Done when:** native tests pass; Linux contracts pass.

**Commit:** `feat: processing status model with stages, elapsed and expectations`

### P02 — Processor emits stage events and real progress

**Files:** `ScrumTrace/Processing/SessionProcessor.swift`, `ScrumTrace/Speech/WhisperTranscriber.swift`,
`scripts/test_contracts.py`, `ScrumTraceTests/LocalProcedureTests.swift` (fixture run).

**Implementation:** §1.3 emission points; `LoadedModel.fraction` closure (an explicit `init(transcribe:fraction:)`
with a default so the test fakes' trailing-closure form still means `transcribe`);
`transcribeFile(at:sessionURL:onProgress:)` and `transcribeMovieAudio(at:sessionURL:onProgress:)` with a default
nil; `CancellableAwait` and the cancellation-aware `prepare` (§1.5); the model-load sink; `stage_seconds` and
`whisper_load_seconds` written at the existing timing write points; `Task.checkCancellation()` at the §1.5
boundaries; `transcribe` rethrows cancellation; the clip-export and movie-fallback catches rethrow it. Keep every
existing `onStatus` line and AgentLog event.

**Tests:** a fixture session with a fake transcriber that returns segments runs `process` with `onEvent` and
yields `[.skipped(.loadingModel) | .stage(.loadingModel), .stage(.transcribing), .progress(.audioSeconds …),
.stage(.slicing), .progress(.count … "clips"), .skipped(.evaluating, "consent"), .stage(.packaging)]` in that order;
`pipeline-timing.json` carries `stage_seconds` for the stages that ran; `prepare` returns `CancellationError`
within a second when its caller is cancelled while the fake load stays blocked, the load still completes, and a
second `prepare` reuses it with one `whisper_prepare_begin`; a `process` cancelled during the second pass throws
`CancellationError` and leaves the manifest at `transcribing` with the transcript on disk byte-identical.
Contracts: the exact strings that change are updated in the same commit: `test_contracts.py:991`
`"transcribeFile(at url: URL, sessionURL: URL? = nil)"` → `"transcribeFile(at url: URL, sessionURL: URL? = nil,
onProgress:"`, `:992` `transcribeMovieAudio(at movie: URL, sessionURL: URL)` → with `, onProgress:`, `:1009`
`"transcribeFile(at: movieCopy)"` → `"transcribeFile(at: movieCopy, onProgress: onProgress)"`, `:2137`
`"transcribeFile(at: wav, sessionURL: sessionURL)"` → with `, onProgress:`, `:2138` likewise for the movie. New
checks: `onEvent` in the `process` signature; `checkCancellation` before `slicer.slice(`, `exporter.export(`,
after `evaluateSlice(` and before `finishExport(`; `fraction` in `LoadedModel`; `stage_seconds` in models;
`pipeline-timing.json` still absent from the zipper; `CancellationError` rethrown in the clip-export catch.

**Done when:** the fixture run reports progress; Linux contracts pass.

**Commit:** `feat: pipeline reports stages, audio seconds, clips and provider calls`

### P03 — Controller owns the status, Finish later, deferral and the log

**Files:** `ScrumTrace/Processing/SessionController.swift`, `scripts/local_export_replay.py`,
`scripts/test_contracts.py`, `ScrumTraceTests/InterruptedSessionTests.swift` (new cases).

**Implementation:** `@Published private(set) var processing: ProcessingStatus?`, `processingTask` (the inner
task, §1.5), `beginProcessing`/`apply`/`finishProcessing`, the ticker scoped to `runID`, `finishLater()`,
`canFinishLater`, `dismissProcessing()`, `processingPanelShouldShow`, the `hudShouldShow` change (§1.1), the
`CancellationError` branch in `runProcessor` (§1.5 step 3), the outcome derived from the returned manifest
(§1.2), the off-main history read (§1.4), `resumeInterruptedSession` passes `.launchResume`, `retryAnalysis`
passes `.retry`, Stop passes `.stop`, `regenerateLocalExport` passes `.localExport` (a new `origin:` parameter
of `runProcessor`, so the pinned call `"await runProcessor(sessionId: sessionId, retry: retry)"` at
`test_contracts.py:3742` becomes `"await runProcessor(sessionId: sessionId, origin: origin, retry: retry)"` in the
same commit; the launch resume passes `.launchResume` through a private `retryAnalysis(sessionId:origin:)`). Log events `processing_stage`, `processing_skip`, `processing_defer`, `processor_deferred`,
`panel_retry`, `panel_close`. `setProcessingForTesting(_:)` for view and snapshot tests.
`scripts/mac_gate01.sh` reads the last `processor_*` row (§1.5 step 6).

**Tests:** (a) a launch resume against a transcriber whose `loadModel` blocks on a continuation: the status names
the session, `recordedAt`, origin `.launchResume`, rows `resuming` done and `loadingModel` active within 5 s;
`finishLater()` ends the run within 5 s, `isBusy` false, `canChangeCaptureSettings` true, outcome `.deferred`,
manifest on disk still `transcribing`, `full_transcript.json` untouched, log has `processing_defer` and
`processor_deferred` and no `processor_fail`; releasing the continuation makes `transcriber.isReady` true without
a new load (`whisper_prepare_begin` logged once); `retryAnalysis` then runs to `processor_ok` with
`loadingModel` skipped. (b) A run whose processor throws ends `.failed(reason)` with `lastError` equal and the
rows kept; a `processor_ok` whose manifest is `transcribing` ends `.incomplete` with Retry. (c) `hudShouldShow`
false during a pipeline run, true during a transfer; the panel hides while a transfer runs over a terminal status.
(d) The `.done` status clears after `doneAutoClearSeconds` (injected 0.1 s) and an `.incomplete` one does not.
(e) `processing_stage` rows' event-specific keys are exactly `session`, `stage`, `prev`, `prev_seconds` and, on the
first, `origin`; a skip reason is one of the closed set. Contracts: the events named in
`test_agent_log_covers_debug_events`; `processing?.isRunning != true` inside `hudShouldShow`; `is CancellationError`
inside `runProcessor`; `processingTask?.cancel()` inside `finishLater`; `processor_deferred` in
`local_export_replay.py` and `mac_gate01.sh`; the §1.5 `runProcessor` string.

**Done when:** Finish later returns Start within seconds on the Mac while the model keeps loading, and the next
Retry does not load it again.

**Commit:** `feat: Finish later defers a run and the agent log names every stage`

### P04 — Main window panel

**Files:** new `ScrumTrace/UI/ProcessingPanelView.swift`, `ScrumTrace/UI/MainWindow.swift`,
`ScrumTraceTests/MainWindowTests.swift`, `ScrumTraceTests/MainWindowSnapshotTests.swift`, `scripts/test_contracts.py`.

**Implementation:** `ProcessingPanelView(controller:)` observes the controller and renders `ProcessingPanelState`
in the compact form of §1.1: a header line (title, subtitle, total elapsed, buttons trailing), a horizontal strip
of the seven stages (9 pt dot pulsing while active with a plain opacity animation, title, elapsed in monospaced
digits), and one detail line for the active stage with `ProgressView(value:)` when determinate. Placed under
`MainLiveBanner` in `MainWindowView`; `MainWindowView` still does not observe the controller. Accessibility
identifiers `main.processing.*`. Never calls `NSApp.activate`, `makeKey` or the presenter.

**Tests:** `MainWindowTests`: the panel is present in the hosting view only while `processing` is set; Finish later
calls `finishLater` and logs; Retry calls `retryAnalysis`; the window keeps its size while rows change and at the
840×620 minimum the Settings section's tab strip and the banner stay visible with the panel shown (same pattern as
`testWindowStaysStableWhileSectionsAndTheBannerChange`). `MainWindowSnapshotTests`: an `overview-processing`
variant with a loading-model status and a failed status, light and dark. Contracts: `ProcessingPanelView` under
`MainLiveBanner` in `MainWindowView`; no self-activation added (the activation-site set in
`test_main_window_docs_match_the_build` is unchanged).

**Done when:** opening the window during a resume shows the panel with the 22 September recording named.

**Commit:** `feat: processing panel in the main window`

### P05 — HUD panel

**Files:** new `ScrumTrace/UI/ProcessingPanelWindow.swift`, `ScrumTrace/UI/MenuBarController.swift`,
`ScrumTrace/App/AppDelegate.swift`, new `ScrumTraceTests/ProcessingPanelTests.swift`, `scripts/test_contracts.py`.

**Implementation:** §1.1 item 2. Built from `NSStackView`s and the HUD's label/button classes (moved to a shared
`HUDControls.swift` only if they must be reused; otherwise private copies, to keep the HUD contracts' file-local
strings intact). `setVisible(_:)`, `refresh()` from the controller's `objectWillChange` like the HUD. A frame
memory key of its own. `MenuBarController` creates it next to the HUD, syncs it every 0.5 s, and adds *Finish
later* to the menu while `canFinishLater`. `AppDelegate` passes it in like the HUD.

**Tests:** panel flags (`nonactivatingPanel`, `canBecomeKey` false, `canBecomeMain` false, `sharingType .none`,
`hidesOnDeactivate` false, `isFloatingPanel`, `.canJoinAllSpaces`, `.fullScreenAuxiliary`, `.stationary`,
`becomesKeyOnlyIfNeeded` false, every button `refusesFirstResponder` and `acceptsFirstMouse`, as
`RecordingHUDTests.swift:96–109` checks for the pill); visible only while `processingPanelShouldShow`; the rows and
buttons follow the status;
a PNG of the panel in the loading, failed and deferred states when `SCRUMTRACE_SNAPSHOT_DIR` is set (same pattern
as the HUD mute snapshot). Contracts: the HUD-style forbidden strings for the new file (`NSApp.activate`, `makeKey`,
`NSHostingView`, `import SwiftUI`, `buttonStyle`), the required ones (`nonactivatingPanel`, `canBecomeKey: Bool
{ false }`, `sharingType = .none`, `refusesFirstResponder`); `processingPanel?.setVisible(` in the menu's `sync()`.

**Done when:** during a resume with the main window closed, the panel floats over Keynote without taking focus,
and *Finish later* on it gives Start back.

**Commit:** `feat: floating processing panel next to the HUD`

### P06 — Docs and status

**Files:** `AGENTS.md`, `AGENT_DEBUG.md`, `README.md`, this file's status line.

**Implementation:** AGENTS.md: the events line adds the `processing_*` / `processor_deferred` / `panel_*` names;
the "Hotkeys, the HUD, …" paragraph names the processing panel among the things that never open or front the
window; line 144's "HUD: Loading Whisper model… then Transcribing" describes the panel; *Honest status* records this
as a user-approved processing-visibility change with the Mac checks still open (§3) and the native-suite baseline
on this host; snapshot date moves. AGENT_DEBUG.md's Pipeline bullet gains the stage events and the deferral
semantics. README's HUD paragraph gains the panel and Finish later. C1–C5 and the archive/export/consent
contract are not edited.

**Done when:** `python3 scripts/test_contracts.py` and `bash scripts/mac_xcode_test.sh` pass on the full branch
(baseline failures excepted, see §3).

**Commit:** `docs: processing panel status and notes`

### P07 — Optional: Overview row for the run in progress

Overview's Needs attention deliberately omits the held session. With the panel above every section it would be
listed twice; leave it. If the user wants the panel collapsible, a disclosure in P04 is the place.

---

## 3. Verify (Mac; not gate evidence)

1. Check the newest manifest and `~/Library/Logs/ScrumTrace/agent.jsonl` show no `processor_begin` without its
   `processor_ok`/`processor_fail`/`processor_deferred`; only then `bash scripts/mac_gate01.sh` and open
   `~/Applications/ScrumTrace.app`. A deferred recording leaves the newest manifest at `transcribing`; the script
   accepts that only when the log's last `processor_*` row for it is `processor_deferred` (§1.5 step 6).
2. With an unfinished recording as the newest (`pipeline_status: transcribing`): launch. The HUD panel appears
   within a second, names the recording's date and length, shows *Resuming last recording* done and *Loading speech
   model* active with a ticking timer and the measured range. Open the main window: the same panel sits above
   Overview; the window did not open by itself.
3. Click **Finish later** on the HUD panel while the model loads. Within a few seconds: Start recording enabled in
   the menu and Overview, the panel shows the deferred state, `processor_deferred` in the log, Recordings lists the
   recording as unfinished with Retry analysis, no file in its folder changed (compare `ls -lT` before and after).
4. Wait for `whisper_prepare_ok` in the log (the load continued), then menu → Retry analysis: the panel shows
   *Loading speech model* skipped ("Already loaded"), *Transcribing* with seconds of audio out of 0:23,
   *Slicing* N of N clips, *Evaluating* skipped or N of N calls, *Packaging*, *Done*, and clears after 8 s.
   `processing_stage` rows in the log name every stage with `prev_seconds`.
5. Record 30 s, Stop: the panel's first row reads *Saving recording*; the rest as in 4. With a subscription
   service selected and consent approved, *Evaluating* counts provider calls.
6. Make a run fail (rename `archive/session.mp4` of an unfinished recording, Retry): the panel shows the failed
   stage, the reason and **Retry**; Retry after restoring the file completes.
7. Keynote full screen, main window closed, launch resume in progress: the panel floats and never takes focus;
   clicking Finish later does not switch out of Keynote (Gate 0 behaviour; record what happens).
8. Quit during a run: the existing confirmation still appears; the next launch resumes.

The seven `MainWindowTests` failures the display-selection paragraph records were four on this host today
(`testARetryWhoseFolderIsDeletedWhileTheUploadConsentAlertIsOpenWritesNothingBack`,
`testDeleteAsksFirstCancelChangesNothingAndConfirmDeletesThenRefreshes`,
`testDeleteWaitsForRecordingAndAnalysisAndRefusesAnUnlistedRowAndALiveRecordingLock`,
`testFileAccessAndDragOfferOnlyRealFoldersInsideTheSession`) on unmodified `develop` at `b3bed2c`, run before any
change (`scripts/mac_xcode_test.sh`, 15 skipped). The final run on the branch passed 486 tests and skipped 9, with
those four plus `testOpeningFromTheAppIconGivesFocusBackToTheAppTheUserCameFrom`, whose `main_open` rows carried a
session id from another test (the same leak the display-selection paragraph records) and which passed when rerun
alone. The 24 new native tests pass; the Linux contract suite passes. Snapshots inspected: `overview-processing`,
`overview-processing-failed`, `settings-minimum-processing` (light and dark) and `processing-panel-{loading,
transcribing, deferred, done, failed}.png`.

---

## 4. Decisions taken

1. **A loading model is left loading on Finish later** (§1.5 step 4). The alternative, cancelling the detached
   task, cannot stop CoreML and would make the next Retry pay the ten minutes again.
2. **Stage events are typed, not parsed from status lines.** The status line keeps feeding `pipeline_status` and
   the menu unchanged.
3. **The HUD pill is hidden during a pipeline run and the panel stands in**; other busy states keep the pill.
4. **Per-stage seconds live in `pipeline-timing.json` and model loads in `UserDefaults`**, because a load at
   recording start belongs to no session folder.
5. **The panel never opens the main window.** A launch resume with the window closed shows the HUD panel only.
6. **Finish later ends at a stage boundary, never mid-write.** Packaging cannot be deferred; everything before it
   is checked after each await and before each write (§1.5).
7. **`processor_ok` is not "Done".** The panel reads the returned manifest; an incomplete transcription or an
   offline-failed evaluation keeps Retry.

---

## 5. Open questions for the user

1. Should the HUD panel also show while a *transfer* or *speaker update* runs (today's pill stays for those)?
   Plan: no.
2. Should the deferred recording's panel stay on screen until closed, or clear after a while like Done? Plan: stay.
3. Should the next launch still resume a recording that was deferred with Finish later? Plan: yes, as today
   (one click defers it again); a "do not resume this one" memory is a separate decision.

---

## 6. Review log

**Revision 1 → 2 (Codex CLI `codex exec`, read-only, 2026-10-13; verdict "revise").** Every finding was checked
against the code before it was applied:

- Blocker: cancelling the run could not escape the model wait. `waitForPrepare` awaited an unstructured
  `prepareTask` from a task-group child, so the group's teardown waited for the whole load, and
  `WhisperTranscriber.prepare` awaited `work.value` with no cancellation path (`:82`, `:88`); the controller's
  speech-profile prepare (`SessionController.swift:1138`) went through the same await. Fixed with a
  cancellation-aware waiter in `prepare` and a structured child in `waitForPrepare` (§1.5 step 2).
- Blocker: a cancelled pass could persist. `transcribe` folded every pass error into `requiredFailed`, so a good
  first pass plus a cancelled second one was a persistable partial transcript, and diarization saved after an
  await. Cancellation now propagates separately and is checked after each await before any write (§1.5).
- Blocker: the clip-export catch kept a slice without its clip and a cancelled provider call became a persisted
  `offline_failed` result, after which the stage could be marked complete. Both catches now rethrow
  cancellation and the evaluation loops check after the call, before persisting (§1.5).
- Blocker: five pinned strings in `scripts/test_contracts.py` (`:991`, `:992`, `:1009`, `:2137`, `:2138`) and the
  `runProcessor` call at `:3742` would break. Listed in P02 and P03 with their replacements.
- `preparationAction` compares a cache key with a bare model name (`:83`): fixed while touching it; "the next
  recording reuses the load" qualified to the same model and source (§1.5 step 4).
- WhisperKit's `progress` is replaced per call and not reset on error: the poller ignores stale and ≥ 1 readings
  and the transcriber reports explicit first and last values; progress steps per decoded window (§1.3).
- Two-pass totals come from the inputs actually selected, the sink is forwarded through extraction and the
  movie-copy fallback, and the label says "(2 passes)" (§1.3).
- `processor_ok` is not Done: the incomplete handoff and offline-failed results return normally. New
  `.incomplete` outcome with Retry; already-complete stages are reported as skipped (§1.2, §1.3).
- Packaging and cleanup made explicit: inner task ownership for all four callers, `canFinishLater` false once
  packaging starts, `isBusy` released only after the inner task unwinds, ticker and auto-clear scoped to a run
  id, relaunch resumes the newest unfinished recording only (§1.5).
- Pill predicate narrowed to an active run; terminal status hidden while another busy operation runs;
  `canFinishLater` added to the menu's sync signature (§1.1).
- Panel flags completed (`canJoinAllSpaces`, `fullScreenAuxiliary`, `stationary`, `isFloatingPanel`,
  `becomesKeyOnlyIfNeeded`); the Retry button's consent alert named as the one activation it can lead to; the
  main window panel made compact for the 840×620 minimum; `restoredFrame` not reused because it forces the
  pill's aspect (§1.1).
- History read moved off the main actor and off `recentSessions` (which decodes every manifest); imported
  sessions skipped; sample counts shown; "slow/fast" instead of asserting a restart cause; the 12-minute line
  describes what the timeout does (§1.4).
- §0 corrected: slicing persists after its loop, Overview's Last recording shows the in-progress analysis,
  `mac_gate01.sh` reads the manifest, not the log (now also the log, §1.5 step 6).
- Agent-log keys confirmed against both filters; skip reasons made a closed set; the row-level assertion applies
  to event-specific extras only (§1.3).

Raw review: the session scratchpad file `codex_review.md`.

---

## 7. Implementation notes (where the build differs from the task text)

- **One commit for P01–P05 plus contracts, one for the plan, one for docs**, as the display-selection branch did:
  the tasks share `SessionController.swift`, `SessionProcessor.swift` and `scripts/test_contracts.py`, and the new
  contract test pins every task's strings at once.
- **P01:** skip reasons are the `ProcessingSkipReason` enum (closed set; an unknown raw value shows no words).
  `ProcessingStatus.enter` also returns whether a transition happened, so a repeated `.stage` is not logged twice.
  `ProcessingStatus.outcome(forReturned:line:)` maps the returned manifest to `.done` / `.incomplete`. Clock text lives
  in `ProcessingClock` (the HUD's `mm:ss` form for elapsed, words for expectations). `ProcessingTimingHistory.load`
  reads the vault; the controller calls it in a detached task.
- **P02:** `transcribe` is `async throws` for cancellation only and returns `modelLoadSeconds` as a third tuple
  element; the already-done skips for the speech stages are emitted from `process`, not `transcribe`, because that is
  where the on-disk transcript is known. Packaging seconds are recorded from `packagingStartedAt`, an instance
  property the processor sets before `finishExport` / `writeIncompleteHandoff`, which both call
  `recordPackagingSeconds` before their `timing.write`. A pass that is silent, missing or fails reports its seconds as
  done when it ends, so the bar reaches the end.
- **P03:** the inner task is `runProcessorBody`; `runProcessor` keeps the missing-session guard and `processor_begin`
  ahead of it, as the contracts pin. The launch resume passes its origin through a private
  `retryAnalysis(sessionId:origin:)`. The ticker, the history read and the Done auto-clear are three tasks scoped to
  the run id. `processingDoneAutoClearSeconds` is the test seam for the auto-clear. The controller's transcriber is
  injectable (`init(settings:vault:transcriber:)`) so the deferral test can hold a fake load open. The menu's *Finish
  later* logs `menu_finish_later`. A `Retry analysis` that the window had deleted the session for (`retry_ignored`)
  clears the status instead of ending it.
- **P04:** the stage strip is a small `Layout` (`ProcessingStageFlow`) that wraps when the window is narrow; the
  detail line comes from `ProcessingPanelView.detailLine`, which the window test checks. The SwiftUI buttons are
  exercised through the view's `close()` / `finishLater()` methods rather than through the accessibility tree.
- **P05:** `isFloatingPanel = true` puts the panel at the floating window level, as it does the pill; the test asserts
  "at least floating", not `.statusBar`. The HUD's label, button and dot classes are private to its file, so the panel
  has its own private copies. Only the panel's origin is remembered; its height always follows the content.
- **P06:** `test_processing_panel_never_loses_a_recording_or_focus()` in `scripts/test_contracts.py`; `mac_gate01.sh`
  reads the log's last `processor_*` row; `local_export_replay.py` treats `processor_deferred` as a run end.
