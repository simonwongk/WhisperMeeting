/// Human-readable names for macOS virtual keycodes, for showing the bound push-to-talk key.
public enum DictationKeyName {
    private static let names: [UInt16: String] = [
        // Modifiers
        54: "Right ⌘", 55: "Left ⌘",
        56: "Left ⇧", 60: "Right ⇧",
        58: "Left ⌥", 61: "Right ⌥",
        59: "Left ⌃", 62: "Right ⌃",
        // Function keys
        122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5", 97: "F6",
        98: "F7", 100: "F8", 101: "F9", 109: "F10", 103: "F11", 111: "F12",
        105: "F13", 107: "F14", 113: "F15",
        // Special
        49: "Space", 36: "Return", 48: "Tab", 53: "Escape", 51: "Delete"
    ]

    /// A short human label for a macOS virtual keycode (e.g. 61 -> "Right ⌥").
    public static func display(for keyCode: UInt16) -> String {
        names[keyCode] ?? "Key #\(keyCode)"
    }

    /// Keycodes suitable as a push-to-talk trigger — modifiers and function keys, which don't emit
    /// text and are recognized by HotkeyMonitor. (Typing keys would both type and trigger; other
    /// modifiers like Caps Lock aren't detected.)
    public static let triggerCandidates: Set<UInt16> = [
        54, 55, 56, 58, 59, 60, 61, 62,                 // ⌘ ⇧ ⌥ ⌃ (left/right)
        122, 120, 99, 118, 96, 97, 98, 100, 101, 109, 103, 111, 105, 107, 113 // F1–F15
    ]
    public static func isTriggerCandidate(_ keyCode: UInt16) -> Bool { triggerCandidates.contains(keyCode) }
}
