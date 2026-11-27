# Session lifecycle refactor

Branch `feature/improve-codebase-architecture-917bd9`, based on `develop` at 91fd0b2. Terms: [GLOSSARY.md](GLOSSARY.md).

## Done means

- One `SessionLifecycle` module owns every write to the **Session status** and the done **Stages**. Nothing outside it can assign them; the compiler enforces it.
- Every classification (Unfinished, Interrupted, Resumable, Export ready, Needs attention, Prunable) is computed in that module from saved fields plus `ArchiveFacts` passed in.
- Behaviour is identical: the saved manifest bytes are unchanged, and the native suite has no failure that the 91fd0b2 baseline does not have.
- `scripts/run_linux_tests.sh` passes. The lifecycle string pins in `scripts/test_contracts.py` are replaced by one guard: no lifecycle field write outside the module.
- Known bugs stay as they are: issues 17, 18 and 19 are fixed later, test first.

## Decisions (settled 2026-11-27)

1. The controller's live capture state gets its own type. The lifecycle keeps recording and paused as saved facts only.
2. The saved format stays frozen: `pipeline_status` and `completed_stages` keep their keys, strings and order. No manifest version bump.
3. The module is a pure value type with no disk access. `SessionVault` persists it inside the manifest.
4. The fields are locked once every caller is migrated.
5. Work happens on one branch, in several commits, with one PR into `develop`. Merge `develop` before opening the PR.
6. Lifecycle string pins become behavioural Swift tests, plus one architecture guard grep.
7. Behaviour is identical. Bugs become separate issues.
8. `invalidate(from:)` only marks stages not done. Status changes are explicit transitions.
9. The different meanings of "unfinished" get separate names and are not merged.
10. Disk facts come in through `ArchiveFacts`.
11. The three transcription facts stay separate.
12. `SessionManifest` stores `lifecycle` and flattens it in its Codable implementation.
13. A `Stage` type lives inside the module. Unknown saved values are kept as they are.
14. Existing tests stay unchanged during the migration. Duplicate tests are trimmed only at the end, and each removal is listed in the PR.

## Checklist

- [x] 0. Baseline at 91fd0b2, 2026-11-27. No ScrumTrace process was running.
  - **Linux:** `run_linux_tests.sh` passes. It needs a `python3` with Pillow: the run used Homebrew `python3.14` (Pillow 12.2.0) through a PATH shim, while CI pins 12.3.0.
  - **Native:** `SCRUMTRACE_DERIVED=~/Library/Developer/Xcode/DerivedData/ScrumTraceLifecycle bash scripts/mac_xcode_test.sh` gives 520 passed, 4 failed and 16 skipped. The failures, all present before any change:
    - `MainWindowTests.testRecordingsKeyboardRevealsDeletesAndClearsTheSearch`
    - `MainWindowTests.testSettingsStayPinnedBelowTheBannerAtTheMinimumSize`
    - `MainWindowTests.testTheDateAndContextColumnsFitAtTheDefaultWindowSize`
    - `SpeakerTests.testSpeakerReviewReadsTheVaultOffTheMainActorAndOpensTheRequestedSessionFirst`
- [x] 1. Add `SessionLifecycle`, `Stage`, `CapturePhase`, `ArchiveFacts` and `SessionLifecycleTests` (table tests for every transition and classification). Not wired in yet.
- [x] 2. `SessionManifest` stores `lifecycle` with flattened Codable. Temporary forwarding accessors keep the existing callers compiling. Byte round-trip tests against `samples/mock-session` and a transferred-manifest fixture.
- [x] 3. Migrate the `SessionProcessor` writes (22). Update the matching pins in `test_contracts.py` in the same commit.
- [x] 4. Migrate the `SessionController` writes (7) and switch the live phase to `CapturePhase` where it feeds the saved status.
- [x] 5. Migrate `SessionTransfer` and `SessionLibrary`. Route the classifications through the module in Library, Controller launch, MenuBarController, RecordingsView, OverviewView and Vault retention.
- [x] 6. Lock: remove the forwarding setters. Add the guard grep to `test_contracts.py` and update AGENTS.md where it describes the lifecycle.
- [x] 7. Trimmed one test: `InterruptedSessionTests.testOnlyProcessingStatesResumeOnTheirOwn` only checked `SessionController.autoResumableStatuses`, which the lifecycle replaced (covered by `SessionLifecycleTests.testResumableIsAProcessingStatusUnlessTheLastPassFailed`). The other nine interrupted-session tests drive the controller end to end and stay.
- [x] 8. The branch contains local `develop` and `origin/develop` as last fetched (10 days old; no fetch was run). Final run: Linux suite passes; native 541 passed, 2 failed, 16 skipped, both failures in the baseline set.
- [ ] 9. The Member fetches, merges any newer `develop`, pushes as `ciprian-lupu` and opens the PR.
