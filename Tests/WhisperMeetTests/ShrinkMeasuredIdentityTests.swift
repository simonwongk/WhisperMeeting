import AVFoundation
import Foundation
import Testing
@testable import WhisperCore
@testable import WhisperMeet

// F1005 — Shrink's delete step removed the files its checks measured by matching name and size only (F949), so a
// same-size rewrite in place, or an atomic replace by a file of the same size, after the check was deleted unmeasured;
// and the commit's in-place replace of a file already named as the output (a link import's `recording.m4a`
// download) compared nothing at all. Now each file is identified as F894 identifies a WAV it removes — volume,
// inode, size and modification time — at the listing the checks ran on, again just before its removal, and by the
// removal itself (set aside, compared, then unlinked); the replace requires the file there to be the one measured.
// The outside writer is a seam: the encode, or the hook called before each removal, changes the folder.

@MainActor
private struct IdentityFixture {
    let root: URL
    let model: AppModel
    let id: UUID
    let folder: URL

    /// A 60 s recording.wav import with a 1 MB recording.mp3 leftover beside it, measured as 1 s.
    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("F1005-\(UUID().uuidString)")
        id = UUID()
        folder = root.appendingPathComponent("Recordings/\(id.uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try WAVWriter.wavData(from: [Float](repeating: 0.1, count: 60 * 48_000), sampleRate: 48_000)
            .write(to: folder.appendingPathComponent("recording.wav"))
        try Data(repeating: 0x11, count: 1_000_000).write(to: folder.appendingPathComponent("recording.mp3"))
        model = AppModel(store: MeetingStore(rootDirectory: root), recorder: AudioCaptureEngine(),
                         defaults: UserDefaults(suiteName: testSuiteName())!)
        model.trashForShrink = try ShrinkTestTrash(in: root).seam   // F1040: never the real Trash
        model.store.upsert(MeetingRecord(
            id: id, title: "Imported talk", duration: 60,
            recordingPath: "Recordings/\(id.uuidString)/recording.wav",
            status: .completed, transcriptText: "Hi."))
        model.encodeForShrink = { _, output, _ in try Data(count: 15_000).write(to: output) }
        // A WAV reports its own length — the 60 s recording, and a leftover's one-second decode, which F1058 holds
        // to the second it measures; the stand-in copy is no WAV and stands for the recording.
        model.decodeForShrink = { url in
            let seconds = WAVInspection.header(at: url).map { Double($0.declaredDataBytes) / Double($0.bytesPerSecond) }
            return DecodedAudio.Decoded(duration: seconds ?? 60, level: 0.1)
        }
        model.declaredDurationForShrink = { $0.pathExtension == "wav" ? 60 : 1 }
        model.availableBytesForShrink = { _ in .max }
        // The leftover's stand-in bytes are not media AVFoundation reads; decoded, they are one channel (F1004).
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

/// Rewrites `url` in place with `byte`, the same size, and moves its modification time a second on, so the change
/// does not depend on the clock's resolution. The inode stays.
private func rewriteInPlace(_ url: URL, byte: UInt8) throws {
    let before = try FileManager.default.attributesOfItem(atPath: url.path)
    let size = try #require((before[.size] as? NSNumber)?.intValue)
    let modified = try #require(before[.modificationDate] as? Date)
    let handle = try FileHandle(forWritingTo: url)
    try handle.write(contentsOf: Data(repeating: byte, count: size))
    try handle.close()
    try FileManager.default.setAttributes([.modificationDate: modified.addingTimeInterval(1)], ofItemAtPath: url.path)
}

@Test("A leftover rewritten in place with the same size after it was measured is kept (F1005)")
@MainActor
func shrinkKeepsALeftoverRewrittenInPlace() async throws {
    let f = try IdentityFixture()
    defer { try? FileManager.default.removeItem(at: f.root) }
    let leftover = f.url("recording.mp3")
    f.model.encodeForShrink = { _, output, _ in
        try Data(count: 15_000).write(to: output)
        try rewriteInPlace(leftover, byte: 0x22)
    }

    await f.shrink()

    let alert = f.model.alertMessage ?? "nil"
    #expect((try? Data(contentsOf: leftover)) == Data(repeating: 0x22, count: 1_000_000), "rewritten after it was measured: \(alert)")
    #expect(f.exists("recording.m4a") && !f.exists("recording.wav"), "the measured original still goes: \(alert)")
    #expect(alert.contains("1 file(s) could not be removed; Shrink again to finish."), "\(alert)")
}

@Test("A leftover replaced by another file of the same size and modification time after it was measured is kept (F1005)")
@MainActor
func shrinkKeepsALeftoverReplacedAtomically() async throws {
    let f = try IdentityFixture()
    defer { try? FileManager.default.removeItem(at: f.root) }
    let leftover = f.url("recording.mp3"), staged = f.root.appendingPathComponent("staged.mp3")
    f.model.encodeForShrink = { _, output, _ in
        try Data(count: 15_000).write(to: output)
        let modified = try #require(try FileManager.default.attributesOfItem(atPath: leftover.path)[.modificationDate] as? Date)
        try Data(repeating: 0x33, count: 1_000_000).write(to: staged)
        try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: staged.path)
        try #require(rename(staged.path, leftover.path) == 0)
    }

    await f.shrink()

    let alert = f.model.alertMessage ?? "nil"
    #expect((try? Data(contentsOf: leftover)) == Data(repeating: 0x33, count: 1_000_000), "another file under the measured name: \(alert)")
    #expect(alert.contains("1 file(s) could not be removed"), "\(alert)")
}

@Test("A leftover rewritten just before its removal, after the delete step listed it, is kept (F1005)")
@MainActor
func shrinkKeepsALeftoverRewrittenAtTheRemoval() async throws {
    let f = try IdentityFixture()
    defer { try? FileManager.default.removeItem(at: f.root) }
    let leftover = f.url("recording.mp3")
    var rewritten = false
    f.model.willRemoveForShrink = { name in
        guard name == "recording.mp3", !rewritten else { return }
        rewritten = true
        try? rewriteInPlace(leftover, byte: 0x44)
    }

    await f.shrink()

    let alert = f.model.alertMessage ?? "nil"
    try #require(rewritten, "the removal hook never ran for the leftover: \(alert)")
    #expect((try? Data(contentsOf: leftover)) == Data(repeating: 0x44, count: 1_000_000), "\(alert)")
    #expect(alert.contains("1 file(s) could not be removed"), "\(alert)")
    #expect(try FileManager.default.contentsOfDirectory(atPath: f.folder.path).filter { $0.contains(".removing-") }.isEmpty,
            "the set-aside name was left")
}

private final class Once: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false
    /// True the first time only.
    func first() -> Bool { lock.withLock { defer { done = true }; return !done } }
}

@Test("A leftover rewritten after the delete step's last identity check, at the moment of its unlink, is kept (F1005 round 2)")
@MainActor
func shrinkKeepsALeftoverRewrittenAtTheUnlink() async throws {
    // Review 1 of Wave 8 lane A, finding 4: with the removal replaced by a plain removal by path, and the identity check
    // before it kept, every F1005 test still passed — the rewrite came before that check. This one comes after it, where
    // only the removal's own set-aside-and-compare (F894's `removeIfUnchanged`) can see it.
    let f = try IdentityFixture()
    defer { try? FileManager.default.removeItem(at: f.root) }
    let leftover = f.url("recording.mp3")
    let once = Once()
    f.model.willUnlinkForShrink = { url in
        guard url.lastPathComponent == "recording.mp3", once.first() else { return }
        try? rewriteInPlace(url, byte: 0x66)
    }

    await f.shrink()

    let alert = f.model.alertMessage ?? "nil"
    #expect((try? Data(contentsOf: leftover)) == Data(repeating: 0x66, count: 1_000_000), "\(alert)")
    #expect(alert.contains("1 file(s) could not be removed"), "\(alert)")
    let setAside = try FileManager.default.contentsOfDirectory(atPath: f.folder.path).filter { $0.contains(".removing-") }
    #expect(setAside.isEmpty, "the set-aside name was left: \(setAside)")
}

@Test("A leftover left as it was measured is still removed, Locked flag and all (F1005 control)")
@MainActor
func shrinkStillRemovesAnUnchangedLeftoverByIdentity() async throws {
    let f = try IdentityFixture()
    defer { try? FileManager.default.removeItem(at: f.root) }
    try FileManager.default.setAttributes([.immutable: true], ofItemAtPath: f.url("recording.mp3").path)

    await f.shrink()

    let alert = f.model.alertMessage ?? "nil"
    #expect(alert.contains("Shrunk") && !alert.contains("could not be removed"), "\(alert)")
    #expect(!f.exists("recording.mp3") && !f.exists("recording.wav") && f.exists("recording.m4a"), "\(alert)")
}

// MARK: - The commit's in-place replace

private func writeM4A(seconds: Double, to url: URL) throws {
    let settings: [String: Any] = [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 16_000,
                                   AVNumberOfChannelsKey: 1, AVEncoderBitRateKey: 32_000]
    let file = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
    let count = Int(seconds * 16_000)
    let buffer = try #require(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(count)))
    buffer.frameLength = AVAudioFrameCount(count)
    let channel = try #require(buffer.floatChannelData?[0])
    for index in 0..<count { channel[index] = Float(0.3 * sin(2 * Double.pi * 440 * Double(index) / 16_000)) }
    try file.write(from: buffer)
}

@Test("The copy does not replace a recording.m4a download that changed after it was measured (F1005)")
@MainActor
func shrinkDoesNotReplaceADownloadThatChanged() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("F1005-replace-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    let id = UUID()
    let folder = root.appendingPathComponent("Recordings/\(id.uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let wav = folder.appendingPathComponent("recording.wav"), download = folder.appendingPathComponent("recording.m4a")
    try WAVWriter.wavData(from: (0..<(6 * 48_000)).map { Float(0.3 * sin(2 * Double.pi * 440 * Double($0) / 48_000)) },
                          sampleRate: 48_000).write(to: wav)
    try writeM4A(seconds: 6, to: download)
    try Data("{}".utf8).write(to: folder.appendingPathComponent(MediaSource.sidecarFilename))
    let model = AppModel(store: MeetingStore(rootDirectory: root), recorder: AudioCaptureEngine(),
                         defaults: UserDefaults(suiteName: testSuiteName())!)
    model.trashForShrink = try ShrinkTestTrash(in: root).seam   // F1040: never the real Trash
    model.store.upsert(MeetingRecord(
        id: id, title: "Conference talk", duration: 6,
        recordingPath: "Recordings/\(id.uuidString)/recording.wav", status: .completed, transcriptText: "Hi.",
        recoverySource: RecoveredRecording.Source.importedRecording.rawValue))
    model.availableBytesForShrink = { _ in .max }
    let real = model.encodeForShrink
    model.encodeForShrink = { input, output, working in
        try real(input, output, working)
        try rewriteInPlace(download, byte: 0x55)
    }
    let rewritten = try Data(contentsOf: download).count

    await model.refreshStorage(ids: [id])
    model.requestShrink(ids: [id])
    await model.performShrink(confirmed: true)?.value

    let alert = model.alertMessage ?? "nil"
    #expect((try? Data(contentsOf: download)) == Data(repeating: 0x55, count: rewritten), "the changed download was replaced: \(alert)")
    #expect(FileManager.default.fileExists(atPath: wav.path), "\(alert)")
    #expect(model.store.meeting(id: id)?.recordingPath.hasSuffix("/recording.wav") == true)
    #expect(alert.contains("“recording.m4a” changed while the recording was being compressed"), "\(alert)")
    #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path).filter { $0.hasPrefix(".shrink-") }.isEmpty)
}
