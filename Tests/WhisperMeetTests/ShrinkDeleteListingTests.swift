import Foundation
import Testing
@testable import WhisperCore
@testable import WhisperMeet

// F949 — Shrink's safety checks (F911's coverage of every other `recording.<ext>`) ran on the folder's
// listing taken before the encode, and its delete step then removed every removable name in a fresh
// listing taken after it, minutes later. A `recording.<ext>` that appeared or grew in between was
// removed without ever being measured. Now only what the checks saw, unchanged, is removed; anything new
// or changed is left for the next Shrink, which measures it. Driven through the Shrink button's calls,
// with the encode and decode stubbed (F47 seams) so the stub can change the folder mid-encode.

@MainActor
private struct ListingFixture {
    let root: URL
    let model: AppModel
    let id: UUID
    let folder: URL

    init(before: [String: Int] = [:]) throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("F949-\(UUID().uuidString)")
        id = UUID()
        folder = root.appendingPathComponent("Recordings/\(id.uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try WAVWriter.wavData(from: [Float](repeating: 0.1, count: 60 * 48_000), sampleRate: 48_000)
            .write(to: folder.appendingPathComponent("recording.wav"))
        for (name, size) in before { try Data(count: size).write(to: folder.appendingPathComponent(name)) }
        model = AppModel(store: MeetingStore(rootDirectory: root), recorder: AudioCaptureEngine(),
                         defaults: UserDefaults(suiteName: testSuiteName())!)
        model.store.upsert(MeetingRecord(
            id: id, title: "Imported talk", duration: 60,
            recordingPath: "Recordings/\(id.uuidString)/recording.wav",
            status: .completed, transcriptText: "Hi."))
        model.decodeForShrink = { _ in DecodedAudio.Decoded(duration: 60, level: 0.1) }
        // The recording runs 60 s; any other `recording.<ext>` measures a second, so F911's rule lets it go.
        model.declaredDurationForShrink = { $0.pathExtension == "wav" ? 60 : 1 }
        model.availableBytesForShrink = { _ in .max }
        // F1004: the stand-in files AVFoundation cannot read are decoded by the installed ffmpeg to check their
        // channels; here each decodes to one channel, which has nothing to cancel against.
        model.decodeUnreadableForShrink = { _, output in
            try WAVWriter.wavData(from: [Float](repeating: 0.1, count: 16_000), sampleRate: 16_000).write(to: output)
        }
    }

    func url(_ name: String) -> URL { folder.appendingPathComponent(name) }
    func exists(_ name: String) -> Bool { FileManager.default.fileExists(atPath: url(name).path) }

    func shrink() async {
        await model.refreshStorage(ids: [id])
        model.requestShrink(ids: [id])
        await model.performShrink(confirmed: true)?.value
    }
}

@Test("A recording file that appears while the copy is encoded is kept, not removed unmeasured (F949)")
@MainActor
func shrinkKeepsARecordingThatAppearedDuringTheEncode() async throws {
    let f = try ListingFixture()
    defer { try? FileManager.default.removeItem(at: f.root) }
    let arrival = f.url("recording.mp3")
    f.model.encodeForShrink = { _, output, _ in
        try Data(count: 15_000).write(to: output)
        try Data(count: 5_000_000).write(to: arrival)
    }

    await f.shrink()

    let alert = f.model.alertMessage ?? "nil"
    #expect(f.exists("recording.mp3"), "never measured, so never removed: \(alert)")
    #expect((try? Data(contentsOf: arrival).count) == 5_000_000)
    #expect(f.exists("recording.m4a") && !f.exists("recording.wav"), "the measured original still goes: \(alert)")
    #expect(alert.contains("1 file(s) could not be removed; Shrink again to finish."), "\(alert)")
}

@Test("A recording file that grows while the copy is encoded is kept (F949)")
@MainActor
func shrinkKeepsARecordingThatGrewDuringTheEncode() async throws {
    let f = try ListingFixture(before: ["recording.mp3": 1_000_000])
    defer { try? FileManager.default.removeItem(at: f.root) }
    let growing = f.url("recording.mp3")
    f.model.encodeForShrink = { _, output, _ in
        try Data(count: 15_000).write(to: output)
        let handle = try FileHandle(forWritingTo: growing)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(count: 4_000_000))
        try handle.close()
    }

    await f.shrink()

    let alert = f.model.alertMessage ?? "nil"
    #expect(f.exists("recording.mp3"), "measured at 1 MB, changed since: \(alert)")
    #expect((try? Data(contentsOf: growing).count) == 5_000_000)
    #expect(!f.exists("recording.wav"))
    #expect(alert.contains("1 file(s) could not be removed; Shrink again to finish."), "\(alert)")
}

@Test("A leftover that stayed as it was measured is removed as before (F949 control)")
@MainActor
func shrinkStillRemovesAnUnchangedLeftover() async throws {
    let f = try ListingFixture(before: ["recording.mp3": 1_000_000])
    defer { try? FileManager.default.removeItem(at: f.root) }
    f.model.encodeForShrink = { _, output, _ in try Data(count: 15_000).write(to: output) }

    await f.shrink()

    let alert = f.model.alertMessage ?? "nil"
    #expect(!f.exists("recording.mp3") && !f.exists("recording.wav") && f.exists("recording.m4a"), "\(alert)")
    #expect(!alert.contains("could not be removed"), "\(alert)")
}
