import AppKit
import Carbon.HIToolbox
import os

/// A key plus Carbon modifier flags, persisted in UserDefaults.
struct Shortcut: Codable, Equatable {
    var keyCode: UInt32
    var modifiers: UInt32

    static let `default` = Shortcut(keyCode: UInt32(kVK_ANSI_D), modifiers: UInt32(optionKey))

    var displayName: String {
        var s = ""
        if modifiers & UInt32(controlKey) != 0 { s += "⌃" }
        if modifiers & UInt32(optionKey) != 0 { s += "⌥" }
        if modifiers & UInt32(shiftKey) != 0 { s += "⇧" }
        if modifiers & UInt32(cmdKey) != 0 { s += "⌘" }
        return s + Self.keyName(keyCode)
    }

    /// Name of the key in the current keyboard layout (e.g. "D"), or a fixed name for
    /// non-character keys.
    static func keyName(_ keyCode: UInt32) -> String {
        switch Int(keyCode) {
        case kVK_Space: return "Space"
        case kVK_Return: return "↩"
        case kVK_Tab: return "⇥"
        case kVK_Escape: return "⎋"
        case kVK_Delete: return "⌫"
        default:
            if let name = fKeys[Int(keyCode)] { return name }
        }
        guard let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
              let data = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else {
            return "#\(keyCode)"
        }
        let layout = unsafeBitCast(data, to: CFData.self)
        var deadKeys: UInt32 = 0
        var chars = [UniChar](repeating: 0, count: 4)
        var length = 0
        let status = CFDataGetBytePtr(layout).withMemoryRebound(to: UCKeyboardLayout.self, capacity: 1) {
            UCKeyTranslate($0, UInt16(keyCode), UInt16(kUCKeyActionDisplay), 0, UInt32(LMGetKbdType()),
                           OptionBits(kUCKeyTranslateNoDeadKeysBit), &deadKeys, chars.count, &length, &chars)
        }
        guard status == noErr, length > 0 else { return "#\(keyCode)" }
        return String(utf16CodeUnits: chars, count: length).uppercased()
    }

    static func isFunctionKey(_ keyCode: Int) -> Bool { fKeys[keyCode] != nil }

    private static let fKeys: [Int: String] = [
        kVK_F1: "F1", kVK_F2: "F2", kVK_F3: "F3", kVK_F4: "F4", kVK_F5: "F5", kVK_F6: "F6",
        kVK_F7: "F7", kVK_F8: "F8", kVK_F9: "F9", kVK_F10: "F10", kVK_F11: "F11", kVK_F12: "F12",
        kVK_F13: "F13", kVK_F14: "F14", kVK_F15: "F15", kVK_F16: "F16", kVK_F17: "F17",
        kVK_F18: "F18", kVK_F19: "F19", kVK_F20: "F20",
    ]

    /// Carbon modifier mask from AppKit flags.
    init(keyCode: UInt32, flags: NSEvent.ModifierFlags) {
        var m: UInt32 = 0
        if flags.contains(.control) { m |= UInt32(controlKey) }
        if flags.contains(.option) { m |= UInt32(optionKey) }
        if flags.contains(.shift) { m |= UInt32(shiftKey) }
        if flags.contains(.command) { m |= UInt32(cmdKey) }
        self.init(keyCode: keyCode, modifiers: m)
    }

    init(keyCode: UInt32, modifiers: UInt32) {
        self.keyCode = keyCode
        self.modifiers = modifiers
    }
}

/// Global hold-to-talk hotkey via Carbon `RegisterEventHotKey`, which needs no
/// permission. Verified on macOS 27 in M2: Option-only combos fire, with both pressed
/// and released events.
@Observable
final class HotkeyManager {
    private(set) var shortcut: Shortcut
    private(set) var isHeld = false
    private(set) var registrationStatus: OSStatus?

    @ObservationIgnored var onPress: (() -> Void)?
    @ObservationIgnored var onRelease: (() -> Void)?
    @ObservationIgnored var onCancel: (() -> Void)?

    @ObservationIgnored private var hotKeyRef: EventHotKeyRef?
    @ObservationIgnored private var cancelRefs: [EventHotKeyRef] = []
    @ObservationIgnored private var handlerRef: EventHandlerRef?

    private static let signature: OSType = 0x4D524D52 // 'MRMR'
    private static let mainID: UInt32 = 1
    private static let cancelID: UInt32 = 2
    private static let defaultsKey = "hotkey"
    private static let log = Logger(subsystem: "io.github.garfield-oo7.Murmur", category: "hotkey")

    var displayName: String { shortcut.displayName }
    var isRegistered: Bool { registrationStatus == noErr }

    init() {
        if let data = UserDefaults.standard.data(forKey: Self.defaultsKey),
           let saved = try? JSONDecoder().decode(Shortcut.self, from: data) {
            shortcut = saved
        } else {
            shortcut = .default
        }
    }

    func register() {
        installHandlerIfNeeded()
        guard handlerRef != nil, hotKeyRef == nil else { return }
        let id = EventHotKeyID(signature: Self.signature, id: Self.mainID)
        let status = RegisterEventHotKey(shortcut.keyCode, shortcut.modifiers, id, GetApplicationEventTarget(), 0, &hotKeyRef)
        registrationStatus = status
        if status == noErr {
            Self.log.notice("registered \(self.displayName, privacy: .public)")
        } else {
            hotKeyRef = nil
            Self.log.error("RegisterEventHotKey \(self.displayName, privacy: .public) failed: \(status)")
        }
    }

    /// Switches to a new shortcut. Returns false (keeping the old one) if it can't be
    /// registered, e.g. because another app already owns it.
    @discardableResult
    func change(to new: Shortcut) -> Bool {
        let old = shortcut
        unregisterMain()
        shortcut = new
        register()
        guard isRegistered else {
            shortcut = old
            register()
            return false
        }
        UserDefaults.standard.set(try? JSONEncoder().encode(new), forKey: Self.defaultsKey)
        return true
    }

    /// Esc cancels only while the dictation key is held, so it's a hotkey just for that
    /// window. Registered with and without Option since Option is usually still down.
    private func setCancelKeyActive(_ active: Bool) {
        if active, cancelRefs.isEmpty {
            for modifiers in [0, shortcut.modifiers] {
                var ref: EventHotKeyRef?
                let id = EventHotKeyID(signature: Self.signature, id: Self.cancelID)
                if RegisterEventHotKey(UInt32(kVK_Escape), modifiers, id, GetApplicationEventTarget(), 0, &ref) == noErr, let ref {
                    cancelRefs.append(ref)
                }
            }
        } else if !active {
            cancelRefs.forEach { UnregisterEventHotKey($0) }
            cancelRefs.removeAll()
        }
    }

    private func unregisterMain() {
        if let hotKeyRef { UnregisterEventHotKey(hotKeyRef) }
        hotKeyRef = nil
        registrationStatus = nil
        setCancelKeyActive(false)
        isHeld = false
    }

    private func installHandlerIfNeeded() {
        guard handlerRef == nil else { return }
        var specs = [
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed)),
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyReleased)),
        ]
        // The handler is a C function pointer and can't capture, so `self` travels as userData.
        let status = InstallEventHandler(GetApplicationEventTarget(), { _, event, userData in
            guard let event, let userData else { return OSStatus(eventNotHandledErr) }
            var id = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                              nil, MemoryLayout<EventHotKeyID>.size, nil, &id)
            let pressed = GetEventKind(event) == UInt32(kEventHotKeyPressed)
            // Carbon delivers application-target events on the main thread.
            MainActor.assumeIsolated {
                Unmanaged<HotkeyManager>.fromOpaque(userData).takeUnretainedValue().handle(id: id.id, pressed: pressed)
            }
            return noErr
        }, specs.count, &specs, Unmanaged.passUnretained(self).toOpaque(), &handlerRef)
        if status != noErr {
            registrationStatus = status
            Self.log.error("InstallEventHandler failed: \(status)")
        }
    }

    private func handle(id: UInt32, pressed: Bool) {
        switch (id, pressed) {
        case (Self.mainID, true):
            // Key repeat can re-send "pressed" while held; act on the first only.
            guard !isHeld else { return }
            isHeld = true
            setCancelKeyActive(true)
            onPress?()
        case (Self.mainID, false):
            guard isHeld else { return }
            isHeld = false
            setCancelKeyActive(false)
            onRelease?()
        case (Self.cancelID, true):
            guard isHeld else { return }
            // The main key is still physically down; ignore its release.
            isHeld = false
            setCancelKeyActive(false)
            onCancel?()
        default:
            break
        }
    }
}
