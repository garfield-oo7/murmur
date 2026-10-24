import CoreMedia
import Foundation
import MurmurCore
import os
import Speech

enum DictationError: LocalizedError {
    case noMicrophone
    case microphoneNotAllowed
    case modelNotInstalled
    case accessibilityNotAllowed

    var errorDescription: String? {
        switch self {
        case .noMicrophone: "No microphone found."
        case .microphoneNotAllowed: "Murmur isn't allowed to use the microphone."
        case .modelNotInstalled: "The speech model isn't downloaded yet."
        case .accessibilityNotAllowed: "Murmur needs Accessibility access to type into other apps. The text is in Murmur's menu."
        }
    }
}

/// Recognizer setup shared by every session.
enum TranscriptionEngine {
    /// DictationTranscriber honors custom vocabulary (contextual strings);
    /// SpeechTranscriber ignores it but punctuates long-form speech a little better.
    enum Kind: String, CaseIterable, Identifiable {
        case dictation, speech
        var id: String { rawValue }
        var title: String {
            switch self {
            case .dictation: "Dictation (uses your vocabulary)"
            case .speech: "Transcription (ignores vocabulary)"
            }
        }

        static let key = "recognitionEngine"
        static var current: Kind {
            UserDefaults.standard.string(forKey: key).flatMap(Kind.init) ?? .dictation
        }
    }

    static let locale = Locale(identifier: "en-US")
    static let options = SpeechAnalyzer.Options(priority: .userInitiated, modelRetention: .processLifetime)
    private static let log = Logger(subsystem: "io.github.garfield-oo7.Murmur", category: "engine")

    /// Finals only; volatile results aren't shown.
    static func makeModule(_ kind: Kind = .current) -> any SpeechModule {
        switch kind {
        case .dictation:
            DictationTranscriber(locale: locale, contentHints: [], transcriptionOptions: [.punctuation],
                                 reportingOptions: [], attributeOptions: [])
        case .speech:
            SpeechTranscriber(locale: locale, transcriptionOptions: [], reportingOptions: [], attributeOptions: [])
        }
    }

    /// Final results of either transcriber, as (start time, text).
    static func finals(of module: any SpeechModule) -> AsyncThrowingStream<(CMTime, String), any Error> {
        stream(of: module, finalOnly: true) { ($0.start, $1) }
    }

    /// Every result, final or not. With `finalize(through:)` on a reused analyzer the
    /// results come out with `isFinal == false`.
    static func results(of module: any SpeechModule) -> AsyncThrowingStream<(range: CMTimeRange, text: String), any Error> {
        stream(of: module, finalOnly: false) { (range: $0, text: $1) }
    }

    private static func stream<T: Sendable>(of module: any SpeechModule, finalOnly: Bool,
                                            _ transform: @escaping @Sendable (CMTimeRange, String) -> T)
        -> AsyncThrowingStream<T, any Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    if let module = module as? DictationTranscriber {
                        for try await r in module.results where !finalOnly || r.isFinal {
                            continuation.yield(transform(r.range, String(r.text.characters)))
                        }
                    } else if let module = module as? SpeechTranscriber {
                        for try await r in module.results where !finalOnly || r.isFinal {
                            continuation.yield(transform(r.range, String(r.text.characters)))
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
}

nonisolated func ms(_ d: Duration) -> String {
    let c = d.components
    return String(format: "%.0f ms", Double(c.seconds) * 1000 + Double(c.attoseconds) / 1e15)
}
