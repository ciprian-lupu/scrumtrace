# ScrumTrace — implementation plan for human review and GPT Astra

**Read this file first.** It is the whole product, architecture, and build order. Do not start coding until this plan is confirmed.

**Audience:** a product owner with no Swift background, and a second AI (GPT Astra) that must confirm or reject the design before anyone writes the app.

**Status:** design only. The repo is empty. Nothing has been built.

---

## 0. How to review this (2 minutes)

If you are a human, you only need to agree or disagree with the **locked decisions** in section 2. Everything else is “how we build it.”

If you are GPT Astra, do this in order:

1. Restate the product in 5 sentences.
2. Mark every locked decision **Confirm / Challenge / Missing**.
3. List fatal risks (privacy, permissions, HTML too huge for Claude, video size, speaker mix).
4. Say whether the implementation order will actually produce a demo after Phase 1.
5. End with: **Approve as-is** or **Approve with these N changes** (numbered, specific).

Do not rewrite the plan into a different product. Confirm this product.

---

## 1. The product in plain English

We sit around one MacBook and test software. Several people talk. Someone clicks through the product.

**ScrumTrace** is a small icon in the Mac menu bar (top-right, next to Wi‑Fi).

1. Press **Start**. The Mac records **the whole screen** and **the room microphone** as one video.
2. We talk and click. Optional: press **Pin** when something matters. Optional: **Pause** for passwords/Slack.
3. Press **Stop**.
4. The app, by itself:
   - figures out **who said what**
   - turns speech into text
   - **cuts the long video into short pieces**
   - sends those pieces to **Gemini** to understand what we asked for
   - **writes one HTML file** that is already analyzed and sorted
5. The HTML **opens in the browser**. That file (plus the media next to it) is what we **give to Claude** to implement.

We do **not** write tickets by hand during the session. We do **not** auto-spam GitHub in v1. We do **not** dump a raw chaotic transcript on Claude.

### What “give to Claude” means

After Stop, Finder has a session folder. You do **one** of these:

- Open `CLAUDE.html` in Chrome, click **Copy prompt for Claude**, paste into Claude (or Cursor).
- Or zip the folder and attach it in Claude / drop it into a Cursor chat with `@CLAUDE.html`.

The HTML is the brief. The clips and screenshots are the evidence. Claude should be able to start implementing without watching the full hour.

### Real example

Room at 11:02:

- Ciprian: “the save button does nothing”
- Screen: greyed-out Save on the athlete form
- Ana: “it should store the athlete, then go to the list”
- Later: “also the search box ignores diacritics”

Stop at 11:20. `CLAUDE.html` opens with **two sorted tasks**, not a wall of chat:

1. **Save on athlete form is dead** — expected / actual / repro / screenshot / 22s clip / quotes
2. **Search must match Romanian diacritics** — same structure

Chit-chat (“should we get coffee”) is gone. Full transcript is at the bottom, collapsed, if Claude needs it.

---

## 2. Locked decisions (review these)

These were already chosen. Changing one of them changes the whole build.

| # | Decision | What it means | Why |
|---|----------|----------------|-----|
| D1 | **In-person room, one MacBook** | Several people around one laptop. Not Zoom-first. | User choice. One microphone. |
| D2 | **Record the entire screen+mic as video** | One MP4 for the whole session. | Stills miss hover, clicks, the 3 steps before the bug. |
| D3 | **Analyze after Stop, in pieces** | Never send the full hour to Gemini as step 1. Cut 15–45s clips, then analyze each. | Full-file analysis is slow, expensive, and bad at small UI text. |
| D4 | **Primary output is one HTML brief for Claude** | Stop → analyzed, sorted `CLAUDE.html` + media. Open in browser. Ready to paste/attach to Claude. | User choice. GitHub tickets are optional later, not v1. |
| D5 | **Native macOS menu-bar app** | Swift + SwiftUI. Apple Silicon. | Screen recording APIs are native. |
| D6 | **Gemini analyzes slices and writes the HTML content** | Gemini sees clips + stills + transcript slices, then one merge pass to sort tasks. | User has a Gemini key. Gemini is strong at video. |
| D7 | **Speech stays on the Mac by default** | Who-said-what runs locally. Gemini gets text + short clips, not the raw hour of room audio as a separate upload. | Room conversation is sensitive. |
| D8 | **GitHub auto-create is out of v1** | No PAT required to get value. Repo URL in the HTML is optional context if we detected one. | The consumer is Claude, not the issue tracker. |
| D9 | **Workspace** | Build in this repo (`figma-code-connect`). Empty today. | Folder already open. |

If you disagree with a row, say so before coding. Do not silently put GitHub publish back as a Phase 1 requirement.

---

## 3. What we are not building in v1

- Auto-creating GitHub issues (the HTML *is* the handoff)
- A Zoom/Meet bot
- A Chrome extension for console/network (Jam later)
- A timeline editor to split tasks by hand before export
- Always-on recording like old Rewind
- Windows or iPhone
- Uploading the full session MP4 to the cloud as the first analysis step
- One giant HTML with the hour-long video base64-inlined (that file would be unusable)

---

## 4. Glossary (no assumed knowledge)

- **Menu bar app:** tiny icon at the top of the Mac. Start / Stop / Settings.
- **ScreenCaptureKit:** Apple’s official screen recorder. macOS will ask: “ScrumTrace would like to record this computer’s screen.”
- **Diarization:** who spoke when. `Speaker 1 00:12–00:18`.
- **Transcript:** the words, with timestamps, attached to speakers.
- **Keyframe:** a PNG still pulled from the video. Easier for Claude to read UI text than a compressed movie.
- **Slice:** a 15–45 second cut of the long video around a suspected task/bug.
- **CLAUDE.html:** the one file we open after Stop. Sorted tasks + evidence + a copy-paste prompt.
- **Session pack:** the folder that contains `CLAUDE.html`, clips, screenshots, and the full `session.mp4`. Zip this to give Claude the pictures and movies too.
- **HEVC:** smaller video files on Apple chips.
- **Keychain:** Mac password vault. Gemini key lives here, never in git.
- **TCC:** the macOS permission popups (Microphone, Screen Recording, Accessibility).
- **Pin:** a hotkey that means “this second matters.” Helps the slicer.
- **Merge pass:** after Gemini looks at each slice, a second Gemini call (text only) sorts and de-duplicates into the final task list.

---

## 5. The HTML is the product (looks like this)

After Stop, the app writes and **opens**:

```text
~/Movies/ScrumTrace/sessions/2026-09-09-1530-abc123/
  CLAUDE.html          ← open this
  PROMPT.txt           ← same prompt, plain text, for copy/paste
  session.mp4          ← full recording (not embedded in HTML)
  audio.wav
  events.jsonl
  transcript.json
  media/
    task-01/
      clip.mp4
      shot-1.png
      shot-2.png
    task-02/
      clip.mp4
      shot-1.png
```

`CLAUDE.html` uses **relative paths** (`media/task-01/shot-1.png`). If you zip the folder, Claude/Cursor can still resolve images. We do **not** embed the full `session.mp4` in the HTML.

### Page structure (dummy mock)

```text
┌─────────────────────────────────────────────────────────────┐
│ ScrumTrace session  9 Sep 2026  ·  18 min  ·  2 tasks      │
│ [ Copy prompt for Claude ]   [ Reveal full transcript ]       │
│ [ Open session folder ]                                      │
├─────────────────────────────────────────────────────────────┤
│ PROMPT FOR CLAUDE (copy this first)                         │
│ You are implementing work from a live QA session.           │
│ Do the tasks below in order. Each task has expected/actual,  │
│ screenshots, a short clip, and quotes. Ignore the appendix     │
│ unless you need extra context. Do not invent unrelated work. │
├─────────────────────────────────────────────────────────────┤
│ TASK 1 of 2  ·  bug  ·  from 11:02                           │
│ Save button on athlete form does nothing                      │
│ Expected: …    Actual: …                                     │
│ Repro: 1. …  2. …                                            │
│ [screenshot] [screenshot]                                    │
│ [ video player: 22s clip ]                                  │
│ Ciprian: “the save button does nothing”                      │
│ Ana: “it should store the athlete”                            │
├─────────────────────────────────────────────────────────────┤
│ TASK 2 of 2  ·  improvement  ·  from 11:14                  │
│ Search must match Romanian diacritics                       │
│ …                                                            │
├─────────────────────────────────────────────────────────────┤
│ APPENDIX — full transcript (speakers + timestamps)            │
│ APPENDIX — full video (link to session.mp4, not autoplay)   │
└─────────────────────────────────────────────────────────────┘
```

The HTML is a **static** file: one CSS file inlined or embedded, no internet required to *view* it (Gemini already ran). Video tags point at local `media/.../clip.mp4`.

---

## 6. How a session flows

```text
[Menu bar] Start
    → permission checks (mic, screen, accessibility)
    → red RECORDING indicator
    → session.mp4 (screen + mic)
    → audio.wav
    → events.jsonl (front window / URL / pin / pause)
    → PIN hotkey
    → PAUSE hotkey (Mail, 1Password, Slack)

[Menu bar] Stop
    → 1. local speech: speakers + transcript
    → 2. propose slices (pins, “that’s a bug”, URL changes, scene cuts)
    → 3. export clip + 2–4 PNGs per slice
    → 4. Gemini per slice → candidate tasks
    → 5. Gemini merge pass (text) → sorted unique tasks
    → 6. write CLAUDE.html + PROMPT.txt
    → 7. open CLAUDE.html in the default browser
    → 8. show a tiny summary: “2 tasks · folder opened”
```

### What Gemini is allowed to see

**Per slice:** short MP4 + 2–4 PNGs + transcript for those seconds + window/URL in that window.

**Merge pass:** JSON from all slices + full transcript text (no video). Output: ordered task list, duplicates merged, chatter dropped.

Gemini is **not** given the full hour MP4 in v1.

---

## 7. Which AI models to use

These are **different jobs**.

### A. GPT Astra — confirm this plan (now)

Do not implement. Challenge D1–D9, especially D4 (HTML for Claude instead of GitHub).

### B. Cursor Composer **2.5** (not Fast) — write the app after approval

Phase-gated. First message: only Phase 0–1. Fast is the wrong model (permissions/ScreenCaptureKit).

### C. Gemini — inside the running app

| Setting | Value |
|---------|--------|
| Slice analysis | `gemini-2.5-pro` (video + images) |
| Merge/sort pass | `gemini-2.5-pro` or `gemini-2.5-flash` (text JSON only) |
| Key | Settings → Keychain, never git |

### D. Local speech

FluidAudio (who spoke) + WhisperKit (words). Romanian + English. Escape hatch later: cloud speech, off by default.

---

## 8. What you need before anyone codes

1. Apple Silicon Mac, macOS 14.2+, **Xcode 26 already installed**.
2. Gemini API key.
3. Willingness to Allow Microphone, Screen Recording, Accessibility.
4. **No GitHub token required for v1.**

---

## 9. App shape (what you click)

**Menu bar**

- Idle: `Start recording` · `Last session` (opens last `CLAUDE.html`) · `Settings`
- Recording: red dot + time · `Pause` · `Stop` · `Pin this moment`
- Processing: Transcribing / Cutting / Asking Gemini / Writing HTML

**Settings**

- Gemini API key
- Model name (default `gemini-2.5-pro`)
- Speaker names (Speaker 1 = Ciprian)
- Optional: default product/repo name to print in the HTML header (plain text, not an API)

**Recording HUD:** red REC + elapsed. Ship blocker if missing.

**After Stop:** default browser opens `CLAUDE.html`. Menu also has “Reveal in Finder.”

---

## 10. Repository layout (Composer)

```text
ScrumTrace/
  ScrumTrace.xcodeproj
  ScrumTrace/
    ScrumTraceApp.swift
    Info.plist
    ScrumTrace.entitlements     App Sandbox OFF; audio-input YES
    MenuBar/MenuBarView.swift
    MenuBar/RecordingHUD.swift
    Settings/SettingsView.swift
    Settings/Secrets.swift
    Capture/SessionRecorder.swift
    Capture/MetadataSampler.swift
    Session/SessionVault.swift
    Session/Models.swift
    Speech/Diarizer.swift
    Speech/Transcriber.swift
    Speech/SpeakerLibrary.swift
    Slicing/Slicer.swift
    Slicing/ClipExporter.swift
    Gemini/GeminiClient.swift
    Export/ClaudeHTMLRenderer.swift   ← writes CLAUDE.html + PROMPT.txt
    Processing/SessionProcessor.swift
  README.md
IMPLEMENTATION_PLAN.md
.gitignore
```

Bundle id: `com.str8minds.ScrumTrace`.

**Deep modules**

| Module | Caller sees | Hidden |
|--------|-------------|--------|
| `SessionRecorder` | start / pause / resume / stop | ScreenCaptureKit, HEVC, mic |
| `SessionProcessor` | `process(folder) -> HTMLURL` | speech → slice → Gemini → HTML |
| `GeminiClient` | `analyze(slice)`, `merge(candidates)` | Files API, retries |
| `ClaudeHTMLRenderer` | `render(session) -> CLAUDE.html` | template, escaping, relative paths |

---

## 11. Gemini contracts

### Slice call → candidate (JSON only)

```json
{
  "decision": "task" | "drop",
  "confidence": 0.0,
  "kind": "bug" | "improvement" | "question" | "decision",
  "title": "Save button on athlete form does nothing",
  "summary": "…",
  "expected": "…",
  "actual": "…",
  "repro_steps": ["…"],
  "quotes": [{"speaker": "Ciprian", "text": "…"}],
  "frame_indices": [0, 1]
}
```

`confidence` < 0.55 → app treats as `drop`.

### Merge call → final task list (JSON only)

Input: all slice candidates + full transcript text.

Output:

```json
{
  "session_title": "Athlete form QA",
  "claude_instructions": "Implement the tasks in order. …",
  "tasks": [
    {
      "id": "task-01",
      "kind": "bug",
      "title": "…",
      "summary": "…",
      "expected": "…",
      "actual": "…",
      "repro_steps": ["…"],
      "quotes": [{"speaker": "…", "text": "…"}],
      "source_slice_ids": ["003", "004"],
      "sort_key": 1
    }
  ]
}
```

Rules for merge:

- Merge two candidates if they are the same work.
- Sort: blockers/bugs first, then improvements, then open questions.
- Drop `question` that is not a product decision Claude can implement.
- Cap **8 tasks** in the HTML body. Extra candidates go in an “Unsorted leftovers” `<details>` so we do not hide data, but Claude is told to ignore leftovers unless asked.
- `claude_instructions` must tell Claude: implement only the numbered tasks; use screenshots/clips as ground truth; do not invent extra scope.

---

## 12. `CLAUDE.html` rules (so Claude can use it)

1. **UTF-8**, self-contained CSS (inline `<style>`), no Google Fonts CDN (works offline).
2. All images/video: relative `src="media/task-01/shot-1.png"`.
3. Escape all transcript text (`<`, `&`) so a user saying `</script>` cannot break the page.
4. Top button copies `#claude-prompt` to the clipboard (a `<textarea>` plus a bit of JS is OK; no framework).
5. `PROMPT.txt` is the same prompt **without HTML**, for tools that hate HTML.
6. Full `session.mp4` is a **download link**, not an autoplay 18-minute player at the top (too heavy).
7. Each task has `id="task-01"` so we can deep-link.
8. Print CSS: screenshots visible, videos show a poster frame + filename.

### Prompt text that gets copied (shape)

```text
You are a coding agent. Implement the QA session below.

Rules:
- Implement TASKS in order (task-01, task-02, …).
- Treat screenshots and clips as ground truth for current UI.
- Do not add unrelated features.
- If something is only in the appendix transcript and not a TASK, ignore it.

## TASK 1 — …
...
```

The HTML shows this prompt *and* the visual evidence. `PROMPT.txt` has the words; the HTML is what you attach when the model can see images.

---

## 13. Slicer rules (code, not Gemini)

Same as before, then windows merged to 15–45s with 3s pre-roll:

1. Pin hotkey
2. Keywords EN+RO: bug, broken, doesn’t work, issue, expected, screenshot, problema, nu merge, nu funcționează, uite, defect, trebuie, implement
3. URL / window-title change lasting > 4s
4. Scene-cut hash jump (not cursor-only). Max one from scene-cut every 20s

Cap **12 slices** sent to Gemini. Merge pass then produces ≤ 8 tasks.

---

## 14. Implementation phases (stop at each gate)

Each phase has a human test. Fail → do not continue.

### Phase 0 — launches

Xcode project, bundle id `com.str8minds.ScrumTrace`, menu bar, Settings for Gemini key in Keychain.

**Test:** Run twice. Icon appears. Fake key survives quit. Nothing secret in git.

### Phase 1 — record and stop

`session.mp4` + `audio.wav`. HUD. Pause.

**Test:** 20 seconds of talking + clicking. QuickTime plays picture and sound. Not a 10 GB file.

Encoding: HEVC, 1080p or 1440p, 15–30 fps.

### Phase 2 — sidecar

`events.jsonl` has Safari/Chrome URLs and pins.

**Test:** Open a GitHub issue in Safari while recording. The URL is in the file.

### Phase 3 — speech

FluidAudio + WhisperKit → `transcript.json`. Off main thread.

**Test:** Two people speak in turn. File has two speakers and roughly the right words.

**Escape hatch:** if SPM integration blocks > 1 day, Gemini-on-`audio.wav` behind a Settings flag, default off.

### Phase 4 — slices on disk

Pin + say “that’s a bug” in a 2-minute recording. `media/` or `slices/` contains a short clip + PNGs.

**Test:** clip is the interesting moment, not the whole session.

### Phase 5 — Gemini dry run

Settings key required. Write JSON under `gemini/`. **No HTML yet.** Show titles in a debug window or console.

**Test:** fake bug on screen. JSON has a recognizable title. Logs show **slice** upload, not full `session.mp4`.

### Phase 6 — CLAUDE.html (this is v1 “done”)

`ClaudeHTMLRenderer` writes `CLAUDE.html` + `PROMPT.txt`, opens the browser.

**Human test:**

1. Record a fake 2-minute session with one real “bug” said out loud.
2. Stop.
3. Browser opens. You see **Copy prompt for Claude**, at least one task, screenshots visible, clip plays.
4. Click copy, paste into a notes app — the prompt contains the task text.
5. Zip the folder, unzip elsewhere, open `CLAUDE.html` — pictures still load (relative paths).
6. A session of silence/scrolling produces an HTML that says **0 tasks** plus the transcript appendix, not invented work.

**Done when:** you would actually paste that HTML/prompt into Claude.

### Phase 7 — harden

Speaker names, 1Password auto-pause, leftover tasks in `<details>`, README permissions.

---

## 15. Stop pipeline (`SessionProcessor`)

1. Close MP4/WAV.
2. Diarize + transcribe.
3. Propose ≤ 12 slices, export clips/frames.
4. Gemini per slice → candidates.
5. Drop low confidence.
6. Merge pass → ≤ 8 tasks.
7. Copy chosen frames/clips into `media/task-NN/`.
8. Render `CLAUDE.html` + `PROMPT.txt`.
9. Open HTML in browser. Reveal folder.

A failed slice is skipped. HTML still generates with a yellow “slice 4 failed” note.

---

## 16. Privacy

- HUD visible the whole time recording is on.
- Pause is first-class.
- Auto-pause if frontmost is `1Password`, `Keychain Access`, `Wallet`.
- Clips sent to Gemini still contain those 15–45s of room audio. README must say so.
- HTML is local. Nothing is uploaded to GitHub in v1.

---

## 17. Risks

| Risk | What goes wrong | Mitigation |
|------|------------------|-----------|
| Claude gets a novel | 18 min of chat, no tasks | Merge pass, cap 8, drop chatter, prompt says ignore appendix |
| HTML too big to attach | Claude.ai file limits | Relative media + zip; `PROMPT.txt` for text-only; clips not full movie |
| Relative paths break | User emails only the HTML | After Stop, reveal **folder**; button “Compress session pack” |
| Auto-invented tasks | Silence → fake bugs | 0-task empty state; confidence floor |
| Overlapping speakers | Wrong names | FluidAudio; rename in Settings |
| Screen Recording denied | Black video | Phase 1 real-Mac test |
| Secrets in git | Leaked Gemini key | Keychain + Phase 0 test |
| Password on screen | Gemini sees 1Password | Auto-pause denylist + human pause |

---

## 18. What “v1 done” means

A real ~10 minute room test produces:

1. Playable `session.mp4`
2. Transcript with two speakers if two people spoke
3. `CLAUDE.html` that opens by itself
4. Sorted tasks with screenshots and short clips
5. A copy-paste prompt you would give Claude
6. No secrets in git
7. No GitHub issues (by design)

---

## 19. Prompt to paste into GPT Astra

```text
You are reviewing IMPLEMENTATION_PLAN.md for ScrumTrace (attached).

Do not implement. Confirm or challenge.

This is a macOS menu-bar QA recorder for an in-person room around one MacBook.
Capture is full screen+mic video. Analysis is after Stop, on short slices.
The v1 deliverable is CLAUDE.html: analyzed, sorted tasks + screenshots + clips,
ready to give to Claude to implement. GitHub auto-issues are out of v1.
Implementer after approval is Cursor Composer 2.5, phase-gated.

Return:
1. 5-sentence restatement
2. Table of D1–D9: Confirm / Challenge / Missing
3. Fatal risks, especially HTML/Claude file-size and “too much chatter”
4. Whether Phase 0→1 yields a recordable demo
5. Missing HTML/export details that would make Claude unable to use the pack
6. Verdict: Approve as-is OR Approve with numbered changes
```

---

## 20. Prompt to paste into Composer 2.5 after Astra approves

```text
Implement ScrumTrace from IMPLEMENTATION_PLAN.md in this repo.

Do Phase 0 and Phase 1 only.
Stop when the Phase 1 human acceptance test can be run.
Do not add Gemini, HTML export, WhisperKit, or slicing yet.
Bundle id must be com.str8minds.ScrumTrace.
No App Sandbox. Follow section 10 folder layout.
```

Then Phase 2, 3, 4, 5, 6 in separate chats. Never “finish the app” in one shot.

---

## 21. Single source of truth

If chat history and this file disagree, **this file wins** until a human edits it.

Locked decisions: **section 2**. Output shape: **section 5**. Phases: **section 14**. Gemini JSON: **section 11**.
