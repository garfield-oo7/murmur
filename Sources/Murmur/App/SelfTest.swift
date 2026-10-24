import Foundation

extension AppDelegate {
    /// `open Murmur.app --args --test-dictation 4 [--test-audio file.wav] [--test-no-insert]`
    /// records for 4 s as if the hotkey were held, so dictation can be checked without
    /// pressing keys.
    func runSelfTestIfRequested() {
        let args = CommandLine.arguments
        guard let i = args.firstIndex(of: "--test-dictation"), i + 1 < args.count,
              let seconds = Double(args[i + 1]) else { return }
        let dictation = model.dictation
        dictation.logsTranscripts = true
        dictation.insertsText = !args.contains("--test-no-insert")
        if let j = args.firstIndex(of: "--test-audio"), j + 1 < args.count {
            dictation.testAudio = URL(fileURLWithPath: args[j + 1])
        }
        var repeats = 1
        if let k = args.firstIndex(of: "--test-repeat"), k + 1 < args.count { repeats = Int(args[k + 1]) ?? 1 }
        Task {
            try? await Task.sleep(for: .seconds(6)) // let launch prep (model, vocabulary) finish
            for i in 0..<repeats {
                if i > 0 { try? await Task.sleep(for: .seconds(20)) }
                dictation.keyDown()
                try? await Task.sleep(for: .seconds(seconds))
                dictation.keyUp()
            }
        }
    }
}
