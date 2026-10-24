import Foundation

enum SourceKind: String {
    /// macOS 27 `CaptureInputSequenceProvider` wired straight to the default mic.
    case capture
    /// `AVAudioEngine` input tap + `AnalyzerInputConverter`.
    case engine
    /// Audio file fed through `AssetInputSequenceProvider`, paced in real time.
    case file
}

enum EngineKind: String {
    case speech      // SpeechTranscriber
    case dictation   // DictationTranscriber
}

struct Options {
    var source: SourceKind = .capture
    var engine: EngineKind = .speech
    var locale = Locale(identifier: "en-US")
    var filePath: String?
    var seconds: Double?
    var runs = 1
    var fast = false
    var realtime = true
    var vocabPath: String?

    static let usage = """
    usage: murmur-cli [options]

      --source capture|engine|file   audio input (default: capture)
      --file PATH                    transcribe an audio file (implies --source file)
      --engine speech|dictation      SpeechTranscriber or DictationTranscriber (default: speech)
      --locale ID                    BCP-47 locale (default: en-US)
      --seconds N                    stop recording after N seconds instead of on Enter
      --runs N                       repeat the session N times (cold vs warm latency)
      --fast                         SpeechTranscriber .fastResults reporting
      --no-realtime                  feed files as fast as possible instead of in real time
      --vocab FILE                   bias recognition with a Murmur vocabulary file
      -h, --help                     show this help
    """

    static func parse(_ args: [String]) throws -> Options {
        var o = Options()
        var it = args.makeIterator()
        func value(_ flag: String) throws -> String {
            guard let v = it.next() else { throw UsageError("missing value for \(flag)") }
            return v
        }
        while let arg = it.next() {
            switch arg {
            case "--source":
                let v = try value(arg)
                guard let s = SourceKind(rawValue: v) else { throw UsageError("unknown source '\(v)'") }
                o.source = s
            case "--file":
                o.filePath = try value(arg)
                o.source = .file
            case "--engine":
                let v = try value(arg)
                guard let e = EngineKind(rawValue: v) else { throw UsageError("unknown engine '\(v)'") }
                o.engine = e
            case "--locale":
                o.locale = Locale(identifier: try value(arg))
            case "--seconds":
                guard let s = Double(try value(arg)), s > 0 else { throw UsageError("--seconds needs a positive number") }
                o.seconds = s
            case "--runs":
                guard let n = Int(try value(arg)), n > 0 else { throw UsageError("--runs needs a positive integer") }
                o.runs = n
            case "--fast":
                o.fast = true
            case "--no-realtime":
                o.realtime = false
            case "--vocab":
                o.vocabPath = try value(arg)
            case "-h", "--help":
                print(usage)
                exit(0)
            default:
                throw UsageError("unknown argument '\(arg)'")
            }
        }
        if o.source == .file && o.filePath == nil {
            throw UsageError("--source file needs --file PATH")
        }
        return o
    }
}

struct CLIError: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

/// A bad command line; reported together with the usage text.
struct UsageError: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}
