# ScrumTrace

Mac menu-bar recorder for sprint demos and design reviews. It captures screen, system audio, and microphone on one clock, then writes an **`export/`** folder for Cursor / Claude Code — not the private archive.

The working spec is [IMPLEMENTATION_PLAN.md](IMPLEMENTATION_PLAN.md) (contracts revised 2026-09-09). Direction is approved; the spec is **not locked** and is **not production-ready**.

## What exists in this tree

- Native Swift menu-bar app (`com.str8minds.ScrumTrace`, sandbox off)
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

Menu → Settings (also ⌘,) has **Speech**, **Capture**, **Logs**, **Permissions**, **AI**, and **General**. Capture shows the shipped 3840×2160 / 4 fps / 16 Mbps (24 Mbps cap) budget, plus pointer and microphone toggles. Start recording opens a selection overlay like macOS screen recording (lasting box, move, resize, then Record or Return on that display). Logs can export a diagnostic bundle (no `archive/`).

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

## Contexts, Settings and speaker review

In **Settings → General → Product contexts**, create a saved context for each product or type of call. Contexts have a name plus optional product name, repository and tech stack. You can edit, duplicate or delete them. The old single product setting is imported once into this library.

**New Recording…** (⌘N) or **Start recording** first asks you to confirm the context, then opens the capture-area picker. The previous selection is offered again; you can switch from ScrumTrace to GIB or choose **No context**. You can also create or edit a context directly from this step. Cancelling either step starts no recording.

Each session saves a copy of the confirmed context, including its name and ID. Later profile changes, deletion, or switching products do not alter that session or its subsequent analysis/export. When the optional product name is blank, the context name supplies it. Context selection is manual in v1; automatic selection is deferred to v2.


In **Settings → Speech**, choose the meeting language and preload the selected Whisper model before recording. Romanian is available explicitly. Existing transcripts keep their recorded language until analysis is run again.

Speaker identification is enabled by default on new installations and runs locally after transcription. It requires macOS 15+ and downloads the FluidAudio 0.15.7 speaker models on first use; **Preload speaker models** prepares them in advance. Room-microphone and call-audio speakers have separate anonymous IDs. Audio and voice embeddings are not uploaded for this analysis, and embeddings are not saved. This does not recognize people's names or link identities between meetings.

Use **Review and name speakers…** to select a session and click a transcript passage to play its video with room and call audio. Enter names for that session, use **Correct** on a passage to change its speaker, then **Save names and corrections**. Saving refreshes the local transcript, brief and session pack without another AI-provider request. **Discard edits** restores the saved version. Older sessions can use **Analyze speakers locally…**; reanalysis replaces names and corrections for sources it successfully analyzes.

The exported brief shows speaker labels and clickable passages within each selected clip. Estimates, unclear passages and overlapping voices remain marked for review. Use headphones to reduce call audio leaking into the room microphone. Real multi-person accuracy and long-run synchronization still need hardware validation; local tests do not close those gates.

In **AI**, each provider retains its own endpoint and model. API keys are saved explicitly for the selected provider and endpoint; saved keys are not displayed again. **Logs** filters the current run and can export diagnostics. **General** explains retention: completed recordings are removed on the next launch when their retention period expires; **Forever** keeps them.

## Hotkeys

| Action | Key | While paused |
|---|---|---|
| Shot | ⌥⌘S | Disabled (no new frame) |
| Pin | ⌥⌘↩ (Return) | Ignored |
| Pause | ⌥⌘P | Toggles. No new bytes from any capture source. In-flight Hold-to-Talk is aborted. |

## Handoff

Give the agent **`export/`** only. Never drop the session root or `archive/` (master `session.mp4`, `audio.wav`, full transcript, raw events). Paths inside the pack are relative to that folder (`shots/…`, `media/…`).

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
