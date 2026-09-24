# Implementation handoff — local export coverage

Status: LE01–LE06 implementation is ready for review; human semantic acceptance remains pending.
Updated: 2026-09-23.

## Repository and publication scope

- Target: upstream `develop`; never merge the PR or change `main`.
- Implementation is in the GIB-managed `local/scrumtrace-local-export-implementation` worktree, based on `develop` commit `77cd978057d4f41a4542cc73ca2e4dd109e7fa78`.
- The source checkout and implementation-planning worktree were not modified by this implementation.
- GIB profile and SSH alias: `github-rares-personal`. Run every GIB command in the external host execution context. GIB is the sole credential boundary; use its managed `gh` shim for authenticated GitHub operations.
- The user authorized source changes, commits, push, and a PR. No private recording material, source IDs, or corpus mapping belongs in Git, CI, or the PR description.

## Delivered

- Persisted, versioned local-procedure schema with stable step, chapter, and anchor identities; bounded excerpts, source/timing metadata, exclusions, and human review state.
- Deterministic transcript extraction and coverage-aware window selection that retains all human Shot/Pin anchors within the existing twelve-window cap.
- Local-only processing and regeneration that bypass providers and transcription/model reloads, refreshes exports for completed or incomplete sessions, and invalidates stale derived/provider results when inputs change.
- Safe projected Markdown/HTML handoffs, actual still-decode timestamps, independent still fallback after clip-encode failure, explicit evidence gaps, and measured 35 MiB ZIP/folder limits.
- Focused regression coverage and a guarded four-alias private-copy replay harness. Details and limits are in [VALIDATION.md](VALIDATION.md); requirements remain in [PLAN.md](PLAN.md).

## Verification

- Passed serial affected Xcode suites: `LocalProcedureTests`, `ContractTests`, `SpeakerTests`, `BriefUsabilityTests`, `SettingsUsabilityTests`, `SessionLibraryTests`, `PackGateTests`, and the recording-action dispatch test.
- Passed guarded local replay for all four supplied aliases. Source hashes and mtimes were unchanged; provider factories, provider calls, and transcriber model loads were all zero. Repeat IDs/fingerprints/export content were stable. ZIP members matched the export folder, links resolved, and measured outputs were within the byte cap.
- Python syntax compilation of the replay harness passed.
- The Linux test script stopped because Pillow is absent from the Python 3.14 environment. No dependency was installed.
- A serial full Xcode suite still fails two window/minimization assertions. Those failures are recorded in [VALIDATION.md](VALIDATION.md); the affected suites above pass.

## Acceptance still open

- No fixed, human-reviewed reference exists for the private recordings. Recall, unsupported assertions, and critical visual coverage have not been scored; semantic acceptance is pending.
- The export-only consumer exercise was not run.
- No real 50-minute or 2–3-hour capture/drift evidence was collected. Capture hardware gates remain unchanged and open.
- The replay preserves the existing saved exports but does not regenerate a baseline using old application code.

The private metrics, snapshots, exports, test logs, and corpus mapping remain in the machine-local owner-only replay directory, outside the repository. The public report may state only aggregate mechanical results and these limitations.
