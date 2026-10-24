import AppKit
import SwiftUI

@main
struct MurmurApp: App {
    @NSApplicationDelegateAdaptor private var appDelegate: AppDelegate

    var body: some Scene {
        MenuBarExtra {
            MenuContent(model: appDelegate.model)
        } label: {
            Image(systemName: appDelegate.model.dictation.state == .idle ? "mic" : "mic.fill")
                .accessibilityLabel("Murmur")
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    let model = AppModel()

    func applicationDidFinishLaunching(_ notification: Notification) {
        if !model.permissions.allGranted { model.showSetup() }
        Task { await TranscriptionEngine.prewarm() }
        runSelfTestIfRequested()
    }

    /// `open Murmur.app --args --test-dictation 4 [--test-audio file.wav]` records for 4 s
    /// as if the hotkey were held, so dictation can be checked without pressing keys.
    private func runSelfTestIfRequested() {
        let args = CommandLine.arguments
        guard let i = args.firstIndex(of: "--test-dictation"), i + 1 < args.count,
              let seconds = Double(args[i + 1]) else { return }
        let dictation = model.dictation
        dictation.logsTranscripts = true
        if let j = args.firstIndex(of: "--test-audio"), j + 1 < args.count {
            dictation.testAudio = URL(fileURLWithPath: args[j + 1])
        }
        Task {
            try? await Task.sleep(for: .seconds(1)) // let prewarm finish
            dictation.keyDown()
            try? await Task.sleep(for: .seconds(seconds))
            dictation.keyUp()
        }
    }
}

/// Everything the app owns.
@Observable
final class AppModel {
    let permissions = Permissions()
    let speechModel = SpeechModel()
    let hotkey = HotkeyManager()
    let dictation = DictationController()

    // An AppKit-owned window rather than a SwiftUI `Window` scene: a menu bar app
    // launched in the background doesn't reliably get scene windows on screen.
    @ObservationIgnored private var setupWindow: NSWindow?
    @ObservationIgnored private var settingsWindow: NSWindow?

    init() {
        hotkey.onPress = { [dictation] in dictation.keyDown() }
        hotkey.onRelease = { [dictation] in dictation.keyUp() }
        hotkey.onCancel = { [dictation] in dictation.cancel() }
        dictation.onError = { [weak self] error in
            switch error {
            case .microphoneNotAllowed, .modelNotInstalled, .accessibilityNotAllowed: self?.showSetup()
            case .noMicrophone: break
            }
        }
        hotkey.register()
    }

    func showSetup() {
        if setupWindow == nil {
            let window = Self.makeWindow(SetupView(model: self), title: "Set Up Murmur")
            window.styleMask.insert(.fullSizeContentView)
            window.titlebarAppearsTransparent = true
            window.titleVisibility = .hidden
            setupWindow = window
        }
        NSApp.activate()
        setupWindow?.makeKeyAndOrderFront(nil)
    }

    func showSettings() {
        if settingsWindow == nil {
            settingsWindow = Self.makeWindow(SettingsView(model: self), title: "Murmur Settings")
        }
        NSApp.activate()
        settingsWindow?.makeKeyAndOrderFront(nil)
    }

    private static func makeWindow(_ view: some View, title: String) -> NSWindow {
        let window = NSWindow(contentViewController: NSHostingController(rootView: view))
        window.title = title
        window.styleMask = [.titled, .closable]
        window.isReleasedWhenClosed = false
        window.center()
        return window
    }

    func closeSetup() {
        setupWindow?.close()
    }
}
