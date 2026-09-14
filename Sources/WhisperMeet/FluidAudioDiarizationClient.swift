import AVFoundation
import FluidAudio
import Foundation
import WhisperCore

/// Where the pinned FluidAudio speaker-diarization models live on disk (F216).
///
/// This is the only place in the app that knows the on-disk layout, and it exists because
/// FluidAudio resolves a models *parent* directory and appends `Repo.diarizer.folderName` itself.
/// `Repo.diarizer` is the Hugging Face slug `FluidInference/speaker-diarization-coreml`, but
/// `folderName` strips the `-coreml` suffix, so the staged directory must be named
/// **`speaker-diarization`**. Staging into a directory named after the repo fails with
/// `DownloadError.modelMissing(repo: "speaker-diarization", …)` — an error that names the folder it
/// looked in rather than the repo it wanted, and therefore actively misdirects. Verified by
/// execution during the F216 evaluation.
enum FluidAudioDiarizationRuntime {
    /// The five artifacts the offline diarizer asks for: four compiled Core ML bundles and the PLDA
    /// parameters. Exactly `ModelNames.OfflineDiarizer.requiredModels`, and the roots of the 21
    /// paths below.
    static let requiredModelArtifacts = [
        "Segmentation.mlmodelc",
        "FBank.mlmodelc",
        "Embedding.mlmodelc",
        "PldaRho.mlmodelc",
        "plda-parameters.json"
    ]

    /// Every file a complete install contains, 21.6 MB in total — and the reason the list is not
    /// simply the five names above.
    ///
    /// Four of the five artifacts are `.mlmodelc` **directories**, and
    /// `FileManager.fileExists(atPath:)` is true for a directory. The installer creates each
    /// directory with `mkdir -p` before fetching the first byte into it, so an install interrupted
    /// anywhere in the middle leaves all five names present and the app reporting a healthy
    /// runtime over an empty tree. Naming the leaves instead makes "present" mean "downloaded".
    ///
    /// This list and `model_manifest` in `Scripts/setup-speaker-diarization.sh` must stay
    /// identical; `diarizationInstallerManifestMatchesTheSwiftRequiredFiles` compares them
    /// mechanically, because the last time two such lists were kept in step by inspection they
    /// drifted.
    static let requiredModelFiles: [String] = requiredModelArtifacts.flatMap { artifact -> [String] in
        guard artifact.hasSuffix(".mlmodelc") else { return [artifact] }
        return [
            "analytics/coremldata.bin",
            "coremldata.bin",
            "metadata.json",
            "model.mil",
            "weights/weight.bin"
        ].map { "\(artifact)/\($0)" }
    }

    /// FluidAudio's own community preset. **Not** `DiarizationRuntime.clusterThreshold` (0.40):
    /// that number was derived on the F217 corpus against sherpa-onnx, whose threshold is a cosine
    /// distance, while FluidAudio's is a Euclidean distance in PLDA space (its v0.15.6 semantics
    /// fix). The two are not comparable — the mapping is `sqrt(2 − 2·cosine)` — so carrying 0.40
    /// across would not be conservatism, it would be a different, far more aggressive setting that
    /// over-splits every meeting. The upstream value calibrated on pyannote community-1 is the only
    /// defensible starting point until the threshold is re-derived on annotated audio (F225).
    static let clusterThreshold = 0.6

    /// Recorded on every sidecar so a result produced by this runtime is identifiable later.
    static let runtimeID = "fluidaudio-offline-diarizer"
    static let runtimeVersion = "0.15.7"

    /// The directory handed to `OfflineDiarizerModels.load(from:)` — the PARENT of the staged
    /// models, because FluidAudio appends the folder name itself.
    static func modelsParentDirectory(applicationSupport: URL? = nil) -> URL {
        DiarizationRuntime.managedDirectory(applicationSupport: applicationSupport)
            .appendingPathComponent("models", isDirectory: true)
    }

    /// Where the five files actually sit. See the type comment for why this name is not negotiable.
    static func modelsDirectory(applicationSupport: URL? = nil) -> URL {
        modelsParentDirectory(applicationSupport: applicationSupport)
            .appendingPathComponent("speaker-diarization", isDirectory: true)
    }

    /// Every required artifact, probed on the filesystem. An interrupted install leaves the
    /// directory present but incomplete, so "the folder exists" is never the question asked.
    static func isInstalled(applicationSupport: URL? = nil) -> Bool {
        isInstalled(inParent: modelsParentDirectory(applicationSupport: applicationSupport))
    }

    static func isInstalled(inParent parent: URL) -> Bool {
        let directory = parent.appendingPathComponent("speaker-diarization", isDirectory: true)
        return requiredModelFiles.allSatisfy { relativePath in
            var isDirectory: ObjCBool = false
            let present = FileManager.default.fileExists(
                atPath: directory.appendingPathComponent(relativePath).path,
                isDirectory: &isDirectory
            )
            return present && !isDirectory.boolValue
        }
    }
}

/// Runs FluidAudio's offline speaker diarizer over one prepared 16 kHz mono file and returns
/// validated anonymous turns (F216).
///
/// It satisfies the contract `LocalDiarizationClient` did — an audio URL and a duration in, a
/// validated `SpeakerDiarizationResult` out — so the `AppModel.runSpeakerDiarization` seam, its
/// guards, its cancellation and the sidecar are unchanged. What changed is everything below the
/// seam: there is no subprocess, no stdout grammar and no process to kill, so cancellation now
/// rides on Swift task cancellation.
///
/// `FluidAudio` is imported HERE and nowhere else. `WhisperCore` stays Foundation-only (the
/// AGENTS.md purity rule), which is the whole reason the runtime lives in the app target.
struct FluidAudioDiarizationClient: Sendable {
    /// Fraction complete, 0...1.
    typealias ProgressHandler = @Sendable (Double) async -> Void

    /// FluidAudio reports progress from a synchronous callback inside its segmentation loop, so the
    /// runtime stage is handed a synchronous reporter and this adapter owns the hop to the caller's
    /// async handler.
    typealias ProgressReporter = @Sendable (Double) -> Void

    /// One interval exactly as the runtime reported it, before any remapping or validation.
    /// Deliberately a plain value type rather than FluidAudio's `TimedSpeakerSegment`: it carries a
    /// 256-float embedding this app must never retain (the PRD's anonymity rule), and keeping the
    /// dependency out of the seam is what lets the adapter be tested without models or audio.
    struct Segment: Sendable, Equatable {
        let speakerID: String
        let startSeconds: TimeInterval
        let endSeconds: TimeInterval
    }

    /// The runtime stage: load the models, run the diarizer, report progress. Injectable so the
    /// remapping, validation and cancellation rules below are testable without 21.6 MB of Core ML
    /// bundles or a real recording.
    typealias Runner = @Sendable (URL, @escaping ProgressReporter) async throws -> [Segment]

    private let run: Runner

    init(
        modelsParentDirectory: URL = FluidAudioDiarizationRuntime.modelsParentDirectory(),
        run: Runner? = nil
    ) {
        self.run = run ?? { audioURL, report in
            try await FluidAudioDiarizationClient.runOfflineDiarizer(
                audioURL: audioURL,
                modelsParentDirectory: modelsParentDirectory,
                report: report
            )
        }
    }

    /// `durationSeconds` is the caller's own measurement of the audio, and every turn is validated
    /// against it: a runtime that reports an interval past the end of the recording has produced a
    /// result we cannot trust, and an untrustworthy result is not shown at all.
    func diarize(
        audioURL: URL,
        durationSeconds: TimeInterval,
        progress: @escaping ProgressHandler = { _ in }
    ) async throws -> SpeakerDiarizationResult {
        try Task.checkCancellation()

        let segments = try await runReportingProgress(audioURL: audioURL, progress: progress)

        // The cooperative check that makes cancellation the adapter's guarantee rather than
        // FluidAudio's. FluidAudio 0.15.7 does check `Task.checkCancellation()` in its segmentation
        // and embedding loops (PR #886, 2026-09-03 — days before this adoption), so a cancelled run
        // normally throws from inside the runtime. This line is what holds if that ever regresses:
        // a runtime that runs to completion after a cancel still ends as a `CancellationError`, so
        // `performSpeakerDiarization` takes its `catch is CancellationError` path and no sidecar is
        // written for a run the user stopped.
        try Task.checkCancellation()

        let turns = Self.densify(segments)
        do {
            let validated = try SpeakerTurns.validate(turns, durationSeconds: durationSeconds)
            return SpeakerDiarizationResult(
                turns: validated,
                speakerCount: Set(validated.map(\.clusterID)).count,
                audioSeconds: durationSeconds
            )
        } catch let error as SpeakerTurnValidationError {
            // Re-thrown as this adapter's error so the caller shows the reassuring "your transcript
            // is unchanged" message. The detail is a diagnostic, not user copy.
            throw LocalDiarizationError.processFailed("speaker-turn validation failed: \(error)")
        }
    }

    /// Runs the runtime stage with its synchronous progress callback bridged to the caller's async
    /// handler through a one-slot stream.
    ///
    /// The stream is what keeps the fractions in order. Spawning a `Task` per callback would let a
    /// later fraction overtake an earlier one and march the progress bar backwards; buffering only
    /// the newest value drops the stale middle of a burst instead, which is exactly right for a
    /// progress bar.
    private func runReportingProgress(
        audioURL: URL,
        progress: @escaping ProgressHandler
    ) async throws -> [Segment] {
        let (fractions, continuation) = AsyncStream<Double>.makeStream(
            bufferingPolicy: .bufferingNewest(1)
        )
        async let relayed: Void = {
            for await fraction in fractions { await progress(fraction) }
        }()

        do {
            let segments = try await run(audioURL) { continuation.yield($0) }
            continuation.finish()
            await relayed
            return segments
        } catch {
            continuation.finish()
            await relayed
            throw error
        }
    }

    /// Remaps the runtime's cluster ids onto dense `0..<n` in first-appearance order, so
    /// "Speaker 1" is the first voice heard rather than an arbitrary internal index.
    ///
    /// `DiarizationOutputParser.densify` does exactly this, and it is deliberately NOT reused: its
    /// input is `RawDiarizationTurn`, whose `rawSpeaker` is an `Int` parsed out of sherpa-onnx's
    /// `speaker_07` line grammar, while FluidAudio's `TimedSpeakerSegment.speakerId` is a `String`
    /// (`"S1"`, `"S2"`, … — `OfflineDiarizerManager` formats it as `"S\(cluster + 1)"`). Reuse
    /// would mean parsing the digits back out of that string, and the day an id stops being "S" +
    /// digits every parse returns the same fallback, every turn collapses onto one cluster, and two
    /// voices are displayed as one confidently-labelled speaker — the one error `SpeakerOverlay`
    /// cannot detect, because it sees a single cluster with no competitor and no overlap. Keyed on
    /// the string itself, an unfamiliar id is merely a different key.
    ///
    /// Sorting happens first because `SpeakerTurns.validate` rejects unsorted turns outright and
    /// FluidAudio promises no order — and because first-appearance only means "first voice heard"
    /// if the turns are in time order when the mapping is built.
    ///
    /// Every turn is `.speech`. FluidAudio reports a per-segment `qualityScore`, but it is not the
    /// per-turn clustering confidence sherpa-onnx emitted and no threshold for it has been earned
    /// on this corpus; `DiarizationRuntime.uncertainBelowConfidence` is 0 for the same reason, so
    /// thresholding nothing is also what the previous runtime did in practice (F225 may revise this
    /// only with a documented before/after table).
    static func densify(_ segments: [Segment]) -> [SpeakerTurn] {
        let ordered = segments.sorted {
            ($0.startSeconds, $0.endSeconds, $0.speakerID)
                < ($1.startSeconds, $1.endSeconds, $1.speakerID)
        }
        var mapping: [String: Int] = [:]
        var next = 0
        return ordered.map { segment in
            let clusterID: Int
            if let existing = mapping[segment.speakerID] {
                clusterID = existing
            } else {
                clusterID = next
                mapping[segment.speakerID] = next
                next += 1
            }
            return SpeakerTurn(
                startSeconds: segment.startSeconds,
                endSeconds: segment.endSeconds,
                clusterID: clusterID,
                kind: .speech
            )
        }
    }

    // MARK: - The real runtime

    /// `ModelHub.offlineMode` is process-global and is set exactly once, before any loader is
    /// touched. It is not a nicety: it is the switch that stops a failed load from deleting the
    /// staged models. In offline mode `ModelHub.loadModels` rethrows a load failure untouched;
    /// with it off, the failure path is "delete the cache and re-download", which on a machine
    /// with no network leaves no models and no way to get them back.
    private static let enforceOfflineMode: Void = {
        ModelHub.offlineMode = true
    }()

    /// The settings every analysis runs with: FluidAudio's community presets (the configuration its
    /// own DER numbers were measured with) with our clustering threshold.
    private static var analysisConfiguration: OfflineDiarizerConfig {
        var clustering = OfflineDiarizerConfig.Clustering.community
        clustering.threshold = FluidAudioDiarizationRuntime.clusterThreshold
        // `numSpeakers`/`minSpeakers`/`maxSpeakers` are deliberately left nil: fixing the speaker
        // count would make the runtime invent a second voice in a monologue rather than report one.
        return OfflineDiarizerConfig(
            segmentation: .community,
            embedding: .community,
            clustering: clustering,
            vbx: .community,
            postProcessing: .community
        )
    }

    private static func runOfflineDiarizer(
        audioURL: URL,
        modelsParentDirectory: URL,
        report: @escaping ProgressReporter
    ) async throws -> [Segment] {
        _ = enforceOfflineMode

        guard FluidAudioDiarizationRuntime.isInstalled(inParent: modelsParentDirectory) else {
            throw LocalDiarizationError.runtimeNotInstalled
        }
        guard FileManager.default.isReadableFile(atPath: audioURL.path) else {
            throw LocalDiarizationError.audioUnreadable("Could not read the prepared analysis audio.")
        }
        try Task.checkCancellation()

        let models: OfflineDiarizerModels
        do {
            // NEVER `prepareModels()`. On any load failure it calls `purgeDiarizerRepo`, which
            // removes the entire staged model directory and then throws — stranding an offline
            // machine with no models and no way to recover them. `load(from:configuration:)` only
            // reads.
            models = try await OfflineDiarizerModels.load(
                from: modelsParentDirectory, configuration: nil
            )
        } catch {
            throw Self.failure(error, whileLoadingModels: true)
        }
        try Task.checkCancellation()

        let manager = OfflineDiarizerManager(config: analysisConfiguration)
        // Not optional bookkeeping: `process` calls the banned `prepareModels()` itself whenever the
        // manager has no models, so skipping this line hands the purge path back a different way.
        manager.initialize(models: models)

        let result: DiarizationResult
        do {
            result = try await manager.process(audioURL) { processed, total in
                guard total > 0 else { return }
                report(min(1, max(0, Double(processed) / Double(total))))
            }
        } catch OfflineDiarizationError.noSpeechDetected {
            // "No speech in this recording" is a RESULT, not a failure. FluidAudio throws where
            // sherpa-onnx printed zero segment lines, and surfaced raw that throw becomes
            // `LocalDiarizationError.processFailed`: a meeting recorded with the microphone muted
            // throughout would be reported to the user as a broken analysis they should retry.
            // Every layer above this one already handles a zero-turn result — the overlay abstains,
            // the sidecar records a count of 0 — so the empty list is what they get. Verified by
            // execution: one second of digital silence throws this case rather than returning [].
            return []
        } catch {
            throw Self.failure(error, whileLoadingModels: false)
        }

        return result.segments.map {
            Segment(
                speakerID: $0.speakerId,
                startSeconds: TimeInterval($0.startTimeSeconds),
                endSeconds: TimeInterval($0.endTimeSeconds)
            )
        }
    }

    /// Maps a runtime failure onto the errors the app already knows how to explain. A cancellation
    /// is never one of them: it has to reach `performSpeakerDiarization` as a `CancellationError`,
    /// or a run the user stopped would be reported to them as a failure.
    private static func failure(_ error: Error, whileLoadingModels loading: Bool) -> Error {
        if error is CancellationError { return error }
        if let known = error as? LocalDiarizationError { return known }
        let detail = String(describing: error)
        if loading {
            // The models were present a moment ago (checked above) but will not load: incomplete,
            // truncated, or built for another OS. "Reinstall it in Settings" is the true remedy.
            return LocalDiarizationError.runtimeDamaged(detail)
        }
        let nsError = error as NSError
        if nsError.domain == NSCocoaErrorDomain
            || nsError.domain == NSOSStatusErrorDomain
            || nsError.domain == AVFoundationErrorDomain {
            // Everything the analysis stage does with the filesystem is reading the prepared audio,
            // so a Foundation/AVFoundation/Core Audio error here is about that file.
            return LocalDiarizationError.audioUnreadable(detail)
        }
        return LocalDiarizationError.processFailed(detail)
    }
}
