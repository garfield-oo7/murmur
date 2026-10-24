import SwiftUI

struct MenuContent: View {
    let model: AppModel

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
