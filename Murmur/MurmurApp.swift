import AppKit
import SwiftUI

@main
struct MurmurApp: App {
    @NSApplicationDelegateAdaptor private var appDelegate: AppDelegate

    var body: some Scene {
        MenuBarExtra {
            MenuContent(model: appDelegate.model)
        } label: {
            Image(systemName: appDelegate.model.hotkey.isHeld ? "mic.fill" : "mic")
                .accessibilityLabel("Murmur")
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    let model = AppModel()

    func applicationDidFinishLaunching(_ notification: Notification) {
        if !model.permissions.allGranted { model.showSetup() }
    }
}

/// Everything the app owns. M3 adds the dictation controller here.
@Observable
final class AppModel {
    let permissions = Permissions()
    let speechModel = SpeechModel()
    let hotkey = HotkeyManager()

    // An AppKit-owned window rather than a SwiftUI `Window` scene: a menu bar app
    // launched in the background doesn't reliably get scene windows on screen.
    @ObservationIgnored private var setupWindow: NSWindow?

    init() {
        hotkey.register()
    }

    func showSetup() {
        if setupWindow == nil {
            let window = NSWindow(contentViewController: NSHostingController(rootView: SetupView(model: self)))
            window.title = "Set Up Murmur"
            window.styleMask = [.titled, .closable, .fullSizeContentView]
            window.titlebarAppearsTransparent = true
            window.titleVisibility = .hidden
            window.isReleasedWhenClosed = false
            window.center()
            setupWindow = window
        }
        NSApp.activate()
        setupWindow?.makeKeyAndOrderFront(nil)
    }

    func closeSetup() {
        setupWindow?.close()
    }
}
