import Carbon
import AppKit
var fired = Set<UInt32>()
var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
InstallEventHandler(GetApplicationEventTarget(), { _, ev, _ in
  var id = EventHotKeyID(); GetEventParameter(ev, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil, MemoryLayout<EventHotKeyID>.size, nil, &id)
  fired.insert(id.id); return noErr }, 1, &spec, nil, nil)
let combos: [(String, CGKeyCode, UInt32, CGEventFlags)] = [
  ("Option+D", 2, UInt32(optionKey), .maskAlternate),
  ("Option+Space", 49, UInt32(optionKey), .maskAlternate),
  ("Shift+Option+D", 2, UInt32(optionKey|shiftKey), [.maskAlternate,.maskShift]),
  ("Ctrl+Option+D", 2, UInt32(controlKey|optionKey), [.maskControl,.maskAlternate]),
  ("Ctrl+Option+Space", 49, UInt32(controlKey|optionKey), [.maskControl,.maskAlternate]),
  ("Cmd+Shift+D", 2, UInt32(cmdKey|shiftKey), [.maskCommand,.maskShift]),
]
print("AX trusted (can post events):", AXIsProcessTrusted())
for (i, c) in combos.enumerated() {
  var ref: EventHotKeyRef?
  RegisterEventHotKey(UInt32(c.1), c.2, EventHotKeyID(signature: 0x54455354, id: UInt32(i)), GetApplicationEventTarget(), 0, &ref)
  let src = CGEventSource(stateID: .hidSystemState)
  for down in [true, false] { let e = CGEvent(keyboardEventSource: src, virtualKey: c.1, keyDown: down)!; e.flags = c.3; e.post(tap: .cghidEventTap) }
  RunLoop.current.run(until: Date().addingTimeInterval(0.4))
  print(c.0.padding(toLength: 20, withPad: " ", startingAt: 0), fired.contains(UInt32(i)) ? "FIRED ✅" : "did not fire")
  if let ref { UnregisterEventHotKey(ref) }
}
