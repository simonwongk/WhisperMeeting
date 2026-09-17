import Foundation
import Testing
@testable import WhisperCore
@testable import WhisperMeet

// F308 — a link import writes `source.json` into its folder before the download starts, "so a
// crash mid-download still leaves a recoverable link import". Nothing read it back: none of the
// upserts in `performStartupRecovery`'s orphan loop passed `source:`, so the recovered meeting was
// an audio file of unknown origin with the answer sitting beside it.
//
// Every test drives the real recovery rather than building a record, because the defect was in
// which arguments the call sites passed — F303's lesson, in the same loop.

private let kestrelSource = MediaSource(
    kind: MediaSource.youTubeKind,
    pageURL: "https://www.youtube.com/watch?v=kestrel42",
    host: "youtube.com",
    videoID: "kestrel42",
    uploader: "Fairhaven Talks",
    fetchedAt: Date(timeIntervalSince1970: 1_758_000_000)
)

/// An orphaned import folder holding `recording.<ext>` with the given bytes, and optionally a
/// sidecar. Returns the recovered model and the folder's id.
@MainActor
private func recoverImportFolder(
    named: String, recording: Data, fileExtension: String, sidecar: Data?
) async throws -> (AppModel, UUID, URL) {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("\(named)-\(UUID().uuidString)", isDirectory: true)
    let id = UUID()
    let folder = root.appendingPathComponent("Recordings/\(id.uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    try recording.write(to: folder.appendingPathComponent("recording.\(fileExtension)"))
    if let sidecar {
        try sidecar.write(to: folder.appendingPathComponent(MediaSource.sidecarFilename))
    }
    let model = AppModel(
        store: MeetingStore(rootDirectory: root),
        recorder: AudioCaptureEngine(),
        defaults: UserDefaults(suiteName: "F308.\(UUID().uuidString)")!
    )
    await model.performStartupRecovery()
    return (model, id, root)
}

private func playableWAV() -> Data {
    WAVWriter.wavData(from: [Float](repeating: 0.1, count: 48_000), sampleRate: 48_000)   // 1s
}

@MainActor
@Test("A recovered link import comes back with where it came from, and its tag (F308)")
func recoveredLinkImportKeepsItsSource() async throws {
    let (model, id, root) = try await recoverImportFolder(
        named: "LinkImport", recording: playableWAV(), fileExtension: "wav",
        sidecar: try JSONEncoder().encode(kestrelSource)
    )
    defer { try? FileManager.default.removeItem(at: root) }

    let meeting = try #require(model.store.meeting(id: id))
    #expect(meeting.status != .failed, "a playable file is the ordinary recovered branch")
    #expect(meeting.source == kestrelSource)
    // The tag is how link imports are found in the sidebar, and the normal import path derives it
    // from the source alone — so a recovery that has the source has everything it needs.
    #expect(meeting.tags == ["YouTube"])
    // The recovery's own facts are not displaced by the provenance.
    #expect(meeting.recoverySource == RecoveredRecording.Source.importedRecording.rawValue)
    #expect(meeting.title.hasPrefix("Recovered Meeting"))
}

@MainActor
@Test("An unverifiable recovered link import keeps its source too (F308)")
func unverifiableLinkImportKeepsItsSource() async throws {
    // The `.failed` sibling. It is the one where the URL matters most: the file cannot be played,
    // so the link is the only way back to the audio.
    let (model, id, root) = try await recoverImportFolder(
        named: "LinkImportUnverified", recording: Data("not audio, but not empty".utf8),
        fileExtension: "m4a", sidecar: try JSONEncoder().encode(kestrelSource)
    )
    defer { try? FileManager.default.removeItem(at: root) }

    let meeting = try #require(model.store.meeting(id: id))
    #expect(meeting.status == .failed)
    #expect(meeting.source == kestrelSource)
    #expect(meeting.tags == ["YouTube"])
}

@MainActor
@Test("An empty recovered link import keeps its source too (F308)")
func emptyLinkImportKeepsItsSource() async throws {
    // The `guard let recovered else` branch — the one F273 missed and F303 had to come back for,
    // because it has no `RecoveredRecording` in scope and reads as a different kind of place.
    let (model, id, root) = try await recoverImportFolder(
        named: "LinkImportEmpty", recording: Data(), fileExtension: "m4a",
        sidecar: try JSONEncoder().encode(kestrelSource)
    )
    defer { try? FileManager.default.removeItem(at: root) }

    let meeting = try #require(model.store.meeting(id: id))
    #expect(meeting.status == .failed)
    #expect(meeting.source == kestrelSource)
    #expect(meeting.tags == ["YouTube"])
}

@MainActor
@Test("A recovered import with no sidecar recovers exactly as before (F308)")
func importWithoutSidecarIsUnchanged() async throws {
    let (model, id, root) = try await recoverImportFolder(
        named: "FileImport", recording: playableWAV(), fileExtension: "wav", sidecar: nil
    )
    defer { try? FileManager.default.removeItem(at: root) }

    let meeting = try #require(model.store.meeting(id: id))
    #expect(meeting.status != .failed)
    #expect(meeting.source == nil)
    #expect((meeting.tags ?? []).isEmpty, "no source, so no invented provenance tag")
    #expect(meeting.recoverySource == RecoveredRecording.Source.importedRecording.rawValue)
}

@MainActor
@Test("A corrupt sidecar costs the provenance and nothing else (F308)")
func corruptSidecarStillRecoversTheAudio() async throws {
    let (model, id, root) = try await recoverImportFolder(
        named: "LinkImportCorrupt", recording: playableWAV(), fileExtension: "wav",
        sidecar: Data("{ \"kind\": ".utf8)
    )
    defer { try? FileManager.default.removeItem(at: root) }

    let meeting = try #require(model.store.meeting(id: id), "the audio recovery must not depend on the sidecar")
    #expect(meeting.status != .failed)
    #expect(meeting.duration > 0.9)
    #expect(meeting.source == nil)
}
