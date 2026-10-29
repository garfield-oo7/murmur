import CoreMedia
import Foundation
import Testing
@testable import MurmurCore

/// A small vocabulary in the same format as Resources/Vocabulary.txt.
private let vocabulary = Vocabulary(text: """
    ## Test
    Tailscale
    vLLM
    LangGraph
    LangChain
    Claude
    Claude Code
    Claude Opus 4.5
    Claude Sonnet
    GPT-4o mini
    DeepSeek-V4-Pro
    Qwen3.5-Coder
    pgvector
    Hugging Face
    Linear
    /compact
    CLAUDE.md
    AGENTS.md

    ## Corrections
    kubectl | !cube control
    Claude Sonnet | clots on it
    Murmur | !mural
    CLAUDE.md | claw.md
    AGENTS.md | agents.d
    Postgres | post gress
    """)

@Suite struct CanonicalizationTests {
    @Test(arguments: [
        ("I connected over tail scale and served it with VLLM.", "I connected over Tailscale and served it with vLLM."),
        ("The agent runs on Langgraph with lang chain.", "The agent runs on LangGraph with LangChain."),
        ("Use claude opus 4.5 or GPT 4o mini.", "Use Claude Opus 4.5 or GPT-4o mini."),
        ("Deploy deep seek v4 pro from hugging face.", "Deploy DeepSeek-V4-Pro from Hugging Face."),
        ("Store embeddings in PG vector.", "Store embeddings in pgvector."),
        ("Run cube control get pods.", "Run kubectl get pods."),
        ("Save it in post gress.", "Save it in Postgres."),
    ])
    func fixesSpelling(heard: String, expected: String) {
        #expect(vocabulary.canonicalize(heard) == expected)
    }

    @Test(arguments: [
        "I want to go home and draw a linear plot.",
        "Make it compact and clear.",
        "The blood clots on it were dark.",
        "My soul felt light, so I wrote a letter.",
        "Read the input/output and/or the docs.",
    ])
    func leavesProseAlone(sentence: String) {
        #expect(vocabulary.canonicalize(sentence) == sentence)
    }

    @Test func realWordMishearingsNeedATechnicalSentence() {
        #expect(vocabulary.canonicalize("Open ~/.claude and ask the clots on it.")
            == "Open ~/.claude and ask the Claude Sonnet.")
        #expect(vocabulary.canonicalize("The clots on it were dark.") == "The clots on it were dark.")
    }

    @Test func bangForcesACorrectionEverywhere() {
        #expect(vocabulary.canonicalize("I'm testing mural right now.") == "I'm testing Murmur right now.")
    }

    @Test func fileNames() {
        #expect(vocabulary.canonicalize("Edit the claw.MD and agents.D files")
            == "Edit the CLAUDE.md and AGENTS.md files")
    }
}

@Suite struct SpokenSyntaxTests {
    @Test(arguments: [
        ("Open Tilda/.Claude/settings.Jason", "Open ~/.claude/settings.json"),
        ("check Hilda/project/murmur.", "check ~/project/murmur."),
        ("Run/model and switch it", "Run /model and switch it"),
        ("Use/compact then/clear,", "Use /compact then /clear,"),
        ("Set /Model to Opus.", "Set /model to Opus."),
        ("Read input/output and/or docs.", "Read input/output and/or docs."),
        ("See ~/Library/Application.", "See ~/Library/Application."),
    ])
    func formats(heard: String, expected: String) {
        #expect(SpokenSyntax.apply(heard) == expected)
    }
}

@Suite struct DictionaryTests {
    @Test(arguments: ["clots", "murals", "deployed", "running", "compact", "/compact"])
    func knowsInflectedWords(word: String) {
        #expect(Vocabulary.isDictionaryWord(word))
    }

    @Test(arguments: ["Tailscale", "vLLM", "kubectl"])
    func rejectsJargon(word: String) {
        #expect(!Vocabulary.isDictionaryWord(word))
    }
}

@Suite struct BundledVocabularyTests {
    /// The shipped list parses and has no term that would rewrite plain English.
    @Test func bundledFileLoads() throws {
        let url = URL(filePath: #filePath).deletingLastPathComponent()
            .appending(path: "../../Resources/Vocabulary.txt").standardized
        let bundled = Vocabulary(text: try String(contentsOf: url, encoding: .utf8))
        #expect(bundled.terms.count > 100)
        for prose in [
            "We deployed the model to the server, then reviewed the plan with the team.",
            "What I am trying to do is put it in a box, as I said, so let me do it.",
            "I sent it to my mama as a minor favor, a lost cause.",
        ] {
            #expect(bundled.canonicalize(prose) == prose)
        }
        #expect(bundled.canonicalize("Make soul 6.1 review it.") == "Make Sol 6.1 review it.")
        #expect(bundled.canonicalize("Add it to the touch desk app in T3.") == "Add it to the TouchDeck app in T3.")
        #expect(bundled.canonicalize("Run the quiz on the staff box over Tailscale.") == "Run the quiz on the dev box over Tailscale.")
        #expect(bundled.canonicalize("Compare Claude Opus and clot on it.") == "Compare Claude Opus and Claude Sonnet.")
        #expect(bundled.canonicalize("Which SONEET versions exist?") == "Which Sonnet versions exist?")
        #expect(bundled.canonicalize("So it goes, a sonnet a day.") == "So it goes, a sonnet a day.")
    }
}

@Suite struct HistoryFileTests {
    private func makeFile() -> HistoryFile {
        HistoryFile(url: FileManager.default.temporaryDirectory
            .appending(path: "murmur-tests-\(UUID().uuidString)/History.jsonl"))
    }

    @Test func appendsAndLoadsInOrder() throws {
        let file = makeFile()
        defer { try? FileManager.default.removeItem(at: file.url.deletingLastPathComponent()) }
        #expect(file.load().isEmpty)
        let first = HistoryEntry(date: Date(timeIntervalSince1970: 1_000), app: "Notes", heard: "tail scale",
                                 text: "Tailscale", outcome: .inserted, heldSeconds: 1.5, latencyMs: 120)
        let second = HistoryEntry(date: Date(timeIntervalSince1970: 2_000), heard: "hi\nthere", text: "hi\nthere",
                                  outcome: .notInserted, error: "blocked")
        try file.append(first)
        try file.append(second)
        #expect(file.load() == [first, second])
        let mode = try FileManager.default.attributesOfItem(atPath: file.url.path)[.posixPermissions] as? Int
        #expect(mode == 0o600)
    }

    @Test func prunesOldEntriesAndSkipsDamagedLines() throws {
        let file = makeFile()
        defer { try? FileManager.default.removeItem(at: file.url.deletingLastPathComponent()) }
        let old = HistoryEntry(date: Date(timeIntervalSince1970: 1_000), heard: "a", text: "a", outcome: .inserted)
        let new = HistoryEntry(date: Date(timeIntervalSince1970: 5_000), heard: "b", text: "b", outcome: .failed)
        try file.append(old)
        let handle = try FileHandle(forWritingTo: file.url)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("not json\n".utf8))
        try handle.close()
        try file.append(new)
        #expect(file.load() == [old, new])
        #expect(try file.prune(olderThan: Date(timeIntervalSince1970: 3_000)) == [new])
        #expect(file.load() == [new])
        try file.clear()
        #expect(file.load().isEmpty)
    }
}

@Suite struct LiveTranscriptTests {
    private func segment(_ start: Double, _ end: Double, _ text: String, final: Bool) -> LiveTranscript.Segment {
        LiveTranscript.Segment(range: CMTimeRange(start: CMTime(seconds: start, preferredTimescale: 1000),
                                                  end: CMTime(seconds: end, preferredTimescale: 1000)),
                               text: text, isFinal: final)
    }

    @Test func guessesReplaceEachOtherUntilSettled() {
        var t = LiveTranscript()
        t.add(segment(0, 1, "I", final: false))
        t.add(segment(0, 2, "I connected over tail", final: false))
        #expect(t.settled == "" && t.unsettled == "I connected over tail")
        t.add(segment(0, 3, "I connected over Tailscale.", final: true))
        #expect(t.settled == "I connected over Tailscale." && t.unsettled == "")
        t.add(segment(3, 4, " Then", final: false))
        #expect(t.text == "I connected over Tailscale. Then")
    }

    @Test func ignoresLateGuessesForSettledAudio() {
        var t = LiveTranscript()
        t.add(segment(0, 3, "Hello there.", final: true))
        t.add(segment(0, 2, "Hello th", final: false))
        #expect(t.text == "Hello there.")
    }

    @Test func keepsAnUnsettledTailAtTheEnd() {
        var t = LiveTranscript()
        t.add(segment(0, 2, "First part.", final: true))
        t.add(segment(2, 3, " and the end", final: false))
        #expect(t.text == "First part. and the end")
    }

    @Test func promotesAGuessThatWasSettledWithoutBeingMarked() {
        var t = LiveTranscript()
        t.add(segment(0, 2, "One two", final: false))
        t.add(segment(2, 3, " three", final: false))
        #expect(t.text == "One two three")
        // The real settled segment for 0–2 replaces the promoted guess.
        t.add(segment(0, 2, "One, two", final: true))
        #expect(t.text == "One, two three")
    }
}
