# What leaves your Mac

ScrumTrace is a local recorder. ScrumTrace itself does not receive your meetings. You choose a BYOK provider (OpenAI-compatible, Anthropic, or Google) if you approve upload at Stop.

## Processed only on this Mac

- Screen, system audio, and microphone in `archive/`
- WhisperKit transcripts (`archive/full_transcript.json`)
- Shot PNGs, events, and the master movie
- API keys in the login Data Protection keychain

## Sent only after you tap Approve upload

- Still images that fit the pack
- Transcript excerpts around each slice
- Window titles and **scrubbed** URLs (query and fragment stripped)
- Shot notes and product context (app name, repo URL, tech stack)
- For Gemini only, and only if Settings → Allow Gemini to upload clip video is on: the 720p clip (video and audio)

Cancel / Local export only sends nothing.

## Retention

Sessions stay under `~/Movies/ScrumTrace/sessions` until you delete them or set a retention window in Settings → General.

## Other participants

You are the controller. Tell people before Record. Use [PARTICIPANT_NOTICE.md](PARTICIPANT_NOTICE.md).
