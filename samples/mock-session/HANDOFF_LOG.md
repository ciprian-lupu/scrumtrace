# Phase -1 handoff log

This pack is `samples/mock-session/export/` only. Do not hand `archive/` (this mock has none).

## Task 1 — image-only fact
- File: `export/shots/001.annotated.png` and `export/shots/001.png`
- Prompt: "What exact failure identity is shown when Save athlete fails?"
- Expected: a coding agent that can **read the PNG** reports the banner code from the pixels.
- The code is intentionally absent from `AGENT_CONTEXT.md`.

## Task 2 — clip-only sequence
- File: `export/media/task-02/clip.mp4`
- Prompt: "What is the recovery order and overlay watermark after the ingest stall?"
- Cursor / Claude Code reading images does **not** prove they parsed this MP4.
- Tools that extract the clip-only fact in this environment:
  1. Human watch of the HTML5 `<video>` in `SESSION_BRIEF.html`
  2. `ffprobe` / `ffmpeg` frame dump (`ffmpeg -i media/task-02/clip.mp4 -vf select='eq(n,300)' -vframes 1 /tmp/frame.png`)
- A still (`media/task-02/shot-1.jpg`) is provided for agents that cannot decode MP4. The still is a convenience; the Gate -1 *sequence* lives in the clip.

## Result
- Markdown and JSON in this export must not contain `ATH-SAVE-DISABLED-0x9F` or `STENCIL-4419`.
- `SESSION_BRIEF.html` is self-contained (CSS/JS inlined, system font stacks, no webfont fetch) and playable in a browser.
