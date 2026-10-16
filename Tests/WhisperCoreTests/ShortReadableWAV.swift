import Foundation
@testable import WhisperCore

/// A tenth of a second of 16 kHz mono 16-bit silence behind a canonical header: a WAV `WAVInspection`
/// reads and puts well within any piece bound, so `LocalWhisperClient` hands it to `whisper` whole with
/// no decode (F903). The client tests that stub `whisper` used a few bytes of text named `.wav`, which
/// since F903 is decoded by ffmpeg first — so on a host with ffmpeg those tests would have tested
/// ffmpeg's error instead of the client's, and on one without it the client's.
func shortReadableWAV() -> Data {
    var data = WAVWriter.header(sampleRate: 16_000, dataByteCount: 3_200)
    data.append(Data(count: 3_200))
    return data
}
