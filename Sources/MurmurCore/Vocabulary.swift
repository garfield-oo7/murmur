import Foundation
import os

/// Custom vocabulary from plain-text files (format: see the header of Vocabulary.txt).
///
/// - Bundled: `Vocabulary.txt` (AI/ML models, labs and tooling).
/// - User: `~/Library/Application Support/Murmur/Vocabulary.txt`, same format, merged on top.
///
/// Used two ways:
/// 1. As contextual strings for DictationTranscriber, which biases recognition towards
///    the terms. (M6 test: SpeechTranscriber ignores contextual strings entirely.)
/// 2. To canonicalize the transcript: a phrase matching a term once spaces, hyphens,
///    dots and case are ignored ("tail scale", "VLLM") is rewritten to the term
///    ("Tailscale", "vLLM"), plus explicit `Term | mishearing` rules.
public struct Vocabulary: Sendable {
    public private(set) var terms: [String] = []
    /// Terms from the user's own file, which get priority where the list must be short.
    public private(set) var userTerms: [String] = []
    /// Changes whenever the term list does; used to know when to recompile.
    public var fingerprint: String { "\(terms.count):\(terms.joined(separator: "\n").hashValue)" }
    /// Normalized spoken form → canonical term.
    private var canonical: [String: String] = [:]
    /// Lowercased mishearing → canonical term, from `Term | mishearing` lines.
    /// `always` is false for mishearings made only of real English words ("clots on it"),
    /// which are only fixed in technical sentences.
    private var corrections: [String: (term: String, always: Bool)] = [:]
    /// Single-word terms that aren't English words ("Claude", "Docker"): seeing one
    /// marks a sentence as technical.
    private var markers: Set<String> = []
    /// Longest span to try, in tokens (words and the separators between them).
    private var maxTokens = 1

    private static let log = Logger(subsystem: "io.github.garfield-oo7.Murmur", category: "vocabulary")

    public static let userFileURL = URL.applicationSupportDirectory
        .appending(path: "Murmur", directoryHint: .isDirectory)
        .appending(path: "Vocabulary.txt")

    /// Bundled list plus the user's file.
    public static func load() -> Vocabulary {
        var vocabulary = Vocabulary()
        if let bundled = Bundle.main.url(forResource: "Vocabulary", withExtension: "txt") {
            vocabulary.add(contentsOf: bundled)
        }
        let before = vocabulary.terms.count
        vocabulary.add(contentsOf: userFileURL)
        vocabulary.userTerms = Array(vocabulary.terms[before...])
        log.notice("loaded \(vocabulary.terms.count) terms, \(vocabulary.corrections.count) correction rules")
        return vocabulary
    }

    public init() {}

    public init(text: String) {
        add(text: text)
    }

    private mutating func add(contentsOf url: URL) {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return }
        add(text: text)
    }

    private mutating func add(text: String) {
        var seen = Set(terms)
        for rawLine in text.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix("#") else { continue }
            let parts = line.split(separator: "|").map { $0.trimmingCharacters(in: .whitespaces) }
            guard let term = parts.first, !term.isEmpty else { continue }

            if seen.insert(term).inserted { terms.append(term) }
            for var mishearing in parts.dropFirst() where !mishearing.isEmpty {
                var always = mishearing.hasPrefix("!")
                if always { mishearing.removeFirst() }
                always = always || !mishearing.split(separator: " ").allSatisfy { Self.isDictionaryWord(String($0)) }
                corrections[mishearing.lowercased()] = (term, always)
                maxTokens = max(maxTokens, Self.tokenize(mishearing).count)
            }
            // Canonicalize by spelling only when that can't capitalize ordinary prose:
            // skip single words that are plain English ("Go", "Linear", "Modal").
            if !term.contains(" "), !Self.isDictionaryWord(term) { markers.insert(term) }
            if term.contains(" ") || !Self.isDictionaryWord(term) {
                canonical[Self.normalize(term)] = term
                // Spoken forms can have extra breaks: "tail scale" for "Tailscale".
                maxTokens = max(maxTokens, Self.tokenize(term).count + 4)
            }
        }
    }

    // MARK: Canonicalization

    /// Formats paths and slash commands, then rewrites recognized phrases to their
    /// vocabulary spelling (longest match wins). Real-word mishearings are applied only
    /// when the sentence turns out to be technical.
    public func canonicalize(_ text: String) -> String {
        let first = rewrite(SpokenSyntax.apply(text), technical: false)
        guard isTechnical(first) else { return first }
        return rewrite(first, technical: true)
    }

    /// A path or slash command, or a term like "Claude" or "Docker".
    private func isTechnical(_ text: String) -> Bool {
        if text.contains("~/") || text.range(of: #"(^|\s)/[a-z]"#, options: .regularExpression) != nil { return true }
        return Self.tokenize(text).contains { $0.isWord && markers.contains($0.text) }
    }

    private func rewrite(_ text: String, technical: Bool) -> String {
        guard !canonical.isEmpty || !corrections.isEmpty else { return text }
        let tokens = Self.tokenize(text)
        var output = ""
        var i = 0
        while i < tokens.count {
            var replaced = false
            if tokens[i].isWord {
                for length in stride(from: min(maxTokens, tokens.count - i), through: 1, by: -1) {
                    let span = tokens[i..<(i + length)]
                    guard span.last!.isWord, let term = match(span, technical: technical) else { continue }
                    output += term
                    i += length
                    replaced = true
                    break
                }
            }
            if !replaced {
                output += tokens[i].text
                i += 1
            }
        }
        return output
    }

    private func match(_ span: ArraySlice<Token>, technical: Bool) -> String? {
        let phrase = span.map(\.text).joined()
        if let rule = corrections[phrase.lowercased()], rule.always || technical { return rule.term }
        // Only spans made of words joined by spaces, hyphens or dots, e.g. "tail scale",
        // "GPT 4o", "Qwen 3 coder". Never across other punctuation.
        guard span.allSatisfy({ $0.isWord || [" ", "-", "."].contains($0.text) }) else { return nil }
        guard let term = canonical[Self.normalize(phrase)] else { return nil }
        // A single recognized word that's already a dictionary word stays as is.
        return term == phrase ? nil : term
    }

    private struct Token {
        let text: String
        let isWord: Bool
    }

    /// Splits into word tokens (letters, digits, apostrophes) and everything else.
    private static func tokenize(_ text: String) -> [Token] {
        var tokens: [Token] = []
        var current = ""
        var currentIsWord = false
        for ch in text {
            let isWord = ch.isLetter || ch.isNumber || ch == "'" || ch == "’"
            if !current.isEmpty, isWord != currentIsWord || !isWord {
                tokens.append(Token(text: current, isWord: currentIsWord))
                current = ""
            }
            current.append(ch)
            currentIsWord = isWord
        }
        if !current.isEmpty { tokens.append(Token(text: current, isWord: currentIsWord)) }
        return tokens
    }

    /// Lowercased, with spaces, hyphens, dots, slashes and underscores removed.
    public static func normalize(_ s: String) -> String {
        String(s.lowercased().filter { !" -._/".contains($0) })
    }

    private static let dictionary: Set<String> = {
        guard let words = try? String(contentsOfFile: "/usr/share/dict/words", encoding: .utf8) else { return [] }
        return Set(words.split(separator: "\n").map { $0.lowercased() })
    }()

    /// Whether `s` is an English word, allowing simple inflections the word list lacks
    /// ("clots", "murals", "deployed", "running"). Punctuation is ignored, so "/compact"
    /// counts as "compact".
    public static func isDictionaryWord(_ s: String) -> Bool {
        let w = normalize(s)
        guard !w.isEmpty else { return false }
        if dictionary.contains(w) { return true }
        for suffix in ["s", "es", "ed", "d", "ing"] where w.hasSuffix(suffix) && w.count > suffix.count + 2 {
            let stem = String(w.dropLast(suffix.count))
            if dictionary.contains(stem) || dictionary.contains(stem + "e") { return true }
            // "running" → "run", "clotted" → "clot"
            if let last = stem.last, stem.dropLast().last == last, dictionary.contains(String(stem.dropLast())) { return true }
        }
        return false
    }

    // MARK: User file

    public static let userFileTemplate = """
        # My Murmur vocabulary
        #
        # Words and names Murmur should recognize and spell exactly as written here.
        # One term per line. Lines starting with # are comments. "## Title" starts a section.
        # To fix a word Murmur keeps mishearing, add the mishearing after a bar:
        #   Ollama | all up | a llama
        # Changes apply to your next dictation.

        ## People and places

        ## Projects

        """

    /// Creates the user file with a template if it doesn't exist yet.
    public static func ensureUserFile() throws -> URL {
        let url = userFileURL
        if !FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try userFileTemplate.write(to: url, atomically: true, encoding: .utf8)
        }
        return url
    }
}
