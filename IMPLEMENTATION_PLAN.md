# ScrumTrace — implementation plan

**Spec.** Reviewed and tightened. Capture is unproven until Phase 1 plays in QuickTime.

**Audit question:** Debating is good if this plan is not the best. If you have a better idea, update this file.

GitHub: [ciprian-lupu/scrumtrace](https://github.com/ciprian-lupu/scrumtrace). App code is not built.

---

## 1. Product

We sit around one MacBook and test software. Several people talk. Someone clicks.

**ScrumTrace** is a Mac menu-bar icon.

1. **Start** — record the whole screen and the room mic as one video.
2. Talk and click. **Shot** = take a screenshot now, then annotate and/or describe it (type or **voice**). **Pin** = mark the time, no still. **Pause** = stop writing video (passwords, Slack, Mail).
3. **Stop** — transcribe locally, cut short clips, Gemini reads those clips **and the human shots**, write one analyzed HTML brief.
4. Reveal the session folder, offer **Compress session pack**, open `CLAUDE.html`.

Give the pack to **Cursor first** (drop the session folder or zip). Claude.ai is backup and often ignores clips. Not GitHub tickets. Not a raw hour of chat.

### Handoff (be honest)

| Mode | What you send | What you get |
|------|----------------|----------------|
| **Cursor (default)** | Drop the session folder, or `session-pack.zip`, with `@CLAUDE.html` | Tasks + screenshots + clips |
| **Claude.ai** | Attach the zip; if clips fail, attach the PNGs + `PROMPT.txt` | Tasks + pictures; video is unreliable |
| **Text-only** | Copy prompt / `PROMPT.txt` | Words only. UI must say so. |

Default zip = `CLAUDE.html` + `PROMPT.txt` + `transcript.json` + `media/**`. **No** `session.mp4`, **no** `audio.wav`. Full movie stays on disk as a local archive.

### Example

- Ciprian hits **Shot**, circles the Save button, holds **Voice**: “this does nothing, it should store the athlete”
- Later: Shot + typed note “search ignores diacritics”
- Coffee talk: dropped

`CLAUDE.html` has **two tasks**, each with expected/actual, repro, screenshots, a ~20s clip, quotes. Full transcript is an appendix.

---

## 2. Locked decisions

| # | Decision | Meaning |
|---|---------|---------|
| D1 | Room, one MacBook | Not Zoom-first. One mic. Speaker names are best-effort. |
| D2 | Full screen+mic video | Still-only is out. **Main display only** in v1. |
| D3 | Analyze after Stop, in pieces | Never upload the hour to Gemini first. |
| D4 | Output is `CLAUDE.html` + zip | **Cursor is the consumer.** Claude.ai is backup. No GitHub auto-issues. |
| D5 | Native Swift menu-bar app | Apple Silicon. App Sandbox off. |
| D6 | Gemini on slices + one merge pass | Max 3 video uploads at once. |
| D7 | Transcript local; clips still go to Gemini | Each 15–45s clip includes room audio. Consent checkbox before first upload. |
| D8 | No GitHub publish in v1 | No PAT required. |
| D9 | Repo is `ciprian-lupu/scrumtrace` | Build the Xcode app in this git repo. |
| D10 | Manual shot + note | Button/hotkey grabs a still. User can draw on it and add a description by **keyboard or voice**. Human shots always reach Claude. |

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
  shots/004.png
  shots/004.annotated.png
  shots/004.json            ← description, voice text, tools used
  media/task-01/clip.mp4    ← H.264
  media/task-01/shot-1.png
```

`events.jsonl` examples:

```json
{"t":12.04,"type":"frontmost","app":"Safari","title":"Issue #42","url":"https://github.com/acme/app/issues/42"}
{"t":188.2,"type":"shot","id":"004","path":"shots/004.png"}
{"t":194.0,"type":"shot_note","id":"004","description":"Save does nothing","source":"voice"}
{"t":200.0,"type":"pin"}
{"t":210.0,"type":"pause"}
{"t":225.1,"type":"resume"}
```

Paused ranges are **not** in any slice sent to Gemini (no 3s pre-roll into a pause).

### Manual shot (human evidence)

HUD/menu **Shot** (and a global hotkey) grabs the main display to `shots/NNN.png` and opens a small note window. Video keeps recording.

The note window:

- Preview of the still
- **Annotate:** rectangle, arrow, red pen. Saved as `shots/NNN.annotated.png` (this is what Claude sees if present)
- **Description:** text field
- **Voice:** hold-to-talk (or toggle). Short utterance → WhisperKit → **append** to the description. Romanian + English. Mic is already on for the session; this is a labeled note, not a second recorder
- Save / skip note (the PNG is kept either way)

Human shots are **never dropped** by the 0.55 Gemini floor. They always appear on a task, or as their own task if Gemini would have discarded the moment.

---

## 5. App UI

**Menu:** Start / Last session / Settings. While recording: red HUD + time, **Shot**, Pause, Stop, Pin. While processing: Transcribing / Cutting / Gemini / Writing HTML.

**Shot** is a first-class HUD button, not buried. Note window can stay up while the room keeps talking.

**Settings:** Gemini key (Keychain), consent checkbox (clips include room audio), model (`gemini-2.5-pro`), speaker rename, stack hint.

**Product context** is filled automatically when possible: frontmost GitHub URL (Phase 2), else Settings app name / repo. Do not rely on a stale typed string.

**HUD is a ship blocker.** People in the room must see REC.

**After Stop:** reveal folder, **Compress session pack**, open HTML. Copy button labeled **Copy prompt (text only — no screenshots)**.

---

## 6. Pipeline after Stop

1. Close MP4/WAV. Mic in the movie must be audible and within ~200 ms of `audio.wav`.
2. Local **WhisperKit** transcript → `transcript.json`. Off the main thread. No speaker library in v1 — Gemini may label voices from the clip. FluidAudio is Phase 7 if quotes are actually wrong.
3. Propose ≤ 12 slices (skip paused time). Every **Shot** forces a slice around that time. Export H.264 clip + PNGs (prefer `*.annotated.png` + the human description).
4. If consent is off, stop here and say so. Do not upload. Human shots + notes still land in the HTML.
5. Gemini on slices, **max 3 at once** → candidates. `confidence` < 0.55 = drop **unless** the slice has a human shot.
6. Gemini merge (text): ≤ 8 tasks, chatter dropped, duplicates merged, product context filled. Shot descriptions are ground truth — do not rewrite away.
7. Copy chosen media to `media/task-NN/` including annotated stills.
8. Write `CLAUDE.html` + `PROMPT.txt` + zip.
9. Reveal folder, open HTML.

A failed slice is skipped (yellow note). HTML still builds. User can re-run analysis.

---

## 7. Speech (v1 = transcript only)

**v1:** WhisperKit (`large-v3` or turbo), Romanian + English. One timeline of words + timestamps. Gemini may put names on quotes from the clip. Banner: “Speaker labels are guessed.”

**Not v1:** FluidAudio diarization. Add in Phase 7 only if guessed names are useless.

One laptop mic will merge people. That is accepted.

If WhisperKit SPM blocks more than a day: Settings flag “Cloud speech” (Gemini on `audio.wav`), default **off**.

---

## 8. Slicer (code, not Gemini)

Merge hits into 15–45s windows with 3s pre-roll, **never into a paused range**.

Priority: **Shot > Pin > spoken keyword > URL/window change > scene cut**.

Keywords (don’t add vague ones like “issue” or “implement” — they fire on every GitHub tab):

- EN: `bug`, `broken`, `doesn't work`, `does not work`, `expected`, `screenshot`
- RO: `problema`, `nu merge`, `nu funcționează`, `nu functioneaza`, `uite`, `defect`, `trebuie`

Scene cuts: max one every 20s; ignore cursor-only jitter.

Cap 12 slices → merge → ≤ 8 tasks. Leftovers in a collapsed “Unsorted” block; Claude is told to ignore them.

---

## 9. Gemini

Slice model: `gemini-2.5-pro` (clip + stills + **human shot + description if any** + local transcript slice + URL).  
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
  "human_shot_ids": ["004"],
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
- Each task shows human annotated stills first, then auto keyframes. Show the shot description under the picture (`Voice:` / `Typed:`).
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
    Capture/ShotCapture.swift
    Capture/ShotNoteWindow.swift      annotate + text + hold-to-talk
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
| `SessionRecorder` | start / pause / resume / stop / `shot()` → folder |
| `ShotNoteWindow` | show(png) → saved note (draws, text, voice) |
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

**Phase 0 — launches.** Menu bar, Settings, Keychain. Check in `samples/claude-pack/` (dummy `CLAUDE.html` + two fake tasks + PNGs) and drop that folder on Cursor once, so the handoff is proven before capture exists. Run the app twice. Fake key survives quit. Nothing secret in git.

**Phase 1 — record.** Main display + mic → `session.mp4` + `audio.wav`, HUD, Pause. 20s talk+click. QuickTime: picture **and** audible mic. Clap at t=0; wav and mp4 audio within ~200 ms. Not a 10 GB file. HEVC 1080p/1440p, 15–30 fps. No Accessibility prompt.

**Phase 2 — sidecar + Shot.** `events.jsonl` has URL + pins + pause + shots. **Shot** saves a PNG, opens the note window: draw (box/arrow/pen), type a description, Save. Open a GitHub issue in Safari; that URL becomes default product context.

**Phase 3 — speech + voice note.** WhisperKit on the session. On a Shot note, **hold-to-talk** appends words to the description. Spoken sentence in `transcript.json`; voice note in `shots/NNN.json`.

**Phase 4 — slices.** A Shot + a Pin + “that’s a bug.” H.264 clip + the **annotated** still. Chrome plays the clip. Human shot is in the slice. No paused seconds inside.

**Phase 5 — Gemini dry run.** Consent on. JSON under `gemini/`. No HTML yet. Logs show **slice** upload only.

**Phase 6 — v1 done.** HTML + `PROMPT.txt` + zip + browser. Drop the folder on Cursor and confirm Claude/Cursor can see pictures. Zip has pictures, no full movie, under ~40 MB. Silence/scrolling → **0 tasks**. Copy is labeled text-only.

**Phase 7 — harden.** FluidAudio only if speaker guesses failed, leftover `<details>`, README TCC screenshots.

---

## 15. v1 done

A ~10 minute real room test yields: playable archive movie, a timestamped transcript, at least one **manual Shot** with a voice or typed note (and optional scribble), `CLAUDE.html` that opens itself with that still + description on a task, a folder/zip you would drop on **Cursor**, no secrets in git, no GitHub issues.

---

## 16. Audit prompt

```text
Audit IMPLEMENTATION_PLAN.md for ScrumTrace.

Question: Debating is good if this plan is not the best.
If you have a better idea for the product, the handoff, or the build order, update this file.
Do not only comment. Edit the spec so the next reader gets the better plan.
If the plan is already the best we can write without building, say so and stop.

Do not implement the app.
```

---

## 17. Implement (Composer 2.5, not Fast)

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

## 18. Source of truth

This file is the current spec. A better idea should be written into this file, not left in chat.

Decisions: §2. Handoff: §1. Shot notes: §4. Pipeline: §6. Slicer: §8. Gemini JSON: §9. HTML/zip: §10. Phases: §14. Audit: §16.
