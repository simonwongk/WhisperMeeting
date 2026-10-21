import Foundation
import Testing
@testable import WhisperCore
@testable import WhisperMeet

// F533 — the app half. `executeEngine` builds its Whisper client through `makeWhisperClient`, so a
// meeting queued the way Stop & Transcribe queues one (`beginTranscription`) runs the REAL client,
// whose splitting is what is under test. `runTranscriptionEngineOverride` would replace the client
// and could not see it. The client gets a stub `whisper`, a stub `ffmpeg`, a scratch folder and a
// four-second piece, so a ten-second fixture stands in for a multi-hour meeting.

@MainActor
private func waitUntil(_ what: String, _ condition: () -> Bool) async throws {
    let deadline = SuspendingClock.now + .seconds(60)
    while !condition(), SuspendingClock.now < deadline {
        try await Task.sleep(nanoseconds: 5_000_000)
    }
    try #require(condition(), "timed out waiting for \(what)")
}

private func writeExecutable(_ url: URL, _ script: String) throws {
    try Data(script.utf8).write(to: url)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
}

@MainActor
@Test("A long meeting is transcribed by Whisper in pieces and the joined transcript lands on it (F533)")
func longMeetingIsTranscribedInPiecesThroughTheApp() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("F533-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    let id = UUID()
    let folder = root.appendingPathComponent("Recordings/\(id.uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let scratch = root.appendingPathComponent("scratch", isDirectory: true)
    try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)

    // Ten seconds of a 440 Hz tone at 16 kHz, silent at 3.0–3.2 s and 6.4–6.6 s.
    let rate = 16_000
    let samples: [Int16] = (0..<(10 * rate)).map { index in
        let seconds = Double(index) / Double(rate)
        if (3.0..<3.2).contains(seconds) || (6.4..<6.6).contains(seconds) { return 0 }
        return Int16(clampedAudioSample: Float(0.37 * sin(2 * Double.pi * 440 * seconds)))
    }
    var wav = WAVWriter.header(sampleRate: UInt32(rate), dataByteCount: UInt32(samples.count * 2))
    samples.withUnsafeBufferPointer { wav.append(Data(buffer: $0)) }
    let recording = folder.appendingPathComponent("meeting.wav")
    try wav.write(to: recording)

    let log = root.appendingPathComponent("whisper.log")
    let whisper = root.appendingPathComponent("whisper")
    try writeExecutable(whisper, #"""
    #!/bin/zsh
    set -euo pipefail
    audio="$1"
    shift
    { print -r -- "---"; print -r -- "$audio"; printf '%s\n' "$@"; } >> "\#(log.path)"
    name="${audio:t:r}"
    output_dir=""; language=""
    while (( $# > 0 )); do
      case "$1" in
        --output_dir) output_dir="$2"; shift ;;
        --language) language="$2"; shift ;;
      esac
      shift
    done
    number="${name##*-}"
    [[ -n "$language" ]] || language="zh"
    printf '{"text":" piece %s","language":"%s","segments":[{"start":0.5,"end":1.0,"text":" piece %s"}]}' \
      "$number" "$language" "$number" > "$output_dir/${name}.json"
    """#)
    let ffmpeg = root.appendingPathComponent("ffmpeg")
    try writeExecutable(ffmpeg, #"""
    #!/bin/zsh
    set -euo pipefail
    input=""; previous=""
    for argument in "$@"; do
      [[ "$previous" == "-i" ]] && input="$argument"
      previous="$argument"
    done
    tail -c +45 "$input" > "${@[-1]}"
    """#)

    let defaults = try #require(UserDefaults(suiteName: testSuiteName()))
    let model = AppModel(
        store: MeetingStore(rootDirectory: root), recorder: AudioCaptureEngine(), defaults: defaults,
        whisperExecutable: { whisper }, qwenInstalled: { false }, carryInitialPromptSupport: { _ in true }
    )
    model.selectedEngine = .whisperLarge
    model.selectedLanguage = .automatic
    let models = root.appendingPathComponent("Models", isDirectory: true)
    model.makeWhisperClient = { executable in
        LocalWhisperClient(
            executableURL: executable, modelDirectory: models,
            piecePolicy: WhisperPiecePolicy(maximumPieceSeconds: 4, quietSearchSeconds: 0.5),
            ffmpegExecutableURL: ffmpeg, scratchDirectory: scratch
        )
    }
    model.store.upsert(MeetingRecord(
        id: id, title: "A long workshop", duration: 10,
        recordingPath: "Recordings/\(id.uuidString)/meeting.wav", status: .recorded
    ))

    model.beginTranscription(id: id)
    try await waitUntil("the meeting to finish transcribing") {
        let status = model.store.meeting(id: id)?.status
        return status == .completed || status == .failed
    }

    let meeting = try #require(model.store.meeting(id: id))
    #expect(meeting.status == .completed, "\(meeting.errorMessage ?? "")")
    let runs = try String(contentsOf: log, encoding: .utf8).components(separatedBy: "---\n").filter { !$0.isEmpty }
    #expect(runs.count == 3, "whisper ran \(runs.count) time(s)")
    #expect(meeting.segments.map(\.text) == ["piece 1", "piece 2", "piece 3"])
    let starts = meeting.segments.map(\.start)
    #expect(starts == [0.5, 3.65, 7.05])
    #expect(meeting.languageCode == "zh")
    #expect(meeting.requestedLanguage == WhisperLanguage.automatic.rawValue)
    #expect(meeting.transcriptionEngine == .whisperLarge)
    #expect(try Data(contentsOf: recording) == wav, "the recording is the source of truth")
    #expect(try FileManager.default.contentsOfDirectory(atPath: scratch.path).isEmpty)
}

@MainActor
@Test("The app's own Whisper client splits at the standard 45-minute bound (F533)")
func appWhisperClientUsesTheStandardPolicy() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("F533-policy-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    let defaults = try #require(UserDefaults(suiteName: testSuiteName()))
    let model = AppModel(
        store: MeetingStore(rootDirectory: root), recorder: AudioCaptureEngine(), defaults: defaults,
        whisperExecutable: { nil }, qwenInstalled: { false }
    )
    #expect(model.makeWhisperClient(URL(fileURLWithPath: "/usr/bin/true")).piecePolicy == .standard)
    #expect(WhisperPiecePolicy.standard.maximumPieceSeconds == 45 * 60)
}
