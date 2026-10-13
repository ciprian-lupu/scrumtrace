# ScrumTrace — Display Selection Plan (pick the monitor before Start)

Status: **implemented on `feature/monitor-selection-display`** (tasks D01–D07; D08 not done), written
2026-10-13, branched from `develop` at `ec3bedb`. Revision 2 folds in the Codex CLI review of
revision 1 (§6); §7 records where the build differs from the task text. The two-display Mac checks in
§3 have not been run.

Request (2026-10-13): "I want to select my monitor before I start. I don't always want to record
all screens."

This document follows the task format of [MAIN_WINDOW_PLAN.md](MAIN_WINDOW_PLAN.md)
(Files / Implementation / Tests / Verify / Done when / Commit). Tasks D01–D07 are ordered so each
one compiles and passes on its own, **including the contract tests it changes**.

---

## 0. What happens today

ScrumTrace never records more than one display. The problem is the opposite of the request's
wording: you cannot choose *which* one.

| User action | Behaviour on `develop` today | Where |
|---|---|---|
| Start → overlay → **Entire Display** button on the external monitor | Returns `CaptureArea.entireDisplay` (`displayID: 0`). The screen the button was on is thrown away. | `CaptureAreaPicker.swift:64` `onUseEntire` → `finish(.entireDisplay)` |
| Start → overlay → **Return** on the external monitor with no box drawn | Hint says "Return records this display". The overlay's initial `liveRect` is the whole screen, so `area(from:)` takes its full-screen branch and returns `.entireDisplay`. Same loss. | `CaptureAreaPicker.swift:242`, `:469` |
| Start → overlay → **Space** | `.entireDisplay`. | key monitor, `keyCode 49` (`:88`) |
| Recorder resolves `.entireDisplay` | `content.displays.first`, the first display ScreenCaptureKit lists. Nothing ties that to `CGMainDisplayID()`; on most Macs it is the display with the menu bar, but that is an observation, not a rule. | `SessionRecorder.swift:320` `display(in:matching:)` |
| AgentLog `recorder_sckit_begin` / `capture_area_picker` | `"display": "all"` for a full-display recording. Not true: one display is recorded. | `SessionRecorder.swift:154`, `CaptureAreaPicker.swift:112` |
| Region on a display that is no longer connected | `display(in:matching:)` falls back to `displays.first`; `regionFitsDisplay` is false, so the **whole** first display is recorded without `sourceRect`. Silent widening. | `SessionRecorder.swift:186–201` |
| Shot during a display recording | `CGDisplayCreateImage(CGMainDisplayID())` for id 0, and a second fallback to the main display if the chosen one fails. A failed crop returns the **whole** image. | `SessionController.swift:1725`, `:1748` |
| Window titles / URLs during a display recording | Sampled from whatever app is frontmost, on **any** display. Single-window mode gates by process (not by window). | `MetadataSampler.swift:46` |
| Menu / Settings / Overview | "Entire display" with no way to say which. | `AppSettings.captureSummary` |

So: one display is always recorded, you cannot say which, and the overlay's per-screen controls do
not mean what their labels say on a second monitor. Single-window mode (`68ebfce`) is unaffected
and is the model for the rules below: pick at Start, never widen, never fall back.

---

## 1. Design

### 1.1 One rule, three entry points

A display recording carries the display it targets, the same way a region already does. The
**overlay is the only place a display is confirmed for a recording**; the menu and Settings only
pre-select which screen the overlay opens on.

1. **Confirm on the overlay at Start.** Each overlay already covers one screen. Its **Entire
   Display** button, **Return** and **Space** record *that* screen. The overlay shows the screen's
   name and, when two screens share a name, a number and position ("2 · right").
2. **Pre-select in the menu and in Settings → Capture.** A *Display* list of the connected
   screens plus *Main display* (the display `CGMainDisplayID()` names, the one with the menu bar).
   The choice is saved; the Start overlay opens with that screen as the key window, so Return
   confirms it without touching the mouse.
3. **Single-window mode is unchanged.**

Choosing a display limits **screen** capture only. System audio, the microphone, Pause, the
credential-app privacy pause and the Shot/Hold-to-Talk gates are untouched and stay global.

### 1.2 Model

`CaptureArea` keeps its shape and coding keys. One optional field, so saved `UserDefaults` blobs
and old `capture-layout.json` files still decode (a decode failure in `AppSettings.init` silently
resets to `.entireDisplay`, so this is tested, not assumed):

```swift
struct CaptureArea {
    var capturesFullDisplay: Bool
    var displayID: UInt32          // 0 = "main display" (CGMainDisplayID() at Start); unchanged meaning
    var displayName: String?       // NEW, "display_name"; NSScreen.localizedName at pick time; label only
    ...                            // region fields unchanged
    static func fullDisplay(id: UInt32, name: String) -> CaptureArea
    var isEntireDisplay: Bool      // unchanged: true for any full-display area
    var targetsMainDisplay: Bool   // displayID == 0
    var summary: String            // "Main display" | "Display: DELL U2720Q" | "640×360 region"
}
```

**Identity is the display ID, never the name.** `CGDirectDisplayID` is stable until the next
restart or reconfiguration; `localizedName` is a label with no uniqueness promise (two identical
monitors share it). There is **no** name-based rematch: if the saved id is not connected, the
overlay says so and the user picks again (§1.4). This keeps "resolved display == what the user
confirmed" true by construction, which is what makes the no-widening rule checkable.

Resolution is a pure function so it can be unit-tested without ScreenCaptureKit:

```swift
struct DisplayCandidate { let id: UInt32; let name: String; let width: Int; let height: Int; let isMain: Bool }
enum CaptureDisplayResolution: Equatable { case display(UInt32); case missing }
enum CaptureDisplayResolver {
    static func resolve(_ area: CaptureArea, among: [DisplayCandidate]) -> CaptureDisplayResolution
}
```

- `displayID == 0` → the candidate with `isMain` (`CGMainDisplayID()`), else `.missing`
  (no "first display" fallback any more).
- `displayID == N` → exact id match, else `.missing`.
- `.missing` in the recorder fails the Start with "The chosen display is no longer connected. Start
  again and pick a display." This can only happen in the race between the overlay confirm and the
  stream start, because the overlay has already refused a missing display (§1.4). It also closes
  today's silent region→whole-first-display fallback.

### 1.3 What the recording pins, and in which order

`SessionController.startRecordingAsync` already sets `sampler.restrictedProcessID`, then
`captureFreeze.attach(recorder)`, then `privacy.start()`, then `recorder.start(...)`, and the
contract tests pin that order (`test_contracts.py:1428–1429`). The display gate must therefore be
known **before** the recorder resolves anything. That works because the overlay always returns a
concrete id now:

1. Controller computes `pinnedDisplayID = area.targetsMainDisplay ? CGMainDisplayID() : area.displayID`
   and sets `sampler.restrictedDisplayID` next to `restrictedProcessID` (nil in window mode).
2. `privacy.start()` as today.
3. `recorder.start` resolves the same area with the resolver and **must** land on `pinnedDisplayID`;
   anything else is `.missing` and throws. The recorder exposes `recordedDisplayID` and the
   configured output size for callers that want them, but never a different id.

From then on:

- **Shots** come from `CGDisplayCreateImage(pinnedDisplayID)` only. No fallback to the main display,
  and a failed crop fails the Shot instead of returning the whole image (`shot_fail reason=display`).
- **Metadata** (window title, URL) is written only when the focused window is on the pinned display
  (§1.5).
- `archive/capture-layout.json` gains `display_id`, `display_name`, `capture_width`, `capture_height`
  (the configured output size, after the writer's even-rounding and 3840×2160 cap; `SCDisplay.width`
  is not promised to be pixels). Private archive provenance only; nothing in `export/` or the briefs
  changes. Every later `persistCaptureLayout()` call rewrites the same values.
- AgentLog `recorder_sckit_begin` / `start_ok` / `capture_area_picker` log
  `"area": "display" | "region" | "window"`, `"display": "<id>"`, and `width`/`height` for display
  recordings too. The value `"all"` and the key `display_name` never appear in AgentLog.

### 1.4 Missing display: one policy for menu, overlay and recorder

- **Menu / Settings:** a saved display that is not connected is listed greyed as
  "DELL U2720Q (not connected)". Choosing any other row replaces it.
- **Overlay at Start:** if the saved id is not among `NSScreen.screens`, the overlay opens with the
  main display as the key window and shows, on every screen, "DELL U2720Q is not connected. Pick a
  display." Return, Space and Entire Display then confirm the key screen explicitly, as always. No
  automatic substitution happens without that confirmation.
- **Recorder:** fails only in the confirm→start race (§1.2). The existing `abortFailedStart` path
  removes the session folder.
- **During a recording:** `NSApplication.didChangeScreenParametersNotification` refreshes the menu
  list only. The pinned target never changes. If the pinned display goes away, ScreenCaptureKit
  stops the stream and the existing `didStopWithError` path applies; the plan asserts nothing more
  than "the app reports the stop and the session is finalised" and §3 tests it on real hardware
  (unplug during Start, while recording, while paused).

### 1.5 Metadata sampler on multi-display Macs

Today a display recording logs titles and URLs of windows the viewer never sees (a chat or mail
window on the other monitor). Same gate as single-window mode, by display:
`MetadataSampler.restrictedDisplayID`. The sampler already holds the focused window's
`AXUIElement`; it additionally reads `kAXPositionAttribute` and `kAXSizeAttribute` (global
top-left coordinates, the same space as `CGDisplayBounds`; no AppKit Y-flip, no backing-scale
multiply) and keeps the title/URL only when the window's centre lies inside
`CGDisplayBounds(restrictedDisplayID)`. Checked before and after the title/URL read, like the
process gate. When the frame cannot be read (no Accessibility trust, AX error) the sampler returns
the existing app-name-only fallback (`NSWorkspaceFallback.frontmost()`, which puts the app name in
`windowTitle` and carries no URL); on timeout it returns nil as today.

**Limit, stated on purpose:** for a *region* recording the gate is still the display, not the
region rectangle. A window on the recorded display but outside the region can still be sampled.
Tightening that to the region is a separate decision and is not in this plan.

The credential-app privacy pause (`PrivacyGuard`) keeps watching the frontmost app on **every**
display; this gate narrows what is *logged*, never what *pauses*.

### 1.6 Out of scope (deliberately)

- **Recording several displays at once.** `SCContentFilter` is single-display; a composite would
  need one `SCStream` per display plus compositing on the writer queue. Not requested.
- **Following the mouse / the frontmost app across displays mid-recording.** Pin at Start.
- **Seamless recovery from a display unplug mid-recording.** Deterministic stop, yes (§1.4);
  retargeting, no.
- **Name-based rematch of a reconnected display.** Cut after review (§6); explicit re-pick instead.
- **Moving the HUD and the Shot window onto the recorded display.** Optional D08, after Gate 0 is
  re-checked with the Shot window on the presentation screen (`ShotNoteWindow.canBecomeKey` is
  true). Not needed for the request: the HUD is excluded from capture and the Shot image is taken
  from the pinned display regardless of where its window opens.

---

## 2. Tasks

Each task updates `scripts/test_contracts.py` for the strings and patterns it changes, in the same
commit, so the Linux suite stays green after every task.

### D01 — Model + resolver

**Files:** `ScrumTrace/Storage/SessionModels.swift` (`CaptureArea`, new `CaptureDisplayResolver`,
`CaptureAudioLayout` display fields), new `ScrumTraceTests/CaptureDisplayTests.swift`,
`ScrumTraceTests/TimelineTests.swift`.

**Implementation:** §1.2, plus the four optional `capture-layout.json` fields. `summary` returns
"Main display" for id 0, "Display: <name>" when a name is stored, "Display <id>" when not.

**Tests:** resolver: id 0 → main; id 0 with no main candidate → `.missing`; exact id; unknown id →
`.missing`; same name, different id → `.missing` (no rematch); empty list → `.missing`.
`CaptureArea` round-trips with and without `display_name`; a byte-for-byte copy of today's
`UserDefaults` blob (fixture) decodes through the real `AppSettings` restore path and does not reset
to `.entireDisplay`. `CaptureAudioLayout` decodes an old file without display fields and keeps its
audio keys. `TimelineTests` line 105 changes from "Entire display" to "Main display".

**Done when:** native tests and the Linux contract suite pass.

**Commit:** `feat: capture area names the display it records`

### D02 — Recorder resolves, pins, never falls back

**Files:** `ScrumTrace/Capture/SessionRecorder.swift`, `ScrumTrace/Processing/SessionController.swift`,
`scripts/test_contracts.py`.

**Implementation:** replace `display(in:matching:)` with the resolver over `content.displays`
(`isMain` = `displayID == CGMainDisplayID()`). `.missing` throws `writerFailed` with the §1.2
message. `regionFitsDisplay` stays `display.displayID == captureArea.displayID`, which is now
always true for a resolved region (no rematch), so a region can no longer widen. `start` takes
`pinnedDisplayID: UInt32` from the controller and treats a different resolution as `.missing`.
Store `recordedDisplayID` and the configured output size; `persistCaptureLayout` writes the display
fields on every call. Log fields per §1.3. `statusLine` becomes "Recording Display: DELL U2720Q"
when a name is known, "Recording" for the main display. Controller: compute `pinnedDisplayID`
before `privacy.start()` (§1.3) and pass it to the recorder; the existing order
`restrictedProcessID` → `captureFreeze.attach(recorder)` → `privacy.start()` → `recorder.start(`
is unchanged.

**Tests:** contracts: `content.displays.first` appears nowhere in the recorder; the error string
exists; `pinnedDisplayID` is assigned before `privacy.start()` and passed to `recorder.start(`;
`"all"` appears in no AgentLog call. Native: `CaptureDisplayTests` covers the resolver; the
recorder itself needs ScreenCaptureKit and is covered by §3.

**Done when:** a region whose display is gone fails the Start instead of recording another display.

**Commit:** `feat: record the pinned display, fail the start when it is gone`

### D03 — Shots from the pinned display only

**Files:** `ScrumTrace/Processing/SessionController.swift` (`captureShot`, `ScreenSnap`),
`scripts/test_contracts.py`.

**Implementation:** `ScreenSnap.capture(area:displayID:)` takes `pinnedDisplayID`. Remove
`?? CGDisplayCreateImage(CGMainDisplayID())`. `crop` returns `CGImage?` and a nil crop fails the
Shot (`shot_fail reason=display`) instead of returning the whole image. The existing split markers
the window-Shot contract relies on (`// Window mode: …`, `} else {\n            snapped =
ScreenSnap.capture(area:`) are kept verbatim. The Shot window is **not** moved in this task (D08).

**Tests:** contracts: no `CGMainDisplayID()` inside `ScreenSnap.capture`; no `?? image` in `crop`;
`test_single_window_capture_never_widens` still passes unchanged. Native: `crop` returns nil for a
rect outside the image (pure CGImage test).

**Done when:** a Shot taken while recording the external monitor shows the external monitor, even
when the pointer and the key window are on the built-in display.

**Commit:** `fix: shots never fall back to the main display or the whole image`

### D04 — Overlay confirms the screen it is on

**Files:** `ScrumTrace/UI/CaptureAreaPicker.swift`, `scripts/test_contracts.py`.

**Implementation:**
- `onUseEntire: ((CaptureArea) -> Void)?`. `confirmEntire`, Space, and the full-screen (and
  near-full-screen, `width >= bounds.width - 2`) branch of `area(from:)` all produce
  `CaptureArea.fullDisplay(id:name:)` for the window's screen (`NSScreenNumber`, `localizedName`).
  `confirmSelection`'s last-resort fallback becomes the key window's full display, never
  `.entireDisplay`.
- Each overlay's toolbar shows the screen's name and point size ("DELL U2720Q · 2560×1440 pt");
  when two screens share a name, an index and position are appended ("2 · right"). The key screen's
  label is emphasised.
- `begin(current:)` picks the starter (key) window as: a window with a saved region on it, else the
  window whose screen id equals `current.displayID`, else the window whose screen id equals
  `CGMainDisplayID()`, else first. `NSScreen.main` (the key-window screen) is no longer used for
  this choice; the mouse-down `makeKey` behaviour the contracts pin is untouched.
- Missing saved display: banner text per §1.4 on every overlay.
- Hints: "Return records this display" / "Return uses this display" stay true and stay in the
  file; "Space = entire display" becomes "Space = this display".
- `capture_area_picker` logs `"display": "<id>"` for every confirm; never `"all"`, never a name.

**Tests:** extract `starterIndex(screens:current:mainID:)`, `fullDisplayArea(screenID:name:)` and
`screenLabel(name:index:duplicates:position:)` as static helpers and unit-test them with tuples.
Contracts: `finish(.entireDisplay)` and `preferred?.proposedArea() ?? .entireDisplay` no longer
appear; "Space = this display" replaces "Space = entire display"; `"Entire Display"` button title
kept.

**Done when:** on a two-display Mac, Return on the external overlay records the external display.

**Commit:** `feat: capture overlay records the display it is shown on`

### D05 — Pre-select a display in the menu and in Settings

**Files:** `ScrumTrace/UI/MenuBarController.swift`, `ScrumTrace/UI/SettingsView.swift`,
`ScrumTrace/App/AppSettings.swift`, `ScrumTrace/UI/OverviewView.swift` (summary text only),
`ScrumTraceTests/MenuAccessTests.swift`, `ScrumTraceTests/SettingsUsabilityTests.swift`,
`ScrumTraceTests/MainWindowSnapshotTests.swift`, `scripts/test_contracts.py`.

**Implementation:**
- `AppSettings.connectedDisplays: [DisplayCandidate]` from `NSScreen.screens`, injectable for tests,
  refreshed on `NSApplication.didChangeScreenParametersNotification`; the menu rebuilds on the same
  notification.
- Menu *Capture area* submenu gains a *Display* group: one checkable item per connected screen
  (label per D04, "(main)" on the main one) plus *Main display* for `.entireDisplay`. The existing
  *Use entire display* item becomes *Main display* (contract string updated). Choosing a row sets
  `captureArea`, clears `recordSingleWindow`, logs `menu_area_display` with the id. Enabled only
  while `canChangeCaptureSettings` (start, recording, pause and processing disable them, like the
  existing items). *Main display* is disabled only when `captureArea.targetsMainDisplay &&
  !recordSingleWindow`, not for every full-display area as today, so a named display can be reset.
- Settings → Capture: `Picker("Display", …)` with the same rows above the existing buttons; same
  side effects and guards; caption gains: "Pick a display here or press Return on it in the overlay.
  Only that display's screen is recorded; audio, Pause and the privacy pause stay the same. Window
  titles and URLs are noted only for windows on it."
- `captureSummary` (menu status line, Overview "Start recording — …") uses the new `summary`.
- A saved display that is not connected is listed greyed as "<name> (not connected)".

**Tests:** `MenuAccessTests`: with two fake displays the submenu lists both plus *Main display*; the
checkmark follows `captureArea`; choosing one clears single-window mode; items disabled while
recording. `SettingsUsabilityTests`: the picker reflects and writes `captureArea`. Add a Capture-tab
variant to `MainWindowSnapshotTests` for the visual check (today's snapshots cover Speech, General
and Permissions only).

**Done when:** choosing a display in the menu, then Start → Return, records that display.

**Commit:** `feat: choose the recording display in the menu and in Settings`

### D06 — Metadata sampler gated by display

**Files:** `ScrumTrace/Capture/MetadataSampler.swift`, `ScrumTrace/Processing/SessionController.swift`
(assign `restrictedDisplayID` next to `restrictedProcessID`), `ScrumTraceTests/` (sampler tests),
`scripts/test_contracts.py`.

**Implementation:** §1.5. Pure helper `MetadataSampler.windowIsOnDisplay(windowFrame: CGRect,
displayBounds: CGRect) -> Bool` (centre-point test). An injectable frame reader so the sampler can
be tested without AX. Gate checked before and after the title/URL read. Window mode keeps the
process gate and gets no display gate.

**Tests:** `windowIsOnDisplay` edge cases (centre on the boundary, window spanning two displays,
zero-size frame → false). Sampler with a stubbed frame reader: off-display window → app-name-only
metadata, no URL; frame unreadable → app-name-only; on-display → full metadata. Contracts:
`restrictedDisplayID` assigned before `privacy.start()`; `PrivacyGuard` unchanged (its split
markers still present). AgentLog privacy: `test_agent_log_privacy.py` and a new contract assert
`display_name` is never a logged key.

**Done when:** during a recording of the external display, a Safari window on the built-in display
produces no URL or title in `events.jsonl`, and the credential-app pause still fires for 1Password
on the built-in display.

**Commit:** `fix: sample window titles and URLs only from the recorded display`

### D07 — Docs and status

**Files:** `AGENTS.md`, `README.md` (only if it gains a Capture paragraph), this file's status line.

**Implementation:** AGENTS.md: the Settings/Capture paragraph (line ~229) describes display
selection and the missing-display policy; the events line adds `menu_area_display`; *Honest
status* records this as a user-approved capture-control change (same class as single-window mode)
with its open Mac acceptance (§3), and the snapshot date moves. C1–C5 definitions and the
archive/export/upload-consent contract are **not** edited. Gate inspectors are untouched: Gate 0
reads `capture_area_picker` `action`/`mode` (kept), Gate 1 and 3 read timing and audio fields (kept).

**Done when:** `python3 scripts/test_contracts.py` and `bash scripts/mac_xcode_test.sh` pass on the
full branch.

**Commit:** `docs: display selection status and notes`

### D08 — Optional: HUD and Shot window on the recorded display

**Files:** `ScrumTrace/UI/RecordingHUDWindow.swift` (`restoreFrame`), `ScrumTrace/UI/ShotNoteWindow.swift`
(`show()` centres on `NSScreen.main` today).

Only after D01–D07 and only with a Gate 0 re-check (Keynote full screen on the recorded display,
Shot window opening there, no focus steal). Both windows take the pinned display from the
controller; a usable saved HUD frame still wins; an absent screen falls back to today's behaviour
without any `NSApp.activate`.

---

## 3. Verify (Mac, two displays; not gate evidence)

1. Build with `bash scripts/mac_gate01.sh` only after checking the newest manifest and
   `~/Library/Logs/ScrumTrace/agent.jsonl` show no `processor_begin` without its `processor_ok`.
2. Menu → Capture area → Display → external. Start → overlay opens with the external screen as the
   key window → Return. `recorder_sckit_begin` shows `area=display`, `display=<external id>`, and
   `width`/`height`; the movie's size equals those logged values.
3. Overlay only: menu set to *Main display*, Start, click **Entire Display** on the external
   overlay. Same result.
4. Shot (Opt+Cmd+S) with the pointer on the built-in display: the PNG shows the external display.
5. Safari on the built-in display while recording the external one: `events.jsonl` has no URL or
   title rows for it; Safari on the external display is sampled as before. 1Password frontmost on
   the built-in display still pauses the recording.
6. Unplug the external, Start: the overlay shows "… is not connected. Pick a display."; Return on
   the built-in overlay records the built-in display. Replug: the menu lists it again; its id may
   differ, and the greyed old row disappears once a new display is chosen.
7. Unplug the external (a) between overlay confirm and the first frame, (b) while recording,
   (c) while paused. Expected: (a) "The chosen display is no longer connected" and no session
   folder; (b) and (c) the stream stops, the session is finalised through the existing error path,
   nothing from another display enters the movie. Record what actually happens.
8. Keynote full screen on the external display: Shot / Pin / Pause do not steal focus (Gate 0
   behaviour unchanged; the Shot window still opens on the main display until D08).
9. Single-window mode: unchanged (chooser, no overlay).

Hardware gates C1–C5 stay open; this is a capture-control change of the same class as single-window
mode, not gate evidence.

---

## 4. Decisions taken (were open questions in revision 1)

1. **Main display stays the default.** No behaviour change until you choose. "Main" means
   `CGMainDisplayID()` everywhere (resolver, overlay starter, menu label), not `NSScreen.main`.
2. **A missing saved display recovers through the overlay, not with a failed Start.** The recorder
   fails only in the confirm→start race. See §1.4.

---

## 5. Open questions for the user

None blocking. One preference: should the overlay's per-screen label include the point size
("DELL U2720Q · 2560×1440 pt") or only the name? Plan assumes name plus size.

---

## 6. Review log

**Revision 1 → 2 (Codex CLI `codex exec`, read-only, 2026-10-13; verdict "revise").** Verified
against the code and applied:

- Blocker: D02 resolved the display inside `recorder.start`, but the sampler gate had to be set
  before `privacy.start()`, which the contracts pin ahead of the recorder. Fixed by pinning the id
  in the controller from the overlay's result (§1.3).
- Blocker: name-based rematch could change the resolved id and turn a region into a whole-display
  recording through `regionFitsDisplay`. Rematch cut (§1.2); region cannot widen.
- Blocker: "missing display fails Start" contradicted the overlay flow, which always confirms a
  screen. One policy now (§1.4): overlay recovers, recorder fails only in the race.
- Blocker: safe target loss and region no-widening kept in scope; the plan now says that display
  choice limits screen capture only (§1.1).
- Return's outcome was right but the explanation was wrong: the full-screen branch of
  `area(from:)`, not a nil `proposedArea()`. D04 fixes that branch (and near-full-screen).
- "Effectively always the main display" softened to what the code does (`displays.first`).
- `ScreenSnap.crop`'s `?? image` whole-image fallback removed (D03).
- "Main display" defined once as `CGMainDisplayID()`; `NSScreen.main` no longer used for it.
- Display name is a label, not identity; duplicates get an index and position on the overlay.
- Sampler: coordinate space confirmed; region limitation stated; privacy pause explicitly global.
- `capture_width`/`capture_height` are the configured output size, not "display pixels".
- Contract updates move into each task; the specific strings the contracts pin are listed.
- Menu guard bug noted and fixed in D05 (*Main display* was disabled for every full-display area).
- `AppSettings` restore path tested with a real legacy blob; `display_name` forbidden in AgentLog.
- `ShotNoteWindow.show()` centres on `NSScreen.main`; HUD/Shot placement moved to optional D08
  behind a Gate 0 re-check.
- AGENTS.md: status paragraph, not a C2 edit.
- Unplug handling made explicit and added to §3 as measured, not asserted.

Raw review: the session scratchpad file `codex_review.md`.

---

## 7. Implementation notes (where the build differs from the task text)

- **One commit for D01–D06 plus contracts, one for docs**, instead of a commit per task: the tasks
  share files (`SessionController.swift` carries D02 and D03) and the tests cover them together.
- **D01:** `CaptureDisplayResolver` also owns `pinnedDisplayID(for:mainID:)`, `missingMessage` and
  `label(for:among:)` (menu rows; identical monitors get "1", "2"). `DisplayCandidate` carries the
  point size and `isMain`.
- **D02:** the resolver's candidates are built from ScreenCaptureKit's displays with names from the
  matching `NSScreen`. `recorder_sckit_begin` logs the pinned id; the configured size is logged in
  `start_ok` (`width`/`height`) because the size is only known after the stream is configured.
  `recorder_display_missing` is logged before the start fails.
- **D03:** `ScreenSnap.capture(area:displayID:)`; `crop` returns `CGImage?`. The Shot window is not
  moved (D08).
- **D04:** the overlay heading is drawn in the view ("▶ " marks the key overlay; others are dimmed),
  the missing-display notice in yellow under it. The key overlay redraws on `becomeKey`/`resignKey`.
  Helpers `starterIndex`, `screenLabel`, `missingDisplayNotice` are static on `CaptureAreaPicker`.
  `NSScreen.main` is no longer used anywhere in the picker; the contracts pin that.
- **D05:** `AppSettings.connectedDisplays` (assignable in tests), `refreshConnectedDisplays()`,
  `selectedDisplayID`, `selectDisplay(id:)`, `savedDisplayNotConnected`. The menu rebuilds on
  `NSApplication.didChangeScreenParametersNotification` unless it is open; Settings → Capture
  refreshes on the same notification. The menu test lives in `CaptureDisplayTests` (not
  `MenuAccessTests`); no Capture-tab snapshot variant was added to `MainWindowSnapshotTests`.
- **D06:** `MetadataSampler.restrictedDisplayID`, `windowIsOnDisplay`, `displayGateAllows` (pure,
  tested) and a private AX frame reader. The gate runs before and after the title/URL read; an
  unreadable frame fails the gate (app name only). The sampler is not otherwise injectable, so the
  AX path itself is covered by the §3 Mac check, not by a unit test.
- **D07:** `test_display_selection_never_widens()` in `scripts/test_contracts.py`; AGENTS.md
  snapshot date, Honest status paragraph, events line and Settings/Capture paragraph; README
  capture sentence.
