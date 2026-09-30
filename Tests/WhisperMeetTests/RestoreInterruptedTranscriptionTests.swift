import Foundation
import Testing
@testable import WhisperCore
@testable import WhisperMeet

// F610 — restoring into a healthy library leaves a restored `.processing` meeting stuck.
//
// `backUpLibrary` does not refuse while a transcription runs, so a backup can capture a meeting as
// `.processing` (the status is persisted the moment a run starts). The only thing that turns a
// leftover `.processing` into something retryable is `recoverInterruptedTranscriptions()`, and it
// ran only from `performStartupRecovery` — which the restore re-ran only when the library had been
// read-only. On a healthy library the restored meeting kept its spinner, its Cancel did nothing
// (the id is neither pending nor active: the restore refuses to start while any job runs or is
// queued), and Transcribe Again said "already being transcribed" until the app was relaunched.

/// A healthy library whose backup caught meeting X mid-transcription, and which has since moved on:
/// the run finished after the backup, so the live library holds X as `.completed`.
@MainActor
private func makeLibraryWithMidRunBackup(
    _ label: String, transcriptAtBackup: String
) throws -> (root: URL, model: AppModel, generation: URL, id: UUID) {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("RestoreInterrupted-\(label)-\(UUID().uuidString)", isDirectory: true)
    let library = root.appendingPathComponent("Library", isDirectory: true)
    let destination = root.appendingPathComponent("Dest", isDirectory: true)
    try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
    let id = UUID()
    let folder = library.appendingPathComponent("Recordings/\(id.uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    try Data("audio".utf8).write(to: folder.appendingPathComponent("meeting.wav"))
    do {
        let writer = MeetingStore(rootDirectory: library, transcriptWriteDebounce: 3_600)
        writer.upsert(MeetingRecord(
            id: id, title: "Mid-run", recordingPath: "Recordings/\(id.uuidString)/meeting.wav",
            status: .processing, transcriptText: transcriptAtBackup, languageCode: "en"
        ))
    }
    let summary = try BackupCoordinator.backUp(source: library, destination: destination, now: 1, retain: 3)
    let generation = destination
        .appendingPathComponent(BackupCoordinator.managedSubfolder, isDirectory: true)
        .appendingPathComponent(summary.generation, isDirectory: true)

    let model = AppModel(
        store: MeetingStore(rootDirectory: library),
        recorder: AudioCaptureEngine(),
        defaults: UserDefaults(suiteName: "WhisperMeet.RestoreInterrupted.\(UUID().uuidString)")!
    )
    // Startup recovery runs below; nothing in it may spawn an installer from a test.
    model.runWhisperInstallRecovery = { _ in 0 }
    model.runQwenInstallRecovery = { _ in 0 }
    model.runSummarizerInstallRecovery = { _ in 0 }
    model.runDiarizationInstallRecovery = { _ in 0 }
    // The run finished after the backup was taken.
    model.store.update(id: id) {
        $0.status = .completed
        $0.transcriptText = "The finished transcript."
        $0.errorMessage = nil
    }
    return (root, model, generation, id)
}

@Test(
    "Restoring a backup taken mid-transcription into a healthy library leaves the meeting retryable (F610)",
    arguments: [
        // No transcript yet: back to Transcribe, with the interruption named.
        ("", MeetingStatus.recorded),
        // A re-run that was replacing a transcript keeps it (F515).
        ("What was said before the re-run.", MeetingStatus.completed),
    ]
)
@MainActor
func restoreIntoHealthyLibraryUnsticksProcessingMeeting(
    transcriptAtBackup: String, expected: MeetingStatus
) async throws {
    let (root, model, generation, id) = try makeLibraryWithMidRunBackup(
        expected.rawValue, transcriptAtBackup: transcriptAtBackup
    )
    defer { try? FileManager.default.removeItem(at: root) }
    // The launch already happened, on a library it could read.
    await model.performStartupRecovery()
    try #require(!model.store.isDegraded, "precondition: the library is healthy before the restore")
    try #require(model.store.meeting(id: id)?.status == .completed, "precondition: the run finished")

    await model.requestLibraryRestore(from: generation)
    try #require(model.pendingLibraryRestore != nil, "refused: \(model.alertMessage ?? "no message")")
    await model.performLibraryRestore(confirmed: true)?.value
    try #require(!model.store.isDegraded, "the restore left the library read-only: \(model.store.health)")

    let restored = try #require(model.store.meeting(id: id))
    #expect(restored.status == expected, "restored meeting stuck as \(restored.status)")
    #expect(model.transcribeAgainBlockedReason(for: id) == nil, "\(model.transcribeAgainBlockedReason(for: id) ?? "")")
    #expect(restored.transcriptText == transcriptAtBackup, "the restored transcript is the backup's")
}
