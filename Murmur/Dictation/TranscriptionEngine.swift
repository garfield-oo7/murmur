import CoreMedia
import Foundation
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

/// SpeechTranscriber setup shared by every session. Ported from prototype/Engine.swift.
enum TranscriptionEngine {
    static let locale = Locale(identifier: "en-US")
    static let options = SpeechAnalyzer.Options(priority: .userInitiated, modelRetention: .processLifetime)
    private static let log = Logger(subsystem: "io.github.garfield-oo7.Murmur", category: "engine")

    static func makeModule() -> SpeechTranscriber {
        // Volatile results aren't shown yet (M5 may use them for the pill); finals only.
        SpeechTranscriber(locale: locale, transcriptionOptions: [], reportingOptions: [], attributeOptions: [])
    }

    /// Loads the model once so the first dictation doesn't pay for it. With
    /// `.processLifetime` the model stays resident after this analyzer is gone.
    static func prewarm() async {
        let module = makeModule()
        guard await AssetInventory.status(forModules: [module]) == .installed else {
            log.notice("prewarm skipped: model not installed")
            return
        }
        let analyzer = SpeechAnalyzer(modules: [module], options: options)
        let start = ContinuousClock.now
        do {
            try await analyzer.prepareToAnalyze(in: await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [module]))
            log.notice("prewarmed in \(ms(ContinuousClock.now - start), privacy: .public)")
        } catch {
            log.error("prewarm failed: \(error, privacy: .public)")
        }
        await analyzer.cancelAndFinishNow()
    }
}

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
    }

    private(set) var timings = Timings()
    private let pressedAt: ContinuousClock.Instant
    private let module = TranscriptionEngine.makeModule()
    private var analyzer: SpeechAnalyzer?
    private var source: (any AudioSource)?
    private var collector: Task<String, any Error>?

    /// Self-test only: read this file instead of the microphone.
    private let testAudio: URL?
    private let meter: LevelMeter?

    init(pressedAt: ContinuousClock.Instant, meter: LevelMeter? = nil, testAudio: URL? = nil) {
        self.pressedAt = pressedAt
        self.meter = meter
        self.testAudio = testAudio
    }

    /// Called on the main actor when the microphone delivers its first audio.
    var onMicLive: (() -> Void)?

    func start() async throws {
        guard await AssetInventory.status(forModules: [module]) == .installed else {
            throw DictationError.modelNotInstalled
        }

        // Mic first: it's the slow part, and buffers queue in the pipe until the
        // analyzer is ready.
        var t = ContinuousClock.now
        let source = try await startCapture()
        self.source = source
        timings.captureStart = ContinuousClock.now - t
        timings.source = source.name

        let analyzer = SpeechAnalyzer(modules: [module], options: TranscriptionEngine.options)
        self.analyzer = analyzer
        t = .now
        try await analyzer.prepareToAnalyze(in: await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [module]))
        timings.prepare = ContinuousClock.now - t

        // Collect results before starting so nothing early is missed.
        let module = self.module
        collector = Task {
            var finals: [(CMTime, String)] = []
            for try await result in module.results where result.isFinal {
                finals.append((result.range.start, String(result.text.characters)))
            }
            return finals.sorted { $0.0 < $1.0 }.map(\.1).joined()
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        try await analyzer.start(inputSequence: source.pipe.stream)
    }

    /// Key released: stop the mic and wait for the final text.
    func finish() async throws -> String {
        let released = ContinuousClock.now
        await source?.stop()
        try await analyzer?.finalizeAndFinishThroughEndOfInput()
        let text = try await collector?.value ?? ""
        timings.releaseToText = ContinuousClock.now - released
        recordStats()
        return text
    }

    func cancel() async {
        await source?.stop()
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
    }
}

nonisolated func ms(_ d: Duration) -> String {
    let c = d.components
    return String(format: "%.0f ms", Double(c.seconds) * 1000 + Double(c.attoseconds) / 1e15)
}
