import Foundation
import Testing
@testable import WhisperCore

/// F533 — the real-installed-model half of splitting long recordings.
///
/// `WhisperPiecesTests` drives a stub `whisper`, which is right for the cut, the offsets and the
/// arguments but cannot catch upstream drift: whether the installed openai-whisper accepts a piece,
/// honours the pinned `--language`, and what its own times look like once joined. This runs the
/// **installed** runtime (`LocalWhisperRuntime.findExecutable()`, the app's model folder, the real
/// `ffmpeg`) twice over the same ~2-minute fixture built from `Scripts/bench/clips`, never a user
/// recording: once with the piece bound lowered to 50 s so it splits in three, once whole.
///
/// Opt-in, because it loads Whisper weights and takes minutes on the CPU:
///
/// ```
/// WHISPERMEET_REAL_WHISPER_PIECES=1 \
/// WHISPERMEET_BENCH_CLIPS=/path/to/Scripts/bench/clips \     # optional; the clips are gitignored
/// WHISPERMEET_REAL_WHISPER_MODEL=turbo \                     # or large; turbo by default
/// WHISPERMEET_REAL_WHISPER_REPORT=/path/to/report.txt \      # optional; where the comparison goes
/// swift test --disable-sandbox --no-parallel --filter realWhisperSplitsAndJoinsLikeOnePass
/// ```
private enum RealWhisperPieces {
    static let environment = ProcessInfo.processInfo.environment

    static var isEnabled: Bool { environment["WHISPERMEET_REAL_WHISPER_PIECES"] == "1" }

    static var clipsDirectory: URL {
        if let path = environment["WHISPERMEET_BENCH_CLIPS"] { return URL(fileURLWithPath: path, isDirectory: true) }
        return URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // WhisperCoreTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // repo root
            .appendingPathComponent("Scripts/bench/clips", isDirectory: true)
    }

    static var model: WhisperModel { environment["WHISPERMEET_REAL_WHISPER_MODEL"] == "large" ? .large : .turbo }

    /// en1–en4, each followed by 0.7 s of silence — a pause between sentences — repeated to at least
    /// 120 s. 16 kHz 16-bit mono, as the clips are.
    static func makeFixture(at url: URL) throws -> Double {
        var pcm = Data()
        var rate: UInt32 = 0
        for name in ["en1", "en2", "en3", "en4"] {
            let clip = clipsDirectory.appendingPathComponent("\(name).wav")
            let header = try #require(WAVInspection.header(at: clip), "\(clip.path) is not a readable WAV")
            try #require(header.channels == 1 && header.bitsPerSample == 16, "\(name) is not 16-bit mono")
            rate = header.sampleRate
            let bytes = try Data(contentsOf: clip)
            let start = Int(header.dataOffset)
            pcm += bytes.subdata(in: start..<min(bytes.count, start + Int(header.declaredDataBytes)))
            pcm += Data(count: Int(rate) * 7 / 10 * 2)
        }
        let target = Int(rate) * 2 * 120
        var audio = Data()
        while audio.count < target { audio += pcm }
        var wav = WAVWriter.header(sampleRate: rate, dataByteCount: UInt32(audio.count))
        wav += audio
        try wav.write(to: url)
        return Double(audio.count) / 2 / Double(rate)
    }
}

@Test(
    "The installed Whisper transcribes a long recording in pieces and joins it like one pass (F533)",
    .enabled(if: RealWhisperPieces.isEnabled)
)
func realWhisperSplitsAndJoinsLikeOnePass() async throws {
    let whisper = try #require(LocalWhisperRuntime.findExecutable(), "no installed whisper")
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("RealWhisperPieces-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let recording = directory.appendingPathComponent("longform-en-2min.wav")
    let seconds = try RealWhisperPieces.makeFixture(at: recording)

    // A wrapper that logs each run's arguments and its peak memory, then runs the real CLI.
    let log = directory.appendingPathComponent("runs.log")
    let wrapper = directory.appendingPathComponent("whisper")
    try Data("""
    #!/bin/zsh
    { print -r -- "---"; printf '%s\\n' "$@"; } >> "\(log.path)"
    exec /usr/bin/time -a -o "\(log.path)" -l "\(whisper.path)" "$@"
    """.utf8).write(to: wrapper)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: wrapper.path)

    func run(_ policy: WhisperPiecePolicy) async throws -> (TranscriptionResult, String, TimeInterval) {
        try? FileManager.default.removeItem(at: log)
        let client = LocalWhisperClient(
            executableURL: wrapper, modelDirectory: LocalWhisperRuntime.modelDirectory(), piecePolicy: policy,
            scratchDirectory: directory.appendingPathComponent("scratch") // F937: not the real $TMPDIR
        )
        let started = Date()
        let result = try await client.transcribe(
            recordingAt: recording, options: .accuracyFirst(model: RealWhisperPieces.model, language: .automatic)
        )
        return (result, try String(contentsOf: log, encoding: .utf8), Date().timeIntervalSince(started))
    }

    let (pieces, piecesLog, piecesWall) = try await run(WhisperPiecePolicy(maximumPieceSeconds: 50, quietSearchSeconds: 5))
    let (whole, wholeLog, wholeWall) = try await run(.standard)

    func runs(_ log: String) -> [String] { log.components(separatedBy: "---\n").filter { !$0.isEmpty } }
    func render(_ result: TranscriptionResult) -> String {
        result.segments.map { segment in
            String(format: "%7.2f–%7.2f  ", segment.start ?? -1, segment.end ?? -1) + segment.text
        }.joined(separator: "\n")
    }
    let report = """
    F533 real-model run — openai-whisper \(RealWhisperPieces.model.rawValue), \(whisper.path)
    fixture: \(recording.lastPathComponent), \(String(format: "%.2f", seconds)) s (en1–en4 + 0.7 s pauses, repeated)

    == IN PIECES (bound 50 s, search ±5 s): \(runs(piecesLog).count) whisper runs, \(String(format: "%.1f", piecesWall)) s wall
    language: \(pieces.languageCode ?? "nil"), audioDuration: \(pieces.audioDuration.map { String($0) } ?? "nil")
    \(render(pieces))

    text: \(pieces.text)

    == ONE PASS (standard policy): \(runs(wholeLog).count) whisper run, \(String(format: "%.1f", wholeWall)) s wall
    language: \(whole.languageCode ?? "nil"), audioDuration: \(whole.audioDuration.map { String($0) } ?? "nil")
    \(render(whole))

    text: \(whole.text)

    == RUN LOGS (arguments, then /usr/bin/time -l)
    -- pieces
    \(piecesLog)
    -- one pass
    \(wholeLog)
    """
    FileHandle.standardError.write(Data((report + "\n").utf8))
    if let path = RealWhisperPieces.environment["WHISPERMEET_REAL_WHISPER_REPORT"] {
        try report.write(toFile: path, atomically: true, encoding: .utf8)
    }

    let pieceRuns = runs(piecesLog)
    #expect(pieceRuns.count == 3)
    #expect(runs(wholeLog).count == 1)
    #expect(!pieceRuns[0].contains("--language\n"), "the first piece must detect")
    #expect(pieceRuns.dropFirst().allSatisfy { $0.contains("--language\nen\n") }, "later pieces must be pinned to it")
    #expect(pieces.languageCode == "en" && whole.languageCode == "en")
    let starts = pieces.segments.compactMap(\.start)
    #expect(zip(starts, starts.dropFirst()).allSatisfy { $0 <= $1 }, "segments out of order")
    #expect(pieces.segments.compactMap(\.end).allSatisfy { $0 <= seconds + 0.5 })
    #expect((pieces.audioDuration ?? 0) > seconds - 10, "the joined transcript stops short of the recording")
}
