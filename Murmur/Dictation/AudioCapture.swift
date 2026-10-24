@preconcurrency import AVFoundation
import Foundation
import os
import Speech
import Synchronization

// Ported from prototype/Sources/murmur-cli/Inputs.swift. Everything here is explicitly
// nonisolated: the target defaults to MainActor isolation, but audio arrives on capture
// and realtime threads.

/// The stream handed to `SpeechAnalyzer.start(inputSequence:)`. We own it (rather than
/// passing a provider's sequence straight through) so that releasing the hotkey ends
/// the input deterministically.
nonisolated final class InputPipe: Sendable {
    struct Stats {
        var buffers = 0
        var seconds = 0.0
        var firstAt: ContinuousClock.Instant?
        /// The upstream sequence ended by itself (vs. us cutting it off).
        var upstreamEnded = false
    }

    let stream: AsyncStream<AnalyzerInput>
    private let continuation: AsyncStream<AnalyzerInput>.Continuation
    private let state = Mutex(Stats())

    init() {
        (stream, continuation) = AsyncStream.makeStream(of: AnalyzerInput.self, bufferingPolicy: .unbounded)
    }

    func yield(_ input: AnalyzerInput) {
        state.withLock {
            $0.buffers += 1
            $0.seconds += input.bufferDuration.seconds
            if $0.firstAt == nil { $0.firstAt = .now }
        }
        continuation.yield(input)
    }

    func markUpstreamEnded() { state.withLock { $0.upstreamEnded = true } }
    func finish() { continuation.finish() }
    var stats: Stats { state.withLock { $0 } }
}

nonisolated protocol AudioSource: AnyObject, Sendable {
    var pipe: InputPipe { get }
    var name: String { get }
    /// Starts producing audio into `pipe`.
    func start() async throws
    /// Stops capture and ends `pipe.stream`.
    func stop() async
}

/// Prototype-style escape hatch: these AVFoundation/Speech objects aren't Sendable, but
/// each is only used from one task at a time.
nonisolated struct Unchecked<T>: @unchecked Sendable { let value: T }

private nonisolated let log = Logger(subsystem: "io.github.garfield-oo7.Murmur", category: "audio")

// MARK: - CaptureInputSequenceProvider (macOS 27, primary)

nonisolated final class CaptureSource: AudioSource, @unchecked Sendable {
    let pipe = InputPipe()
    let name = "capture"
    private let module: any SpeechModule
    // Written in start(), read in stop(); the controller never overlaps the two.
    private var provider: CaptureInputSequenceProvider?
    private var forward: Task<Void, Never>?

    /// How long stop() waits for in-flight buffers. Live buffers are ~11 ms (M1).
    static let drainWindow: Duration = .milliseconds(50)

    init(module: any SpeechModule) { self.module = module }

    func start() async throws {
        guard let device = Microphone.resolve() else {
            throw DictationError.noMicrophone
        }
        log.notice("mic: \(device.localizedName, privacy: .public)")
        let provider = try await CaptureInputSequenceProvider.providerWithSession(from: device, compatibleWith: [module])
        self.provider = provider
        let box = Unchecked(value: provider)
        let pipe = self.pipe
        forward = Task.detached(priority: .userInitiated) {
            do {
                for try await input in box.value.analyzerInputs { pipe.yield(input) }
                pipe.markUpstreamEnded()
            } catch {
                log.error("capture input error: \(error, privacy: .public)")
            }
        }
        // startRunning() blocks until the session is up; keep it off the caller's executor.
        await Task.detached(priority: .userInitiated) {
            let session = box.value.captureSession
            if !session.isRunning { session.startRunning() }
        }.value
    }

    func stop() async {
        if let provider {
            let box = Unchecked(value: provider)
            await Task.detached(priority: .userInitiated) { box.value.captureSession.stopRunning() }.value
        }
        // Wait briefly for in-flight buffers, ending early if the provider's sequence
        // finishes by itself. Never await `forward` directly: it might never end.
        let deadline = ContinuousClock.now + Self.drainWindow
        while ContinuousClock.now < deadline, !pipe.stats.upstreamEnded {
            try? await Task.sleep(for: .milliseconds(5))
        }
        pipe.finish()
        forward?.cancel()
    }
}

// MARK: - AVAudioEngine + AnalyzerInputConverter (fallback)

// Records from the system default input, not Microphone.resolve(): choosing a device
// on AVAudioEngine needs Core Audio plumbing that isn't worth it for a fallback path.

nonisolated final class EngineSource: AudioSource, @unchecked Sendable {
    let pipe = InputPipe()
    let name = "engine"
    private let module: any SpeechModule
    private let engine = AVAudioEngine()
    private var converter: AnalyzerInputConverter?

    init(module: any SpeechModule) { self.module = module }

    func start() async throws {
        let converter = try await AnalyzerInputConverter.converter(compatibleWith: [module])
        self.converter = converter
        installTap(converter: Unchecked(value: converter))
        engine.prepare()
        try engine.start()
    }

    /// Synchronous so the tap closure isn't actor-isolated: it runs on a realtime audio
    /// thread. The converter is only used from that thread until the tap is removed.
    private func installTap(converter: Unchecked<AnalyzerInputConverter>) {
        let node = engine.inputNode
        let format = node.outputFormat(forBus: 0)
        let pipe = self.pipe
        // Deprecated in macOS 27 in favour of installTapOnBus:…:error:block:, but that one is
        // NS_REFINED_FOR_SWIFT and the SDK ships no Swift overlay for it yet.
        node.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in
            do {
                for input in try converter.value.convert(buffer, at: nil) { pipe.yield(input) }
            } catch {
                log.error("convert error: \(error, privacy: .public)")
            }
        }
    }

    func stop() async {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        if let converter, let tail = try? converter.flush() {
            for input in tail { pipe.yield(input) }
        }
        pipe.finish()
    }
}

// MARK: - Audio file (self-test only)

/// Feeds a file in real time, for `--test-dictation N --test-audio PATH` runs where no
/// one is speaking (e.g. AirPods as the mic). Not used in normal operation.
nonisolated final class FileSource: AudioSource, @unchecked Sendable {
    let pipe = InputPipe()
    let name = "file"
    private let module: any SpeechModule
    private let url: URL
    private var forward: Task<Void, Never>?

    init(module: any SpeechModule, url: URL) {
        self.module = module
        self.url = url
    }

    func start() async throws {
        let provider = try await AssetInputSequenceProvider.provider(from: AVURLAsset(url: url), compatibleWith: [module])
        let box = Unchecked(value: provider)
        let pipe = self.pipe
        forward = Task.detached(priority: .userInitiated) {
            // A buffer is handed over once the audio it covers has "happened", like a mic.
            let t0 = ContinuousClock.now
            var fed = 0.0
            do {
                for try await input in box.value.analyzerInputs {
                    fed += input.bufferDuration.seconds
                    try await Task.sleep(until: t0 + .seconds(fed), clock: .continuous)
                    pipe.yield(input)
                }
                pipe.markUpstreamEnded()
            } catch {
                log.error("file input error: \(error, privacy: .public)")
            }
        }
    }

    func stop() async {
        pipe.finish()
        forward?.cancel()
    }
}
