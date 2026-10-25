import SwiftUI

struct MenuContent: View {
    let model: AppModel
    @AppStorage(Microphone.defaultsKey) private var microphone = Microphone.automatic

    var body: some View {
        let dictation = model.dictation
        let permissions = model.permissions

        Text(status)
        if let error = dictation.lastError {
            Text("⚠︎ \(error)")
        }
        if let text = dictation.lastTranscript {
            Divider()
            Text("Last: \(Self.menuTitle(text))")
            Button("Copy Last Dictation") { Self.copy(text) }
        }
        let recent = dictation.history.recent.filter { !$0.text.isEmpty }
        if !recent.isEmpty {
            Menu("Recent Dictations") {
                ForEach(recent) { entry in
                    Button(Self.menuTitle(entry.text)) { Self.copy(entry.text) }
                    if let app = entry.app {
                        Text("\(app), \(entry.date.formatted(.relative(presentation: .named)))")
                    }
                }
                Divider()
                Button("Show History in Finder") { dictation.history.showInFinder() }
            }
        }

        Divider()

        Picker("Microphone", selection: $microphone) {
            Text(Self.title("Automatic", for: Microphone.automatic)).tag(Microphone.automatic)
            Text("Built-in").tag(Microphone.builtIn)
            Text(Self.title("System Default", for: Microphone.systemDefault)).tag(Microphone.systemDefault)
            let others = Microphone.available.filter { $0.uniqueID != "BuiltInMicrophoneDevice" }
            if !others.isEmpty {
                Divider()
                ForEach(others, id: \.uniqueID) { Text($0.localizedName).tag($0.uniqueID) }
            }
        }

        Divider()

        if !permissions.allGranted {
            Text("Microphone: \(permissions.microphoneGranted ? "allowed" : "not allowed")")
            Text("Accessibility: \(permissions.accessibility ? "allowed" : "not allowed")")
        }
        Button("Set Up Murmur…") { model.showSetup() }
        Button("Settings…") { model.showSettings() }
            .keyboardShortcut(",")

        Divider()

        Button("Quit Murmur") { NSApp.terminate(nil) }
            .keyboardShortcut("q")
            .onAppear { permissions.refresh() }
    }

    private static func menuTitle(_ text: String) -> String {
        text.count > 60 ? text.prefix(60) + "…" : text
    }

    /// "Automatic (EarPods)": the mic a setting would use right now.
    private static func title(_ name: String, for choice: String) -> String {
        guard let mic = Microphone.resolve(choice) else { return name }
        return "\(name) (\(mic.localizedName))"
    }

    private static func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    private var status: String {
        let hotkey = model.hotkey
        guard hotkey.isRegistered else {
            return "Hotkey \(hotkey.displayName) unavailable. Choose another in Settings."
        }
        return switch model.dictation.state {
        case .idle: "Hold \(hotkey.displayName) to dictate"
        case .starting, .listening: "Listening…"
        case .finalizing: "Transcribing…"
        }
    }
}
