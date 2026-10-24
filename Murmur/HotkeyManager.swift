import Carbon.HIToolbox
import Foundation
import os

/// Global hold-to-talk hotkey via Carbon `RegisterEventHotKey`, which needs no
/// permission. Option+D for now; configurable in M3.
///
/// M2 uses this as a diagnostic: it records press/release so we can confirm that
/// Option-only hotkeys fire on macOS 27 (PLAN.md §2.1). If they don't, M3 switches to
/// a CGEventTap.
@Observable
final class HotkeyManager {
    private(set) var isHeld = false
    private(set) var registrationStatus: OSStatus?
    private(set) var pressCount = 0
    private(set) var lastPress: Date?
    private(set) var lastRelease: Date?
    private(set) var lastHoldDuration: TimeInterval?

    let keyCode = UInt32(kVK_ANSI_D)
    let modifiers = UInt32(optionKey)
    let displayName = "⌥D"

    @ObservationIgnored private var hotKeyRef: EventHotKeyRef?
    @ObservationIgnored private var handlerRef: EventHandlerRef?
    private static let signature: OSType = 0x4D524D52 // 'MRMR'
    private static let log = Logger(subsystem: "io.github.garfield-oo7.Murmur", category: "hotkey")

    var isRegistered: Bool { registrationStatus == noErr }

    func register() {
        guard hotKeyRef == nil else { return }
        var specs = [
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed)),
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyReleased)),
        ]
        // The handler is a C function pointer and can't capture, so `self` travels as userData.
        let installStatus = InstallEventHandler(GetApplicationEventTarget(), { _, event, userData in
            guard let event, let userData else { return OSStatus(eventNotHandledErr) }
            let kind = GetEventKind(event)
            // Carbon delivers application-target events on the main thread.
            MainActor.assumeIsolated {
                let manager = Unmanaged<HotkeyManager>.fromOpaque(userData).takeUnretainedValue()
                manager.handle(pressed: kind == UInt32(kEventHotKeyPressed))
            }
            return noErr
        }, specs.count, &specs, Unmanaged.passUnretained(self).toOpaque(), &handlerRef)
        guard installStatus == noErr else {
            registrationStatus = installStatus
            Self.log.error("InstallEventHandler failed: \(installStatus)")
            return
        }

        let id = EventHotKeyID(signature: Self.signature, id: 1)
        let status = RegisterEventHotKey(keyCode, modifiers, id, GetApplicationEventTarget(), 0, &hotKeyRef)
        registrationStatus = status
        if status == noErr {
            Self.log.notice("registered \(self.displayName, privacy: .public)")
        } else {
            Self.log.error("RegisterEventHotKey \(self.displayName, privacy: .public) failed: \(status)")
        }
    }

    func unregister() {
        if let hotKeyRef { UnregisterEventHotKey(hotKeyRef) }
        if let handlerRef { RemoveEventHandler(handlerRef) }
        hotKeyRef = nil
        handlerRef = nil
        registrationStatus = nil
        isHeld = false
    }

    private func handle(pressed: Bool) {
        let now = Date()
        if pressed {
            // Key repeat can re-send "pressed" while held; count the first only.
            guard !isHeld else { return }
            isHeld = true
            pressCount += 1
            lastPress = now
            Self.log.notice("pressed")
        } else {
            isHeld = false
            lastRelease = now
            lastHoldDuration = lastPress.map { now.timeIntervalSince($0) }
            Self.log.notice("released after \(self.lastHoldDuration ?? -1, format: .fixed(precision: 3))s")
        }
    }
}
