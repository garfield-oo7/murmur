import AVFoundation
import CoreAudio
import Foundation

/// Tells other apps on this Mac (TouchDeck, scripts) which microphone Murmur records
/// from and whether it's dictating, with distributed notifications:
///
/// - `io.github.garfield-oo7.Murmur.status`: posted by Murmur whenever something
///   below changes, and in reply to a request. `userInfo` (all strings):
///   - `state`: `idle`, `listening` or `transcribing`
///   - `microphoneName`: e.g. "EarPods Microphone" (empty if there's no mic)
///   - `microphoneUID`: the CoreAudio device UID, e.g. "BuiltInMicrophoneDevice"
///   - `microphoneSetting`: `auto`, `builtin`, `system`, or a device UID
///   - `version`: `1`
/// - `io.github.garfield-oo7.Murmur.requestStatus`: post this (no userInfo) and Murmur
///   answers with a status notification. Use it at launch to get the current value.
///
/// The microphone is the one Murmur would use if you pressed the shortcut now; while
/// dictating, the one it's recording from.
final class StatusBroadcaster {
    static let statusName = Notification.Name("io.github.garfield-oo7.Murmur.status")
    static let requestName = Notification.Name("io.github.garfield-oo7.Murmur.requestStatus")

    private let dictation: DictationController
    private var observers: [(NotificationCenter, NSObjectProtocol)] = []
    private var lastPosted: [String: String] = [:]
    /// The mic in use during a dictation, so a device change mid-dictation isn't reported
    /// as the one being recorded from.
    private var recordingMic: AVCaptureDevice?

    init(dictation: DictationController) {
        self.dictation = dictation
    }

    func start() {
        let distributed = DistributedNotificationCenter.default()
        observe(distributed, Self.requestName, force: true)
        // Mic plugged in or out, or the microphone setting changed.
        observe(.default, AVCaptureDevice.wasConnectedNotification)
        observe(.default, AVCaptureDevice.wasDisconnectedNotification)
        observe(.default, UserDefaults.didChangeNotification)
        // The system input changed (matters for the "System default" setting).
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultInputDevice,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, .main) { [weak self] _, _ in
            MainActor.assumeIsolated { self?.post() }
        }
        dictation.onStateChange = { [weak self] state in
            guard let self else { return }
            recordingMic = state == .idle ? nil : (recordingMic ?? Microphone.resolve())
            post()
        }
        post(force: true)
    }

    var status: [String: String] {
        let mic = recordingMic ?? Microphone.resolve()
        let state = switch dictation.state {
        case .idle: "idle"
        case .starting, .listening: "listening"
        case .finalizing: "transcribing"
        }
        return [
            "state": state,
            "microphoneName": mic?.localizedName ?? "",
            "microphoneUID": mic?.uniqueID ?? "",
            "microphoneSetting": Microphone.choice,
            "version": "1",
        ]
    }

    private func post(force: Bool = false) {
        let status = self.status
        guard force || status != lastPosted else { return }
        lastPosted = status
        DistributedNotificationCenter.default()
            .postNotificationName(Self.statusName, object: nil, userInfo: status, deliverImmediately: true)
    }

    /// Posts the status when `name` arrives; `force` answers even if nothing changed.
    private func observe(_ center: NotificationCenter, _ name: Notification.Name, force: Bool = false) {
        let token = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.post(force: force) }
        }
        observers.append((center, token))
    }
}
