import Foundation

/// Where the pinned speaker-analysis runtime lives on disk, and the settings it is always run with
/// (F219). The layout mirrors `QwenASRRuntime`: a self-contained tree under the app's managed
/// Runtime directory, so uninstalling is a single `rm -rf` and a partial install is detectable.
public struct DiarizationRuntime: Sendable {
    /// Re-derived on the F217 corpus (F217), replacing the 0.3 that F216 calibrated on five
    /// two-speaker clips — the wrong sample for the cases that actually fail. Measured over seven
    /// thresholds x 18 fixtures, 0.3 through 0.6 form a flat plateau and 0.7 falls off a cliff;
    /// 0.4 has the best displayed-label precision in that plateau (90.8% at 68.8% coverage).
    ///
    /// The axis this moves along is asymmetric, which is why it is not simply "tune for DER":
    /// too low over-splits, and the overlay rule safely abstains on the rows that become ambiguous.
    /// Too high merges two speakers into one cluster, which the overlay cannot detect — it sees one
    /// cluster covering the segment with no competitor and no overlap, and labels it confidently.
    /// Erring low costs coverage; erring high costs correctness.
    public static let clusterThreshold = 0.40

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

    /// The executable links this by `@rpath`, so a tree missing it launches and dies immediately
    /// with a dyld error no `LocalDiarizationError` case maps — the alert would carry a raw linker
    /// message instead of "Reinstall it in Settings".
    public static func onnxRuntimeLibrary(applicationSupport: URL? = nil) -> URL {
        managedDirectory(applicationSupport: applicationSupport)
            .appendingPathComponent("lib/libonnxruntime.dylib")
    }

    /// The segmentation model's licence travels with the model. A tree the app calls installed but
    /// that carries no licence is a compliance defect, not a cosmetic one.
    public static func segmentationLicense(applicationSupport: URL? = nil) -> URL {
        managedDirectory(applicationSupport: applicationSupport)
            .appendingPathComponent("models/segmentation/LICENSE")
    }

    public static func thirdPartyNotices(applicationSupport: URL? = nil) -> URL {
        managedDirectory(applicationSupport: applicationSupport)
            .appendingPathComponent("THIRD-PARTY-NOTICES.txt")
    }

    public static func manifest(applicationSupport: URL? = nil) -> URL {
        managedDirectory(applicationSupport: applicationSupport)
            .appendingPathComponent("MANIFEST")
    }

    /// Every required file, probed on the filesystem. An interrupted install leaves the directory
    /// present but incomplete, so "the folder exists" is never the question asked — the same lesson
    /// `QwenASRRuntime.isInstalled` and `LocalWhisperRuntime.mlxModelCached` encode.
    ///
    /// These are exactly the seven files `runtime_is_complete()` requires in
    /// `Scripts/setup-speaker-diarization.sh` (DIARIZATION_RUNTIME_DECISION.md's completeness
    /// predicate), and the two predicates must name the same seven: checking a subset here is how a
    /// tree the installer would call incomplete gets reported healthy, enabling a menu entry whose
    /// first run dies on `@rpath/libonnxruntime.dylib` — an error this adapter has no case for.
    public static func isInstalled(applicationSupport: URL? = nil) -> Bool {
        let files = FileManager.default
        guard files.isExecutableFile(
            atPath: executable(applicationSupport: applicationSupport).path
        ) else { return false }
        return [
            onnxRuntimeLibrary(applicationSupport: applicationSupport),
            segmentationModel(applicationSupport: applicationSupport),
            segmentationLicense(applicationSupport: applicationSupport),
            embeddingModel(applicationSupport: applicationSupport),
            thirdPartyNotices(applicationSupport: applicationSupport),
            manifest(applicationSupport: applicationSupport)
        ].allSatisfy { files.fileExists(atPath: $0.path) }
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
            // is unchanged" message. The detail is a diagnostic, not user copy — interpolating a
            // Swift case name into a sentence put "(exceedsDuration)" in front of a person.
            throw LocalDiarizationError.processFailed("speaker-turn validation failed: \(error)")
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
        // The runtime reads nothing from stdin, so hand it /dev/null rather than letting it inherit
        // the parent's descriptor (the runtime record's "stdin is unused; close it"). An inherited
        // descriptor is a channel nobody accounted for, and a child that ever blocks on a read from
        // it would hang a run that has no reason to wait for anything.
        process.standardInput = FileHandle.nullDevice
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
            var log = DiarizationDiagnosticLog()
            var raw: [RawDiarizationTurn] = []
            for await data in dataStream {
                for line in reader.consume(String(decoding: data, as: UTF8.self)) {
                    log.append(line, hasStarted: reader.hasStarted)
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
                log.append(line, hasStarted: reader.hasStarted)
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

            let logText = log.text
            try Task.checkCancellation()
            let status = process.terminationStatus
            guard status == 0 else {
                let diagnostic = String(logText.suffix(4_000))
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

/// The bounded diagnostic accumulated while the runtime speaks, built line by line rather than from
/// raw read chunks so the config preamble can be left out of it (F219).
///
/// Bounded because a damaged binary can spew without end; only the tail is ever used, and the
/// caller trims it to 4 KB again before it reaches an error value.
private struct DiarizationDiagnosticLog {
    private var data = Data()

    mutating func append(_ line: String, hasStarted: Bool) {
        guard !DiarizationLineReader.isConfigDump(line, hasStarted: hasStarted) else { return }
        data.append(Data((line + "\n").utf8))
        if data.count > 200_000 {
            data = data.suffix(100_000)
        }
    }

    var text: String {
        String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
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

    /// True once the literal `Started` line has been seen. Everything printed before it is preamble
    /// (DIARIZATION_RUNTIME_DECISION.md:601-606), which is what makes the config dump identifiable.
    var hasStarted: Bool { started }

    /// Anything longer than this is not a line of this grammar — a damaged binary spewing one
    /// unterminated blob must not be buffered without bound.
    private static let maximumPendingBytes = 100_000

    /// The runtime's one-line `OfflineSpeakerDiarizationConfig(...)` preamble, which
    /// `--print-args=false` does NOT suppress and which embeds the recording path and both model
    /// paths. It must never be retained verbatim — not as a turn, and not in the log that becomes a
    /// diagnostic (DIARIZATION_RUNTIME_DECISION.md:585-591, :612, :647).
    ///
    /// Only this line is withheld, not everything before `Started`: all three documented failure
    /// markers — `Errors in config!`, `Failed to read <path>`, `Expect sample rate ...` — are
    /// printed *instead of* `Started` (:677-679), so a log gated on `Started` alone would be empty
    /// in exactly the runs where it is the only evidence there is, and every damaged-runtime failure
    /// would degrade to a bare `.processFailed`.
    static func isConfigDump(_ line: String, hasStarted: Bool) -> Bool {
        !hasStarted && line.contains("Config(")
    }

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
