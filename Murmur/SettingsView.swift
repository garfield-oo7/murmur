import AVFoundation
import Carbon.HIToolbox
import CoreAudio
import SwiftUI

struct SettingsView: View {
    let model: AppModel
    @AppStorage("playSounds") private var playSounds = true
    @AppStorage(Microphone.defaultsKey) private var microphone = Microphone.builtIn

    var body: some View {
        Form {
            LabeledContent("Dictation shortcut") {
                ShortcutRecorder(hotkey: model.hotkey)
            }
            Text("Hold the shortcut, speak, and let go. Press Esc while holding to cancel.")
                .font(.callout)
                .foregroundStyle(.secondary)
            Picker("Microphone", selection: $microphone) {
                Text("Built-in microphone").tag(Microphone.builtIn)
                Text("System default").tag(Microphone.systemDefault)
                let others = Microphone.available.filter {
                    $0.transportType != Int32(bitPattern: kAudioDeviceTransportTypeBuiltIn)
                }
                if !others.isEmpty {
                    Divider()
                    ForEach(others, id: \.uniqueID) { Text($0.localizedName).tag($0.uniqueID) }
                }
            }
            Toggle("Play start and stop sounds", isOn: $playSounds)
        }
        .formStyle(.grouped)
        .frame(width: 420)
        .fixedSize()
    }
}

/// Click, then press a key combination. Needs at least one of ⌃⌥⌘ (or an F-key) so a
/// plain letter can't be hijacked system-wide. Esc stops recording.
private struct ShortcutRecorder: View {
    let hotkey: HotkeyManager
    @State private var isRecording = false
    @State private var monitor: Any?
    @State private var message: String?

    var body: some View {
        VStack(alignment: .trailing, spacing: 4) {
            HStack {
                Button(isRecording ? "Press keys…" : hotkey.displayName) {
                    isRecording ? stop() : start()
                }
                .frame(minWidth: 110)
                if hotkey.shortcut != .default {
                    Button("Reset") { apply(.default) }
                }
            }
            if let message {
                Text(message).font(.caption).foregroundStyle(.red)
            }
        }
        .onDisappear(perform: stop)
    }

    private func start() {
        message = nil
        isRecording = true
        hotkey.suspend()
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            let code = Int(event.keyCode)
            if code == kVK_Escape {
                stop()
                return nil
            }
            let flags = event.modifierFlags.intersection([.control, .option, .shift, .command])
            let isFunctionKey = Shortcut.isFunctionKey(code)
            guard !flags.intersection([.control, .option, .command]).isEmpty || isFunctionKey else {
                message = "Include ⌃, ⌥ or ⌘ (or use an F-key)."
                return nil
            }
            apply(Shortcut(keyCode: UInt32(code), flags: flags))
            stop()
            return nil
        }
    }

    private func apply(_ shortcut: Shortcut) {
        message = hotkey.change(to: shortcut) ? nil : "\(shortcut.displayName) is taken by another app."
    }

    private func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        isRecording = false
        hotkey.resume() // no-op if apply() already registered the new shortcut
    }
}
