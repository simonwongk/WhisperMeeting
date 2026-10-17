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

private let say = "/usr/bin/say"

/// How long `say` may take to write a sentence (review 2 of Wave 8 lane A, finding 3): it writes one in about two
/// seconds here, and a speech service that never answers on a headless runner must fail this test by name, not hang
/// the suite until its watchdog.
private let sayDeadline: Duration = .seconds(30)

/// `text` spoken by the system voice at 16 kHz, mono, with `say` (as the bench clips are made), at half level.
@MainActor
private func spoken(_ text: String, rate words: Int, in folder: URL) async throws -> [Float] {
    let url = folder.appendingPathComponent("\(UUID().uuidString).wav")
    let log = folder.appendingPathComponent("\(UUID().uuidString).log")
    FileManager.default.createFile(atPath: log.path, contents: nil)
    let process = Process()
    process.executableURL = URL(fileURLWithPath: say)
    process.arguments = ["-r", "\(words)", "-o", url.path, "--file-format=WAVE", "--data-format=LEI16@16000", text]
    // Into a file, not a pipe, so a chatty or stuck `say` can never block on a full pipe.
    let handle = try FileHandle(forWritingTo: log)
    defer { try? handle.close() }
    process.standardOutput = handle
    process.standardError = handle
    try process.run()
    let deadline = ContinuousClock.now + sayDeadline
    while process.isRunning, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(20)) }
    if process.isRunning {
        process.terminate()
        Issue.record("say did not finish within \(sayDeadline); terminated")
        throw CancellationError()
    }
    let output = (try? String(contentsOf: log, encoding: .utf8)) ?? ""
    try #require(process.terminationStatus == 0, "say: \(output)")
    let file = try AVAudioFile(forReading: url)
    let buffer = try #require(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)))
    try file.read(into: buffer)
    try #require(file.processingFormat.sampleRate == 16_000 && buffer.frameLength > 16_000, "say made \(buffer.frameLength) frames")
    return Array(UnsafeBufferPointer(start: try #require(buffer.floatChannelData)[0], count: Int(buffer.frameLength))).map { $0 * 0.5 }
}

private func mixed(_ a: [Float], _ b: [Float], _ k: Float = 1) -> [Float] { zip(a, b).map { $0 + k * $1 } }
private func scaled(_ a: [Float], _ k: Float) -> [Float] { a.map { $0 * k } }
private func late(_ x: [Float], _ frames: Int) -> [Float] { [Float](repeating: 0, count: frames) + Array(x.dropLast(frames)) }

@Test(
    "Ordinary stereo made of real speech shrinks on every host, and its mid/side pairing is kept (F1007 control)",
    // Skipped, and said so in the run's list, on a host with no `say`; one that has it but cannot speak fails by name.
    .enabled(if: FileManager.default.isExecutableFile(atPath: say), "no /usr/bin/say on this host")
)
@MainActor
func shrinkStillShrinksSpokenStereo() async throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("F1007-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    let first = try await spoken("The quarterly numbers look better than we expected, so let us review the budget together.",
                                 rate: 190, in: folder)
    let second = try await spoken("I think the second option is cheaper, but we should ask the team before Friday afternoon.",
                                  rate: 170, in: folder)
    let count = Swift.min(first.count, second.count, 5 * 16_000)
    let x = Array(first.prefix(count)), y = Array(second.prefix(count))
    // Each ordinary layout well inside what Shrink lets through: the spaced talker at 0.5 ms, not the 1 ms where F1001's
    // by-design comb refusals begin to come near (review 1 of Wave 8 lane A, finding 7).
    let ordinary: [(String, [[Float]])] = [
        ("a talker per channel", [x, y]),
        ("both talkers panned", [mixed(scaled(x, 0.7), scaled(y, 0.3)), mixed(scaled(x, 0.3), scaled(y, 0.7))]),
        ("a phone's spacing, two talkers", [mixed(x, late(y, 7)), mixed(late(x, 7), y)]),
        ("one talker on microphones 0.5 ms apart", [x, late(x, 8)]),
        ("one talker centred, the other hard left", [mixed(x, y), x]),
    ]
    let seconds = Double(count) / 16_000
    let cases = ordinary + [("mid/side", [mixed(x, y), mixed(x, y, -1)])]
    let outcomes = try await concurrentProbes(cases) { item in try await shrinkSpoken(item.1, seconds: seconds) }
    var wrong: [String] = []
    for ((label, _), outcome) in zip(cases, outcomes) {
        if label == "mid/side" {
            if !outcome.kept { wrong.append("DELETED mid/side: \(outcome.alert)") }
        } else if outcome.kept || !outcome.alert.contains("Shrunk") {
            wrong.append("REFUSED \(label): \(outcome.alert)")
        }
    }
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
