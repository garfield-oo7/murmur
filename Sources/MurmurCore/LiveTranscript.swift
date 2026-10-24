import CoreMedia

/// Text of one dictation as the recognizer reports it: settled segments plus the
/// latest guess for the audio after them. Each guess replaces the previous one; a
/// settled segment replaces the guesses it covers.
public struct LiveTranscript: Sendable {
    public struct Segment: Sendable {
        public var range: CMTimeRange
        public var text: String
        public var isFinal: Bool

        public init(range: CMTimeRange, text: String, isFinal: Bool) {
            self.range = range
            self.text = text
            self.isFinal = isFinal
        }
    }

    public init() {}

    public private(set) var finals: [Segment] = []
    public private(set) var pending: Segment?

    public mutating func add(_ segment: Segment) {
        if segment.isFinal {
            // Replaces a guess promoted below for the same audio.
            finals.removeAll { $0.range.start >= segment.range.start && $0.range.start < segment.range.end }
            finals.append(segment)
            finals.sort { $0.range.start < $1.range.start }
            if let pending, pending.range.start < segment.range.end { self.pending = nil }
        } else {
            // A late guess for audio that has already settled.
            if let end = finals.last?.range.end, segment.range.start < end { return }
            // Guesses start where settled text ends, so a guess that starts after the
            // previous one ended means that one was settled without being marked so.
            if let pending, segment.range.start >= pending.range.end {
                finals.append(Segment(range: pending.range, text: pending.text, isFinal: true))
            }
            pending = segment
        }
    }

    public var settled: String { finals.map(\.text).joined() }
    public var unsettled: String { pending?.text ?? "" }

    /// Everything heard so far. When the key is released this is the dictation: any
    /// guess the recognizer never settled is kept rather than dropped.
    public var text: String {
        (settled + unsettled).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
