import Foundation

/// Settings ▸ Quick Dictation ▸ Change: which key the user meant as the new trigger (F521).
///
/// The Settings window feeds it each key event while capture is armed and does what it says. Before
/// this, the first modifier or F-key the app saw became the trigger on its key-down, so the ⌘ of ⌘W
/// and the ⇧ of a capital letter each rebound push-to-talk, and Escape could not cancel. The rules:
///
/// - Escape cancels, and the trigger is unchanged.
/// - An F-key is chosen when it goes down. With ⌘ or ⌃ held it is a shortcut instead, and is let
///   through, as is any other key with ⌘ or ⌃ held (⌘W closes the window, ⌘Q quits).
/// - A modifier is chosen when it comes back up with nothing pressed while it was down: that is a
///   lone modifier. A key or another modifier pressed meanwhile made it half of a chord, and its
///   release chooses nothing.
/// - Any other key, Tab and Space included, is refused and held back, so it types nothing into a
///   field that has focus; the Settings window says why and that Esc cancels.
///
/// Pure, so the rules are tested without a window or a keyboard.
public struct DictationTriggerCapture: Sendable, Equatable {
    public enum Input: Equatable, Sendable {
        /// A key went down. `isShortcut` when ⌘ or ⌃ is held with it.
        case keyDown(keyCode: UInt16, isShortcut: Bool)
        /// A modifier key went down or up. `flags` is the event's raw modifier flags, whose
        /// device-dependent bits say which side's key is down.
        case modifiersChanged(keyCode: UInt16, flags: UInt64)
    }

    public enum Decision: Equatable, Sendable {
        /// Make this key the trigger. Capture is over.
        case choose(UInt16)
        /// Escape. Capture is over and the trigger is unchanged.
        case cancel
        /// Not a trigger. Hold the key back, say so, and keep capturing.
        case refuse
        /// Nothing chosen yet. Let the event through.
        case pass
    }

    public static let refusalHint = "That key can’t be a trigger — pick a modifier (⌘ ⌃ ⌥ ⇧) or an F-key, or press Esc to cancel."

    /// The modifier candidates down now that went down while capture was armed.
    private var heldModifiers: Set<UInt16> = []
    /// Whether anything else was pressed while `heldModifiers` were down.
    private var chorded = false

    public init() {}

    public mutating func handle(_ input: Input) -> Decision {
        switch input {
        case let .keyDown(keyCode, isShortcut):
            if keyCode == DictationKeyName.escapeKeyCode { return .cancel }
            if !heldModifiers.isEmpty { chorded = true }
            if isShortcut { return .pass }
            return DictationKeyName.functionKeyCodes.contains(keyCode) ? .choose(keyCode) : .refuse

        case let .modifiersChanged(keyCode, flags):
            guard DictationKeyName.modifierKeyCodes.contains(keyCode) else { return .pass }
            if Self.isDown(keyCode, flags: flags) {
                if !heldModifiers.isEmpty { chorded = true }
                heldModifiers.insert(keyCode)
                return .pass
            }
            // Up. A modifier that was already down when capture began was not pressed for it.
            guard heldModifiers.remove(keyCode) != nil else { return .pass }
            guard heldModifiers.isEmpty else { return .pass }
            defer { chorded = false }
            return chorded ? .pass : .choose(keyCode)
        }
    }

    /// Whether this side's modifier is down after the event. The side's own bit decides; an event
    /// that carries no side bits for the family at all (one a program made, say) is read by the
    /// family's device-independent bit instead, so a lone modifier can still be chosen.
    private static func isDown(_ keyCode: UInt16, flags: UInt64) -> Bool {
        if flags & DictationKeyName.modifierDeviceMask(for: keyCode) != 0 { return true }
        let (family, sides) = DictationKeyName.modifierFamily(of: keyCode)
        return flags & sides == 0 && flags & family != 0
    }
}
