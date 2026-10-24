import Foundation

/// One finished dictation, as stored in the history file.
public struct HistoryEntry: Codable, Equatable, Sendable, Identifiable {
    public enum Outcome: String, Codable, Sendable {
        /// Typed into the app.
        case inserted
        /// Recognized but not typed (password field, missing permission, test mode).
        case notInserted
        /// Recognition failed; there is no text.
        case failed
    }

    public var id: Date { date }
    public var date: Date
    /// App that had focus when the hotkey was pressed.
    public var app: String?
    public var bundleID: String?
    /// What the recognizer heard, before vocabulary and spoken-syntax fixes.
    public var heard: String
    /// What Murmur typed (or would have typed).
    public var text: String
    public var outcome: Outcome
    public var error: String?
    /// How long the hotkey was held.
    public var heldSeconds: Double
    /// Key release to final text.
    public var latencyMs: Int

    public init(date: Date = .now, app: String? = nil, bundleID: String? = nil, heard: String, text: String,
                outcome: Outcome, error: String? = nil, heldSeconds: Double = 0, latencyMs: Int = 0) {
        self.date = date
        self.app = app
        self.bundleID = bundleID
        self.heard = heard
        self.text = text
        self.outcome = outcome
        self.error = error
        self.heldSeconds = heldSeconds
        self.latencyMs = latencyMs
    }
}

/// Dictation history as JSON Lines: one entry per line, oldest first, appended as you
/// dictate. Lines that don't parse are skipped, so a damaged line loses one entry.
public struct HistoryFile: Sendable {
    public let url: URL

    /// `~/Library/Application Support/Murmur/History.jsonl`
    public static let defaultURL = URL.applicationSupportDirectory
        .appending(path: "Murmur/History.jsonl")

    public init(url: URL = HistoryFile.defaultURL) {
        self.url = url
    }

    public func append(_ entry: HistoryEntry) throws {
        var line = try Self.encoder.encode(entry)
        line.append(0x0A)
        let fileManager = FileManager.default
        if !fileManager.fileExists(atPath: url.path) {
            try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            fileManager.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600])
        }
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: line)
    }

    public func load() -> [HistoryEntry] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        return data.split(separator: 0x0A).compactMap { try? Self.decoder.decode(HistoryEntry.self, from: $0) }
    }

    /// Drops entries older than `cutoff` (and unreadable lines), rewriting the file only
    /// if something was dropped. Returns the entries kept.
    @discardableResult
    public func prune(olderThan cutoff: Date) throws -> [HistoryEntry] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        let lines = data.split(separator: 0x0A)
        let kept = lines.compactMap { try? Self.decoder.decode(HistoryEntry.self, from: $0) }
            .filter { $0.date >= cutoff }
        guard kept.count != lines.count else { return kept }
        var out = Data()
        for entry in kept {
            out.append(try Self.encoder.encode(entry))
            out.append(0x0A)
        }
        try out.write(to: url, options: .atomic)
        return kept
    }

    public func clear() throws {
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
    }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}
