@preconcurrency import AVFoundation
import Accelerate
import Synchronization

/// Microphone loudness for the pill's bars, written from the capture thread and read
/// by the pill every frame. 0 = silence, 1 = loud speech.
///
/// Fed by a second AVCaptureAudioDataOutput on the capture session (or the engine tap),
/// not by AnalyzerInput: its deprecated `buffer` getter traps on provider inputs (M4).
nonisolated final class LevelMeter: Sendable {
    private struct State {
        var level: Float = 0
        var peakDB: Float = -160
    }
    private let state = Mutex(State())

    var level: Float { state.withLock { $0.level } }
    /// Loudest RMS seen since the last reset, in dBFS. For the log: tells "mic heard
    /// nothing" apart from "speech not recognized".
    var peakDB: Float { state.withLock { $0.peakDB } }

    func reset() { state.withLock { $0 = State() } }

    /// Settings slider, 0…1 (default 0.5). Higher = bars react to quieter sound.
    static let sensitivityKey = "waveformSensitivity"

    /// The dBFS that maps to empty bars; full bars are 35 dB above it. Speech on a
    /// laptop mic sits around -45…-15 dBFS, which sensitivity 0.5 (-50 dB) covers.
    private static func floorDB() -> Float {
        let sensitivity = UserDefaults.standard.object(forKey: sensitivityKey) as? Double ?? 0.5
        return Float(-35 - 30 * sensitivity) // 0 → -35 dB, 1 → -65 dB
    }

    func record(rms: Float) {
        let db = 20 * log10(max(rms, 1e-7))
        let target = min(max((db - Self.floorDB()) / 35, 0), 1)
        state.withLock {
            $0.peakDB = max($0.peakDB, db)
            // Fast attack, slower release, so bars jump with syllables and fall gently.
            $0.level = target > $0.level ? target : $0.level * 0.82 + target * 0.18
        }
    }

    func record(samples: UnsafePointer<Float>, count: Int) {
        guard count > 0 else { return }
        var rms: Float = 0
        vDSP_rmsqv(samples, 1, &rms, vDSP_Length(count))
        record(rms: rms)
    }
}

/// Second audio output on the capture session that only measures loudness.
nonisolated final class LevelTap: NSObject, AVCaptureAudioDataOutputSampleBufferDelegate, @unchecked Sendable {
    private let meter: LevelMeter
    private let output = AVCaptureAudioDataOutput()
    private let queue = DispatchQueue(label: "murmur.level-tap", qos: .userInteractive)

    init(meter: LevelMeter) {
        self.meter = meter
        super.init()
        output.audioSettings = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsNonInterleaved: false,
            AVNumberOfChannelsKey: 1,
        ]
        output.setSampleBufferDelegate(self, queue: queue)
    }

    /// Returns false if the session won't take another output; the pill then just
    /// shows idle bars.
    @discardableResult
    func attach(to session: AVCaptureSession) -> Bool {
        session.beginConfiguration()
        defer { session.commitConfiguration() }
        guard session.canAddOutput(output) else { return false }
        session.addOutput(output)
        return true
    }

    func detach(from session: AVCaptureSession) {
        session.beginConfiguration()
        session.removeOutput(output)
        session.commitConfiguration()
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        var blockBuffer: CMBlockBuffer?
        var list = AudioBufferList()
        let status = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sampleBuffer, bufferListSizeNeededOut: nil, bufferListOut: &list,
            bufferListSize: MemoryLayout<AudioBufferList>.size, blockBufferAllocator: nil,
            blockBufferMemoryAllocator: nil, flags: 0, blockBufferOut: &blockBuffer)
        guard status == noErr, let data = list.mBuffers.mData else { return }
        let count = Int(list.mBuffers.mDataByteSize) / MemoryLayout<Float>.size
        meter.record(samples: data.assumingMemoryBound(to: Float.self), count: count)
    }
}
