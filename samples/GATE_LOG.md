# ScrumTrace hardware gates

Fill this in on a **Mac**. Linux CI and this cloud agent cannot run ScreenCaptureKit, WhisperKit, or Gate 0/1.

Do not treat a passing `bash scripts/run_linux_tests.sh` as Gate 0–6.

Machine: `_` · macOS: `_` · chip: `_` · ScrumTrace build: `_`

---

## Gate −0 — 30 s record (not in the original spec)

Record 30 seconds, Stop or Quit, confirm the session folder exists.

| Check | Pass? | Notes |
|---|---|---|
| `archive/session.mp4` exists and duration > 0 |  | |
| `archive/audio.wav` exists and duration > 0 |  | |
| Inspector exists-fields true (no pause token; you did not pause) |  | |
| `agent.jsonl` has `recorder_first_sample` for screen, audio, wav |  | |

If this fails, do not run Gate 0 or Gate 1.

---

## Gate 0 — shell (Phase 0)

Hotkeys from **full-screen Keynote** must not steal focus.

| Check | Pass? | Notes |
|---|---|---|
| ⌥⌘S Shot does not bring ScrumTrace to the front |  | |
| ⌥⌘Space Pin does not steal Keynote focus |  | |
| ⌥⌘P Pause toggles HUD amber without activating the app |  | |
| Menu bar extra exists (`com.str8minds.ScrumTrace`) |  | |
| App Sandbox is **off** |  | |
| Session folder created with `archive/` and `export/` |  | |

---

## Gate 1 — pause, every source (Phase 1, contract C1)

Record ≥ 20 minutes with **three pauses**. During **one** pause:

1. Display a unique screen token.
2. Speak a unique passphrase into the mic.
3. Play the same token through **system audio**.
4. Press Shot. Press-and-hold Hold-to-Talk.

Token / passphrase used: `_`

| Inspect | Must be absent | Pass? |
|---|---|---|
| `archive/session.mp4` | pause token |  |
| `archive/audio.wav` | passphrase and token |  |
| `archive/full_transcript.json` | passphrase and token |  |
| `archive/events.jsonl` | pause token |  |
| `archive/shots/` | no new PNG created during pause |  |
| `export/` and zip | token / passphrase |  |

A/V offset at t = 20 min (target ≤ 50 ms, not a guarantee): `_` ms

Hold-to-Talk in-flight at Pause: temp WAV deleted? `_`

---

## Gate 3 — WhisperKit (Phase 3)

Model on disk: `openai_whisper-large-v3-v20240930_turbo_632MB` / Settings value: `_`

| Run | Media seconds | Wall time | Notes |
|---|---|---|---|
| 5 min 16 kHz mono (target, not a guarantee) |  |  | |
| Dual pass: room WAV + movie system audio merged |  |  | `sources` in `full_transcript.json`: `_` |
| `archive/pipeline-timing.json` whisper_wall_seconds |  |  | Never copied into `export/` |

---

## Gate 4 — slicer + measured pack (Phase 4, C3)

Working media in `archive/media-work/` may exceed 35 MB.

| Check | Result |
|---|---|
| Candidate windows ≤ 12 |  |
| At least one 720p clip plays in Chrome without transcode |  |
| Pack builder logged **measured** zip bytes | `_` bytes |

---

## Gate 5 — MVP provider + evidence (Phase 5, C4/C5/D15)

| Check | Pass? |
|---|---|
| Consent sheet shows provider, endpoint, model |  |
| Cancel → no upload, local `export/` still written |  |
| Empty / invalid API key → no crash, `offline_failed` / needs_review |  |
| Retired Anthropic id refused |  |
| `confirmed` tasks have files on disk under `export/` |  |
| Failed quotes demote to `needs_review` |  |

---

## Gate 6 — export pack (Phase 6, C2/C3)

| Check | Result |
|---|---|
| Finder reveals **`export/`**, not `archive/` |  |
| Zip built from allow-list (no session-root minus exclusions) |  |
| Measured `session-pack.zip` ≤ 35 MB | `_` bytes from `archive/pipeline-timing.json` |
| `OMITTED.md` present iff anything was dropped |  |
| Remaining paths in `AGENT_CONTEXT.md` exist |  |
| `SESSION_BRIEF.html` escapes `& < > "` |  |

8×25 s + 20 shots stress (zip ≤ 35 MB, omitted named): `_`
