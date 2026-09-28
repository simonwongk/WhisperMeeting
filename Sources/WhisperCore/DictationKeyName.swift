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

    /// Escape, which cancels choosing a trigger rather than being one (F521).
    public static let escapeKeyCode: UInt16 = 53

    /// Each side's ⌘ ⇧ ⌥ ⌃. HotkeyMonitor tells a modifier trigger's down from its up by the
    /// side's device-dependent flag bit (`modifierDeviceMask`), and Caps Lock has none.
    public static let modifierKeyCodes: Set<UInt16> = [54, 55, 56, 58, 59, 60, 61, 62]

    /// F1–F15.
    public static let functionKeyCodes: Set<UInt16> = [
        122, 120, 99, 118, 96, 97, 98, 100, 101, 109, 103, 111, 105, 107, 113
    ]

    /// Keycodes suitable as a push-to-talk trigger — modifiers and function keys, which don't emit
    /// text and are recognized by HotkeyMonitor. (Typing keys would both type and trigger; other
    /// modifiers like Caps Lock aren't detected.)
    public static let triggerCandidates: Set<UInt16> = modifierKeyCodes.union(functionKeyCodes)
    public static func isTriggerCandidate(_ keyCode: UInt16) -> Bool { triggerCandidates.contains(keyCode) }

    /// The device-dependent flag bit for one side's modifier key; 0 for a key that is no modifier.
    /// The same bits in a `CGEvent`'s flags and an `NSEvent`'s raw modifier flags.
    public static func modifierDeviceMask(for keyCode: UInt16) -> UInt64 {
        switch keyCode {
        case 58: 0x0000_0020 // left Option
        case 61: 0x0000_0040 // right Option
        case 59: 0x0000_0001 // left Control
        case 62: 0x0000_2000 // right Control
        case 56: 0x0000_0002 // left Shift
        case 60: 0x0000_0004 // right Shift
        case 55: 0x0000_0008 // left Command
        case 54: 0x0000_0010 // right Command
        default: 0
        }
    }

    /// The device-independent flag of a modifier key's family (⇧ ⌃ ⌥ ⌘, either side), and the
    /// device-dependent bits of both of that family's sides; zeros for a key that is no modifier.
    static func modifierFamily(of keyCode: UInt16) -> (family: UInt64, sides: UInt64) {
        switch keyCode {
        case 56, 60: (0x0002_0000, 0x0000_0006)  // Shift
        case 59, 62: (0x0004_0000, 0x0000_2001)  // Control
        case 58, 61: (0x0008_0000, 0x0000_0060)  // Option
        case 54, 55: (0x0010_0000, 0x0000_0018)  // Command
        default: (0, 0)
        }
    }
}
