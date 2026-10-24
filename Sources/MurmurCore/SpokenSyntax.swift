import Foundation

/// Tidies paths and slash commands the recognizer half-gets right. It already turns
/// spoken "slash" and "dot" into "/" and ".", but glues commands onto the previous word
/// ("Run/model"), mishears "tilde" ("Tilda/", "Hilda/") and capitalizes path parts
/// ("~/.Claude/settings.Jason").
public enum SpokenSyntax {
    /// Slash commands of Claude Code, Codex and similar CLIs.
    public static let slashCommands: Set<String> = [
        "model", "compact", "clear", "init", "help", "review", "config", "cost", "memory", "permissions",
        "resume", "agents", "mcp", "hooks", "login", "logout", "status", "doctor", "export", "context",
        "rewind", "plugin", "plugins", "skills", "add-dir", "terminal-setup", "statusline", "usage", "ide",
        "security-review", "vim", "approvals", "diff", "fast", "loop", "output-style", "upgrade", "bug",
        "pr-comments", "install-github-app", "new", "mention", "quit", "exit", "plan", "todos", "tasks",
    ]

    /// How the recognizer tends to write "tilde" right before a slash.
    private static let tildeWords: Set<String> = ["tilde", "tilda", "tilder", "hilda", "tilled", "tilly"]

    /// Path parts that should be lowercase, with mishearings ("Jason" for json).
    private static let pathParts: [String: String] = [
        "claude": "claude", "codex": "codex", "cursor": "cursor", "config": "config", "ssh": "ssh",
        "git": "git", "github": "github", "vscode": "vscode", "local": "local", "cache": "cache",
        "json": "json", "jason": "json", "jsonl": "jsonl", "md": "md", "yaml": "yaml", "yml": "yml",
        "toml": "toml", "txt": "txt", "env": "env", "sh": "sh", "zsh": "zsh", "zshrc": "zshrc",
        "bashrc": "bashrc", "swift": "swift", "py": "py", "ts": "ts", "tsx": "tsx", "js": "js",
        "plist": "plist", "lock": "lock", "log": "log", "xcconfig": "xcconfig", "mcp": "mcp",
    ]

    /// Works word by word (whitespace-separated), so prose is never touched.
    public static func apply(_ text: String) -> String {
        var output = ""
        var word = ""
        for ch in text {
            if ch.isWhitespace {
                output += fixWord(word) + String(ch)
                word = ""
            } else {
                word.append(ch)
            }
        }
        return output + fixWord(word)
    }

    private static func fixWord(_ word: String) -> String {
        guard word.contains("/") else { return word }
        var w = word
        // "Tilda/projects" → "~/projects"
        if let slash = w.firstIndex(of: "/"), tildeWords.contains(w[..<slash].lowercased()) {
            w = "~" + w[slash...]
        }
        // "Run/model" → "Run /model" (also "then/clear,"), only for known commands.
        let parts = w.split(separator: "/", maxSplits: 1, omittingEmptySubsequences: false)
        if parts.count == 2, let first = parts[0].first, first.isLetter,
           parts[0].allSatisfy(\.isLetter) {
            let (command, tail) = splitTrailingPunctuation(String(parts[1]))
            if slashCommands.contains(command.lowercased()) {
                return parts[0] + " /" + command.lowercased() + tail
            }
        }
        // "/Model" → "/model"
        if w.hasPrefix("/"), !w.dropFirst().contains("/") {
            let (command, tail) = splitTrailingPunctuation(String(w.dropFirst()))
            if slashCommands.contains(command.lowercased()) { return "/" + command.lowercased() + tail }
        }
        // Paths: "~/.Claude/settings.Jason" → "~/.claude/settings.json"
        if w.hasPrefix("~/") || w.hasPrefix("./") || w.hasPrefix("/") {
            let (path, tail) = splitTrailingPunctuation(w)
            return fixPath(path) + tail
        }
        return w
    }

    /// "clear," → ("clear", ","); "settings.json." → ("settings.json", ".")
    private static func splitTrailingPunctuation(_ s: String) -> (String, String) {
        var body = s
        var tail = ""
        while let last = body.last, ",.;:!?)\"'”’".contains(last) {
            tail.insert(last, at: tail.startIndex)
            body.removeLast()
        }
        return (body, tail)
    }

    private static func fixPath(_ path: String) -> String {
        let segments = path.split(separator: "/", omittingEmptySubsequences: false).map { segment -> String in
            let parts = segment.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
            return parts.enumerated().map { index, part in
                // The name before the first dot keeps its case (~/Library, README); dot
                // folders and extensions are mapped/lowercased when known.
                guard index > 0 || parts.count == 1 else { return part }
                return pathParts[part.lowercased()] ?? part
            }.joined(separator: ".")
        }
        return segments.joined(separator: "/")
    }

}
