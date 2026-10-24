import Foundation
import Speech
import os

/// Readiness of the on-device SpeechTranscriber model for the current locale.
/// Assets are reserved per app, so even when another app (or the M1 CLI) has the model
/// on disk, Murmur still has to request it once.
@Observable
final class SpeechModel {
    enum State: Equatable {
        case checking
        case unsupported
        case needsDownload
        case downloading(Double)
        case ready
        case failed(String)
    }

    private(set) var state = State.checking
    let locale = Locale(identifier: "en-US")
    private static let log = Logger(subsystem: "io.github.garfield-oo7.Murmur", category: "speech-model")

    private func makeModule() -> SpeechTranscriber {
        SpeechTranscriber(locale: locale, preset: .transcription)
    }

    func refresh() async {
        guard SpeechTranscriber.isAvailable,
              await SpeechTranscriber.supportedLocale(equivalentTo: locale) != nil else {
            state = .unsupported
            return
        }
        if case .downloading = state { return }
        switch await AssetInventory.status(forModules: [makeModule()]) {
        case .installed: state = .ready
        case .unsupported: state = .unsupported
        case .supported, .downloading: state = .needsDownload
        @unknown default: state = .needsDownload
        }
    }

    func install() async {
        if case .downloading = state { return }
        state = .downloading(0)
        do {
            if let request = try await AssetInventory.assetInstallationRequest(supporting: [makeModule()]) {
                let progress = request.progress
                let ticker = Task {
                    while !Task.isCancelled {
                        state = .downloading(progress.fractionCompleted)
                        try? await Task.sleep(for: .milliseconds(250))
                    }
                }
                defer { ticker.cancel() }
                try await request.downloadAndInstall()
            }
            state = .checking
            await refresh()
        } catch {
            Self.log.error("model install failed: \(error, privacy: .public)")
            state = .failed(error.localizedDescription)
        }
    }
}
