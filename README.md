# ScrumTrace

Mac menu-bar recorder for sprint demos and design reviews. It captures screen, system audio, and microphone on one clock, then writes an **`export/`** folder for Cursor / Claude Code — not the private archive.

The working spec is [IMPLEMENTATION_PLAN.md](IMPLEMENTATION_PLAN.md) (contracts revised 2026-09-09). Direction is approved; the spec is **not locked** and is **not production-ready**.

## What exists in this tree

- Native Swift menu-bar app (`com.str8minds.ScrumTrace`, sandbox off)
- A ScrumTrace window with **Overview**, **Recordings**, **Contexts** and **Settings**, opened from the app icon or **Open ScrumTrace…** in the menu
- Pause gate shared by screen, system audio, microphone, metadata, Shot, and Hold-to-Talk
- WhisperKit transcribes the room-mic WAV **and** system audio in `archive/session.mp4`, then merges on `t_media`
- Local speaker estimates for room and call audio, with session names, manual corrections and synchronized transcript/video review (macOS 15+)
- Gate 3/6 timings written to `archive/pipeline-timing.json` (never in the export zip)
- Session disk layout: `archive/` (private) vs `export/` (handoff, export-relative paths)
- Measured 35 MB `session-pack.zip` with `OMITTED.md` when the cap drops files
- Pluggable AI adapters behind one internal contract (MVP: OpenAI-compatible + JSON Schema)
- Timeline / contract / transcript-merge / pack-budget / evidence tests (no Mac required): `bash scripts/run_linux_tests.sh`

## Open in Cursor

Working branch is **`develop`**. GitHub `main` is an older spec-only history — do not merge or force-push it. Agents: start at [AGENTS.md](AGENTS.md).

This repo is the Cursor project. On a Mac:

```bash
git clone -b develop https://github.com/ciprian-lupu/scrumtrace.git
cd scrumtrace
cursor .
```

Or **File → Open Folder** on that clone. Run **Linux tests** / **Serve SESSION_BRIEF preview** from the Command Palette tasks. The menu-bar app still needs Xcode on macOS 14+.

Cloud / Linux agents use `.cursor/environment.json` (regenerate the mock pack, serve the brief on port 43147). They cannot compile ScreenCaptureKit or run Gate 0/1.

## Build (macOS 14+, Apple Silicon recommended)

```bash
bash scripts/mac_gate01.sh
open ~/Applications/ScrumTrace.app
```

The script copies the Debug build to `~/Applications/ScrumTrace.app` and signs it with a local **ScrumTrace Debug** identity (created once in your login keychain). Ad-hoc Xcode builds look like a new app to macOS on every rebuild, which is why Screen Recording and Microphone keep asking after you already flipped the toggle.

Open **that** copy only. In System Settings, remove extra ScrumTrace rows, enable Screen Recording and Microphone for this app, then **Relaunch** from the menu. A grant never applies to the process that was already running. Accessibility is optional.

Xcode resolves WhisperKit **0.11.0** from the committed `Package.resolved`. First WhisperKit launch downloads the compressed turbo model (`openai_whisper-large-v3-v20240930_turbo_632MB`, about 632 MB). The HUD shows **Loading Whisper model…** with elapsed seconds; it no longer sits on “Transcribing locally with WhisperKit” during the download.

Archive capture is **3840×2160 at 4 fps, 16 Mbps H.264 High** (keyframe every second). Export clips stay 720p / 1.2 Mbps.

Settings (⌘, or menu → Settings → Settings Window…) is a section of the ScrumTrace window with **Speech**, **Capture**, **Logs**, **Permissions**, **AI**, and **General**. Capture shows the shipped 3840×2160 / 4 fps / 16 Mbps (24 Mbps cap) budget, plus pointer and microphone toggles. Start recording opens a selection overlay like macOS screen recording (lasting box, move, resize, then Record or Return on that display). Logs can export a diagnostic bundle (no `archive/`).

Inspect every gate that has artifacts (Phase −1 mock, −0, 0, 1, Shot-pause log, 3–6). ASCII / JSON checks are required and still do not replace a Keynote focus check or a manual media scrub. The helpers never write `samples/GATE_LOG.md`:

```bash
bash scripts/mac_all_gates.sh --begin
bash scripts/mac_all_gates.sh --latest \
  --manual-video-scrub-ok --manual-audio-scrub-ok \
  --av-offset-ms 12 --ptt-temp-deleted-ok \
  --target-media-seconds 300 --target-wall-seconds 15 \
  --chrome-playback-ok
# Strict all-gate acceptance needs a multi-session artifact map:
# python3 scripts/inspect_all_gates.py --artifact-map path/to/map.json --strict
python3 scripts/inspect_all_gates.py --session /path/to/session \
  --log ~/Library/Logs/ScrumTrace/agent.jsonl --log-start-line N \
  --token 'ST-G1-PAUSE-TOKEN-9F3C' \
  --passphrase 'orchid lantern seven' \
  --manual-video-scrub-ok --manual-audio-scrub-ok \
  --av-offset-ms 12 --ptt-temp-deleted-ok
```

Gate 0 only: `python3 scripts/inspect_gate0_log.py --log ~/Library/Logs/ScrumTrace/agent.jsonl`  
Gate 1 only: `python3 scripts/inspect_gate1_session.py --session /path/to/session --token 'ST-G1-PAUSE-TOKEN-9F3C' --passphrase 'orchid lantern seven'`

## Main window

Opening ScrumTrace from Finder, Launchpad, Spotlight or the Dock shows the **ScrumTrace** window on Overview. Launched as a Login Item or by the Mac agent loop, ScrumTrace stays in the menu bar. **Relaunch ScrumTrace** brings the window back only if it was open, and never when ScrumTrace was started with `--background` (by the agent loop, or by an earlier relaunch with the window closed). Clicking the app icon again, or choosing **Open ScrumTrace…** in the menu-bar menu, brings the same window forward on the section you left. ⌘1 to ⌘4 switch sections and ⌘, opens Settings. Hotkeys, starting or stopping a recording, processing and timers never open the window or bring it forward on their own. An alert that needs an answer, such as upload consent during processing or a failed start, still activates ScrumTrace; while the window is open it may bring the window forward too (not yet checked on a Mac). While a recording runs, a banner with Pause and Stop sits above every section.

- **Overview** — *Ready to record?* lists Screen Recording, Microphone, Accessibility, the speech model, the AI service and the meeting notice, each with the button that fixes it and a note when a relaunch is needed. **Start recording** uses the same flow as the menu. *Needs attention* lists unfinished recordings (with Retry analysis), unreadable manifests, the last error, the retention period and an update that a check already found; the window itself makes no network request. *Last recording* and *Storage* (Recordings folder, recording count, private archive size and retention) follow.
- **Recordings** — every session, newest first, with date, context / product, recorded time, status, Shots, tasks and pack size. Search (⌘F) matches the session id, date, context and product names only, never transcripts, Shot notes or task titles; Escape clears it. Filter by status or context. The detail pane shows processing stages, upload consent, export files and Shot thumbnails from `export/shots/`. Actions: Reveal export/ (⌘R), Open in Claude, Open in Codex, Open brief, Copy export path, Retry analysis, Review speakers…, Reveal archive… (after a warning) and Delete… (Delete key; asks first, removes `archive/` and `export/`). Session-changing actions wait while a recording or analysis runs. Drag a row to drop its `export/` folder into Cursor, Terminal or Finder; only `export/` is offered. A session whose manifest cannot be read is listed as **Unreadable manifest** with Reveal folder… and Delete… only.
- **Contexts** — saved contexts with how many recordings used each one and when. New, Edit, Duplicate, Delete, Set as default and **Record with this context…**, which still asks you to confirm the context before the capture-area picker. Deleting a context never changes existing recordings.
- **Settings** — the six tabs described above.

While the window is open, ScrumTrace has a Dock icon and a ⌘-Tab entry. Turn this off in **Settings → General** (*Show ScrumTrace in the Dock while its window is open*). Closing the window returns ScrumTrace to the menu bar once no other ScrumTrace window, such as the first-run permissions window, is still open. Closing it is also meant to give focus back to the app you used before; that hand-back has not been checked on a Mac yet. The Mac agent loop opens the app with `--args --background`, so it never shows the window.

## Contexts, Settings and speaker review

In **Settings → General → Product contexts** or the window's **Contexts** section, create a saved context for each product or type of call. Contexts have a name plus optional product name, repository and tech stack. You can edit, duplicate or delete them. The old single product setting is imported once into this library.

**New Recording…** (⌘N) or **Start recording** first asks you to confirm the context, then opens the capture-area picker. The previous selection is offered again; you can switch from ScrumTrace to GIB or choose **No context**. You can also create or edit a context directly from this step. Cancelling either step starts no recording.

Each session saves a copy of the confirmed context, including its name and ID. Later profile changes, deletion, or switching products do not alter that session or its subsequent analysis/export. When the optional product name is blank, the context name supplies it. Context selection is manual in v1; automatic selection is deferred to v2.


In **Settings → Speech**, choose the meeting language and preload the selected Whisper model before recording. Romanian and Hungarian are available explicitly. Existing transcripts keep their recorded language until analysis is run again.

Speech profiles are separate from AI-analysis services. Add named local WhisperKit or OpenAI transcription profiles, choose one as the normal default, and check profiles only for an explicit comparison. A cloud profile stores its key in Keychain; profiles may reuse a credential ID when they intentionally share a key. Automatic detects language, a single selection is sent as a recognition hint, and the Romanian/English/Hungarian multi-language mode is saved as expected-language context/validation—not incorrectly sent to WhisperKit as `ro,en,hu`. No mode requests translation.

To compare an existing recording, check at least one profile and choose **Menu → Compare transcriptions** (or the action in a Recent session). Every profile runs serially against the same canonical private audio file and creates a separately fingerprinted archive result with its requested/resolved model, language strategy, duration and status. Cloud runs show a dedicated audio-upload consent sheet naming the endpoint, model, audio source and duration. Pick a completed result to make it primary; prior results are retained privately and dependent slices/AI analysis are cleared until Retry Analysis regenerates them. Comparative transcripts and audio are never automatically put in `export/`.

Speaker identification is enabled by default on new installations and runs locally after transcription. It requires macOS 15+ and downloads the FluidAudio 0.15.7 speaker models on first use; **Preload speaker models** prepares them in advance. Room-microphone and call-audio speakers have separate anonymous IDs. Audio and voice embeddings are not uploaded for this analysis, and embeddings are not saved. This does not recognize people's names or link identities between meetings.

Use **Review and name speakers…** (Settings → Speech, or **Review speakers…** on a recording in the window) to select a session and click a transcript passage to play its video with room and call audio. Enter names for that session, use **Correct** on a passage to change its speaker, then **Save names and corrections**. Saving refreshes the local transcript, brief and session pack without another AI-provider request. **Discard edits** restores the saved version. Older sessions can use **Analyze speakers locally…**; reanalysis replaces names and corrections for sources it successfully analyzes.

The exported brief opens review items when there are no confirmed findings. Processing status distinguishes unavailable transcription, speaker estimates, and AI analysis skipped without upload consent. The overview groups confirmed findings into highlights, decisions, actions and explicitly unresolved questions, with evidence links; it does not invent conclusions, owners or deadlines. Export actions link only existing, included files. If full-transcript export is enabled, the brief also offers a readable full transcript; only selected clips have playable video.

WhisperKit's prefill cache is disabled for decoding because it produced empty 30-second windows with the compressed multilingual turbo model on recorded audio. Empty non-silent results remain retryable and are shown as unrecognized speech; digitally silent sources are identified separately. A silent source does not overwrite the language of the source containing text. ASR output and anonymous speaker estimates still require human review.

The exported brief shows speaker labels and clickable passages within each selected clip. Estimates, unclear passages and overlapping voices remain marked for review. Use headphones to reduce call audio leaking into the room microphone. Real multi-person accuracy and long-run synchronization still need hardware validation; local tests do not close those gates.

In **AI**, save each provider as a named service (Hive, DeepSeek, OpenAI, and so on) with its own endpoint, model, and key. Only explicitly checked services are used for comparison analysis. Saved keys are not displayed again. The previous single provider setting is imported once. **Logs** filters the current run and can export diagnostics. **General** explains retention: completed recordings are removed on the next launch when their retention period expires; **Forever** keeps them.

## Hotkeys

| Action | Key | While paused |
|---|---|---|
| Shot | ⌥⌘S | Disabled (no new frame) |
| Pin | ⌥⌘↩ (Return) | Ignored |
| Pause | ⌥⌘P | Toggles. No new bytes from any capture source. In-flight Hold-to-Talk is aborted. |

## Handoff

Give the agent **`export/`** only. Never drop the session root or `archive/` (master `session.mp4`, `audio.wav`, full transcript, raw events). Paths inside the pack are relative to that folder (`shots/…`, `media/…`).

**Open last session in Codex** in the menu and **Open in Codex** in Recordings follow **Settings → AI → Local coding agents → Open in Codex**:

- **Codex app** (default): opens a new local task with the validated export/ folder and a prepared prompt. The prompt stays in the composer until you send it. The app must be installed and opened once on this Mac; no separate CLI installation is needed.
- **Codex CLI in Terminal**: starts the interactive codex command with its working directory bound to export/. Install the CLI and sign in with ChatGPT in Terminal first. Allow ScrumTrace to control Terminal when macOS asks.

**Open last session in Claude** / **Open in Claude** still uses the interactive claude command in Terminal with your existing Claude login. Neither CLI uses claude -p or codex exec. These handoffs do not use a ScrumTrace API key and never open archive/. A full transcript in export/ is allowed only when the export manifest explicitly includes it and it was not omitted from the pack.

After replacing or rebuilding ScrumTrace, quit the old process and reopen the installed copy. macOS can refuse Automation when the running process no longer matches its binary on disk. If Automation was denied, enable Terminal under **System Settings → Privacy & Security → Automation → ScrumTrace**; no macOS permission is changed automatically.

The app handoff uses the [documented Codex workspace and prompt link](https://learn.chatgpt.com/docs/reference/commands#deep-links).


Phase -1 mock pack (open in a browser or drop into Cursor):

```bash
python3 scripts/generate_mock_session.py
python3 scripts/serve_preview.py --port 43147
```

Then open `samples/mock-session/export/SESSION_BRIEF.html`. The image-only failure code and the clip-only recovery sequence are **not** in `AGENT_CONTEXT.md` — they live in `shots/` and `media/task-02/clip.mp4`. See `samples/mock-session/HANDOFF_LOG.md`.

## Agent debug loop

The Mac writes `~/Library/Logs/ScrumTrace/agent.jsonl` and a LaunchAgent can pull `develop`, rebuild **only on request**, and publish that log to `cursor/scrumtrace-agent-logs-0397`. Cloud agents read it with `bash scripts/fetch_agent_log.sh`. See [AGENT_DEBUG.md](AGENT_DEBUG.md).

## What this Linux / cloud agent can test

This application is ScreenCaptureKit + WhisperKit. A Linux VM cannot compile or run it. What *can* run without a Mac:

```bash
bash scripts/run_linux_tests.sh
```

GitHub Actions (`.github/workflows/ci.yml`) runs those tests on Ubuntu and, when the repo is on GitHub with Actions enabled, `xcodebuild` on `macos-15`. That compiles the app. It still cannot grant Screen Recording, show a display, or fill `samples/GATE_LOG.md`.

There is no honest ScreenCaptureKit emulator. Hardware gates stay on one Mac after the code is finished.

## Next gates (must run on a Mac)

Use the fill-in log at [`samples/GATE_LOG.md`](samples/GATE_LOG.md). Linux tests do **not** prove these.

1. Phase −0: 30 s Record, then `inspect_gate_minus0.py` (movie + WAV + first samples)
2. Phase 0–1: Keynote focus; 20 min record, 3 pauses, all-source pause token test (screen, system audio, mic, Shot, Hold-to-Talk)
3. Phase 3: WhisperKit elapsed time on a named Mac; confirm `full_transcript.json` `sources` includes room and system when both were captured
4. Phase 4–6: ≤ 12 slices; measured zip ≤ 35 MB; consent / evidence; remaining `AGENT_CONTEXT.md` paths exist


### Comparing services and models

In Settings → AI, add a named service for each endpoint/model combination. Duplicate a service to compare another model at the same endpoint, then edit its model and save. The active service controls editing and connection testing; the comparison checkboxes control uploads. Unchecking all services stays local, including after relaunch.

Record once, then approve the listed destinations at Stop. Every selected, configured service evaluates every slice serially using the same system/user prompts, transcript excerpt, notes, context and up to four JPEG stills. Comparison excludes video for all providers. The HTTP envelope and provider-specific structured-output controls still differ; model outputs are not deterministic.

The brief and AGENT_CONTEXT include a per-slice/service status table and SHA-256 input fingerprints. Results stay grouped by service/model; there is no consensus or ranking across models. A successful empty candidate response is still a completed evaluation, with any local evidence review shown separately.

Retry Analysis resumes unfinished pairs and preserves successful results for unchanged destinations. Adding a service asks for consent again and evaluates only the new service plus unfinished pairs. Changing a model or endpoint invalidates that service's results. Missing keys/configuration skip that service; HTTP 401/403 stops all remaining uploads for that attempt.

The fingerprint includes the exact prompts and encoded image bytes. If evidence or prompts changed between attempts, Retry refuses the changed input before uploading it and reports `comparison_input_changed`; existing results stay available. Start a new recording for revised evidence. Older results without fingerprints must be evaluated once with the new implementation before they count as verified comparisons. No transcript, image payload or API key is included in the fingerprint table.

Verification uses synthetic providers and temporary sessions. A live multi-provider session still requires configured keys, explicit upload consent and inspection of the resulting export; software tests do not close hardware gates.

## Transfer a recording between Macs

In **Recordings**, open the **Transfer recordings** toolbar menu:

- Select recordings with **Command-click** or **Shift-click**, or choose **Select all listed recordings** in the transfer menu. **Export for another Mac…** defaults to the existing export evidence. Choose **Complete recording** and explicitly check the private-data option to include original video/audio, full transcripts, raw events, previous results and available session diagnostics. For multiple recordings, choose one destination folder; each gets its own package. Hidden selections and unreadable recordings are excluded.
- Copy the whole **.scrumtrace package** to the receiving Mac. This is a Finder package containing ordinary files and a versioned checksum index. A complete transfer can exceed 35 MB; the separate coding-agent session-pack.zip remains capped at 35 MB.
- Choose **Import recordings…** on the receiving Mac and select one or more packages or folders together. Older versions can be migrated by copying the entire session folder; an existing export folder is also accepted. Unzip a legacy session pack first and select its folder.
- Imported rows show **Imported**, source/export information and which materials are available. File verification does not establish transcription accuracy. A legacy folder has no source checksum claim.
- **Analyze a copy** reuses the available transcript and starts fresh evidence evaluation in a separate session. **Transcribe a new copy** requires original media and starts transcription again. The receiving Mac uses its own selected services and asks for fresh upload consent. Original imported results remain available.
- Read **export/TRANSFER_REVIEW.md** for technical facts, missing evidence and measured before/current outcomes. New transcription times are reported only when transcription actually runs again. More findings alone do not establish better quality.

A result list shows each completed, skipped or failed transfer. Duplicate imports and existing destination packages are skipped; an invalid item does not stop the remaining selection. Cancel removes the unfinished copy and keeps transfers already completed. The private-data choice applies to the selected recordings together; provider upload consent is still reset independently in every import.

Keys, app settings and macOS permissions are not transferred. Complete packages are private Mac-to-Mac transfers; coding agents receive only export/. Newly imported old recordings receive the configured retention period from their import date.

The original app's capture environment is recorded only for new captures made with this version. Older sessions show it as unavailable instead of attributing them to the Mac that exported them.
