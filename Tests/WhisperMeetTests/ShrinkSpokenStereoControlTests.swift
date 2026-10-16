import AVFoundation
import Foundation
import Testing
@testable import WhisperCore
@testable import WhisperMeet

// F1007 — F1001's controls with real speech (`shrinkJudgesBenchSpeech`, the bench clips) and with the installed ffmpeg
// are gated off CI, which has neither, so CI pinned Shrink's false refusals on synthetic tones only, and a change that
// made Shrink refuse ordinary spoken stereo would pass it. The bench clips are macOS's own text-to-speech (`say`,
// Scripts/bench/generate_clips.sh), and `say` ships with every macOS, the runner included: so this control speaks its
// own two sentences with the system voice at test time, builds ordinary stereo from them, and requires every one to
// shrink — and a mid/side pairing of the same speech to be kept, so the control cannot pass by measuring nothing.
// Nothing is committed: the speech is made where the test runs.

/// `text` spoken by the system voice at 16 kHz, mono, with `say` (as the bench clips are made), at half level.
private func spoken(_ text: String, rate words: Int, in folder: URL) throws -> [Float] {
    let url = folder.appendingPathComponent("\(UUID().uuidString).wav")
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/say")
    process.arguments = ["-r", "\(words)", "-o", url.path, "--file-format=WAVE", "--data-format=LEI16@16000", text]
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = pipe
    try process.run()
    let output = pipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    try #require(process.terminationStatus == 0, "say: \(String(decoding: output, as: UTF8.self))")
    let file = try AVAudioFile(forReading: url)
    let buffer = try #require(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)))
    try file.read(into: buffer)
    try #require(file.processingFormat.sampleRate == 16_000 && buffer.frameLength > 16_000, "say made \(buffer.frameLength) frames")
    return Array(UnsafeBufferPointer(start: try #require(buffer.floatChannelData)[0], count: Int(buffer.frameLength))).map { $0 * 0.5 }
}

private func mixed(_ a: [Float], _ b: [Float], _ k: Float = 1) -> [Float] { zip(a, b).map { $0 + k * $1 } }
private func scaled(_ a: [Float], _ k: Float) -> [Float] { a.map { $0 * k } }
private func late(_ x: [Float], _ frames: Int) -> [Float] { [Float](repeating: 0, count: frames) + Array(x.dropLast(frames)) }

@Test("Ordinary stereo made of real speech shrinks on every host, and its mid/side pairing is kept (F1007 control)")
@MainActor
func shrinkStillShrinksSpokenStereo() async throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("F1007-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    let first = try spoken("The quarterly numbers look better than we expected, so let us review the budget together.",
                           rate: 190, in: folder)
    let second = try spoken("I think the second option is cheaper, but we should ask the team before Friday afternoon.",
                            rate: 170, in: folder)
    let count = Swift.min(first.count, second.count, 5 * 16_000)
    let x = Array(first.prefix(count)), y = Array(second.prefix(count))
    let ordinary: [(String, [[Float]])] = [
        ("a talker per channel", [x, y]),
        ("both talkers panned", [mixed(scaled(x, 0.7), scaled(y, 0.3)), mixed(scaled(x, 0.3), scaled(y, 0.7))]),
        ("a phone's spacing, two talkers", [mixed(x, late(y, 7)), mixed(late(x, 7), y)]),
        ("one talker on microphones 1 ms apart", [x, late(x, 16)]),
        ("one talker centred, the other hard left", [mixed(x, y), x]),
    ]
    var wrong: [String] = []
    for (label, channels) in ordinary {
        let outcome = try await shrinkSpoken(channels, seconds: Double(count) / 16_000)
        if outcome.kept || !outcome.alert.contains("Shrunk") { wrong.append("REFUSED \(label): \(outcome.alert)") }
    }
    let midSide = try await shrinkSpoken([mixed(x, y), mixed(x, y, -1)], seconds: Double(count) / 16_000)
    if !midSide.kept { wrong.append("DELETED mid/side: \(midSide.alert)") }
    print("F1007 spoken stereo: \(ordinary.count) ordinary, 1 cancelling, \(wrong.count) wrong")
    #expect(wrong.isEmpty, "\(wrong)")
}

/// Shrinks a two-channel 16 kHz float WAV of `channels` through the calls the Shrink button makes.
@MainActor
private func shrinkSpoken(_ channels: [[Float]], seconds: Double) async throws -> (kept: Bool, alert: String) {
    let f = try await MixFixture(recordingExtension: "wav", duration: seconds) { url in
        try fixtureFloatWAV(channels, rate: 16_000).write(to: url)
    }
    defer { try? FileManager.default.removeItem(at: f.root) }
    let original = try Data(contentsOf: f.recording)
    await f.shrink()
    let alert = f.model.alertMessage ?? "nil"
    return ((try? Data(contentsOf: f.recording)) == original && !f.exists("recording.m4a"), alert)
}
