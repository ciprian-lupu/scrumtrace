# ScrumTrace — REVISE Closure (2026-09-09)

External re-review of `IMPLEMENTATION_PLAN.md` at `86ed189`. Prior round items that stay closed: handoff pretest, `t_wall`/`t_media`, `candidates[]`, `needs_review`, no hasty cloud-transcript replace, versioned manifest, observed/stated/inferred.

**Verdict:** REVISE for the full spec — not a redesign. Five normative blockers below must be closed before the named phases. “Production-Ready” is not supported until implementation + measured tests exist.

## Phase gate updates

| Phase | Gate |
|---|---|
| **-1** Mock handoff / pretest | **APPROVE** — execute next; record which tools were required to extract clip facts |
| **0–1** Shell + recorder + Pause | **APPROVE after** blocker **#1** (Pause covers all capture sources) |
| **5–6** AI engine + export pack | **REVISE** — blockers **#2–#5** |
| Production-Ready label | **Not yet** |

---

## Blocker 1 — Pause covers all capture sources (before Phase 1)

**Refs:** §2 D1/D3, §3, §5, §6.

Pause must stop **every** capture path, not only screen frames / mic / metadata. Revision added **system audio**, **Shot**, and **Hold-to-Talk** without Pause rules.

**Normative**
- One shared capture-state and time bound for all sources.
- While Paused: no new Shot capture, no Hold-to-Talk capture, no system-audio persistence.
- Annotating an image captured *before* Pause may be allowed only if the plan defines that as non-capture.

**Forbidden path (must be impossible):** Pause → sensitive content appears → Shot Save / Hold-to-Talk / system-audio buffer write.

**Acceptance test:** During Pause, display a fake token, speak it, play it via system audio, try Shot hotkey + Hold-to-Talk. The token must be absent from `session.mp4`, `audio.wav`, transcripts, Shot artifacts, and all exports.

Update **D3** and §3 Pause Invariants accordingly.

---

## Blocker 2 — Archive vs export + upload approval (before upload/export)

**Refs:** §1, §2 D5, §4, §7.

Handing the whole session folder leaks private archive files even if ZIP excludes them. Explicit upload approval must return (Keychain ≠ approval).

**Normative layout**
```text
session/
  archive/                 ← film, audio, full transcript, raw events
  export/                  ← only approved handoff materials
  session.manifest.json    ← canonical SoT
```

- Agent receives **`export/` only**.
- ZIP is built from an **explicit allowlist**.
- Exported manifest is a **projection** of the canonical manifest, not a second SoT.
- Before the first external transfer: user confirms **destination + payload** (including clip audio). Retries reuse the same approval.

**Acceptance test:** A fake phrase that appears only in irrelevant discussion must not appear in `export/`, ZIP, or handoff docs. With upload unapproved, no captured content is sent to any provider.

---

## Blocker 3 — Media budget is measured, not “guaranteed” 35 MB (before export)

**Refs:** §2 D7/D9, §4, §8, Gate 4.

Max-duration math at budgeted bitrate can exceed 35 MB (e.g. 8×25s clips + 16×350KB images ≳ 38 MB). Gate 4 “<30 MB” conflicts with 12×20s video-only math. “Keep all Shots” vs max 16 images + originals+annotated is unresolved.

**Normative**
- Separate **working/temp budget** from **final package budget**.
- Export measures **actual** size, adjusts encoding, and **reports** what did not fit.
- Full originals may remain in `archive/`.
- Explicitly choose priority: either “all Shots in export” **or** “max 35 MB” — not both for unlimited Shots.
- Drop the word **guaranteed** until measured on defined hardware.

**Acceptance test:** 8×25s clips, 20 Shots, detailed IDE captures → package respects the chosen limit, keeps valid refs, and does not hide non-exported materials.

---

## Blocker 4 — Provider engine must declare real capabilities (before Phase 5)

**Ref:** §7.

Keep `AIProviderProtocol`, but remove false compatibility claims.

**Normative**
- Do not list retired models as usable (Anthropic Sonnet 3.5 retired 2025-10-28; Sonnet 3.7 retired 2026-02-19).
- Do not ship a shared schema using non-portable types like `"OBJECT"` / `"STRING"` as if it were JSON Schema / OpenAI Structured Outputs for every provider.
- Internal common I/O contract + **per-provider adapters**.
- Each provider config declares capabilities: text / images / video.
- **Never** silently strip media to make a request succeed.
- MVP recommendation: validate **one** provider end-to-end; keep the interface for extension.

---

## Blocker 5 — Evidence must be verifiably required (before final task generation)

**Refs:** §4, §7.

`observed` / `stated` / `inferred` stays. Optional quotes / frame refs + free-form `agent_instructions` + undefined `confirmed` are insufficient.

**Normative**
- App attaches the analyzed fragment identity.
- Every kept candidate has ≥1 **valid** evidence reference.
- Quotes (when present) link to transcript segments with time refs.
- Media refs are validated against the manifest / export allowlist.
- Hypotheses do not auto-promote to confirmed facts; define the `confirmed` criterion.
- General agent instructions come from a **controlled template**; model-proposed content remains untrusted content.
- Reintroduce **HTML escaping** for any text injected into HTML.

**Acceptance test:** Synthetic responses with missing image, quote absent from transcript, ref outside export, and HTML markup — none become “confirmed” with fake evidence; markup renders as text.

---

## Soft adjustments (no redesign)

1. Performance claims → measurable targets with hardware, OS/app versions, and test duration. Align “60+ min zero drift” with the actual acceptance window (e.g. 50 ms / 20 min) — no “guaranteed” before measurement.
2. Execute Phase -1 handoff pretest now; for the video fact, record which tools were required (filesystem image tools ≠ automatic MP4 understanding).

## Message to implementers

Close these five blockers with punctual plan edits + tests. Do not widen scope (extra providers, presentation modes) until Phase -1 is executed and Phase 0–1 Pause-all-sources is green.
