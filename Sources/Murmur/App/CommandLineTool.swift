import AVFoundation
import Foundation
import MurmurCore
import ServiceManagement
import Speech

/// Developer and maintenance commands, run instead of the app:
///
///     Murmur.app/Contents/MacOS/Murmur --transcribe recording.wav
///     echo "board request" | Murmur.app/Contents/MacOS/Murmur --canonicalize
///     Murmur.app/Contents/MacOS/Murmur --unregister-login-item   (used by uninstall.sh)
enum CommandLineTool {
    /// Runs a command if one was given; returns false to start the app normally.
    static func runIfRequested() -> Bool {
        let args = Array(CommandLine.arguments.dropFirst())
        switch args.first {
        case "--transcribe":
            let options = parse(args.dropFirst())
            guard !options.files.isEmpty else { usageError("--transcribe needs at least one audio file") }
            run { try await transcribe(options) }
        case "--canonicalize":
            let options = parse(args.dropFirst())
            guard options.files.isEmpty, !options.json else { usageError("--canonicalize reads stdin and takes no files") }
            canonicalize(Vocabulary.load(userFile: options.userVocabulary))
        case "--status":
            printStatus()
        case "--unregister-login-item":
            run { try await SMAppService.mainApp.unregister() }
        case "--help", "-h":
            print("""
                usage: Murmur [--transcribe [--user-vocabulary FILE] [--json] AUDIO... |
                               --canonicalize [--user-vocabulary FILE] | --status | --unregister-login-item]
                  --transcribe AUDIO...      print what Murmur would type for each audio file (the raw
                                             recognition goes to stderr as "heard: …")
                    --json                   instead, print one JSON object per file:
                                             {"file", "heard", "text", "engine"}
                  --canonicalize             apply the vocabulary to each line of stdin, one line out per line in
                  --user-vocabulary FILE     use FILE instead of your vocabulary file (the bundled list still applies)
                  --status                   ask the running app for its status (mic, state) as JSON
                  --unregister-login-item    remove Murmur from login items
                Without arguments, starts the menu bar app.
                """)
            return true
        default:
            return false
        }
        return true
    }

    private struct Options {
        var userVocabulary = Vocabulary.userFileURL
        var json = false
        var files: [String] = []
    }

    private static func parse(_ args: ArraySlice<String>) -> Options {
        var options = Options()
        var rest = args[...]
        while let arg = rest.popFirst() {
            switch arg {
            case "--json":
                options.json = true
            case "--user-vocabulary":
                guard let path = rest.popFirst() else { usageError("--user-vocabulary needs a file") }
                options.userVocabulary = URL(filePath: path)
            case let flag where flag.hasPrefix("--"):
                usageError("unknown option \(flag)")
            default:
                options.files.append(arg)
            }
        }
        return options
    }

    private static func usageError(_ message: String) -> Never {
        FileHandle.standardError.write(Data("error: \(message) (see --help)\n".utf8))
        exit(2)
    }

    /// Exactly one output line per input line, in order.
    private static func canonicalize(_ vocabulary: Vocabulary) {
        while let line = readLine() {
            print(vocabulary.canonicalize(line))
        }
    }

    /// Runs `body` on the main actor and exits when it finishes. Never returns.
    private static func run(_ body: @escaping () async throws -> Void) {
        Task {
            do {
                try await body()
                exit(0)
            } catch {
                FileHandle.standardError.write(Data("error: \(error.localizedDescription)\n".utf8))
                exit(1)
            }
        }
        dispatchMain()
    }

    /// Asks the running app the way another app would, and prints its answer.
    private static func printStatus() {
        var reply: [AnyHashable: Any]?
        let center = DistributedNotificationCenter.default()
        let token = center.addObserver(forName: StatusBroadcaster.statusName, object: nil, queue: nil) {
            reply = $0.userInfo
        }
        center.postNotificationName(StatusBroadcaster.requestName, object: nil, userInfo: nil, deliverImmediately: true)
        let deadline = Date.now.addingTimeInterval(2)
        while reply == nil, Date.now < deadline { RunLoop.current.run(until: .now.addingTimeInterval(0.05)) }
        center.removeObserver(token)
        guard let reply, let data = try? JSONSerialization.data(withJSONObject: reply, options: [.prettyPrinted, .sortedKeys]) else {
            FileHandle.standardError.write(Data("Murmur isn't running.\n".utf8))
            exit(1)
        }
        print(String(decoding: data, as: UTF8.self))
    }

    /// Same recognizer, vocabulary and formatting as a dictation. Prints the raw
    /// recognition to stderr and the final text to stdout, or both as JSON lines.
    /// Each file gets a fresh analyzer, so its timestamps start at zero.
    private static func transcribe(_ options: Options) async throws {
        let vocabulary = Vocabulary.load(userFile: options.userVocabulary)
        let kind = TranscriptionEngine.Kind.current
        for file in options.files {
            let module = TranscriptionEngine.makeModule(kind)
            let analyzer = SpeechAnalyzer(modules: [module], options: TranscriptionEngine.options)
            if module is DictationTranscriber {
                let context = AnalysisContext()
                context.contextualStrings[.general] = vocabulary.terms
                try await analyzer.setContext(context)
            }
            let collector = Task {
                var transcript = LiveTranscript()
                for try await segment in TranscriptionEngine.results(of: module) { transcript.add(segment) }
                return transcript.text
            }
            try await analyzer.start(inputAudioFile: AVAudioFile(forReading: URL(filePath: file)), finishAfterFile: true)
            let raw = try await collector.value
            let text = vocabulary.canonicalize(raw)
            if options.json {
                let object = ["file": file, "heard": raw, "text": text, "engine": kind.rawValue]
                let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])
                print(String(decoding: data, as: UTF8.self))
            } else {
                FileHandle.standardError.write(Data("heard: \(raw)\n".utf8))
                print(text)
            }
        }
    }
}
