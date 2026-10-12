import AVFoundation
import Foundation
import Testing
@testable import WhisperCore
@testable import WhisperMeet

// F955 — resuming an interrupted Shrink removes the originals the earlier run left beside its copy, and
// it read only their length (F911), never their tracks or channels. A build without F801's refusal (the
// installed F795 build) shrank a two-track or four-channel import to its first track or channel; if it
// was interrupted between saving the index and removing the original, the next resume deleted the last
// copy of the rest. Now a leftover with several tracks or more than two channels is removed only when the
// copy is shown to hold each of its channels, the check an encode makes since F942 — so a copy a current
// build mixed still finishes, and one that kept track 1 keeps its original. Driven through the Shrink
// button's calls, with the real encoder and decoder.

@MainActor
private struct ResumeFixture {
    let root: URL
    let model: AppModel
    let id: UUID
    let folder: URL

    /// A meeting whose index already names `recording.m4a` (the copy `makeCopy` writes from the leftover
    /// `leftoverName`, which `writeLeftover` makes): the state an interrupted Shrink leaves.
    init(leftoverName: String, duration: TimeInterval, writeLeftover: (URL) async throws -> Void,
         makeCopy: (URL, URL, URL) async throws -> Void) async throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("F955-\(UUID().uuidString)")
        id = UUID()
        folder = root.appendingPathComponent("Recordings/\(id.uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let leftover = folder.appendingPathComponent(leftoverName)
        try await writeLeftover(leftover)
        try await makeCopy(leftover, folder.appendingPathComponent("recording.m4a"), root)
        model = AppModel(store: MeetingStore(rootDirectory: root), recorder: AudioCaptureEngine(),
                         defaults: UserDefaults(suiteName: testSuiteName())!)
        model.store.upsert(MeetingRecord(
            id: id, title: "Client call", duration: duration,
            recordingPath: "Recordings/\(id.uuidString)/recording.m4a",
            status: .completed, transcriptText: "Hi."))
        model.availableBytesForShrink = { _ in .max }
    }

    func exists(_ name: String) -> Bool {
        FileManager.default.fileExists(atPath: folder.appendingPathComponent(name).path)
    }

    func shrink() async {
        await model.refreshStorage(ids: [id])
        model.requestShrink(ids: [id])
        await model.performShrink(confirmed: true)?.value
    }
}

/// What the F795 build's encode made: afconvert's transcode, which keeps the first track (or of more than
/// two channels with no layout, the first channel), then AAC.
private func firstTrackCopy(_ leftover: URL, _ copy: URL, _ scratch: URL) async throws {
    try AudioCompressor.compressSpeech(input: leftover, output: copy,
                                       workingWAV: scratch.appendingPathComponent("work-\(UUID().uuidString).wav"))
}

/// What a build with F942 makes: every channel of every track mixed, then AAC.
private func mixedCopy(_ leftover: URL, _ copy: URL, _ scratch: URL) async throws {
    let mix = scratch.appendingPathComponent("mix-\(UUID().uuidString).wav")
    _ = try await RecordingMixer.mixEveryChannel(of: leftover, to: mix)
    try AudioCompressor.compressSpeech(input: mix, output: copy,
                                       workingWAV: scratch.appendingPathComponent("work-\(UUID().uuidString).wav"))
}

/// A call saved a side per track, the sides taking turns: the first 10 s on track 1, the rest on track 2.
private func twoSidedCall(_ url: URL) async throws {
    try await writeFixtureTracks(to: url, [FixtureTrack(channels: [(300, 0.2)], seconds: 20, audibleTo: 10),
                                           FixtureTrack(channels: [(800, 0.2)], seconds: 20, audibleFrom: 10)])
}

@Test("A resume keeps a two-track leftover whose copy holds only its first track, and says why (F955)")
@MainActor
func shrinkResumeKeepsATwoTrackLeftoverItsCopyLacks() async throws {
    let f = try await ResumeFixture(leftoverName: "recording.mov", duration: 20,
                                    writeLeftover: twoSidedCall, makeCopy: firstTrackCopy)
    defer { try? FileManager.default.removeItem(at: f.root) }
    let original = try Data(contentsOf: f.folder.appendingPathComponent("recording.mov"))

    await f.shrink()

    let alert = f.model.alertMessage ?? "nil"
    #expect(f.exists("recording.mov"), "the only copy of the second side: \(alert)")
    #expect(try Data(contentsOf: f.folder.appendingPathComponent("recording.mov")) == original)
    #expect(alert.contains("nothing was removed"), "\(alert)")
    #expect(alert.contains("“recording.mov”") && alert.contains("0:10"), "names the file and where: \(alert)")
}

@Test("A resume keeps a four-channel leftover whose copy holds only its first channel (F955)")
@MainActor
func shrinkResumeKeepsAFourChannelLeftoverItsCopyLacks() async throws {
    // A panel's four microphones, each speaker in turn for five seconds.
    let tones = [300.0, 500.0, 700.0, 900.0]
    let f = try await ResumeFixture(leftoverName: "recording.wav", duration: 20, writeLeftover: { url in
        try fixturePolyWAV(tones.enumerated().map { index, tone in
            fixtureTone(frequency: tone, amplitude: 0.2, seconds: 20, from: Double(index) * 5, to: Double(index + 1) * 5)
        }).write(to: url)
    }, makeCopy: firstTrackCopy)
    defer { try? FileManager.default.removeItem(at: f.root) }

    await f.shrink()

    let alert = f.model.alertMessage ?? "nil"
    #expect(f.exists("recording.wav"), "\(alert)")
    #expect(alert.contains("nothing was removed") && alert.contains("0:05"), "\(alert)")
}

@Test("A resume still removes a several-track leftover whose copy is its mix (F955 control)")
@MainActor
func shrinkResumeRemovesALeftoverItsMixHolds() async throws {
    let f = try await ResumeFixture(leftoverName: "recording.mov", duration: 20,
                                    writeLeftover: twoSidedCall, makeCopy: mixedCopy)
    defer { try? FileManager.default.removeItem(at: f.root) }

    await f.shrink()

    let alert = f.model.alertMessage ?? "nil"
    #expect(!f.exists("recording.mov") && f.exists("recording.m4a"), "\(alert)")
    #expect(alert.contains("Shrunk"), "\(alert)")
}

@Test("A resume still removes a one-track leftover, as before (F955 control)")
@MainActor
func shrinkResumeRemovesAOneTrackLeftover() async throws {
    let f = try await ResumeFixture(leftoverName: "recording.mov", duration: 20, writeLeftover: { url in
        try await writeFixtureTracks(to: url, [FixtureTrack(channels: [(300, 0.2)], seconds: 20)])
    }, makeCopy: firstTrackCopy)
    defer { try? FileManager.default.removeItem(at: f.root) }

    await f.shrink()

    let alert = f.model.alertMessage ?? "nil"
    #expect(!f.exists("recording.mov") && f.exists("recording.m4a"), "\(alert)")
}
