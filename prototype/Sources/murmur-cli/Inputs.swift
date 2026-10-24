@preconcurrency import AVFoundation
import Foundation
import Speech
import Synchronization

/// The stream handed to `SpeechAnalyzer.start(inputSequence:)`, plus bookkeeping.
/// We own the stream (rather than passing a provider's sequence straight through)
/// so that "key released" can end the input deterministically.
final class InputPipe: Sendable {
    let stream: AsyncStream<AnalyzerInput>
    private let continuation: AsyncStream<AnalyzerInput>.Continuation
    private let state = Mutex<(buffers: Int, seconds: Double, firstAt: ContinuousClock.Instant?)>((0, 0, nil))

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

    func finish() { continuation.finish() }

    var buffers: Int { state.withLock { $0.buffers } }
    var audioSeconds: Double { state.withLock { $0.seconds } }
    var firstBufferAt: ContinuousClock.Instant? { state.withLock { $0.firstAt } }
}

protocol AudioSource: AnyObject {
    var pipe: InputPipe { get }
    /// Starts producing audio into `pipe`.
    func start() async throws
    /// Stops capture and ends `pipe.stream`. For files: waits for the natural end.
    func stop() async throws
    /// True for sources that end by themselves (files).
    var endsByItself: Bool { get }
}

// MARK: - CaptureInputSequenceProvider (macOS 27)

/// Prototype-only escape hatch: the provider isn't Sendable, but we only touch it from
/// one task at a time.
private struct Unchecked<T>: @unchecked Sendable { let value: T }

final class CaptureSource: AudioSource {
    let pipe = InputPipe()
    let endsByItself = false
    private let module: any SpeechModule
    private var provider: CaptureInputSequenceProvider?
    private var forward: Task<Void, Never>?

    init(module: any SpeechModule) { self.module = module }

    func start() async throws {
        guard let device = AVCaptureDevice.default(for: .audio) else { throw CLIError("no audio capture device") }
        log("mic: \(device.localizedName)")
        let provider = try await CaptureInputSequenceProvider.providerWithSession(from: device, compatibleWith: [module])
        self.provider = provider
        let box = Unchecked(value: provider)
        let pipe = self.pipe
        forward = Task.detached(priority: .userInitiated) {
            do {
                for try await input in box.value.analyzerInputs { pipe.yield(input) }
            } catch {
                log("capture input error: \(error)")
            }
        }
        // startRunning() blocks until the session is up; keep it off the caller's executor.
        await Task.detached {
            let session = box.value.captureSession
            if !session.isRunning { session.startRunning() }
        }.value
    }

    func stop() async throws {
        if let provider {
            let box = Unchecked(value: provider)
            await Task.detached { box.value.captureSession.stopRunning() }.value
        }
        // Give in-flight buffers a moment to arrive, then end the stream regardless of
        // whether the provider's sequence terminates on stopRunning(). Don't await the
        // forward task: if the sequence never ends, that await would never return.
        try? await Task.sleep(for: .milliseconds(150))
        pipe.finish()
        forward?.cancel()
    }
}

// MARK: - AVAudioEngine + AnalyzerInputConverter

final class EngineSource: AudioSource {
    let pipe = InputPipe()
    let endsByItself = false
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

    /// Nonisolated and synchronous so the tap closure isn't inferred to be actor-isolated
    /// (the tap runs on a realtime audio thread). The converter is only used from that
    /// thread until the tap is removed.
    private func installTap(converter: Unchecked<AnalyzerInputConverter>) {
        let node = engine.inputNode
        let format = node.outputFormat(forBus: 0)
        log("mic format: \(Int(format.sampleRate)) Hz, \(format.channelCount) ch")
        let pipe = self.pipe
        // Deprecated in macOS 27 in favour of installTapOnBus:…:error:block:, but that one is
        // NS_REFINED_FOR_SWIFT and the SDK ships no Swift overlay for it yet.
        node.installTap(onBus: 0, bufferSize: 2048, format: format) { buffer, _ in
            do {
                for input in try converter.value.convert(buffer, at: nil) { pipe.yield(input) }
            } catch {
                log("convert error: \(error)")
            }
        }
    }

    func stop() async throws {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        if let converter {
            for input in try converter.flush() { pipe.yield(input) }
        }
        pipe.finish()
    }
}

// MARK: - Audio file (for testing without a mic)

final class FileSource: AudioSource {
    let pipe = InputPipe()
    let endsByItself = true
    private let module: any SpeechModule
    private let url: URL
    private let realtime: Bool
    private var forward: Task<Void, Never>?

    init(module: any SpeechModule, url: URL, realtime: Bool) {
        self.module = module
        self.url = url
        self.realtime = realtime
    }

    func start() async throws {
        let provider = try await AssetInputSequenceProvider.provider(from: AVURLAsset(url: url), compatibleWith: [module])
        let box = Unchecked(value: provider)
        let pipe = self.pipe
        let realtime = self.realtime
        forward = Task.detached(priority: .userInitiated) {
            // Pace buffers against a wall clock the way a mic delivers them: a buffer is
            // handed over only once the audio it covers has "happened". "Release" is then
            // the moment the last buffer goes in.
            let t0 = ContinuousClock.now
            var fed = 0.0
            do {
                for try await input in box.value.analyzerInputs {
                    fed += input.bufferDuration.seconds
                    if realtime {
                        try await Task.sleep(until: t0 + .seconds(fed), clock: .continuous)
                    }
                    pipe.yield(input)
                }
            } catch {
                log("file input error: \(error)")
            }
            pipe.finish()
        }
    }

    func stop() async throws {
        await forward?.value
    }
}
