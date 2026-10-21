import AVFoundation
import Foundation
import Testing
@testable import WhisperCore
@testable import WhisperMeet

// F955 — resuming an interrupted Shrink removes the originals the earlier run left beside its copy, and
// it read only their length (F911), never their tracks or channels. A build without F801's refusal (the
// installed F795 build) shrank a two-track or four-channel import to its first track or channel; if it
// was interrupted between saving the index and removing the original, the next resume deleted the last
// copy of the rest. As shipped, while Shrink of a recording that needs mixing is held back (F980), such a
// leftover is always kept. With the switch on (`mixing: true`, the held-back path these tests keep running),
// it is removed only when the copy is shown to hold each of its channels, the check a mixing encode makes —
// so a copy a mixing build made finishes, and one that kept track 1 keeps its original. Driven through the
// Shrink button's calls, with the real encoder and decoder.

@MainActor
private struct ResumeFixture {
    let root: URL
    let model: AppModel
    let id: UUID
    let folder: URL

    /// A meeting whose index already names `recording.m4a` (the copy `makeCopy` writes from the leftover
    /// `leftoverName`, which `writeLeftover` makes): the state an interrupted Shrink leaves.
    /// `mixing` sets `shrinkMixesRecordings`, the switch: off as shipped (F980), on for the held-back path.
    init(leftoverName: String, duration: TimeInterval, mixing: Bool = false, writeLeftover: (URL) async throws -> Void,
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
        model.trashForShrink = try ShrinkTestTrash(in: root).seam   // F1040: never the real Trash
        model.store.upsert(MeetingRecord(
            id: id, title: "Client call", duration: duration,
            recordingPath: "Recordings/\(id.uuidString)/recording.m4a",
            status: .completed, transcriptText: "Hi."))
        model.availableBytesForShrink = { _ in .max }
        model.shrinkMixesRecordings = mixing
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
    let f = try await ResumeFixture(leftoverName: "recording.mov", duration: 20, mixing: true,
                                    writeLeftover: twoSidedCall, makeCopy: firstTrackCopy)
    defer { try? FileManager.default.removeItem(at: f.root) }
    let original = try Data(contentsOf: f.folder.appendingPathComponent("recording.mov"))

    await f.shrink()

    let alert = f.model.alertMessage ?? "nil"
    #expect(f.exists("recording.mov"), "the only copy of the second side: \(alert)")
    #expect(try Data(contentsOf: f.folder.appendingPathComponent("recording.mov")) == original)
    #expect(alert.contains("nothing was removed"), "\(alert)")
    // Not the window it names: macOS 15 (the CI runner) reads this AVAssetWriter .mov's track timing differently from
    // later macOS, so the audit's first failing window differs (CI run 38320877235: no "0:10"). The original kept and
    // "nothing was removed" are the claims; the exact reason is re-pinned on macos-15 when F980 turns mixing Shrink on.
    #expect(alert.contains("“recording.mov”"), "names the file: \(alert)")
}

@Test("A resume keeps a four-channel leftover whose copy holds only its first channel (F955)")
@MainActor
func shrinkResumeKeepsAFourChannelLeftoverItsCopyLacks() async throws {
    // A panel's four microphones, each speaker in turn for five seconds.
    let tones = [300.0, 500.0, 700.0, 900.0]
    let f = try await ResumeFixture(leftoverName: "recording.wav", duration: 20, mixing: true, writeLeftover: { url in
        try fixturePolyWAV(tones.enumerated().map { index, tone in
            fixtureTone(frequency: tone, amplitude: 0.2, seconds: 20, from: Double(index) * 5, to: Double(index + 1) * 5)
        }).write(to: url)
    }, makeCopy: firstTrackCopy)
    defer { try? FileManager.default.removeItem(at: f.root) }

    await f.shrink()

    let alert = f.model.alertMessage ?? "nil"
    #expect(f.exists("recording.wav"), "\(alert)")
    // The copy is channel 1 whole, four times the level of the four channels averaged, so since F980 the
    // audit refuses it at 0:00 as not the mix, before speaker 2's absence at 0:05 is reached.
    #expect(alert.contains("nothing was removed") && alert.contains("“recording.wav”"), "\(alert)")
}

// Review of F955, mutants M2 and M3: both fixtures above take turns, so while the lost side or channel
// speaks alone the copy is silent, and a level check catches it without the per-channel check. These sound
// together: the copy keeps the mix's level, so only the fit of each track and channel shows what is gone.

@Test("A resume keeps a two-track leftover whose tracks speak together and whose copy holds track 1 (F955 review)")
@MainActor
func shrinkResumeKeepsATwoTrackLeftoverWhoseTracksOverlap() async throws {
    // The review's probe I: the second side speaks under the first, never alone.
    let f = try await ResumeFixture(leftoverName: "recording.mov", duration: 20, mixing: true, writeLeftover: { url in
        try await writeFixtureTracks(to: url, [FixtureTrack(channels: [(300, 0.2)], seconds: 20),
                                               FixtureTrack(channels: [(800, 0.1)], seconds: 20, audibleFrom: 2, audibleTo: 18)])
    }, makeCopy: firstTrackCopy)
    defer { try? FileManager.default.removeItem(at: f.root) }
    let original = try Data(contentsOf: f.folder.appendingPathComponent("recording.mov"))

    await f.shrink()

    let alert = f.model.alertMessage ?? "nil"
    #expect(try Data(contentsOf: f.folder.appendingPathComponent("recording.mov")) == original, "\(alert)")
    // As above: on macOS 15 the audit refuses this .mov for a different track or window (CI run 38320877235), so only
    // the outcome is pinned here; F980 re-pins the reason on macos-15.
    #expect(alert.contains("nothing was removed"), "\(alert)")
}

@Test("A resume keeps a four-channel leftover whose channels sound at once and whose copy holds channel 1 (F955 review)")
@MainActor
func shrinkResumeKeepsAFourChannelLeftoverWhoseChannelsOverlap() async throws {
    // R5's four simultaneous feeds at one level: the copy of channel 1 alone is louder than their mix.
    let tones = [300.0, 500.0, 700.0, 900.0]
    let f = try await ResumeFixture(leftoverName: "recording.wav", duration: 6, mixing: true, writeLeftover: { url in
        try fixturePolyWAV(tones.map { fixtureTone(frequency: $0, amplitude: 0.2, seconds: 6) }).write(to: url)
    }, makeCopy: firstTrackCopy)
    defer { try? FileManager.default.removeItem(at: f.root) }
    let original = try Data(contentsOf: f.folder.appendingPathComponent("recording.wav"))

    await f.shrink()

    let alert = f.model.alertMessage ?? "nil"
    #expect(try Data(contentsOf: f.folder.appendingPathComponent("recording.wav")) == original, "\(alert)")
    #expect(alert.contains("nothing was removed") && alert.contains("missing channel 2 of “recording.wav”"), "\(alert)")
}

@Test("A resume keeps a leftover measured with fewer channels than the copy was checked against (F955 review)")
@MainActor
func shrinkResumeKeepsALeftoverMeasuredWithFewerChannels() async throws {
    // The copy is the leftover's own mix, so every check passes on it; only the count shows that the
    // decode left a channel unjudged.
    let f = try await ResumeFixture(leftoverName: "recording.mov", duration: 20, mixing: true,
                                    writeLeftover: twoSidedCall, makeCopy: mixedCopy)
    defer { try? FileManager.default.removeItem(at: f.root) }
    f.model.decodeForShrink = { url in
        var decoded = try await DecodedAudio.fullyDecodedEveryTrack(of: url)
        if url.lastPathComponent == "recording.mov" { decoded.channelWindowLevels.removeLast() }
        return decoded
    }

    await f.shrink()

    let alert = f.model.alertMessage ?? "nil"
    #expect(f.exists("recording.mov"), "\(alert)")
    #expect(alert.contains("“recording.mov”, which the compressed copy replaced, could not be checked"), "\(alert)")
}

@Test("A resume still removes a several-track leftover whose copy is its mix (F955 control)")
@MainActor
func shrinkResumeRemovesALeftoverItsMixHolds() async throws {
    let f = try await ResumeFixture(leftoverName: "recording.mov", duration: 20, mixing: true,
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

// F980: while Shrink of a recording that needs mixing is held back, a resume keeps a several-track leftover
// too, even beside a copy that is its own mix: the check that would show the copy holds it is F980's.
@Test("A resume keeps a several-track leftover while mixing Shrink is held back, even beside its own mix (F955, F980)")
@MainActor
func shrinkResumeKeepsASeveralTrackLeftoverWhileMixingIsHeldBack() async throws {
    let f = try await ResumeFixture(leftoverName: "recording.mov", duration: 20,
                                    writeLeftover: twoSidedCall, makeCopy: mixedCopy)
    defer { try? FileManager.default.removeItem(at: f.root) }
    let original = try Data(contentsOf: f.folder.appendingPathComponent("recording.mov"))

    await f.shrink()

    let alert = f.model.alertMessage ?? "nil"
    #expect(f.exists("recording.mov") && f.exists("recording.m4a"), "\(alert)")
    #expect(try Data(contentsOf: f.folder.appendingPathComponent("recording.mov")) == original)
    #expect(alert.contains("“recording.mov”, which has 2 audio tracks"), "\(alert)")
}
