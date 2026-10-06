import Foundation
import Testing
@testable import WhisperCore

// F599 — the model-independent floor a Quick Dictation clip must reach before a model is asked.
// The calibration (real helpers on synthetic silence, noise and attenuated bench speech) is in
// F599's log entry; these pin the measure and the direction the floor fails in.

private let rate = DictationCaptureLimits.sampleRate

/// A sine at `dBFS` RMS, `seconds` long.
private func tone(dBFS: Double, seconds: Double, frequency: Double = 220) -> [Float] {
    let amplitude = pow(10, dBFS / 20) * 2.squareRoot()
    let count = Int(saturating: seconds * Double(rate))
    return (0..<count).map { Float(amplitude * sin(2 * .pi * frequency * Double($0) / Double(rate))) }
}

private func silence(seconds: Double) -> [Float] {
    [Float](repeating: 0, count: Int(saturating: seconds * Double(rate)))
}

@Test("Digital silence is below the speech floor, at any length (F599)")
func digitalSilenceIsBelowTheFloor() throws {
    for seconds in [0.02, 1.0, 6.0] {
        let level = try #require(DictationSpeechFloor.level(of: silence(seconds: seconds)))
        #expect(level.loudestWindowDBFS == -.infinity)
        #expect(level.isBelowFloor)
    }
    // No samples is not a level at all; the caller transcribes as before.
    #expect(DictationSpeechFloor.level(of: []) == nil)
}

@Test("The floor is a level: just under it is silence, just over it is sent to the model (F599)")
func theFloorDecidesByLevel() throws {
    let floor = DictationSpeechFloor.floorDBFS
    let under = try #require(DictationSpeechFloor.level(of: tone(dBFS: floor - 1, seconds: 2)))
    let over = try #require(DictationSpeechFloor.level(of: tone(dBFS: floor + 1, seconds: 2)))
    #expect(abs(under.loudestWindowDBFS - (floor - 1)) < 0.1)
    #expect(under.isBelowFloor)
    #expect(!over.isBelowFloor)
}

@Test("One short word in a long hold is measured by its own loudest window, not the clip's average (F599)")
func aShortWordInALongHoldIsNotSilence() throws {
    // 100 ms at 15 dB over the floor inside 6 s of silence: averaged over the whole clip it would
    // sit about 3 dB under the floor and be thrown away.
    let word = tone(dBFS: DictationSpeechFloor.floorDBFS + 15, seconds: 0.1)
    let clip = silence(seconds: 3) + word + silence(seconds: 2.9)
    let level = try #require(DictationSpeechFloor.level(of: clip))
    let wholeClipMeanSquare = clip.reduce(0.0) { $0 + Double($1) * Double($1) } / Double(clip.count)
    #expect(10 * log10(wholeClipMeanSquare) < DictationSpeechFloor.floorDBFS)
    #expect(!level.isBelowFloor)
}

@Test("A clip on disk is read as WAVWriter wrote it, and anything else is never called silent (F599)")
func aClipOnDiskIsMeasuredOrLeftToTheModel() throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("DictationSpeechFloorTests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    let quiet = directory.appendingPathComponent("quiet.wav")
    try WAVWriter.wavData(from: silence(seconds: 2), sampleRate: rate).write(to: quiet)
    #expect(try #require(DictationSpeechFloor.level(ofClipAt: quiet)).isBelowFloor)

    let spoken = directory.appendingPathComponent("spoken.wav")
    let samples = silence(seconds: 0.5) + tone(dBFS: -30, seconds: 1) + silence(seconds: 0.5)
    try WAVWriter.wavData(from: samples, sampleRate: rate).write(to: spoken)
    let level = try #require(DictationSpeechFloor.level(ofClipAt: spoken))
    #expect(!level.isBelowFloor)
    #expect(abs(level.loudestWindowDBFS - (-30)) < 0.1)

    // Unreadable, missing or not 16-bit mono PCM: no level, so no refusal.
    let garbage = directory.appendingPathComponent("garbage.wav")
    try Data("not a wav file at all, but long enough to be read".utf8).write(to: garbage)
    #expect(DictationSpeechFloor.level(ofClipAt: garbage) == nil)
    #expect(DictationSpeechFloor.level(ofClipAt: directory.appendingPathComponent("missing.wav")) == nil)
    var stereo = WAVWriter.wavData(from: silence(seconds: 1), sampleRate: rate)
    stereo[22] = 2  // fmt channels
    let stereoURL = directory.appendingPathComponent("stereo.wav")
    try stereo.write(to: stereoURL)
    #expect(DictationSpeechFloor.level(ofClipAt: stereoURL) == nil)
}
