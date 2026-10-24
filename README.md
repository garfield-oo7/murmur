# Murmur

On-device voice dictation for macOS 27. Hold **Option+D**, speak, and release: your words are typed wherever the text cursor is, in any app.

- Uses Apple's on-device speech models (`SpeechAnalyzer` + `SpeechTranscriber`), so audio never leaves your Mac
- Hold-to-talk with a bottom-center pill whose bars react to your voice
- Inserts text into any app (paste with clipboard restore, falling back to the Accessibility API and typed keystrokes)

**Status:** early development.

## Requirements
- macOS 27, Apple silicon
- Xcode 27+

## Building the app

```sh
scripts/make-dev-cert.sh   # once: creates a local "Murmur Dev" signing certificate (asks for your Mac password)
scripts/build.sh           # builds, installs to ~/Applications/Murmur.app and launches it
```

Murmur lives in the menu bar (no Dock icon). On first launch a setup window asks for **Microphone** and **Accessibility** access and downloads the English speech model.

macOS ties those permissions to the app's code signature. `build.sh` signs every build with the same local certificate, so permissions survive rebuilds. Without the certificate it signs ad-hoc, and you have to re-grant Accessibility after each build. You can open `Murmur.xcodeproj` in Xcode too, but builds run from Xcode are ad-hoc signed, so use the script when you need working permissions.

## Using Murmur

- **Hold ⌥D** (Option+D) in any app. Start speaking after the soft *tink*: that's when the mic is live.
- **Let go** to finish. The text is typed where your text cursor is, and a *pop* confirms it. The last dictation also stays in Murmur's menu (🎙 in the menu bar) with **Copy Last Dictation**.
- Murmur pastes through the clipboard and puts back what you had copied. The dictation is marked as temporary, so clipboard managers that follow the nspasteboard.org convention skip it. If an app doesn't like pasting, switch **Insert text by** in Settings.
- Password fields (and Terminal with Secure Keyboard Entry) block typed input on purpose. Murmur then leaves the text in its menu.
- While you hold the shortcut, a small **waveform pill** at the bottom of the screen shows Murmur is listening. Its bars follow your voice, then shimmer while the text is produced. It never takes focus from your app.
- **Esc** while holding cancels (the pill shakes). A very short tap does nothing.
- **Vocabulary:** Murmur knows about 4,000 AI-engineering names (models from every major lab, tools, people, companies) from `Murmur/Vocabulary.txt`, and spells them exactly: "tail scale" → Tailscale, "deep seek v3" → DeepSeek-V3, "cube control" → kubectl. Add your own with **Settings → Edit My Vocabulary…** (same format; the changes apply after your next dictation).
- **Settings…** in the menu: change the shortcut, pick the microphone (built-in by default, so AirPods aren't hijacked), choose how text is inserted, turn sounds or the waveform off, and set how strongly the bars react.

## Repo layout
- `Murmur/`, `Murmur.xcodeproj`, `Config/`: the menu bar app
- `scripts/`: build and signing helpers
- `spike/`: feasibility checks (speech model availability, hotkey registration)
- `prototype/`: `murmur-cli`, a command-line prototype (mic → `SpeechTranscriber` → text, with latency timings)

## Prototype CLI

```sh
cd prototype
swift build -c release

# Speak, then press Enter to stop (the "key release"). The transcript goes to stdout, timings to stderr.
.build/release/murmur-cli                     # mic via CaptureInputSequenceProvider (macOS 27)
.build/release/murmur-cli --source engine     # mic via AVAudioEngine + AnalyzerInputConverter
.build/release/murmur-cli --runs 3            # repeat to compare cold vs warm latency

# No mic needed: transcribe a synthesized file, fed in real time
say -o /tmp/sample.wav --data-format=LEI16@16000 "Testing one two three"
.build/release/murmur-cli --file /tmp/sample.wav
```

Other flags: `--engine dictation` (DictationTranscriber), `--fast` (`.fastResults`), `--seconds N`, `--locale ID`. See `--help`.

Run the mic modes from a terminal app (Terminal, iTerm, Ghostty). macOS asks for microphone access on behalf of that app the first time.
