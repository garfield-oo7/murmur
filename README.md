# Murmur

On-device voice dictation for macOS 27. Hold **Option+D**, speak, and release: your words are typed wherever the text cursor is, in any app.

- Uses Apple's on-device speech models (`SpeechAnalyzer` + `DictationTranscriber`), so audio never leaves your Mac
- Hold-to-talk with a bottom-center pill whose bars react to your voice
- Inserts text into any app (paste with clipboard restore, falling back to the Accessibility API and typed keystrokes)

**Status:** early development.

## Requirements
- macOS 27, Apple silicon
- Swift 6.4 toolchain (Xcode 27 or the Command Line Tools); no Xcode project needed

## Install

```sh
git clone git@github.com:garfield-oo7/murmur.git && cd murmur
scripts/install.sh
```

This builds a release binary with SwiftPM, wraps it in `Murmur.app`, signs it and installs it to `~/Applications/Murmur.app`, then launches it. Run it again to update. Options: `--debug`, `--no-open`.

Murmur lives in the menu bar (no Dock icon). On first launch a setup window asks for **Microphone** and **Accessibility** access and downloads the English speech model.

macOS ties those permissions to the app's code signature, so the install script signs every build with one local certificate, "Murmur Dev". If it's missing, the script offers to create it (`scripts/make-dev-cert.sh`, which asks for your Mac password once). Without it the app is signed ad-hoc and you have to re-grant Accessibility after every update.

## Uninstall

```sh
scripts/uninstall.sh                     # asks first; --yes to skip the question
scripts/uninstall.sh --keep-vocabulary   # keep ~/Library/Application Support/Murmur (vocabulary and history)
```

It quits Murmur, removes the login item, the app, its settings, your vocabulary file and dictation history, and its privacy permissions. The speech model is shared with macOS dictation and stays. The script prints how to delete the "Murmur Dev" certificate if you want that gone too.

## Using Murmur

- **Hold ⌥D** (Option+D) in any app. Start speaking after the soft *tink*: that's when the mic is live.
- **Let go** to finish. The text is typed where your text cursor is, and a *pop* confirms it. The last dictation also stays in Murmur's menu (🎙 in the menu bar) with **Copy Last Dictation**.
- Murmur pastes through the clipboard and puts back what you had copied. The dictation is marked as temporary, so clipboard managers that follow the nspasteboard.org convention skip it. If an app doesn't like pasting, switch **Insert text by** in Settings.
- Password fields (and Terminal with Secure Keyboard Entry) block typed input on purpose. Murmur then leaves the text in its menu.
- While you hold the shortcut, a small **waveform pill** at the bottom of the screen shows Murmur is listening. Its bars follow your voice, then shimmer while the text is produced. It never takes focus from your app.
- **Live text:** while you speak, a caption above the pill shows the last two lines of what Murmur hears, about half a second behind your voice, with your vocabulary already applied. Words that are still a guess are slightly dimmed. Nothing is typed until you let go. Turn it off with **Settings → Show words as you speak**.
- **⌫ (Delete)** while holding starts over: what you've said so far is thrown away, and after the *tink* you continue from scratch without letting go.
- **Esc** while holding cancels (the pill shakes). A very short tap does nothing.
- **Vocabulary:** Murmur knows about 2,900 AI-engineering and developer names (current models, labs, tools) from `Resources/Vocabulary.txt`, and spells them exactly: "tail scale" → Tailscale, "deep seek v3" → DeepSeek-V3, "cube control" → kubectl. Add your own with **Settings → Edit My Vocabulary…** (same format; the changes apply after your next dictation).
- **Paths and commands:** say "tilde slash dot claude slash settings dot json" for `~/.claude/settings.json`, or "slash model" for `/model`.
- **Context-aware fixes:** phrases that are real English ("clots on it") are only corrected to a term (Claude Sonnet) when the sentence is technical, i.e. it has a path, a `/command` or a known name.
- **History:** every dictation is saved on your Mac in `~/Library/Application Support/Murmur/History.jsonl`, one JSON line each: time, app, what the recognizer heard, what was typed, and how long it took. The menu's **Recent Dictations** shows the last 10 (click to copy). Settings lets you turn it off, choose how long to keep it (default 30 days), show it in Finder or clear it. Cancelled dictations (Esc) aren't saved. Comparing `heard` with `text` is a quick way to find words for your vocabulary.
- Murmur **opens at login** (turn it off in Settings, or in System Settings → General → Login Items).
- **Settings…** in the menu: change the shortcut, pick the microphone (Automatic by default: a wired headset like EarPods when plugged in, otherwise the built-in mic; never AirPods, so they aren't switched into call mode), choose how text is inserted, turn sounds or the waveform off, and set how strongly the bars react.

## For other apps

Murmur tells other apps on your Mac (like TouchDeck) which microphone it uses and whether it's dictating, through distributed notifications. No permissions are needed.

- **`io.github.garfield-oo7.Murmur.status`**: Murmur posts this whenever something changes. Its `userInfo` holds strings:
  - `state`: `idle`, `listening` or `transcribing`
  - `microphoneName`: e.g. "EarPods Microphone"
  - `microphoneUID`: the CoreAudio device UID
  - `microphoneSetting`: `auto`, `builtin`, `system` or a device UID
  - `version`: `1`
- **`io.github.garfield-oo7.Murmur.requestStatus`**: post this and Murmur replies with a status notification. Use it when your app starts.

The microphone is the one Murmur would record from if you pressed the shortcut now. While a dictation is running, it's the one in use.

```swift
let center = DistributedNotificationCenter.default()
center.addObserver(forName: .init("io.github.garfield-oo7.Murmur.status"), object: nil, queue: .main) { note in
    let info = note.userInfo as? [String: String] ?? [:]
    print(info["state"] ?? "", info["microphoneName"] ?? "")
}
center.postNotificationName(.init("io.github.garfield-oo7.Murmur.requestStatus"), object: nil, userInfo: nil, deliverImmediately: true)
```

From a terminal: `~/Applications/Murmur.app/Contents/MacOS/Murmur --status` prints the same information as JSON.

## Vocabulary format

`Resources/Vocabulary.txt` is the bundled list; your own file at `~/Library/Application Support/Murmur/Vocabulary.txt` uses the same format:

```
## Section headings and blank lines are ignored
Tailscale                      # a term: spelled exactly like this
kubectl | cube control         # a term with mishearings to correct
Murmur | !mural                # "!" corrects it even in ordinary sentences
```

Single English words in the list (like "Linear") never rewrite ordinary speech. Mishearings that are real English ("clots on it") are only fixed in technical sentences.

## Development

```sh
swift build                    # debug build
swift test                     # MurmurCore tests: vocabulary, spoken syntax, live transcript, history file
scripts/install.sh --debug     # run the real app (permissions need the signed bundle)

# What would Murmur type for this audio? Uses the same recognizer and vocabulary.
say -o /tmp/sample.wav --data-format=LEI16@16000 "open tilde slash dot claude"
~/Applications/Murmur.app/Contents/MacOS/Murmur --transcribe /tmp/sample.wav

# Live logs
/usr/bin/log stream --info --predicate 'subsystem == "io.github.garfield-oo7.Murmur"'
```

`--transcribe` compiles the full vocabulary first, so it takes about 12 seconds. The app does that once at launch.

## Repo layout
- `Package.swift`: SwiftPM package (no Xcode project)
- `Sources/Murmur/`: the menu bar app
  - `App/`: entry point, menu, settings, setup window, command-line options
  - `Dictation/`: mic capture, the speech recognizer and the hold-to-talk session
  - `Pill/`: the waveform pill
  - `System/`: hotkey, permissions, text insertion, login item, speech model
- `Sources/MurmurCore/`: vocabulary, spoken-syntax rules, live-transcript merging and the history file format (pure Swift, unit-tested)
- `Tests/MurmurCoreTests/`: tests for MurmurCore
- `Resources/`: `Info.plist`, entitlements and the bundled `Vocabulary.txt`
- `scripts/`: `install.sh`, `uninstall.sh`, `make-dev-cert.sh`
