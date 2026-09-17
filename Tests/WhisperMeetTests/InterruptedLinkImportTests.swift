import Foundation
import Testing
@testable import WhisperCore
@testable import WhisperMeet

// F311 — a link import that died before any audio arrived warned on every launch, forever.
//
// `importFromURL` writes `source.json` into the folder *before* the download starts, deliberately,
// "so a crash mid-download still leaves a recoverable link import". But yt-dlp writes
// `recording.<ext>.part` until it finishes, and `importedRecordingCandidate` does not match a
// `.part`. So if the app dies in that window the folder holds `source.json` and maybe a `.part`:
// `recover` finds no audio, the imported-candidate branch does not fire, `removeIfEmpty` refuses
// because the folder is not empty, and the loop falls through to "…did not contain enough audio to
// rebuild a WAV." Nothing about the folder changes, so it says so again on the next launch.
//
// The ticket was filed from reading the code and said so — "traced through the code, not reproduced
// by a run; reproduce it before fixing". `theWarningRepeatsOnEveryLaunch` is that reproduction, and
// it ran red before the fix for the stated reason rather than an assumed one.

@MainActor
private func makeModel(root: URL, suite: String) -> AppModel {
    AppModel(
        store: MeetingStore(rootDirectory: root),
        recorder: AudioCaptureEngine(),
        defaults: UserDefaults(suiteName: suite)!
    )
}

/// A folder as a crash mid-download leaves it: the sidecar, and optionally the partial file.
private func makeInterruptedDownload(in root: URL, withPartFile: Bool) throws -> (UUID, MediaSource) {
    let id = UUID()
    let folder = root.appendingPathComponent("Recordings/\(id.uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let source = MediaSource(
        kind: MediaSource.webKind,
        pageURL: "https://example.com/watch?v=abc123",
        host: "example.com",
        videoID: "abc123",
        uploader: "Example Channel",
        fetchedAt: Date(timeIntervalSince1970: 1_700_000_000)
    )
    try JSONEncoder().encode(source)
        .write(to: folder.appendingPathComponent(MediaSource.sidecarFilename))
    if withPartFile {
        // What yt-dlp leaves behind, and what `importedRecordingCandidate` will not match.
        try Data("partial bytes".utf8).write(to: folder.appendingPathComponent("recording.m4a.part"))
    }
    return (id, source)
}

@MainActor
@Test("A crashed link import is indexed once instead of warning on every launch (F311)")
func theWarningRepeatsOnEveryLaunch() async throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("InterruptedLink-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let (id, _) = try makeInterruptedDownload(in: root, withPartFile: true)

    let suite = "F311.\(UUID().uuidString)"
    defer { UserDefaults().removePersistentDomain(forName: suite) }
    let model = makeModel(root: root, suite: suite)

    await model.performStartupRecovery()
    let first = model.alertMessage
    #expect(first != nil, "the first launch should say something about it")

    // The second launch is the whole defect: `orphanedRecordings()` skips folders whose UUID is
    // indexed, so an indexed entry ends the repetition — and nothing indexed it.
    model.alertMessage = nil
    let second = makeModel(root: root, suite: suite)
    await second.performStartupRecovery()
    #expect(
        second.alertMessage == nil,
        "the same folder warned again on a second launch, and would forever: \(second.alertMessage ?? "")"
    )
    #expect(
        second.store.meeting(id: id) != nil,
        "it should have been indexed once, which is what stops the repetition"
    )
}

@MainActor
@Test("The interrupted import keeps the link, which is the only copy of it (F311)")
func theInterruptedImportKeepsItsLink() async throws {
    // The reason to index rather than delete. `source.json` is written before the download
    // precisely so the URL survives a crash — the user has it nowhere else, and the sidecar's own
    // comment promises the folder is "recoverable as a link import rather than an anonymous orphan
    // folder". Deleting it after one message would break that promise to save a directory.
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("InterruptedLinkKeep-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let (id, source) = try makeInterruptedDownload(in: root, withPartFile: false)

    let suite = "F311.keep.\(UUID().uuidString)"
    defer { UserDefaults().removePersistentDomain(forName: suite) }
    let model = makeModel(root: root, suite: suite)
    await model.performStartupRecovery()

    let meeting = try #require(model.store.meeting(id: id))
    #expect(meeting.status == .failed, "there is no audio, so it is not a playable meeting")
    #expect(meeting.source?.pageURL == source.pageURL, "the link is the thing worth keeping")
    #expect(meeting.title.contains("example.com"), "say which link it was: \(meeting.title)")
    #expect(meeting.errorMessage?.isEmpty == false, "and why it needs attention")
}

@MainActor
@Test("A capture folder with no audio is still not indexed (F311)")
func aCaptureFolderWithNoAudioIsUntouched() async throws {
    // The guard on the fix. This branch must fire only for a link import — a capture folder that
    // failed to produce audio has no `source.json`, nothing to retry, and no URL worth keeping, so
    // it keeps today's behaviour rather than gaining a permanent `.failed` row.
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("InterruptedCapture-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let id = UUID()
    let folder = root.appendingPathComponent("Recordings/\(id.uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    // Not empty, not audio, and no sidecar: `removeIfEmpty` refuses and there is nothing to index.
    try Data("stray".utf8).write(to: folder.appendingPathComponent("notes.txt"))

    let suite = "F311.capture.\(UUID().uuidString)"
    defer { UserDefaults().removePersistentDomain(forName: suite) }
    let model = makeModel(root: root, suite: suite)
    await model.performStartupRecovery()

    #expect(model.store.meeting(id: id) == nil, "a capture folder with no audio must not be indexed")
    #expect(model.alertMessage?.contains("did not contain enough audio") == true)
}
