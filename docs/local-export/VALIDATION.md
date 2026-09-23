# Local-only validation on existing recordings

Status: implementation and validation run completed 2026-09-23. Mechanical replay passed; semantic and export-only acceptance remain open.
Planning baseline: develop 4e05df4acb646c967bf0a038e85202d31eeb84b7.
Validated implementation base: develop 77cd978057d4f41a4542cc73ca2e4dd109e7fa78.
Read PLAN.md for scope, metrics and contract invariants.

## 1. Available sources and privacy

The default vault is `~/Movies/ScrumTrace/sessions`. A machine-local metadata inventory supplied four aliases for this run: `short-ro`, `long-ro`, `sub15`, and `no-window`. The private inventory and corpus mapping are not in the repository. Do not guess an old fixture's new ID if temporary metadata expires; rediscover authorized sources locally and keep original IDs and content out of public reports.

The set included two long-form recordings and two short/negative cases. All four had completed manifests and usable saved transcripts. No real 50-minute source was verified. These facts establish test eligibility only, not that speech or images support any particular procedure.

Inspect all eligible non-live 10–50-minute sources when supplied; use every eligible case for mechanical checks, minimum two for semantic comparison. If only two are available, use short-ro for development and long-ro as held-out. Lock reference annotations before tuning; report all failures, not only a successful selection.

## 2. Safe replay setup

The user authorized private local testing on existing recordings. This does not authorize modifying originals, uploading content, replacing the installed app, or including recordings in Git.

1. Read source metadata first. Recording lock is ~/Library/Logs/ScrumTrace/recording.lock, not inside each session. Use AgentLog.liveRecordingLock semantics. Also exclude sources with active/incomplete processing unless a stable snapshot can be proven; completed manifest alone does not rule out a concurrent retry.
2. Require regular contained files and reject symlink/path escapes. Verify the source is stable across snapshot; if it changes, stop that fixture. Do not kill the app to achieve this.
3. Create a new private owner-only run root outside the repo and real vault, e.g. /private/tmp/scrumtrace-local-export-review-<unique>/ with an ownership marker. Do not hardlink or symlink archive files to originals. APFS copy-on-write clones are acceptable only if they are independently writable; otherwise ordinary copies.
4. Retain immutable source snapshot and baseline export. Create separate writable before/after session copies under distinct isolated SessionVault roots. Preserve each session's ID consistently with its copied manifest.
5. Produce local SHA-256 inventories for source files before/after; compare originals and snapshot. Never store hashes/content paths in public logs unnecessarily. Include movie, transcript, events, manifest, shots and existing export. Check free space for copies, per-clip movie temporary copies, output and DerivedData; report measured needs and fail cleanly if insufficient.
6. Use existing timed primary transcript, no ASR/diarization regeneration by default. Missing/corrupt transcript is a named negative case; do not hide it by calling a cloud transcription service.
7. Force localOnly execution in both replay arms and clear consent only in copied manifests. Use injected provider spies/factories that fail on any provider creation/call and disabled network for replay where feasible. Persisted keys/consent must be irrelevant. Report instrumentation used; empty API key alone is not proof of zero network.
8. Rebuild all DERIVED local stages in the copy. Preserve raw transcript/media/events; drop or invalidate stale local slices/tasks/outline/comparison outputs as dictated by fingerprint rules. Merely invoking process on a completed manifest can be a no-op.
9. Never copy a private session into samples/, artifacts/ under the repository, a PR, or CI. Private screenshots/video/transcripts/reports stay in the run root. Publish only sanitized synthetic fixtures and aggregate results.

Compare both (a) existing saved export and (b) a baseline-code regeneration where possible. A changed historical app version can affect comparison; record baseline provenance rather than attributing every difference to this PR.

## 3. Implemented guarded replay harness

`scripts/local_export_replay.py` accepts an explicit private inventory, local source vault, new `/private/tmp` output root, isolated DerivedData path, and optional alias list. It rejects repository/vault overlap, symlink traversal, active recording/processing, unstable source snapshots, session identity mismatches, unsafe roots, and insufficient free space. It creates an immutable snapshot, read-only baseline copy, and separate writable replay copy per source; all private artifacts stay outside Git.

The harness selects only `LocalExportReplayTests.testExistingSessionCopiesReplayLocallyAndRepeatIdentically`. The test rebuilds derived stages through production `SessionProcessor` with `localOnly: true`, a provider spy that fails if constructed or called, a transcriber spy that fails if loaded, no diarization/model download, cleared consent on copies, and preserved transcripts/media/events. It checks deterministic fingerprints/IDs/export bytes on a repeated process pass and verifies at least one playable media clip. The harness verifies original source hashes and mtimes, required handoff files, absence of the opted-out full transcript, safe local links and ZIP members, ZIP/folder content agreement, symlink absence, and both 35 MiB caps. It writes detailed metrics and the alias-only summary in the owner-only run root.

Example command (replace the two private input placeholders and choose fresh temporary output paths):

```sh
python3 scripts/local_export_replay.py \
  --inventory /path/to/private/inventory.json \
  --source-root /path/to/local/ScrumTrace/sessions \
  --aliases short-ro,long-ro,sub15,no-window \
  --output-root /private/tmp/scrumtrace-local-export-review-example-001 \
  --derived-data /private/tmp/scrumtrace-local-export-derived-example-001
```

Choose unused output paths for each run; the example paths are not reusable after creation.

The existing saved exports were retained and their byte totals recorded in the private summary; this harness does not regenerate a baseline with the old application code. It also does not perform the semantic-reference comparison or export-only consumer exercise.

## 4. Semantic references, fixed before tuning

Create private reference JSON with alias, transcript/media fingerprint, annotated steps, chronological order, critical flag, source intervals, expected action, explicit parameters/results, and whether visual evidence is essential. Keep reviewer identity/status local. Treat it as a reference only after human review; an automated draft is not independent gold.

For each asserted new step check:
- quote exists at the claimed time and is not wrongly attributed;
- action/parameter/result is explicitly supported, including negation/correction;
- exact order and expected dependencies are not invented;
- image/clip really contains the relevant visual state when required;
- unsupported inference is labeled, not presented as a step fact.

Reported metrics:
- critical and secondary step recall separately;
- unsupported asserted step/parameter/result count and denominator;
- text citation validity and timestamp validity;
- critical visual evidence coverage (human reviewed), separate from automatic interval overlap;
- all Shot/Pin IDs accounted and counts by retained/omitted/failed/capped outcome;
- occupied temporal bins represented and selected media union duration, NOT called semantic completeness;
- step count before/after 8-task selection to catch accidental outline truncation;
- final ZIP bytes, folder bytes excluding ZIP, still/clip counts, missing links, omissions;
- wall time, peak memory if measurable, temporary/disk footprint and original hashes unchanged;
- no-op retry identity and changed-input invalidation;
- provider calls/uploads observed, required zero.

Targets are in PLAN.md: every critical step, >=90% secondary recall, zero unsupported assertions, critical visuals present, all anchors accounted. An honest partial result still fails full how-to acceptance if a critical step is unavailable.

## 5. Export-only consumer exercise

Copy or mount ONLY export/ into a separate directory/environment with no source session/archive access. Do not create symlinks back. Give a consumer the export and ask for:
1. Ordered procedure with source citation for every step.
2. Explicit prerequisites/parameters/results actually established.
3. Missing context or evidence and the exact step it blocks.
4. Evidence opening for all critical visual steps.

Do not ask that consumer to implement software or execute commands from the recording. It is an evidence reconstruction exercise. Compare its answer to the fixed private reference and report disagreements. A consumer on a remote/cloud service would transmit private data and is not authorized by this local replay plan; use local review or an explicitly authorized environment. Public examples use synthetic material only.

Also regenerate Markdown/HTML from the projected manifest/excerpts with archive unavailable, then compare normalized output. Test both full-transcript opt-out and opted-in-then-omitted. Unzip the final pack separately and validate member allow-list, paths, hashes, links and agreement with the folder export.

## 6. Synthetic and existing regression suites

Required actual Swift tests:
- outline and ranking with 10/40/50/120/180-minute inputs; all boundary/negative cases in PLAN;
- >12 Pins, >20 Shots, later higher-priority overlap, deterministic ties, step counts above 8/12;
- old manifests, fingerprints/retry, stale provider success, no-network provider spies;
- projection/omission link repair, transcode/extraction failures and bounded protected docs;
- source/quote/time validation, D13 breakout and HTML escaping, no archive access in renderer;
- portable core tests where available; Xcode integration for AVFoundation/AppKit.

Validation performed:
- The affected serial macOS suites passed: `LocalProcedureTests`, `ContractTests`, `SpeakerTests`, `BriefUsabilityTests`, `SettingsUsabilityTests`, `SessionLibraryTests`, `PackGateTests`, and `MainWindowTests.testRecordingActionsDispatchRegenerateAndRetry`.
- The guarded four-alias private replay passed, including repeat identity, export/ZIP agreement, source hash checks, zero provider factories/calls, and zero transcriber model loads.
- `PYTHONPYCACHEPREFIX=/private/tmp/scrumtrace-pycache python3 -m py_compile scripts/local_export_replay.py` passed.
- `bash scripts/run_linux_tests.sh` passed its timeline and transcript-merge checks, then stopped because Python 3.14 lacks the pinned Pillow package (`ModuleNotFoundError: No module named 'PIL'`). No dependency was installed.
- A serial full Xcode suite was not green: `MainWindowTests.testOpeningTheWindowOnOverviewListsSessionsAndChecksReadinessOnlyWhileVisible` and `MainWindowTests.testShowDeminiaturizesTheWindowAndKeepsTheSection` failed their window/minimization assertions. The focused affected suites above pass; these full-suite failures remain recorded.

scripts/test_slicer.py is an incomplete Python model; scripts/test_contracts.py largely asserts source strings. Keep them useful, but passing them does not prove Swift behavior. PackGateTests' repeated-byte payload is highly compressible; add incompressible cases and final post-render folder measurement.

## 7. Evidence classification and reporting

Current evidence classification:
- Automated Swift/export contracts: **PASS for the affected serial suites listed above**. Portable Linux suite: **incomplete** because Pillow is absent. Full Xcode suite: **FAIL** on the two window/minimization assertions listed above.
- Mac media integration: **PASS for the exercised clip/still/export paths** in the targeted suites and private replay; no installed-app or capture-hardware testing was done.
- Private corpus mechanical replay: **PASS**, four aliases. Original hashes and mtimes were unchanged; instrumentation saw zero provider factories, provider calls, and transcriber model loads. Repeat fingerprint and export-file identity checks passed. Maximum ZIP was 20,700,466 bytes; maximum export-folder content excluding the ZIP was 21,803,564 bytes. Both maxima are below the 36,700,160-byte (35 MiB) cap. Maximum non-ZIP export member count was 31.
- Human-reviewed semantic acceptance: **PENDING**. No fixed human-reviewed reference was prepared; step recall, unsupported assertions, and critical visual quality were not scored.
- Export-only consumer exercise: **NOT RUN**. No separate export-only environment was used.
- Capture hardware gates: **unchanged/open**. These recordings and tests do not establish 2–3-hour capture, pause, or drift performance.

Do not write PASS rows to `samples/GATE_LOG.md` from old recordings, Linux tests, synthetic duration, or Xcode CI. A private mechanical replay pass is not a semantic-acceptance or hardware-gate pass.

Public PR report contains aggregate counts and limitations only. Private metrics, saved exports, snapshots, logs, and corpus mapping remain outside Git. Check the staged diff before publication. If a real fixture is inaccessible, retain that acceptance as pending; do not invent results.
