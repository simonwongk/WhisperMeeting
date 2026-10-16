import Foundation
import Testing
@testable import WhisperCore
@testable import WhisperMeet

// F624 — the app half. A meeting whose transcription fails keeps its engine's whole log as
// `transcription-failure.log` beside the recording; the message says so and the failed card offers
// Show Full Log (`transcriptionFailureLogURL(for:)`). The next run removes it first, so a successful
// one leaves none. The run uses the REAL Whisper client with a stub `whisper`, through
// `beginTranscription`, as Stop & Transcribe queues one.

@MainActor
private func waitUntil(_ what: String, _ condition: () -> Bool) async throws {
    let deadline = ContinuousClock.now + .seconds(30)
    while !condition(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
    try #require(condition(), "timed out waiting for \(what)")
}

@MainActor
@Test("A failed transcription keeps the engine's whole log beside the recording, and a later success removes it (F624)")
func aFailedTranscriptionKeepsItsWholeLog() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("F624-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    let id = UUID()
    let folder = root.appendingPathComponent("Recordings/\(id.uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let tone = (0..<16_000).map { Float(0.3 * sin(2 * Double.pi * 440 * Double($0) / 16_000)) }
    let recording = folder.appendingPathComponent("meeting.wav")
    try WAVWriter.wavData(from: tone, sampleRate: 16_000).write(to: recording)
    let whisper = root.appendingPathComponent("whisper")
    let succeed = root.appendingPathComponent("succeed")
    // Fails as openai-whisper usually does — a traceback and exit 0, no JSON — until `succeed` exists.
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

    let model = AppModel(
        store: MeetingStore(rootDirectory: root), recorder: AudioCaptureEngine(),
        defaults: try #require(UserDefaults(suiteName: testSuiteName())),
        whisperExecutable: { whisper }, qwenInstalled: { false }, carryInitialPromptSupport: { _ in true }
    )
    model.selectedEngine = .whisperLarge
    let scratch = root.appendingPathComponent("scratch", isDirectory: true)
    model.engineScratchDirectory = scratch
    model.makeWhisperClient = { executable in
        LocalWhisperClient(executableURL: executable, modelDirectory: root.appendingPathComponent("Models"),
                           scratchDirectory: scratch)
    }
    model.store.upsert(MeetingRecord(id: id, title: "Meeting", duration: 1,
                                     recordingPath: "Recordings/\(id.uuidString)/meeting.wav", status: .recorded))

    model.beginTranscription(id: id)
    try await waitUntil("the meeting to fail") { model.store.meeting(id: id)?.status == .failed }

    let failed = try #require(model.store.meeting(id: id))
    let logURL = try #require(model.transcriptionFailureLogURL(for: failed), "no full log for the failed meeting")
    #expect(logURL == folder.appendingPathComponent("transcription-failure.log"))
    let log = try String(contentsOf: logURL, encoding: .utf8)
    #expect(log.hasPrefix("FIRST LINE of the traceback") && log.hasSuffix("out of memory"), "the log is not whole")
    #expect(failed.errorMessage?.contains(AppModel.transcriptionFailureLogNote) == true, "\(failed.errorMessage ?? "nil")")
    #expect((failed.errorMessage?.count ?? 0) < 5_000, "the stored message is still the capped summary")
    #expect(!(failed.errorMessage?.contains("FIRST LINE") ?? true))

    try Data().write(to: succeed)
    try await waitUntil("the first run to end") { !model.hasActiveTranscription }
    model.beginTranscription(id: id)
    try await waitUntil("the retry to complete") { model.store.meeting(id: id)?.status == .completed }
    #expect(!FileManager.default.fileExists(atPath: logURL.path), "a successful run left the old failure's log")
    #expect(model.transcriptionFailureLogURL(for: try #require(model.store.meeting(id: id))) == nil)
}

@Test("The failed meeting's card offers Show Full Log when a log was kept (F624)")
func theFailedCardOffersTheFullLog() throws {
    let view = try SourceAssertion.uncommentedSource("Sources/WhisperMeet/ContentView.swift")
    #expect(view.contains("if model.transcriptionFailureLogURL(for: meeting) != nil {"))
    #expect(view.contains("Button(\"Show Full Log\") {"))
    #expect(view.contains("model.revealTranscriptionFailureLog(for: meeting.id)"))
}
