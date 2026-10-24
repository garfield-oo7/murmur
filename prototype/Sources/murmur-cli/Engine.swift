import CoreMedia
import Foundation
import Speech

/// One transcription result, flattened so SpeechTranscriber and DictationTranscriber look the same.
struct Piece: Sendable {
    let start: CMTime
    let isFinal: Bool
    let text: String
}

/// Picks SpeechTranscriber, falling back to DictationTranscriber when it is unavailable
/// or doesn't support the locale.
func resolveEngine(_ requested: EngineKind, locale: Locale) async -> (EngineKind, Locale) {
    if requested == .speech, SpeechTranscriber.isAvailable,
       let l = await SpeechTranscriber.supportedLocale(equivalentTo: locale) {
        return (.speech, l)
    }
    if requested == .speech {
        log("SpeechTranscriber unavailable for \(locale.identifier(.bcp47)), falling back to DictationTranscriber")
    }
    let l = await DictationTranscriber.supportedLocale(equivalentTo: locale) ?? locale
    return (.dictation, l)
}

func makeModule(_ kind: EngineKind, locale: Locale, fast: Bool) -> any SpeechModule {
    switch kind {
    case .speech:
        var reporting: Set<SpeechTranscriber.ReportingOption> = [.volatileResults]
        if fast { reporting.insert(.fastResults) }
        return SpeechTranscriber(locale: locale, transcriptionOptions: [],
                                 reportingOptions: reporting, attributeOptions: [.audioTimeRange])
    case .dictation:
        return DictationTranscriber(locale: locale, contentHints: [],
                                    transcriptionOptions: [.punctuation],
                                    reportingOptions: [.volatileResults],
                                    attributeOptions: [.audioTimeRange])
    }
}

/// Ensures the model for `module` is installed and reserved for this process.
/// `assetInstallationRequest` returns nil when nothing needs doing.
func ensureAssets(for module: any SpeechModule) async throws {
    let before = await AssetInventory.status(forModules: [module])
    log("asset status: \(before)")
    guard let request = try await AssetInventory.assetInstallationRequest(supporting: [module]) else { return }
    let start = ContinuousClock.now
    let progress = request.progress
    let ticker = Task {
        while !Task.isCancelled {
            log(String(format: "  installing model… %.0f%%", progress.fractionCompleted * 100))
            try? await Task.sleep(for: .seconds(1))
        }
    }
    defer { ticker.cancel() }
    try await request.downloadAndInstall()
    let after = await AssetInventory.status(forModules: [module])
    log("asset status: \(after) (install request took \(ms(ContinuousClock.now - start)))")
}

/// Streams results from either transcriber type as `Piece`s.
func pieces(of module: any SpeechModule) -> AsyncThrowingStream<Piece, any Error> {
    AsyncThrowingStream { continuation in
        let task = Task {
            do {
                if let t = module as? SpeechTranscriber {
                    for try await r in t.results {
                        continuation.yield(Piece(start: r.range.start, isFinal: r.isFinal, text: String(r.text.characters)))
                    }
                } else if let t = module as? DictationTranscriber {
                    for try await r in t.results {
                        continuation.yield(Piece(start: r.range.start, isFinal: r.isFinal, text: String(r.text.characters)))
                    }
                }
                continuation.finish()
            } catch {
                continuation.finish(throwing: error)
            }
        }
        continuation.onTermination = { _ in task.cancel() }
    }
}
