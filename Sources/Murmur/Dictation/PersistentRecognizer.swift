import CoreMedia
import Foundation
import MurmurCore
import os
import Speech

/// One long-lived DictationTranscriber analyzer with the vocabulary compiled in.
///
/// Contextual strings cost ~3.5 ms per term in `prepareToAnalyze` (1,300 terms ≈ 4.5 s),
/// paid by every new analyzer. So we prepare one analyzer in the background and feed it
/// each dictation in turn with `analyzeSequence` + `finalize(through:)`. That works as
/// long as each recording's timestamps come after the previous one's, which holds for
/// the capture provider (host-clock timestamps) but not for the engine fallback or
/// file tests; those keep using a fresh analyzer per dictation.
///
/// Results arrive with `isFinal == false` in this mode; finalize returning is the
/// signal that everything up to `end` has been delivered.
final class PersistentRecognizer {
    enum State: Equatable {
        case idle
        case compiling
        case ready
        case failed
    }

    private(set) var state = State.idle
    private var analyzer: SpeechAnalyzer?
    private var results: [(range: CMTimeRange, text: String)] = []
    private var collector: Task<Void, Never>?
    /// Identifies the vocabulary the current analyzer was compiled with.
    private var compiledFingerprint: String?
    private static let log = Logger(subsystem: "io.github.garfield-oo7.Murmur", category: "recognizer")

    /// Compiles `vocabulary` into a new analyzer unless the current one already has it.
    /// The previous analyzer keeps serving until the new one is ready.
    func prepare(vocabulary: Vocabulary) async {
        let fingerprint = vocabulary.fingerprint
        guard fingerprint != compiledFingerprint, state != .compiling else { return }
        if analyzer == nil { state = .compiling }

        let module = TranscriptionEngine.makeModule(.dictation)
        let analyzer = SpeechAnalyzer(modules: [module], options: TranscriptionEngine.options)
        let start = ContinuousClock.now
        do {
            let context = AnalysisContext()
            context.contextualStrings[.general] = vocabulary.terms
            try await analyzer.setContext(context)
            try await analyzer.prepareToAnalyze(in: await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [module]))
        } catch {
            Self.log.error("compile failed: \(error, privacy: .public)")
            if self.analyzer == nil { state = .failed }
            return
        }
        Self.log.notice("compiled \(vocabulary.terms.count) terms in \(ms(ContinuousClock.now - start), privacy: .public)")

        // Swap in the new analyzer.
        if let old = self.analyzer {
            Task { await old.cancelAndFinishNow() }
        }
        collector?.cancel()
        results = []
        self.analyzer = analyzer
        compiledFingerprint = fingerprint
        collector = Task { [weak self] in
            do {
                for try await result in TranscriptionEngine.results(of: module) {
                    self?.results.append(result)
                }
            } catch {
                Self.log.error("results ended: \(error, privacy: .public)")
            }
        }
        state = .ready
    }

    /// One dictation's worth of audio going through the shared analyzer.
    final class Run {
        fileprivate let analysis: Task<CMTime?, any Error>
        fileprivate let firstResult: Int

        fileprivate init(analysis: Task<CMTime?, any Error>, firstResult: Int) {
            self.analysis = analysis
            self.firstResult = firstResult
        }
    }

    /// Starts analyzing `stream`; nil if the analyzer isn't ready.
    func begin(_ stream: AsyncStream<AnalyzerInput>) -> Run? {
        guard state == .ready, let analyzer else { return nil }
        let analysis = Task { try await analyzer.analyzeSequence(stream) }
        return Run(analysis: analysis, firstResult: results.count)
    }

    /// Waits for the run's audio to be analyzed and returns its text.
    func finish(_ run: Run) async throws -> String {
        guard let analyzer else { return "" }
        if let end = try await run.analysis.value {
            try await analyzer.finalize(through: end)
        }
        // Results normally land before finalize returns; allow a little slack.
        try? await Task.sleep(for: .milliseconds(30))
        return results.dropFirst(run.firstResult)
            .sorted { $0.range.start < $1.range.start }
            .map(\.text).joined()
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Discards the run's audio so it can't leak into the next dictation.
    func cancel(_ run: Run) async {
        guard let analyzer else { return }
        if let end = try? await run.analysis.value {
            await analyzer.cancelAnalysis(before: end)
        }
        if results.count > run.firstResult { results.removeSubrange(run.firstResult...) }
    }

    /// After an error the analyzer may be unusable; compile a fresh one next time.
    func invalidate() {
        compiledFingerprint = nil
        state = analyzer == nil ? .idle : state
    }
}
