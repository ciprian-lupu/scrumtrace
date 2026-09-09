# ScrumTrace — Implementation Plan (Hardened & Audited Specification)
**Audited Architecture for High-Fidelity Meeting & Presentation Context Capture for AI Coding Agents**

---

## 1. Product Vision & Downstream Handoff Contracts

### Context & Persona
You present or collaborate live from a Mac during technical meetings (sprint demos, architectural discussions, bug bashes, live design reviews). You want any AI coding agent to receive high-fidelity, multimodal context (screens, code, diagrams, spoken rationale, decisions) without manually writing notes.

### Downstream Consumer Reality & Handoff Contract
We do not make vague claims that "uploading a zip to any AI understands video and images". The handoff contract is strictly defined by tier:

| Consumer Tier | Target Tools | Ingestion Mechanism | What the Model Actually Receives |
|---|---|---|---|
| **Tier 1: Filesystem-Aware Coding Agents (Primary)** | **Cursor**, **Claude Code CLI**, **Windsurf**, **Aider** | Drop session folder into workspace or reference `@AGENT_CONTEXT.md` | Model directly reads Markdown, follows relative paths, and inspects images (`shots/`, `media/`) via local filesystem tools. |
| **Tier 2: Web Chat Interfaces (Secondary)** | **Claude.ai**, **ChatGPT** | User uploads `session-pack.zip` or attaches individual `shots/*.png` + `AGENT_PROMPT.txt` | Text prompt and raw attached images. (Clips are retained in the zip for human reference; web LLMs do not reliably unpack zip archives to watch MP4s). |
| **Tier 3: Human Stakeholders & Team Members** | Any Web Browser | Double-click `SESSION_BRIEF.html` | Self-contained, responsive dashboard with playable HTML5 video clips, image lightboxes, quotes, and transcript appendix. |

> [!IMPORTANT]
> **Pre-Flight Acceptance Test (Before Phase 0 Code):**
> Create a manual mock session folder with 2 tasks: 
> 1. One fact present *only* in a screenshot.
> 2. One sequence present *only* in a clip.
> 
> Confirm that Cursor / Claude Code extracts these facts before any capture code is written.

---

## 2. Core Decisions

| # | Decision | Meaning |
|---|---|---|
| **D1** | Live Meeting & Presentation Focus | Room mic + system audio. One Mac. Works over Keynote, browser, IDE. |
| **D2** | Master Clock PTS Synchronization | Video and audio inputs are locked to `CMClockGetHostTimeClock()`. Guaranteed zero AV drift over 60+ min. |
| **D3** | Strict Pause Contract & Zero Persistence | When paused, screen frames, microphone audio, and metadata are **completely discarded**. Nothing is written to MP4/WAV. |
| **D4** | Unified Timeline Contract (`t_wall` vs `t_media`) | Explicit mathematical mapping between real elapsed time and recorded media presentation timestamps. |
| **D5** | Privacy & Transcript Partitioning | Full transcript remains in the **local archive only**. The export pack contains **task-relevant excerpts only** (full transcript is opt-in). |
| **D6** | Evidence-Grounded Schema | Model outputs must distinguish between `observed` (screen evidence), `stated` (human quote), and `inferred` (model hypothesis). |
| **D7** | No Silent Dropping | Slices with low confidence ($< 0.55$) are marked as `needs_review` in a collapsed section, never silently deleted. Human shots are always kept. |
| **D8** | Multi-Candidate Slices | Each candidate slice evaluates `candidates[]` so multiple bugs/decisions in a single 30s clip are not merged or lost. |
| **D9** | Deterministic Media Budget | Slices are re-encoded to 720p @ 1.2 Mbps ($\approx 3.0\text{ MB}$ per 20s clip). Total pack size strictly capped $\le 35\text{ MB}$. |
| **D10** | Single Source of Truth (`session.manifest.json`) | All timestamps, pause intervals, slices, evidence links, and task states derive from one versioned manifest file. |
| **D11** | Model-Agnostic Pluggable Engine | Pluggable backend supporting any OpenAI-compatible endpoint (Ollama, vLLM, OpenAI), Anthropic API, or Google API. |
| **D12** | Async Non-Blocking Sampler | Accessibility queries (`AXUIElement`) run on a background queue with a 200ms timeout; never freeze UI. |

---

## 3. The Timeline & Pause Contract

### Mathematical Mapping
- **Wall-Clock Time ($t_{\text{wall}}$)**: Continuous real-world seconds since recording was started. Used by the HUD and real-time events.
- **Media Presentation Time ($t_{\text{media}}$)**: Continuous playback seconds of `session.mp4` and `audio.wav`. Advances **only** when recording is active.

$$\Delta t_{\text{paused}}(t) = \sum_{i \in \text{completed\_pauses}} (\text{resume}_i - \text{pause}_i) + [\text{current\_time} - \text{pause}_{\text{active}}]$$
$$t_{\text{media}} = t_{\text{wall}} - \Delta t_{\text{paused}}(t)$$

### Pause Invariants
1. **Zero Persistence:** From the microsecond Pause is confirmed:
   - `AVAssetWriterInput` stops accepting video frames.
   - Microphone PCM buffers are discarded (zero samples written to `audio.wav` or `session.mp4`).
   - `MetadataSampler` suspends window and URL logging.
2. **Timeline Integrity:** All slice ranges, transcript segments, and video cut points are strictly indexed in **$t_{\text{media}}$**.
3. **Acceptance Test:** While paused, display a secret token on screen and speak a secret passphrase. Inspect `session.mp4`, `audio.wav`, `transcript.json`, and all exports. The secret must be completely absent. Slices spanning around the pause boundary must remain in perfect AV sync.

---

## 4. Session on Disk & Manifest Architecture

All data flows from a single source of truth: `session.manifest.json`.

```text
~/Movies/ScrumTrace/sessions/2026-09-09-1530-meeting/
  session.manifest.json     ← SINGLE SOURCE OF TRUTH (versioned schema)
  AGENT_CONTEXT.md          ← Clean Markdown for Cursor / Claude Code CLI
  SESSION_BRIEF.html        ← Self-contained visual HTML dashboard
  AGENT_PROMPT.txt          ← Clean text prompt for web chat interfaces
  session-pack.zip          ← Compressed bundle (≤ 35 MB)
  
  # Local-Only Archive (Never included in default session-pack.zip)
  session.mp4               ← Continuous recorded video (H.264/HEVC)
  audio.wav                 ← Clean 16kHz mono audio
  full_transcript.json      ← Complete meeting transcript
  events.jsonl              ← Raw timeline events (pins, pauses, shots, URLs)

  # Exportable Artifacts (Included in session-pack.zip)
  shots/
    001.png                 ← Original full-res frame
    001.annotated.png       ← Human drawing (box/arrow/pen)
    001.json                ← Description & voice transcript
  media/
    task-01/clip.mp4        ← 20s 720p H.264 clip (≤ 3.5 MB)
    task-01/shot-1.png      ← High-res keyframe (≤ 400 KB)
```

### `session.manifest.json` Schema
```json
{
  "manifest_version": "1.0.0",
  "session_id": "2026-09-09-1530-abc123",
  "created_at": "2026-09-09T15:30:00Z",
  "duration": { "wall_seconds": 1845.2, "media_seconds": 1620.0 },
  "pauses": [
    { "pause_wall": 190.0, "resume_wall": 205.0, "duration": 15.0 }
  ],
  "product_context": {
    "app_name": "AthleteTracker",
    "repo_url": "https://github.com/acme/athlete-app",
    "tech_stack": "Next.js, Tailwind, PostgreSQL"
  },
  "shots": [
    {
      "id": "shot-001",
      "t_media": 188.2,
      "raw_path": "shots/001.png",
      "annotated_path": "shots/001.annotated.png",
      "note": "Save button does nothing",
      "source": "voice"
    }
  ],
  "slices": [
    {
      "slice_id": "slice-01",
      "start_media": 178.0,
      "end_media": 198.0,
      "trigger": "shot",
      "associated_shot_id": "shot-001",
      "clip_path": "media/task-01/clip.mp4",
      "stills": ["media/task-01/shot-1.png"]
    }
  ],
  "tasks": [
    {
      "task_id": "TASK-01",
      "source_slice_id": "slice-01",
      "kind": "bug",
      "status": "confirmed",
      "title": "Save button disabled on valid form",
      "observed": "Save button element has disabled attribute visible in UI.",
      "stated": "User said 'this does nothing, it should store the athlete'.",
      "inferred": "Likely form validation state failed to update on date selection."
    }
  ]
}
```

---

## 5. UI & Interaction Flow

### 1. Menu Bar & Floating HUD
- Minimal menu bar extra: Start / Stop / Recent / Settings / Quit.
- Floating HUD pill on active screen:
  - Elapsed media recording time ($t_{\text{media}}$).
  - Quick action buttons: **Shot** (`Opt+Cmd+S`), **Pin** (`Opt+Cmd+Space`), **Pause** (`Opt+Cmd+P`), **Stop**.
  - Visual status: Red pulsing dot = Recording, Amber = Paused.

### 2. Shot Annotation Window (`Opt+Cmd+S`)
- Freezes a snapshot of the active screen without stopping recording.
- Lightweight floating window:
  - **Drawing Tools:** Red rectangle, arrow, freehand pen.
  - **Text Description:** Simple text field.
  - **Hold-to-Talk Voice Note:** Uses local WhisperKit to transcribe quick spoken rationale and appends text.
  - **Save:** Writes `shots/NNN.png`, `shots/NNN.annotated.png`, and `shots/NNN.json`.

---

## 6. Pipeline after Stop & Resilient Execution

```
┌────────────────────────────────────────────────────────────────────────┐
│ 1. Finalize AV Streams (Master clock stops; MP4 & WAV flushed)         │
├────────────────────────────────────────────────────────────────────────┤
│ 2. Local WhisperKit Transcription → full_transcript.json               │
├────────────────────────────────────────────────────────────────────────┤
│ 3. Slicer Engine (Merge Shots, Pins, Keywords; exclude paused time)    │
│    Exports ≤ 12 candidate clips (720p H.264) + compressed keyframes    │
├────────────────────────────────────────────────────────────────────────┤
│ 4. Multimodal AI Analysis (Candidate evaluation via configured engine) │
│    • Slices evaluate candidates[] array                                │
│    • High confidence (≥0.55) → Confirmed Tasks                         │
│    • Low confidence (<0.55) → "Needs Review" section (never dropped)   │
│    • Human Shots → Always confirmed                                    │
│    • On API failure: Flagged as "Offline / Unanalyzed" (never lost)    │
├────────────────────────────────────────────────────────────────────────┤
│ 5. Synthesis & Merge Pass (Deduplication, grouping by component)       │
├────────────────────────────────────────────────────────────────────────┤
│ 6. Exporter (AGENT_CONTEXT.md, SESSION_BRIEF.html, session-pack.zip)   │
│    • Full transcript excluded from zip by default                      │
│    • Total zip strictly verified ≤ 35 MB                               │
├────────────────────────────────────────────────────────────────────────┤
│ 7. Complete: Reveal session folder in Finder & launch HTML in browser  │
└────────────────────────────────────────────────────────────────────────┘
```

---

## 7. Evidence-Grounded AI Prompts & Schemas

### Epistemic Honesty Rules
The AI model is explicitly instructed:
1. **Never invent root causes:** A greyed-out button is *not* a "broken API endpoint" unless network traffic or error logs were visible.
2. **Triangulate evidence:**
   - `observed`: What is visually confirmed on screen (UI state, error banner, code line).
   - `stated`: What participants literally said (direct quote with speaker/timestamp).
   - `inferred`: Working hypothesis for the coding agent to investigate.
3. **Allow multiple candidates:** A single 30s slice can yield multiple distinct tasks (`candidates[]`).

### Candidate Slice Response Schema
```json
{
  "type": "OBJECT",
  "properties": {
    "candidates": {
      "type": "ARRAY",
      "items": {
        "type": "OBJECT",
        "properties": {
          "decision": { "type": "STRING", "enum": ["keep", "needs_review", "drop"] },
          "confidence": { "type": "NUMBER" },
          "kind": { "type": "STRING", "enum": ["bug", "decision", "action_item", "architecture_note", "improvement"] },
          "title": { "type": "STRING" },
          "observed": { "type": "STRING", "description": "Strictly what is visible on screen" },
          "stated": { "type": "STRING", "description": "Verbatim statement from participants" },
          "inferred": { "type": "STRING", "description": "Hypothesis or recommended investigation" },
          "agent_instructions": { "type": "STRING" },
          "quotes": {
            "type": "ARRAY",
            "items": {
              "type": "OBJECT",
              "properties": {
                "speaker": { "type": "STRING" },
                "text": { "type": "STRING" }
              },
              "required": ["speaker", "text"]
            }
          },
          "frame_references": { "type": "ARRAY", "items": { "type": "STRING" } }
        },
        "required": ["decision", "confidence", "kind", "title", "observed", "stated", "inferred", "agent_instructions"]
      }
    }
  },
  "required": ["candidates"]
}
```

---

## 8. Deterministic Media Budget & Packaging

To guarantee `session-pack.zip` remains well within the **35–40 MB** ceiling:

$$\text{Total Media Budget} = N_{\text{clips}} \times \text{Size}_{\text{clip}} + N_{\text{stills}} \times \text{Size}_{\text{still}} \le 35\text{ MB}$$

### Encoding Parameters
- **Video Slices:** Max 8 tasks $\times$ 1 clip each = 8 clips.
  - Duration: $15\text{s} - 25\text{s}$ (mean 20s).
  - Codec: H.264, Baseline/Main profile (universal browser/webview playback).
  - Resolution: **720p (1280x720)**.
  - Target Bitrate: **1.2 Mbps** video + 96 kbps AAC audio.
  - Size per clip: $\approx 20\text{s} \times 1.296\text{ Mbps} / 8 = \mathbf{3.24\text{ MB}}$.
  - Total video allocation: $8 \times 3.24\text{ MB} \approx \mathbf{25.9\text{ MB}}$.
- **Stills & Screenshots:**
  - Max 16 keyframe stills / annotated shots.
  - Resolution: Max width 1440px, compressed JPEG (quality 0.82) or PNG.
  - Size per image: $\approx 350\text{ KB}$.
  - Total image allocation: $16 \times 350\text{ KB} \approx \mathbf{5.6\text{ MB}}$.
- **Documents & Metadata:**
  - `AGENT_CONTEXT.md` + `SESSION_BRIEF.html` + `session.manifest.json` $\approx \mathbf{0.5\text{ MB}}$.
- **Guaranteed Archive Size:** $\approx \mathbf{32.0\text{ MB}}$ ($\le 35\text{ MB}$ safe limit).

---

## 9. Phased Implementation Roadmap & Verification Gates

```
Phase -1: Mock Handoff Test ──► Phase 0: Shell & Hotkeys ──► Phase 1: Sync AV & Pause
         │                               │                               │
         ▼                               ▼                               ▼
Phase 2: Shot Note & Async   ──► Phase 3: WhisperKit STT  ──► Phase 4: Slicer & Budget
         │                               │                               │
         ▼                               ▼                               ▼
Phase 5: Resilient AI Engine ──► Phase 6: Multi-Agent Pack──► Production Ready
```

### Phase -1: Pre-Flight Handoff Verification (Before App Code)
- Manually create `samples/mock-session/`:
  - `AGENT_CONTEXT.md` with 2 tasks.
  - Task 1 contains a key fact visible *only* in an image (`shots/test.png`).
  - Task 2 contains a key step visible *only* in a short video clip.
- Test ingestion: Drop folder into **Cursor** and run **Claude Code CLI**.
- **Gate -1 Acceptance:** Both agents correctly answer questions requiring the visual evidence without guessing.

### Phase 0: Project Shell & Global Hotkeys
- Native Swift menu bar app (`com.str8minds.ScrumTrace`). App Sandbox OFF.
- Global hotkeys: `Opt+Cmd+Space` (Pin), `Opt+Cmd+S` (Shot), `Opt+Cmd+P` (Pause).
- Floating HUD window displaying recording state and elapsed time.
- Settings window with Keychain storage for custom AI provider endpoints and API keys.
- **Gate 0 Acceptance:** App launches in menu bar; pressing hotkeys from full-screen Keynote logs events without stealing focus.

### Phase 1: Zero-Drift AV Recording & Strict Pause Contract
- `ScreenCaptureKit` stream capturing display and audio.
- Master clock synchronization via `CMClockGetHostTimeClock()`.
- Pause mechanics: Zero bytes written to MP4 or WAV during paused intervals.
- **Gate 1 Acceptance:**
  1. Record 20 minutes with 3 separate pauses.
  2. Speak/display a secret token during pause $\rightarrow$ verify it is 100% absent from MP4, WAV, and logs.
  3. Verify audio and video remain synchronized within $\le 50\text{ ms}$ at $t=20\text{m}$.

### Phase 2: Shot Note Window & Async Metadata
- `ShotNoteWindow`: Transparent drawing canvas (box, arrow, pen), text field, and hold-to-talk button.
- `MetadataSampler`: Non-blocking background worker querying active window title and browser URL with a 200ms timeout.
- **Gate 2 Acceptance:** Pressing `Opt+Cmd+S` grabs screen and opens note window; hanging or beachballing Chrome tab does not freeze recording or HUD.

### Phase 3: Local Speech Pipeline
- Integrate `WhisperKit` (`large-v3-turbo` CoreML) on Apple Silicon Neural Engine.
- Transcribe session in background task $\rightarrow$ `full_transcript.json`.
- Voice notes from Shot window transcribed and appended to note text.
- **Gate 3 Acceptance:** 5-minute meeting transcribes in $< 20\text{s}$ locally with correct timestamp alignments.

### Phase 4: Slicer & Media Budget Enforcement
- Slicer creates $\le 12$ candidate windows around Shots, Pins, and keywords.
- Strict timeline conversion from $t_{\text{wall}}$ to $t_{\text{media}}$, excluding paused time.
- Re-encode clips to 720p H.264 @ 1.2 Mbps and keyframes to $\le 1440\text{px}$.
- **Gate 4 Acceptance:** Clips play in Chrome without transcode; sum of candidate media is verified $< 30\text{ MB}$.

### Phase 5: Resilient Multimodal AI Integration
- Pluggable AI engine (OpenAI-compatible, Anthropic, Google).
- Implements `candidates[]` evaluation with epistemic honesty schema (`observed`, `stated`, `inferred`).
- Low-confidence items placed in `needs_review` section. Human shots always preserved.
- Resilient failure modes: Network failure or invalid API key marks tasks as "Offline - Requires Review" and still builds HTML/Markdown.
- **Gate 5 Acceptance:** Slices processed in parallel; invalid API key produces structured fallback without crashing.

### Phase 6: Multi-Agent Pack & Final Polish
- Render `AGENT_CONTEXT.md`, `SESSION_BRIEF.html`, and `session.manifest.json`.
- Zip compression ensures archive $\le 35\text{ MB}$. Full transcript omitted from zip by default.
- Session folder auto-revealed in Finder.
- **Gate 6 Acceptance:** 15-minute real presentation produces valid pack; Cursor immediately reads `AGENT_CONTEXT.md` with working image references.
