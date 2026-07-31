import Testing
@testable import WhisperCore

@Test("Dictation audio buffering stops at the configured sample limit")
func dictationAudioBufferHasAHardLimit() {
    var buffer = BoundedAudioSampleBuffer(capacity: 4)

    buffer.append(contentsOf: [1, 2, 3])
    buffer.append(contentsOf: [4, 5, 6])

    #expect(buffer.samples == [1, 2, 3, 4])
}
