import Foundation

/// Where the pinned speaker-analysis runtime lives on disk, and the settings it is always run with
/// (F219). The layout mirrors `QwenASRRuntime`: a self-contained tree under the app's managed
/// Runtime directory, so uninstalling is a single `rm -rf` and a partial install is detectable.
public struct DiarizationRuntime: Sendable {
    /// 0.3, not the runtime's 0.5 default. Measured on the F217 corpus: 0.5 merges two same-gender
    /// speakers into one cluster, which reads as a confident wrong label rather than as ambiguity.
    public static let clusterThreshold = 0.3

    /// Segmentation and embedding each get four threads — enough to stay well under real time on
    /// Apple silicon without starving the UI while a meeting is open.
    public static let numThreads = 4

    /// Turns below this per-turn confidence are marked `.uncertain` instead of `.speech`.
    ///
    /// Deliberately 0 — the number was not earned. A 0.50 floor does separate wholly-misattributed
    /// turns from correct ones *per turn*, but scored on what a reader actually sees (rows that
    /// survive `SpeakerOverlay`'s 80%/20-point rule) the overlay already abstains on exactly those
    /// rows: 100% displayed precision at 93.3% coverage without the floor, versus 100% at 86.7%
    /// with it. It costs coverage and buys no precision. F217's benchmark may revise this only with
    /// a documented before/after table.
    public static let uncertainBelowConfidence = 0.0

    public static func managedDirectory(applicationSupport: URL? = nil) -> URL {
        LocalWhisperRuntime.managedDirectory(applicationSupport: applicationSupport)
            .appendingPathComponent("Diarization", isDirectory: true)
    }

    public static func executable(applicationSupport: URL? = nil) -> URL {
        managedDirectory(applicationSupport: applicationSupport)
            .appendingPathComponent("bin/sherpa-onnx-offline-speaker-diarization")
    }

    public static func segmentationModel(applicationSupport: URL? = nil) -> URL {
        managedDirectory(applicationSupport: applicationSupport)
            .appendingPathComponent("models/segmentation/model.onnx")
    }

    public static func embeddingModel(applicationSupport: URL? = nil) -> URL {
        managedDirectory(applicationSupport: applicationSupport)
            .appendingPathComponent("models/embedding/campplus_zh_en.onnx")
    }

    /// Every required file, probed on the filesystem. An interrupted install leaves the directory
    /// present but incomplete, so "the folder exists" is never the question asked — the same lesson
    /// `QwenASRRuntime.isInstalled` and `LocalWhisperRuntime.mlxModelCached` encode.
    public static func isInstalled(applicationSupport: URL? = nil) -> Bool {
        let files = FileManager.default
        return files.isExecutableFile(
            atPath: executable(applicationSupport: applicationSupport).path
        )
            && files.fileExists(
                atPath: segmentationModel(applicationSupport: applicationSupport).path
            )
            && files.fileExists(
                atPath: embeddingModel(applicationSupport: applicationSupport).path
            )
    }
}

/// One completed analysis. Anonymous by construction: intervals and a count, never a name, an
/// embedding, or anything derived from the transcript (F219).
public struct SpeakerDiarizationResult: Sendable, Equatable {
    public let turns: [SpeakerTurn]
    public let speakerCount: Int
    public let audioSeconds: TimeInterval

    public init(turns: [SpeakerTurn], speakerCount: Int, audioSeconds: TimeInterval) {
        self.turns = turns
        self.speakerCount = speakerCount
        self.audioSeconds = audioSeconds
    }
}

/// Runs the pinned diarization binary over one prepared 16 kHz mono file and returns validated
/// anonymous turns (F219).
///
/// The seam is the executable path, so the whole adapter is testable against a shell script — the
/// same arrangement `QwenASRClient` uses. Process handling follows `LocalWhisperClient.run`
/// verbatim: one shared pipe, a `readabilityHandler` feeding an `AsyncStream`, and an exit stream
/// armed before `run()`. `Process.waitUntilExit()` is never called: it spins a CFRunLoop on the
/// calling thread and wedges a Swift cooperative worker under suite load (the F115/F121 hang).
public struct LocalDiarizationClient: Sendable {
    /// Fraction complete, 0...1. The runtime prints `progress NN.NN%` as it works.
    public typealias ProgressHandler = @Sendable (Double) async -> Void

    private let executableURL: URL
    private let segmentationModelURL: URL
    private let embeddingModelURL: URL

    public init(executableURL: URL, segmentationModelURL: URL, embeddingModelURL: URL) {
        self.executableURL = executableURL
        self.segmentationModelURL = segmentationModelURL
        self.embeddingModelURL = embeddingModelURL
    }

    /// `durationSeconds` is the caller's own measurement of the audio, and every turn is validated
    /// against it: a runtime that reports an interval past the end of the recording has produced a
    /// result we cannot trust, and an untrustworthy result is not shown at all.
    public func diarize(
        audioURL: URL,
        durationSeconds: TimeInterval,
        progress: @escaping ProgressHandler = { _ in }
    ) async throws -> SpeakerDiarizationResult {
        let files = FileManager.default
        guard files.isExecutableFile(atPath: executableURL.path),
              files.fileExists(atPath: segmentationModelURL.path),
              files.fileExists(atPath: embeddingModelURL.path) else {
            throw LocalDiarizationError.runtimeNotInstalled
        }
        // The audio is deliberately not probed here. The caller hands us a file it just wrote, and
        // the runtime reports a missing or unreadable one as `Failed to read …`, which
        // `DiarizationOutputParser.classify` turns into `.audioUnreadable`. A pre-check would only
        // add a race with the same answer.
        try Task.checkCancellation()

        let raw = try await run(
            arguments: commandArguments(audioURL: audioURL),
            progress: progress
        )
        try Task.checkCancellation()

        let densified = DiarizationOutputParser.densify(
            raw,
            uncertainBelowConfidence: DiarizationRuntime.uncertainBelowConfidence
        )
        let turns: [SpeakerTurn]
        do {
            turns = try SpeakerTurns.validate(densified, durationSeconds: durationSeconds)
        } catch let error as SpeakerTurnValidationError {
            // Re-thrown as this adapter's error so the caller shows the reassuring "your transcript
            // is unchanged" message rather than a bare enum description in an alert.
            throw LocalDiarizationError.processFailed(
                "The analysis produced an unusable result (\(error))."
            )
        }
        return SpeakerDiarizationResult(
            turns: turns,
            speakerCount: Set(turns.map(\.clusterID)).count,
            audioSeconds: durationSeconds
        )
    }

    private func commandArguments(audioURL: URL) -> [String] {
        [
            // The runtime otherwise echoes its full config, including model paths, into the log.
            "--print-args=false",
            "--clustering.cluster-threshold=\(DiarizationRuntime.clusterThreshold)",
            "--clustering.compute-confidence=true",
            "--segmentation.num-threads=\(DiarizationRuntime.numThreads)",
            "--embedding.num-threads=\(DiarizationRuntime.numThreads)",
            "--segmentation.pyannote-model=\(segmentationModelURL.path)",
            "--embedding.model=\(embeddingModelURL.path)",
            audioURL.path
        ]
        // `--clustering.num-clusters` is never passed: fixing the speaker count would make the
        // runtime invent a second voice in a monologue rather than report one.
    }

    /// The child's environment. Analysis makes no network call — the binary links no network
    /// framework — so a proxy variable inherited from the shell could only ever make an unexpected
    /// egress *look* configured. Strip all six spellings rather than rely on the binary's restraint.
    static func makeEnvironment(
        base: [String: String] = ProcessInfo.processInfo.environment
    ) -> [String: String] {
        var environment = base
        for name in ["HTTP_PROXY", "HTTPS_PROXY", "ALL_PROXY",
                     "http_proxy", "https_proxy", "all_proxy"] {
            environment.removeValue(forKey: name)
        }
        return environment
    }

    /// Streams the merged stdout+stderr so progress is live, accumulating a bounded log for
    /// diagnostics. Both streams share one pipe: two pipes deadlock as soon as one fills.
    private func run(
        arguments: [String],
        progress: @escaping ProgressHandler
    ) async throws -> [RawDiarizationTurn] {
        let pipe = Pipe()
        let process = Process()
        process.executableURL = executableURL
        process.arguments = arguments
        process.standardOutput = pipe
        process.standardError = pipe
        process.environment = Self.makeEnvironment()
        let cancellation = ProcessCancellationController(process: process)

        let handle = pipe.fileHandleForReading
        let processExited = armedExitStream(for: process)
        let dataStream = AsyncStream<Data> { continuation in
            handle.readabilityHandler = { fileHandle in
                let data = fileHandle.availableData
                if data.isEmpty {
                    continuation.finish()
                } else {
                    continuation.yield(data)
                }
            }
            continuation.onTermination = { _ in
                handle.readabilityHandler = nil
            }
        }

        return try await withTaskCancellationHandler {
            try cancellation.runUnlessCancelled()

            var reader = DiarizationLineReader()
            var logData = Data()
            var raw: [RawDiarizationTurn] = []
            for await data in dataStream {
                logData.append(data)
                if logData.count > 200_000 {
                    logData = logData.suffix(100_000)
                }
                for line in reader.consume(String(decoding: data, as: UTF8.self)) {
                    if let fraction = DiarizationOutputParser.progress(from: line) {
                        await progress(fraction)
                    } else if let turn = reader.turn(from: line) {
                        raw.append(turn)
                    }
                }
            }
            // A final line with no terminator is still a line; the runtime does not always end its
            // last write with a newline.
            for line in reader.flush() {
                if let fraction = DiarizationOutputParser.progress(from: line) {
                    await progress(fraction)
                } else if let turn = reader.turn(from: line) {
                    raw.append(turn)
                }
            }
            // The pipe reached EOF, so the child has closed its handles; wait for the exit itself
            // through terminationHandler rather than the blocking waitUntilExit() (see
            // armedExitStream) before reading terminationStatus.
            for await _ in processExited {}
            handle.readabilityHandler = nil

            let log = String(decoding: logData, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            try Task.checkCancellation()
            let status = process.terminationStatus
            guard status == 0 else {
                let diagnostic = String(log.suffix(4_000))
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                throw DiarizationOutputParser.classify(
                    errorOutput: diagnostic.isEmpty
                        ? "Speaker analysis exited with status \(status)."
                        : diagnostic,
                    exitStatus: status
                )
            }
            return raw
        } onCancel: {
            cancellation.cancel()
        }
    }
}

/// Reassembles the runtime's output into lines and enforces the one structural rule of its grammar:
/// nothing before the literal `Started` is data (F219).
///
/// Reads arrive in arbitrary chunks, so a line can straddle two of them; and the runtime terminates
/// its progress updates with a carriage return, so splitting on `\n` alone would fuse a whole run's
/// progress into one unparsable line.
private struct DiarizationLineReader {
    private var pending = ""
    private var started = false

    /// Anything longer than this is not a line of this grammar — a damaged binary spewing one
    /// unterminated blob must not be buffered without bound.
    private static let maximumPendingBytes = 100_000

    mutating func consume(_ chunk: String) -> [String] {
        pending += chunk
        let pieces = pending.split(omittingEmptySubsequences: false) { $0 == "\n" || $0 == "\r" }
        pending = String(pieces.last ?? "")
        if pending.utf8.count > Self.maximumPendingBytes { pending = "" }
        return pieces.dropLast().map(String.init)
    }

    mutating func flush() -> [String] {
        defer { pending = "" }
        return pending.isEmpty ? [] : [pending]
    }

    /// A turn, but only once `Started` has been seen. The preamble is a config dump that embeds the
    /// model paths; parsing it would both mis-read its contents as turns and put those paths in
    /// front of the user.
    mutating func turn(from line: String) -> RawDiarizationTurn? {
        guard started else {
            if line.trimmingCharacters(in: .whitespaces) == "Started" { started = true }
            return nil
        }
        return DiarizationOutputParser.turn(from: line)
    }
}
