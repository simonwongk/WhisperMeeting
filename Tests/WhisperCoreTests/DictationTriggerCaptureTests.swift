import Testing
@testable import WhisperCore

/// F521 — Settings ▸ Quick Dictation ▸ Change. Before it, the first modifier or F-key the app saw
/// became the trigger on its key-DOWN, so the ⌘ of ⌘W and the ⇧ of a capital letter each rebound
/// push-to-talk, and Escape, Tab and Space were refused with capture left armed.
///
/// Flags are what an `NSEvent`'s raw modifier flags carry: the family's device-independent bit and
/// the side's device-dependent bit (`DictationKeyName.modifierDeviceMask`).

private let leftCommand: UInt16 = 55
private let leftShift: UInt16 = 56
private let rightOption: UInt16 = 61
private let f5: UInt16 = 96
private let wKey: UInt16 = 13
private let bKey: UInt16 = 11

private let commandFlag: UInt64 = 0x0010_0000
private let shiftFlag: UInt64 = 0x0002_0000
private let optionFlag: UInt64 = 0x0008_0000

private func down(_ key: UInt16, flags: UInt64) -> DictationTriggerCapture.Input {
    .modifiersChanged(keyCode: key, flags: flags)
}

@Test("Escape cancels choosing a trigger instead of being refused (F521)")
func escapeCancelsTriggerCapture() {
    var capture = DictationTriggerCapture()
    #expect(capture.handle(.keyDown(keyCode: DictationKeyName.escapeKeyCode, isShortcut: false)) == .cancel)
}

@Test("Tab and Space are refused as triggers and choose nothing (F521)")
func tabAndSpaceAreRefused() {
    var capture = DictationTriggerCapture()
    #expect(capture.handle(.keyDown(keyCode: 48, isShortcut: false)) == .refuse)
    #expect(capture.handle(.keyDown(keyCode: 49, isShortcut: false)) == .refuse)
}

@Test("⌘W while choosing a trigger closes the window and chooses nothing (F521)")
func commandWIsAShortcutNotATrigger() {
    var capture = DictationTriggerCapture()
    // ⌘ goes down: on main this chose Left ⌘ and ended capture before the W arrived.
    #expect(capture.handle(down(leftCommand, flags: commandFlag | 0x0008)) == .pass)
    // W with ⌘ held is a menu shortcut: let through, so the window closes.
    #expect(capture.handle(.keyDown(keyCode: wKey, isShortcut: true)) == .pass)
    // ⌘ comes up: a key was pressed while it was down, so it was a chord, not a choice.
    #expect(capture.handle(down(leftCommand, flags: 0)) == .pass)
}

@Test("A capital letter typed while choosing a trigger does not rebind it to Shift (F521)")
func shiftOfACapitalLetterIsNotATrigger() {
    var capture = DictationTriggerCapture()
    #expect(capture.handle(down(leftShift, flags: shiftFlag | 0x0002)) == .pass)
    #expect(capture.handle(.keyDown(keyCode: bKey, isShortcut: false)) == .refuse)
    #expect(capture.handle(down(leftShift, flags: 0)) == .pass)
}

@Test("A modifier pressed and released alone is chosen on its release (F521)")
func aLoneModifierIsChosenOnRelease() {
    var capture = DictationTriggerCapture()
    #expect(capture.handle(down(rightOption, flags: optionFlag | 0x0040)) == .pass)
    #expect(capture.handle(down(rightOption, flags: 0)) == .choose(rightOption))
}

@Test("An F-key is chosen on its press; with ⌘ held it is a shortcut (F521)")
func anFKeyIsChosenOnItsPress() {
    var shortcut = DictationTriggerCapture()
    #expect(shortcut.handle(.keyDown(keyCode: f5, isShortcut: true)) == .pass)
    var plain = DictationTriggerCapture()
    #expect(plain.handle(.keyDown(keyCode: f5, isShortcut: false)) == .choose(f5))
}

@Test("Two modifiers pressed together choose neither (F521)")
func twoModifiersTogetherChooseNeither() {
    var capture = DictationTriggerCapture()
    #expect(capture.handle(down(leftCommand, flags: commandFlag | 0x0008)) == .pass)
    #expect(capture.handle(down(leftShift, flags: commandFlag | 0x0008 | shiftFlag | 0x0002)) == .pass)
    #expect(capture.handle(down(leftShift, flags: commandFlag | 0x0008)) == .pass)
    #expect(capture.handle(down(leftCommand, flags: 0)) == .pass)
    // Nothing left over: the next lone modifier is a choice again.
    #expect(capture.handle(down(rightOption, flags: optionFlag | 0x0040)) == .pass)
    #expect(capture.handle(down(rightOption, flags: 0)) == .choose(rightOption))
}

@Test("A modifier held for a click is not chosen on its release, and the click goes through (F653)")
func aModifierHeldForAClickIsNotATrigger() {
    for (key, flags) in [(leftCommand, commandFlag | 0x0008), (rightOption, optionFlag | 0x0040)] {
        var capture = DictationTriggerCapture()
        #expect(capture.handle(down(key, flags: flags)) == .pass)
        // ⌘-click or ⌥-click in the Settings window: the click is the app's, and it makes the
        // modifier half of a chord.
        #expect(capture.handle(.click) == .pass)
        #expect(capture.handle(down(key, flags: 0)) == .pass, "a modifier held for a click became the trigger")
    }
    // A click with nothing held changes nothing: the next lone modifier is still a choice.
    var capture = DictationTriggerCapture()
    #expect(capture.handle(.click) == .pass)
    #expect(capture.handle(down(rightOption, flags: optionFlag | 0x0040)) == .pass)
    #expect(capture.handle(down(rightOption, flags: 0)) == .choose(rightOption))
}

@Test("A modifier already down when capture began chooses nothing on its release (F521)")
func aModifierHeldBeforeCaptureIsNotChosen() {
    var capture = DictationTriggerCapture()
    #expect(capture.handle(down(rightOption, flags: 0)) == .pass)
}

@Test("A modifier event without side bits still reads down and up by its family (F521)")
func aModifierWithoutSideBitsFallsBackToItsFamily() {
    var capture = DictationTriggerCapture()
    #expect(capture.handle(down(leftCommand, flags: commandFlag)) == .pass)
    #expect(capture.handle(down(leftCommand, flags: 0)) == .choose(leftCommand))
}
