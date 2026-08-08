import Foundation
import Testing
@testable import WhisperCore
@testable import WhisperMeet

// F183 — the reachability red-green for link import, per AGENTS.md § "Wiring an unreachable core":
// asserted THROUGH AppModel.importFromURL over a real temp MeetingStore with the download seams stubbed,
// never by calling the core directly.

private final class SeamBox: @unchecked Sendable {
    var probedURL: String?
    var downloadURL: String?
    var captionLangs: String?
}

@MainActor
private func makeModel() throws -> (AppModel, URL) {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("MediaURLImportTests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let defaults = UserDefaults(suiteName: "F183.\(UUID().uuidString)")!
    let model = AppModel(store: MeetingStore(rootDirectory: root), recorder: AudioCaptureEngine(), defaults: defaults)
    model.linkImportEnabled = true // the feature is off by default; these tests opt in explicitly
    return (model, root)
}

/// Stubs a download by writing a tiny real file where the client would have written one.
@MainActor
private func stubSuccessfulDownload(_ model: AppModel, box: SeamBox, probe: MediaProbe) {
    model.probeMediaURL = { url in box.probedURL = url; return probe }
    model.downloadMedia = { url, directory, _ in
        box.downloadURL = url
        let file = directory.appendingPathComponent("recording.wav")
        try Data([0x52, 0x49, 0x46, 0x46]).write(to: file)
        return file
    }
    model.downloadCaptions = { _, _, langs in
        box.captionLangs = langs
        return [TranscriptSegment(speaker: nil, start: 0, end: 2, text: "caption line")]
    }
}

@MainActor
@Test("A link import creates a meeting carrying provenance, the auto tag, and the probed title (F183)")
func linkImportCreatesMeetingWithProvenance() async throws {
    let (model, root) = try makeModel()
    defer { try? FileManager.default.removeItem(at: root) }
    let box = SeamBox()
    stubSuccessfulDownload(model, box: box, probe: MediaProbe(
        title: "Quarterly review", durationSeconds: 600, uploader: "Acme", language: "en"
    ))

    let id = try #require(await model.importFromURL("https://www.youtube.com/watch?v=abc123"))
    let meeting = try #require(model.store.meeting(id: id))

    #expect(meeting.title == "Quarterly review")
    #expect(meeting.source?.isYouTube == true)
    #expect(meeting.source?.videoID == "abc123")
    #expect(meeting.tags == ["YouTube"])                       // provenance mirrored as a tag
    #expect(meeting.referenceSegments?.first?.text == "caption line")
    #expect(box.captionLangs == "en")                          // pinned to the video's own language
    #expect(model.alertMessage == nil)
    // The provenance sidecar is written into the meeting folder before the bytes arrive.
    let sidecar = model.store.recordingDirectoryURL(for: id)
        .appendingPathComponent(MediaSource.sidecarFilename)
    #expect(FileManager.default.fileExists(atPath: sidecar.path))
}

@MainActor
@Test("A failed download leaves no meeting and no orphan directory (F183)")
func failedDownloadLeavesNothingBehind() async throws {
    let (model, root) = try makeModel()
    defer { try? FileManager.default.removeItem(at: root) }
    model.probeMediaURL = { _ in MediaProbe(title: "T", durationSeconds: 60) }
    model.downloadMedia = { _, _, _ in throw MediaDownloadError.missingOutput }

    let id = await model.importFromURL("https://youtu.be/abc")
    #expect(id == nil)
    #expect(model.store.meetings.isEmpty)
    #expect(model.alertMessage != nil)
    let recordings = root.appendingPathComponent("Recordings")
    let leftovers = (try? FileManager.default.contentsOfDirectory(atPath: recordings.path)) ?? []
    #expect(leftovers.isEmpty)
}

@MainActor
@Test("The feature is off by default and refuses until it is enabled (F183)")
func disabledByDefault() async throws {
    let (model, root) = try makeModel()
    defer { try? FileManager.default.removeItem(at: root) }
    model.linkImportEnabled = false
    let box = SeamBox()
    stubSuccessfulDownload(model, box: box, probe: MediaProbe(title: "T", durationSeconds: 60))

    #expect(await model.importFromURL("https://youtu.be/abc") == nil)
    #expect(box.probedURL == nil)              // nothing reached the network
    #expect(model.alertMessage?.contains("Settings") == true)
}

@MainActor
@Test("Playlists, live streams, and bad links are refused before any download (F183)")
func refusesUnsupportedLinks() async throws {
    let (model, root) = try makeModel()
    defer { try? FileManager.default.removeItem(at: root) }
    let box = SeamBox()
    stubSuccessfulDownload(model, box: box, probe: MediaProbe(title: "T", durationSeconds: 60))

    #expect(await model.importFromURL("https://www.youtube.com/playlist?list=PL1") == nil)
    #expect(box.downloadURL == nil)
    #expect(await model.importFromURL("not a url") == nil)
    #expect(box.downloadURL == nil)

    model.probeMediaURL = { _ in MediaProbe(title: "Live", isLive: true) }
    #expect(await model.importFromURL("https://youtu.be/live1") == nil)
    #expect(box.downloadURL == nil)
    #expect(model.alertMessage?.contains("live") == true)
}

@MainActor
@Test("A long video asks for explicit confirmation, then proceeds when confirmed (F183)")
func longMediaRequiresConfirmation() async throws {
    let (model, root) = try makeModel()
    defer { try? FileManager.default.removeItem(at: root) }
    let box = SeamBox()
    stubSuccessfulDownload(model, box: box, probe: MediaProbe(
        title: "Long conference", durationSeconds: 3 * 3_600, language: "en"
    ))

    #expect(await model.importFromURL("https://youtu.be/long1") == nil)
    #expect(box.downloadURL == nil)                            // nothing downloaded yet
    #expect(model.pendingLongMediaConfirmation?.title == "Long conference")

    // Confirming proceeds — the length is a warning, never a cap.
    let id = await model.importFromURL("https://youtu.be/long1", confirmedLongDuration: true)
    #expect(id != nil)
    #expect(box.downloadURL == "https://youtu.be/long1")
    #expect(model.pendingLongMediaConfirmation == nil)
}
