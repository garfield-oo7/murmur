# Murmur

On-device voice dictation for macOS 27. Hold **Option+D**, speak, and release: your words are typed wherever the text cursor is, in any app.

- Uses Apple's on-device speech models (`SpeechAnalyzer` + `SpeechTranscriber`), so audio never leaves your Mac
- Hold-to-talk with a bottom-center pill whose bars react to your voice
- Inserts text into any app (paste with clipboard restore, falling back to the Accessibility API and typed keystrokes)

**Status:** early development.

## Requirements
- macOS 27, Apple silicon
- Xcode 27+

## Repo layout
- `spike/`: feasibility checks (speech model availability, hotkey registration)
