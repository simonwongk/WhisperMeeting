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
}
