import AVFoundation
import CoreAudio

/// Which microphone Murmur records from, stored in UserDefaults under `microphone`:
/// "builtin" (default), "system", or an `AVCaptureDevice.uniqueID`.
///
/// Built-in is the default because the system input follows AirPods and other headsets
/// around, and opening an AirPods mic switches them into low-quality call mode,
/// interrupting whatever they're playing (even on another device).
nonisolated enum Microphone {
    static let defaultsKey = "microphone"
    static let builtIn = "builtin"
    static let systemDefault = "system"

    static var choice: String {
        UserDefaults.standard.string(forKey: defaultsKey) ?? builtIn
    }

    static var available: [AVCaptureDevice] {
        AVCaptureDevice.DiscoverySession(deviceTypes: [.microphone, .external], mediaType: .audio,
                                         position: .unspecified).devices
    }

    /// The device to record from; falls back to the system default if the chosen one
    /// is gone (e.g. a USB mic was unplugged).
    static func resolve() -> AVCaptureDevice? {
        switch choice {
        case systemDefault:
            break
        case builtIn:
            if let mic = available.first(where: { $0.transportType == Int32(bitPattern: kAudioDeviceTransportTypeBuiltIn) }) {
                return mic
            }
        case let id:
            if let mic = AVCaptureDevice(uniqueID: id) { return mic }
        }
        return AVCaptureDevice.default(for: .audio)
    }
}
