# ScrumTrace — Main Window Plan (Overview · Recordings · Contexts · Settings)

Status: **implemented on `feature/main-window`** (tasks H01–H07, then layout snapshot renders and review
fixes; proposal written 2026-09-13).
Applies to `develop`. Written after reading the tree at `be436db`
(`feat: save multiple AI services and select one`). Where the build differs from the task text,
§8 *Implementation notes* is authoritative.

Request (2026-09-13): clicking the ScrumTrace icon in Applications should open a real window,
"basically like the Settings screen", that shows the last recordings and the product contexts,
plus whatever else is worth adding around that surface.

This document follows the task format of [FULL_APP_EXECUTION_PLAN.md](FULL_APP_EXECUTION_PLAN.md)
(Files / Implementation / Tests / Verify / Done when / Commit) so a Cursor or Claude Code builder
can pick tasks up one at a time.

---

## 0. What happens today

| User action | Behaviour on `develop` today | Where |
|---|---|---|
| Double-click ScrumTrace in Applications while it is **not running** | The app launches as a menu-bar accessory. Only the status-bar icon appears. On the very first run the permissions window also opens. Nothing else is shown. | `Info.plist` `LSUIElement=true`; `AppDelegate.applicationDidFinishLaunching` calls `NSApp.setActivationPolicy(.accessory)` and `OnboardingWindow.presentIfNeeded()` |
| Click the icon (Finder, Launchpad, Spotlight) while it **is running** | The six-tab **Settings** window opens. | `AppDelegate.applicationShouldHandleReopen` → `showSettingsWindow` |
| Dock tile / ⌘-Tab | Never. Accessory apps have no Dock presence. | activation policy |
| Last recordings | Status-bar menu → **Recent** → one submenu per session (Reveal export/, Open in Claude, Open in ChatGPT, Retry analysis). Twelve sessions, label = session id + pipeline status. | `MenuBarController.rebuild()`; `SessionVault.recentSessions(limit:)` |
| Product contexts | Settings → General → *Product contexts* (a picker plus New / Edit / Duplicate / Delete), and the confirmation sheet before every recording. | `ProductContextsSettingsView`, `RecordingContextView` |
| Unfinished session after a crash | One disabled status line in the menu: “Last session is unfinished — Retry Analysis to finish”. | `SessionController.init` |
| Speaker review | Settings → Speech → *Review and name speakers…* (its own session picker). | `SpeakerReviewView` |

So the gap is exactly the one described: the icon either does nothing visible or opens
preferences, and the session library only exists as nested menus.

---

## 1. Constraints this plan respects

1. **Product-surface deferral.** [AGENTS.md](AGENTS.md) says no new product surface until
   C1–C5 are gated on a Mac. This window is a user-approved exception of the same class as the
   2026-09-12 speaker / Settings / menu work. Task H07 records that exception in AGENTS.md so the
   next agent does not revert it. Nothing in this plan touches capture, pause, clock, Whisper,
   slicing, provider or export code.
2. **C2 archive ≠ export.** Lists and the search index use manifest metadata only: session id,
   date, status, duration, context / product name, counts, export availability and sizes. No
   transcript text, Shot notes, window titles, URLs or provider responses are read into any
   list or index (same rule as TASK D07). Thumbnails, when shown, come from `export/shots/` only.
   `archive/` is revealed only behind an explicit warning.
3. **Gate 0 focus rules.** Nothing here activates the app from a hotkey. `NSApp.activate` is
   called only from the presenter’s `show()` after an explicit user action (icon click, menu
   item, ⌘,). Hotkeys and the HUD (`NSPanel`, `canBecomeKey == false`) are untouched.
4. **TCC.** The window requests Screen Recording only through the existing explicit buttons
   (`CapturePermissions.requestScreenAccess`), never on appear. No rebuild policy changes.
5. **Contract greps.** `scripts/test_contracts.py` pins strings in `AppDelegate.swift`
   (`height: 640`, `SettingsView(settings:`, `settings_open`, `OnboardingWindow.presentIfNeeded`,
   `snapshotLaunchState`, `sweepPrivateTemporaryOrphans`, `AgentLog.eventSync("launch"`,
   `AgentLog.eventSync("terminate"`, `haltCaptureForTermination`,
   `captureFreeze: controller.captureFreeze`, `applicationWillFinishLaunching`,
   `tryExecFromArguments`, `requestTrust(prompt: false)` and **no** `requestTrust(prompt: true)`),
   in `MenuBarController.swift` (`retryRecent`, `openRecentInClaude`, `openRecentInChatGPT`,
   `Relaunch ScrumTrace`, `status.isHidden = false`, the `func quit()` … `func openRecent` order),
   and in `SessionVault.swift` (the order `listedSessionIds` → `recentSessions` → `nextShotIndex`,
   `revealInFinder` → `removeAbandonedSession` → `pruneAbandonedStarts`). Keep them. New vault
   code goes in a **new file** as an extension so those `split()` windows stay intact.
6. **Keep `SettingsView` whole.** The Settings section of the new window hosts the existing
   `SettingsView` (all six tabs, unchanged). `SettingsUsabilityTests` and the SettingsView pins
   stay green without edits.
7. **Deployment target macOS 14.** `NavigationSplitView`, `Table`, `ContentUnavailableView`
   and two-parameter `onChange` are all available. No new packages.

---

## 2. Target experience

One retained window titled **ScrumTrace**, 960×640 by default, minimum 840×620, frame
autosaved. Left sidebar with four sections; the detail pane changes with the selection. When a
recording is live, a banner sits above the detail pane in every section.

```text
┌────────────┬───────────────────────────────────────────────────────┐
│ Overview   │  ● Recording 12:34 t_media · Paused/Live   [Pause] [Stop] │  ← banner only while live
│ Recordings │───────────────────────────────────────────────────────│
│ Contexts   │                                                       │
│ Settings   │   section content                                     │
│            │                                                       │
└────────────┴───────────────────────────────────────────────────────┘
```

### Overview (default section)

- **Ready to record?** card built from what already exists:
  `CapturePermissions.readiness(requireMicrophone:)` (Screen Recording, relaunch-required,
  microphone), Accessibility (optional, `MetadataSampler.requestTrust(prompt: false)`),
  Whisper model state (`controller.transcriber.isReady(for:)`), AI service line
  (`settings.configurationSummary`), meeting notice (`settings.meetingNoticeAccepted`).
  Each row keeps the button it has today (Ask now / Open settings / Relaunch / Preload / Open
  Settings tab). This is the natural home for TASK D01’s preflight snapshot later; until D01
  lands it is a plain composition of the existing calls.
- **Start recording** primary button showing the capture-area summary. Same flow as the menu
  (meeting notice → readiness → context confirmation → capture-area overlay). ⌘N.
- **Needs attention** list: unfinished sessions (Retry analysis), `controller.lastError`,
  retention notice when `retentionDays > 0`, update line only if a check already ran.
- **Last recording** card: date, context, duration, status, the four actions.
- **Storage** line: Recordings folder (home-scrubbed path), recording count, total bytes (computed
  off the main thread, cached), link to Settings → General → Retention.

### Recordings

- **Table** sorted by date descending: Date · Context / product · Duration (t_media) · Status ·
  Shots · Tasks (confirmed / needs review) · Export (zip size or —).
  Search field (session id, date, context name, product name) and filters: status
  (Completed, Needs review, Unfinished, Offline-failed), context.
- **Detail pane** for the selected row:
  header (id, created, wall vs media duration, pauses count);
  stage progress `transcribing → slicing → evaluating → synthesizing → completed` from
  `completedStages`, with `offline_failed` shown as a distinct state;
  consent line (approved / not approved, provider + model when approved, clip audio/video
  flags); omitted-asset count; export files with sizes (`AGENT_CONTEXT.md`, `AGENT_PROMPT.txt`,
  `SESSION_BRIEF.html`, `session-pack.zip`, `OMITTED.md`, `export/full_transcript.json` when
  present); optional thumbnails of `export/shots/*.png`.
- **Actions** (toolbar + context menu + keyboard):
  Reveal export/ (⌘R) · Open in Claude · Open in ChatGPT · Open brief (opens
  `export/SESSION_BRIEF.html` in the default browser) · Retry analysis / Recover ·
  Review speakers… · Copy export path · Reveal archive… (warning sheet) · Delete… (⌫, confirm).
  All session-mutating actions are disabled while `!controller.canChangeCaptureSettings`.
- **Drag out**: the row’s `export/` folder is draggable as a file URL so it can be dropped into
  Cursor, a Claude Code terminal or Finder. Only `export/` is ever offered.
- **Unreadable rows**: a session folder whose manifest fails to decode appears as
  “Unreadable manifest” with Reveal folder and Delete… only (D07 rule 8), never a crash and
  never silently hidden as `recentSessions()` does today.
- **Empty state**: “No recordings yet” with the Start recording button.

### Contexts

- **Table**: Name · Product · Repository · Recordings (count of sessions whose
  `product_context.context_id` equals the profile id) · Last used. Tech stack is shown in the detail
  pane only (§8 H05).
- Toolbar: New… · Edit… · Duplicate… · Delete… · **Record with this context…** ·
  Set as default. The editor is the existing `ProductContextEditor` (made internal).
- Detail: `ProductContextSummary` plus the list of sessions recorded with it.
- Copy stays honest: deleting a context never alters existing recordings; the confirmation
  sheet before Record still appears (it is the C2 “copy the confirmed value” step).

### Settings

The existing `SettingsView` with its six tabs, unchanged. ⌘, and the menu’s
*Settings Window…* / *Agent Log…* open this section with the right tab selected.

### Window behaviour

| Trigger | Result |
|---|---|
| Launch from Finder / Launchpad / Spotlight / Dock | Window opens on Overview. Skipped when launched with `--background` (the LaunchAgent loop) or when the first-run onboarding window is showing on top — it still opens behind it. |
| Launch as a Login Item | Menu bar only. The launch event says `keyAELaunchedAsLogInItem`. |
| Relaunch ScrumTrace | The new instance gets `--background` unless the window was open, and always when this instance had it. |
| Icon click while running (reopen) | Window fronted, section unchanged. No longer opens Settings. |
| Menu bar → **Open ScrumTrace…** | Same as reopen. New item placed directly above *Settings*. |
| ⌘, / *Settings Window…* / *Agent Log…* | Window on Settings, tab selected. |
| ⌘1 … ⌘4 | Sidebar sections. |
| Window visible | `NSApp.setActivationPolicy(.regular)` so ScrumTrace has a Dock tile and appears in ⌘-Tab; back to `.accessory` when the last window closes. Preference *Show ScrumTrace in the Dock while its window is open* (default on). Verify focus hand-back manually — AppKit sometimes leaves no app active after the switch; the presenter re-activates the previously frontmost app via `NSRunningApplication` when that happens. |
| Recording starts | Window never auto-opens. If it is open it shows the live banner and disables session mutations. |
| Quit | Unchanged. |

---

## 3. Architecture

```text
ScrumTrace/
  UI/
    MainWindow.swift          NEW  MainWindowPresenter, MainNavigation, MainSection, MainWindowView (split view + banner)
    OverviewView.swift        NEW  readiness card, start button, attention list, last recording, storage
    RecordingsView.swift      NEW  table, filters, SessionDetailView, actions, drag source
    ContextsView.swift        NEW  contexts table + detail; reuses ProductContextEditor / ProductContextSummary
    SettingsView.swift        unchanged (hosted as the Settings section)
    MenuBarController.swift   + "Open ScrumTrace…" item and openMain closure
    ProductContextViews.swift ContextEditRequest / ProductContextEditor become internal (no logic change)
    SpeakerReviewView.swift   + initialSessionId parameter
  Storage/
    SessionLibrary.swift      NEW  SessionSummary (pure value), SessionEntry, SessionLibrary (ObservableObject),
                                   extension SessionVault { sessionEntries(), deleteSession(id:), exportSizes(id:), archiveByteCount(id:) }
  App/
    AppDelegate.swift         presenter swap, reopen/launch routing, activation policy hooks
    ScrumTraceApp.swift       commands: ⌘N, ⌘,, ⌘1–4
    AppSettings.swift         + showInDockWhileWindowOpen (UserDefaults key)
ScrumTraceTests/
    MainWindowTests.swift     NEW
    SessionLibraryTests.swift NEW
    MainWindowSnapshotTests.swift NEW  layout PNGs for a visual review, added after H07 (§7)
    MenuAccessTests.swift     presenter rename only
scripts/test_contracts.py     + pins for the new routing (see H07)
```

Data flow:

- `SessionLibrary.refresh()` runs `vault.sessionEntries()` on a background task, then publishes
  `[SessionEntry]` on the main actor. It stats each `session.manifest.json` first and reuses
  the cached summary when size + mtime are unchanged, so a refresh over a few hundred sessions
  is a directory listing, not a decode.
- Refresh triggers: window shown, `controller.phase` returning to `.idle` / `.completed`, after
  Delete / Retry / speaker save, and a 5 s timer only while the window is visible.
- `SessionSummary` is a pure `Sendable` struct; everything the table shows is derived from it,
  which keeps it unit-testable without AppKit.
- Sizes (`session-pack.zip`, export files, archive total) are computed on selection, off-main,
  and cached per session id + folder mtime. Never in the table refresh loop.
- `SessionVault` keeps its current file untouched; the new API lives in `SessionLibrary.swift`
  as an extension and reuses `ExportRel` containment helpers and `removeOwnedSessionFolder`
  for deletion (same guards as `removeAbandonedSession`: valid id, usable root, not a symlink).

---

## 4. Tasks

Order: H01 → H02 → H03 → H04 → H05 → H06 → H07. Each is one commit. H02 can start in
parallel with H01 (no shared files).

### TASK H01 — Main window shell and icon-click routing

**Files**

- new `ScrumTrace/UI/MainWindow.swift`
- `ScrumTrace/App/AppDelegate.swift`
- `ScrumTrace/App/ScrumTraceApp.swift`
- `ScrumTrace/UI/MenuBarController.swift`
- `ScrumTraceTests/MenuAccessTests.swift`
- new `ScrumTraceTests/MainWindowTests.swift`

**Implementation**

1. Add `MainSection` (`overview`, `recordings`, `contexts`, `settings`) and `MainNavigation`
   (`@Published section`, `settings = SettingsNavigation()`, `@Published selectedSessionId`).
2. Add `MainWindowPresenter` (replaces `SettingsWindowPresenter`, same shape): one retained
   `NSWindow`, title `ScrumTrace`, `[.titled, .closable, .miniaturizable, .resizable]`,
   `setContentSize(NSSize(width: 960, height: 640))`, `contentMinSize` 840×620 (see §8 H01),
   `isReleasedWhenClosed = false`, frame autosave name `ScrumTraceMain`, `hosting.sizingOptions = []`
   (same macOS 26 hosting workaround as `RecordingContextPresenter`).
   API: `show()`, `show(section:)`, `show(tab:)` (→ `.settings` + tab), `show(sessionId:)`.
   `show()` deminiaturizes, `NSApp.activate(ignoringOtherApps: true)`, `makeKeyAndOrderFront`.
3. `MainWindowView`: `NavigationSplitView` with a `List(selection:)` sidebar and a detail
   `switch navigation.section`. Placeholder `ContentUnavailableView`s for Overview / Recordings /
   Contexts in this task; Settings hosts `SettingsView(settings:controller:navigation:)`.
   Live banner: reads `controller.phase`, `controller.statusLine`, `controller.mediaElapsed`,
   `controller.captureState`; buttons call `controller.togglePause()` / `controller.stopRecording()`
   and log `main_pause` / `main_stop` like the HUD does.
4. `AppDelegate`: replace the presenter property; `applicationShouldHandleReopen` calls
   `mainPresenter.show()`; `showSettingsWindow` keeps the `settings_open` event and calls
   `show(section: .settings)`; `showAgentLogWindow` calls `show(tab: .logs)`. After
   `OnboardingWindow.presentIfNeeded()`, call `mainPresenter.show()` unless
   `CommandLine.arguments.contains("--background")` or the process is an XCTest host.
   Log `main_open` with `["source": "launch" | "reopen" | "menu" | "command"]` (technical only).
5. `ScrumTraceApp.commands`: keep ⌘N and ⌘,; add ⌘1–⌘4 for sections.
6. `MenuBarController`: add `openMain` closure and an **Open ScrumTrace…** item directly above
   *Settings*; log `menu_open_main`.
7. `scripts/mac_agent_loop.sh` line 93: `open "$STABLE"` → `open "$STABLE" --args --background`
   so the log loop does not pop a window every three minutes.

**Tests**

- Reopen shows the main window, not a Settings-only window; a second reopen reuses the same
  `NSWindow` instance.
- `show(tab:)` selects `.settings` and the requested tab; all six `SettingsTab` cases stay in
  the same window (port of `testAllSixSettingsTabsRemainInTheSameWindow`).
- `show(sessionId:)` selects `.recordings` and the id.
- Miniaturized window is deminiaturized by `show()`.
- Menu item *Open ScrumTrace…* exists and is enabled while busy, paused and idle.
- With `--background` in the arguments the launch path does not show the window (unit-test the
  decision function, not `applicationDidFinishLaunching`).

**Verify**

```bash
bash scripts/run_linux_tests.sh
bash scripts/mac_xcode_test.sh
open ~/Applications/ScrumTrace.app          # after a requested rebuild: window on Overview
open ~/Applications/ScrumTrace.app          # second time: reopen fronts the same window
```

**Done when:** the icon opens a ScrumTrace window every time, Settings is a section of it, and
no existing menu, hotkey or HUD behaviour changed.

**Commit:** `feat: open a main window from the app icon`

---

### TASK H02 — Private session index

**Files**

- new `ScrumTrace/Storage/SessionLibrary.swift`
- new `ScrumTraceTests/SessionLibraryTests.swift`

**Implementation**

1. `SessionSummary: Sendable, Identifiable, Hashable` with exactly: `sessionId`, `createdAt`,
   `pipelineStatus`, `completedStages`, `mediaSeconds`, `wallSeconds`, `pauseCount`,
   `contextName`, `productName` (context name when product name is blank, as the brief does),
   `contextID`, `shotCount`, `sliceCount`, `taskCounts` (confirmed / needsReview / dropped),
   `consentApproved`, `omittedCount`, `hasExportContext` (`export/AGENT_CONTEXT.md`),
   `hasBrief`, `hasPack`, `packBytes`, `hasFullTranscriptArchive` (for Review speakers),
   `isUnfinished` (status not `idle`/`completed`). Nothing else. A `SessionSummary.init(manifest:exportProbe:)`
   keeps it a pure mapping.
2. `SessionEntry = .loaded(SessionSummary) | .unreadable(id: String, reason: String)`.
3. `extension SessionVault`:
   - `sessionEntries() -> [SessionEntry]` — reuses the same directory rules as
     `listedSessionIds` (skip symlinks, non-directories, invalid ids); decode failures become
     `.unreadable` with a sanitized reason (`decoding failed`, `not readable`), never the file
     contents.
   - `exportSizes(id:) -> [String: Int]` for the known export names via `ExportRel.existingSessionFile`.
   - `archiveByteCount(id:) -> Int` — enumerator over `archive/` without following symlinks.
   - `deleteSession(id:) throws` — same guards as `removeAbandonedSession`; additionally throws
     `SessionVaultError.writeFailed("session is live")` when `recording.lock` names a live pid
     for that id. `AgentLog` only writes the lock today (`setRecording`); add a small reader next
     to it that parses session id + pid and treats a dead pid as stale, the way
     `mac_agent_loop.sh` does. The caller holds the controller’s active session only while
     recording or analysis runs, and afterwards has the controller forget a session it deleted
     (see the H03 implementation notes).
4. `SessionLibrary: ObservableObject` (`@MainActor`): `@Published entries`, `@Published isLoading`,
   `refresh()` with the stat-cache described in §3, `filtered(search:status:contextID:)` as a
   pure function on `[SessionEntry]`, `totalArchiveBytes` computed lazily.
5. Search matches `sessionId`, the formatted date, `contextName`, `productName` only.

**Tests**

- Fixture vault (`SessionVault(rootURL: tmp)`) with three manifests: completed with export,
  unfinished (`transcribing`, no export), offline-failed; plus one corrupt manifest and one
  planted symlink folder. Entries: 3 loaded + 1 unreadable, symlink ignored.
- Sort is `createdAt` descending; status and context filters; search by id, context, product;
  a search for a word that exists only in a Shot note / task title / `full_transcript.json`
  returns nothing.
- `SessionSummary` has no field that carries free text beyond context and product names (assert
  the `Mirror` labels against an allow-list so future edits cannot add transcript fields silently).
- `deleteSession` refuses invalid ids, symlinked session folders, and a live lock; removes a real
  folder; `entries` no longer contains it after `refresh()`.
- Cache: unchanged mtime + size does not decode again (inject a counting decoder hook).

**Verify**

```bash
bash scripts/mac_xcode_test.sh
bash scripts/run_linux_tests.sh
```

**Done when:** the app can list, search, size and delete sessions without reading any captured
text, and a corrupt manifest is a row, not a crash or a silent omission.

**Commit:** `feat: add a private session index`

---

### TASK H03 — Recordings section

**Files**

- new `ScrumTrace/UI/RecordingsView.swift`
- `ScrumTrace/UI/MainWindow.swift`
- `ScrumTrace/UI/SpeakerReviewView.swift`
- `ScrumTrace/Processing/SessionController.swift` (add a read-only `activeSessionId` returning the private `manifest?.sessionId`)
- `ScrumTraceTests/MainWindowTests.swift`

**Implementation**

1. `RecordingsView`: `Table` bound to `library.filtered(...)`, search field in the toolbar,
   status + context filter menus, selection bound to `navigation.selectedSessionId`.
2. `SessionDetailView` as described in §2: header, stage progress (`PipelineStatusOrder.processingFlow`),
   consent, omitted count, export file list with sizes, optional `export/shots` thumbnails
   (load lazily with `NSImage(contentsOf:)` through `ExportRel.existingSessionFile`, max 8).
3. Actions call existing controller / vault code only:
   `vault.revealInFinder(sessionId:)`, `controller.openInLocalCLI(.claude/.chatGPT, sessionId:)`,
   `NSWorkspace.shared.open(exportBriefURL)`, `controller.retryAnalysis(sessionId:)`,
   `SpeakerReviewView(controller:initialSessionId:)` in a sheet, `NSPasteboard` for the export
   path, `deleteSession` behind a confirmation sheet that names the id and says the archive is
   deleted too. *Reveal archive…* shows a warning sheet first (“This folder holds the full
   recording and transcript. Never hand it to an agent.”), then reveals `archive/` with the
   same symlink checks `revealInFinder` uses.
4. Drag source: `.onDrag { NSItemProvider(object: exportURL as NSURL) }` on the row; only when
   `export/` exists and passes `ExportRel.unfollowedDirectoryURL`.
5. Unreadable rows render with Reveal folder and Delete… only.
6. Every action logs a `main_*` event with `["session": id]` and nothing else.
7. Disabled state: all mutating actions and Delete follow `controller.canChangeCaptureSettings`, so
   the active session is held only while recording or analysis runs. Before and after a delete,
   `controller.forgetSession(id:newestRemaining:)` drops the controller’s references to that session (§8).

**Tests**

- Actions dispatch to the injected closures with the selected id (view-model level, no AppKit).
- Delete requires confirmation; cancel changes nothing; confirm calls `deleteSession` then refresh.
- Busy / recording state disables Retry, Delete, Review speakers, Reveal archive.
- Unreadable entry exposes exactly two actions.
- Thumbnail loader never opens a path outside `export/shots`.

**Verify**

```bash
bash scripts/mac_xcode_test.sh
bash scripts/run_linux_tests.sh
```

Manual: select a completed session, Reveal export/ opens `export/`; drag the row into a Finder
window creates a copy of `export/` only; Open brief opens `SESSION_BRIEF.html` in the browser.

**Done when:** every Recent-menu action is reachable from the window with more context, and
deleting or revealing a session cannot touch anything outside that session folder.

**Commit:** `feat: add the Recordings section`

---

### TASK H04 — Overview section

**Files**

- new `ScrumTrace/UI/OverviewView.swift`
- `ScrumTrace/UI/MainWindow.swift`
- `ScrumTrace/App/AppDelegate.swift` (pass the start closure)
- `ScrumTraceTests/MainWindowTests.swift`

**Implementation**

1. Readiness card rows (status text + existing action) built from a pure
   `OverviewReadiness` value computed from `CaptureReadiness`, microphone status string,
   Accessibility trust, Whisper ready flag, `configurationSummary`, `meetingNoticeAccepted`.
   When TASK D01 lands, `CapturePreflightSnapshot` replaces this value; keep the row layout.
2. **Start recording** calls the same `requestStart()` path as the menu (inject
   `onStartRecording` from `AppDelegate`, which forwards to `menuBar?.requestStart()`).
   Disabled while `!canChangeCaptureSettings` or while the context sheet is up.
3. Needs-attention list: unfinished entries from `SessionLibrary`, `controller.lastError`,
   retention line when `retentionDays > 0`, update result only if `UpdateChecker` already ran
   this launch (no automatic network call from the window).
4. Last recording card reuses `SessionDetailView` actions in compact form.
5. Storage line: `CapturePermissions.scrubHome(vault.rootURL.path)`, count, total archive bytes
   (background, cached), *Reveal recordings folder…*, link to Settings → General.
6. The card copy states plainly what is missing and whether a relaunch is required
   (reuse `CaptureReadiness.userMessage`).

**Tests**

- `OverviewReadiness` for: ready; screen denied; granted-needs-relaunch; microphone disabled in
  Settings (must not show a microphone problem); no AI service (informational, not blocking);
  notice not accepted.
- Unfinished sessions appear in Needs attention with a Retry action; completed ones do not.
- Start button disabled while busy / paused / start in flight.
- No network call happens on appear (inject the update checker and assert zero calls).

**Verify**

```bash
bash scripts/mac_xcode_test.sh
bash scripts/run_linux_tests.sh
```

**Done when:** a first-time user can read the window and know whether Record will work, what to
fix, and what happened to the last recording, without opening a menu.

**Commit:** `feat: add the Overview section`

---

### TASK H05 — Contexts section

**Files**

- new `ScrumTrace/UI/ContextsView.swift`
- `ScrumTrace/UI/ProductContextViews.swift` (visibility only)
- `ScrumTrace/UI/MainWindow.swift`
- `ScrumTraceTests/ProductContextTests.swift` (+ counts / last-used tests)

**Implementation**

1. `Table` over `settings.contextLibrary.profiles` with Recordings and Last used columns computed
   from `SessionLibrary.entries` by `contextID` (pure `ContextUsage.compute(profiles:entries:)`).
2. Toolbar: New… / Edit… / Duplicate… / Delete… reuse the existing `saveProductContext`,
   `deleteProductContext`, duplicate-name logic (move `duplicate()` naming into a small internal
   helper shared with `ProductContextsSettingsView`).
3. **Record with this context…**: `try settings.selectProductContext(id:)` then the same start
   path as Overview. The confirmation sheet still appears with that context preselected — that
   is intentional (C2: the session copies the confirmed value).
4. **Set as default** sets `selectedID` without recording.
5. Detail: `ProductContextSummary` + the sessions recorded with this context (rows link to the
   Recordings section via `navigation.show(sessionId:)`).
6. Same disabled rules as the Settings pane (`canChangeCaptureSettings`, `contextLibraryIssue`).

**Tests**

- Usage counts and last-used dates match fixture manifests; sessions without `context_id`
  count for nobody.
- Deleting a context leaves session manifests untouched (read back the fixture).
- Record-with-context selects the profile before the start closure fires; a missing id throws
  and fires nothing.

**Verify**

```bash
bash scripts/mac_xcode_test.sh
bash scripts/run_linux_tests.sh
```

**Done when:** contexts are a first-class list with usage, and starting a recording for a given
product is two clicks from the window.

**Commit:** `feat: add the Contexts section`

---

### TASK H06 — Dock presence, shortcuts and launch polish

**Files**

- `ScrumTrace/UI/MainWindow.swift`
- `ScrumTrace/App/AppSettings.swift`
- `ScrumTrace/UI/SettingsView.swift` (one toggle in General → About area; keep pinned strings)
- `ScrumTrace/App/AppDelegate.swift`
- `ScrumTraceTests/MainWindowTests.swift`

**Implementation**

1. `AppSettings.showInDockWhileWindowOpen` (key `scrumtrace.showInDock`, default `true`).
2. Presenter: on `show()` with the preference on → `NSApp.setActivationPolicy(.regular)`;
   on `windowWillClose` (last window) → remember the frontmost app, set `.accessory`, and if
   `NSWorkspace.shared.frontmostApplication` is still ScrumTrace afterwards, activate the
   remembered app. Keep the launch-time `.accessory` call in `AppDelegate` as is.
3. Keyboard: ⌘1–⌘4 sections (done in H01), ⌘R reveal export, ⌫ delete (confirm), ⌘F focus
   search, Esc clears search.
4. Sidebar badges: unfinished count on Recordings.
5. First run: keep `OnboardingWindow.presentIfNeeded()`; the main window opens behind it on
   Overview, whose readiness card repeats the same three rows, so closing onboarding lands on a
   useful screen.
6. Window state (section, selection, search) survives close / reopen within a launch.

**Tests**

- Policy is `.regular` while visible and `.accessory` after close when the preference is on;
  stays `.accessory` throughout when it is off.
- Hotkey paths (`HotkeyManager`) contain no reference to the presenter (Linux grep, H07).

**Verify**

```bash
bash scripts/mac_xcode_test.sh
bash scripts/run_linux_tests.sh
```

Manual: Keynote full screen → ⌥⌘S / ⌥⌘↩ / ⌥⌘P must still not bring ScrumTrace forward
(Gate 0 check unchanged); open the window, close it, confirm the previous app regains focus.

**Done when:** the window behaves like a normal Mac app window while open and the app returns
to a quiet menu-bar accessory when it closes.

**Commit:** `feat: show ScrumTrace in the Dock while its window is open`

---

### TASK H07 — Docs, policy note and contract pins

**Files**

- `AGENTS.md`
- `README.md`
- `scripts/test_contracts.py`

**Implementation**

1. AGENTS.md → *Honest status* and *Next work*: record the 2026-09-13 user-approved exception
   (main window: Overview / Recordings / Contexts / Settings) alongside the 2026-09-12 one, and
   update the snapshot date. State that the window does not change capture, pause or export
   code and is not a gate.
2. README → replace the *Recent* menu description with the window; keep the pinned sentences
   (“Open last session in Claude”, “Open last session in ChatGPT”, `claude -p`, `codex exec`).
3. `test_contracts.py` additions:
   - `applicationShouldHandleReopen` body contains `mainPresenter.show(` and not `showSettingsWindow`;
   - `MainWindow.swift` contains `NSApp.activate(` only inside `func show(`;
   - `HotkeyManager.swift` and `RecordingHUDWindow.swift` contain no `MainWindowPresenter`;
   - `SessionLibrary.swift` contains no `full_transcript`, `note`, `title`, `url` field reads
     (grep the `SessionSummary` struct body);
   - `AppDelegate.swift` still contains every string listed in §1.5.

**Verify**

```bash
bash scripts/run_linux_tests.sh
```

**Done when:** the next agent reading AGENTS.md knows the window is approved, and the Linux
suite fails if someone routes reopen back to Settings or reads captured text into the index.

**Commit:** `docs: record the main window as an approved surface`

---

## 5. Other suggestions (ranked)

Do now, inside H01–H06:

1. **Setup checklist on Overview** — first launch currently shows only the permissions window,
   then nothing. The readiness card is the same three rows plus Whisper preload, AI service and
   meeting notice, so a new user sees one screen that says what is missing. Later it becomes the
   surface for TASK D01’s preflight snapshot.
2. **Unfinished sessions front and centre** — a crash mid-processing leaves one disabled menu
   line today. Needs-attention + a Retry button on the row makes recovery obvious; TASK D04’s
   Recover / Discard states plug into the same list.
3. **Drag `export/` out of the window** — Tier 1 handoff is “drop the folder into Cursor”.
   A draggable row that only ever offers `export/` is faster than Reveal-then-drag and cannot
   leak `archive/`.
4. **Copy export path** — for pasting into a Claude Code or Codex terminal session that is
   already open.
5. **Open brief** — `SESSION_BRIEF.html` is self-contained; open it in the browser instead of
   embedding WebKit (no `WKWebView` file-access surface, no window bloat).
6. **Speaker review from the session row** — today it is under Settings → Speech; nobody looks
   for a per-session action there.
7. **Storage visibility** — sessions folder size and per-session archive size next to the
   retention picker, so the 3840×2160 / 16 Mbps archives are not a surprise.

Do after the hardware gates (keep out of this plan):

8. **Payload review (D03) and pre-export review (D05)** as sections of this window. They change
   what leaves the Mac and belong after Gate 1 / Gates 3–6.
9. **Export profiles (D06)** as a per-session action.
10. **Repository auto-fill for contexts** — pick a project folder and read the git remote URL.
    Nice, but it is a new product surface with file-system access; v2.
11. **Automatic context selection** — explicitly deferred to v2 in README; leave it.

Do not do:

12. **Index transcripts or Shot notes for search.** D07 forbids it and C2 makes it a leak path.
13. **Embed the HTML brief or video in the window.** The speaker review already has a native
    `AVPlayerView` for the private archive; the export brief is for the browser.
14. **Auto-open the window when a recording starts or stops.** Gate 0 says the app must not take
    focus during a presentation; a status change is not a user click.
15. **Gate Record, Open in Claude or export on the license.** `LicenseStore` is display-only by
    contract and the window must keep it that way.

---

## 6. Risks

| Risk | Mitigation |
|---|---|
| Activation-policy flip leaves no app focused after the window closes | Presenter re-activates the previous frontmost app; preference to turn the Dock behaviour off; manual check in H06. |
| `SettingsView` hosted in a split view is narrower than its 620 pt minimum | Window minimum 840×620 and a sidebar of at most 200 pt, so Settings keeps its sides and footer while recording (§8 H01); sidebar collapsible. |
| Hundreds of sessions make refresh slow | Stat-cache before decode; sizes computed on selection only; 5 s timer only while visible. |
| A contract grep breaks on refactor | New vault code lives in `SessionLibrary.swift`; AppDelegate keeps every pinned literal (§1.5); run `python3 scripts/test_contracts.py` after each task. |
| Delete removes the wrong folder | Same owned-folder removal as `removeAbandonedSession`; symlink and live-lock refusal; confirmation names the id. |
| The LaunchAgent loop pops the window every three minutes | `--background` argument in `mac_agent_loop.sh` (H01.7). |
| Two Settings paths (SwiftUI `Settings` scene + presenter) | Unchanged from today; the command group already routes ⌘, to the presenter. Optional cleanup later. |
| Older `NSApp.activate` calls (alerts, capture-area picker, context window) bring the open window forward over another app or a presentation | Not changed by this plan; manual check 7 in §8. |
| Layout review relies on snapshot PNGs that cannot draw Liquid Glass | The PNGs are for a person to look at; the real sidebar and toolbar are manual check 8 in §8. |

---

## 7. Verification summary

After each task:

```bash
bash scripts/run_linux_tests.sh
bash scripts/mac_xcode_test.sh
```

Layout snapshots (added after H07; not a gate and not a pixel test):

```bash
TEST_RUNNER_SCRUMTRACE_SNAPSHOT_DIR=/absolute/dir bash scripts/mac_xcode_test.sh
```

xcodebuild passes `TEST_RUNNER_` variables to the test process without the prefix, so the tests read
`SCRUMTRACE_SNAPSHOT_DIR`. `ScrumTraceTests/MainWindowSnapshotTests.swift` then draws the real window over
a fixture vault (five recordings, one of them unreadable, and two saved contexts) at 960×640 in the light
and dark appearance: Overview idle, recording and scrolled; Recordings selected, scrolled, interrupted and
empty; Contexts; Settings → Speech, General and Permissions; and Settings at the 840×620 minimum while
recording beside the widest sidebar. Files are named `<section>-<variant>-<light|dark>.png`. Some
`MainWindowTests` and `ProductContextTests` also write `main-*.png` into the same folder. Without the
variable the two snapshot tests are skipped and the others write nothing. Nothing is asserted about pixels:
the PNGs are for a person to look at. `NSView.cacheDisplay` cannot draw Liquid Glass on macOS 26, so the
sidebar and, in the dark appearance, the toolbar items and the Settings tab strip come out as blank shapes.
That is a limit of the renderer, not a regression; check those areas in the real window (manual check 8
in §8).

Manual, once, after H06 (does not touch `samples/GATE_LOG.md`):

1. Quit every ScrumTrace. Request one rebuild (`touch ~/Library/Logs/ScrumTrace/agent.request_rebuild`
   then `bash scripts/mac_agent_loop.sh`, or `bash scripts/mac_gate01.sh`), open
   `~/Applications/ScrumTrace.app`.
2. Window opens on Overview; readiness rows match Settings → Permissions.
3. Recordings lists the existing sessions under `~/Movies/ScrumTrace/sessions` with sizes;
   the unfinished `transcribing` session shows Retry.
4. Reveal export/, Open in Claude, Open brief, drag-out, Delete… on a throwaway session.
5. Contexts shows usage counts; Record with this context… reaches the capture-area overlay.
6. ⌘, opens Settings; Agent Log… opens the Logs tab; icon click fronts the same window.
7. Keynote full screen: hotkeys still do not bring ScrumTrace forward.
8. Close the window: Dock tile disappears, previous app has focus.

Hardware gates remain exactly where AGENTS.md says they are. This window is not evidence for
any of them.

---

## 8. Implementation notes

Where the committed code differs from the task text above, these notes are authoritative. Every
task kept the contract pins in §1.5 and passed `scripts/test_contracts.py`.

### H01 — window shell

- `MainWindowPresenter` lives in `ScrumTrace/App/AppDelegate.swift`, not `MainWindow.swift`, so
  the pinned `height: 640`, `SettingsView(settings:` and `settings_open` literals stay in that file.
  `MainWindow.swift` holds `MainSection`, `MainNavigation`, `MainWindowView`, the live banner and
  `MainWindowLaunchPolicy`.
- The Settings section receives `SettingsView` through a builder closure created in
  `AppDelegate.swift`, and builds it fresh each time the section is shown.
- The 840×620 minimum (`MainWindowPresenter.minimumContentSize`) is enforced in
  `windowWillResize(_:to:)`, because SwiftUI resets
  `contentMinSize` whenever the split view content changes. The same clamp applies to a frame
  restored from the `ScrumTraceMain` autosave name. Tests pass `frameAutosaveName: nil`.
- While a sheet is attached to the window, section, tab and session navigation are ignored and the
  window is only fronted. Changing the section would dismiss the sheet and lose its edits.
- Launch shows the window first, then `OnboardingWindow.presentIfNeeded()`, so the first-run
  permissions window stays on top. `MainWindowLaunchPolicy.shouldShowOnLaunch` returns false for
  `--background` and for hosted XCTest runs.
- A Login Item launch stays in the menu bar too: `applicationDidFinishLaunching` passes
  `MainWindowLaunchPolicy.isLoginItemLaunch(NSAppleEventManager.shared().currentAppleEvent)`, true when the
  launch event's `keyAEPropData` is `keyAELaunchedAsLogInItem`. macOS may not mark a relaunch by Resume at
  login that way, so such a launch can still show the window (not checked on a Mac).
- Relaunch ScrumTrace opens the new instance with `MainWindowLaunchPolicy.relaunchArguments`: `--background`
  unless the main window is open (minimized counts), and always when this instance was started with it. The
  presenter tells `SessionController.isMainWindowOpen` whether its window is open. A relaunch with the window
  closed therefore passes `--background` on: a later Relaunch from that instance stays in the menu bar even if
  the window was opened in between (manual check 6).
- Settings at the minimum size: the sidebar column can be dragged to at most 200 pt
  (`MainWindowView.sidebarMaximumWidth`, down from 260), and the minimum content height is 620 pt, up
  from 580 in the first build. Measured on macOS 26, the sidebar is drawn 8 pt wider than its column,
  Settings needs about 652×592 pt and the live banner is 41 pt. So at 840×620, recording, beside the
  widest sidebar, Settings keeps both sides, its tab strip and its footer, and loses at most 10 pt of
  side padding and 13 pt of bottom padding. The detail pane is still clipped, which now cuts only that
  padding. The cost: the window can shrink only 20 pt below its 640 pt default height.
  `testSettingsKeepsItsSidesAndFooterBesideTheWidestSidebarAtTheMinimumSize` checks that the sidebar
  stops at its maximum (plus the 8 pt) and that Settings loses no more than its 16 pt padding on either
  side or at the bottom; the 10 pt and 13 pt figures come from the measurement, not the test.
- The banner samples whether Resume is allowed every 0.5 s, and only while paused. While the privacy
  guard holds a pause, Resume is disabled with *Resume waits while a password manager is on screen.*
  as its help tag, and as the banner's detail line unless the status line already names the automatic
  pause.

### H02 — session index

- `SessionSummary` has one field beyond the list: `offlineFailedSliceCount` (a count), because a
  completed session can still hold offline-failed slices and the Needs review filter needs them.
  The `Mirror` allow-list test pins it.
- Decoded summaries are cached by manifest size and modification time (lstat). Export availability
  is probed again on every refresh with `ExportRel.regularFileByteCount`, which never follows a
  symlink and treats zero bytes as missing, because export files change without a manifest write.
- A manifest whose `session_id` differs from its folder name is an unreadable row with the fixed
  reason `session id mismatch`, in addition to `decoding failed` and `not readable`.
- The Unfinished filter uses the `isUnfinished` definition, so offline-failed sessions also appear
  there. Filters may overlap.
- Views filter on every render, so an empty search formats no date, and a search builds each row's
  searchable fields (id, formatted date, context and product names) once per row.
- The `recording.lock` reader sits in `AgentLog.swift` right after `setRecording`; it refuses
  symlinked locks and never deletes the lock. `SessionVault.swift` changed only
  `private func listedSessionIds` to internal. A lock counts as live only while its pid runs an
  executable named ScrumTrace (`proc_pidpath`), so a pid the system reused after a crash mid-recording
  never blocks Delete….
- A scan leaves out a folder removed between listing and reading, and a new folder that has no
  `session.manifest.json` yet (a recording `createSession` is still writing). The library's first scan
  counts as following a scan that listed nothing, so this also holds when the window first opens. If the
  manifest is still missing on the next scan, the folder is listed as `not readable`, so one that never
  gets a manifest can still be revealed and deleted (launch already prunes abandoned starts, so such a
  folder is rare). A manifest that exists but cannot be read or decoded and a folder an earlier scan
  already listed (such as what a failed delete puts back) are listed at once, and so is every folder in
  `sessionEntries()`, a one-off listing with no next scan.
- `deleteSession(id:recordingLockURL:)` also throws for a folder that does not exist and confirms
  the folder is gone afterwards.
- Archive totals are cached per session stamp (manifest plus `archive/` lstat); only changed
  sessions are walked again. A file growing deep inside `archive/` is counted after the next
  manifest write. `isLoading` is true only until the first scan publishes, and unchanged refreshes
  publish nothing.

### H03 — Recordings

- The window toolbar is bridged (`sceneBridgingOptions = [.toolbars]`) and `MainWindowView` keeps a
  persistent, accessibility-hidden navigation toolbar item. Without it AppKit resized the window
  whenever Recordings added toolbar items. The window therefore has a toolbar-height titlebar in
  every section (a 692 pt frame for 640 pt of content).
- The presenter in `AppDelegate.swift` owns `RecordingsModel` and its `SessionLibrary`, takes an
  `onStartRecording` closure (`menuBar?.requestStart()`), reports window visibility, and
  `show(sessionId:)` clears a search or filter that would hide the requested row.
- Table and detail are stacked in a `VStack` (flexible table, 290 pt detail), not a `VSplitView`,
  which ignored the sidebar's safe area.
- Reveal folder… on an unreadable row uses the same private-files warning as Reveal archive… and is
  disabled while recording or processing, because the folder contains `archive/`.
- The consent line's provider, model and clip audio/video flags are not in `SessionSummary`. The
  detail pane decodes the selected manifest off the main actor and keeps only `UploadConsent`
  fields (provider and model only when approved). `scripts/test_contracts.py` pins that
  `SessionDetailFacts` reads only `uploadConsent`, and a `Mirror` allow-list test pins its fields.
- The row drag checks `export/` at drag time on the main actor (a lazy provider would advertise a
  file URL before the check).
- `SpeakerReviewView` reads its session list and the selected transcript off the main actor, through
  `SpeakerReviewLoader`. Opened from Recordings, it reads the requested manifest on its own first and
  selects it, so that transcript loads while the recent list (every manifest that decodes, at most 100,
  as before) is still being read. Names and corrections change only together with the transcript, and
  after a save the sheet shows the transcript the controller returns instead of reading it again.
  The loader's recent-list read is async, so a test can hold it without holding a thread.
  Settings → Speech enables *Review and name speakers…* once a manifest decodes, as before, but that tab
  is redrawn every second, so the check runs off the main actor, only when Settings appears and when
  recording or analysis starts or ends. It tries the newest folders first and usually decodes one
  manifest. The disabled button has a help tag. The answer is kept on `SettingsNavigation` (nil until the
  first check lands), which outlives the rebuilt Settings view, so the snapshot test waits for it instead of sleeping.
- The empty state's Start recording follows Overview's rule and help text: it waits while recording,
  analysis or a start runs, and while a Start shows its recording-context window. Opening that window
  from the status-bar menu or ⌘N, and cancelling it, publishes nothing on the controller, so while the
  window is visible `RecordingsModel` reads the capture state every 2 s, and every 0.5 s while the
  context window shows, as Overview does while its section is shown.
- At 960×640 Duration, Shots, Tasks and Export sit at their minimum widths (52, 34, 46 and 56 pt, which
  fit a meeting over an hour, 99 / 99 tasks and a pack at its 35 MB cap), and Date, Context and Status
  shrink by the same amount from their ideals (174, 184 and 172 pt). That leaves Date a 24-hour date and
  time, Context *Unreadable manifest* with its symbol, and Status *Offline — needs review*, all in full.
  A 12-hour time, a long context and a narrower window truncate; Date, Context and Status cells carry
  the full text as a help tag.
- An unreadable row shows plain words for its fixed reason: *Damaged*, *Could not be read* or *Folder
  name mismatch* in the Status column, and one sentence in the detail pane. The technical phrases stay in
  `SessionEntry` and never reach the window.
- The Delete… confirmation names the recording as its row does, by date and context (*Unreadable
  manifest* for an unreadable row), and its message names the folder id. It deletes the row the command
  came from, so Delete… in the context menu of a row that is not selected deletes that row and leaves the
  selection alone. While the dialog animates away after Cancel or Delete recording it keeps that title
  (`RecordingsModel.closingDeleteTitle`) instead of flipping to the generic *Delete this recording?*.
- Delete… waits only while recording or analysis runs, like the other session-changing actions.
  The session the controller last recorded or retried can be deleted once both finish. Just before the
  folder is removed, and again after, `SessionController.forgetSession(id:newestRemaining:)` drops the
  in-memory manifest when it names that session and moves `lastSessionId` from it to the newest readable
  recording the window still lists that no delete is removing, or to none. So the menu's last-session items
  stay usable while other recordings remain, and neither they nor Retry Analysis point at a folder being
  removed. If recording, analysis or a start runs when the delete finishes (a Retry Analysis of that session
  from the menu, say), `forgetSession` changes nothing and returns false, and the window asks again once the
  controller is idle, so a run never loses its session part way. A Retry Analysis that finds neither the
  manifest nor the folder (started from a menu built before the delete) logs `retry_ignored` with reason
  `session_missing`, writes nothing, ends idle without an offline-failed state, sets the menu's status line
  to *Recording was deleted — nothing to retry* and puts back the menu's previous last session. It checks the
  folder again just before writing the manifest, because the upload consent alert can stay open while the
  delete removes it. A delete the vault refuses (a live `recording.lock`) or that fails part way is not
  undone: the row stays listed, and the menu stays on the recording it moved to rather than on one another
  capture holds or that is partly wiped.
- Detail facts load only for the selected row. Selecting another row cancels every other row's
  load (the thumbnail loop stops before its next still) and drops its result, and the eight-entry
  detail cache never evicts the selected row's facts.
- A recording whose manifest is still at `recording` or `paused`, and that no running capture holds,
  was cut short when ScrumTrace stopped (a normal quit writes idle). It reads as interrupted:
  *Recording was interrupted* and one sentence above its stage bar in the detail pane, and the same
  words in Overview's Needs attention (`RecordingsModel.isInterrupted`,
  `RecordingRowText.unfinishedNote`). The empty state says recordings appear after you stop recording.

### H04 — Overview

- `RecordingsModel.listsSessions(_:)` makes the session index refresh on Overview (and, from H05,
  Contexts), so a window reopened there does not show stale rows. This touched `RecordingsView.swift`.
- `MenuBarController.isPreparingRecording` became `private(set)`; `UpdateChecker` gained a static
  `lastResult` written by `check()`. The window never makes a network request.
- A window Start logs `main_start` once, then calls `requestStart()`, which logs no start row. Only the
  status-bar menu's Start logs `menu_start`, and ⌘N logs `command_start`. `scripts/inspect_gate0_log.py`
  checks the capture-area overlay after any of the three. Tests replace `askMeetingNotice` so a Start stops
  at the notice without an alert. Overview, Recordings and Contexts check what the flow checks (recording or
  analysis idle, no Start showing its context window) before they log `main_start`, so a refused Start logs
  no start row.
- The presenter's `isWindowOnScreen` decides visibility after an occlusion change. The app uses the live
  read (visible, not minimized, not covered); hosted tests ignore occlusion so the test Mac's screen cannot
  stop the loops they wait for.
- The meeting-notice row is marked as needing action but never blocks recording, because Start
  asks for the notice itself. Only the Screen Recording and microphone rows block.
- Overview's Start button also waits while readiness blocks recording (Screen Recording denied or
  granted but needing a relaunch, microphone denied), and its help tag names the row whose buttons fix
  it, so the card never leads to the flow's *Cannot start recording* alert. The flow itself is
  unchanged: the status-bar menu, ⌘N, the Recordings empty state and Contexts' Record with this
  context… still show that alert when readiness blocks. While recording or analysis runs, the card's
  first row reads *Recording in progress* or *Analysis in progress* with a neutral icon instead of
  readiness (`OverviewStartCard`).
- A readiness row button that waits has a help tag saying why (recording or analysis, or the Whisper
  model already loading). The microphone row also offers Capture settings, because turning Record
  microphone off clears the block.
- The update line appears only when a check that already ran found a newer release.
- Additions: a Needs attention line for unreadable manifests, a local Dismiss for the last error,
  and an Accessibility row that opens Settings → Permissions instead of prompting.
- One noun for the user: the window, Settings and the status-bar menu say *recordings* where they
  said *sessions* (*Recordings folder*, *Reveal recordings folder…*, *Keep recordings*, the retention
  and Product contexts captions). Settings → Permissions shows Microphone and Accessibility in the
  card's words, lower-cased (`OverviewReadiness.microphoneStatus`, `accessibilityStatus`). Internal
  names (`SessionVault`, `revealSessions`, the `reveal_sessions` log value) are unchanged.
  `test_overview_card_and_window_wording` in `scripts/test_contracts.py` pins the wording.
- `SessionController` gained `setStartInFlightForTesting(_:)` in an extension at the end of the
  file.

### H05 — Contexts

- The presenter in `AppDelegate.swift` creates `ContextsModel` with the same start and
  context-window closures as Overview.
- `ProductContextNaming.duplicate` compares names ignoring case and diacritics, the rule
  `saveProductContext` uses; Settings → General uses the same helper.
- `ProductContextEditor` gained an explicit internal `init`; its body is unchanged.
- The table has five columns, not the six in §2: Name, Product, Repository, Recordings and Last used.
  Tech stack shows in the detail pane (`ProductContextSummary`). With six columns, Product and
  Repository truncated at 960×640; now a product name and a repository URL of about 35 characters fit,
  and a longer URL truncates in the middle so it keeps its host and repository name.
- While recording or analysis runs, the table, detail and Show in Recordings stay usable; only the
  six context actions are disabled.
- Record with this context… selects the context first. If the Start flow returns without opening
  its context window (notice cancelled, readiness blocked), the previous default is restored.

### H06 — Dock, keyboard, launch

- Edit → **Find Recordings…** (⌘F) in `ScrumTraceApp.swift` focuses the Recordings search field,
  because `.searchable` cannot be focused programmatically on macOS 14. Escape on the table clears
  the search (`RecordingsModel.clearSearch()`). ⌘R and Delete use the existing toolbar shortcut and
  `.onDeleteCommand`.
- Main-menu commands (⌘,, ⌘F, ⌘1–⌘4) act only while ScrumTrace is already the active app, because
  key equivalents can reach the main menu from the non-activating Shot note panel during a
  presentation (Gate 0). The menu-bar item and the app icon are unaffected.
- Search text and filters stay in `RecordingsModel`, which the presenter keeps for its whole life,
  instead of moving into `MainNavigation`. Section, selection, search and filters survive close and
  reopen.
- Activation goes through the `MainWindowActivation` seam; the app passes `.live`, tests pass nil.
  The app that gets focus back is the last other app activated (process id only), and the hand-back
  runs about 150 ms after the close, only if ScrumTrace is still frontmost, no other ScrumTrace
  window is key and the window was not reopened.
- Changing the Dock preference while the window is open applies immediately.
- New log events `main_dock` and `main_focus_return` carry one small value each.

### H07 — docs and pins

- `test_main_window_routing_and_private_index` in `scripts/test_contracts.py` pins the §1.5
  `AppDelegate.swift` strings; the reopen body (`mainPresenter.show(`, and no mention of Settings
  in any spelling); every self-activation in `AppDelegate.swift` (`NSApp.activate`,
  `NSApplication.shared.activate`, `NSRunningApplication.current.activate` or
  `activate(ignoringOtherApps:`) sitting inside a `func show(` body of `MainWindowPresenter` (the
  presenter moved there, see H01); no presenter reference and no self-activation in
  `HotkeyManager.swift` or `RecordingHUDWindow.swift`; no prompting permission calls or
  self-activation in the four window view files; `--background` in the launch policy and the agent
  loop; and the index privacy rule. That rule checks the `SessionSummary` body as the task asked,
  and the whole of `SessionLibrary.swift` (helpers and the search filter included): no captured-text
  words outside the `hasFullTranscriptArchive` flag and the size-only export probes, no `.url`,
  `.windowTitle`, `.text`, `.segments` or `.words` member reads, and `manifest.` reads limited to
  the metadata fields the index uses. Both ignore whole-line comments (a doc comment names
  `archive/full_transcript.json`).
- The Gate 0 rule is about the main window's code. Existing activations elsewhere stay:
  onboarding, the capture-area picker, the recording-context window, the menu's alerts (meeting
  notice, readiness, updates), the upload consent alert during processing and the failed-start
  alert.
  While the window is open ScrumTrace is a regular app, so each of those activations may also bring
  the main window forward, over another app or a full-screen presentation. The capture-area picker
  activates on every Start and afterwards only orders its overlays out, so after Record an open window
  may stay in front of what is being recorded. None of this is checked on a Mac (manual check 7).

### After H07 — snapshot renders and review fixes

- `ScrumTraceTests/MainWindowSnapshotTests.swift` (commit `test: render main window sections for layout
  review`) renders the window for a visual review; §7 says how to run it and what it cannot draw. The
  doc comment on its `render` helper stays the authoritative note on the `cacheDisplay` limit.
- A review of the branch led to four fix commits. Their notes sit under the task each one changes:
  - `fix: keep login and relaunch starts in the menu bar`: Login Item and Relaunch launches (H01), one
    start row per Start and the occlusion seam (H04).
  - `fix: let finished recordings be deleted and drop stale detail loads`: `recording.lock` pid
    ownership, new folders without a manifest and a cheaper search (H02); the held-session rule for
    Delete…, `forgetSession`, stale detail loads and the detail pane's C2 pin (H03).
  - `fix: clarify Recordings states and load speaker review off the main thread`: speaker review
    loading, the empty state's Start, column widths, plain words for unreadable rows and the Delete…
    confirmation (H03).
  - `fix: make Overview, banner and Contexts states read correctly`: Settings at the minimum size and
    the banner's Resume (H01), interrupted recordings (H03), the Start card, row help and wording
    (H04), and the Contexts columns (H05).

### Manual checks still open

Agents building H01–H07 and the review fixes were not allowed to launch or install ScrumTrace, so §7
and these checks have not been run on a Mac:

1. Keynote full screen: ⌥⌘S, ⌥⌘↩ and ⌥⌘P do not bring ScrumTrace forward, with the window closed
   and with it open behind the presentation. Take a Shot and type its note both ways too
   (`ShotNoteWindow.canBecomeKey` is still true).
2. Keynote full screen: open the Shot note, click its field, press ⌘F, ⌘, and ⌘2. ScrumTrace must
   stay behind the presentation.
3. On macOS 14 and on macOS 26: open the window from the Dock icon, Finder, Spotlight and the menu;
   the Dock tile and ScrumTrace's menu bar appear after the switch to `.regular`. Close it; the previous
   app regains focus (150 ms delay, `NSRunningApplication.activate(options: [])` under cooperative
   activation) and no app is left without focus.
4. First run: close the main window while the permissions window is open; the permissions window
   keeps its Dock tile and focus.
5. Turn *Show ScrumTrace in the Dock while its window is open* off while the window has focus.
6. Login Item and Relaunch: add ScrumTrace in System Settings → General → Login Items, log out and in;
   ScrumTrace stays in the menu bar with no window and no Dock tile. The unit test builds the launch event
   itself, so this also confirms that `currentAppleEvent` holds the launch event in
   `applicationDidFinishLaunching` under the SwiftUI app delegate adaptor. Then choose Relaunch ScrumTrace
   with the window closed (menu bar only) and with it open (the window returns). Also log out with
   *Reopen windows when logging back in* on while ScrumTrace runs, and note whether that launch shows
   the window.
7. Older activations with the window open. Open the window, then switch to another app, and separately
   to Keynote full screen. Trigger each older `NSApp.activate` call: the meeting notice and *Cannot
   start recording* (Start from the status-bar menu and ⌘N), the update result (Check for updates in
   the status-bar menu, then switch away before it answers), the capture-area picker (Start, and Select
   area on screen…), the recording-context window, the upload consent alert (Stop & process),
   *Recording did not start*, the first-run permissions window (`OnboardingWindow.focus`, on a
   first launch and from Show first-run permissions in Settings → General; note which of the two
   windows ends up in front) and the transcription review window (Review transcription results in
   the status-bar menu). Note whether the main window comes forward with each, whether macOS
   switches Spaces, and which app is in front after Record in the capture-area picker.
8. What the snapshot PNGs cannot show: the real window in the light and dark appearance on macOS 26 and
   on macOS 14, including the sidebar, the toolbar items and the Settings tab strip; Settings at the
   840×620 minimum while recording, with the sidebar dragged to its widest; and the Recordings Date
   column with a 12-hour clock, which truncates the time at 960×640.
9. Refresh cost: with hundreds of recordings in the Recordings folder, keep the window open on Overview
   and on Recordings, on battery, and watch CPU and energy in Activity Monitor. While the window is
   visible and not covered, the index refreshes every 5 s (an lstat of each manifest plus export size
   probes), and while Overview is shown it reads readiness every 2 s (Screen Recording preflight,
   Accessibility trust, microphone status).
