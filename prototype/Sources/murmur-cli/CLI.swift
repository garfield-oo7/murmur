@preconcurrency import AVFoundation
import Foundation
import Speech

@main
struct CLI {
    static func main() async {
        setvbuf(stdout, nil, _IOLBF, 0)
        do {
            let options = try Options.parse(Array(CommandLine.arguments.dropFirst()))
            try await run(options)
        } catch let error as UsageError {
            log("error: \(error)\n\n\(Options.usage)")
            exit(2)
        } catch {
            log("error: \(error)")
            exit(1)
        }
    }

    static func run(_ o: Options) async throws {
        let (engine, locale) = await resolveEngine(o.engine, locale: o.locale)
        log("engine: \(engine == .speech ? "SpeechTranscriber" : "DictationTranscriber") \(locale.identifier(.bcp47))"
            + (o.fast ? " (fastResults)" : "") + ", source: \(o.source.rawValue)")
        log("speech recognition auth (before): \(describe(SFSpeechRecognizer.authorizationStatus()))")

        if o.source != .file { try await ensureMicAccess() }

        var reports: [Report] = []
        for i in 1...o.runs {
            if o.runs > 1 { log("\n— run \(i)/\(o.runs) —") }
            let report = try await session(o, engine: engine, locale: locale)
            reports.append(report)
            print(report.text.isEmpty ? "(no speech recognized)" : report.text)
            report.printTimings()
        }

        log("\nspeech recognition auth (after): \(describe(SFSpeechRecognizer.authorizationStatus()))")
        if reports.count > 1 {
            let latencies = reports.map(\.releaseToFinal)
            log("release→final per run: " + latencies.map(ms).joined(separator: ", "))
        }
    }

    /// One hold-to-talk cycle: prepare, record until "release", finalize, collect text.
    static func session(_ o: Options, engine: EngineKind, locale: Locale) async throws -> Report {
        var r = Report()
        let module = makeModule(engine, locale: locale, fast: o.fast)

        var t = ContinuousClock.now
        try await ensureAssets(for: module)
        r.assets = ContinuousClock.now - t

        let analyzer = SpeechAnalyzer(modules: [module],
                                      options: .init(priority: .userInitiated, modelRetention: .processLifetime))
        let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [module])
        if let format { log("analyzer format: \(Int(format.sampleRate)) Hz, \(format.channelCount) ch, \(format.commonFormat.rawValue)") }
        t = .now
        try await analyzer.prepareToAnalyze(in: format)
        r.prepare = ContinuousClock.now - t

        let source: AudioSource = switch o.source {
        case .capture: CaptureSource(module: module)
        case .engine: EngineSource(module: module)
        case .file: FileSource(module: module, url: URL(fileURLWithPath: o.filePath!), realtime: o.realtime)
        }

        // Consume results before starting the analyzer so nothing early is missed.
        let pressed = ContinuousClock.now
        let collector = Task { () throws -> (String, ContinuousClock.Instant?) in
            var finals: [Piece] = []
            var firstVolatile: ContinuousClock.Instant?
            for try await p in pieces(of: module) {
                if p.isFinal {
                    finals.append(p)
                } else {
                    if firstVolatile == nil { firstVolatile = .now }
                    liveLine(finals.map(\.text).joined() + p.text)
                }
            }
            clearLiveLine()
            let text = finals.sorted { $0.start < $1.start }.map(\.text).joined()
            return (text.trimmingCharacters(in: .whitespacesAndNewlines), firstVolatile)
        }

        t = .now
        try await source.start()
        try await analyzer.start(inputSequence: source.pipe.stream)
        r.startCapture = ContinuousClock.now - t

        if source.endsByItself {
            log("feeding \(o.filePath!)…")
            try await source.stop()
        } else {
            log(o.seconds.map { "🎙  recording for \($0)s…" } ?? "🎙  recording… press Enter to stop")
            await waitForRelease(seconds: o.seconds)
            try await source.stop()
        }

        // "Key released": everything from here on is latency the user waits through.
        let released = ContinuousClock.now
        try await analyzer.finalizeAndFinishThroughEndOfInput()
        r.finalizeCall = ContinuousClock.now - released
        let (text, firstVolatile) = try await collector.value
        r.releaseToFinal = ContinuousClock.now - released

        r.text = text
        r.audioSeconds = source.pipe.audioSeconds
        r.buffers = source.pipe.buffers
        r.firstBuffer = source.pipe.firstBufferAt.map { $0 - pressed }
        r.firstVolatile = firstVolatile.map { $0 - pressed }
        return r
    }

    static func ensureMicAccess() async throws {
        let status = AVCaptureDevice.authorizationStatus(for: .audio)
        log("microphone auth: \(describe(status))")
        switch status {
        case .authorized: return
        case .notDetermined:
            guard await AVCaptureDevice.requestAccess(for: .audio) else {
                throw CLIError("microphone access denied. Run this from Terminal.app (or iTerm/Ghostty) so macOS can "
                               + "show the prompt, or enable your terminal in System Settings → Privacy & Security → Microphone")
            }
            log("microphone auth: \(describe(AVCaptureDevice.authorizationStatus(for: .audio)))")
        default:
            throw CLIError("microphone access is \(describe(status)); enable it for your terminal app in "
                           + "System Settings → Privacy & Security → Microphone")
        }
    }

    static func waitForRelease(seconds: Double?) async {
        if let seconds {
            try? await Task.sleep(for: .seconds(seconds))
        } else {
            await Task.detached { _ = readLine() }.value
        }
    }
}

struct Report {
    var text = ""
    var assets: Duration = .zero
    var prepare: Duration = .zero
    var startCapture: Duration = .zero
    var firstBuffer: Duration?
    var firstVolatile: Duration?
    var finalizeCall: Duration = .zero
    var releaseToFinal: Duration = .zero
    var audioSeconds = 0.0
    var buffers = 0

    func printTimings() {
        log("""
        ── timings ──
          assets check/reserve   \(ms(assets))
          prepareToAnalyze       \(ms(prepare))
          start capture          \(ms(startCapture))
          press → first audio    \(firstBuffer.map(ms) ?? "–")
          press → first volatile \(firstVolatile.map(ms) ?? "–")
          audio captured         \(String(format: "%.2f s", audioSeconds)) in \(buffers) buffers
          finalize call          \(ms(finalizeCall))
          release → final text   \(ms(releaseToFinal))   ← hold-to-talk latency
        """)
    }
}

// MARK: - Output helpers

/// Diagnostics go to stderr so stdout carries only the transcript.
func log(_ s: String) {
    FileHandle.standardError.write(Data((s + "\n").utf8))
}

private let isTTY = isatty(STDERR_FILENO) != 0

func liveLine(_ s: String) {
    guard isTTY else { return }
    let width = 100
    let tail = s.count > width ? "…" + s.suffix(width - 1) : s
    FileHandle.standardError.write(Data("\r\u{1B}[2K  \u{1B}[2m\(tail)\u{1B}[0m".utf8))
}

func clearLiveLine() {
    guard isTTY else { return }
    FileHandle.standardError.write(Data("\r\u{1B}[2K".utf8))
}

func ms(_ d: Duration) -> String {
    let c = d.components
    return String(format: "%.0f ms", Double(c.seconds) * 1000 + Double(c.attoseconds) / 1e15)
}

func describe(_ s: SFSpeechRecognizerAuthorizationStatus) -> String {
    switch s {
    case .notDetermined: "notDetermined"
    case .denied: "denied"
    case .restricted: "restricted"
    case .authorized: "authorized"
    @unknown default: "unknown(\(s.rawValue))"
    }
}

func describe(_ s: AVAuthorizationStatus) -> String {
    switch s {
    case .notDetermined: "notDetermined"
    case .denied: "denied"
    case .restricted: "restricted"
    case .authorized: "authorized"
    @unknown default: "unknown(\(s.rawValue))"
    }
}
