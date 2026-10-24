import SwiftUI

struct MenuContent: View {
    let model: AppModel

    var body: some View {
        let hotkey = model.hotkey
        let permissions = model.permissions

        Text(hotkeyStatus(hotkey))
        if let press = hotkey.lastPress {
            Text("Last press \(press.formatted(date: .omitted, time: .standard))" + holdSuffix(hotkey))
        }

        Divider()

        Text("Microphone: \(permissions.microphoneGranted ? "allowed" : "not allowed")")
        Text("Accessibility: \(permissions.accessibility ? "allowed" : "not allowed")")
        Button("Set Up Murmur…") { model.showSetup() }

        Divider()

        Button("Quit Murmur") { NSApp.terminate(nil) }
            .keyboardShortcut("q")
            .onAppear { permissions.refresh() }
    }

    private func hotkeyStatus(_ hotkey: HotkeyManager) -> String {
        switch hotkey.registrationStatus {
        case nil: "Hotkey \(hotkey.displayName): not registered"
        case noErr?: "Hotkey \(hotkey.displayName): pressed \(hotkey.pressCount)×" + (hotkey.isHeld ? " (held)" : "")
        case let status?: "Hotkey \(hotkey.displayName): registration failed (\(status))"
        }
    }

    private func holdSuffix(_ hotkey: HotkeyManager) -> String {
        guard !hotkey.isHeld, let held = hotkey.lastHoldDuration else { return "" }
        return String(format: ", released after %.2f s", held)
    }
}
