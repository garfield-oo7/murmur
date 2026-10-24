import AVFoundation
import Foundation
import MurmurCore
import ServiceManagement
import Speech

/// Developer and maintenance commands, run instead of the app:
///
///     Murmur.app/Contents/MacOS/Murmur --transcribe recording.wav
///     Murmur.app/Contents/MacOS/Murmur --unregister-login-item   (used by uninstall.sh)
enum CommandLineTool {
    /// Runs a command if one was given; returns false to start the app normally.
    static func runIfRequested() -> Bool {
        let args = Array(CommandLine.arguments.dropFirst())
        switch args.first {
        case "--transcribe" where args.count >= 2:
            run { try await transcribe(URL(filePath: args[1])) }
        case "--unregister-login-item":
            run { try await SMAppService.mainApp.unregister() }
        case "--help", "-h":
            print("""
                usage: Murmur [--transcribe FILE | --unregister-login-item]
                  --transcribe FILE          print what Murmur would type for an audio file
                  --unregister-login-item    remove Murmur from login items
                Without arguments, starts the menu bar app.
                """)
            return true
        default:
            return false
        }
        return true
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

    /// Same recognizer, vocabulary and formatting as a dictation. Prints the raw
    /// recognition to stderr and the final text to stdout.
    private static func transcribe(_ url: URL) async throws {
        let vocabulary = Vocabulary.load()
        let module = TranscriptionEngine.makeModule(.dictation)
        let analyzer = SpeechAnalyzer(modules: [module], options: TranscriptionEngine.options)
        let context = AnalysisContext()
        context.contextualStrings[.general] = vocabulary.terms
        try await analyzer.setContext(context)
        let collector = Task {
            var parts: [(CMTime, String)] = []
            for try await result in TranscriptionEngine.results(of: module) {
                parts.append((result.range.start, result.text))
            }
            return parts.sorted { $0.0 < $1.0 }.map(\.1).joined()
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        try await analyzer.start(inputAudioFile: AVAudioFile(forReading: url), finishAfterFile: true)
        let raw = try await collector.value
        FileHandle.standardError.write(Data("heard: \(raw)\n".utf8))
        print(vocabulary.canonicalize(raw))
    }
}
