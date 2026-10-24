import AppKit
import os
import SwiftUI

@main
enum Main {
    static func main() {
        // Command-line tools (--transcribe, --unregister-login-item) run and exit;
        // otherwise start the menu bar app.
        if CommandLineTool.runIfRequested() { return }
        guard SingleInstance.claim() else { return }
        MurmurApp.main()
    }
}

/// Only one Murmur may run: two would both register ⌥D and fight over the mic.
enum SingleInstance {
    static var isTestRun: Bool { CommandLine.arguments.contains("--test-dictation") }

    /// False if another copy is already running (this one should exit). A test run
    /// takes over instead: it quits the running copy and reopens it when done.
    static func claim() -> Bool {
        let others = NSRunningApplication.runningApplications(withBundleIdentifier: Bundle.main.bundleIdentifier ?? "")
            .filter { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }
        guard !others.isEmpty else { return true }
        guard isTestRun else {
            Logger(subsystem: "io.github.garfield-oo7.Murmur", category: "app")
                .notice("already running (pid \(others[0].processIdentifier)); exiting")
            return false
        }
        others.forEach { $0.terminate() }
        let deadline = Date.now.addingTimeInterval(5)
        while others.contains(where: { !$0.isTerminated }), Date.now < deadline {
            RunLoop.current.run(until: .now.addingTimeInterval(0.1))
        }
        others.filter { !$0.isTerminated }.forEach { $0.forceTerminate() }
        return true
    }

    /// Ends a test run and starts the normal app again, once this process has gone.
    static func quitAndRelaunchNormally() {
        let relaunch = Process()
        relaunch.executableURL = URL(filePath: "/bin/sh")
        relaunch.arguments = ["-c", "sleep 1; /usr/bin/open \"$0\"", Bundle.main.bundleURL.path]
        try? relaunch.run()
        NSApp.terminate(nil)
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
