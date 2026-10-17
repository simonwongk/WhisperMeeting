import Foundation
import Testing
@testable import WhisperCore
@testable import WhisperMeet

// F624 — the app half. A meeting whose transcription fails keeps the log its engine kept as
// `transcription-failure.log` in the meeting's own recording folder (`MeetingStore.ownRecordingFolder`);
// the failed card offers Show Full Log (`transcriptionFailureLogURL(for:)`), and says so beside it. The
// next run removes it first, so a successful one leaves none. The run uses the REAL Whisper client with
// a stub `whisper`, through `beginTranscription`, as Stop & Transcribe queues one.
//
// Round 2 (the review of F624): the sentence pointing at the button is said where the button is — on
// the card and in the one-time alert — and never stored in `errorMessage`, where it outlived a log the
// user deleted. And the log goes only in the meeting's OWN folder: a record whose recording sits in
// another folder (which `delete` treats as not its own) gets none, rather than writing into, deleting
// from, or showing another meeting's folder's log.

@MainActor
private func waitUntil(_ what: String, _ condition: () -> Bool) async throws {
    let deadline = ContinuousClock.now + .seconds(30)
    while !condition(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
    try #require(condition(), "timed out waiting for \(what)")
}

/// A library with a stub `whisper` that fails as openai-whisper usually does — a traceback and exit 0,
/// no JSON — until `succeed` exists, and a one-second recording at `Recordings/<folderID>/meeting.wav`.
@MainActor
private struct FailingWhisperRig {
    let root: URL
    let model: AppModel
    let folder: URL
    let succeed: URL

    init(folderID: UUID) throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("F624-\(UUID().uuidString)")
        folder = root.appendingPathComponent("Recordings/\(folderID.uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let tone = (0..<16_000).map { Float(0.3 * sin(2 * Double.pi * 440 * Double($0) / 16_000)) }
        try WAVWriter.wavData(from: tone, sampleRate: 16_000).write(to: folder.appendingPathComponent("meeting.wav"))
        let whisper = root.appendingPathComponent("whisper")
        succeed = root.appendingPathComponent("succeed")
        try """
        #!/bin/zsh
        input="$1"; shift; out=""
        while (( $# > 0 )); do [[ "$1" == "--output_dir" ]] && { out="$2"; shift; }; shift; done
        if [[ -e '\(succeed.path)' ]]; then
          printf '%s' '{"text":" Hello.","language":"en","segments":[{"start":0.0,"end":1.0,"text":" Hello."}]}' > "$out/${input:t:r}.json"
          exit 0
        fi
        print 'FIRST LINE of the traceback'
        for i in {1..2000}; do print 'Downloading: 3%|##      | 30M/1.0G'; done
        print "Skipping $input due to RuntimeError: out of memory"
        """.write(to: whisper, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: whisper.path)

        model = AppModel(
            store: MeetingStore(rootDirectory: root), recorder: AudioCaptureEngine(),
            defaults: try #require(UserDefaults(suiteName: testSuiteName())),
            whisperExecutable: { whisper }, qwenInstalled: { false }, carryInitialPromptSupport: { _ in true }
        )
        model.selectedEngine = .whisperLarge
        let scratch = root.appendingPathComponent("scratch", isDirectory: true)
        model.engineScratchDirectory = scratch
        let models = root.appendingPathComponent("Models")
        model.makeWhisperClient = { executable in
            LocalWhisperClient(executableURL: executable, modelDirectory: models, scratchDirectory: scratch)
        }
    }

    func transcribeUntilFailed(_ id: UUID) async throws -> MeetingRecord {
        model.beginTranscription(id: id)
        try await waitUntil("the meeting to fail") { model.store.meeting(id: id)?.status == .failed }
        try await waitUntil("the run to end") { !model.hasActiveTranscription }
        return try #require(model.store.meeting(id: id))
    }
}

@MainActor
@Test("A failed transcription keeps its engine's log in the meeting's folder, says so where it is shown, and a later success removes it (F624)")
func aFailedTranscriptionKeepsItsWholeLog() async throws {
    let id = UUID()
    let rig = try FailingWhisperRig(folderID: id)
    defer { try? FileManager.default.removeItem(at: rig.root) }
    rig.model.store.upsert(MeetingRecord(id: id, title: "Meeting", duration: 1,
                                         recordingPath: "Recordings/\(id.uuidString)/meeting.wav", status: .recorded))

    let failed = try await rig.transcribeUntilFailed(id)

    let logURL = try #require(rig.model.transcriptionFailureLogURL(for: failed), "no full log for the failed meeting")
    #expect(logURL == rig.folder.appendingPathComponent("transcription-failure.log"))
    let log = try String(contentsOf: logURL, encoding: .utf8)
    #expect(log.hasPrefix("FIRST LINE of the traceback") && log.hasSuffix("out of memory"), "the log is not whole")
    // Said in the alert, which is shown once, and not stored: the card says it beside the button.
    #expect(rig.model.alertMessage?.contains(AppModel.transcriptionFailureLogNote) == true, "\(rig.model.alertMessage ?? "nil")")
    #expect(failed.errorMessage?.contains(AppModel.transcriptionFailureLogNote) == false, "\(failed.errorMessage ?? "nil")")
    #expect((failed.errorMessage?.count ?? 0) < 5_000, "the stored message is still the capped summary")
    #expect(!(failed.errorMessage?.contains("FIRST LINE") ?? true))

    // A log the user removes takes the button with it; nothing stored still points at it.
    try FileManager.default.removeItem(at: logURL)
    #expect(rig.model.transcriptionFailureLogURL(for: failed) == nil)
    #expect(TranscriptionFailureLog.write("again", to: logURL))

    try Data().write(to: rig.succeed)
    rig.model.beginTranscription(id: id)
    try await waitUntil("the retry to complete") { rig.model.store.meeting(id: id)?.status == .completed }
    #expect(!FileManager.default.fileExists(atPath: logURL.path), "a successful run left the old failure's log")
    #expect(rig.model.transcriptionFailureLogURL(for: try #require(rig.model.store.meeting(id: id))) == nil)
}

@MainActor
@Test("A meeting whose recording is in another meeting's folder gets no log there, and never shows that folder's (F624)")
func aRecordingOutsideItsOwnFolderGetsNoLog() async throws {
    // The record's recording sits in a folder named for ANOTHER id: not its own folder, as `delete`
    // judges (`ownRecordingFolder` is nil), so the log has nowhere that is the meeting's own.
    let id = UUID(), otherID = UUID()
    let rig = try FailingWhisperRig(folderID: otherID)
    defer { try? FileManager.default.removeItem(at: rig.root) }
    let foreignLog = rig.folder.appendingPathComponent("transcription-failure.log")
    try Data("the other meeting's log".utf8).write(to: foreignLog)
    rig.model.store.upsert(MeetingRecord(id: id, title: "Stray", duration: 1,
                                         recordingPath: "Recordings/\(otherID.uuidString)/meeting.wav", status: .recorded))

    let failed = try await rig.transcribeUntilFailed(id)

    #expect(rig.model.transcriptionFailureLogURL(for: failed) == nil, "a meeting showed a log from a folder that is not its own")
    #expect(try String(contentsOf: foreignLog, encoding: .utf8) == "the other meeting's log",
            "the run replaced or removed a log in another meeting's folder")
    #expect(rig.model.alertMessage?.contains(AppModel.transcriptionFailureLogNote) == false)
}

@Test("The failed meeting's card offers Show Full Log, and says so beside it, only when a log was kept (F624)")
func theFailedCardOffersTheFullLog() throws {
    let view = try SourceAssertion.uncommentedSource("Sources/WhisperMeet/ContentView.swift")
    #expect(view.contains("if model.transcriptionFailureLogURL(for: meeting) != nil {\n                                Text(AppModel.transcriptionFailureLogNote)"))
    #expect(view.contains("Button(\"Show Full Log\") {"))
    #expect(view.contains("model.revealTranscriptionFailureLog(for: meeting.id)"))
}
