import AppKit
import AVFoundation
import os

/// Hold-to-talk state machine: idle → starting → listening → finalizing → idle.
/// Esc while holding, or a very short tap, cancels.
@Observable
final class DictationController {
    enum State: Equatable {
        case idle
        case starting
        case listening
        case finalizing
    }

    private(set) var state = State.idle
    private(set) var lastTranscript: String?
    private(set) var lastError: String?

    /// Holds shorter than this are treated as accidental taps.
    static let minimumHold: Duration = .milliseconds(300)
    /// Set by `--test-dictation`: logs the transcript publicly for automated checks.
    var logsTranscripts = false
    /// Set by `--test-audio`: transcribe this file instead of the microphone.
    var testAudio: URL?
    /// Set by `--test-no-insert`: keep the text in the menu only.
    var insertsText = true

    /// Mic loudness, shared with the pill.
    let meter = LevelMeter()
    @ObservationIgnored let pill: FlowPill

    init() {
        pill = FlowPill(meter: meter)
    }

    @ObservationIgnored private var session: DictationSession?
    @ObservationIgnored private var startTask: Task<Bool, Never>?
    @ObservationIgnored private var pressedAt = ContinuousClock.now
    @ObservationIgnored var onError: ((DictationError) -> Void)?
    private static let log = Logger(subsystem: "io.github.garfield-oo7.Murmur", category: "dictation")

    // MARK: Hotkey events

    func keyDown() {
        guard state == .idle else { return } // ignore presses while finalizing
        guard testAudio != nil || AVCaptureDevice.authorizationStatus(for: .audio) == .authorized else {
            fail(.microphoneNotAllowed)
            return
        }
        pressedAt = .now
        state = .starting
        lastError = nil
        meter.reset()
        pill.listening()

        let session = DictationSession(pressedAt: pressedAt, meter: meter, testAudio: testAudio)
        self.session = session
        // The mic needs ~0.25 s to deliver audio; the sound and the bars coming alive
        // mean "go ahead and speak".
        session.onMicLive = { [weak self, weak session] in
            guard let self, let session, self.session === session, self.state != .idle else { return }
            Sound.start.play()
            self.pill.micLive()
        }
        startTask = Task {
            do {
                try await session.start()
            } catch {
                Self.log.error("start failed: \(error, privacy: .public)")
                if self.session === session { self.reset() }
                if let error = error as? DictationError { self.fail(error) } else { self.fail(message: error.localizedDescription) }
                return false
            }
            // Released or cancelled while the mic was starting: those paths take over.
            if self.session === session, self.state == .starting { self.state = .listening }
            return true
        }
    }

    func keyUp() {
        guard state == .starting || state == .listening, let session else { return }
        let held = ContinuousClock.now - pressedAt
        guard held >= Self.minimumHold else {
            Self.log.notice("tap of \(ms(held), privacy: .public) ignored")
            cancel(quietly: true)
            return
        }
        state = .finalizing
        pill.transcribing()
        let startTask = self.startTask
        Task {
            guard await startTask?.value == true, self.session === session else { return }
            do {
                let text = try await session.finish()
                self.logTimings(session.timings, held: held)
                if text.isEmpty {
                    Self.log.notice("no speech recognized")
                } else {
                    self.lastTranscript = text
                    if self.logsTranscripts { Self.log.notice("transcript: \(text, privacy: .public)") }
                    if self.insertsText { try await self.insert(text) }
                    if self.logsTranscripts, self.insertsText {
                        try? await Task.sleep(for: .milliseconds(500))
                        let landed = TextInserter.focusedTextForTesting() ?? "(unreadable)"
                        Self.log.notice("focused text after insert: \(landed, privacy: .public)")
                    }
                }
                Sound.stop.play()
                self.pill.finished()
            } catch let error as DictationError {
                self.fail(error)
            } catch {
                Self.log.error("finish failed: \(error, privacy: .public)")
                self.fail(message: error.localizedDescription)
            }
            if self.session === session { self.reset() }
        }
    }

    /// Esc while holding (or a too-short tap): throw the recording away.
    func cancel(quietly: Bool = false) {
        guard let session, state != .idle else { return }
        reset()
        if quietly {
            pill.finished()
        } else {
            Self.log.notice("cancelled")
            Sound.cancel.play()
            pill.cancelled()
        }
        let startTask = self.startTask
        Task {
            _ = await startTask?.value
            await session.cancel()
        }
    }

    // MARK: Helpers

    private func insert(_ text: String) async throws {
        do {
            try await TextInserter.insert(text)
        } catch TextInserter.Failure.notTrusted {
            throw DictationError.accessibilityNotAllowed
        }
    }

    private func reset() {
        session = nil
        state = .idle
    }

    private func fail(_ error: DictationError) {
        fail(message: error.localizedDescription)
        onError?(error)
    }

    private func fail(message: String) {
        lastError = message
        Sound.cancel.play()
        pill.failed()
    }

    private func logTimings(_ t: DictationSession.Timings, held: Duration) {
        Self.log.notice("""
            dictation: held \(ms(held), privacy: .public), source \(t.source, privacy: .public), \
            capture start \(ms(t.captureStart), privacy: .public), prepare \(ms(t.prepare), privacy: .public), \
            press→first audio \(t.pressToFirstAudio.map(ms) ?? "–", privacy: .public), \
            audio \(t.audioSeconds, format: .fixed(precision: 2), privacy: .public)s in \(t.buffers, privacy: .public) buffers, \
            drain ended early \(t.drainEndedEarly, privacy: .public), \
            mic peak \(self.meter.peakDB, format: .fixed(precision: 1), privacy: .public) dBFS, \
            release→text \(ms(t.releaseToText), privacy: .public)
            """)
    }
}

/// Short system sounds for start / stop / cancel. Fire-and-forget.
enum Sound: String {
    case start = "Tink"
    case stop = "Pop"
    case cancel = "Funk"

    func play() {
        guard UserDefaults.standard.object(forKey: "playSounds") as? Bool ?? true else { return }
        NSSound(named: rawValue)?.play()
    }
}
