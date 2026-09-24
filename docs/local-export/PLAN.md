# Local export coverage — implementation plan

Status: implementation delivered for review; private semantic acceptance remains pending.
Updated: 2026-09-23. Planning baseline date: 2026-09-22.
Planning baseline: develop at 4e05df4acb646c967bf0a038e85202d31eeb84b7.
Implementation base: develop at 77cd978057d4f41a4542cc73ca2e4dd109e7fa78.
Audience: implementation reviewers; target upstream `develop`, never `main`.
Read AGENTS.md and IMPLEMENTATION_PLAN.md first. See VALIDATION.md and HANDOFF_TERRA.md.

The LE01–LE06 implementation and guarded mechanical replay are complete on the implementation branch. Selected macOS regression suites and four private-copy replays passed. The Linux script stopped on a missing Pillow dependency; a serial full-suite run still has two window/minimization failures. Human semantic review and the export-only consumer exercise have not been performed. See VALIDATION.md for the evidence and limits. Capture hardware gates remain open.

## 1. User intent and scope

Make export/ sufficient for a coding agent to understand a recorded procedure without a cloud analysis provider. Existing private recordings of roughly 10–50 minutes are authorized as LOCAL validation inputs on isolated copies. Do not modify originals, upload recordings, or include private content in Git/PR/CI.

Next PR delivers the complete compact workflow: local extractive outline, coverage-aware <=12 evidence windows, useful stills, honest renderers, resumable processing, and a reproducible private-copy comparison harness. It does not merely add more keywords or put placeholders in the outline.

The existing single-session pack remains capped. Long recordings must retain a textual outline independent of the number of clips/tasks and report gaps. A future detailed mode will provide multiple chapter packs, each capped, with an index; its total may exceed one pack. That mode is explicitly a later PR, not a covert reinterpretation of today's 35 MB session cap. This PR adds stable step/chapter references and 120/180-minute synthetic cases so the later work does not require replacing the data model.

No capture/clock/pause redesign, new provider, local generative model dependency, automatic cloud fallback, full-transcript opt-in change, TCC/signing change, installed-app replacement, or hardware gate claims. Product work here implements the user's explicit request; unrelated surfaces remain deferred.

## 2. Verified code diagnosis

- Slicing/MeetingSlicer.swift: Shot=100, Pin=80, English keyword=40, overlap merge and top 12 by score. No procedure coverage or time-distribution objective.
- Speech/WhisperTranscriber.swift, TranscriptQuery.keywordHits: English issue/action vocabulary, substring matches. It is not a multilingual procedural detector.
- Processing/SessionProcessor.swift: process -> slicing -> evaluation or abandonEvaluate -> finishExport. localReviewTasks has no transcript argument, emits generic unknown/needs_review rows with empty quotes. A completed synthesizing stage means documents were produced, not that a procedure was recovered.
- Storage/SessionModels.swift: maxTasks=8, maxCandidateSlices=12, maxStills=16 extra stills, 15/20/25-second clip bounds; TaskRanking exempts Shot-backed rows but ordinary slice rows can be trimmed.
- Shot recovery exists for windows lost to the cap. All original Pins do not have equivalent independent manifest representation.
- MeetingSlicer.mergeOverlapping updates last.score before comparing scores to select the preferred center. The later higher score can lose its intended center. scripts/test_slicer.py uses the old score instead and only asserts duration/still union; it is not equivalent Swift coverage.
- Slicing/ClipExporter.swift extracts the first successful still at midpoint/start/end fallback, after video encode. It does not persist the extractor's actual frame time or semantically verify what is visible.
- ExportProjector already projects allow-listed evidence, resets stale exports, rewrites paths and preserves archive. SessionPackZipper measures ZIP and folder bytes and strips omitted references. Extend these, do not implement a parallel unsafe packer.
- AgentContextRenderer and SessionBriefRenderer still load selected speech from the private transcript while producing documents. Persist selected export-safe excerpts so final rendering is reproducible from projected data.
- BriefPresentation treats summary availability as provider-backed. Separate local outline availability from provider findings.
- Context is a session snapshot; do not retroactively infer repository, stack or context from current Settings.
- C5 validates quotes when present; it does not require a quote on every legacy/provider finding. The new extractive procedure representation requires a source citation without changing that existing contract.

Private metadata inspection found two usable-length candidates with existing transcripts and movies: about 12.1 minutes (346 segments, 3 Shots, 4 slices, 6 tasks) and 41.1 minutes (1114 segments, 1 Shot, 3 slices, 3 tasks). Contents and semantic accuracy have NOT been reviewed. Other locally found recordings are short edge cases. No 50-minute or 2–3-hour real fixture was established. Exact paths live in a private inventory outside Git; never assume an older session ID names the same recording.

## 3. Invariants

C2: only producer-side local processing reads archive; consumer gets export only. Use existing contained-file helpers, reject symlinks/traversal, and never log/private-publish source text. localOnly execution performs zero analysis/transcription-provider calls even with persisted approved consent, saved keys, or comparison services. Network model downloads are not part of replay: use existing usable transcripts, no diarization rerun.

C3: preserve MediaBudget.maxZipBytes = 35 * 1024 * 1024 (36,700,160 bytes), report exact bytes and the existing MB/MiB ambiguity. Do not silently change the contract or raise it. Prefer a conservative <=35,000,000-byte output target. Check both final ZIP and export files excluding ZIP after the last document rewrite. Missing ZIP is a failure, not a zero-byte PASS. Protected text must be bounded; if even protected output cannot fit, fail export readiness explicitly.

C5: local generated outline never auto-promotes to confirmed. Citation existence, visual existence, and procedural completeness are separate. Preserve valid existing provider findings only when their input fingerprint still matches; changed slice/text inputs invalidate them without a network retry in localOnly mode.

D7: every Shot/Pin has a stable inventory entry and outcome even when no clip/still fits. Export media may be omitted under C3; evidence/anchor metadata must not silently disappear. Archive remains unchanged.

D13: ASR/OCR/notes and every derivative title/label/quote are untrusted data. Use existing sanitizer/wrappers in Markdown and prompt; HTML escaping separately. Meeting commands are evidence, never execution authorization. JSON schema marks these fields as untrusted; JSON does not execute instructions.

C1 and t_media semantics remain unchanged. Do not mix wall-clock durations into slice/quote/frame times.

## 4. LE01 — schema and bounded deterministic core

Add Foundation-oriented value types for local procedure output and anchor accounting; use names appropriate to the repository. Keep core extraction/ranking pure and test the actual Swift core, not only a Python imitation.

Suggested fields:
- LocalProcedure: schema/algorithm version, input fingerprint, transcript quality/completeness, chapters, steps, excluded source ranges/reasons, generation limits.
- Chapter: stable ID, temporal span, neutral or extractive label. Chapter grouping is navigation only in this PR, not multiple packs.
- Step: stable ID, chapter ID, chronological order, action_excerpt or review_passage type, selected source references/quotes with t_media, source Shot/Pin IDs, selected slice IDs, evidence refs, review state, missing-evidence reasons.
- Anchor: stable Shot/Pin ID, type, t_media, source references, represented step/window IDs and outcome. Recover all Pins from events through the existing loader. Do not invent a Pin action from its timestamp.
- Evidence: export-relative path after projection, kind, requested and actual frame time when applicable, owning step/slice/Shot; per-pack availability and omission reason.
- Coverage: candidate/selected/represented counts, anchor outcomes, temporal distribution and evidence availability. Never label selection coverage as semantic completeness.

Decode missing fields on legacy manifests as absent, not as completed generation. Version defaults and migration must be explicit; synthesized Codable defaults alone are insufficient where absent keys would throw. Extend projection/rewrite/omission paths for every new reference. Avoid extra JSON assets unless needed; if introduced, update zipper allow-list and protected-document policy explicitly.

IDs must survive ranking, omission and unchanged retries. Hash normalized source identity/time + algorithm version rather than array position; order for display is independent. Fingerprint the primary transcript (including source/word timing), Shot notes/media identity, Pin inventory, duration, frozen product context and relevant algorithm settings. Keep byte-level media identity checks local, without reading/exporting secrets.

Acceptance: legacy decode, deterministic round-trip, zero archive/absolute paths in projected output, stable IDs when selection order changes, changed inputs invalidate only dependent data.

## 5. LE02 / A — local procedure outline

Integrate after usable transcript load and refreshed Shot/Pin inventory, before clip ranking. Build draft outline from full private transcript locally; attach selected windows later.

Initial rules:
1. Validate finite ordered timestamps, sort deterministically, keep capture-source provenance and uncertain speaker attribution.
2. Use sentence/word boundaries plus explicit procedural cues in Romanian and English (ordinal transitions, action verbs, stated expected result). Maintain small documented lexicons with examples and negative cases. No generated paraphrases in version 1.
3. Export verbatim bounded action excerpts; otherwise label text as a review passage. Chronology does not prove logical dependency. Preserve corrections/revisits rather than globally deduplicating repeated wording.
4. For boundary segments use word timestamps; without them keep a wholly contained segment or flag an unavailable excerpt. Never manufacture word timing.
5. Every asserted textual step cites its selected source excerpt and time. A human note is a separately labeled source; an image without interpretation only establishes frame availability.
6. Initial text bounds: at most 128 step/review entries, one selected quote <=320 Unicode characters per entry, <=64 KiB total selected quotation UTF-8 bytes; truncate at a source boundary. Bound all derivative serialized text to <=512 KiB across the procedure representation before renderer duplication. If limits are hit, preserve omitted-range/count metadata and mark outline partial. Do not reconstruct the full transcript under another filename.
7. Keep steps independent from the 8-task and 12-window limits. Legacy task rows may link to steps but cannot be the only storage for them.
8. Product context remains the recording snapshot. Empty fields are unspecified. All local output is review-only, even when a quote and image both exist.

Generate chapter navigation at explicit discourse boundaries when supported; use neutral chronological ranges otherwise. Do not claim semantic topic boundaries from a time split. No new elaborate chapter UI.

Acceptance: synthetic 10/40/50/120/180-minute sessions, RO/EN/mixed and unsupported cue patterns, no old keywords, repeated steps, correction, silence, malformed/partial transcript, no words, Shot-only/Pin-only, text bounds. Unsupported structure produces honest review/gaps, not fabricated completeness.

## 6. LE03 / B — coverage-aware <=12 windows

Candidate sources: all human anchors, action-excerpt anchors, existing keyword hits, fallback review passages from otherwise unrepresented occupied temporal bins. Use 12 equal-duration bins only as a distribution metric/fallback, not as semantic chapters.

Start with 20-second windows, adjust to useful utterance boundaries within 15–25 seconds and clamp to media. A whole session shorter than 15 seconds is an explicit exception. No zero, inverted, NaN or out-of-media ranges.

Merge only when the union is <=25 seconds; union ALL provenance IDs/stills, not only one associatedShotId. For larger unions retain candidates for ranking, rather than clamping away an anchor. Cover the current later-higher-score regression separately.

Greedy selection, lexicographic marginal gain:
1. number of previously unrepresented human anchors;
2. number of previously unrepresented action-excerpt steps;
3. number of previously unrepresented occupied temporal bins;
4. legacy relevance/usable source support.
Tie-break by start time, then stable ID. Select <=12 and render chronologically. Exact/near-duplicate windows with no marginal information must not consume capacity.

A step counts as visually covered only if its required action interval is represented by suitable surviving evidence; mere window overlap does not prove visibility. Keep temporal-window overlap and reviewed semantic evidence as separate metrics.

When >12 distinct human windows compete, keep all anchor records and mark the unselected ones with capacity reasons. No algorithm can guarantee every visual step fits; export is partial when required evidence is missing.

Acceptance: dense early keywords do not starve a 10–12-stage synthetic procedure across the timeline; >12 Pins and >20 Shots all remain accounted; mixed merges retain provenance; stable ties; chronological output; no accidental maxTasks truncation of outline.

## 7. LE04 / C — evidence and measured packing

Preserve human shots first. Allocate one generated still per selected window lacking an adequate Shot, before assigning remaining capacity (16 extra stills total) to before/after pairs. Start with the step anchor time; nearby fallback frames must remain within the associated interval. Record actual extractor time, not just requested time. Deduplicate identical assets while retaining all owners.

Separate still extraction failure from clip encode failure. If video encoding fails, try extracting a still independently from the source. A successful decode is not a semantic quality claim; inspect readability on real fixtures.

Continue to encode through ClipExporter and project through ExportProjector. Register procedure evidence with omission priority, so evidence for steps outside legacy tasks is not treated as unrelated extras. Preserve the established contractual omission class order; within a class prefer dropping redundant evidence before the last evidence for a step. Budget wins over any reservation.

Extend stripOmitted and final evidence validation to steps, anchors, chapter indexes and renderers. A dropped asset updates its availability/reason and removes the link; the step/anchor remains visible. Bound renderer text to avoid protected documents defeating C3. Reweigh after FINAL rewrites, until stable or explicit failure.

Acceptance: real playable clip, <=16 generated stills, correctly timestamped references, dense IDE readability, 12x25s +20 Shots oversized case, incompressible bytes, failed encode/extraction, stale files, missing media, symlinks, omitted sole evidence, last-write budget growth, ZIP failure and folder-only readiness distinction. Do not count ZIP nonexistence as success.

## 8. LE05 / D — export honesty and pipeline integration

AgentContextRenderer / SessionBriefRenderer / BriefPresentation / AGENT_PROMPT:
- show frozen context, local chronological outline, source excerpts and links, then gaps and separately attributed provider findings;
- distinguish transcript-supported, human-note-supported, visual file available, evidence omitted/missing, and manual semantic review;
- show counts and exact bytes; no 'complete procedure' claim from stage completion or distribution metrics;
- state local processing without misleading API Offline/provider-dependent summary absence;
- remove active links to missing evidence; retain anchor notes/time and omission explanation;
- consume projected excerpts/metadata, not private transcript reads for normal selected-content rendering;
- retain the existing explicit full-transcript inclusion path and remove the full transcript from rendered output when omitted;
- sanitize/wrap all derived content and preserve HTML escaping.

Use an explicit localOnly processing/replay boundary that bypasses all provider branches and consent prompting. Ordinary no-consent/no-key local fallbacks receive the new outline automatically. Expose re-generation through the existing review/retry flow with a small explicit local-only action if necessary; do not add a new major product surface. A replay test-only helper alone is not product integration.

Version/fingerprint invalidation must cover completed slicing, localReviewTasks/abandonEvaluate, selected-primary transcription changes, updateSpeakers, interrupted processing and incomplete-handoff output. Unchanged provider results must keep valid provenance; changed windows/excerpts must never reuse successful comparison state. Recheck input identity before committing derived results, so a late Shot edit cannot race with outline generation.

Generation must not depend on entering abandonEvaluate: all local, provider-skipped and provider-success paths get consistent local outline. A transcript failure remains retryable; incomplete outline does not falsely complete failed transcription. Avoid reloading the current context for old recordings.

Acceptance: new Stop/local fallback and existing-session local regeneration work; interrupted retry and no-op retry deterministic; no provider calls with old approved consent/keys/comparison results; fresh outline when algorithms/primary transcript/notes change; unchanged inputs retain correct service results; export-only rendering parity.

## 9. LE06 — validation and PR acceptance

Implement the private-copy harness described in VALIDATION.md using the same production builder/ranker/projector. Never point a test processor at the real session vault. No performance/coverage numbers are pre-approved: collect them.

Required PR evidence:
- meaningful Swift core/unit/integration tests and existing Linux suite;
- two existing-session before/after comparisons (12 and 41-minute candidates), plus other 10–50-minute recordings when available;
- synthetic 50/120/180-minute tests, explicitly not real capture validation;
- independently annotated step reference fixed before tuning, with one recording held out until the first implementation is complete;
- raw bytes, step recall/unsupported assertions, visual evidence coverage, all-anchor accounting, links/ZIP consistency, repeatability, runtime/disk observations, and zero provider calls;
- consumer exercise with only export mounted/available; answer references must resolve there;
- original input hash verification before and after replay;
- no private content in published diff, fixtures, logs or PR text.

Per how-to fixture: 100% critical step recall, >=90% secondary recall, zero unsupported asserted actions/parameters/results; every critical visual requirement has readable evidence in export. Any missing critical support is a failed semantic acceptance, even if honestly marked partial. Honest partial output is nevertheless required for overflow/unsupported/negative test cases. Do not lower thresholds to obtain green results. If local rules cannot pass, document the exact failure and leave acceptance open; cloud is not a workaround.

Non-procedural recordings are negative cases, not opportunities to invent steps. User/human review of semantic references is required before claiming semantic acceptance; automated quote checks cannot establish completeness.

No global hardware gate closure. Mac/Xcode success is code/media evidence, not Record/Pause/drift evidence. Do not run mac_gate01.sh, terminate the installed app, or reinstall it as part of this task.

## 10. Suggested commit sequence inside the next PR

1. LE01 + regression fixtures and anchor/schema migration.
2. LE02 + minimal LE05 outline rendering for inspection.
3. LE03 selection and actual Swift behavior tests.
4. LE04 evidence projection/packing and post-omit renderer updates.
5. Complete LE05 retry/local-only/product integration.
6. LE06 private replay harness, redacted validation report, contract documentation updates.

All six are required for this compact-workflow PR. Keep commits independently reviewable. Add new files to Xcode target/project membership as required. Preserve valuable string-based contract checks; when an invariant moves, update its check with behavioral coverage, not by deleting coverage.

## 11. Follow-up: detailed chapter packs

Later PR only: user-selectable compact versus detailed export; global index mapping stable step/chapter IDs to self-contained chapter exports, each <=existing byte cap; accurate total byte count; chapter-local <=12-window budgets; individual omission reports; no archive links. A chapter exceeding one pack may need explicitly labeled parts. No new full-transcript/provider consent is implied. Cross-chapter references must resolve within the provided bundle and not silently require another unprovided pack.

Do not describe today's compact 35 MB pack as exhaustive evidence for three hours. This PR demonstrates bounded processing of long synthetic input and honest gaps, not 2–3-hour real capture reliability.
