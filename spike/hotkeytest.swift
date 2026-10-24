import Carbon
// kVK codes: D=2, Space=49
let combos: [(String, UInt32, UInt32)] = [
  ("Option+D", 2, UInt32(optionKey)),
  ("Shift+Option+D", 2, UInt32(optionKey|shiftKey)),
  ("Option+Space", 49, UInt32(optionKey)),
  ("Ctrl+Option+D", 2, UInt32(controlKey|optionKey)),
  ("Ctrl+Option+Space", 49, UInt32(controlKey|optionKey)),
  ("Cmd+Shift+D", 2, UInt32(cmdKey|shiftKey)),
  ("Ctrl+Shift+D", 2, UInt32(controlKey|shiftKey)),
  ("Cmd+Option+Space", 49, UInt32(cmdKey|optionKey)),
]
for (i, c) in combos.enumerated() {
  var ref: EventHotKeyRef?
  let st = RegisterEventHotKey(c.1, c.2, EventHotKeyID(signature: 0x54455354, id: UInt32(i)), GetApplicationEventTarget(), 0, &ref)
  print(c.0.padding(toLength: 20, withPad: " ", startingAt: 0), st == noErr ? "OK" : "REJECTED (\(st))")
  if let ref { UnregisterEventHotKey(ref) }
}
