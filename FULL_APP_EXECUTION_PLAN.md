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

## 1. Cursor Auto model and parallel-work strategy

Use only the user's Cursor Auto subscription. Do not add model API keys, call
these models from ScrumTrace, or introduce an orchestration dependency into the
app.

### Model roles

| Role | Cursor model | Responsibilities |
|---|---|---|
| Coordinator/integrator | **Composer 2.5** | Own `develop`, freeze interfaces, assign worktrees, integrate commits in dependency order, run aggregate tests, resolve blockers |
| Stateful implementation | **Composer 2.5** | Changes involving `SessionController`, `SessionProcessor`, `SessionModels`, capture lifecycle, consent state, or recovery |
| Isolated implementation | **Grok 4.6** | Inspectors, contained helpers, new standalone views, focused fixtures, negative-path tests |
| Adversarial reviewer | **Grok 4.6** | Search for false passes, path escapes, privacy leaks, stale state, missing negative tests, and spec violations |
| Cross-reviewer | Opposite model | Composer reviews Grok changes; Grok reviews Composer changes before integration |

Use Composer 2.5 for coordination/integration and Grok 4.6 for adversarial
implementation/review. Correct prompts, ownership, tests, and cross-review are
the quality controls; do not claim a reasoning setting that Cursor did not
expose. Do not substitute an unavailable model silently.

### Worktree protocol

The coordinator stays on `develop`. Every write-capable parallel worker gets an
isolated worktree from the exact same wave base:

```bash
git checkout develop
git pull --ff-only origin develop
BASE="$(git rev-parse develop 2>/dev/null || git rev-parse origin/develop)"
TASK="a03"
BRANCH="cursor/scrumtrace-${TASK}-0397"
DIR="../scrumtrace-${TASK}"
git worktree add -b "$BRANCH" "$DIR" "$BASE"
```

Rules:

1. One task or explicitly listed subtask per worktree.
2. Record `BASE` in every worker prompt and response.
3. Workers never switch to, merge, pull, or push `develop`.
4. Workers commit only files in their ownership list.
5. Workers do not edit shared docs, aggregate runners, project settings,
   `SessionModels.swift`, `SessionController.swift`, or `SessionProcessor.swift`
   unless the wave table explicitly assigns ownership.
6. A read-only reviewer may inspect any file but creates no commit.
7. The coordinator verifies each worker commit with:

   ```bash
   git diff --name-only "$BASE"...<worker-commit>
   git diff --check "$BASE"...<worker-commit>
   ```

8. If a worker changed an unowned file, reject the commit and ask that worker
   to split it. Do not resolve avoidable conflicts in the integration branch.
9. Same-machine worktrees return a commit SHA directly. Remote Cursor Auto
   workers push only their task branch:

   ```bash
   git push -u origin "$BRANCH"
   ```

   The coordinator fetches it explicitly:

   ```bash
   git fetch origin "$BRANCH"
   git ls-remote --heads origin "$BRANCH"
   ```

   A commit is not accepted until the remote branch resolves. The required
   lowercase `cursor/…-0397` name is an explicit user override for these tasks.
10. Integrate with `git cherry-pick <worker-commit>` in the table's order.
11. Run the wave test command only after all commits in that wave are
    integrated.
12. Delete integrated worktrees and branches:

    ```bash
    git worktree remove "$DIR"
    git branch -D "$BRANCH"
    git push origin --delete "$BRANCH"
    ```

    `-D` is intentional because a cherry-picked commit has a different commit
    identity and Git does not consider the task branch merged.
13. Push `develop` only after the complete wave is green.

Branch names must remain lowercase and end in `-0397`.

### High-contention files: one writer at a time

Never assign concurrent write access to:

- `ScrumTrace/Storage/SessionModels.swift`
- `ScrumTrace/Processing/SessionController.swift`
- `ScrumTrace/Processing/SessionProcessor.swift`
- `ScrumTrace/Capture/SessionRecorder.swift`
- `scripts/gate_inspect_lib.py`
- `scripts/inspect_all_gates.py`
- `scripts/mac_all_gates.sh`
- `scripts/run_linux_tests.sh`
- `scripts/test_contracts.py`
- `scripts/test_inspect_gates.py`
- `README.md`, `AGENTS.md`, `IMPLEMENTATION_PLAN.md`,
  `samples/GATE_LOG.md`, and this plan
- `ScrumTrace.xcodeproj/project.pbxproj`

New Swift files beneath synchronized `ScrumTrace/` and `ScrumTraceTests/`
groups do not require a project-file edit. Composer still exclusively owns SPM
changes, entitlements, `Package.resolved`, and project settings.

The coordinator owns shared documentation and aggregate runners unless a task
explicitly transfers ownership.

### Parallel execution waves

`→` means sequential dependency. Items separated by `‖` may run concurrently
from the same base because their write sets are disjoint.

| Wave | Work | Builder / reviewer | Integration order |
|---|---|---|---|
| 0 | **O01** split gate tests into owned modules | Composer / Grok | O01 |
| 1 | **A01 → A02** shared containment and log-window foundations | Composer / Grok | A01, then A02 |
| 2 | **A03 ‖ A04 ‖ A05 ‖ A06 ‖ A07 ‖ A08 ‖ A09** | Composer: A04/A05/A07/A09; Grok: A03/A06/A08; opposite model reviews each | Numeric order |
| 3 | **A10 → A11** ZIP helper, then aggregate wiring/docs | Grok then Composer; cross-review | A10, then A11 |
| 4 | **B01 → B02 → B03 → B04** one Mac/TCC identity | Composer operator / Grok log review | Strictly sequential |
| 5 | **C01 → C02 → C03 → C04** on the operator Mac | Composer operator / Grok artifact review | Strictly sequential |
| 6 | **D01 → D02 → D03 → D04 → D05 → D06 → D07 → D08** | Composer stateful core; Grok isolated UI/tests and review | Strict task order |
| 7 | **E01 standards ‖ E01 spec ‖ E01 security**, then **E02 → E03** | Composer architecture; Grok spec/security | Reviews may parallel; fixes serial |
| 8 | **F01-linux ‖ F01-mac**, then **F02 → F03 → F04** | Parallel tests are read-only; hardware flows are sequential | Stop both lanes on any failure |
| 9 | **G01 → G02 → G03** | Composer operator / Grok artifact review | Strictly sequential |

Do not parallelize merely because tokens are available. TCC, one physical
display, one persistent agent log, shared session manifests, final packaging,
and release signing are serial resources.

Wave 2 exception: if A06 reports `INTERFACE_BLOCKED`, pause Wave 2 integration
before A06. Composer performs serial TASK A06b on a new base, owning only the
required Swift logging files and tests, runs Mac tests, and integrates A06b.
Restart A06 from that base. Do not cherry-pick A07–A09 until A06 is complete.

For a parallel wave, launch all eligible builders in one Cursor batch after
recording the common base SHA. Do not start downstream review agents until
their corresponding builder commit exists. Reviews of completed sibling tasks
may run concurrently.

Wave integration checks:

```bash
# Wave 0
python3 scripts/test_inspect_gates.py

# Wave 1 (new modules are not aggregate-registered until A11)
python3 scripts/gate_tests/test_gate_inspect_lib.py
python3 scripts/gate_tests/test_gate_log_window.py
bash scripts/run_linux_tests.sh
bash scripts/mac_xcode_test.sh

# Wave 2, after all seven commits are cherry-picked
for test_file in \
  test_gate_minus0.py \
  test_gate0.py \
  test_gate1.py \
  test_gate2.py \
  test_gate3.py \
  test_gate4.py \
  test_gate5.py; do
  python3 "scripts/gate_tests/${test_file}"
done
bash scripts/run_linux_tests.sh
bash scripts/mac_xcode_test.sh

# Wave 3 / final inspector integration
python3 scripts/test_inspect_gates.py
bash scripts/run_linux_tests.sh
bash scripts/mac_xcode_test.sh
```

The Wave 2 loop uses the exact O01 filenames. If O01 selects a different
spelling for minus-zero, update this plan and the command in O01 before
launching parallel work. Never let a shell glob silently skip a test module.

### Within-task parallelism for Phase D

Phase D tasks touch shared state and cannot safely run as whole tasks in
parallel. They may use three short-lived lanes **after Composer freezes the
public interface in a compiling commit**:

1. **Core lane — Composer 2.5:** existing stateful files and service logic.
2. **UI lane — Grok 4.6:** only the task's new standalone UI file.
3. **Test lane — Grok 4.6:** only the task's new dedicated test file.

Launch a UI lane only when the task explicitly lists a `new
ScrumTrace/UI/*.swift` file. Composer owns every edit to an existing UI file.
When a task lists multiple new test files, one Grok test lane owns all of them.

The interface commit must define type names, initializers, protocols, and
observable properties needed by UI/tests. Lanes may not change that interface.
If an interface proves insufficient, stop all lanes, update and compile the
interface centrally, then restart them from the new base.

The frozen interface commit must pass `bash scripts/mac_xcode_test.sh` on a Mac
before UI/test lanes launch. Linux contract tests cannot approve a Swift
interface. With no Mac worker, Phase D is `BLOCKED`.

### Dual-model completion rule

A task is ready to integrate only when:

1. the assigned builder reports exact changed files and green focused tests;
2. the opposite model performs a read-only diff review;
3. every critical/high finding is fixed by the original builder;
4. the reviewer confirms the revised diff or lists remaining findings;
5. the coordinator verifies file ownership and cherry-picks the commit;
6. wave-level tests pass after integration.

Unlimited tokens permit deeper review and more fixtures, not duplicate
implementations of the same stateful code.

## 2. Rules for the implementing model

Execute dependency waves in order. Complete and integrate one wave before
starting the next. Only tasks explicitly separated by `‖` may overlap.

- The coordinator works only on `develop`; workers use assigned worktree
  branches.
- Before editing: `git status --short`. Preserve unrelated user changes.
- Read every file named by the task before modifying it.
- Add or update tests in the same commit as behavior.
- Run the task-specific command, then `bash scripts/run_linux_tests.sh`.
- Commit each task separately with the exact proposed Conventional Commit
  subject.
- Workers return their commit SHA and do not push `develop`.
- The coordinator pushes each green integrated wave with
  `git push -u origin develop` and `git push github develop`.
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

### Copy/paste prompt for a builder

Fill every placeholder. Select the builder model from the wave table.

```text
You are the <Composer 2.5 | Grok 4.6> builder for TASK <ID> from
FULL_APP_EXECUTION_PLAN.md.

Wave base: <BASE SHA>
Branch: <cursor/scrumtrace-<TASK_ID_LOWER>-0397>
Owned files: <exact list>
Forbidden shared files: <exact list>

Read AGENTS.md, IMPLEMENTATION_PLAN.md, the complete task, and every owned file.
Implement only this task. Do not modify an unowned file. Preserve unrelated
changes. Add every listed test in the dedicated task test file. Do not weaken
existing tests/contracts or edit GATE_LOG PASS cells. Run focused verification
and the full suite available in this environment.

If an owned-file change is insufficient, stop and report INTERFACE_BLOCKED with
the exact additional file/API needed. Do not expand ownership yourself.
If Mac, permission, secret, or human evidence is unavailable, report BLOCKED.
Otherwise commit on the assigned branch with the task's exact subject. Do not
merge, rebase, push develop, or create a PR. If this is a remote Cursor Auto
worker, push only the assigned task branch with `git push -u origin <branch>`.

Return:
1. base SHA and branch;
2. exact changed files;
3. behavior implemented;
4. tests added and negative cases covered;
5. exact command results and exit codes;
6. blockers or assumptions;
7. commit SHA;
8. task-branch push result, or `same-machine worktree`.
```

### Copy/paste prompt for the opposite-model reviewer

The reviewer is read-only and uses the opposite model family:

```text
Review TASK <ID> commit <SHA> against base <BASE SHA> in
FULL_APP_EXECUTION_PLAN.md.

Builder model: <MODEL>. You are the opposite-model adversarial reviewer.
Do not edit files or create commits. Read AGENTS.md, IMPLEMENTATION_PLAN.md,
the task, and `git diff <BASE SHA>...<SHA>`.

Check:
1. changed files;
2. task requirements implemented exactly;
3. false pass/fail and missing-artifact behavior;
4. privacy, containment, symlink, traversal, and side effects;
5. state transitions, retries, cancellation, and concurrency;
6. tests that would fail before and pass after;
7. unowned files, scope creep, weakened pins, or missing exhaustive handling.

Return findings only, ordered critical/high/medium/low, with file:line,
reproduction, and required fix. Say `NO FINDINGS` if none. Do not praise or
summarize.
```

### Copy/paste prompt for Composer integration

```text
Integrate TASK <ID> commit <SHA> onto develop at expected base <BASE SHA>.
First verify changed files are within task ownership and review findings are
resolved. Cherry-pick the commit. Do not manually combine unrelated changes.
Run the focused task tests and the wave-level suite. If green, report the new
develop SHA. If not, stop and return exact failure output; do not weaken tests.
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

## 3. Inspector result contract

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

## Phase O — Prepare conflict-free test ownership

### TASK O01 — Split the monolithic gate test file

This is a behavior-preserving prerequisite for parallel inspector work.

**Owner:** Composer 2.5 builder; Grok 4.6 reviewer.

**Files**

- `scripts/test_inspect_gates.py`
- new `scripts/gate_tests/__init__.py`
- new `scripts/gate_tests/support.py`
- new `scripts/gate_tests/test_gate_minus1.py`
- new `scripts/gate_tests/test_gate_minus0.py`
- new `scripts/gate_tests/test_gate0.py`
- new `scripts/gate_tests/test_gate1.py`
- new `scripts/gate_tests/test_gate2.py`
- new `scripts/gate_tests/test_gate3.py`
- new `scripts/gate_tests/test_gate4.py`
- new `scripts/gate_tests/test_gate5.py`
- new `scripts/gate_tests/test_gate6.py`
- new `scripts/gate_tests/test_all_gates.py`

**Implementation**

1. Move existing fixtures and subprocess helpers into `support.py`.
2. Move every existing test unchanged into the matching gate module.
3. Keep `scripts/test_inspect_gates.py` as a thin deterministic runner.
4. Use only the Python standard library. Do not add pytest.
5. The runner discovers a fixed sorted module list and invokes each module in a
   child Python process.
6. Run every module even after a failure, preserve each stdout/stderr/exit code,
   and return nonzero at the end.
7. Print one concise result line per module.
8. Preserve direct execution of each module:

   ```bash
   python3 scripts/gate_tests/test_gate3.py
   ```

9. Do not change inspector behavior in this task.

**Tests**

- Record the current `python3 scripts/test_inspect_gates.py` output/exit first.
- Run every split module directly.
- Run the thin aggregate runner.
- Confirm the same number of test functions exists before and after using an
  AST-based count, not text grep.
- Assert the fixed module list equals the AST-discovered test-module set and
  every listed module emitted one result line.

**Verify**

```bash
python3 scripts/test_inspect_gates.py
bash scripts/run_linux_tests.sh
```

**Done when:** test behavior is unchanged and each TASK A03–A09 worker can own
one test module without editing a shared test file. Freeze `support.py` after
this commit; later tasks keep gate-specific fixtures in their owned test module.
Do not start A01 until O01 is integrated and the aggregate test runner passes.

**Commit:** `test: split gate inspector test ownership`

---

## Phase A — Make gate evidence trustworthy

### TASK A01 — Contain every export evidence path

**Problem:** `export_file_exists()` accepts traversal such as
`shots/../../outside.png`.

**Files**

- `scripts/gate_inspect_lib.py`
- new `scripts/gate_tests/test_gate_inspect_lib.py`

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
4. Replace `emit()` with the Section 3 result schema. Require explicit
   `pass`, `fail`, `blocked`, or `manual_required`; never infer the two exit-2
   states from a Boolean alone. Existing inspectors keep their current outcome
   while adopting the schema.

**Tests**

Add cases proving all of these are false:

- `../outside.png`
- `shots/../../outside.png`
- `/tmp/outside.png`
- `export/../archive/session.mp4`
- a symlink under `export/shots/` to an outside file
- a symlink under `export/shots/` to another file still inside `export/`
- a zero-byte file

Add one positive case for `shots/inside.png`.

**Verify**

```bash
python3 scripts/gate_tests/test_gate_inspect_lib.py
bash scripts/run_linux_tests.sh
```

**Done when:** only a non-empty regular file contained under the real
`export/` root can satisfy evidence. `run_linux_tests.sh` alone is insufficient:
the dedicated A01 module and Wave 1 integration commands must both pass.

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
- `scripts/gate_tests/test_gate_minus0.py`
- `scripts/gate_tests/test_gate0.py`
- `scripts/gate_tests/test_gate2.py`
- `scripts/gate_tests/test_gate5.py`
- `scripts/gate_tests/test_all_gates.py`
- new `scripts/gate_tests/test_gate_log_window.py`
- new `ScrumTraceTests/AgentLogTests.swift`

**Implementation**

1. Generate one random, non-secret `run_id` when the app process launches.
   Include it in every `AgentLog.event` row without changing individual call
   sites.
2. Add a process-safe current session context to `AgentLog`.
   `SessionController` sets it immediately after the session ID is created and
   clears it only after processing/retry finishes or the controller abandons
   that session. Include `session` automatically in every event while context
   is set. Explicit event fields win only when equal;
   mismatches must be asserted in Debug and logged as a technical error.
3. Never include titles, URLs, notes, transcripts, tokens, or keys in either
   identifier.
4. Add optional `--log-start-line N` to every log-reading inspector. Direct
   child CLIs preserve existing behavior temporarily so their O01 tests stay
   green. A03/A04/A06/A09 make it mandatory for their respective final
   inspector. The aggregate immediately returns exit `2` when `--log` lacks
   `--log-start-line`; A11 later wires the full artifact-map schema.
5. Add a shared `read_jsonl_window(path, start_line)` helper.
   - Lines are one-based.
   - Reject negative values.
   - Exit `2` when the marker is beyond EOF.
6. Add `bash scripts/mac_all_gates.sh --begin`.
   - Verify macOS.
   - Create `~/Library/Logs/ScrumTrace/gate-run.json`.
   - Store current log line count + 1, UTC time, current `git rev-parse HEAD`,
     app CDHash, machine name, macOS version, and chip.
   - Do not truncate or rewrite `agent.jsonl`.
7. Normal `mac_all_gates.sh` loads that marker and passes
   `--log-start-line` to all log inspectors.
8. `inspect_all_gates.py` must require `--log-start-line` whenever `--log` is
   supplied. Missing marker is exit `2`, not a whole-log fallback.
9. Session-aware inspectors must additionally infer `session_id` from
   `session.manifest.json` and require a matching log event where the event
   schema includes `session`.
10. Read the applicable `run_id` from the first `launch` event after the
    marker. A marker must be created after the final TCC relaunch and separately
    for B02, B03, and B04. Require one `run_id` within each individual test
    run—not across multiple gate runs.
11. Set/clear session context on the AgentLog serialization queue. In Release,
    a mismatched explicit session is dropped and a content-free
    `session_mismatch` technical event is emitted; do not rely on `assert`.
12. Use `TemporaryDirectory` for every parallel Python fixture. No test may
    share a hard-coded `/tmp/scrumtrace-*` path.

**Tests**

- Old failing event before the marker is ignored.
- Old passing event before the marker cannot satisfy a new run.
- Matching event after the marker is used.
- Marker beyond EOF blocks.
- Missing marker blocks.
- A different session ID does not satisfy Gate −0 or Gate 5.
- Every app event receives the same process `run_id`.
- Session context appears after start, remains through processing/consent/export,
  and is absent only after processing/retry completes or the session is
  abandoned.
- A session mismatch cannot silently overwrite context.

**Verify**

```bash
python3 scripts/gate_tests/test_gate_log_window.py
bash scripts/run_linux_tests.sh
bash scripts/mac_xcode_test.sh
```

**Done when:** no log-based result can be influenced by events before the
explicit gate-run marker or by another session, and the Swift logging changes
compile and pass on a Mac. If no Mac is available, this task is `BLOCKED` and
Wave 2 must not start. `run_linux_tests.sh` alone is insufficient: the
dedicated A02 module and every Wave 1 integration command must pass.

**Commit:** `fix: scope gate logs to one run`

---

### TASK A03 — Make Gate −0 prove a 30-second capture

**Files**

- `scripts/inspect_gate_minus0.py`
- `scripts/gate_tests/test_gate_minus0.py`

**Implementation**

Require:

0. `--log-start-line` is mandatory; missing marker returns exit `2`.
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
python3 scripts/gate_tests/test_gate_minus0.py
bash scripts/run_linux_tests.sh
```

**Done when:** a short or failed recording cannot pass Gate −0.

**Commit:** `fix: require a complete Gate minus zero capture`

---

### TASK A04 — Make Gate 0 require actual Keynote actions

**Files**

- `scripts/inspect_gate0_log.py`
- `scripts/mac_gate01.sh`
- `ScrumTrace/UI/HotkeyManager.swift`
- `scripts/gate_tests/test_gate0.py`

**Implementation**

Within the scoped log window require:

1. `--log-start-line` is mandatory; missing marker returns exit `2`.
2. One `hotkey_shot`, one `hotkey_pin`, and one `hotkey_pause`.
3. Capture `front` and `app_active` before performing Shot or Pin and log one
   `hotkey_front` result for each. Pause is proven by `hotkey_pause` plus
   `pause_ok`/`resume_ok`; it does not require `hotkey_front`.
4. Shot and Pin pre-action results have `app_active == "0"` and
   `front == "com.apple.iWork.Keynote"`.
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
python3 scripts/gate_tests/test_gate0.py
bash scripts/run_linux_tests.sh
bash scripts/mac_xcode_test.sh
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
- `scripts/gate_tests/test_gate1.py`

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
6. Require at least three closed pauses and at least 1,200 seconds
   of media.
7. Require pause durations to be finite, positive, and consistent with
   `resume_wall - pause_wall` within 10 ms.
8. Require media duration to approximately equal wall duration minus summed
   pause duration.
9. Remove `--shot-before-pause`; Shot behavior belongs to scoped log evidence
   in Task A06. A filename set cannot distinguish a valid post-resume Shot.
10. Continue scanning transcript, events, loose export text, and every ZIP text
    member for token/passphrase.
11. Do not edit aggregate runners in this task. TASK A11 wires these arguments
    into `inspect_all_gates.py` and `mac_all_gates.sh`.

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
python3 scripts/gate_tests/test_gate1.py
bash scripts/run_linux_tests.sh
```

**Done when:** this inspector's CLI cannot label Gate 1 passed without explicit
human media checks and offset measurement. Aggregate wiring remains A11.

**Commit:** `fix: require manual evidence for Gate one`

---

### TASK A06 — Require every paused action in Phase 2 evidence

**Files**

- `scripts/inspect_gate2_shot.py`
- `scripts/gate_tests/test_gate2.py`

**Implementation**

Within one scoped pause window require:

0. `--log-start-line` is mandatory; missing marker returns exit `2`.
1. A Shot attempt and `shot_ignored`/`shot_fail` with `reason=paused`.
2. A Pin attempt and `pin_ignored` with `reason=paused`.
3. A Hold-to-Talk attempt and `talk_start_fail reason=paused`, **or** an
   in-flight `talk_press` before Pause followed by `talk_abort` before Resume.
4. No `shot_begin` during Pause. A `shot_save` is allowed only when its
   captured frame `t_media` predates the pause; this is the permitted completion
   of a pre-pause annotation. A save whose capture `t_media` lies inside the
   pause fails.
5. No `pin_ok` during Pause.
6. No `talk_transcribe_begin`, `talk_transcribe_ok`, or persisted voice-note
   result for a paused attempt.
7. At least one normal Shot save before or after Pause, proving Shot was
   generally functional.

Use event order, not wall-clock parsing, unless all events already provide the
same monotonic timestamp.

If product logging changes, log only action, reason, session ID, booleans, and
numeric timing. Never log note or transcript content.

This Grok-owned task may not edit Swift. If the required capture-time field is
missing, return `INTERFACE_BLOCKED`. Composer creates a separate serial A06b
logging commit, runs Mac tests, and Grok restarts A06 from that new base.

**Tests**

- Pause with no attempts blocks.
- Each missing required action blocks.
- Refused Shot + Pin + PTT passes.
- In-flight PTT abort passes.
- A newly captured `shot_save`, `pin_ok`, or transcription during Pause fails.
- Saving a pre-pause annotation during Pause passes.

**Verify**

```bash
python3 scripts/gate_tests/test_gate2.py
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
- `scripts/gate_tests/test_gate3.py`

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
python3 scripts/gate_tests/test_gate3.py
bash scripts/run_linux_tests.sh
```

**Done when:** a surviving single pass may support Retry Analysis, but can
never close Gate 3.

**Commit:** `fix: fail Gate three on incomplete transcription`

---

### TASK A08 — Tie Gate 4 measurements to real files

**Files**

- `scripts/inspect_gate4_slicer.py`
- `scripts/gate_tests/test_gate4.py`

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
python3 scripts/gate_tests/test_gate4.py
bash scripts/run_linux_tests.sh
```

**Done when:** Gate 4 reports measured values from the selected session, not
merely numeric manifest fields.

**Commit:** `fix: verify Gate four media measurements`

---

### TASK A09 — Split Gate 5 into four explicit scenarios

Gate 5 cannot be proven by one session. It requires separate consent-denied,
invalid-key, retired-model, and evidence-validation scenarios. Use only canned,
non-sensitive synthetic content for scenarios that may contact a provider.

**Files**

- `scripts/inspect_gate5_provider.py`
- `scripts/gate_tests/test_gate5.py`

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

- `--log-start-line` is mandatory for every log-backed scenario;
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

Define a stable CLI for four named Gate 5 session directories. Do not edit
aggregate runners in this task. TASK A11 wires the four scenarios and blocks
when any is missing.

**Tests**

Add positive and negative fixture tests for every scenario. Specifically cover
empty task lists, empty transcript, missing quotes, traversal evidence, old log
events, and provider/model mismatch.

**Verify**

```bash
python3 scripts/gate_tests/test_gate5.py
bash scripts/run_linux_tests.sh
```

**Done when:** Gate 5 cannot pass vacuously or from one happy-path session.

**Commit:** `fix: require all Gate five provider scenarios`

---

### TASK A10 — Validate the actual Gate 6 ZIP and projection

**Files**

- `scripts/gate_inspect_lib.py`
- `scripts/inspect_gate6_pack.py`
- `scripts/gate_tests/test_gate6.py`
- new `ScrumTraceTests/PackGateTests.swift`

**Implementation**

1. Add typed `zip_inventory()` with states that distinguish:
   - missing;
   - valid;
   - corrupt/unreadable.
   Keep the existing `zip_names() -> list[str]` behavior for Gate 3 and
   implement it through the typed inventory without changing its public type.
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
python3 scripts/gate_tests/test_gate6.py
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
- new `scripts/inspect_agent_log_privacy.py`
- `scripts/test_inspect_gates.py`
- `scripts/test_contracts.py`
- `scripts/gate_tests/test_all_gates.py`
- new `scripts/gate_tests/test_agent_log_privacy.py`
- `README.md`
- `AGENTS.md`
- `IMPLEMENTATION_PLAN.md`
- `samples/GATE_LOG.md`

**Implementation**

1. Aggregate subprocess output using the explicit inspector result contract.
2. Treat malformed/non-JSON inspector output or a missing `status`,
   `blocked_reasons`, or `manual_checks` field as failure.
3. Treat unexpected exit codes as failure.
4. `--strict` succeeds only when all requested gates are `pass`.
5. Preserve the required order: −1, −0, 0, 1, 2, 3, 4, 5, 6.
6. Stop after Gate −0 failure when running the guided Mac workflow.
7. Stop before Gates 3–6 unless Gate 1 is passed from a named artifact.
8. Print exact next actions for blocked/manual rows.
9. Never include secret values or captured content in aggregate output.
10. Never write `GATE_LOG.md`.
11. Wire all manual Gate 1/3/4 assertions introduced by A05/A07/A08.
12. Wire all four Gate 5 scenario artifacts introduced by A09.
13. Add every new test module from A01–A10 to the thin sorted test runner.
    Assert its fixed list equals the test modules on disk.
14. Update shared docs and source-text contract pins in this integration commit.
    `samples/GATE_LOG.md` edits are command/example changes only—never PASS
    cells.
15. Preserve every symbol currently pinned by `scripts/test_contracts.py`
    during A03–A10. A11 may update a pin only in the same commit that wires the
    replacement behavior.
16. Add `--artifact-map PATH` to both aggregate runners. The JSON map contains
    separate entries for −0, 0, 1/2, 3, 4, 5, and 6. Every log-backed entry
    carries `log` and `log_start_line`; every session-backed entry carries
    `session`. Gate 5 contains nested `denied`, `invalid_key`,
    `retired_model`, and `evidence` entries. Document and JSON-validate this
    schema. Reject missing/unknown keys in strict mode.
17. Preserve direct per-inspector arguments for debugging, but strict all-gate
    acceptance requires the artifact map so one session cannot satisfy
    unrelated scenarios.
18. Add `inspect_agent_log_privacy.py`. Parse JSONL structurally; reject
    forbidden content keys and user-supplied marker values while permitting
    documented technical keys such as `has_url`. Never print a rejected secret
    value—print line number and key only.
19. Do not use `--strict` as sign-off before A11 is integrated.

**Tests**

- Child exit 0 + malformed JSON fails.
- Child exit 2 is blocked.
- `--strict` fails on blocked/manual.
- Gate −0 failure prevents later execution.
- Gate 1 blocked prevents 3–6.
- All synthetic passes return zero.
- Privacy inspector catches forbidden keys/values without echoing them and does
  not flag `has_url`.

**Verify**

```bash
python3 scripts/gate_tests/test_all_gates.py
python3 scripts/test_inspect_gates.py
bash scripts/run_linux_tests.sh
```

**Done when:** one command cannot overstate the state of any gate.

**Commit:** `fix: make all-gate results fail closed`

---

## Phase B — Compile and exercise the real app

Do not begin this phase until Phase A is merged on `develop`.

### TASK B01 — Mac compile and Xcode tests

**Coordinator/operator-only on the canonical Mac `develop` clone. This is not
a worktree worker task. No code changes unless the command fails.**

```bash
cd "$(git rev-parse --show-toplevel)"
git checkout develop
git pull --ff-only origin develop
bash scripts/mac_xcode_test.sh
bash scripts/mac_gate01.sh
```

**Pass criteria**

- Swift app compiles in Debug.
- All `ScrumTraceTests` pass.
- The actual exit code from both commands is `0` on macOS; Linux output is
  `BLOCKED`, never PASS.
- Stable app exists at `~/Applications/ScrumTrace.app`.
- Signature identifier is `com.str8minds.ScrumTrace`.
- Local `ScrumTrace Debug` identity is used.
- App Sandbox is off.

`mac_xcode_test.sh` proves compilation/tests only and may use ad-hoc signing.
Signing identity, sandbox, bundle ID, and `LSUIElement` are verified by
`mac_gate01.sh`.

If compilation fails, create a numbered B01a focused task with an exact
owned-file list and one fix commit. Do not turn B01 into an unbounded cleanup.
Do not start B02 until Mac tests pass.

---

### TASK B02 — Fresh TCC and Gate −0

**Operator steps**

```bash
pkill -x ScrumTrace || true
launchctl bootout gui/$(id -u)/com.str8minds.ScrumTrace.agentloop 2>/dev/null || true
open -n ~/Applications/ScrumTrace.app
```

1. Grant Screen Recording and Microphone to that stable app.
2. Relaunch. Do not rebuild after granting.
3. After the post-TCC relaunch is running, execute
   `bash scripts/mac_all_gates.sh --begin`.
4. Record at least 31 seconds with visible motion, system audio, and microphone.
5. Stop and wait for local processing.
6. Run the Gate −0 inspector for that exact session and marker.

**Pass criteria**

- Gate −0 automated checks pass.
- Manual playback confirms picture, system audio, and microphone.
- No capture/write/start/stop fatal event exists in the scoped log.

If this fails, stop. Do not run Gate 0 or Gate 1.

---

### TASK B03 — Gate 0 over full-screen Keynote

1. Create a fresh marker with `bash scripts/mac_all_gates.sh --begin`.
2. Open the Start overlay and begin a short recording so overlay sequencing is
   inside the marked window and Pin has a valid timeline.
3. Enter full-screen Keynote.
4. Press Shot, Pin, and Pause hotkeys once each.
5. Confirm Keynote remains visually frontmost after each.
6. Resume and stop.
7. Run Gate 0 against the saved run marker.

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

1. Begin a new marked gate run with `bash scripts/mac_all_gates.sh --begin`.
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

Before accepting the commit, Grok 4.6 performs a read-only review of the scoped
gate JSON and `samples/GATE_LOG.md` diff for stale events, missing manual rows,
content leakage, and overstated PASS claims.

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
Use canned, non-sensitive synthetic sessions for every network-provider
scenario. Hardware captures may validate local processing but must not be
uploaded for this gate.

1. Deny consent.
2. Approve consent with an invalid key.
3. Select a retired Anthropic ID.
4. Run one valid OpenAI-compatible evaluation with a user-provided key against
   a synthetic session containing only canned, non-sensitive stills and
   transcript. Never upload the Gate 1 hardware session or real captured
   meeting content for this validation.

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

Grok 4.6 reviews the Gate 3–6 JSON artifacts and Gate-log diff read-only before
the coordinator accepts these provisional results.

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
- `ScrumTrace/Export/ExportProjector.swift`
- `ScrumTrace/Storage/SessionModels.swift`
- new `ScrumTrace/UI/UploadReviewWindow.swift`
- new `ScrumTraceTests/UploadReviewTests.swift`
- new `ScrumTraceTests/ProviderRequestTests.swift`

Verify the existing declarations with
`rg 'AIProviderProtocol|ProviderWireMedia' ScrumTrace/AI/AIProviderProtocol.swift`.
Do not create a duplicate `ProviderWireMedia.swift`.

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
9. Expose one `presentConsentIfNeeded(payloadPlan:)` integration hook.
   Processing completion must call this hook rather than directly constructing
   the consent UI. TASK D05 inserts Session Review before this hook without
   rewriting payload/consent state.

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

### TASK D08 — Implement signed updates and license display

This source-code task must finish before Phase E so update and license code is
included in final review and release-candidate tests.

**Files**

- `ScrumTrace.xcodeproj/project.pbxproj`
- `ScrumTrace.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved`
- `ScrumTrace/App/UpdateChecker.swift`
- `ScrumTrace/App/AppDelegate.swift`
- `ScrumTrace/App/Info.plist`
- `ScrumTrace/UI/SettingsView.swift`
- `scripts/mac_release.sh`
- update-feed/release automation files selected by the coordinator
- new `ScrumTraceTests/UpdateAndLicenseTests.swift`

**Implementation**

1. Add Sparkle as the required v1 installer:
   - resolve the latest stable package on a Mac, never Linux;
   - commit `Package.resolved`;
   - integrate its updater without changing Record availability;
   - keep EdDSA private keys outside git;
   - support signed feed, download, install, and relaunch;
   - reject tampered or unsigned updates.
2. Keep GitHub release-check failure nonfatal.
3. Keep license verification local and signature-based.
4. Test missing, invalid, expired, and valid license display.
5. Confirm Record works in all four license states.
6. Never place update/license private keys or full license values in logs.
7. Extend `mac_release.sh` to accept both
   `SCRUMTRACE_MARKETING_VERSION` and `SCRUMTRACE_BUILD_NUMBER` as paired,
   validated build-setting overrides. If only one is present, fail before
   `xcodebuild`. Pass them as `MARKETING_VERSION` and
   `CURRENT_PROJECT_VERSION` without editing tracked files. Preserve existing
   behavior when neither is set.
8. Replace hardcoded `CFBundleShortVersionString` and `CFBundleVersion` values
   in `ScrumTrace/App/Info.plist` with `$(MARKETING_VERSION)` and
   `$(CURRENT_PROJECT_VERSION)`. The target uses a checked-in Info.plist, so
   build-setting overrides are not valid until these substitutions exist.

**Tests**

- Valid signed update metadata accepted.
- Tampered/unsigned update rejected.
- Feed/network failure is nonfatal.
- Missing/invalid/expired/valid license states render correctly.
- Record availability is identical in every license state.
- Secrets and full license values are absent from logs.
- Release script rejects a partial/invalid version override and does not dirty
  the source tree.
- Built-app plist tests prove both build-setting substitutions resolve to the
  requested concrete values.

**Verify**

```bash
bash scripts/mac_xcode_test.sh
bash scripts/run_linux_tests.sh
```

**Done when:** update and license code is complete, Mac-tested, and ready for
Phase E review. Actual signed release/feed installation is proven in Phase G.

**Commit:** `feat: add signed updates without gating record`

---

## Phase E — Code review and product audit

Phase E happens after all implementation tasks. Do not start the final test with
unresolved review findings.

### TASK E01 — Automated branch review

Use the parent of TASK O01 as the fixed comparison point so the test split is
also reviewed.

Run three independent reviews in parallel:

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

3. **Security review**

- export containment;
- ZIP member validation;
- provider side effects and consent;
- HTML/Markdown injection;
- diagnostics and logs;
- file deletion and symlinks;
- credentials and signing material.

**Output**

Each reviewer owns one file:

- `FINAL_REVIEW_STANDARDS.md`
- `FINAL_REVIEW_SPEC.md`
- `FINAL_REVIEW_SECURITY.md`

Each file contains only:

- comparison base and reviewed HEAD;
- finding severity;
- exact file/line;
- reproduction or failing test;
- disposition: accepted, rejected with reason, or blocked.

Do not copy captured content or secrets into the review. After all three
reviews finish, Composer serially combines them into `FINAL_REVIEW.md` and is
the only writer of that merged file.

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

**F01-linux lane**

```bash
bash scripts/run_linux_tests.sh
python3 scripts/inspect_all_gates.py --mock-only
```

This proves Linux contracts and Phase −1 only. It is never evidence for Mac
Gates −0 through 6.

**F01-mac lane**

```bash
bash scripts/mac_xcode_test.sh
xcodebuild \
  -project ScrumTrace.xcodeproj \
  -scheme ScrumTrace \
  -configuration Release \
  -destination 'platform=macOS' \
  CODE_SIGNING_ALLOWED=NO \
  build
```

Both lanes are read-only and may run in parallel. If either fails, stop both
lanes, open one serial fix task, complete Phase E again, and rerun both lanes
from clean clones.

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
- reopen one focused implementation task with exact ownership;
- complete the E02 fix/review loop;
- restart all of F01–F04 from clean artifacts.

**Done when:** a fresh user can record, pause, annotate, process, inspect, and
hand off a session without Xcode or Terminal after installation.

---

### TASK F03 — Privacy and negative-path audit

Run the structured privacy inspector from A11:

```bash
python3 scripts/inspect_agent_log_privacy.py \
  --log ~/Library/Logs/ScrumTrace/agent.jsonl \
  --forbidden-value 'ST-G1-PAUSE-TOKEN-9F3C' \
  --forbidden-value 'orchid lantern seven' \
  --forbidden-value "$SEEDED_SYNTHETIC_SECRET"
```

It fails on forbidden content keys such as `title`, `window_title`, `url`,
`note`, `transcript`, `api_key`, `token`, `passphrase`, or `secret`, and on
forbidden marker values. It permits documented technical booleans such as
`has_url` and never echoes a secret.

List and inspect the ZIP with:

```bash
unzip -Z -1 /path/to/export/session-pack.zip
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

Do not start F04 unless every Phase D commit is integrated, all Mac tests pass,
E02 has zero unresolved critical/high finding, and E03 human approval is
recorded.

Run Gate −0, Gate 0, Gate 1, and Gates 3–6 in order. Exercise:

- create a new `mac_all_gates.sh --begin` marker immediately before each
  separate −0, 0, and 1 run;
- all three export profiles;
- payload exclusion and image redaction;
- processing crash/recovery at every stage;
- session review edits;
- session history recover/reveal/delete;
- consent denied, invalid key, retired model, and valid provider using canned
  non-sensitive sessions only—never upload the Gate 1 hardware capture;
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

Phase D08 already implemented Sparkle and licensing before review/testing.
Build two artifacts from the exact reviewed source commit: baseline version N
and update version N+1. Only version/build metadata may differ.

**Prerequisites supplied by the human**

- Developer ID Application identity/team.
- Notary credentials.
- Baseline and update version/build numbers.
- Sparkle EdDSA signing key outside git.

**Commands**

Use `scripts/mac_release.sh`; do not invent replacement signing commands unless
that script is proven broken.

Build into distinct destinations so the second archive cannot overwrite the
first. Example values must be replaced with the approved release numbers:

```bash
SOURCE_SHA="$(git rev-parse HEAD)"
test -z "$(git status --short)"

SCRUMTRACE_DERIVED="$HOME/Library/Developer/Xcode/DerivedData/ScrumTrace-N" \
SCRUMTRACE_DMG="$HOME/Desktop/ScrumTrace-N.dmg" \
SCRUMTRACE_MARKETING_VERSION="1.0.0" \
SCRUMTRACE_BUILD_NUMBER="100" \
bash scripts/mac_release.sh

SCRUMTRACE_DERIVED="$HOME/Library/Developer/Xcode/DerivedData/ScrumTrace-N1" \
SCRUMTRACE_DMG="$HOME/Desktop/ScrumTrace-N1.dmg" \
SCRUMTRACE_MARKETING_VERSION="1.0.1" \
SCRUMTRACE_BUILD_NUMBER="101" \
bash scripts/mac_release.sh

N_APP="$HOME/Library/Developer/Xcode/DerivedData/ScrumTrace-N/ScrumTrace.xcarchive/Products/Applications/ScrumTrace.app"
N1_APP="$HOME/Library/Developer/Xcode/DerivedData/ScrumTrace-N1/ScrumTrace.xcarchive/Products/Applications/ScrumTrace.app"
N_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$N_APP/Contents/Info.plist")"
N_BUILD="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$N_APP/Contents/Info.plist")"
N1_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$N1_APP/Contents/Info.plist")"
N1_BUILD="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$N1_APP/Contents/Info.plist")"
test "$N_VERSION" = "1.0.0"
test "$N_BUILD" = "100"
test "$N1_VERSION" = "1.0.1"
test "$N1_BUILD" = "101"
python3 - "$N_BUILD" "$N1_BUILD" <<'PY'
import sys

if int(sys.argv[2]) <= int(sys.argv[1]):
    raise SystemExit("update CFBundleVersion must increase")
PY

test "$SOURCE_SHA" = "$(git rev-parse HEAD)"
git diff --exit-code
test -z "$(git status --short)"
```

Copying one binary twice is not an update. Require
`CFBundleVersion(N+1) > CFBundleVersion(N)` and a newer marketing version.

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
- Both N and N+1 originate from the same reviewed source commit.
- N and N+1 have distinct SHA-256 values and increasing bundle versions.

Store SHA-256, version/build, Team ID, CDHash, notarization result, and stapling
result for both artifacts.

---

### TASK G02 — Publish and verify the signed update

1. Publish baseline N and update N+1 to the test release channel.
2. Generate and sign the Sparkle feed outside the repository.
3. Install notarized baseline N on a clean user account.
4. Verify feed/network failure is nonfatal.
5. Verify a tampered/unsigned update is rejected.
6. Install signed update N+1 and verify relaunch.
7. Verify settings and session history survive update.
8. Re-run `codesign`, Gatekeeper assessment, and stapler validation on the
   updated installed app.

No source change is permitted in G02. Any required code change returns to a
focused implementation task, Phase E review, Phase F, and G01.

---

### TASK G03 — Final installed-release acceptance test

This is the final test at the end of the plan. Start with exact notarized
baseline N from G01 on a clean account; step 11 updates it to exact notarized
N+1 through the G02 feed. Do not rebuild either artifact.

1. Record both artifact SHA-256 values, versions, builds, Team ID, CDHashes,
   notarization results, machine, macOS, and chip.
2. Complete onboarding and fresh TCC grants, then relaunch.
3. After relaunch, create a fresh `mac_all_gates.sh --begin` marker and run
   Gate −0.
4. Create another fresh marker, then run the full-screen Keynote Gate 0
   sequence.
5. Create another fresh marker, then run the 20-minute, three-pause Gate 1
   sequence.
6. Complete local Whisper, slicing, review, provider scenarios using canned
   non-sensitive sessions only, and all three export profiles. Never upload the
   Gate 1 hardware capture.
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

## 4. Final verification command set

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
  --artifact-map /path/to/final-gate-artifacts.json
```

The artifact map is produced by A11 and must identify separate Gate 5
`denied`, `invalid_key`, `retired_model`, and `evidence` sessions. Do not point
all entries at the Gate 1 capture.

Release:

```bash
codesign --verify --deep --strict --verbose=2 /Applications/ScrumTrace.app
spctl --assess --type execute --verbose=2 /Applications/ScrumTrace.app
xcrun stapler validate /Applications/ScrumTrace.app
```

`~/Applications/ScrumTrace.app` is the locally signed Debug gate build.
`/Applications/ScrumTrace.app` in these Release commands must be the exact
notarized G01 artifact. Never sign or assess the Debug copy as the release.

## 5. Review handoff checklist

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
