import AppKit
import SwiftUI

@main
enum Main {
    static func main() {
        // Command-line tools (--transcribe, --unregister-login-item) run and exit;
        // otherwise start the menu bar app.
        if CommandLineTool.runIfRequested() { return }
        MurmurApp.main()
    }
}

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
            // Compiling the full vocabulary takes a few seconds; dictations before it's
            // ready use a fresh analyzer with a short list.
            await model.dictation.recognizer.prepare(vocabulary: .load())
        }
        runSelfTestIfRequested()
    }
}
