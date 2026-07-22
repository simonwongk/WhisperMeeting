import Testing
@testable import WhisperCore

@Test("clean trims and collapses whitespace, preserving CJK")
func cleanNormalizes() {
    #expect(DictationTextCleanup.clean(" Hello world ") == "Hello world")
    #expect(DictationTextCleanup.clean("Hello\n\n  world") == "Hello world")
    #expect(DictationTextCleanup.clean("   ") == "")
    #expect(DictationTextCleanup.clean(" 你好") == "你好")
    #expect(DictationTextCleanup.clean("你好 世界") == "你好 世界")
}
