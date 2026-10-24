import AppKit
import MurmurCore
import os

/// Keeps every dictation in `~/Library/Application Support/Murmur/History.jsonl`
/// (never leaves the Mac), and the latest few in memory for the menu.
@Observable
final class DictationHistory {
    static let enabledKey = "keepHistory"
    static let retentionKey = "historyRetentionDays"
    /// Retention choices in days; 0 keeps everything.
    static let retentionChoices = [7, 30, 90, 365, 0]
    static let menuCount = 10

    /// Newest first.
    private(set) var recent: [HistoryEntry] = []
    /// Off for automated test runs so they don't fill your history.
    @ObservationIgnored var isRecording = true

    @ObservationIgnored private let file = HistoryFile()
    private static let log = Logger(subsystem: "io.github.garfield-oo7.Murmur", category: "history")

    init() {
        load()
    }

    var isEnabled: Bool {
        UserDefaults.standard.object(forKey: Self.enabledKey) as? Bool ?? true
    }

    static var retentionDays: Int {
        UserDefaults.standard.object(forKey: retentionKey) as? Int ?? 30
    }

    static func title(forRetention days: Int) -> String {
        switch days {
        case 0: "Forever"
        case 365: "1 year"
        default: "\(days) days"
        }
    }

    /// Drops expired entries and loads the latest ones for the menu.
    func load() {
        do {
            let days = Self.retentionDays
            let entries = days > 0
                ? try file.prune(olderThan: .now.addingTimeInterval(-Double(days) * 86_400))
                : file.load()
            recent = Array(entries.suffix(Self.menuCount).reversed())
        } catch {
            Self.log.error("load failed: \(error, privacy: .public)")
        }
    }

    func record(_ entry: HistoryEntry) {
        guard isRecording, isEnabled else { return }
        recent.insert(entry, at: 0)
        if recent.count > Self.menuCount { recent.removeLast() }
        do {
            try file.append(entry)
        } catch {
            Self.log.error("append failed: \(error, privacy: .public)")
        }
    }

    func clear() {
        recent = []
        do {
            try file.clear()
        } catch {
            Self.log.error("clear failed: \(error, privacy: .public)")
        }
    }

    func showInFinder() {
        if FileManager.default.fileExists(atPath: file.url.path) {
            NSWorkspace.shared.activateFileViewerSelecting([file.url])
        } else {
            let folder = file.url.deletingLastPathComponent()
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            NSWorkspace.shared.open(folder)
        }
    }
}
