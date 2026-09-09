# ScrumTrace — Implementation Plan (Universal & Brand-Agnostic)
**Zero-Friction Meeting & Presentation Context Capture for AI Coding Agents**

---

## 1. Product Vision & Workflow

You present or collaborate from your Mac during technical meetings (sprint demos, architectural discussions, bug bashes, live design reviews). You want any AI coding agent to receive high-fidelity, multimodal context (screens, code, diagrams, spoken rationale, decisions) without manually writing notes.

**ScrumTrace** is a native macOS menu-bar utility:
1. **Start** — Records the selected presentation display and microphone/system audio in perfect hardware sync.
2. **Interact & Point**:
   - **Shot** (`Opt+Cmd+S`) — Takes an instant screenshot, opening a lightweight note window to draw (box/arrow/pen) or add a description (typing or **hold-to-talk voice note**).
   - **Pin** (`Opt+Cmd+Space`) — Drops a high-priority timestamp bookmark on the timeline without interrupting your flow.
   - **Pause** (`Opt+Cmd+P`) — Halts recording immediately (auto-pauses on credential managers / banking).
3. **Stop** — Transcribes locally, cuts short 15–30s candidate clips, runs multimodal analysis via your **configured AI provider**, and writes a unified context brief.
4. **Handoff to Any AI Agent** — Automatically opens the session folder with structured Markdown, an interactive HTML brief, and a lightweight zip pack ready for any agent.

---

## 2. Pluggable, Brand-Agnostic Architecture

ScrumTrace does not hardcode any single AI provider or downstream tool. Everything is standard, open, and configurable.

### Supported Downstream AI Consumers
| Consumer | How Context is Ingested | Output Consumed |
|---|---|---|
| **IDE AI Agents (Cursor, Windsurf, Copilot)** | Drop folder into project or reference in prompt | `@AGENT_CONTEXT.md` + screenshots + clips |
| **CLI Coding Agents (Claude Code, Aider, Codex)** | Pass context path directly in CLI prompt | `AGENT_CONTEXT.md` |
| **Web Chat Interfaces** | Upload the compressed session pack | `session-pack.zip` ($\le 40\text{ MB}$) |
| **Human Reviewers & Team Members** | Open directly in any web browser | `SESSION_BRIEF.html` (self-contained viewer) |

### Universal AI Engine Interface
The app uses a pluggable adapter pattern for multimodal evaluation and text synthesis:

```
┌────────────────────────────────────────────────────────────┐
│                  Pluggable AI Provider Layer                │
│  (Configured via API Key + Base URL + Model Name in Settings)│
└─────────────────────────────┬──────────────────────────────┘
                              │
         ┌────────────────────┼────────────────────┐
         ▼                    ▼                    ▼
┌──────────────────┐ ┌──────────────────┐ ┌──────────────────┐
│ OpenAI-Compatible│ │  Anthropic API   │ │Google Generative │
│ (GPT-4o, Ollama, │ │(Claude 3.5/3.7)  │ │ (Gemini Flash/Pro│
│  vLLM, Groq)     │ │                  │  endpoints)        │
└──────────────────┘ └──────────────────┘ └──────────────────┘
```

- **Default Protocol:** Standard OpenAI-compatible multimodal endpoint (`/v1/chat/completions`) or native SDKs for Anthropic / Google.
- **Local/Offline Support:** Can point to local LLMs via Ollama, LM Studio, or vLLM (`http://localhost:11434/v1`).
- **Configurable Models in Settings:**
  - **Fast Multimodal Model (for 15–30s slice evaluation):** High-speed vision-language model.
  - **Reasoning Model (for final synthesis & merge):** Deep reasoning text model.

---

## 3. Core Decisions

| # | Decision | Meaning |
|---|---|---|
| **D1** | Live Meeting & Presentation Focus | Room mic + system audio. One Mac. Works over Keynote, browser, IDE. |
| **D2** | Master Clock PTS Synchronization | Video and audio inputs are locked to `CMClockGetHostTimeClock()`. Guaranteed zero AV drift over 60+ min. |
| **D3** | Brand-Agnostic Outputs | Produces standard `AGENT_CONTEXT.md`, `SESSION_BRIEF.html`, and `AGENT_PROMPT.txt`. |
| **D4** | Model-Agnostic Provider Layer | Pluggable API backend: OpenAI-compatible, Anthropic, Google, or local Ollama. |
| **D5** | Native Swift Menu-Bar App | Apple Silicon native, low resource usage ($<15\text{MB}$ RAM, $<2\%$ CPU). App Sandbox OFF. |
| **D6** | Bounded Slices, Never Full Video Upload | Full 1-hour video stays local. Only $\le 12$ short candidate clips (15–30s) are processed. |
| **D7** | First-Class Human Shots | Human `Shot` annotations (draw/type/voice) are **never dropped** by AI confidence filters. |
| **D8** | Non-Blocking Context Sampling | Window title & URL inspections run asynchronously with a 200ms timeout. Never freezes the Mac. |
| **D9** | Comprehensive Meeting Taxonomy | Classifies: `bug`, `decision`, `action_item`, `architecture_note`, `improvement`. |
| **D10** | Local-First Speech Transcription | Whisper CoreML (`large-v3-turbo`) runs locally on the Neural Engine (ANE). Fast, private, zero cloud cost. |

---

## 4. Session Structure on Disk

```text
~/Movies/ScrumTrace/sessions/2026-09-09-1530-meeting/
  AGENT_CONTEXT.md          ← Clean Markdown for any AI coding agent
  SESSION_BRIEF.html        ← Self-contained visual HTML dashboard
  AGENT_PROMPT.txt          ← Ready-to-copy instruction prompt
  session-pack.zip          ← Compressed bundle (< 40 MB) for upload
  session.mp4               ← Full meeting video archive (local only)
  audio.wav                 ← Clean 16kHz mono audio archive
  events.jsonl              ← Timeline of URLs, pins, pauses, and shots
  transcript.json           ← Timestamped local transcript
  shots/
    001.png                 ← Raw screenshot
    001.annotated.png       ← Drawing with box/arrow/pen
    001.json                ← Description & voice transcript
  media/
    task-01/clip.mp4        ← 20s H.264 video snippet
    task-01/shot-1.png      ← Extracted high-res frame
```

---

## 5. UI & Interaction Flow

### Menu Bar & Floating HUD
- **Menu Bar:** Start / Stop / Recent Sessions / Settings / Quit.
- **Floating HUD:** Non-intrusive translucent pill on the active display. Shows live recording duration, current status, and buttons for **Shot**, **Pin**, **Pause**, **Stop**.
- **Global Hotkeys:**
  - `Opt + Cmd + S`: Capture Shot & open annotation note.
  - `Opt + Cmd + Space`: Drop Pin bookmark.
  - `Opt + Cmd + P`: Pause / Resume.

### Shot Annotation Window
When `Opt+Cmd+S` or **Shot** is triggered:
- Grabs the current screen frame.
- Opens a lightweight, non-activating floating editor:
  - **Visual Markup:** Quick box, arrow, and pen highlight.
  - **Text Note:** Quick input field for typed description.
  - **Voice Memo:** Hold-to-talk button transcribing via local Whisper to append to note.
  - **Save & Dismiss:** Closes instantly while meeting recording continues uninterrupted.

### Settings Window
- **AI Provider Selection:** Dropdown for OpenAI, Anthropic, Google, or Custom / OpenAI-Compatible (Ollama, LM Studio).
- **Endpoint URL:** `https://api.openai.com/v1`, `https://api.anthropic.com/v1`, or custom `http://localhost:11434/v1`.
- **API Key:** Stored securely in macOS Keychain (`kSecClassGenericPassword`).
- **Models:** Configurable slice inspection model and synthesis model.
- **Privacy & Consent:** Consent toggle acknowledging short clips leave the Mac for AI processing.

---

## 6. Processing Pipeline (Triggered on Stop)

```
1. Finalize AV Streams   ──► Master clock sync stops. Writes session.mp4 + audio.wav.
         │
         ▼
2. Local STT             ──► WhisperKit transcribes session off main thread → transcript.json.
         │
         ▼
3. Candidate Slicing     ──► Merges Shots, Pins, and keywords into ≤ 12 windows (15–30s).
         │                   Exports H.264 clips + stills. Paused sections strictly excluded.
         │
         ▼
4. Multimodal Analysis   ──► Sends candidate clips + stills + Shot notes to configured AI.
         │                   Filters out low-confidence chatter (< 0.55), keeps all human Shots.
         │
         ▼
5. Synthesis & Merge     ──► Reconciles items, removes duplicates, groups by topic/priority.
         │
         ▼
6. Multi-Agent Export    ──► Generates AGENT_CONTEXT.md, SESSION_BRIEF.html, session-pack.zip.
         │
         ▼
7. Complete              ──► Reveals folder in Finder and launches SESSION_BRIEF.html.
```

---

## 7. Universal AI Prompt & Schemas

### Stage 1: Multimodal Candidate Slice Evaluation
```json
{
  "decision": "keep" | "drop",
  "confidence": 0.85,
  "kind": "bug" | "decision" | "action_item" | "architecture_note" | "improvement",
  "title": "Title describing the item",
  "summary": "Clear technical explanation",
  "visual_context": "What was visible on screen (app name, UI component, diagram)",
  "expected_vs_actual": "Expected vs actual behavior (for bugs), or rationale (for decisions)",
  "instructions_for_ai_agent": "Concrete implementation directions for the AI agent",
  "quotes": [{"speaker": "Speaker 1", "text": "..."}],
  "human_shot_ids": ["001"]
}
```

### Stage 2: Synthesis & Reconciliation Schema
```json
{
  "session_title": "Sprint Review & Architecture Sync",
  "executive_summary": "High-level summary of the meeting",
  "items": [
    {
      "id": "ITEM-01",
      "kind": "decision",
      "priority": "P0" | "P1" | "P2",
      "title": "Migrate Session Cache to Redis",
      "description": "Agreed by team during architecture slide review.",
      "affected_areas": ["src/auth/", "docker-compose.yml"],
      "implementation_guidance": "Replace in-memory map with Redis client cluster connection.",
      "media_reference": "media/task-01/shot-1.png",
      "clip_reference": "media/task-01/clip.mp4"
    }
  ]
}
```

---

## 8. Output Formats

### 1. `AGENT_CONTEXT.md` (Standardized for Any AI Assistant)
```markdown
# Meeting Context: [Session Title]
**Date:** 2026-09-09 15:30  
**Context:** Captured during live Mac presentation  

## Executive Summary
[High-level meeting summary]

## 1. Architectural & Technical Decisions
### [DECISION-01] Migrate Session Cache to Redis
- **Consensus:** Agreed by team during slide review.
- **Reference Image:** `media/task-01/shot-1.png`
- **Clip:** `media/task-01/clip.mp4`
- **Implementation Guidance:** In `src/auth/sessionStore.ts`, replace in-memory session store with Redis client.

## 2. Bugs & Visual Glitches
### [BUG-01] Save Button Greyed Out
- **Repro Steps:** Fill name and date; button remains disabled.
- **Annotated Screenshot:** `shots/001.annotated.png` (Red box around button)
- **Voice Note:** *"Save does nothing, should store the athlete."*
- **Implementation Guidance:** Check validation dirty flag in `AthleteForm.tsx`.
```

### 2. `SESSION_BRIEF.html`
- Clean, responsive dashboard with embedded CSS and Dark/Light mode support.
- In-browser HTML5 video player for each slice.
- Image modal / lightbox displaying annotated shots side-by-side with original stills.
- Full searchable transcript appendix.
- One-click copy buttons: "Copy Context Markdown" and "Copy Prompt".

---

## 9. Modular Code Architecture

```text
ScrumTrace/
  ScrumTrace.xcodeproj
  ScrumTrace/
    App/
      ScrumTraceApp.swift                # Menu bar lifecycle
      Info.plist                         # Mic & Screen permissions
      ScrumTrace.entitlements            # Audio Input, Sandbox OFF
    UI/
      MenuBarController.swift            # Status item & menu actions
      RecordingHUDWindow.swift           # Floating translucent timer pill
      ShotNoteWindow.swift               # Drawing canvas, text field, hold-to-talk
      SettingsView.swift                 # Provider, endpoint, models, Keychain
    Capture/
      SessionRecorder.swift              # ScreenCaptureKit coordinator
      ClockSynchronizer.swift            # PTS timebase alignment (CMClock)
      MetadataSampler.swift              # Async frontmost URL & title sampler (200ms timeout)
      PrivacyGuard.swift                 # 1Password / Wallet auto-pause
    Storage/
      SessionVault.swift                 # Session folder manager
      SessionModels.swift                # Codable data structures
    Speech/
      WhisperTranscriber.swift           # WhisperKit CoreML ANE coordinator
    Slicing/
      MeetingSlicer.swift                # Shot / Pin / Keyword priority scoring
      ClipExporter.swift                 # AVAssetExportSession (H.264 1080p)
    AI/
      AIProviderProtocol.swift           # Universal interface for LLM calls
      OpenAICompatibleClient.swift       # Generic /v1/chat/completions client
      AnthropicClient.swift              # Anthropic Messages API client
      GoogleClient.swift                 # Google Generative AI client
      PromptTemplates.swift              # Brand-agnostic prompts & schemas
    Export/
      AgentContextRenderer.swift         # AGENT_CONTEXT.md builder
      SessionBriefRenderer.swift         # Standalone SESSION_BRIEF.html builder
      SessionPackZipper.swift            # Zip archiver (< 40 MB)
    Processing/
      SessionProcessor.swift             # Pipeline state machine
```

---

## 10. Phased Implementation Roadmap

- [ ] **Phase 0: Shell & Provider Settings:** Menu bar app, floating HUD, hotkeys (`Opt+Cmd+Space`, `Opt+Cmd+S`), and Settings window with Keychain storage for custom provider/endpoint/key.
- [ ] **Phase 1: Zero-Drift AV Capture:** ScreenCaptureKit video + mic capture locked to `CMClockGetHostTimeClock()`. 20-minute test proves audio and video remain aligned within 50ms.
- [ ] **Phase 2: Shot Note Window & Async Metadata:** Screen capture to `shots/NNN.png`, annotation canvas (draw/type/voice), and async window/URL inspection with 200ms timeout.
- [ ] **Phase 3: Local Speech Transcription:** WhisperKit CoreML transcribes audio locally on Neural Engine to `transcript.json`.
- [ ] **Phase 4: Slicing & Candidate Clips:** Priority slicing (Shot > Pin > Keywords), H.264 1080p export, skipping paused intervals.
- [ ] **Phase 5: Universal AI Integration:** Pluggable AI engine evaluates candidate slices and generates synthesized JSON output using configured model.
- [ ] **Phase 6: Multi-Agent Handoff:** Generates `AGENT_CONTEXT.md`, `SESSION_BRIEF.html`, and `session-pack.zip`. Verifies direct ingestion into Cursor, Claude Code, or any AI assistant.
