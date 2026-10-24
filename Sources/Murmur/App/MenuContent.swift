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
            Text("Last: \(text.count > 60 ? text.prefix(60) + "…" : text)")
            Button("Copy Last Dictation") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(text, forType: .string)
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
