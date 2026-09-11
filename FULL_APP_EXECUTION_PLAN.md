# ScrumTrace — Full-App Completion Plan

This is the implementation queue for making the current `develop` branch work
end to end. It is intentionally explicit enough for a weaker coding model to
execute one task at a time without redesigning the product.

Source of truth: [IMPLEMENTATION_PLAN.md](IMPLEMENTATION_PLAN.md).  
Operator handbook: [AGENTS.md](AGENTS.md).  
Hardware evidence: [samples/GATE_LOG.md](samples/GATE_LOG.md).

## 0. Definition of done

The app is done only when all of the following are true:

1. `bash scripts/run_linux_tests.sh` passes.
2. `bash scripts/mac_xcode_test.sh` passes on macOS.
3. A stable, locally signed Debug app completes Gate −0, Gate 0, and Gate 1.
4. The same Mac completes Gates 3–6 in order.
5. `samples/GATE_LOG.md` contains real machine results and no invented cells.
6. A Release archive is signed, notarized, stapled, installed on a clean user
   account, and completes a short record-to-export smoke test.
7. Record remains available regardless of license state.
8. No private `archive/` asset appears in `export/`, the zip, provider payloads,
   diagnostics, or agent logs.
9. The v1 product improvements in Phase D are implemented: preflight and
   capture health, payload review and redaction, crash-safe processing,
   pre-export session review, export profiles, and searchable session history.
10. The complete branch receives both an automated diff review and a human
    review, with every accepted finding fixed and retested.
11. The release-candidate test in Phase F and the final installed/notarized
    acceptance test in TASK G03 pass after implementation and review. Earlier
    task tests do not replace these integrated runs.

Passing inspectors is supporting evidence, not hardware proof. A gate is not
closed until its manual checks are also recorded.

### V1 scope boundary

“Entire app” means the complete record → pause/annotate → process → review →
consent → export → install/update workflow described in this document. It does
not mean every possible future recorder feature.

Explicitly out of v1 unless `IMPLEMENTATION_PLAN.md` is revised first:

- speaker diarization;
- a 60-minute zero-drift claim;
- cloud accounts or hosted storage;
- team collaboration;
- mobile applications;
- live meeting bots;
- automatic code changes from meeting content.

This boundary prevents an implementing model from growing an unfinishable
backlog while claiming the app is incomplete.

## 1. Rules for the implementing model

Execute tasks in order. Complete one task and its tests before starting the
next.

- Work only on `develop`.
- Before editing: `git status --short`. Preserve unrelated user changes.
- Read every file named by the task before modifying it.
- Add or update tests in the same commit as behavior.
- Run the task-specific command, then `bash scripts/run_linux_tests.sh`.
- Commit each task separately with the exact proposed Conventional Commit
  subject.
- Push with `git push -u origin develop` and `git push github develop`.
- Never edit `samples/GATE_LOG.md` to add PASS without a real Mac run.
- Never weaken `scripts/test_contracts.py` to make a failure disappear.
- Never put titles, URLs, notes, transcripts, tokens, or API keys in
  `agent.jsonl`.
- Keep imports at the top of each module.
- Do not add dependencies for these tasks.
- Do not edit `ClockSynchronizer` in a recorder, UI, inspector, or docs commit.
- If clock math must change, stop and create a separate clock-only task and
  commit.
- Do not call `CGRequestScreenCaptureAccess` from Record.
- Do not add Sparkle SPM until dependencies resolve and tests pass on a Mac.
- Do not gate Record on license state.
- Do not merge, rebase, force-push, or touch GitHub `main`.

When a required Mac, permission, account, secret, or hardware artifact is
missing, report `BLOCKED` with the exact command and output. Do not substitute a
Linux result.

### Copy/paste prompt for each task

Give the implementing model exactly one task at a time:

```text
Implement TASK <ID> from FULL_APP_EXECUTION_PLAN.md.

Read AGENTS.md, IMPLEMENTATION_PLAN.md, and every file listed by the task.
Implement only that task. Preserve unrelated changes. Add every listed test.
Do not weaken existing tests or contracts. Do not edit GATE_LOG PASS cells.
Run the task verification commands and the full Linux suite. If a Mac,
permission, secret, or human check is required and unavailable, stop and report
BLOCKED with exact evidence. Otherwise commit with the task's exact commit
subject and push develop to origin and github.

Return:
1. changed files;
2. behavior implemented;
3. tests added;
4. exact command results;
5. remaining blockers;
6. commit SHA and push result.
```

Reject an implementation response that says “should work,” omits tests, changes
multiple task IDs, or calls a hardware gate passed without the named artifact.

### Testing policy

“Test at the end” means there is one comprehensive final test after all
implementation and code-review fixes. It does **not** mean skipping feedback
during development.

- Each implementation task adds and runs focused regression tests.
- Phase A runs Linux tests because it changes Python inspectors.
- Swift tasks compile and run targeted Xcode tests on a Mac before commit.
- Hardware gates are provisional evidence until the final integrated rerun.
- Phase E performs final code review after feature implementation.
- Phase F starts from a clean checkout and reruns the whole product as the
  release candidate before signing.
- TASK G03 is the final test at the end, using the distributed notarized app.
- A failure in Phase F or G03 reopens one focused implementation task, then
  requires the complete Phase E review and Phase F/G03 tests again.

## 2. Inspector result contract

All gate inspectors must emit JSON and use these exit codes:

| Exit | Meaning |
|---|---|
| `0` | All automated checks for this invocation passed |
| `1` | At least one automated check failed |
| `2` | Required artifacts or explicit human assertions are missing |

Every report must include:

```json
{
  "gate": "1",
  "status": "pass | fail | blocked | manual_required",
  "checks": {},
  "failed": [],
  "blocked_reasons": [],
  "manual_checks": []
}
```

`manual_required` uses exit `2`. `inspect_all_gates.py --strict` must fail for
both `blocked` and `manual_required`.

No inspector may write `samples/GATE_LOG.md`.

---

## Phase A — Make gate evidence trustworthy

### TASK A01 — Contain every export evidence path

**Problem:** `export_file_exists()` accepts traversal such as
`shots/../../outside.png`.

**Files**

- `scripts/gate_inspect_lib.py`
- `scripts/test_inspect_gates.py`
- `scripts/test_contracts.py`

**Implementation**

1. Replace `export_file_exists(session, rel)` with containment logic:
   - reject empty paths;
   - reject absolute paths;
   - reject NUL, newline, and carriage return;
   - normalize an optional leading `export/`;
   - reject every `..` component;
   - resolve the candidate and export root;
   - require `candidate.relative_to(export_root)` to succeed;
   - reject symlinks in the candidate or any component;
   - require a non-empty regular file.
2. Do not fall back to `session / rel`.
3. Keep one shared helper; Gates 5 and 6 must call it.

**Tests**

Add cases proving all of these are false:

- `../outside.png`
- `shots/../../outside.png`
- `/tmp/outside.png`
- `export/../archive/session.mp4`
- a symlink under `export/shots/` to an outside file
- a zero-byte file

Add one positive case for `shots/inside.png`.

**Verify**

```bash
python3 scripts/test_inspect_gates.py
bash scripts/run_linux_tests.sh
```

**Done when:** only a non-empty regular file contained under the real
`export/` root can satisfy evidence.

**Commit:** `fix: contain gate evidence under export`

---

### TASK A02 — Add an explicit gate-run log window

**Problem:** inspectors currently consume the entire persistent
`agent.jsonl`. Old events can pass or fail a new run.

**Files**

- `ScrumTrace/Capture/AgentLog.swift`
- `ScrumTrace/Processing/SessionController.swift`
- `ScrumTrace/Capture/SessionRecorder.swift`
- `scripts/gate_inspect_lib.py`
- `scripts/inspect_gate_minus0.py`
- `scripts/inspect_gate0_log.py`
- `scripts/inspect_gate2_shot.py`
- `scripts/inspect_gate5_provider.py`
- `scripts/inspect_all_gates.py`
- `scripts/mac_all_gates.sh`
- `scripts/test_inspect_gates.py`
- `scripts/test_contracts.py`

**Implementation**

1. Generate one random, non-secret `run_id` when the app process launches.
   Include it in every `AgentLog.event` row without changing individual call
   sites.
2. Add a process-safe current session context to `AgentLog`.
   `SessionController` sets it immediately after the session ID is created and
   clears it after stop/termination. Include `session` automatically in every
   event while context is set. Explicit event fields win only when equal;
   mismatches must be asserted in Debug and logged as a technical error.
3. Never include titles, URLs, notes, transcripts, tokens, or keys in either
   identifier.
4. Add `--log-start-line N` to every log-reading inspector.
5. Add a shared `read_jsonl_window(path, start_line)` helper.
   - Lines are one-based.
   - Reject negative values.
   - Exit `2` when the marker is beyond EOF.
6. Add `bash scripts/mac_all_gates.sh --begin`.
   - Verify macOS.
   - Create `~/Library/Logs/ScrumTrace/gate-run.json`.
   - Store current log line count + 1, UTC time, current `git rev-parse HEAD`,
     app CDHash, app `run_id` when available, machine name, macOS version, and
     chip.
   - Do not truncate or rewrite `agent.jsonl`.
7. Normal `mac_all_gates.sh` loads that marker and passes
   `--log-start-line` to all log inspectors.
8. `inspect_all_gates.py` must require `--log-start-line` whenever `--log` is
   supplied. Missing marker is exit `2`, not a whole-log fallback.
9. Session-aware inspectors must additionally infer `session_id` from
   `session.manifest.json` and require a matching log event where the event
   schema includes `session`.
10. Require one `run_id` throughout a gate window. Gate 0 remains run-window
    scoped because it intentionally happens outside a session.

**Tests**

- Old failing event before the marker is ignored.
- Old passing event before the marker cannot satisfy a new run.
- Matching event after the marker is used.
- Marker beyond EOF blocks.
- Missing marker blocks.
- A different session ID does not satisfy Gate −0 or Gate 5.
- Every app event receives the same process `run_id`.
- Session context appears after start and is absent after a clean stop.
- A session mismatch cannot silently overwrite context.

**Verify**

```bash
python3 scripts/test_inspect_gates.py
bash scripts/run_linux_tests.sh
```

**Done when:** no log-based result can be influenced by events before the
explicit gate-run marker or by another session.

**Commit:** `fix: scope gate logs to one run`

---

### TASK A03 — Make Gate −0 prove a 30-second capture

**Files**

- `scripts/inspect_gate_minus0.py`
- `scripts/test_inspect_gates.py`
- `samples/GATE_LOG.md`
- `README.md`

**Implementation**

Require:

1. `archive/`, `export/`, canonical manifest, MP4, WAV, events, and capture
   layout exist.
2. MP4 duration is at least 30.0 seconds.
3. WAV duration is at least 30.0 seconds.
4. MP4 and WAV durations differ by no more than 0.5 seconds.
5. Manifest `duration.media_seconds` is at least 30.0 and within 0.5 seconds of
   MP4 duration.
6. `wav_start_media_seconds` is a finite, non-negative number.
7. Scoped log has screen, audio, and WAV `recorder_first_sample`.
8. Scoped log has matching `start_ok`, `stop_capture_ok`, and no
   `capture_write_fail`, `capture_stream_failed`, `start_fail`, or
   `stop_capture_fail`.

If `ffprobe` is unavailable, return exit `2`; do not skip duration checks.

**Tests**

- 29.9 seconds fails.
- 30.0 seconds passes duration threshold.
- NaN, infinity, bool, negative WAV start fail.
- A missing first-sample type fails.
- A fatal recorder event after first samples fails.

Mock `ffprobe_duration` in unit-level tests or create tiny fixtures; do not add
large media files to git.

**Verify**

```bash
python3 scripts/test_inspect_gates.py
bash scripts/run_linux_tests.sh
```

**Done when:** a short or failed recording cannot pass Gate −0.

**Commit:** `fix: require a complete Gate minus zero capture`

---

### TASK A04 — Make Gate 0 require actual Keynote actions

**Files**

- `scripts/inspect_gate0_log.py`
- `scripts/mac_gate01.sh`
- `scripts/test_inspect_gates.py`
- `samples/GATE_LOG.md`

**Implementation**

Within the scoped log window require:

1. One `hotkey_shot`, one `hotkey_pin`, and one `hotkey_pause`.
2. A `hotkey_front` result for each action.
3. Every result has `app_active == "0"`.
4. `front == "com.apple.iWork.Keynote"` for each action.
5. Shot may become key, but `shot_window_key` must still show
   `app_active == "0"` and Keynote frontmost.
6. Pause has a corresponding `pause_ok` or `resume_ok`.
7. Pin has `pin_ok` while recording.
8. `mac_gate01.sh` fails unless:
   - bundle ID is `com.str8minds.ScrumTrace`;
   - `LSUIElement` is true;
   - signed entitlements do not contain `com.apple.security.app-sandbox=true`.
9. Preserve the existing Start-overlay sequencing checks.

An empty log or partial hotkey sequence must block or fail, never pass.

**Tests**

- Empty log blocks.
- All three actions over Keynote pass.
- Missing Pin blocks.
- Wrong frontmost bundle fails.
- `app_active=1` fails.
- Start without record-mode overlay fails.

**Verify**

```bash
python3 scripts/test_inspect_gates.py
bash scripts/run_linux_tests.sh
```

**Done when:** Gate 0 output proves the three requested actions happened during
the marked Keynote run and shows no observable focus steal.

**Commit:** `fix: require complete Gate zero hotkey evidence`

---

### TASK A05 — Separate Gate 1 automation from human media proof

**Problem:** `strings` cannot detect text rendered in video or speech encoded
in PCM/AAC.

**Files**

- `scripts/inspect_gate1_session.py`
- `scripts/inspect_all_gates.py`
- `scripts/mac_all_gates.sh`
- `scripts/test_inspect_gates.py`
- `samples/GATE_LOG.md`
- `README.md`

**Implementation**

1. Keep ASCII scans as leak diagnostics, not proof of visual/audio absence.
2. Rename checks so they say `no_ascii_*`, never `missing_*` for media.
3. Add required CLI arguments for final Gate 1:
   - `--manual-video-scrub-ok`
   - `--manual-audio-scrub-ok`
   - `--av-offset-ms VALUE`
   - `--ptt-temp-deleted-ok`
4. Without all four, automated checks may succeed but status must be
   `manual_required`, exit `2`.
5. Reject non-finite or negative offset. Offset above 50 ms fails the current
   target row but error copy must call it a measured target, not a guarantee.
6. Require exactly or at least three closed pauses and at least 1,200 seconds
   of media.
7. Require pause durations to be finite, positive, and consistent with
   `resume_wall - pause_wall` within 10 ms.
8. Require media duration to approximately equal wall duration minus summed
   pause duration.
9. Remove `--shot-before-pause`; Shot behavior belongs to scoped log evidence
   in Task A06. A filename set cannot distinguish a valid post-resume Shot.
10. Continue scanning transcript, events, loose export text, and every ZIP text
    member for token/passphrase.

**Tests**

- Automated artifact checks plus no human flags returns exit `2`.
- Four human assertions plus valid artifacts returns `0`.
- Offset 50 passes; 50.1 fails.
- Two pauses fail.
- Open pause fails.
- Inconsistent pause duration fails.
- A token in a deflated ZIP text member fails.

**Verify**

```bash
python3 scripts/test_inspect_gates.py
bash scripts/run_linux_tests.sh
```

**Done when:** aggregate output can never label Gate 1 passed without explicit
human media checks and offset measurement.

**Commit:** `fix: require manual evidence for Gate one`

---

### TASK A06 — Require every paused action in Phase 2 evidence

**Files**

- `scripts/inspect_gate2_shot.py`
- `scripts/test_inspect_gates.py`
- `ScrumTrace/Processing/SessionController.swift` only if an event lacks the
  technical fields needed below
- `ScrumTrace/UI/ShotNoteWindow.swift` only if an event lacks the technical
  fields needed below

**Implementation**

Within one scoped pause window require:

1. A Shot attempt and `shot_ignored`/`shot_fail` with `reason=paused`.
2. A Pin attempt and `pin_ignored` with `reason=paused`.
3. A Hold-to-Talk attempt and `talk_start_fail reason=paused`, **or** an
   in-flight `talk_press` before Pause followed by `talk_abort` before Resume.
4. No `shot_begin` or `shot_save` during Pause.
5. No `pin_ok` during Pause.
6. No `talk_transcribe_begin`, `talk_transcribe_ok`, or persisted voice-note
   result for a paused attempt.
7. At least one normal Shot save before or after Pause, proving Shot was
   generally functional.

Use event order, not wall-clock parsing, unless all events already provide the
same monotonic timestamp.

If product logging changes, log only action, reason, session ID, booleans, and
numeric timing. Never log note or transcript content.

**Tests**

- Pause with no attempts blocks.
- Each missing required action blocks.
- Refused Shot + Pin + PTT passes.
- In-flight PTT abort passes.
- `shot_save`, `pin_ok`, or transcription during Pause fails.

**Verify**

```bash
python3 scripts/test_inspect_gates.py
bash scripts/run_linux_tests.sh
```

On Mac after implementation:

```bash
bash scripts/mac_xcode_test.sh
```

**Done when:** Phase 2 cannot pass from a pause that did not exercise all three
capture controls.

**Commit:** `fix: require paused capture attempts in Gate two`

---

### TASK A07 — Make Gate 3 reject incomplete transcription

**Files**

- `scripts/inspect_gate3_whisper.py`
- `scripts/test_inspect_gates.py`

**Implementation**

Require:

1. Valid capture layout exists.
2. `whisper_incomplete` is exactly `false`.
3. `whisper_wall_seconds` is finite and greater than zero.
4. Transcript has non-empty segments and non-empty `sources`.
5. `timing.whisper_sources` equals transcript `sources` as a set.
6. If `microphone_wav` is true, `room` is present.
7. If `system_audio_in_movie` is true, `system` is present.
8. If both are true, both are present.
9. Timing file is absent from `export/` and every ZIP member.
10. The 5-minute `<20 s` value remains a recorded target. Add optional
    `--target-media-seconds` and `--target-wall-seconds`; without the named
    target run, status is `manual_required` for that row.

**Tests**

- Missing layout blocks.
- Incomplete true fails.
- Missing expected source fails.
- Timing/transcript source mismatch fails.
- Zero, negative, NaN, infinity wall time fail.
- Archive timing leaked in ZIP fails.

**Verify**

```bash
python3 scripts/test_inspect_gates.py
bash scripts/run_linux_tests.sh
```

**Done when:** a surviving single pass may support Retry Analysis, but can
never close Gate 3.

**Commit:** `fix: fail Gate three on incomplete transcription`

---

### TASK A08 — Tie Gate 4 measurements to real files

**Files**

- `scripts/inspect_gate4_slicer.py`
- `scripts/test_inspect_gates.py`

**Implementation**

Require:

1. One through twelve slices.
2. Every slice range is finite, non-negative, ordered, and no longer than
   25 seconds.
3. At least one contained, non-empty exported clip exists.
4. `ffprobe` succeeds for that clip.
5. Primary clip is H.264, 1280×720; record profile and audio codec in output.
6. `export/session-pack.zip` exists and is a valid ZIP.
7. `pipeline-timing.json.zip_bytes` is a positive integer.
8. Timing `zip_bytes == stat(session-pack.zip).st_size`.
9. Optional `--chrome-playback-ok` is required to close the manual playback
   row. Without it, return `manual_required`.

**Tests**

- 13 slices fail.
- Empty slices block.
- 25.0 seconds passes; 25.001 fails.
- Negative and NaN times fail.
- Negative/stale/mismatched `zip_bytes` fail.
- Missing or corrupt clip fails.
- Missing Chrome assertion returns exit `2`.

**Verify**

```bash
python3 scripts/test_inspect_gates.py
bash scripts/run_linux_tests.sh
```

**Done when:** Gate 4 reports measured values from the selected session, not
merely numeric manifest fields.

**Commit:** `fix: verify Gate four media measurements`

---

### TASK A09 — Split Gate 5 into four explicit scenarios

Gate 5 cannot be proven by one session. It requires separate consent-denied,
invalid-key, retired-model, and evidence-validation scenarios.

**Files**

- `scripts/inspect_gate5_provider.py`
- `scripts/inspect_all_gates.py`
- `scripts/mac_all_gates.sh`
- `scripts/test_inspect_gates.py`
- `samples/GATE_LOG.md`
- `README.md`

**Implementation**

Replace the current single-session Gate 5 result with these subcommands:

```text
inspect_gate5_provider.py denied --session PATH --log PATH --log-start-line N
inspect_gate5_provider.py invalid-key --session PATH --log PATH --log-start-line N
inspect_gate5_provider.py retired-model --session PATH --log PATH --log-start-line N
inspect_gate5_provider.py evidence --session PATH
```

Requirements:

**Denied**

- manifest records a denied consent with provider, endpoint, model;
- scoped log has matching `consent_result approved=0`;
- no `eval_slice` or provider-call event follows;
- local export documents and zip still exist.

**Invalid key**

- consent was approved for the named test destination;
- deliberately invalid/empty credential causes no crash;
- pipeline or slices become `offline_failed`/`needs_review`;
- export documents still exist;
- no task is incorrectly `confirmed`.

**Retired model**

- provider is Anthropic;
- model matches the retired-ID rule;
- no `eval_slice`/network provider-call event occurs;
- local export remains usable.

**Evidence**

- at least one task is present;
- every confirmed task has confidence ≥ 0.55;
- every confirmed task has contained, non-empty export evidence;
- every confirmed quote has valid numeric times, lies inside its source slice,
  overlaps transcript time, and normalized text is present;
- failed quotes are represented only by `needs_review`;
- inferred text alone cannot establish confirmation.

The all-gates runner accepts four named Gate 5 session directories. If any is
missing, Gate 5 is blocked.

**Tests**

Add positive and negative fixture tests for every scenario. Specifically cover
empty task lists, empty transcript, missing quotes, traversal evidence, old log
events, and provider/model mismatch.

**Verify**

```bash
python3 scripts/test_inspect_gates.py
bash scripts/run_linux_tests.sh
```

**Done when:** Gate 5 cannot pass vacuously or from one happy-path session.

**Commit:** `fix: require all Gate five provider scenarios`

---

### TASK A10 — Validate the actual Gate 6 ZIP and projection

**Files**

- `scripts/gate_inspect_lib.py`
- `scripts/inspect_gate6_pack.py`
- `scripts/test_inspect_gates.py`
- `ScrumTraceTests/ContractTests.swift`

**Implementation**

1. Replace `zip_names()` with a result that distinguishes:
   - missing;
   - valid;
   - corrupt/unreadable.
2. Require a valid ZIP containing:
   - `AGENT_CONTEXT.md`;
   - `SESSION_BRIEF.html`;
   - `AGENT_PROMPT.txt`;
   - `session.manifest.json`.
3. Reject ZIP members that are:
   - absolute;
   - contain `..`;
   - contain `archive` as a path component;
   - `pipeline-timing.json`;
   - symbolic links;
   - outside the explicit document + optional transcript + `shots/` +
     `media/` allow-list.
4. Require actual ZIP size ≤ 35 MiB.
5. Require positive timing `zip_bytes` exactly equal to actual size.
6. Compare canonical `omitted[]`, projected `omitted[]`, timing
   `omitted_count`, and `OMITTED.md`.
7. Normalize canonical `export/foo` paths to `foo` before matching
   `OMITTED.md`.
8. Require `OMITTED.md` iff omissions exist and require every omitted path and
   reason to be represented.
9. Parse every media link emitted by `AGENT_CONTEXT.md`; require contained,
   non-empty export files.
10. Require the export manifest to contain no `archive/` path values.
11. Add a purpose-built HTML escaping test session containing `& < > "` in
    every user-controlled field. Do not call “no special characters present”
    an escaping pass.
12. Add a Swift test using the real `SessionPackZipper`, not only the Python
    mirror, for an oversized 8-clip/20-shot fixture. Assert ≤ 35 MiB and named
    omissions.

**Tests**

- Missing and corrupt ZIP fail.
- Traversal, absolute, archive, timing, and symlink members fail.
- Missing required document fails.
- Timing mismatch fails.
- Omission count/path/reason mismatch fails.
- Broken Markdown media path fails.
- Unescaped HTML fixture fails.
- Valid pack passes.

**Verify**

```bash
python3 scripts/test_inspect_gates.py
bash scripts/run_linux_tests.sh
```

On Mac:

```bash
bash scripts/mac_xcode_test.sh
```

**Done when:** Gate 6 validates the bytes actually handed to an agent.

**Commit:** `fix: validate the complete Gate six pack`

---

### TASK A11 — Make the aggregate honest and deterministic

**Files**

- `scripts/inspect_all_gates.py`
- `scripts/mac_all_gates.sh`
- `scripts/test_inspect_gates.py`
- `scripts/test_contracts.py`

**Implementation**

1. Aggregate subprocess output using the explicit inspector result contract.
2. Treat malformed/non-JSON inspector output as failure.
3. Treat unexpected exit codes as failure.
4. `--strict` succeeds only when all requested gates are `pass`.
5. Preserve the required order: −1, −0, 0, 1, 2, 3, 4, 5, 6.
6. Stop after Gate −0 failure when running the guided Mac workflow.
7. Stop before Gates 3–6 unless Gate 1 is passed from a named artifact.
8. Print exact next actions for blocked/manual rows.
9. Never include secret values or captured content in aggregate output.
10. Never write `GATE_LOG.md`.

**Tests**

- Child exit 0 + malformed JSON fails.
- Child exit 2 is blocked.
- `--strict` fails on blocked/manual.
- Gate −0 failure prevents later execution.
- Gate 1 blocked prevents 3–6.
- All synthetic passes return zero.

**Verify**

```bash
python3 scripts/test_inspect_gates.py
bash scripts/run_linux_tests.sh
```

**Done when:** one command cannot overstate the state of any gate.

**Commit:** `fix: make all-gate results fail closed`

---

## Phase B — Compile and exercise the real app

Do not begin this phase until Phase A is merged on `develop`.

### TASK B01 — Mac compile and Xcode tests

**No code changes unless the command fails.**

```bash
cd ~/development/scrumtrace
git checkout develop
git pull --ff-only origin develop
bash scripts/mac_xcode_test.sh
bash scripts/mac_gate01.sh
```

**Pass criteria**

- Swift app compiles in Debug.
- All `ScrumTraceTests` pass.
- Stable app exists at `~/Applications/ScrumTrace.app`.
- Signature identifier is `com.str8minds.ScrumTrace`.
- Local `ScrumTrace Debug` identity is used.
- App Sandbox is off.

If compilation fails, create one focused fix commit. Do not combine compile
fixes with runtime behavior.

---

### TASK B02 — Fresh TCC and Gate −0

**Operator steps**

```bash
pkill -x ScrumTrace || true
launchctl bootout gui/$(id -u)/com.str8minds.ScrumTrace.agentloop 2>/dev/null || true
bash scripts/mac_all_gates.sh --begin
open -n ~/Applications/ScrumTrace.app
```

1. Grant Screen Recording and Microphone to that stable app.
2. Relaunch. Do not rebuild after granting.
3. Record at least 31 seconds with visible motion, system audio, and microphone.
4. Stop and wait for local processing.
5. Run the Gate −0 inspector for that exact session and marker.

**Pass criteria**

- Gate −0 automated checks pass.
- Manual playback confirms picture, system audio, and microphone.
- No capture/write/start/stop fatal event exists in the scoped log.

If this fails, stop. Do not run Gate 0 or Gate 1.

---

### TASK B03 — Gate 0 over full-screen Keynote

1. Start a short recording so Pin has a valid timeline.
2. Enter full-screen Keynote.
3. Press Shot, Pin, and Pause hotkeys once each.
4. Confirm Keynote remains visually frontmost after each.
5. Resume and stop.
6. Run Gate 0 against the saved run marker.

**Pass criteria**

- Automated Gate 0 checks pass.
- Human confirms no focus steal.
- HUD pause state changes amber.
- Menu bar extra remains present.

Record machine evidence in `samples/GATE_LOG.md`.

---

### TASK B04 — Gate 1 all-source pause and drift

Use token `ST-G1-PAUSE-TOKEN-9F3C` and passphrase
`orchid lantern seven`.

1. Begin a new marked gate run.
2. Record at least 20 minutes of **media time**.
3. Make exactly three or more pauses.
4. During one pause:
   - display the token;
   - speak the passphrase into the mic;
   - play the token through system audio;
   - press Shot;
   - press Pin;
   - try Hold-to-Talk;
   - also test one in-flight Hold-to-Talk aborted by Pause.
5. Resume, make one normal Shot, and stop.
6. Scrub video and audio around all pause boundaries.
7. Measure A/V offset at 20 minutes.
8. Confirm the temporary Hold-to-Talk WAV was deleted.
9. Run Gate 1 and Phase 2 inspectors with explicit human assertions.

**Pass criteria**

- Token absent from visible recorded frames during Pause.
- Token/passphrase absent from captured audio and transcript.
- No new paused Shot, Pin, metadata, or voice note persisted.
- At least three closed pauses.
- Media time ≥ 1,200 seconds.
- Measured A/V offset ≤ 50 ms target.
- Automated Gate 1 and Phase 2 checks pass.

Commit only the factual Gate log update:

`docs: record Gate one Mac results`

Do not continue if Gate 1 fails.

---

## Phase C — Complete the local processing pipeline

### TASK C01 — Gate 3 WhisperKit

Use the Gate 1 session plus a separate warm five-minute session.

1. In Settings, preload
   `openai_whisper-large-v3-v20240930_turbo_632MB`.
2. Confirm the folder exists on disk.
3. Process microphone WAV and movie system audio.
4. Run Gate 3 inspector.
5. Record:
   - machine;
   - model directory;
   - media seconds;
   - `whisper_wall_seconds`;
   - transcript sources;
   - whether it met the `<20 s` target.

**Pass criteria**

- `whisper_incomplete=false`.
- Sources include `room` and `system` when both were captured.
- Segments are non-empty and use `t_media`.
- Timing file remains archive-only.
- Retry Analysis succeeds after a recoverable interrupted processing run.

---

### TASK C02 — Gate 4 slicer

Use a session with speech, at least one Pin, and at least one Shot.

**Pass criteria**

- One to twelve windows.
- Every window ≤ 25 seconds.
- At least one exported H.264 1280×720 clip with AAC audio.
- Clip plays directly in Chrome.
- Timing bytes exactly match the current zip file.
- Working media remains under `archive/media-work/`.

---

### TASK C03 — Gate 5 provider scenarios

Create four disposable sessions or copies as required by Task A09.

1. Deny consent.
2. Approve consent with an invalid key.
3. Select a retired Anthropic ID.
4. Run one valid OpenAI-compatible evaluation with a user-provided key.

Never commit keys or provider responses containing captured content.

**Pass criteria**

- Denial sends no provider request and still writes local export.
- Invalid key causes no crash and yields structured offline/review state.
- Retired Anthropic model is refused before network evaluation.
- Valid provider output is schema-valid.
- Confirmed tasks satisfy all evidence rules.
- Failed quotes are demoted to `needs_review`.

---

### TASK C04 — Gate 6 normal and stress packs

1. Run the normal Gate 1 session through final export.
2. Run a stress session with 8 candidate clips and 20 Shots.
3. Open `SESSION_BRIEF.html`.
4. Drop `export/` into a clean Cursor workspace.
5. Inspect and unzip `session-pack.zip`.

**Pass criteria**

- Finder reveals `export/`, never `archive/`.
- Zip ≤ 35 MiB by actual file size.
- Zip and export use only the explicit allow-list.
- Omitted assets are named consistently.
- Every `AGENT_CONTEXT.md` media path opens.
- Special characters render as text, not markup.
- Archive originals survive all pack omissions.
- Stress pack remains under cap.

Commit only factual Gate 3–6 evidence:

`docs: record processing gate results`

---

## Phase D — Finish the v1 product experience

Do not begin new product surfaces until the core Gate 1 and Gates 3–6 have
passed once on a Mac. These tasks improve the proven pipeline; they do not
replace it. After Phase D, all gates must be rerun in Phase F.

### TASK D01 — Add a capture preflight panel

The user must be able to see whether a recording can work before opening the
selection overlay.

**Files**

- `ScrumTrace/Capture/CapturePermissions.swift`
- `ScrumTrace/Processing/SessionController.swift`
- `ScrumTrace/UI/MenuBarController.swift`
- `ScrumTrace/UI/SettingsView.swift`
- new `ScrumTrace/UI/CapturePreflightView.swift`
- new `ScrumTraceTests/CapturePreflightTests.swift`

**Implementation**

1. Create a pure `CapturePreflightSnapshot` value containing:
   - current stable app identity/CDHash;
   - Screen Recording state and relaunch requirement;
   - microphone state when microphone capture is enabled;
   - selected display/region availability;
   - free bytes at the sessions volume;
   - configured archive quality;
   - whether a live recording already owns `recording.lock`.
2. Create a pure evaluator returning `ready`, `warning`, or `blocked` plus
   ordered reasons.
3. Show the snapshot from Menu and Settings without starting capture.
4. Provide explicit buttons for requesting Screen Recording, opening Screen
   Settings, opening Microphone Settings, and Relaunch.
5. Never request Screen Recording or open Settings from `startRecording()`.
6. Record remains one click away when snapshot is ready.
7. Use real copy; explain exactly what is missing and whether a relaunch is
   required.
8. Cover loading, ready, warning, and blocked states.

**Tests**

- Screen denied blocks.
- Current launch granted but launch snapshot denied requires relaunch.
- Disabled microphone does not require microphone permission.
- Enabled microphone denied blocks.
- Missing display blocks.
- Low disk is a warning at the warning threshold and blocked at the hard
  threshold.
- Stale dead-PID lock does not block; live lock blocks.
- `startRecording()` contains no permission request.

**Verify**

```bash
bash scripts/mac_xcode_test.sh
bash scripts/run_linux_tests.sh
```

**Done when:** a user can diagnose capture readiness without attempting Record.

**Commit:** `feat: add recording preflight`

---

### TASK D02 — Add capture health to the HUD

**Files**

- `ScrumTrace/Capture/SessionRecorder.swift`
- `ScrumTrace/Processing/SessionController.swift`
- `ScrumTrace/UI/RecordingHUDWindow.swift`
- `ScrumTrace/Storage/SessionModels.swift`
- new `ScrumTraceTests/CaptureHealthTests.swift`

**Implementation**

1. Define a `CaptureHealthSnapshot` value with:
   - last screen sample age;
   - last system-audio sample age;
   - last microphone sample age when enabled;
   - writer state;
   - bytes written for MP4/WAV;
   - remaining disk bytes;
   - latest non-sensitive technical warning.
2. Update health from capture queues without blocking them.
3. Coalesce UI publication to at most four updates per second.
4. HUD states:
   - healthy: quiet green indicator;
   - warning: amber source name;
   - fatal: red, capture stops safely, error remains visible.
5. Never place sample content, application metadata, or file-system home paths
   in health logs.
6. Pause freezes expected source ages and must not produce false warnings.
7. Disabled microphone must not appear unhealthy.

**Tests**

- Fresh samples are healthy.
- Missing screen/system/mic sample crosses warning threshold.
- Paused state suppresses age warnings.
- Disabled mic is ignored.
- Writer failure becomes fatal once.
- Repeated warning updates are coalesced.
- Health transition does not alter clock or pause math.

**Verify**

```bash
bash scripts/mac_xcode_test.sh
bash scripts/run_linux_tests.sh
```

**Done when:** a user knows during recording whether every enabled source is
still being persisted.

**Commit:** `feat: show capture health in the HUD`

---

### TASK D03 — Add payload preview and privacy redaction

Consent must show the actual outbound payload, and the user must be able to
remove sensitive items before any network request.

**Files**

- `ScrumTrace/Processing/SessionController.swift`
- `ScrumTrace/Processing/SessionProcessor.swift`
- `ScrumTrace/AI/AIProviderProtocol.swift`
- `ScrumTrace/AI/ProviderWireMedia.swift`
- `ScrumTrace/Export/ExportProjector.swift`
- `ScrumTrace/Storage/SessionModels.swift`
- new `ScrumTrace/UI/UploadReviewWindow.swift`
- new `ScrumTraceTests/UploadReviewTests.swift`
- new `ScrumTraceTests/ProviderRequestTests.swift`

If protocol files have different names, locate the existing declarations with
`rg 'AIProviderProtocol|ProviderWireMedia' ScrumTrace` and edit those files; do
not create duplicate types.

**Implementation**

1. Build a deterministic `OutboundPayloadPlan` before consent:
   - provider, endpoint origin, model;
   - exact still paths and byte counts;
   - exact clip paths, byte counts, audio/video inclusion;
   - transcript excerpt character count;
   - metadata field names;
   - total planned bytes.
2. Display thumbnails and filenames from `export/` only.
3. Let the user exclude individual stills/clips, all clip audio/video, transcript
   excerpts, window metadata, Shot notes, and product context.
4. Add rectangular image redaction. Save a redacted export copy; never alter
   archive originals.
5. Re-run evidence validation after exclusions/redactions. Demote tasks whose
   evidence was removed.
6. Persist the approved payload fingerprint and inclusion flags in canonical
   consent. Do not persist captured text in the fingerprint.
7. Immediately before the provider call, rebuild the plan and require the
   fingerprint to match. A mismatch requires new consent.
8. Cancel always produces local export and zero provider requests.

**Tests**

- Every displayed item equals an actual planned request part.
- Exclusion removes bytes from the request.
- Redaction changes only the export derivative.
- Removed evidence demotes confirmation.
- Payload mutation after consent blocks the request.
- Denial produces zero mocked network requests.
- Endpoint, model, or capability change requires new consent.
- No archive master path enters a request.

Use `URLProtocol` or the existing injectable transport. Never hit a live
provider in automated tests.

**Verify**

```bash
bash scripts/mac_xcode_test.sh
bash scripts/run_linux_tests.sh
```

**Done when:** the user can inspect and reduce the exact outbound payload before
approval, and approval is bound to those exact bytes.

**Commit:** `feat: add upload payload review`

---

### TASK D04 — Make processing crash-safe and resumable

This task resumes post-recording processing. It does not claim seamless
continuation of an interrupted ScreenCaptureKit recording.

**Files**

- `ScrumTrace/Processing/SessionProcessor.swift`
- `ScrumTrace/Processing/SessionController.swift`
- `ScrumTrace/Storage/SessionVault.swift`
- `ScrumTrace/Storage/SessionModels.swift`
- `ScrumTrace/UI/MenuBarController.swift`
- new `ScrumTraceTests/ProcessingRecoveryTests.swift`

**Implementation**

1. Give every processing stage explicit states:
   `pending`, `running`, `completed`, `failed`.
2. Persist stage start, finish, attempt count, and sanitized technical error
   atomically in the canonical manifest.
3. On launch, convert stale `running` stages to `failed/retryable`.
4. Compute stage input fingerprints from file identity, size, and modification
   time—not captured text.
5. Reuse a completed stage only when its outputs exist, are non-empty, are
   contained, and its input fingerprint still matches.
6. Retry from the first invalid/incomplete stage. Do not repeat provider calls
   after an ambiguous crash unless a request idempotency key proves safety or
   the user approves retry.
7. Preserve the existing consent only when destination and payload fingerprint
   still match.
8. Surface Recover Session and Discard Session for unfinished processing.
9. Never delete archive media when discarding generated processing output.

**Tests**

- Crash after each stage start resumes from that stage.
- Missing output invalidates a completed stage.
- Changed input invalidates dependent stages.
- Completed transcription is reused.
- Ambiguous provider call blocks for user decision.
- Changed payload requires consent again.
- Corrupt canonical manifest is preserved and surfaced, not overwritten.
- Archive files survive discard/retry.

**Verify**

```bash
bash scripts/mac_xcode_test.sh
bash scripts/run_linux_tests.sh
```

**Done when:** killing the app during any post-recording stage cannot silently
lose the session or duplicate a network side effect.

**Commit:** `feat: resume interrupted session processing`

---

### TASK D05 — Add pre-export session review

**Files**

- `ScrumTrace/Processing/SessionController.swift`
- `ScrumTrace/Processing/SessionProcessor.swift`
- `ScrumTrace/Storage/SessionModels.swift`
- `ScrumTrace/Slicing/ClipExporter.swift`
- `ScrumTrace/Export/ExportProjector.swift`
- new `ScrumTrace/UI/SessionReviewWindow.swift`
- new `ScrumTraceTests/SessionReviewTests.swift`

**Implementation**

1. After local transcription/slicing and before consent/provider evaluation,
   show one review window with:
   - slice timeline;
   - clip preview;
   - still/Shot preview;
   - transcript excerpt;
   - task/review status;
   - measured projected bytes.
2. Permit:
   - remove a slice from export;
   - adjust slice start/end inside media bounds and ≤ 25 seconds;
   - remove a still from export;
   - edit typed Shot notes;
   - mark a candidate `needs_review`;
   - return to the payload review.
3. Never edit master MP4/WAV/full transcript/raw events.
4. Every edit invalidates only dependent generated stages.
5. Re-export and remeasure after edits.
6. Provide explicit Cancel Review (keep local archive) and Build Export.
7. Support keyboard navigation, VoiceOver labels, and visible focus.

**Tests**

- Trim bounds and 25-second cap.
- Removal keeps archive source.
- Changed note is escaped in HTML/Markdown.
- Evidence removal demotes confirmation.
- Byte estimate refreshes after edit.
- Cancel performs no upload.
- Stage invalidation is minimal and deterministic.

**Verify**

```bash
bash scripts/mac_xcode_test.sh
bash scripts/run_linux_tests.sh
```

**Done when:** users control what enters the final handoff without touching the
private archive.

**Commit:** `feat: add pre-export session review`

---

### TASK D06 — Add export profiles

Profiles change presentation and optional media inclusion, never archive
privacy or the 35 MiB limit.

**Files**

- `ScrumTrace/App/AppSettings.swift`
- `ScrumTrace/Storage/SessionModels.swift`
- `ScrumTrace/Export/ExportProjector.swift`
- `ScrumTrace/Export/SessionPackZipper.swift`
- `ScrumTrace/Export/AgentContextRenderer.swift`
- `ScrumTrace/UI/SessionReviewWindow.swift`
- new `ScrumTraceTests/ExportProfileTests.swift`

**Implementation**

Define exactly three profiles:

1. `coding_agent`: Markdown + manifest + evidence; clips included only when
   referenced and within budget.
2. `web_chat`: prompt + selected images + zip; copy explains that ZIP video
   interpretation is not assumed.
3. `human_review`: HTML brief + playable selected clips + evidence.

All profiles:

- project from the same canonical manifest;
- use export-relative paths;
- enforce the same allow-list and cap;
- list omissions;
- never include archive masters or raw events;
- re-run evidence validation after projection.

Do not add provider-specific prompt instructions that treat meeting speech as
commands.

**Tests**

- Golden manifest projection for each profile.
- No archive paths or files.
- All referenced paths exist.
- Cap and omission behavior are identical.
- Untrusted-data wrapping and HTML escaping remain present.

**Verify**

```bash
bash scripts/mac_xcode_test.sh
bash scripts/run_linux_tests.sh
```

**Done when:** each target gets an honest, bounded handoff without duplicating
the processing pipeline.

**Commit:** `feat: add bounded export profiles`

---

### TASK D07 — Add searchable session history

**Files**

- `ScrumTrace/Storage/SessionVault.swift`
- `ScrumTrace/Storage/SessionModels.swift`
- `ScrumTrace/UI/MenuBarController.swift`
- new `ScrumTrace/UI/SessionHistoryWindow.swift`
- new `ScrumTraceTests/SessionHistoryTests.swift`

**Implementation**

1. Build the index locally from canonical manifests. Do not add a database.
2. Index only:
   - session ID;
   - created date;
   - product app name;
   - pipeline status;
   - duration;
   - counts of shots/slices/tasks;
   - export availability.
3. Do not index transcript text, Shot notes, window titles, URLs, or provider
   responses.
4. Search by date, app name, session ID, and status.
5. Filter incomplete, needs-review, completed, and failed sessions.
6. Actions: Review, Retry/Recover, Reveal export, Reveal archive with explicit
   privacy warning, Delete.
7. Delete requires confirmation, rejects path escapes/symlinks, and updates the
   view atomically.
8. Corrupt manifests appear as recoverable rows rather than crashing history.

**Tests**

- Sorting and filters.
- Allowed-field search.
- Sensitive text is not searchable.
- Corrupt manifest row.
- Symlink/path-escape deletion refusal.
- Delete confirmation and refresh.
- Empty and loading states.

**Verify**

```bash
bash scripts/mac_xcode_test.sh
bash scripts/run_linux_tests.sh
```

**Done when:** users can find and recover local sessions without exposing
captured content to a new index.

**Commit:** `feat: add private session history`

---

## Phase E — Code review and product audit

Phase E happens after all implementation tasks. Do not start the final test with
unresolved review findings.

### TASK E01 — Automated branch review

Use the commit immediately before TASK A01 as the fixed comparison point.

Run two independent reviews:

1. **Standards review**
   - `AGENTS.md`;
   - workspace rules;
   - privacy/logging rules;
   - code smells and duplicated logic.
2. **Spec review**
   - `IMPLEMENTATION_PLAN.md`;
   - this plan;
   - `samples/GATE_LOG.md`;
   - required states and negative paths.

Also run a dedicated security review of:

- export containment;
- ZIP member validation;
- provider side effects and consent;
- HTML/Markdown injection;
- diagnostics and logs;
- file deletion and symlinks;
- credentials and signing material.

**Output**

Create `FINAL_REVIEW.md` containing only:

- comparison base and reviewed HEAD;
- finding severity;
- exact file/line;
- reproduction or failing test;
- disposition: accepted, rejected with reason, or blocked.

Do not copy captured content or secrets into the review.

---

### TASK E02 — Fix accepted review findings

For each accepted finding:

1. Write or expose a failing regression test.
2. Make one focused fix.
3. Run focused tests.
4. Commit separately.
5. Update finding disposition with commit SHA.

After all fixes, rerun the automated reviews against the new HEAD. Repeat until:

- zero critical/high findings;
- every medium finding is fixed or has a specific documented reason;
- no blocked security finding remains.

Do not suppress a finding by weakening an inspector or test.

---

### TASK E03 — Human review checkpoint

Provide the human reviewer:

- commit range;
- `FINAL_REVIEW.md`;
- changed architecture summary;
- test inventory;
- known limitations;
- privacy data-flow summary;
- screenshots of every new window/state;
- current factual gate log.

The human must explicitly approve:

- v1 scope is complete;
- consent copy matches actual payload;
- archive/export boundary;
- destructive actions;
- accessibility and keyboard flow;
- release candidate is ready for final testing.

Record approval as a dated note in `FINAL_REVIEW.md`. This is not a gate PASS.

---

## Phase F — Clean release-candidate integrated test

Run this only after all implementation and review fixes are committed and
pushed. It qualifies the bits that Phase G signs. TASK G03 remains the final
end test on the installed notarized artifact.

### TASK F01 — Clean checkout and automated test matrix

On Linux and a Mac, clone `develop` into new directories. Do not reuse build
products, generated mock media, DerivedData, app installation, or TCC state.

Run:

```bash
bash scripts/run_linux_tests.sh
python3 scripts/inspect_all_gates.py --mock-only
bash scripts/mac_xcode_test.sh
```

Then verify:

- Debug build;
- Release build;
- zero compiler errors;
- zero test failures;
- no unexpected warnings introduced by this branch;
- deterministic mock export regeneration;
- clean `git status --short`.

Save command output as review artifacts outside the repository unless it is
short, sanitized, and intentionally committed.

---

### TASK F02 — Fresh-user functional walkthrough

Use a separate macOS user account or a clean test machine.

Walk every shipped surface:

1. First launch and onboarding.
2. Screen and microphone permission buttons.
3. Relaunch after permission change.
4. Start overlay:
   - entire display;
   - dragged region;
   - resize all eight handles;
   - cancel;
   - Return on the key display;
   - Record button.
5. HUD elapsed time, Pause/Resume, Shot, Pin, Stop.
6. Typed Shot note, drawing, normal Hold-to-Talk.
7. Settings tabs: Speech, Capture, Logs, This process, AI, General.
8. Pointer and microphone toggles on the next session.
9. Stop consent approve and deny paths.
10. Recent sessions, Retry Analysis, Reveal export.
11. Quit while recording and recovery of the unfinished session.
12. Empty, loading, permission-denied, invalid-key, interrupted, and pack
    omission states.
13. Preflight ready, warning, blocked, and relaunch-required states.
14. Capture-health healthy, warning, paused, and fatal states.
15. Payload review exclusions and image redaction.
16. Processing recovery after terminating each processing stage.
17. Session review trim/remove/edit/cancel/build actions.
18. Coding-agent, web-chat, and human-review export profiles.
19. Session-history search, filters, recovery, reveal, and safe deletion.

For every failure:

- capture the scoped technical log;
- write an exact reproduction;
- make one focused code/test commit;
- rerun the affected gate and all automated tests.

**Done when:** a fresh user can record, pause, annotate, process, inspect, and
hand off a session without Xcode or Terminal after installation.

---

### TASK F03 — Privacy and negative-path audit

Run:

```bash
rg -n 'title|url|note|transcript|api.?key' ~/Library/Logs/ScrumTrace/agent.jsonl
unzip -l /path/to/export/session-pack.zip
```

Inspect provider request construction with synthetic markers.

**Pass criteria**

- Agent log contains no titles, URLs, notes, transcripts, tokens, or keys.
- Diagnostics contain no archive media.
- Provider payload matches consent and adapter capabilities.
- Denied consent produces no provider call.
- No archive path or byte appears in export or zip.
- HTML and Markdown treat captured text as untrusted data.

If a security defect appears, fix it before distribution.

---

### TASK F04 — Final gate rerun

Create new artifacts after the last code-review fix. Do not reuse provisional
Phase B/C PASS evidence.

Run Gate −0, Gate 0, Gate 1, and Gates 3–6 in order. Exercise:

- all three export profiles;
- payload exclusion and image redaction;
- processing crash/recovery at every stage;
- session review edits;
- session history recover/reveal/delete;
- consent denied, invalid key, retired model, and valid provider;
- 8-clip/20-shot stress pack.

Update `samples/GATE_LOG.md` only with these final run results. Include commit
SHA, machine, macOS, chip, signing identity/CDHash, measured durations/bytes,
and manual-check notes.

**Final acceptance**

- Every required automated result is `pass`.
- Every manual row is completed.
- No blocked row remains.
- No critical/high review finding remains.
- Fresh-user walkthrough passes.
- Privacy audit passes.
- Working tree is clean and all commits are pushed.

Any failure reopens implementation. After a fix, repeat Phase E and all of
Phase F; do not rerun only the failed line.

---

## Phase G — Distribution

### TASK G01 — Release signing and notarization

**Prerequisites supplied by the human**

- Developer ID Application identity/team.
- Notary credentials.
- Release version/build number.

**Commands**

Use `scripts/mac_release.sh`; do not invent replacement signing commands unless
that script is proven broken.

**Pass criteria**

- Release archive succeeds.
- `codesign --verify --deep --strict` succeeds.
- `spctl --assess --type execute` succeeds.
- Notarization is accepted.
- Stapling succeeds.
- Installed Release app launches outside Xcode.
- Bundle ID and entitlements match the Debug-gated app except expected signing
  identity differences.
- Record is never license-gated.

After installation, repeat a short Gate −0 and export smoke test on the Release
build.

---

### TASK G02 — Updates and licensing

Do this only after the functional Release app passes G01.

1. Validate GitHub update-check behavior using a real test release.
2. If adding Sparkle:
   - resolve the latest stable package on a Mac;
   - commit `Package.resolved`;
   - provide and protect the EdDSA private key outside git;
   - test signed feed and update installation.
3. Generate license signatures outside the repository.
4. Test valid, invalid, expired, and missing license displays.
5. Confirm Record works in all four license states.

**Pass criteria**

- Update check failure is nonfatal.
- A signed update installs and relaunches.
- Invalid license never crashes and never disables Record.
- No signing or license private key is committed.

---

### TASK G03 — Final installed-release acceptance test

This is the final test at the end of the plan. Use the exact notarized and
stapled artifact produced by G01, installed on a clean macOS user account. Do
not rebuild between signing and this test.

1. Record artifact SHA-256, version, build, Team ID, CDHash, notarization
   result, machine, macOS, and chip.
2. Complete onboarding and fresh TCC grants.
3. Run Gate −0.
4. Run the full-screen Keynote Gate 0 sequence.
5. Run the 20-minute, three-pause Gate 1 sequence.
6. Complete local Whisper, slicing, review, provider scenarios, and all three
   export profiles.
7. Exercise payload removal/redaction and verify exact consent binding.
8. Terminate during each processing stage and recover.
9. Verify session-history search/reveal/recover/delete.
10. Build and inspect the 8-clip/20-shot stress pack.
11. Install one signed update and confirm settings/session history remain.
12. Repeat Record with missing, invalid, expired, and valid license states.
13. Run the privacy audit against the final logs, exports, zips, diagnostics,
    and mocked provider requests.

**Final pass criteria**

- All final Gate −0 through 6 rows pass with fresh artifacts.
- Every Phase D feature works on the installed Release app.
- No crash, hang, lost archive, duplicate provider call, or privacy leak.
- Record works in every license state.
- Update installs and relaunches successfully.
- `codesign`, Gatekeeper assessment, notarization, and stapling remain valid
  after installation.
- `FINAL_REVIEW.md` has no unresolved critical/high issue.
- Source tree is clean; tested commit is pushed to both `origin/develop` and
  `github/develop`.

If any item fails, the app is not complete. Fix it in one focused commit,
repeat Phase E, rebuild/re-sign/notarize, repeat Phase F, then rerun all of G03.

Record the final result in `samples/GATE_LOG.md` and the release notes without
including secrets or captured content.

---

## 3. Final verification command set

Linux:

```bash
git status --short
bash scripts/run_linux_tests.sh
python3 scripts/inspect_all_gates.py --mock-only
```

Mac:

```bash
bash scripts/mac_xcode_test.sh
bash scripts/mac_all_gates.sh --no-build --strict \
  --session /path/to/gate1-session \
  --log ~/Library/Logs/ScrumTrace/agent.jsonl \
  --log-start-line "$(python3 -c 'import json, pathlib; print(json.loads(pathlib.Path.home().joinpath(\"Library/Logs/ScrumTrace/gate-run.json\").read_text())[\"log_start_line\"])')"
```

Release:

```bash
codesign --verify --deep --strict --verbose=2 /Applications/ScrumTrace.app
spctl --assess --type execute --verbose=2 /Applications/ScrumTrace.app
xcrun stapler validate /Applications/ScrumTrace.app
```

## 4. Review handoff checklist

Before requesting another review, provide:

- comparison base commit;
- final commit list;
- Linux test output;
- macOS Xcode test output;
- exact Mac model, macOS version, app commit, signing identity/CDHash;
- Gate −0 through 6 results;
- all blocked/manual rows;
- `FINAL_REVIEW.md` with no unresolved critical/high finding;
- final clean-checkout Phase F output;
- Release signing/notarization output if Phase G was attempted;
- confirmation that `git status --short` is clean;
- confirmation that no secret or captured content was committed.

Ask the reviewer to check, in this order:

1. path containment and privacy;
2. false gate passes;
3. log/session scoping;
4. pause and clock behavior;
5. consent and provider side effects;
6. pack integrity and evidence;
7. fresh-user usability;
8. release integrity.
