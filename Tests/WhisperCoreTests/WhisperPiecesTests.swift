import Foundation
import Testing
@testable import WhisperCore

// F533 — Whisper Large used to get the whole multi-hour WAV in one call, and openai-whisper builds
// the log-mel spectrogram of the ENTIRE file before decoding starts (`transcribe.py:139`,
// `mel = log_mel_spectrogram(audio, model.dims.n_mels, padding=N_SAMPLES)`), about 3 GB an hour on
// top of the weights. The user's decision (2026-10-08): a recording over ~45 minutes is transcribed
// in pieces of at most 45 minutes, cut at quiet moments, with the times offset and joined.
//
// The pure parts — where to cut, how to offset and join, how progress maps — are tested directly.
// The client is tested end to end with a stub `whisper` and a stub `ffmpeg`, so the pieces it writes
// and the arguments it passes are observed rather than assumed.

private let rate = WhisperPiecePlanner.sampleRate
private let frame = WhisperPiecePlanner.frameSamples

/// A 10-second profile at the planner's 100 ms frames: loud everywhere, silent in `quiet`.
private func energies(frames count: Int, quiet: Set<Int> = []) -> [Double] {
    (0..<count).map { quiet.contains($0) ? 0 : 1 }
}

/// Four-second pieces searched ±0.5 s: small enough that a ten-second fixture splits in three.
private let smallPolicy = WhisperPiecePolicy(maximumPieceSeconds: 4, quietSearchSeconds: 0.5)

// MARK: - Cut planning

@Test("A recording no longer than the bound stays one piece (F533)")
func recordingWithinTheBoundIsOnePiece() {
    let total = 4 * rate
    #expect(WhisperPiecePlanner.pieces(totalSamples: total, frameEnergies: energies(frames: 40), policy: smallPolicy)
        == [0..<total])
}

@Test("A long recording is cut at the quietest moment near each target, never past the bound (F533)")
func longRecordingIsCutAtQuietMoments() {
    // Targets for 10 s at a 4 s bound: three pieces, the first aimed at 3.33 s and the second at
    // 6.58 s. The silent frames 30–31 (3.0–3.2 s) and 64–65 (6.4–6.6 s) are inside the ±0.5 s
    // windows; of each silent pair the cut takes the frame centre nearer its target.
    let pieces = WhisperPiecePlanner.pieces(
        totalSamples: 10 * rate, frameEnergies: energies(frames: 100, quiet: [30, 31, 64, 65]), policy: smallPolicy
    )
    let expected: [Range<Int>] = [0..<50_400, 50_400..<104_800, 104_800..<160_000]
    #expect(pieces == expected)
}

@Test("With no quiet moment the cut is a hard one, and still no piece is longer than the bound (F533)")
func noQuietMomentStillHonoursTheBound() {
    let bound = 4 * rate
    let cases: [(profile: [Double], policy: WhisperPiecePolicy, count: Int?)] = [
        (energies(frames: 100), smallPolicy, 3),
        ([], smallPolicy, 3),                                                          // no profile at all
        (energies(frames: 100), WhisperPiecePolicy(maximumPieceSeconds: 4, quietSearchSeconds: 30), nil),  // a window wider than a piece
    ]
    for (profile, policy, count) in cases {
        let pieces = WhisperPiecePlanner.pieces(totalSamples: 10 * rate, frameEnergies: profile, policy: policy)
        if let count { #expect(pieces.count == count, "\(pieces)") }
        #expect(pieces.allSatisfy { $0.count <= bound && !$0.isEmpty }, "\(pieces)")
        #expect(pieces.first?.lowerBound == 0 && pieces.last?.upperBound == 10 * rate)
        #expect(zip(pieces, pieces.dropFirst()).allSatisfy { $0.upperBound == $1.lowerBound }, "a gap or an overlap: \(pieces)")
    }
}

@Test("A quiet moment just past the bound is never taken, though it is in a search window (F533)")
func quietMomentPastTheBoundIsNeverTaken() {
    // 7.9 s at a 4 s bound, searched ±0.5 s. The only silent frames are 42–43 (4.2–4.4 s): past the
    // bound, but within ±0.5 s of 3.95 s, where a two-piece split would aim. The planner aims low
    // enough that its whole search window fits under the bound, and clips the window at the bound
    // besides. With neither, the cut lands at 4.25 s and the first piece is longer than the bound
    // (the lane L review's mutant M1: `[0..<68000, 68000..<126400]`).
    let pieces = WhisperPiecePlanner.pieces(
        totalSamples: 79 * frame, frameEnergies: energies(frames: 79, quiet: [42, 43]), policy: smallPolicy
    )
    #expect(pieces.allSatisfy { $0.count <= 4 * rate }, "\(pieces)")
    #expect(pieces.first?.lowerBound == 0 && pieces.last?.upperBound == 79 * frame)
}

@Test("Three hours at the standard policy is five pieces of 30 to 45 minutes (F533)")
func threeHoursAtTheStandardPolicy() {
    let total = 3 * 3_600 * rate
    let pieces = WhisperPiecePlanner.pieces(
        totalSamples: total, frameEnergies: energies(frames: total / frame), policy: .standard
    )
    #expect(pieces.count == 5, "\(pieces.map { Double($0.count) / Double(rate) / 60 })")
    #expect(pieces.allSatisfy { $0.count >= 30 * 60 * rate && $0.count <= 45 * 60 * rate })
    #expect(pieces.last?.upperBound == total)
}

// MARK: - Energy profile

@Test("The energy profile is the same however the decoded bytes arrive (F533)")
func energyProfileIgnoresChunkBoundaries() {
    // One full frame at half scale (mean square 0.25), then a partial frame of silence and one sample.
    var samples = [Int16](repeating: 16_384, count: frame)
    samples += [Int16](repeating: 0, count: 99)
    samples.append(-32_768)
    let bytes = samples.withUnsafeBufferPointer { Data(buffer: $0) }

    var whole = WhisperAudioEnergy()
    whole.consume(bytes)
    var split = WhisperAudioEnergy()
    split.consume(bytes.prefix(3))           // ends mid-sample
    split.consume(bytes.dropFirst(3).prefix(1_001))
    split.consume(bytes.dropFirst(1_004))

    #expect(whole.sampleCount == frame + 100)
    #expect(split.sampleCount == whole.sampleCount)
    let expected: [Double] = [0.25, 1.0 / 100]
    #expect(whole.frameEnergies() == expected)
    #expect(split.frameEnergies() == expected)
}

// MARK: - What the app holds while it reads the decode

// `FileHandle.read(upToCount:)` returns each chunk in an autoreleased buffer. A loop that never
// drains a pool keeps every chunk it has read until the job that called it ends. The lane L review
// (R1) measured `measure` holding +346,489,072 bytes after reading a 345,600,000-byte decode, so the
// app held the whole decode beside every Whisper process. Each test reads a dense 64 MiB file
// through ONE direct call and checks what the call left held (`heldMemory`): the current footprint,
// and the bytes malloc has allocated, which an earlier test cannot mask (`FootprintMeasurement.swift`).
// Holding every chunk is the whole 64 MiB in both; one chunk at a time is about 1 MiB.

@Test("Measuring the decoded recording holds one chunk of it at a time, not all of it (F533)")
func measuringTheDecodeHoldsOneChunkAtATime() throws {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("F533-measure-\(UUID().uuidString).s16le")
    defer { try? FileManager.default.removeItem(at: url) }
    try writeDenseFile(at: url, mebibytes: 64, seed: 533)

    var energy = WhisperAudioEnergy()
    let held = try heldMemory { energy = try WhisperPieceAudio.measure(url) }

    #expect(energy.sampleCount == (64 << 20) / 2)
    #expect(held.allocated < 16 << 20, "measuring a 64 MiB decode left \(held) held")
    #expect(held.footprint < 16 << 20, "measuring a 64 MiB decode left \(held) held")
}

@Test("Writing a piece holds one chunk of the decode at a time, not all of it (F533)")
func writingAPieceHoldsOneChunkAtATime() throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("F533-piece-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let decoded = directory.appendingPathComponent("whispermeet-decoded.s16le")
    let piece = directory.appendingPathComponent("whispermeet-piece-1.wav")
    try writeDenseFile(at: decoded, mebibytes: 64, seed: 534)

    let held = try heldMemory {
        try WhisperPieceAudio.writePiece(0..<((64 << 20) / 2), from: decoded, to: piece)
    }

    // Mapped, so the comparison itself holds nothing.
    let written = try Data(contentsOf: piece, options: .alwaysMapped)
    #expect(written.count == 44 + (64 << 20))
    #expect(written.dropFirst(44) == (try Data(contentsOf: decoded, options: .alwaysMapped)), "the piece is its slice, byte for byte")
    #expect(held.allocated < 16 << 20, "writing a 64 MiB piece left \(held) held")
    #expect(held.footprint < 16 << 20, "writing a 64 MiB piece left \(held) held")
}

// MARK: - Joining

private func segment(_ text: String, _ start: Double, _ end: Double) -> TranscriptSegment {
    TranscriptSegment(speaker: nil, start: start, end: end, text: text)
}

@Test("Joined pieces carry the recording's own times, in order, with the first piece's language (F533)")
func joinOffsetsTimesAndKeepsOrder() throws {
    let result = try WhisperPieceJoin.join([
        (0, WhisperPieceTranscript(text: " First part.", language: "en",
                                   segments: [segment("First part.", 0.5, 2)])),
        (2_700, WhisperPieceTranscript(text: "", language: "en", segments: [])),   // a silent piece
        (5_400.25, WhisperPieceTranscript(text: " Second part. Third.", language: "en",
                                          segments: [segment("Second part.", 0, 1.5), segment("Third.", 1.5, 3)])),
    ], id: "meeting.wav")

    #expect(result.id == "meeting.wav")
    #expect(result.text == "First part. Second part. Third.")
    #expect(result.languageCode == "en")
    let starts = result.segments.map(\.start)
    let ends = result.segments.map(\.end)
    #expect(starts == [0.5, 5_400.25, 5_401.75])
    #expect(ends == [2, 5_401.75, 5_403.25])
    #expect(result.segments.map(\.text) == ["First part.", "Second part.", "Third."])
    #expect(result.audioDuration == 5_403.25)
}

@Test("Pieces join with no space between two Chinese characters and a space anywhere else (F533)")
func joinFollowsTheQwenHelpersBoundaryRule() throws {
    func text(_ parts: [String]) throws -> String {
        try WhisperPieceJoin.join(parts.enumerated().map { index, part in
            (Double(index) * 10, WhisperPieceTranscript(text: part, language: "zh", segments: [segment(part, 0, 1)]))
        }, id: "x").text
    }
    #expect(try text(["我们开会。", "下午三点。"]) == "我们开会。下午三点。")
    #expect(try text(["我们的 deadline", "是周五。"]) == "我们的 deadline 是周五。")
    #expect(try text(["客户", "wants it"]) == "客户 wants it")
}

@Test("Pieces that are all silent are no speech, exactly as one silent pass is (F533)")
func allSilentPiecesAreNoSpeech() {
    #expect(throws: LocalWhisperError.emptyTranscript) {
        try WhisperPieceJoin.join([
            (0, WhisperPieceTranscript(text: " ", language: "en", segments: [])),
            (2_700, WhisperPieceTranscript(text: "", language: "en", segments: [])),
        ], id: "meeting.wav")
    }
}

@Test("A piece's segment times are clamped to the piece's own length (F533)")
func pieceTranscriptIsClampedToItsLength() {
    // A 3.15 s piece: one segment inside it, one Whisper ended in the padding after its last
    // sample, and one that starts there too.
    let clamped = WhisperPieceTranscript(text: " a b c", language: "en", segments: [
        segment("Inside.", 0.5, 2), segment("Ends past the cut.", 2.9, 3.6), segment("In the padding.", 3.3, 3.8),
    ]).clamped(toSeconds: 3.15)

    let starts: [Double?] = clamped.segments.map(\.start)
    let ends: [Double?] = clamped.segments.map(\.end)
    let expectedStarts: [Double?] = [0.5, 2.9, 3.15]
    let expectedEnds: [Double?] = [2, 3.15, 3.15]
    #expect(starts == expectedStarts)
    #expect(ends == expectedEnds)
    #expect(clamped.segments.map(\.text) == ["Inside.", "Ends past the cut.", "In the padding."], "no text is dropped")
    #expect(clamped.text == " a b c" && clamped.language == "en")
}

// MARK: - Progress

@Test("A piece's progress is reported as progress through the whole recording (F533)")
func pieceProgressMapsToTheWholeRecording() {
    let pieces: [Range<Int>] = [0..<40, 40..<70, 70..<100]
    let halfway = WhisperPieceProgress.overall(
        LocalTranscriptionProgress(phase: .transcribing, fractionCompleted: 0.5, estimatedSecondsRemaining: 10),
        pieceIndex: 1, pieces: pieces
    )
    #expect(halfway.phase == .transcribing)
    #expect(halfway.fractionCompleted == 0.55)
    // 15 units left in this piece took 10 s, so the 45 units left in the recording take 30 s.
    #expect(halfway.estimatedSecondsRemaining == 30)

    let download = LocalTranscriptionProgress(phase: .downloadingModel, fractionCompleted: 0.3)
    #expect(WhisperPieceProgress.overall(download, pieceIndex: 0, pieces: pieces) == download)
}

@Test("A later piece's model load is progress at that piece's start, never loading again (F533)")
func laterPieceLoadIsProgressAtItsStart() {
    let pieces: [Range<Int>] = [0..<40, 40..<70, 70..<100]
    for progress in [LocalTranscriptionProgress.loadingModel, .preparing] {
        let mapped = WhisperPieceProgress.overall(progress, pieceIndex: 1, pieces: pieces)
        #expect(mapped.phase == .transcribing, "\(progress.phase)")
        #expect(mapped.fractionCompleted == 0.4, "\(progress.phase)")
    }
    // The first piece's load is the run's own, and is shown as what it is.
    #expect(WhisperPieceProgress.overall(.loadingModel, pieceIndex: 0, pieces: pieces) == .loadingModel)
}

// MARK: - The client, end to end with stubs

/// A stub `whisper` that logs its arguments and how many piece files sit beside the audio it is
/// given, copies that audio to `captured/` (unless `copiesAudio` is false), and writes the JSON
/// openai-whisper would: piece N says "piece N" at 0.5–1.0 s of its own time, in the language it was
/// pinned to, or "zh" when it had to detect one.
private struct PieceFixture {
    let directory: URL
    let whisper: URL
    let ffmpeg: URL
    let recording: URL
    let models: URL
    let scratch: URL
    let captured: URL
    let invocationLog: URL
    let ffmpegLog: URL
    /// One line per whisper run: how many piece files sat beside the audio it was given.
    let pieceCountLog: URL

    /// `copiesAudio: false` keeps the stub from copying its input to `captured/`, for a sparse
    /// 45-minute file a copy would make dense. `overrunEnds: true` ends each piece's segment a
    /// second past the piece's own length, as a timestamp the model put in the padding would.
    init(
        failPiece: Int? = nil, hangPiece: Int? = nil, ffmpegFails: Bool = false,
        recordingName: String = "meeting.wav", copiesAudio: Bool = true, overrunEnds: Bool = false
    ) throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("WhisperPiecesTests-\(UUID().uuidString)", isDirectory: true)
        whisper = directory.appendingPathComponent("whisper")
        ffmpeg = directory.appendingPathComponent("ffmpeg")
        recording = directory.appendingPathComponent(recordingName)
        models = directory.appendingPathComponent("Models", isDirectory: true)
        scratch = directory.appendingPathComponent("scratch", isDirectory: true)
        captured = directory.appendingPathComponent("captured", isDirectory: true)
        invocationLog = directory.appendingPathComponent("whisper.log")
        ffmpegLog = directory.appendingPathComponent("ffmpeg.log")
        pieceCountLog = directory.appendingPathComponent("pieces.log")
        try FileManager.default.createDirectory(at: captured, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)

        let fail = failPiece.map(String.init) ?? "none"
        let hang = hangPiece.map(String.init) ?? "none"
        try writeExecutable(whisper, #"""
        #!/bin/zsh
        set -euo pipefail
        audio="$1"
        shift
        { print -r -- "---"; print -r -- "$audio"; printf '%s\n' "$@"; } >> "\#(invocationLog.path)"
        pieces=( "${audio:h}"/whispermeet-piece-*.wav(N) )
        print -r -- "${#pieces}" >> "\#(pieceCountLog.path)"
        name="${audio:t:r}"
        \#(copiesAudio ? "cp \"$audio\" \"\(captured.path)/${name}.wav\"" : ": no copy")
        output_dir=""; language=""
        while (( $# > 0 )); do
          case "$1" in
            --output_dir) output_dir="$2"; shift ;;
            --language) language="$2"; shift ;;
          esac
          shift
        done
        number="${name##*-}"
        [[ "$number" == <-> ]] || number=0
        if [[ "$number" == "\#(hang)" ]]; then touch "\#(directory.path)/hung"; exec sleep 120; fi
        if [[ "$number" == "\#(fail)" ]]; then print "Skipping $audio due to RuntimeError: out of memory"; exit 0; fi
        print -r -- " 50%|#####     | 50/100 [00:01<00:01, 50.00frames/s]"
        print -r -- "100%|##########| 100/100 [00:02<00:00, 50.00frames/s]"
        [[ -n "$language" ]] || language="zh"
        end="1.0"
        \#(overrunEnds ? #"end=$(( ($(stat -f %z "$audio") - 44) / 32000.0 + 1.0 ))"# : ": ends at 1.0")
        printf '{"text":" piece %s","language":"%s","segments":[{"start":0.5,"end":%s,"text":" piece %s"}]}' \
          "$number" "$language" "$end" "$number" > "$output_dir/${name}.json"
        """#)
        // Stands in for ffmpeg's decode to 16 kHz mono s16le: the fixture is already that, behind a
        // canonical 44-byte header, so the decode is the bytes after it.
        try writeExecutable(ffmpeg, #"""
        #!/bin/zsh
        set -euo pipefail
        printf '%s\n' "$@" >> "\#(ffmpegLog.path)"
        \#(ffmpegFails ? "print -u2 'Invalid data found when processing input'; exit 1" : "")
        input=""; previous=""
        for argument in "$@"; do
          [[ "$previous" == "-i" ]] && input="$argument"
          previous="$argument"
        done
        tail -c +45 "$input" > "${@[-1]}"
        """#)
    }

    func remove() { try? FileManager.default.removeItem(at: directory) }

    func client(policy: WhisperPiecePolicy = smallPolicy) -> LocalWhisperClient {
        LocalWhisperClient(
            executableURL: whisper, modelDirectory: models, piecePolicy: policy,
            ffmpegExecutableURL: ffmpeg, scratchDirectory: scratch
        )
    }

    /// Each whisper run's audio path followed by its arguments.
    func invocations() throws -> [[String]] {
        guard FileManager.default.fileExists(atPath: invocationLog.path) else { return [] }
        return try String(contentsOf: invocationLog, encoding: .utf8)
            .components(separatedBy: "---\n")
            .filter { !$0.isEmpty }
            .map { $0.split(separator: "\n", omittingEmptySubsequences: false).map(String.init).filter { !$0.isEmpty } }
    }

    func scratchIsEmpty() throws -> Bool {
        try FileManager.default.contentsOfDirectory(atPath: scratch.path).isEmpty
    }

    /// For each whisper run in order, how many piece files sat beside the audio it was given.
    func pieceFilesBesideEachRun() throws -> [Int] {
        guard FileManager.default.fileExists(atPath: pieceCountLog.path) else { return [] }
        return try String(contentsOf: pieceCountLog, encoding: .utf8).split(separator: "\n").compactMap { Int($0) }
    }
}

private func writeExecutable(_ url: URL, _ script: String) throws {
    try Data(script.utf8).write(to: url)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
}

/// Ten seconds of 16 kHz 16-bit mono: a 440 Hz tone, silent at 3.0–3.2 s and 6.4–6.6 s — the quiet
/// moments `longRecordingIsCutAtQuietMoments` cuts at.
private func tenSecondSamples() -> [Int16] {
    (0..<(10 * rate)).map { index in
        let seconds = Double(index) / Double(rate)
        if (3.0..<3.2).contains(seconds) || (6.4..<6.6).contains(seconds) { return 0 }
        return Int16(clampedAudioSample: Float(0.37 * sin(2 * Double.pi * 440 * seconds)))
    }
}

private func writeWAV(_ samples: [Int16], to url: URL) throws {
    var data = WAVWriter.header(sampleRate: UInt32(rate), dataByteCount: UInt32(samples.count * 2))
    samples.withUnsafeBufferPointer { data.append(Data(buffer: $0)) }
    try data.write(to: url)
}

private func pcm(of url: URL) throws -> Data {
    try Data(contentsOf: url).dropFirst(44)
}

private extension Array where Element == String {
    func has(_ pair: [String]) -> Bool {
        indices.dropLast(pair.count - 1).contains { Array(self[$0..<($0 + pair.count)]) == pair }
    }
}

@Test("A long recording is transcribed in pieces cut at its quiet moments and joined on its own clock (F533)")
func longRecordingIsTranscribedInPieces() async throws {
    let fixture = try PieceFixture()
    defer { fixture.remove() }
    let samples = tenSecondSamples()
    try writeWAV(samples, to: fixture.recording)
    let original = try Data(contentsOf: fixture.recording)

    let result = try await fixture.client().transcribe(
        recordingAt: fixture.recording,
        options: .accuracyFirst(model: .large, language: .automatic, keyterms: ["WhisperMeet"])
    )

    let runs = try fixture.invocations()
    try #require(runs.count == 3, "whisper ran \(runs.count) time(s); a ten-second recording at a four-second bound is three pieces")
    // Each piece is exactly its slice of the recording — no sample lost, repeated or resampled.
    let whole = samples.withUnsafeBufferPointer { Data(buffer: $0) }
    let cuts = [0, 50_400, 104_800, 160_000]
    for index in 0..<3 {
        let piece = try pcm(of: fixture.captured.appendingPathComponent("whispermeet-piece-\(index + 1).wav"))
        #expect(piece == whole.subdata(in: (cuts[index] * 2)..<(cuts[index + 1] * 2)), "piece \(index + 1)")
    }
    // The language is detected once, from the start of the recording, as one pass does — then pinned.
    #expect(!runs[0].contains("--language"))
    #expect(runs[1].has(["--language", "zh"]) && runs[2].has(["--language", "zh"]))
    for run in runs {
        #expect(run.has(["--model", "large"]) && run.has(["--task", "transcribe"]))
        #expect(run.has(["--initial_prompt", "WhisperMeet"]) && run.has(["--carry_initial_prompt", "True"]))
    }

    #expect(result.text == "piece 1 piece 2 piece 3")
    #expect(result.languageCode == "zh")
    let starts = result.segments.map(\.start)
    let ends = result.segments.map(\.end)
    #expect(starts == [0.5, 3.65, 7.05])
    #expect(ends == [1.0, 4.15, 7.55])
    #expect(result.audioDuration == 7.55)
    // One piece file on disk at a time: each is removed before the next is written (the review's
    // M7 kept them all, and the run folder grew by a piece per run).
    let pieceFilesPresent = try fixture.pieceFilesBesideEachRun()
    let onePieceAtATime: [Int] = [1, 1, 1]
    #expect(pieceFilesPresent == onePieceAtATime)
    #expect(try fixture.scratchIsEmpty(), "the pieces and the decoded audio must not outlive the run")
    #expect(try Data(contentsOf: fixture.recording) == original, "the recording is the source of truth")
}

@Test("A pinned language and Turbo reach every piece (F533)")
func pinnedLanguageAndTurboReachEveryPiece() async throws {
    let fixture = try PieceFixture()
    defer { fixture.remove() }
    try writeWAV(tenSecondSamples(), to: fixture.recording)

    let result = try await fixture.client().transcribe(
        recordingAt: fixture.recording, options: .accuracyFirst(model: .turbo, language: .english)
    )

    let runs = try fixture.invocations()
    try #require(runs.count == 3, "whisper ran \(runs.count) time(s)")
    #expect(runs.allSatisfy { $0.has(["--language", "English"]) && $0.has(["--model", "turbo"]) })
    #expect(runs.allSatisfy { !$0.contains("--initial_prompt") })
    #expect(result.languageCode == "en")
}

@Test("A recording within the bound is still one Whisper call on the original file, with no decode (F533)")
func shortRecordingIsUnchanged() async throws {
    let fixture = try PieceFixture()
    defer { fixture.remove() }
    try writeWAV(Array(tenSecondSamples().prefix(3 * rate)), to: fixture.recording)

    _ = try await fixture.client().transcribe(recordingAt: fixture.recording, options: .accuracyFirst())

    let runs = try fixture.invocations()
    #expect(runs.count == 1)
    #expect(runs.first?.first == fixture.recording.path)
    #expect(!FileManager.default.fileExists(atPath: fixture.ffmpegLog.path), "a short WAV needs no decode to be measured")
}

@Test("A WAV of exactly 45 minutes is one pass on the original, with no decode (F533)")
func exactlyTheBoundIsOnePassWithNoDecode() async throws {
    let fixture = try PieceFixture(copiesAudio: false)
    defer { fixture.remove() }
    // Sparse: 45 minutes of 16 kHz 16-bit mono is 86.4 MB, of which only the header is on disk.
    let bytes = UInt64(45 * 60 * rate * 2)
    try WAVWriter.header(sampleRate: UInt32(rate), dataByteCount64: bytes).write(to: fixture.recording)
    let handle = try FileHandle(forWritingTo: fixture.recording)
    try handle.truncate(atOffset: 44 + bytes)
    try handle.close()

    _ = try await fixture.client(policy: .standard).transcribe(recordingAt: fixture.recording, options: .accuracyFirst())

    let runs = try fixture.invocations()
    #expect(runs.count == 1)
    #expect(runs.first?.first == fixture.recording.path)
    // At most the bound is one piece, and the header says so without a decode (the review's M6
    // decoded a WAV of exactly 45:00 by testing `<` where it means `<=`).
    #expect(!FileManager.default.fileExists(atPath: fixture.ffmpegLog.path), "a 45:00 WAV needs no decode")
}

@Test("A recording whose length the header cannot tell is decoded to measure it, and a short one runs whole (F533)")
func nonWAVRecordingIsMeasuredByDecoding() async throws {
    let fixture = try PieceFixture(recordingName: "meeting.m4a")
    defer { fixture.remove() }
    // The stub "decodes" by dropping 44 bytes, so the stand-in container is 44 bytes of something
    // that is not a RIFF header (an MP4 `ftyp` box's start) followed by the PCM.
    var container = Data(repeating: 0x20, count: 44)
    container.replaceSubrange(4..<8, with: Data("ftyp".utf8))
    Array(tenSecondSamples().prefix(3 * rate)).withUnsafeBufferPointer { container.append(Data(buffer: $0)) }
    try container.write(to: fixture.recording)

    _ = try await fixture.client().transcribe(recordingAt: fixture.recording, options: .accuracyFirst())

    let decode = try String(contentsOf: fixture.ffmpegLog, encoding: .utf8).split(separator: "\n").map(String.init)
    // openai-whisper's own `load_audio` decode (`audio.py:45-55`), so the pieces hold the samples one
    // pass would have seen.
    #expect(decode.has(["-nostdin", "-threads", "0", "-i", fixture.recording.path, "-f", "s16le", "-ac", "1",
                        "-acodec", "pcm_s16le", "-ar", "16000"]))
    let runs = try fixture.invocations()
    #expect(runs.count == 1)
    #expect(runs.first?.first == fixture.recording.path)
    #expect(try fixture.scratchIsEmpty())
}

// F903: a `.wav` whose header `WAVInspection` cannot read (only a disk import can be one) was handed to
// Whisper whole, however long — F533's memory problem kept for it. It is decoded and measured like a
// container that is not a WAV, and cut into pieces when it is over the bound.
@Test("A long .wav whose header cannot be read is decoded, measured and transcribed in pieces (F903)")
func unreadableHeaderWAVIsTranscribedInPieces() async throws {
    let fixture = try PieceFixture()
    defer { fixture.remove() }
    // 44 bytes WAVInspection cannot read (no RIFF/RF64 magic), then ten seconds of the PCM the stub
    // "decodes" by dropping them: over the small policy's bound.
    var container = Data(repeating: 0x20, count: 44)
    container.replaceSubrange(0..<4, with: Data("RIFX".utf8))
    tenSecondSamples().withUnsafeBufferPointer { container.append(Data(buffer: $0)) }
    try container.write(to: fixture.recording)
    #expect(WAVInspection.header(at: fixture.recording) == nil, "precondition: the header is unreadable")

    let result = try await fixture.client().transcribe(recordingAt: fixture.recording, options: .accuracyFirst())

    #expect(FileManager.default.fileExists(atPath: fixture.ffmpegLog.path), "the recording was not decoded to be measured")
    let runs = try fixture.invocations()
    #expect(runs.count > 1, "a ten-second recording over a shorter bound ran as \(runs.count) Whisper call(s)")
    #expect(!runs.contains { $0.first == fixture.recording.path }, "Whisper was handed the whole recording")
    #expect(result.segments.count == runs.count)
    #expect(try fixture.scratchIsEmpty())
}

@Test("A piece that fails fails the whole transcription; no partial transcript comes back (F533)")
func failedPieceFailsTheWhole() async throws {
    let fixture = try PieceFixture(failPiece: 2)
    defer { fixture.remove() }
    try writeWAV(tenSecondSamples(), to: fixture.recording)

    do {
        let result = try await fixture.client().transcribe(recordingAt: fixture.recording, options: .accuracyFirst())
        Issue.record("a transcript came back with a piece missing: \(result.text)")
    } catch let LocalWhisperError.processFailed(message) {
        #expect(message.contains("out of memory"), "\(message)")
    }
    #expect(try fixture.invocations().count == 2, "nothing runs after the failed piece")
    #expect(try fixture.scratchIsEmpty())
}

@Test("A recording that cannot be decoded for splitting fails clearly before Whisper starts (F533)")
func undecodableRecordingFailsBeforeWhisper() async throws {
    let fixture = try PieceFixture(ffmpegFails: true)
    defer { fixture.remove() }
    try writeWAV(tenSecondSamples(), to: fixture.recording)

    do {
        _ = try await fixture.client().transcribe(recordingAt: fixture.recording, options: .accuracyFirst())
        Issue.record("expected the decode failure to throw")
    } catch let LocalWhisperError.processFailed(message) {
        #expect(message.contains("Invalid data found when processing input"), "\(message)")
    }
    #expect(try fixture.invocations().isEmpty)
    #expect(try fixture.scratchIsEmpty())
}

@Test("Cancelling a piece while it runs stops the run, and no later piece starts (F533)")
func cancellingAPieceStopsTheRun() async throws {
    let fixture = try PieceFixture(hangPiece: 2)
    defer { fixture.remove() }
    try writeWAV(tenSecondSamples(), to: fixture.recording)
    let client = fixture.client()
    let recording = fixture.recording
    let task = Task { try await client.transcribe(recordingAt: recording, options: .accuracyFirst()) }

    let hung = fixture.directory.appendingPathComponent("hung")
    var waited = 0
    while !FileManager.default.fileExists(atPath: hung.path), waited < 600 {
        try await Task.sleep(for: .milliseconds(50))
        waited += 1
    }
    try #require(FileManager.default.fileExists(atPath: hung.path), "piece 2 never started")
    task.cancel()

    await #expect(throws: CancellationError.self) { try await task.value }
    #expect(try fixture.invocations().count == 2)
    #expect(try fixture.scratchIsEmpty())
}

private final class ProgressLog: @unchecked Sendable {
    private let lock = NSLock()
    private var entries: [LocalTranscriptionProgress] = []
    func append(_ progress: LocalTranscriptionProgress) { lock.withLock { entries.append(progress) } }
    var snapshot: [LocalTranscriptionProgress] { lock.withLock { entries } }
}

@Test("Progress across pieces only moves forward and ends at the whole recording (F533)")
func progressAcrossPiecesMovesForward() async throws {
    let fixture = try PieceFixture()
    defer { fixture.remove() }
    try writeWAV(tenSecondSamples(), to: fixture.recording)
    let log = ProgressLog()

    _ = try await fixture.client().transcribe(recordingAt: fixture.recording, options: .accuracyFirst()) { progress in
        log.append(progress)
    }

    let fractions = log.snapshot.filter { $0.phase == .transcribing }.compactMap(\.fractionCompleted)
    #expect(zip(fractions, fractions.dropFirst()).allSatisfy { $0 <= $1 }, "progress went backwards: \(fractions)")
    // Once the bar is moving it never goes back to an indeterminate Loading or Preparing, though each
    // later piece's own process loads the model again.
    let phases = log.snapshot.map(\.phase)
    let firstTranscribing = try #require(phases.firstIndex(of: .transcribing))
    #expect(!phases[firstTranscribing...].contains { $0 == .loadingModel || $0 == .preparing },
            "the bar went back to indeterminate between pieces: \(phases)")
    // Each piece's own 100% is where it ends in the recording: 3.15 s, 6.55 s and 10 s of 10. (Its
    // 50% line may arrive in the same read as its 100% one, and then only the newer is reported.)
    for end in [0.315, 0.655, 1.0] {
        #expect(fractions.contains { abs($0 - end) < 0.000_1 }, "no \(end) in \(fractions)")
    }
    #expect(fractions.last == 1)
}

@Test("A segment Whisper ends in a piece's padding is clamped to the cut, so pieces never overlap at a join (F533)")
func pieceTimesNeverOverlapAtAJoin() async throws {
    let fixture = try PieceFixture(overrunEnds: true)
    defer { fixture.remove() }
    try writeWAV(tenSecondSamples(), to: fixture.recording)

    let result = try await fixture.client().transcribe(recordingAt: fixture.recording, options: .accuracyFirst())

    // The stub ends each piece's one segment a second past that piece: 4.15 s into a 3.15 s piece.
    // Clamped, each ends where its piece does on the recording's clock: 3.15, 6.55 and 10 s.
    let starts = result.segments.compactMap(\.start)
    let ends = result.segments.compactMap(\.end)
    try #require(ends.count == 3, "\(result.segments)")
    for (end, cut) in zip(ends, [3.15, 6.55, 10.0]) {
        #expect(abs(end - cut) < 0.000_001, "ends \(ends)")
    }
    #expect(zip(ends, starts.dropFirst()).allSatisfy { $0 <= $1 }, "a segment overlaps the next piece's: ends \(ends), starts \(starts)")
    #expect(result.audioDuration.map { abs($0 - 10) < 0.000_001 } == true, "\(String(describing: result.audioDuration))")
}

// MARK: - Run folders a crash left behind

/// Above macOS's `PID_MAX` (99,999), so no process can have it: the run folder of a process that has
/// certainly exited. PID 1, launchd, is a process that certainly exists and is not this one.
private let exitedProcess: pid_t = 99_999_999

@Test("Only a run folder whose process has exited is swept, never one in use or named or linked like one (F533)")
func onlyAbandonedRunFoldersAreSwept() throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("F533-sweep-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    func makeFolder(_ name: String) throws {
        let folder = directory.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data("decoded audio".utf8).write(to: folder.appendingPathComponent("whispermeet-decoded.s16le"))
    }
    let abandoned = LocalWhisperClient.runFolderName(processID: exitedProcess)
    try makeFolder(abandoned)
    let kept = [
        LocalWhisperClient.runFolderName(),                                    // this process: a run may still be going
        LocalWhisperClient.runFolderName(processID: 1),                        // launchd: exists, and is not ours to signal
        "WhisperMeet-\(UUID().uuidString)",                                    // the name run folders had before
        "WhisperMeet-Qwen-\(UUID().uuidString)",                               // another feature's
        "WhisperMeet-Whisper-\(exitedProcess)-not-a-uuid",
        "WhisperMeet-Whisper-0\(exitedProcess)-\(UUID().uuidString)",          // a leading zero: not a name we make
        "WhisperMeet-Whisper-\(exitedProcess)-\(UUID().uuidString.lowercased())",
    ]
    for name in kept { try makeFolder(name) }
    // A file, and a link to a folder, each named exactly like an abandoned run folder.
    let file = LocalWhisperClient.runFolderName(processID: exitedProcess)
    try Data("not a folder".utf8).write(to: directory.appendingPathComponent(file))
    let target = directory.appendingPathComponent("target", isDirectory: true)
    try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
    try Data("keep".utf8).write(to: target.appendingPathComponent("keep.txt"))
    let link = LocalWhisperClient.runFolderName(processID: exitedProcess)
    try FileManager.default.createSymbolicLink(
        atPath: directory.appendingPathComponent(link).path, withDestinationPath: target.path
    )

    let removed = LocalWhisperClient.removeAbandonedRunFolders(in: directory)

    #expect(removed == [abandoned])
    let left = Set(try FileManager.default.contentsOfDirectory(atPath: directory.path))
    #expect(left == Set(kept + [file, link, "target"]))
    #expect(FileManager.default.fileExists(atPath: target.appendingPathComponent("keep.txt").path), "a link is never followed")
}

@Test("A transcription first removes a run folder a crashed run left, and keeps one in use (F533)")
func transcriptionSweepsAbandonedRunFolders() async throws {
    let fixture = try PieceFixture()
    defer { fixture.remove() }
    try writeWAV(Array(tenSecondSamples().prefix(3 * rate)), to: fixture.recording)
    let abandoned = fixture.scratch.appendingPathComponent(LocalWhisperClient.runFolderName(processID: exitedProcess))
    let inUse = fixture.scratch.appendingPathComponent(LocalWhisperClient.runFolderName(processID: 1))
    for folder in [abandoned, inUse] {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data(count: 4_096).write(to: folder.appendingPathComponent("whispermeet-decoded.s16le"))
    }

    _ = try await fixture.client().transcribe(recordingAt: fixture.recording, options: .accuracyFirst())

    #expect(!FileManager.default.fileExists(atPath: abandoned.path), "a crashed run's folder outlived the next run")
    #expect(try FileManager.default.contentsOfDirectory(atPath: fixture.scratch.path) == [inUse.lastPathComponent])
    // The run's own folder carries this process's ID, so a later run can tell when it is abandoned.
    let run = try #require(try fixture.invocations().first)
    let outputIndex = try #require(run.firstIndex(of: "--output_dir"))
    let outputFolder = URL(fileURLWithPath: run[outputIndex + 1]).lastPathComponent
    #expect(LocalWhisperClient.runFolderOwner(outputFolder) == getpid(), "\(outputFolder)")
}
