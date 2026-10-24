import AVFoundation
import CoreAudio

/// Which microphone Murmur records from, stored in UserDefaults under `microphone`:
/// "auto" (default), "builtin", "system", or an `AVCaptureDevice.uniqueID`.
///
/// Automatic uses a wired headset (USB, like EarPods, or the headphone jack) when one
/// is plugged in, and the built-in mic otherwise. It never picks Bluetooth or iPhone
/// mics: the system input follows AirPods around, and opening an AirPods mic switches
/// them into low-quality call mode, interrupting whatever they're playing.
nonisolated enum Microphone {
    static let defaultsKey = "microphone"
    static let automatic = "auto"
    static let builtIn = "builtin"
    static let systemDefault = "system"

    static var choice: String {
        UserDefaults.standard.string(forKey: defaultsKey) ?? automatic
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
        case automatic:
            if let mic = wiredHeadset ?? builtInMic { return mic }
        case builtIn:
            if let mic = builtInMic { return mic }
        case let id:
            if let mic = AVCaptureDevice(uniqueID: id) { return mic }
        }
        return AVCaptureDevice.default(for: .audio)
    }

    private static func transport(_ device: AVCaptureDevice) -> UInt32 {
        UInt32(bitPattern: device.transportType)
    }

    /// The Mac's own microphone (not a headset in the headphone jack).
    private static var builtInMic: AVCaptureDevice? {
        available.first { $0.uniqueID == "BuiltInMicrophoneDevice" }
            ?? available.first { transport($0) == kAudioDeviceTransportTypeBuiltIn }
    }

    /// A USB headset or one plugged into the headphone jack, if any.
    private static var wiredHeadset: AVCaptureDevice? {
        available.first { transport($0) == kAudioDeviceTransportTypeUSB }
            ?? available.first {
                transport($0) == kAudioDeviceTransportTypeBuiltIn && $0.uniqueID != "BuiltInMicrophoneDevice"
                    && $0.localizedName.localizedCaseInsensitiveContains("external")
            }
    }
}
