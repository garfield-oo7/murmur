import MurmurCore
import AVFoundation
import Carbon.HIToolbox
import CoreAudio
import SwiftUI

struct SettingsView: View {
    let model: AppModel
    @AppStorage("playSounds") private var playSounds = true
    @AppStorage(FlowPill.enabledKey) private var showPill = true
    @AppStorage(FlowPill.Position.key) private var pillPosition = FlowPill.Position.bottom.rawValue
    @AppStorage(LevelMeter.sensitivityKey) private var sensitivity = 0.5
    @AppStorage(Microphone.defaultsKey) private var microphone = Microphone.builtIn
    @AppStorage(TranscriptionEngine.Kind.key) private var engine = TranscriptionEngine.Kind.dictation.rawValue
    @AppStorage(TextInserter.methodKey) private var insertionMethod = TextInserter.Method.paste.rawValue
    @AppStorage(DictationHistory.enabledKey) private var keepHistory = true
    @AppStorage(DictationHistory.retentionKey) private var historyDays = 30
    @State private var confirmingClear = false

    var body: some View {
        Form {
            Toggle("Open Murmur at login", isOn: Binding(
                get: { model.launchAtLogin.isEnabled },
                set: { model.launchAtLogin.set($0) }
            ))
            if model.launchAtLogin.needsApproval {
                LabeledContent("Needs your OK in System Settings") {
                    Button("Open Login Items…") { model.launchAtLogin.openSystemSettings() }
                }
                .font(.callout)
            }
            if let error = model.launchAtLogin.lastError {
                Text(error).font(.caption).foregroundStyle(.red)
            }
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
            Picker("Recognition", selection: $engine) {
                ForEach(TranscriptionEngine.Kind.allCases) { Text($0.title).tag($0.rawValue) }
            }
            LabeledContent("Vocabulary") {
                Button("Edit My Vocabulary…") {
                    if let url = try? Vocabulary.ensureUserFile() { NSWorkspace.shared.open(url) }
                }
            }
            Picker("Insert text by", selection: $insertionMethod) {
                ForEach(TextInserter.Method.allCases) { Text($0.title).tag($0.rawValue) }
            }
            Toggle("Keep dictation history", isOn: $keepHistory)
            Picker("Keep history for", selection: $historyDays) {
                ForEach(DictationHistory.retentionChoices, id: \.self) {
                    Text(DictationHistory.title(forRetention: $0)).tag($0)
                }
            }
            .disabled(!keepHistory)
            .onChange(of: historyDays) { model.dictation.history.load() }
            LabeledContent("Stored only on this Mac") {
                HStack {
                    Button("Show in Finder") { model.dictation.history.showInFinder() }
                    Button("Clear History…") { confirmingClear = true }
                }
            }
            .font(.callout)
            .confirmationDialog("Delete your whole dictation history?", isPresented: $confirmingClear) {
                Button("Clear History", role: .destructive) { model.dictation.history.clear() }
            }
            Toggle("Play start and stop sounds", isOn: $playSounds)
            Toggle("Show waveform while dictating", isOn: $showPill)
            Picker("Waveform position", selection: $pillPosition) {
                ForEach(FlowPill.Position.allCases) { Text($0.title).tag($0.rawValue) }
            }
            .disabled(!showPill)
            LabeledContent("Waveform sensitivity") {
                Slider(value: $sensitivity, in: 0...1) {
                    EmptyView()
                } minimumValueLabel: {
                    Text("Low").font(.caption)
                } maximumValueLabel: {
                    Text("High").font(.caption)
                }
                .frame(width: 180)
            }
            .disabled(!showPill)
        }
        .formStyle(.grouped)
        .onAppear { model.launchAtLogin.refresh() }
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
