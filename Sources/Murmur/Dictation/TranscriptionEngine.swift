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

    /// Reports guesses as you speak (volatile results) as well as settled text. The
    /// guesses cost the speech service about 4% of one core while you talk.
    static func makeModule(_ kind: Kind = .current) -> any SpeechModule {
        switch kind {
        case .dictation:
            DictationTranscriber(locale: locale, contentHints: [], transcriptionOptions: [.punctuation],
                                 reportingOptions: [.volatileResults], attributeOptions: [])
        case .speech:
            SpeechTranscriber(locale: locale, transcriptionOptions: [], reportingOptions: [.volatileResults],
                              attributeOptions: [])
        }
    }

    /// Every result of either transcriber. A result counts as settled when the
    /// recognizer says so, or when it ends before the point up to which results are
    /// final (on a reused analyzer, `finalize(through:)` results can arrive with
    /// `isFinal == false`).
    static func results(of module: any SpeechModule) -> AsyncThrowingStream<LiveTranscript.Segment, any Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                func segment(_ range: CMTimeRange, _ text: AttributedString, _ isFinal: Bool,
                             _ finalizedThrough: CMTime) -> LiveTranscript.Segment {
                    LiveTranscript.Segment(range: range, text: String(text.characters),
                                           isFinal: isFinal || range.end <= finalizedThrough)
                }
                do {
                    if let module = module as? DictationTranscriber {
                        for try await r in module.results {
                            continuation.yield(segment(r.range, r.text, r.isFinal, r.resultsFinalizationTime))
                        }
                    } else if let module = module as? SpeechTranscriber {
                        for try await r in module.results {
                            continuation.yield(segment(r.range, r.text, r.isFinal, r.resultsFinalizationTime))
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
