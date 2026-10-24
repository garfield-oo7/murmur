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
        #expect(bundled.terms.count > 2_000)
        let prose = "We deployed the model to the server, then reviewed the plan with the team."
        #expect(bundled.canonicalize(prose) == prose)
    }
}
