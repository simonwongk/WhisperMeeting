import Testing
@testable import WhisperCore

@Test("61 maps to Right Option")
func keyNameRightOption() {
    #expect(DictationKeyName.display(for: 61) == "Right ⌥")
}

@Test("54 maps to Right Command")
func keyNameRightCommand() {
    #expect(DictationKeyName.display(for: 54) == "Right ⌘")
}

@Test("96 maps to F5")
func keyNameF5() {
    #expect(DictationKeyName.display(for: 96) == "F5")
}

@Test("49 maps to Space")
func keyNameSpace() {
    #expect(DictationKeyName.display(for: 49) == "Space")
}

@Test("unmapped key code falls back to Key #<code>")
func keyNameUnmapped() {
    #expect(DictationKeyName.display(for: 0) == "Key #0")
}

@Test("F11, F14 and F15 are named as keys macOS binds by default; F5 and modifiers are not (F547)")
func systemBoundFKeysAreNamed() {
    for key: UInt16 in [103, 107, 113] {
        #expect(DictationKeyName.systemShortcut(for: key) != nil, "F-key \(key) is not flagged")
    }
    for key: UInt16 in [96, 97, 61, 55] {
        #expect(DictationKeyName.systemShortcut(for: key) == nil)
    }
}

@Test("trigger candidates accept modifiers and F-keys, reject letters and Caps Lock")
func keyNameTriggerCandidates() {
    #expect(DictationKeyName.isTriggerCandidate(61) == true)
    #expect(DictationKeyName.isTriggerCandidate(96) == true)
    #expect(DictationKeyName.isTriggerCandidate(0) == false)
    #expect(DictationKeyName.isTriggerCandidate(57) == false)
}
