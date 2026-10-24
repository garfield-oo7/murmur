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
        if !CommandLine.arguments.contains("--test-dictation") { model.launchAtLogin.enableOnFirstLaunch() }
        Task { [model] in
            // Reserving an on-disk model is instant; a real download runs in the
            // background and shows progress in the setup window.
            await model.speechModel.refresh()
            if model.speechModel.state == .needsDownload { await model.speechModel.install() }
            await TranscriptionEngine.prewarm()
            // Compiling the full vocabulary takes a few seconds; dictations before it's
            // ready use a fresh analyzer with a short list.
            await model.dictation.recognizer.prepare(vocabulary: .load())
        }
        runSelfTestIfRequested()
    }

    /// `open Murmur.app --args --test-dictation 4 [--test-audio file.wav] [--test-no-insert]`
    /// records for 4 s as if the hotkey were held, so dictation can be checked without
    /// pressing keys.
    private func runSelfTestIfRequested() {
        let args = CommandLine.arguments
        guard let i = args.firstIndex(of: "--test-dictation"), i + 1 < args.count,
              let seconds = Double(args[i + 1]) else { return }
        let dictation = model.dictation
        dictation.logsTranscripts = true
        dictation.insertsText = !args.contains("--test-no-insert")
        if let j = args.firstIndex(of: "--test-audio"), j + 1 < args.count {
            dictation.testAudio = URL(fileURLWithPath: args[j + 1])
        }
        var repeats = 1
        if let k = args.firstIndex(of: "--test-repeat"), k + 1 < args.count { repeats = Int(args[k + 1]) ?? 1 }
        Task {
            try? await Task.sleep(for: .seconds(6)) // let launch prep (model, vocabulary) finish
            for i in 0..<repeats {
                if i > 0 { try? await Task.sleep(for: .seconds(20)) }
                dictation.keyDown()
                try? await Task.sleep(for: .seconds(seconds))
                dictation.keyUp()
            }
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
    let launchAtLogin = LaunchAtLogin()

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
