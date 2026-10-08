import Foundation
import Testing
@testable import WhisperCore
@testable import WhisperMeet

// F453 part 1 — Stop pressed while a link import fetches its captions was swallowed.
//
// The audio has finished downloading; yt-dlp is now fetching the publisher's captions, which takes
// seconds. The user presses Stop. `MediaDownloadClient.captions` wraps its runner in `try?`, so the
// CancellationError the runner throws for that Stop becomes "no captions" — by design, since a
// caption failure must never fail an import. But `importFromURL` had no cancellation check after
// the caption fetch, so it went on to adopt the recording: it upserted the meeting, started its
// transcription, and returned `.imported(id)`, which the sheet answers by navigating to it. The
// sheet had already closed on Stop, and a meeting the user had just stopped appeared anyway.

private final class CaptionStopBox: @unchecked Sendable {
    var captionsRequested = false
    var transcriptionStarted = false
}

@MainActor
private func makeModel(root: URL, box: CaptionStopBox) -> AppModel {
    // Both engines read as installed (F262's pin), so an adopted import WOULD start transcription:
    // the assertion below cannot pass merely because there was no engine to start.
    let model = AppModel(
        store: MeetingStore(rootDirectory: root),
        recorder: AudioCaptureEngine(),
        defaults: UserDefaults(suiteName: testSuiteName())!,
        whisperExecutable: { URL(fileURLWithPath: "/tmp/whisper-stub") },
        qwenInstalled: { true }
    )
    model.linkImportEnabled = true
    model.runTranscriptionEngineOverride = { _, _ in
        box.transcriptionStarted = true
        throw CancellationError()
    }
    model.probeMediaURL = { _ in
        MediaProbe(title: "Quarterly review", durationSeconds: 600, uploader: "Acme", language: "en")
    }
    model.downloadMedia = { _, directory, _ in
        let file = directory.appendingPathComponent("recording.wav")
        try Data([0x52, 0x49, 0x46, 0x46]).write(to: file)
        return file
    }
    // The Stop lands here. `captions` swallows the CancellationError its runner throws and returns
    // no captions, so this does exactly that: the import's task is cancelled, and `[]` comes back.
    model.downloadCaptions = { _, _, _ in
        box.captionsRequested = true
        withUnsafeCurrentTask { $0?.cancel() }
        return []
    }
    return model
}

@MainActor
@Test("Stop during the caption fetch leaves no meeting, no folder and no transcription (F453)")
func stopDuringCaptionsImportsNothing() async throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("F453-captions-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let box = CaptionStopBox()
    let model = makeModel(root: root, box: box)

    // Its own task, as the sheet's `importTask` is, so the Stop cancels the import and not the test.
    let importTask = Task { @MainActor in
        await model.importFromURL("https://www.youtube.com/watch?v=abc123")
    }
    let outcome = await importTask.value

    // Precondition: the Stop really did land during the caption fetch.
    try #require(box.captionsRequested, "the import never reached its caption fetch")

    #expect(outcome == .cancelled, "the sheet would have navigated to \(String(describing: outcome.meetingID))")
    #expect(model.store.meetings.isEmpty, "a stopped import was added to the library")
    // Asserted directly, not only implied by "no meeting": the engine stub records any run (review of
    // F453 found the meeting-status check alone could not fire, because the stub fails at once).
    #expect(!box.transcriptionStarted, "a stopped import was transcribed")
    if let id = outcome.meetingID {
        #expect(!model.isQueuedForTranscription(id) && model.store.meeting(id: id)?.status != .processing,
                "a stopped import was sent to transcription")
    }
    let recordings = root.appendingPathComponent("Recordings", isDirectory: true)
    let left = (try? FileManager.default.contentsOfDirectory(atPath: recordings.path)) ?? []
    #expect(left.isEmpty, "a stopped import left its folder behind: \(left)")
    #expect(!model.isImporting)
    #expect(model.mediaDownloadProgress == nil)
    #expect(model.alertMessage == nil, "Stop is not a failure: \(model.alertMessage ?? "")")
}

@MainActor
@Test("An import that is not stopped still adopts the recording after its captions (F453)")
func captionsWithoutStopStillImport() async throws {
    // The check must sit after the caption fetch without turning every caption fetch into a cancel.
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("F453-nostop-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let box = CaptionStopBox()
    let model = makeModel(root: root, box: box)
    model.downloadCaptions = { _, _, _ in
        box.captionsRequested = true
        return [TranscriptSegment(speaker: nil, start: 0, end: 2, text: "caption line")]
    }

    let id = try #require(await model.importFromURL("https://www.youtube.com/watch?v=abc123").meetingID)
    #expect(model.store.meeting(id: id)?.referenceSegments?.first?.text == "caption line")
    #expect(model.store.meeting(id: id)?.title == "Quarterly review")
}
