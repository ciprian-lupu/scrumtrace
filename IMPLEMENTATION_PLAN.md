# ScrumTrace — implementation plan

**Locked spec.** Grok and Composer 2.5 reviewed this. Required changes are in this file. Implement from here; do not reopen product debates.

GitHub: [ciprian-lupu/scrumtrace](https://github.com/ciprian-lupu/scrumtrace). App code is not built yet.

---

## 1. Product

We sit around one MacBook and test software. Several people talk. Someone clicks.

**ScrumTrace** is a Mac menu-bar icon.

1. **Start** — record the whole screen and the room mic as one video.
2. Talk and click. **Pin** = this second matters. **Pause** = stop writing video (passwords, Slack, Mail).
3. **Stop** — transcribe locally, cut short clips, Gemini reads those clips, write one analyzed HTML brief.
4. Reveal the session folder, offer **Compress session pack**, open `CLAUDE.html`.

Give **the zip** to Claude. That is the product. Not GitHub tickets. Not a raw hour of chat.

### Handoff (be honest)

| Mode | What you send | What Claude gets |
|------|----------------|------------------|
| **Multimodal (default)** | `session-pack.zip` or the whole folder in Cursor | Tasks + screenshots + H.264 clips |
| **Text-only** | Copy prompt / `PROMPT.txt` | Words only. UI must say so. Not a “success” if they needed pictures. |

Default zip = `CLAUDE.html` + `PROMPT.txt` + `transcript.json` + `media/**`. **No** `session.mp4`, **no** `audio.wav`. Full movie stays on disk as a local archive.

### Example

- Ciprian: “the save button does nothing” (greyed-out Save)
- Ana: “it should store the athlete”
- Later: “search ignores diacritics”
- Coffee talk: dropped

`CLAUDE.html` has **two tasks**, each with expected/actual, repro, screenshots, a ~20s clip, quotes. Full transcript is an appendix.

---

## 2. Locked decisions

| # | Decision | Meaning |
|---|---------|---------|
| D1 | Room, one MacBook | Not Zoom-first. One mic. Speaker names are best-effort. |
| D2 | Full screen+mic video | Still-only capture is out. |
| D3 | Analyze after Stop, in pieces | Never upload the hour to Gemini first. |
| D4 | Output is `CLAUDE.html` + zip | Claude is the consumer. GitHub auto-issues are out of v1. |
| D5 | Native Swift menu-bar app | Apple Silicon. App Sandbox off. |
| D6 | Gemini on slices + one merge pass | Max 3 video uploads at once. |
| D7 | Transcript local; clips still go to Gemini | Each 15–45s clip includes room audio. Consent checkbox before first upload. |
| D8 | No GitHub publish in v1 | No PAT required. |
| D9 | Repo is `ciprian-lupu/scrumtrace` | Build the Xcode app in this git repo. |

---

## 3. Out of v1

GitHub issue creation, Zoom bots, Chrome console capture, a hand-split editor, always-on recording, Windows/iPhone, uploading the full MP4, inlining the hour into HTML.

---

## 4. Session on disk

```text
~/Movies/ScrumTrace/sessions/2026-09-09-1530-abc123/
  CLAUDE.html
  PROMPT.txt
  session-pack.zip          ← what you attach
  session.mp4               ← local archive only
  audio.wav
  events.jsonl
  transcript.json
  media/task-01/clip.mp4    ← H.264
  media/task-01/shot-1.png
```

`events.jsonl` examples:

```json
{"t":12.04,"type":"frontmost","app":"Safari","title":"Issue #42","url":"https://github.com/acme/app/issues/42"}
{"t":188.2,"type":"pin"}
{"t":190.0,"type":"pause"}
{"t":205.1,"type":"resume"}
```

Paused ranges are **not** in any slice sent to Gemini (no 3s pre-roll into a pause).

---

## 5. App UI

**Menu:** Start / Last session / Settings. While recording: red HUD + time, Pause, Stop, Pin. While processing: Transcribing / Cutting / Gemini / Writing HTML.

**Settings:** Gemini key (Keychain), consent checkbox (clips include room audio), model (`gemini-2.5-pro`), speaker rename, **product context** (app name, optional repo URL, stack).

**HUD is a ship blocker.** People in the room must see REC.

**After Stop:** reveal folder, **Compress session pack**, open HTML. Copy button labeled **Copy prompt (text only — no screenshots)**.

---

## 6. Pipeline after Stop

1. Close MP4/WAV. Mic in the movie must be audible and within ~200 ms of `audio.wav`.
2. Local diarize + transcribe → `transcript.json`. Off the main thread.
3. Propose ≤ 12 slices (skip paused time). Export H.264 clip + 2–4 PNGs ≤1920px per slice.
4. If consent is off, stop here and say so. Do not upload.
5. Gemini on slices, **max 3 at once** → candidates. `confidence` < 0.55 = drop.
6. Gemini merge (text): ≤ 8 tasks, chatter dropped, duplicates merged, product context filled.
7. Copy chosen media to `media/task-NN/`.
8. Write `CLAUDE.html` + `PROMPT.txt` + zip.
9. Reveal folder, open HTML.

A failed slice is skipped (yellow note). HTML still builds. User can re-run analysis.

---

## 7. Speech (best-effort)

FluidAudio (who spoke) + WhisperKit (words). Romanian + English.

One laptop mic **will** merge people and fail on crosstalk. That is accepted. Settings rename Speaker 1/2. Low confidence → HTML banner: “Speaker labels may be wrong.” Claude is told names are not facts.

If SPM blocks more than a day: Settings flag “Cloud speech”, default **off**.

---

## 8. Slicer (code, not Gemini)

Merge hits into 15–45s windows with 3s pre-roll, **never into a paused range**.

Priority: **Pin > spoken keyword > URL/window change > scene cut**.

Keywords (don’t add vague ones like “issue” or “implement” — they fire on every GitHub tab):

- EN: `bug`, `broken`, `doesn't work`, `does not work`, `expected`, `screenshot`
- RO: `problema`, `nu merge`, `nu funcționează`, `nu functioneaza`, `uite`, `defect`, `trebuie`

Scene cuts: max one every 20s; ignore cursor-only jitter.

Cap 12 slices → merge → ≤ 8 tasks. Leftovers in a collapsed “Unsorted” block; Claude is told to ignore them.

---

## 9. Gemini

Slice model: `gemini-2.5-pro` (clip + stills + local transcript slice + URL).  
Merge model: same, or `gemini-2.5-flash` (text only).

**Slice JSON**

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
  "quotes": [{"speaker": "Speaker 1", "text": "…"}],
  "frame_indices": [0, 1]
}
```

**Merge JSON** adds `session_title`, `product_context` `{app, repo, stack, speakers}`, `claude_instructions`, and `tasks[]` with `source_slice_ids` and `sort_key`.

Sort: bugs first, then improvements, then implementable decisions. Drop questions Claude cannot code.

Never send `session.mp4` to Gemini.

---

## 10. HTML / zip rules

- UTF-8, inline CSS, no CDN fonts. Escape all user text.
- Relative media paths only.
- Task clips **H.264** (Chrome must play them). Archival `session.mp4` may be HEVC.
- PNG max 1920px wide. Clip target ≤10 MB. Zip target ≤40 MB. If over: drop leftover media, then shrink PNGs.
- Header: date, duration, task count, **product context**.
- `frame_indices` = PNGs in time order for that slice. Clip in/out = those transcript seconds.
- Full movie: link in appendix, not in the zip, not autoplay.
- Prompt copy includes product context and: if there are no images, ask for the zip before guessing UI.

---

## 11. Repo layout

```text
ScrumTrace/
  ScrumTrace.xcodeproj
  ScrumTrace/
    ScrumTraceApp.swift
    Info.plist
    ScrumTrace.entitlements    audio-input; App Sandbox OFF
    MenuBar/…
    Settings/…                 Keychain + consent
    Capture/SessionRecorder.swift
    Capture/MetadataSampler.swift
    Session/SessionVault.swift
    Session/Models.swift
    Speech/…
    Slicing/Slicer.swift
    Slicing/ClipExporter.swift
    Gemini/GeminiClient.swift
    Export/ClaudeHTMLRenderer.swift
    Export/SessionPackZipper.swift
    Processing/SessionProcessor.swift
```

Bundle id: `com.str8minds.ScrumTrace`.

Deep modules (small public surface):

| Module | Caller sees |
|--------|-------------|
| `SessionRecorder` | start / pause / resume / stop → folder |
| `SessionProcessor` | `process(folder) → pack` (html + zip) |
| `GeminiClient` | `analyze(slice)`, `merge(candidates)` |
| `ClaudeHTMLRenderer` | `render(session) → CLAUDE.html` |
| `SessionPackZipper` | `zip(session) → session-pack.zip` |

---

## 12. Permissions

- Phase 1: **Microphone** + **Screen Recording** only.
- Phase 2: **Accessibility** (frontmost URL / window).
- Screen Recording is TCC (System Settings), not an Info.plist key. Document it in README.
- Bundle id is frozen so TCC does not reset: `com.str8minds.ScrumTrace`.

---

## 13. Privacy

- HUD while recording.
- Pause is first-class. Auto-pause if frontmost is `1Password`, `Keychain Access`, `Wallet`.
- Paused time never becomes a Gemini slice.
- Consent + README: short clips (with room audio) leave the Mac. The hour of audio does not.

---

## 14. Build order

Fail a phase test → do not start the next.

**Phase 0 — launches.** Menu bar, Settings, Keychain. Run twice. Fake key survives quit. Nothing secret in git.

**Phase 1 — record.** `session.mp4` + `audio.wav`, HUD, Pause. 20s talk+click. QuickTime: picture **and** audible mic. Clap at t=0; wav and mp4 audio within ~200 ms. Not a 10 GB file. HEVC 1080p/1440p, 15–30 fps. No Accessibility prompt.

**Phase 2 — sidecar.** `events.jsonl` has Safari/Chrome URL + pins + pause. Open a GitHub issue in Safari; the URL is in the file.

**Phase 3 — speech.** FluidAudio + WhisperKit, background. Two people in turn → two speaker ids, roughly right words.

**Phase 4 — slices.** Pin + “that’s a bug.” H.264 clip + PNGs. Chrome plays the clip. Clip start matches the pin. No paused seconds inside.

**Phase 5 — Gemini dry run.** Consent on. JSON under `gemini/`. No HTML yet. Logs show **slice** upload only.

**Phase 6 — v1 done.** HTML + `PROMPT.txt` + zip + browser. Product context in the prompt. Zip has pictures, no full movie, under ~40 MB. Silence/scrolling → **0 tasks**, not invented work. Copy is labeled text-only.

**Phase 7 — harden.** Speaker rename, leftover `<details>`, README TCC screenshots.

---

## 15. v1 done

A ~10 minute real room test yields: playable archive movie, a transcript, `CLAUDE.html` that opens itself, sorted tasks with pictures and playable clips, a zip you would attach to Claude, no secrets in git, no GitHub issues.

---

## 16. Implement (Composer 2.5, not Fast)

```text
Implement ScrumTrace from IMPLEMENTATION_PLAN.md in this repo.

Do Phase 0 and Phase 1 only.
Stop when the Phase 1 human test can be run.
Do not add Gemini, HTML export, WhisperKit, or slicing yet.
Bundle id must be com.str8minds.ScrumTrace.
No App Sandbox. Follow section 11.
```

Then Phase 2, 3, 4, 5, 6 in separate chats.

---

## 17. Source of truth

This file wins over chat history.

Decisions: §2. Handoff: §1. Pipeline: §6. Slicer: §8. Gemini JSON: §9. HTML/zip: §10. Phases: §14.
