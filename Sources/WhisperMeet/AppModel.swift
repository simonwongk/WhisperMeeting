import AVFoundation
import AppKit
import CoreGraphics
import Foundation
import UserNotifications
import WhisperCore

struct RecordingPreflightStatus: Equatable {
    enum Access: Equatable {
        case granted
        case permissionNeeded
        case notGranted
        case denied
        case unavailable
    }

    let microphoneAccess: Access
    let systemAudioAccess: Access
    let microphoneName: String
    let availableStorageBytes: Int64?

    static let checking = RecordingPreflightStatus(
        microphoneAccess: .permissionNeeded,
        systemAudioAccess: .permissionNeeded,
        microphoneName: "Default microphone",
        availableStorageBytes: nil
    )

    static func inspect(storageDirectory: URL) -> RecordingPreflightStatus {
        let microphone = AVCaptureDevice.default(for: .audio)
        let microphoneAccess: Access
        if microphone == nil {
            microphoneAccess = .unavailable
        } else {
            switch AVCaptureDevice.authorizationStatus(for: .audio) {
            case .authorized:
                microphoneAccess = .granted
            case .notDetermined:
                microphoneAccess = .permissionNeeded
            case .denied, .restricted:
                microphoneAccess = .denied
            @unknown default:
                microphoneAccess = .denied
            }
        }
        let values = try? storageDirectory.resourceValues(forKeys: [
            .volumeAvailableCapacityForImportantUsageKey
        ])
        return RecordingPreflightStatus(
            microphoneAccess: microphoneAccess,
            systemAudioAccess: CGPreflightScreenCaptureAccess() ? .granted : .notGranted,
            microphoneName: microphone?.localizedName ?? "No microphone available",
            availableStorageBytes: values?.volumeAvailableCapacityForImportantUsage
        )
    }
}

@MainActor
final class RecordingMeterViewModel: ObservableObject {
    @Published private(set) var snapshot = RecordingMeterSnapshot.silent

    func update(_ snapshot: RecordingMeterSnapshot) {
        guard self.snapshot != snapshot else { return }
        self.snapshot = snapshot
    }

    func reset() {
        update(.silent)
    }
}

/// Why a per-segment re-run could not slice a clip (F92 audit fixes).
enum SegmentReRunError: LocalizedError {
    case unsupportedRecordingFormat
    case unreadableRecording

    var errorDescription: String? {
        switch self {
        case .unsupportedRecordingFormat:
            return "This recording isn't a native WAV, so a single segment can't be re-transcribed in place. Re-transcribe the whole meeting instead."
        case .unreadableRecording:
            return "The recording could not be read for re-transcription."
        }
    }
}

@MainActor
final class AppModel: ObservableObject {
    enum RecordingState: Equatable {
        case idle
        case starting
        case recording(startedAt: Date)
        case stopping
    }

    /// The lifecycle of a disposable "test recording" that verifies both channels before a real
    /// meeting. Kept entirely separate from the recording state machine and the meeting library.
    enum PreflightTestPhase: Equatable {
        case idle
        case recording(secondsRemaining: Int)
        case analyzing
        case result(PreflightReport, playbackURL: URL?)
        case failed(String)
    }

    @Published private(set) var recordingState: RecordingState = .idle
    @Published private(set) var preflightTest: PreflightTestPhase = .idle
    /// Markers dropped during the current recording (offsets from its start). Persisted into the
    /// `MeetingRecord` on stop; discarded on cancel. See `docs/RECORDING_MARKERS.md`.
    @Published private(set) var pendingMarkers: [RecordingMarker] = []
    @Published private(set) var activeMeetingID: UUID?
    @Published private(set) var transcription = TranscriptionQueue()
    @Published private(set) var transcriptionProgress: [UUID: LocalTranscriptionProgress] = [:]
    @Published private(set) var activeSummarizationID: UUID?
    @Published private(set) var hasClaudeAPIKey: Bool = false
    @Published private(set) var runtimeExecutableURL: URL?
    @Published private(set) var isInstallingRuntime = false
    @Published private(set) var installationMessage: String?
    @Published private(set) var isQwenInstalled = false
    @Published private(set) var isInstallingQwenRuntime = false
    @Published private(set) var qwenInstallationMessage: String?
    @Published private(set) var recordingPreflight = RecordingPreflightStatus.checking
    @Published private(set) var recordingHealth: RecordingHealthSnapshot?
    @Published private(set) var isImporting = false
    @Published var selectedEngine: MeetingTranscriptionEngine {
        didSet { defaults.set(selectedEngine.rawValue, forKey: Self.modelKey) }
    }
    @Published var selectedLanguage: WhisperLanguage {
        didSet { defaults.set(selectedLanguage.rawValue, forKey: Self.languageKey) }
    }
    @Published var alertMessage: String?
    /// Presents the Keyboard Shortcuts reference sheet, toggled by the ⌘/ command (F85).
    @Published var showsShortcutsSheet = false

    let store: MeetingStore
    let recordingMeter = RecordingMeterViewModel()
    private let recorder: AudioCaptureEngine
    private var preflightRecorder: AudioCaptureEngine?
    private var preflightDirectory: URL?
    private var preflightTask: Task<Void, Never>?
    private static let preflightDurationSeconds = 8
    private let defaults: UserDefaults
    private var transcriptionTasks: [UUID: Task<Void, Never>] = [:]
    private var transcriptionSettings = TranscriptionSelectionStore()
    private var summarizationTasks: [UUID: Task<Void, Never>] = [:]
    private var didPerformStartupRecovery = false
    private var isDictationActive: () -> Bool = { false }

    private static let modelKey = "localWhisperModel"
    private static let languageKey = "localWhisperLanguage"
    private static let claudeAPIKeyAccount = "claudeAPIKey"

    convenience init() {
        self.init(
            store: MeetingStore(),
            recorder: AudioCaptureEngine(),
            defaults: .standard
        )
    }

    init(
        store: MeetingStore,
        recorder: AudioCaptureEngine,
        defaults: UserDefaults
    ) {
        self.store = store
        self.recorder = recorder
        self.defaults = defaults
        let storedEngine = MeetingTranscriptionEngine(
            rawValue: defaults.string(forKey: Self.modelKey) ?? ""
        ) ?? .whisperLarge
        selectedEngine = storedEngine.isSupportedOnCurrentMac ? storedEngine : .whisperLarge
        selectedLanguage = WhisperLanguage(
            rawValue: defaults.string(forKey: Self.languageKey) ?? ""
        ) ?? .automatic
        runtimeExecutableURL = LocalWhisperRuntime.findExecutable()
        isQwenInstalled = QwenASRRuntime.isInstalled()
        hasClaudeAPIKey = KeychainStore.string(for: Self.claudeAPIKeyAccount) != nil
        refreshRecordingPreflight()
    }

    var isRuntimeInstalled: Bool {
        runtimeExecutableURL != nil
    }

    var isSelectedEngineInstalled: Bool {
        selectedEngine == .qwenBalanced ? isQwenInstalled : isRuntimeInstalled
    }

    var isInstallingRecognitionRuntime: Bool {
        isInstallingRuntime || isInstallingQwenRuntime
    }

    /// Wires the reverse of dictation's own meeting-active guard: lets `startRecording()` refuse to
    /// start while dictation currently owns the microphone. See `AppEntry`'s `.task` for the call site.
    func configureDictationGuard(_ isActive: @escaping () -> Bool) {
        isDictationActive = isActive
    }

    var isRecordingActive: Bool {
        switch recordingState {
        case .idle: return false
        default: return true
        }
    }

    var isPreflightTestActive: Bool {
        switch preflightTest {
        case .idle: return false
        default: return true
        }
    }

    /// True while any capture path owns the microphone — a meeting recording, an active preflight
    /// phase, OR a preflight engine still tearing down after Cancel. That last case matters because
    /// `teardownPreflight()` publishes `.idle` immediately, but the `SCStream` isn't released until
    /// the cancelled task's `engine.cancel()` finishes; guarding only on the published phase would
    /// let a new capture (meeting, another test, or dictation) start on top of a still-closing
    /// stream. All capture-start guards and the dictation hotkey consult this.
    var isMicrophoneBusy: Bool {
        isRecordingActive || isPreflightTestActive || preflightRecorder != nil
    }

    var isSummarizing: Bool {
        activeSummarizationID != nil
    }

    func setClaudeAPIKey(_ key: String?) {
        KeychainStore.set(key, for: Self.claudeAPIKeyAccount)
        hasClaudeAPIKey = KeychainStore.string(for: Self.claudeAPIKeyAccount) != nil
    }

    var activeTranscriptionID: UUID? { transcription.activeID }

    var hasActiveTranscription: Bool {
        transcription.activeID != nil
    }

    func isQueuedForTranscription(_ id: UUID) -> Bool {
        transcription.isPending(id)
    }

    func refreshRuntime() {
        runtimeExecutableURL = LocalWhisperRuntime.findExecutable()
        isQwenInstalled = QwenASRRuntime.isInstalled()
    }

    func refreshRecordingPreflight() {
        recordingPreflight = .inspect(storageDirectory: store.rootDirectory)
    }

    /// Rebuilds one interrupted recording folder from its raw tracks. Injectable so startup
    /// recovery's per-orphan resilience is testable; defaults to the real rebuild (F47).
    var recoverInterruptedRecording: @Sendable (URL) throws -> RecoveredRecording? = {
        try InterruptedRecordingRecovery.recover(in: $0)
    }

    /// Runs the read-only integrity check for one meeting's on-disk audio. Injectable so the library
    /// sweep is testable with a fake finding, mirroring F47's recover seam; defaults to the real
    /// checker. Never opens, deletes, or rewrites audio (F83 wires the F66 core).
    var checkMeetingIntegrity: @Sendable (MeetingIntegrityDescriptor) -> [IntegrityFinding] = {
        MeetingIntegrityChecker.check($0)
    }

    /// Runs the Qwen installer's recovery-only reclaim over a runtime directory (restores an orphaned
    /// complete backup, removes abandoned artifacts). Injectable so the startup wiring is testable
    /// without spawning a real process; defaults to invoking the bundled `setup-qwen-asr.sh` with
    /// `QWEN_INSTALL_RECOVERY_ONLY=1` — the tested F33 core. Returns the reclaim's exit status.
    var runQwenInstallRecovery: @Sendable (URL) async -> Int32 = { runtimeDirectory in
        await AppModel.spawnQwenInstallRecovery(runtimeDirectory: runtimeDirectory)
    }

    /// Builds the summarizer for a meeting summary. Injectable so the style-threading wiring is
    /// testable without the Claude network call; defaults to the real `ClaudeSummarizer` (F81).
    var makeSummarizer: @Sendable (String) -> MeetingSummarizer = { ClaudeSummarizer(apiKey: $0) }

    /// Runs a transcription engine on a WAV and returns the result WITHOUT persisting. Injectable so the
    /// second-opinion (F88) and per-segment re-run (F92) flows are testable with a stub engine; when nil,
    /// `executeEngine` performs the real Qwen/Whisper dispatch.
    var runTranscriptionEngineOverride: ((MeetingTranscriptionSelection, URL) async throws -> TranscriptionResult)?

    /// Spans of the most recent cross-engine "second opinion", for the review sheet (F88).
    @Published var secondOpinionSpans: [TranscriptComparisonSpan]?
    /// True when the most recent second-opinion run failed to produce a comparison — so the sheet can
    /// show an error instead of rendering nil spans as "no differences" (F142).
    @Published var secondOpinionFailed = false
    /// True while a second-opinion or segment re-run engine pass is in flight (F88/F92).
    @Published private(set) var isRunningAuxiliaryEngine = false

    /// Runs the given engine selection on a recording (or clip) and returns the result without touching
    /// the store. Extracted from `performTranscription` so second-opinion/segment-rerun share one code
    /// path; the override seam lets tests substitute a stub.
    func executeEngine(
        _ selection: MeetingTranscriptionSelection,
        on url: URL,
        onProgress: @escaping @Sendable (LocalTranscriptionProgress) async -> Void = { _ in }
    ) async throws -> TranscriptionResult {
        if let override = runTranscriptionEngineOverride {
            return try await override(selection, url)
        }
        if selection.engine == .qwenBalanced {
            guard isQwenInstalled else { throw QwenASRError.runtimeNotInstalled }
            let client = QwenASRClient(
                pythonExecutableURL: QwenASRRuntime.pythonExecutable(),
                helperScriptURL: QwenASRRuntime.helperScript(),
                modelDirectory: QwenASRRuntime.modelDirectory(),
                alignerDirectory: QwenASRRuntime.alignerDirectory()
            )
            return try await client.transcribe(recordingAt: url, language: selection.language, onProgress: onProgress)
        } else {
            guard let executableURL = runtimeExecutableURL,
                  let whisperModel = selection.engine.whisperModel else {
                throw LocalWhisperError.runtimeNotInstalled
            }
            let client = LocalWhisperClient(
                executableURL: executableURL,
                modelDirectory: LocalWhisperRuntime.modelDirectory()
            )
            return try await client.transcribe(
                recordingAt: url,
                options: .accuracyFirst(model: whisperModel, language: selection.language, keyterms: store.vocabulary),
                onProgress: onProgress
            )
        }
    }

    /// Kick off a second opinion (F88); guarded so it never runs alongside a transcription or another
    /// auxiliary pass. The heavy work is in `computeSecondOpinion`, which tests await directly.
    func requestSecondOpinion(id: UUID) {
        guard !hasActiveTranscription, !isRunningAuxiliaryEngine else {
            alertMessage = "Finish the current transcription before requesting a second opinion."
            return
        }
        secondOpinionFailed = false
        secondOpinionSpans = nil
        isRunningAuxiliaryEngine = true
        Task {
            await computeSecondOpinion(id: id)
            isRunningAuxiliaryEngine = false
        }
    }

    /// Runs the non-selected engine on the meeting's recording and stores the comparison spans. Never
    /// overwrites the stored transcript — only `applySecondOpinionSpan` does, on explicit user action.
    func computeSecondOpinion(id: UUID) async {
        guard let meeting = store.meeting(id: id), meeting.status == .completed, !meeting.segments.isEmpty else { return }
        secondOpinionFailed = false
        // Run the genuine OTHER engine relative to the engine that produced this transcript (recorded on
        // the meeting), not current Settings — otherwise a Settings change could re-run the same engine (F142).
        let producedBy = meeting.transcriptionEngine ?? selectedEngine
        let other: MeetingTranscriptionEngine = producedBy == .qwenBalanced ? .whisperLarge : .qwenBalanced
        let selection = MeetingTranscriptionSelection(engine: other, language: selectedLanguage)
        do {
            let result = try await executeEngine(selection, on: store.recordingURL(for: meeting))
            secondOpinionSpans = TranscriptComparison.compare(meeting.segments, result.segments)
        } catch {
            secondOpinionFailed = true
            alertMessage = error.localizedDescription
        }
    }

    /// Replace one diverging segment's text with the other engine's reading (F88), on explicit apply.
    func applySecondOpinionSpan(_ span: TranscriptComparisonSpan, to id: UUID) {
        guard let secondary = span.secondaryText else { return }
        store.update(id: id) { meeting in
            guard let index = meeting.segments.firstIndex(where: { $0.start == span.start && $0.text == span.primaryText }) else { return }
            meeting.segments[index].text = secondary
            meeting.transcriptText = TranscriptFormatter.timestamped(meeting.segments)
        }
    }

    /// Re-transcribe a single segment (F92): slice that segment's audio from `meeting.wav`, run the
    /// selected engine on the clip, and splice the result back — the recording is never modified. The
    /// heavy work is here so tests can await it directly; `requestSegmentReTranscription` guards + wraps.
    func reTranscribeSegment(id: UUID, index: Int) async {
        guard let meeting = store.meeting(id: id),
              meeting.segments.indices.contains(index),
              let start = meeting.segments[index].start,
              let end = meeting.segments[index].end else { return }
        let selection = MeetingTranscriptionSelection(engine: selectedEngine, language: selectedLanguage)
        do {
            let clipURL = try Self.makeSegmentClip(
                from: store.recordingURL(for: meeting), startSeconds: start, endSeconds: end
            )
            defer { try? FileManager.default.removeItem(at: clipURL) }
            let result = try await executeEngine(selection, on: clipURL)
            // A re-run can validly return text with no timestamped segments (alignment failure). Splicing
            // an empty array would DELETE the segment's text — keep the original instead (F92 audit fix).
            guard !result.segments.isEmpty else {
                alertMessage = "Re-transcribing that segment produced no timestamped text, so the original was kept."
                return
            }
            store.update(id: id) { meeting in
                guard meeting.segments.indices.contains(index) else { return }
                let merged = TranscriptSegmentSplice.splice(meeting.segments, replacingIndex: index, with: result.segments)
                meeting.segments = merged
                meeting.transcriptText = TranscriptFormatter.timestamped(merged)
            }
        } catch {
            alertMessage = error.localizedDescription
        }
    }

    func requestSegmentReTranscription(id: UUID, index: Int) {
        guard !hasActiveTranscription, !isRunningAuxiliaryEngine else {
            alertMessage = "Finish the current transcription before re-transcribing a segment."
            return
        }
        isRunningAuxiliaryEngine = true
        Task {
            await reTranscribeSegment(id: id, index: index)
            isRunningAuxiliaryEngine = false
        }
    }

    /// Writes a temp WAV holding just one segment's audio, sliced from `meeting.wav`. Reads the real
    /// sample rate from the WAV header (the recording is 48 kHz, not 16 kHz) so the byte range is
    /// correct, then re-wraps the PCM slice with a fresh header. Never modifies the source (F92).
    static func makeSegmentClip(from wavURL: URL, startSeconds: Double, endSeconds: Double) throws -> URL {
        let handle = try FileHandle(forReadingFrom: wavURL)
        defer { try? handle.close() }
        guard let header = try handle.read(upToCount: SegmentAudioRange.headerBytes),
              header.count >= SegmentAudioRange.headerBytes else {
            throw SegmentReRunError.unreadableRecording
        }
        // Only a canonical PCM WAV can be byte-sliced. Imported recordings keep their original container
        // (.m4a/.mp3/.mp4/.mov/.aiff/.caf); slicing those as raw WAV bytes would produce garbage, so
        // refuse and let the caller guide the user (F92 audit fix).
        guard header.prefix(4).elementsEqual(Array("RIFF".utf8)),
              header.subdata(in: 8..<12).elementsEqual(Array("WAVE".utf8)) else {
            throw SegmentReRunError.unsupportedRecordingFormat
        }
        let sampleRate = header.withUnsafeBytes { raw -> UInt32 in
            raw.loadUnaligned(fromByteOffset: 24, as: UInt32.self).littleEndian
        }
        let fileSize = (try? wavURL.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? SegmentAudioRange.headerBytes
        let range = SegmentAudioRange.byteRange(
            startSeconds: startSeconds, endSeconds: endSeconds, sampleRate: Int(sampleRate)
        )
        let clamped = range.clamped(to: SegmentAudioRange.headerBytes..<max(SegmentAudioRange.headerBytes, fileSize))
        // Partial read: seek to the clip's byte range and read only those bytes — never the whole file,
        // so a multi-hundred-MB recording doesn't load into memory on the main actor (F92 audit fix).
        try handle.seek(toOffset: UInt64(clamped.lowerBound))
        let pcm = (try handle.read(upToCount: clamped.count)) ?? Data()
        var clip = WAVWriter.header(sampleRate: sampleRate, dataByteCount: UInt32(pcm.count))
        clip.append(pcm)
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("WhisperMeet-segment-\(UUID().uuidString).wav")
        try clip.write(to: url)
        return url
    }

    /// Backs the library up to a destination as a verified generation snapshot. Injectable so the
    /// Settings wiring is testable without touching a real disk destination; defaults to the real
    /// `BackupCoordinator` (F90). `now` is the generation stamp (epoch seconds).
    var runLibraryBackup: @Sendable (_ source: URL, _ destination: URL, _ now: Int, _ retain: Int) throws -> BackupSummary = {
        try BackupCoordinator.backUp(source: $0, destination: $1, now: $2, retain: $3)
    }
    /// Newest N backup generations to keep at the destination (Settings-controlled, F90).
    @Published var backupRetention = 5

    /// Copy the meeting library to a chosen backup folder as a new verified snapshot. Read-only on the
    /// source; surfaces success or the failure reason through `alertMessage` (F90). Refuses while a
    /// recording or import is active so it never snapshots changing files, and runs the copy/hash work
    /// off the main actor so the UI doesn't stall (F137).
    func backUpLibrary(to destination: URL, now: Int = Int(Date().timeIntervalSince1970)) async {
        guard !isRecordingActive, !isImporting else {
            alertMessage = "Finish recording or importing before backing up the library."
            return
        }
        let source = store.rootDirectory
        let retain = backupRetention
        let run = runLibraryBackup
        do {
            let summary = try await Task.detached(priority: .userInitiated) {
                try run(source, destination, now, retain)
            }.value
            alertMessage = "Library backed up: \(summary.copied) file(s) copied, \(summary.skipped) unchanged."
                + (summary.prunedGenerations.isEmpty ? "" : " Removed \(summary.prunedGenerations.count) old backup(s).")
        } catch {
            alertMessage = error.localizedDescription
        }
    }

    func performStartupRecovery() async {
        guard !didPerformStartupRecovery else { return }
        didPerformStartupRecovery = true
        // Self-heal an interrupted Qwen install *before* refreshing runtime state, so a runtime that a
        // force-quit mid-install stranded in a backup dir is restored and shows as installed rather
        // than "not installed" (F33 wires the tested `setup-qwen-asr.sh` recovery branch to launch).
        await reclaimInterruptedQwenInstall()
        refreshRuntime()
        refreshRecordingPreflight()
        var messages = store.startupRecoveryMessages

        do {
            let recover = recoverInterruptedRecording
            for orphan in try store.orphanedRecordings() {
                let recovered: RecoveredRecording?
                do {
                    recovered = try await Task.detached(priority: .utility) {
                        try recover(orphan.directory)
                    }.value
                } catch {
                    // One unreadable/broken orphan folder must not abort recovery of the rest (F47).
                    // The folder is left untouched (raw tracks preserved) and reported.
                    messages.append(
                        "An interrupted recording folder at \(orphan.directory.path) could not be rebuilt and was left untouched. \(error.localizedDescription)"
                    )
                    continue
                }
                guard let recovered else {
                    if let imported = InterruptedRecordingRecovery.importedRecordingCandidate(
                        in: orphan.directory
                    ) {
                        let failedTitle = "Unverified Import \(orphan.createdAt.formatted(date: .abbreviated, time: .shortened))"
                        let message = "WhisperMeet preserved this interrupted import, but it was empty or macOS could not verify it as playable audio or video. The original file remains on this Mac; replace it with a valid recording or delete this entry."
                        store.upsert(MeetingRecord(
                            id: orphan.id,
                            title: failedTitle,
                            createdAt: orphan.createdAt,
                            recordingPath: store.relativeRecordingPath(for: imported),
                            status: .failed,
                            errorMessage: message
                        ))
                        messages.append("\(failedTitle) needs attention. \(message)")
                        continue
                    }
                    if (try? InterruptedRecordingRecovery.removeIfEmpty(
                        in: orphan.directory
                    )) == true {
                        continue
                    }
                    messages.append(
                        "An interrupted recording folder was kept at \(orphan.directory.path), but it did not contain enough audio to rebuild a WAV."
                    )
                    continue
                }
                let title = "Recovered Meeting \(orphan.createdAt.formatted(date: .abbreviated, time: .shortened))"
                let duration = recovered.duration > 0
                    ? recovered.duration
                    : await Self.loadDuration(of: recovered.recordingURL)
                if recovered.source == .importedRecording, duration <= 0 {
                    let failedTitle = "Unverified Import \(orphan.createdAt.formatted(date: .abbreviated, time: .shortened))"
                    let message = "WhisperMeet preserved this interrupted import, but macOS could not verify it as playable audio or video. The original file remains on this Mac; replace it with a valid recording or delete this entry."
                    store.upsert(MeetingRecord(
                        id: orphan.id,
                        title: failedTitle,
                        createdAt: orphan.createdAt,
                        recordingPath: store.relativeRecordingPath(for: recovered.recordingURL),
                        status: .failed,
                        errorMessage: message
                    ))
                    messages.append("\(failedTitle) needs attention. \(message)")
                    continue
                }
                store.upsert(MeetingRecord(
                    id: orphan.id,
                    title: title,
                    createdAt: orphan.createdAt,
                    duration: duration,
                    recordingPath: store.relativeRecordingPath(for: recovered.recordingURL),
                    errorMessage: recovered.wasRebuiltFromRawTracks
                        ? "Recovered from source audio after an interruption. The raw microphone and system tracks were preserved; their exact start alignment was unavailable."
                        : "Recovered after an interruption. The original recording and source tracks were preserved."
                ))
                messages.append("Recovered \(title) and added it back to meeting history.")
            }
        } catch {
            messages.append(
                "WhisperMeet could not finish scanning interrupted recordings. Existing recording folders were not changed. \(error.localizedDescription)"
            )
        }
        recoverInterruptedTranscriptions()
        // Read-only integrity sweep over the whole library (including anything just recovered above):
        // flags missing/truncated/inconsistent audio without ever touching it (F83 wires the F66 core).
        messages.append(contentsOf: Self.integrityMessages(verifyLibraryIntegrity()))
        if !messages.isEmpty {
            alertMessage = messages.joined(separator: "\n\n")
        }
    }

    func installLocalWhisper() {
        guard !isInstallingRecognitionRuntime,
              !isMicrophoneBusy,
              !isImporting,
              !hasActiveTranscription,
              !isDictationActive() else {
            return
        }
        guard let scriptURL = Bundle.main.url(
            forResource: "setup-local-whisper",
            withExtension: "sh"
        ) else {
            alertMessage = "The local Whisper installer is missing. Rebuild the app and try again."
            return
        }
        isInstallingRuntime = true
        installationMessage = "Installing FFmpeg and local Whisper…"
        let runtimeDirectory = LocalWhisperRuntime.managedDirectory()
        Task {
            do {
                try await runInstaller(
                    scriptURL: scriptURL,
                    runtimeDirectory: runtimeDirectory
                )
                refreshRuntime()
                if isRuntimeInstalled {
                    installationMessage = "Local Whisper is ready. The selected model downloads once, when first used."
                } else {
                    throw LocalWhisperError.runtimeNotInstalled
                }
            } catch {
                installationMessage = "Installation failed."
                alertMessage = error.localizedDescription
            }
            isInstallingRuntime = false
        }
    }

    func installQwenASR() {
        guard !isInstallingRecognitionRuntime,
              !isMicrophoneBusy,
              !isImporting,
              !hasActiveTranscription,
              !isRunningAuxiliaryEngine, // don't install atop a second-opinion / segment re-run (F140)
              !isDictationActive() else {
            return
        }
        guard MeetingTranscriptionEngine.qwenBalanced.isSupportedOnCurrentMac else {
            alertMessage = "Qwen3-ASR requires an Apple-silicon Mac. Whisper remains available on Intel Macs."
            return
        }
        guard let scriptURL = Bundle.main.url(
            forResource: "setup-qwen-asr",
            withExtension: "sh"
        ) else {
            alertMessage = "The Qwen3-ASR installer is missing. Rebuild the app and try again."
            return
        }
        isInstallingQwenRuntime = true
        qwenInstallationMessage = "Installing Qwen3-ASR and its timestamp model…"
        Task {
            do {
                try await runQwenInstaller(
                    scriptURL: scriptURL,
                    runtimeDirectory: QwenASRRuntime.managedDirectory()
                )
                refreshRuntime()
                if isQwenInstalled {
                    qwenInstallationMessage = "Qwen3-ASR is ready for local transcription."
                } else {
                    throw QwenASRError.runtimeNotInstalled
                }
            } catch {
                qwenInstallationMessage = "Installation failed. The previous runtime was preserved."
                alertMessage = error.localizedDescription
            }
            isInstallingQwenRuntime = false
        }
    }

    func startRecording() async {
        guard recordingState == .idle, !isImporting, !isMicrophoneBusy else { return }
        guard !isInstallingRecognitionRuntime else {
            alertMessage = "Wait for the local recognition model installation to finish before recording."
            return
        }
        guard !isDictationActive() else {
            alertMessage = "Finish Quick Dictation before recording a meeting — they can't share the microphone at the same time."
            return
        }
        refreshRecordingPreflight()
        if recordingPreflight.microphoneAccess == .unavailable {
            alertMessage = "Recording cannot start because no microphone is connected or available. Connect an input device and choose Check Again."
            return
        }
        if let available = recordingPreflight.availableStorageBytes,
           available < 500_000_000 {
            alertMessage = "Recording cannot start because this Mac has less than 500 MB available. Free some storage so the meeting audio is not put at risk."
            return
        }
        recordingState = .starting
        recordingHealth = nil
        recordingMeter.reset()
        pendingMarkers = []
        let id = UUID()
        activeMeetingID = id
        let directory = store.recordingDirectoryURL(for: id)
        do {
            _ = try store.recordingDirectory(for: id)
            try await recorder.start(in: directory) { [weak self] snapshot in
                Task { @MainActor [weak self] in
                    guard let self,
                          self.activeMeetingID == id,
                          case .recording = self.recordingState else {
                        return
                    }
                    self.recordingHealth = snapshot
                }
            } onLevels: { [weak self] snapshot in
                Task { @MainActor [weak self] in
                    guard let self,
                          self.activeMeetingID == id,
                          case .recording = self.recordingState else {
                        return
                    }
                    self.recordingMeter.update(snapshot)
                }
            }
            recordingState = .recording(startedAt: Date())
            refreshRecordingPreflight()
        } catch {
            recordingState = .idle
            activeMeetingID = nil
            recordingHealth = nil
            recordingMeter.reset()
            refreshRecordingPreflight()
            _ = try? InterruptedRecordingRecovery.removeIfEmpty(in: directory)
            alertMessage = error.localizedDescription
        }
    }

    func stopRecording(title: String) async -> UUID? {
        guard let id = activeMeetingID else { return nil }
        recordingState = .stopping
        let directory = store.recordingDirectoryURL(for: id)
        do {
            let artifact = try await recorder.stop()
            let fallbackTitle = "Meeting \(Date.now.formatted(date: .abbreviated, time: .shortened))"
            let cleanTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
            let meeting = MeetingRecord(
                id: id,
                title: cleanTitle.isEmpty ? fallbackTitle : cleanTitle,
                duration: artifact.duration,
                recordingPath: store.relativeRecordingPath(for: artifact.mixedRecordingURL),
                markers: pendingMarkers.isEmpty ? nil : pendingMarkers,
                healthReport: artifact.healthReport
            )
            store.upsert(meeting)
            pendingMarkers = []
            recordingState = .idle
            activeMeetingID = nil
            recordingHealth = nil
            recordingMeter.reset()
            refreshRecordingPreflight()

            refreshRuntime()
            if isSelectedEngineInstalled {
                beginTranscription(id: id)
            } else {
                alertMessage = "Recording saved on this Mac. Install the selected transcription model in Settings, then choose Transcribe."
            }
            return id
        } catch let recordingError {
            recordingState = .idle
            activeMeetingID = nil
            recordingHealth = nil
            recordingMeter.reset()
            refreshRecordingPreflight()
            do {
                let recovered = try await Task.detached(priority: .userInitiated) {
                    try InterruptedRecordingRecovery.recover(in: directory)
                }.value
                if let recovered {
                    let fallbackTitle = "Recovered Meeting \(Date.now.formatted(date: .abbreviated, time: .shortened))"
                    let cleanTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
                    let recoveredMarkers = pendingMarkers.isEmpty ? nil : pendingMarkers
                    pendingMarkers = []
                    store.upsert(MeetingRecord(
                        id: id,
                        title: cleanTitle.isEmpty ? fallbackTitle : cleanTitle,
                        duration: recovered.duration,
                        recordingPath: store.relativeRecordingPath(for: recovered.recordingURL),
                        errorMessage: "The recording was recovered after a finishing error. The source files remain on this Mac, and transcription can be tried again.",
                        markers: recoveredMarkers
                    ))
                    alertMessage = "The meeting could not finish normally, but its recording was recovered and added to history. \(recordingError.localizedDescription)"
                    return id
                }
            } catch {
                alertMessage = "The recording could not be finalized automatically. Its folder was preserved at \(directory.path). Finishing error: \(recordingError.localizedDescription) Recovery error: \(error.localizedDescription)"
                return nil
            }
            alertMessage = "No usable audio could be rebuilt, but the recording folder was left untouched at \(directory.path). \(recordingError.localizedDescription)"
            return nil
        }
    }

    /// Presents the discard-recording confirmation. Owned by the model so both the in-window button and
    /// the ⌘ Cancel command route through the SAME confirmation, and never prompt when nothing is being
    /// recorded (F139).
    @Published var isConfirmingCancellation = false
    /// Cancel is only valid while capturing or starting — NOT during finalization (`.stopping`), where a
    /// cancel would race the Stop, nor when idle (F139).
    var canCancelRecording: Bool {
        switch recordingState {
        case .recording, .starting: return true
        case .stopping, .idle: return false
        }
    }
    func requestCancelConfirmation() {
        guard canCancelRecording else { return }
        isConfirmingCancellation = true
    }

    func cancelRecording() async {
        // A cancel that arrives during finalization (`.stopping`) or when idle must be a no-op so it
        // can't race/corrupt a simultaneous Stop (F139).
        guard canCancelRecording else { return }
        await recorder.cancel()
        recordingState = .idle
        activeMeetingID = nil
        recordingHealth = nil
        recordingMeter.reset()
        pendingMarkers = []
        refreshRecordingPreflight()
    }

    // MARK: - Recording markers

    /// Drops a marker at the current point in the live recording. No-op unless recording. The audio
    /// is never touched — this only records an offset. See `docs/RECORDING_MARKERS.md`.
    func addLiveMarker(label: String? = nil) {
        guard case let .recording(startedAt) = recordingState else { return }
        let offset = max(0, Date().timeIntervalSince(startedAt))
        pendingMarkers = RecordingMarkers.inserting(
            RecordingMarker(offset: offset, label: label),
            into: pendingMarkers
        )
    }

    /// Adds a marker to an already-saved meeting (e.g. from playback at the current time).
    func addMarker(to meetingID: UUID, offset: TimeInterval, label: String? = nil) {
        store.update(id: meetingID) { meeting in
            meeting.markers = RecordingMarkers.inserting(
                RecordingMarker(offset: offset, label: label),
                into: meeting.markers ?? []
            )
        }
    }

    /// Removes a marker from a saved meeting.
    func removeMarker(_ markerID: UUID, from meetingID: UUID) {
        store.update(id: meetingID) { meeting in
            meeting.markers = (meeting.markers ?? []).filter { $0.id != markerID }
        }
    }

    /// Renames a marker on a saved meeting (a blank label clears it, reverting to "Marker N").
    func renameMarker(_ markerID: UUID, to label: String, in meetingID: UUID) {
        let trimmed = label.trimmingCharacters(in: .whitespacesAndNewlines)
        store.update(id: meetingID) { meeting in
            guard var markers = meeting.markers else { return }
            for index in markers.indices where markers[index].id == markerID {
                markers[index].label = trimmed.isEmpty ? nil : trimmed
            }
            meeting.markers = markers
        }
    }

    // MARK: - Preflight test recording

    /// Records a short, disposable sample of both channels and reports whether each is capturing.
    /// Uses a dedicated engine and a temp directory — never the meeting library — and never becomes
    /// a meeting. See `docs/PREFLIGHT_TEST.md`.
    func startPreflightTest() {
        guard recordingState == .idle, !isImporting, !isMicrophoneBusy else { return }
        guard !isInstallingRecognitionRuntime else {
            alertMessage = "Wait for the local recognition model installation to finish before testing a recording."
            return
        }
        guard !isDictationActive() else {
            alertMessage = "Finish Quick Dictation before running a test recording — they can't share the microphone at the same time."
            return
        }
        let engine = AudioCaptureEngine()
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("WhisperMeet-Preflight-\(UUID().uuidString)", isDirectory: true)
        preflightRecorder = engine
        preflightDirectory = directory
        preflightTest = .recording(secondsRemaining: Self.preflightDurationSeconds)
        preflightTask = Task { [weak self] in
            await self?.runPreflightTest(engine: engine, directory: directory)
        }
    }

    /// The task owns the engine's *entire* lifecycle. `AudioCaptureEngine.start()` is not
    /// cancellation-aware, so we always let it finish and then re-check cancellation — that way a
    /// Cancel tapped during `start()` still results in the just-created stream being torn down here
    /// (rather than orphaned). `teardownPreflight()` only cancels this task; it never touches the
    /// engine while the task is live, so `engine.cancel()` is called from exactly one place.
    private func runPreflightTest(engine: AudioCaptureEngine, directory: URL) async {
        do {
            try await engine.start(in: directory, onHealthUpdate: { _ in }, onLevels: { _ in })
            try Task.checkCancellation()  // Cancel during start() → stop the stream we just created.
            for remaining in stride(from: Self.preflightDurationSeconds - 1, through: 0, by: -1) {
                try await Task.sleep(for: .seconds(1))
                try Task.checkCancellation()
                preflightTest = .recording(secondsRemaining: remaining)
            }
            try Task.checkCancellation()
            preflightTest = .analyzing
            let artifact = try await engine.stop()
            try Task.checkCancellation()
            let report = await Self.analyzePreflight(artifact: artifact)
            try Task.checkCancellation()
            let playbackURL = FileManager.default.fileExists(atPath: artifact.mixedRecordingURL.path)
                ? artifact.mixedRecordingURL
                : nil
            preflightRecorder = nil
            preflightTask = nil
            preflightTest = .result(report, playbackURL: playbackURL)
        } catch is CancellationError {
            await engine.cancel()  // stops the stream and removes the temp session directory
            releasePreflightOwnership(of: engine)
            // teardownPreflight() already set the phase to .idle; don't disturb it.
        } catch {
            await engine.cancel()
            let owned = releasePreflightOwnership(of: engine)
            // A Cancel that landed alongside a real error must not resurrect a dismissed sheet, and
            // a newer test that took ownership during engine.cancel() must not be clobbered either.
            if owned, !Task.isCancelled {
                preflightTest = .failed(error.localizedDescription)
            }
        }
    }

    /// Clears the engine/task/temp-directory references for a finished run — but only if they still
    /// describe *this* engine. `engine.cancel()` above is a suspension point during which a new test
    /// (e.g. "Test Again") can install its own engine/task; the resuming old task must not nil those.
    /// Returns whether this run still owned the state.
    @discardableResult
    private func releasePreflightOwnership(of engine: AudioCaptureEngine) -> Bool {
        guard preflightRecorder === engine else { return false }
        preflightRecorder = nil
        preflightTask = nil
        preflightDirectory = nil
        return true
    }

    private static func analyzePreflight(artifact: RecordingArtifact) async -> PreflightReport {
        await Task.detached(priority: .utility) {
            let micData = (try? Data(contentsOf: artifact.microphoneTrackURL)) ?? Data()
            let systemData = (try? Data(contentsOf: artifact.systemTrackURL)) ?? Data()
            return PreflightAssessment.evaluate(
                microphone: PreflightSignalAnalyzer.analyze(float32LittleEndian: micData),
                system: PreflightSignalAnalyzer.analyze(float32LittleEndian: systemData)
            )
        }.value
    }

    /// Cancels an in-progress test and discards its temp files.
    func cancelPreflightTest() { teardownPreflight() }

    /// Dismisses a finished (result/failed) test and discards its temp files.
    func dismissPreflightTest() { teardownPreflight() }

    /// Ends any preflight test.
    ///
    /// - If the capture task is still running, we only cancel it and set `.idle`; the task's
    ///   cancellation path (the single owner of the engine) stops the stream and `engine.cancel()`
    ///   removes the temp directory. This avoids a second, concurrent `engine.cancel()`.
    /// - If the task has already finished (a result/failed sheet), the engine is gone and the temp
    ///   files were retained for playback, so we remove the directory directly.
    private func teardownPreflight() {
        if let task = preflightTask {
            task.cancel()
            preflightTest = .idle
            return
        }
        let directory = preflightDirectory
        preflightDirectory = nil
        preflightTest = .idle
        if let directory {
            Task.detached(priority: .utility) {
                try? FileManager.default.removeItem(at: directory)
            }
        }
    }

    /// Imports an existing audio or video file as a new meeting and transcribes it. The file is
    /// copied into the recording library so the imported audio becomes the source of truth, exactly
    /// like a live recording. Whisper (via FFmpeg) decodes any supported container directly, so no
    /// conversion is needed here.
    func importRecording(from sourceURL: URL, title: String) async -> UUID? {
        guard recordingState == .idle, !isImporting, !isPreflightTestActive else { return nil }
        guard !isInstallingRecognitionRuntime else {
            alertMessage = "Wait for the local recognition model installation to finish before importing."
            return nil
        }
        refreshRecordingPreflight()
        if let available = recordingPreflight.availableStorageBytes {
            // The file is copied into the library, so require room for it plus a safety margin.
            let sourceSize = (try? sourceURL.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
            let needed = Int64(sourceSize) + 500_000_000
            if available < needed {
                alertMessage = "Importing this recording needs about \(ByteCountFormatter.string(fromByteCount: needed, countStyle: .file)) free, but less is available. Free some storage and try again."
                return nil
            }
        }
        isImporting = true
        let id = UUID()
        let directory = store.recordingDirectoryURL(for: id)
        let cleanTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            let copiedURL = try await Task.detached(priority: .userInitiated) {
                try Self.copyImportedRecording(from: sourceURL, into: directory)
            }.value
            let duration = await Self.loadDuration(of: copiedURL)
            let fallbackTitle = sourceURL.deletingPathExtension().lastPathComponent
            let displayTitle = cleanTitle.isEmpty
                ? (fallbackTitle.isEmpty ? "Imported Recording" : fallbackTitle)
                : cleanTitle
            store.upsert(MeetingRecord(
                id: id,
                title: displayTitle,
                duration: duration,
                recordingPath: store.relativeRecordingPath(for: copiedURL),
                status: .recorded
            ))
            isImporting = false
            refreshRuntime()
            if isSelectedEngineInstalled {
                beginTranscription(id: id)
            } else {
                alertMessage = "Recording imported and saved on this Mac. Install the selected transcription model in Settings, then choose Transcribe."
            }
            return id
        } catch {
            isImporting = false
            try? FileManager.default.removeItem(at: directory)
            alertMessage = "The recording could not be imported: \(error.localizedDescription)"
            return nil
        }
    }

    /// Imports several files, enqueueing each for transcription. Returns the first meeting's id so
    /// the UI can navigate to it. Only a single-file import adopts the typed title.
    func importRecordings(from urls: [URL], title: String) async -> UUID? {
        var firstID: UUID?
        for url in urls {
            let itemTitle = urls.count == 1 ? title : ""
            if let id = await importRecording(from: url, title: itemTitle), firstID == nil {
                firstID = id
            }
        }
        return firstID
    }

    nonisolated private static func copyImportedRecording(
        from sourceURL: URL,
        into directory: URL
    ) throws -> URL {
        let didAccess = sourceURL.startAccessingSecurityScopedResource()
        defer { if didAccess { sourceURL.stopAccessingSecurityScopedResource() } }

        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        let ext = sourceURL.pathExtension.isEmpty ? "wav" : sourceURL.pathExtension.lowercased()
        let destination = directory.appendingPathComponent("recording").appendingPathExtension(ext)
        if FileManager.default.fileExists(atPath: destination.path) {
            try FileManager.default.removeItem(at: destination)
        }
        try FileManager.default.copyItem(at: sourceURL, to: destination)
        return destination
    }

    nonisolated private static func loadDuration(of url: URL) async -> TimeInterval {
        let asset = AVURLAsset(url: url)
        guard let duration = try? await asset.load(.duration) else { return 0 }
        let seconds = duration.seconds
        return seconds.isFinite && seconds > 0 ? seconds : 0
    }

    /// Requests transcription for a meeting. If another transcription is already running, this one
    /// waits in the queue and starts automatically when the active one finishes.
    func beginTranscription(id: UUID) {
        guard !isInstallingRecognitionRuntime else {
            alertMessage = "Wait for the local recognition model installation to finish before transcribing."
            return
        }
        // A second-opinion or segment re-run is holding the engine; don't start a normal run atop it (F140).
        guard !isRunningAuxiliaryEngine else {
            alertMessage = "Finish the second-opinion or segment re-run before transcribing this meeting."
            return
        }
        refreshRuntime()
        let settings = MeetingTranscriptionSelection(
            engine: selectedEngine,
            language: selectedLanguage
        )
        let engineIsInstalled = settings.engine == .qwenBalanced
            ? isQwenInstalled
            : isRuntimeInstalled
        guard engineIsInstalled else {
            alertMessage = settings.engine == .qwenBalanced
                ? QwenASRError.runtimeNotInstalled.localizedDescription
                : LocalWhisperError.runtimeNotInstalled.localizedDescription
            return
        }
        guard transcription.enqueue(id) else { return }
        transcriptionSettings.snapshot(settings, for: id)
        pumpTranscriptionQueue()
    }

    /// Starts the next queued transcription if nothing is currently running.
    private func pumpTranscriptionQueue() {
        guard let next = transcription.startNext() else { return }
        // A pending id never has a live task (tasks exist only for the active job and are cleared
        // before finishActive), so this holds by construction — asserted rather than guarded, so a
        // future regression can never strand the active slot with no task.
        assert(transcriptionTasks[next] == nil, "pending transcription unexpectedly had a task")
        let task = Task {
            await performTranscription(id: next)
            transcriptionTasks[next] = nil
            transcriptionSettings.remove(next)
            transcription.finishActive()
            pumpTranscriptionQueue()
        }
        transcriptionTasks[next] = task
    }

    func cancelTranscription(id: UUID) {
        // A waiting job is just dropped; an active job is cancelled and its task completion frees
        // the slot and starts the next one.
        if transcription.isPending(id) {
            transcription.remove(id)
            transcriptionSettings.remove(id)
            return
        }
        if transcription.activeID == id {
            transcriptionTasks[id]?.cancel()
        }
    }

    /// Deletes a meeting, first removing it from the transcription queue (dropping a pending job or
    /// cancelling an active one) so no ghost remains to run against a deleted recording.
    func deleteMeeting(id: UUID) {
        cancelTranscription(id: id)
        store.delete(id: id)
    }

    func summarize(id: UUID, style: SummaryStyle = .balanced) {
        guard summarizationTasks[id] == nil else { return }
        guard let key = KeychainStore.string(for: Self.claudeAPIKeyAccount) else {
            alertMessage = SummarizerError.missingAPIKey.localizedDescription
            return
        }
        guard activeSummarizationID == nil else {
            alertMessage = "Another meeting is being summarized. Try again when it finishes."
            return
        }
        guard let meeting = store.meeting(id: id) else { return }

        activeSummarizationID = id
        let transcript = meeting.transcriptText
        let language = meeting.languageCode
        let task = Task {
            await performSummarization(id: id, apiKey: key, transcript: transcript, language: language, style: style)
            summarizationTasks[id] = nil
            activeSummarizationID = nil
        }
        summarizationTasks[id] = task
    }

    func performSummarization(
        id: UUID,
        apiKey: String,
        transcript: String,
        language: String?,
        style: SummaryStyle
    ) async {
        let summarizer = makeSummarizer(apiKey)
        do {
            let summary = try await summarizer.summarize(transcript: transcript, language: language, style: style)
            store.update(id: id) { $0.summary = summary }
        } catch {
            alertMessage = error.localizedDescription
        }
    }

    /// Proposed spelling corrections toward the user's vocabulary for a meeting's transcript (F82).
    /// Read-only — computes over the stored segments; the user reviews before any apply.
    func glossaryCorrections(for id: UUID) -> [GlossaryCorrection] {
        guard let meeting = store.meeting(id: id) else { return [] }
        return GlossaryCorrector.corrections(vocabulary: store.vocabulary, segments: meeting.segments)
    }

    /// Applies the user-accepted corrections to a meeting's transcript, rebuilding the timestamped
    /// text from the corrected segments. Skipped when the transcript was hand-edited (segment-derived
    /// text no longer matches what's shown). The recording is never opened (F82).
    func applyGlossaryCorrections(_ corrections: [GlossaryCorrection], to id: UUID) {
        guard let meeting = store.meeting(id: id), !meeting.isTranscriptEdited, !corrections.isEmpty else { return }
        let corrected = GlossaryCorrector.apply(corrections, to: meeting.segments)
        store.update(id: id) {
            $0.segments = corrected
            $0.transcriptText = TranscriptFormatter.timestamped(corrected)
        }
    }

    /// Whether the segments reconstruct the full text (by alphanumeric character count). Segments are
    /// derived from the text, so equal-or-greater coverage means no content is lost; a shortfall means
    /// the alignment was partial and the segment-derived text would drop content (F144).
    private static func segmentsCoverText(_ segments: [TranscriptSegment], _ fullText: String) -> Bool {
        func alphanumericCount(_ s: String) -> Int {
            s.unicodeScalars.reduce(0) { CharacterSet.alphanumerics.contains($1) ? $0 + 1 : $0 }
        }
        let full = alphanumericCount(fullText)
        guard full > 0 else { return true } // no text to lose
        return alphanumericCount(segments.map(\.text).joined()) >= full
    }

    /// Flush any pending debounced transcript/notes write immediately. Called from the app-lifecycle
    /// observers (termination, resign-active) so an edit made in the last debounce window is not lost on
    /// a normal quit — the editor's `.onDisappear` flush doesn't fire reliably on app termination (F138).
    func flushPendingWrites() {
        store.flushPendingEdits()
    }

    func recoverInterruptedTranscriptions() {
        for meeting in store.meetings where meeting.status == .processing {
            store.update(id: meeting.id) {
                $0.status = .recorded
                $0.errorMessage = "Local transcription was interrupted. Start it again; the recording is unchanged."
            }
        }
    }

    private func performTranscription(id: UUID) async {
        // The meeting may have been deleted while queued; that is not an error.
        guard let meeting = store.meeting(id: id),
              let settings = transcriptionSettings.selection(for: id) else {
            return
        }
        store.update(id: id) {
            $0.status = .processing
            $0.errorMessage = nil
        }

        do {
            let recordingURL = store.recordingURL(for: meeting)
            let result = try await executeEngine(settings, on: recordingURL) { progress in
                await self.apply(progress: progress, to: id)
            }
            apply(result: result, to: id, requestedLanguage: settings.language, engine: settings.engine)
        } catch is CancellationError {
            handleCancellation(id: id)
        } catch {
            handle(error: error, id: id)
        }
    }

    private func apply(progress: LocalTranscriptionProgress, to id: UUID) {
        transcriptionProgress[id] = progress
        // Persist the .processing transition once. Later progress ticks only move the in-memory
        // progress bar (transcriptionProgress isn't stored), so re-running the meeting index's
        // backup-validate + two atomic writes on every tick is pure waste.
        if store.meeting(id: id)?.status != .processing {
            store.update(id: id) { $0.status = .processing }
        }
    }

    /// Applies a completed transcription to the stored meeting. Exposed to `WhisperMeetTests` (not
    /// `private`) so the alignment-warning persistence hop is testable without a GUI (F30). The
    /// `requestedLanguage` is the engine snapshot's selected language, used for the
    /// "original language only" advisory (F32); it defaults to `.automatic`, which never flags.
    func apply(result: TranscriptionResult, to id: UUID, requestedLanguage: WhisperLanguage = .automatic, engine: MeetingTranscriptionEngine? = nil) {
        // Only use segment-derived (timestamped) text when the segments actually reconstruct the full
        // text; otherwise a partially-aligned result would drop content. Fall back to the complete
        // text and drop the incomplete segments so text and segments stay consistent (F144).
        let covers = !result.segments.isEmpty && Self.segmentsCoverText(result.segments, result.text)
        let effectiveSegments = covers ? result.segments : []
        store.update(id: id) {
            $0.status = .completed
            $0.transcriptText = effectiveSegments.isEmpty
                ? result.text
                : TranscriptFormatter.timestamped(effectiveSegments)
            $0.languageCode = result.languageCode
            // Revive the header confidence label from the quality review; nil (no claim) when the
            // transcript carries no scorable segments (F56).
            let quality = TranscriptQuality.review(effectiveSegments)
            $0.confidence = quality.isUnscored ? nil : quality.confidence
            $0.segments = effectiveSegments
            $0.errorMessage = nil
            // Carry the alignment warning onto the meeting so the detail view can explain why a
            // Qwen transcript has no seekable timestamps, instead of dropping it silently (F30).
            $0.alignmentWarning = result.alignmentWarning
            // "Original language only" advisory: if the user pinned a language and the transcript's
            // dominant script disagrees, surface it rather than trusting the model blindly. Advisory
            // only — the transcript and recording are untouched (F32).
            $0.languageWarning = LanguageConsistency.mismatchWarning(
                requested: requestedLanguage,
                transcript: result.text
            )
            // Freshly produced text is already final; never rebuild it from segments later.
            $0.transcriptNormalized = true
            // Record which engine produced this transcript so a later "second opinion" runs the genuine
            // other engine regardless of current Settings (F142).
            if let engine { $0.transcriptionEngine = engine }
        }
        transcriptionProgress[id] = nil
        postTranscriptionNotification(
            title: store.meeting(id: id)?.title ?? "Meeting",
            outcome: .completed,
            segmentCount: result.segments.count
        )
    }

    /// Local OS notification when a transcription finishes while the app is backgrounded. Reuses the
    /// dictation notification pattern; the body carries only the meeting title + outcome, never
    /// transcript content (F57). No-op when frontmost or on cancellation.
    private func postTranscriptionNotification(
        title: String,
        outcome: TranscriptionOutcome,
        segmentCount: Int
    ) {
        // `NSApp` is always set in the running app but nil in a headless test process; binding it
        // (rather than force-unwrapping) keeps production behaviour identical while letting
        // WhisperMeetTests drive `apply(result:)` without a GUI (a prerequisite for the F30 test).
        guard let app = NSApp else { return }
        guard TranscriptionNotification.shouldNotify(outcome: outcome, appIsActive: app.isActive),
              let content = TranscriptionNotification.content(
                title: title, outcome: outcome, segmentCount: segmentCount
              ) else { return }
        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert, .sound]) { _, _ in }
        let notification = UNMutableNotificationContent()
        notification.title = content.title
        notification.body = content.body
        center.add(UNNotificationRequest(identifier: UUID().uuidString, content: notification, trigger: nil))
    }

    private func handleCancellation(id: UUID) {
        store.update(id: id) {
            $0.status = .recorded
            $0.errorMessage = "Local transcription was cancelled. The recording is unchanged."
        }
        transcriptionProgress[id] = nil
    }

    /// Privacy-safe diagnostics JSON built from the live library (F86 → delivers F70). The mapping and
    /// its exclusion guarantee (never transcript, summary, vocabulary, title, or paths) are unit-tested
    /// in `DiagnosticsExport`; this hop only supplies the live store and real recording byte sizes.
    func diagnosticsJSON() -> String {
        let input = DiagnosticsExport.input(
            meetings: store.meetings,
            vocabulary: store.vocabulary,
            recordingBytes: { meeting in
                let path = store.recordingURL(for: meeting).path
                let size = try? FileManager.default.attributesOfItem(atPath: path)[.size]
                return (size as? NSNumber)?.int64Value
            }
        )
        return DiagnosticsBundleBuilder.json(input)
    }

    private func handle(error: Error, id: UUID) {
        // Classify the failure so the message tells the user what to actually do (install / re-import /
        // retry) instead of a blind "Transcribe" retry (F68).
        let category = TranscriptionFailureClassifier.classify(error)
        var message = category.explanation
        // Keep the underlying detail (e.g. a subprocess message) for transient/subprocess failures.
        if category.action == .retry {
            let detail = error.localizedDescription
            if !detail.isEmpty { message += " (\(detail))" }
            let recordingIsSafe = store.meeting(id: id).map {
                FileManager.default.fileExists(atPath: store.recordingURL(for: $0).path)
            } ?? false
            if recordingIsSafe { message += " The recording is safe on this Mac." }
        }
        store.update(id: id) {
            $0.status = .failed
            $0.errorMessage = message
        }
        transcriptionProgress[id] = nil
        alertMessage = message
        postTranscriptionNotification(
            title: store.meeting(id: id)?.title ?? "Meeting",
            outcome: .failed,
            segmentCount: 0
        )
    }

    private func runInstaller(scriptURL: URL, runtimeDirectory: URL) async throws {
        try await Task.detached(priority: .userInitiated) {
            try FileManager.default.createDirectory(
                at: runtimeDirectory,
                withIntermediateDirectories: true
            )
            let logURL = runtimeDirectory.appendingPathComponent("install.log")
            try Data().write(to: logURL, options: .atomic)
            let handle = try FileHandle(forWritingTo: logURL)
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/zsh")
            process.arguments = [scriptURL.path, runtimeDirectory.path]
            process.standardOutput = handle
            process.standardError = handle
            try process.run()
            process.waitUntilExit()
            try? handle.close()
            let log = (try? String(contentsOf: logURL, encoding: .utf8)) ?? ""
            guard process.terminationStatus == 0 else {
                let tail = String(log.suffix(2_000))
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                throw LocalWhisperError.processFailed(
                    tail.isEmpty ? "The installer exited with status \(process.terminationStatus)." : tail
                )
            }
        }.value
    }

    private func runQwenInstaller(scriptURL: URL, runtimeDirectory: URL) async throws {
        try await Task.detached(priority: .userInitiated) {
            let parent = runtimeDirectory.deletingLastPathComponent()
            try FileManager.default.createDirectory(
                at: parent,
                withIntermediateDirectories: true
            )
            let logURL = parent.appendingPathComponent("qwen-install.log")
            try Data().write(to: logURL, options: .atomic)
            let handle = try FileHandle(forWritingTo: logURL)
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/zsh")
            process.arguments = [scriptURL.path, runtimeDirectory.path]
            process.standardOutput = handle
            process.standardError = handle
            try process.run()
            process.waitUntilExit()
            try? handle.close()
            let log = (try? String(contentsOf: logURL, encoding: .utf8)) ?? ""
            guard process.terminationStatus == 0 else {
                let tail = String(log.suffix(2_000))
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                throw QwenASRError.processFailed(
                    tail.isEmpty
                        ? "The installer exited with status \(process.terminationStatus)."
                        : tail
                )
            }
        }.value
    }
}

// MARK: - Library integrity sweep (F83 — wires the tested F66 core to the running app)

extension AppModel {
    /// One meeting's read-only integrity result. Advisory only — the audio is never repaired.
    struct LibraryIntegrityResult: Sendable, Equatable {
        let meeting: MeetingRecord
        let findings: [IntegrityFinding]
    }

    /// Read-only sweep of the whole meeting library. Reachable from launch (`performStartupRecovery`)
    /// and Settings ("Verify Library"). Flags missing/truncated/inconsistent audio; never touches it.
    func verifyLibraryIntegrity() -> [LibraryIntegrityResult] {
        var results: [LibraryIntegrityResult] = []
        for meeting in store.meetings {
            guard let descriptor = integrityDescriptor(for: meeting) else { continue }
            let findings = checkMeetingIntegrity(descriptor)
            if !findings.isEmpty {
                results.append(LibraryIntegrityResult(meeting: meeting, findings: findings))
            }
        }
        return results
    }

    /// Runs the sweep and surfaces any findings through the shared alert. The thin action behind the
    /// Settings "Verify Library" button (F83). Read-only — it reports, never repairs.
    func verifyLibrary() {
        let messages = Self.integrityMessages(verifyLibraryIntegrity())
        if messages.isEmpty {
            alertMessage = "Library check complete — no audio problems were found."
        } else {
            let header = "Library check found problems with \(messages.count) recording"
                + (messages.count == 1 ? "" : "s")
                + ". The recordings were not changed."
            alertMessage = ([header] + messages).joined(separator: "\n\n")
        }
    }

    /// Builds a read-only integrity descriptor for a meeting from its on-disk files. Returns nil for
    /// a meeting with no recording (nothing to check).
    private func integrityDescriptor(for meeting: MeetingRecord) -> MeetingIntegrityDescriptor? {
        guard !meeting.recordingPath.isEmpty else { return nil }
        let recordingURL = store.recordingURL(for: meeting)
        let directory = recordingURL.deletingLastPathComponent()
        return MeetingIntegrityDescriptor(
            recordingURL: recordingURL,
            sourceTracks: Self.sourceTracks(in: directory),
            indexDurationSeconds: meeting.duration > 0 ? meeting.duration : nil
        )
    }

    /// Maps integrity results into user-facing advisory lines. Presentation only.
    static func integrityMessages(_ results: [LibraryIntegrityResult]) -> [String] {
        results.flatMap { result in
            result.findings.map { describe($0, title: result.meeting.title) }
        }
    }

    /// Decodes `source-tracks.json` (or the recovery variant) into descriptor source tracks. A
    /// missing or unreadable manifest yields no track checks — an imported meeting may have none.
    static func sourceTracks(in directory: URL) -> [MeetingIntegrityDescriptor.SourceTrack] {
        struct Manifest: Decodable {
            struct Track: Decodable {
                let file: String
                let frameCount: Int64
            }
            let systemAudio: Track
            let microphoneAudio: Track
        }
        for name in ["source-tracks.json", "source-tracks.recovered.json"] {
            let url = directory.appendingPathComponent(name)
            guard let data = try? Data(contentsOf: url),
                  let manifest = try? JSONDecoder().decode(Manifest.self, from: data) else { continue }
            return [
                .init(
                    name: "system",
                    url: directory.appendingPathComponent(manifest.systemAudio.file),
                    expectedFrameCount: manifest.systemAudio.frameCount
                ),
                .init(
                    name: "microphone",
                    url: directory.appendingPathComponent(manifest.microphoneAudio.file),
                    expectedFrameCount: manifest.microphoneAudio.frameCount
                ),
            ]
        }
        return []
    }

    private static func describe(_ finding: IntegrityFinding, title: String) -> String {
        switch finding {
        case .recordingMissing:
            return "“\(title)”: the recording file is missing from disk. The meeting entry was kept; its audio could not be found."
        case .recordingEmpty:
            return "“\(title)”: the recording file is empty."
        case .wavHeaderUnreadable:
            return "“\(title)”: the recording’s audio header could not be read."
        case let .wavTruncated(declaredBytes, actualBytes):
            return "“\(title)”: the recording looks truncated — its header expects \(declaredBytes) bytes but only \(actualBytes) are present."
        case let .sourceTrackFrameMismatch(track, expectedFrames, actualFrames):
            return "“\(title)”: the \(track) source track is shorter than recorded (\(actualFrames) of \(expectedFrames) frames)."
        case let .durationInconsistent(headerSeconds, indexSeconds):
            return "“\(title)”: the recording’s length (\(String(format: "%.1f", headerSeconds))s) doesn’t match its saved duration (\(String(format: "%.1f", indexSeconds))s)."
        }
    }
}

// MARK: - Interrupted Qwen-install reclaim (F33 — wires the tested setup-qwen-asr.sh recovery to launch)

extension AppModel {
    /// Reclaim an interrupted Qwen install on launch — but only when orphaned install artifacts
    /// actually exist under the runtime parent, so a clean launch (or a Mac that never installed Qwen)
    /// spawns nothing. A force-quit mid-install can strand the previous ~4 GB runtime in a
    /// `.Qwen3ASR-backup-*` dir while `Qwen3ASR/` is gone and Qwen reports "not installed"; the tested
    /// recovery-only reclaim restores it (or clears an incomplete one) without a manual reinstall
    /// (F33). Returns whether the reclaim was run. The reclaim itself is the injected
    /// `runQwenInstallRecovery` seam, so this hop is headless-testable without spawning a process.
    @discardableResult
    func reclaimInterruptedQwenInstall(
        runtimeDirectory: URL = QwenASRRuntime.managedDirectory()
    ) async -> Bool {
        let parent = runtimeDirectory.deletingLastPathComponent()
        guard Self.hasOrphanedQwenInstallArtifacts(in: parent) else { return false }
        _ = await runQwenInstallRecovery(runtimeDirectory)
        return true
    }

    /// True when the runtime parent holds installer-owned orphan artifacts — a leftover backup or an
    /// abandoned staging directory from an interrupted Qwen install. Only the installer's hidden
    /// `.Qwen3ASR-backup-*` / `.Qwen3ASR-install-*` names match, so this never fires on a clean runtime
    /// (the live `Qwen3ASR/`, `venv/`, and helper carry none of these prefixes).
    nonisolated static func hasOrphanedQwenInstallArtifacts(in parent: URL) -> Bool {
        guard let entries = try? FileManager.default.contentsOfDirectory(atPath: parent.path) else {
            return false
        }
        return entries.contains {
            $0.hasPrefix(".Qwen3ASR-backup-") || $0.hasPrefix(".Qwen3ASR-install-")
        }
    }

    /// Spawns the bundled `setup-qwen-asr.sh` in recovery-only mode over the runtime directory and
    /// returns its exit status. Runs off the main actor. Returns a non-zero sentinel if the bundled
    /// script is missing or the process cannot start.
    nonisolated static func spawnQwenInstallRecovery(runtimeDirectory: URL) async -> Int32 {
        guard let scriptURL = Bundle.main.url(forResource: "setup-qwen-asr", withExtension: "sh") else {
            return -1
        }
        return await Task.detached(priority: .utility) {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/zsh")
            process.arguments = [scriptURL.path, runtimeDirectory.path]
            var environment = ProcessInfo.processInfo.environment
            environment["QWEN_INSTALL_RECOVERY_ONLY"] = "1"
            process.environment = environment
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            do {
                try process.run()
                process.waitUntilExit()
                return process.terminationStatus
            } catch {
                return -1
            }
        }.value
    }
}
