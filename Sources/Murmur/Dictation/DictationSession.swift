import CoreMedia
import Foundation
import MurmurCore
import os
import Speech

/// One hold-to-talk recording: start on key-down, finish (or cancel) on key-up.
final class DictationSession {
    struct Timings {
        var prepare: Duration = .zero
        var captureStart: Duration = .zero
        var pressToFirstAudio: Duration?
        var releaseToText: Duration = .zero
        var audioSeconds = 0.0
        var buffers = 0
        var source = ""
        var drainEndedEarly = false
        var sharedAnalyzer = false
        var firstTimestamp: Double?
    }

    private(set) var timings = Timings()
    private let pressedAt: ContinuousClock.Instant
    private let module = TranscriptionEngine.makeModule()
    private let vocabulary = Vocabulary.load()
    private let recognizer: PersistentRecognizer?
    private var run: PersistentRecognizer.Run?
    private var analyzer: SpeechAnalyzer?
    private var source: (any AudioSource)?
    private var collector: Task<String, any Error>?

    /// Self-test only: read this file instead of the microphone.
    private let testAudio: URL?
    private let meter: LevelMeter?

    init(pressedAt: ContinuousClock.Instant, recognizer: PersistentRecognizer? = nil,
         meter: LevelMeter? = nil, testAudio: URL? = nil) {
        self.pressedAt = pressedAt
        self.recognizer = recognizer
        self.meter = meter
        self.testAudio = testAudio
    }

    /// Fresh per-dictation analyzers only get a short list: every term costs ~3.5 ms
    /// of setup. The user's own terms come first.
    private static let freshAnalyzerTermLimit = 100

    /// Called on the main actor when the microphone delivers its first audio.
    var onMicLive: (() -> Void)?

    func start() async throws {
        guard await AssetInventory.status(forModules: [module]) == .installed else {
            throw DictationError.modelNotInstalled
        }

        // Mic first: it's the slow part, and buffers queue in the pipe until the
        // analyzer is ready.
        let t = ContinuousClock.now
        let source = try await startCapture()
        self.source = source
        timings.captureStart = ContinuousClock.now - t
        timings.source = source.name

        // The shared analyzer has the whole vocabulary compiled in and costs nothing to
        // start. It needs timestamps that keep increasing, i.e. the capture provider.
        if module is DictationTranscriber, source is CaptureSource,
           let recognizer, let run = recognizer.begin(source.pipe.stream) {
            self.run = run
            timings.sharedAnalyzer = true
            return
        }
        try await startFreshAnalyzer(input: source.pipe.stream)
    }

    private func startFreshAnalyzer(input: some AsyncSequence<AnalyzerInput, Never> & Sendable) async throws {
        let analyzer = SpeechAnalyzer(modules: [module], options: TranscriptionEngine.options)
        self.analyzer = analyzer
        if module is DictationTranscriber, !vocabulary.terms.isEmpty {
            let priority = vocabulary.userTerms + vocabulary.terms.filter { !vocabulary.userTerms.contains($0) }
            let context = AnalysisContext()
            context.contextualStrings[.general] = Array(priority.prefix(Self.freshAnalyzerTermLimit))
            try await analyzer.setContext(context)
        }
        let t = ContinuousClock.now
        try await analyzer.prepareToAnalyze(in: await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [module]))
        timings.prepare = ContinuousClock.now - t

        // Collect results before starting so nothing early is missed.
        let module = self.module
        collector = Task {
            var finals: [(CMTime, String)] = []
            for try await final in TranscriptionEngine.finals(of: module) { finals.append(final) }
            return finals.sorted { $0.0 < $1.0 }.map(\.1).joined()
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        try await analyzer.start(inputSequence: input)
    }

    /// What the recognizer heard, before vocabulary fixes. Set by `finish()`.
    private(set) var heard = ""

    /// Key released: stop the mic and wait for the final text.
    func finish() async throws -> String {
        let released = ContinuousClock.now
        await source?.stop()
        var raw: String
        if let run, let recognizer {
            do {
                raw = try await recognizer.finish(run)
            } catch {
                // Don't lose the dictation: replay the recorded audio into a fresh analyzer.
                Logger(subsystem: "io.github.garfield-oo7.Murmur", category: "recognizer")
                    .error("shared analyzer failed (\(error, privacy: .public)); replaying")
                recognizer.invalidate()
                let inputs = source?.pipe.stats.inputs ?? []
                try await startFreshAnalyzer(input: AsyncStream { c in inputs.forEach { c.yield($0) }; c.finish() })
                try await analyzer?.finalizeAndFinishThroughEndOfInput()
                raw = try await collector?.value ?? ""
            }
        } else {
            try await analyzer?.finalizeAndFinishThroughEndOfInput()
            raw = try await collector?.value ?? ""
        }
        heard = raw
        let text = vocabulary.canonicalize(raw)
        timings.releaseToText = ContinuousClock.now - released
        recordStats()
        return text
    }

    func cancel() async {
        await source?.stop()
        if let run, let recognizer { await recognizer.cancel(run) }
        await analyzer?.cancelAndFinishNow()
        collector?.cancel()
        recordStats()
    }

    private func startCapture() async throws -> any AudioSource {
        if let testAudio {
            let file = FileSource(module: module, url: testAudio)
            try await begin(file)
            return file
        }
        let capture = CaptureSource(module: module, meter: meter)
        do {
            try await begin(capture)
            return capture
        } catch {
            // e.g. SFSpeechError.cannotConfigureAudioSystem; fall back to AVAudioEngine.
            Logger(subsystem: "io.github.garfield-oo7.Murmur", category: "audio")
                .error("capture provider failed (\(error, privacy: .public)); using AVAudioEngine")
            await capture.stop()
            let engine = EngineSource(module: module, meter: meter)
            try await begin(engine)
            return engine
        }
    }

    private func begin(_ source: some AudioSource) async throws {
        if let onMicLive {
            let live = Unchecked(value: onMicLive)
            source.pipe.onFirstBuffer { Task { @MainActor in live.value() } }
        }
        try await source.start()
    }

    private func recordStats() {
        guard let stats = source?.pipe.stats else { return }
        timings.audioSeconds = stats.seconds
        timings.buffers = stats.buffers
        timings.pressToFirstAudio = stats.firstAt.map { $0 - pressedAt }
        timings.drainEndedEarly = stats.upstreamEnded
        timings.firstTimestamp = stats.firstStartTime?.seconds
    }
}
