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
