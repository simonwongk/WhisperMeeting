import AVFoundation
import CoreGraphics
import Foundation
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
final class AppModel: ObservableObject {
    enum RecordingState: Equatable {
        case idle
        case starting
        case recording(startedAt: Date)
        case stopping
    }

    @Published private(set) var recordingState: RecordingState = .idle
    @Published private(set) var activeMeetingID: UUID?
    @Published private(set) var transcription = TranscriptionQueue()
    @Published private(set) var transcriptionProgress: [UUID: LocalTranscriptionProgress] = [:]
    @Published private(set) var activeSummarizationID: UUID?
    @Published private(set) var hasClaudeAPIKey: Bool = false
    @Published private(set) var runtimeExecutableURL: URL?
    @Published private(set) var isInstallingRuntime = false
    @Published private(set) var installationMessage: String?
    @Published private(set) var recordingPreflight = RecordingPreflightStatus.checking
    @Published private(set) var recordingHealth: RecordingHealthSnapshot?
    @Published private(set) var recordingLevels: RecordingLevels?
    @Published private(set) var isImporting = false
    @Published var selectedModel: WhisperModel {
        didSet { defaults.set(selectedModel.rawValue, forKey: Self.modelKey) }
    }
    @Published var selectedLanguage: WhisperLanguage {
        didSet { defaults.set(selectedLanguage.rawValue, forKey: Self.languageKey) }
    }
    @Published var alertMessage: String?

    let store: MeetingStore
    private let recorder: AudioCaptureEngine
    private let defaults: UserDefaults
    private var transcriptionTasks: [UUID: Task<Void, Never>] = [:]
    private var summarizationTasks: [UUID: Task<Void, Never>] = [:]
    private var didPerformStartupRecovery = false

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
        selectedModel = WhisperModel(
            rawValue: defaults.string(forKey: Self.modelKey) ?? ""
        ) ?? .large
        selectedLanguage = WhisperLanguage(
            rawValue: defaults.string(forKey: Self.languageKey) ?? ""
        ) ?? .automatic
        runtimeExecutableURL = LocalWhisperRuntime.findExecutable()
        hasClaudeAPIKey = KeychainStore.string(for: Self.claudeAPIKeyAccount) != nil
        refreshRecordingPreflight()
    }

    var isRuntimeInstalled: Bool {
        runtimeExecutableURL != nil
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
    }

    func refreshRecordingPreflight() {
        recordingPreflight = .inspect(storageDirectory: store.rootDirectory)
    }

    func performStartupRecovery() async {
        guard !didPerformStartupRecovery else { return }
        didPerformStartupRecovery = true
        refreshRuntime()
        refreshRecordingPreflight()
        var messages = store.startupRecoveryMessages

        do {
            for orphan in try store.orphanedRecordings() {
                let recovered = try await Task.detached(priority: .utility) {
                    try InterruptedRecordingRecovery.recover(in: orphan.directory)
                }.value
                guard let recovered else {
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
                // A recovered imported (non-WAV) file has no readable duration in the core WAV
                // parser; recompute it here where AVFoundation is available.
                let duration = recovered.duration > 0
                    ? recovered.duration
                    : await Self.loadDuration(of: recovered.recordingURL)
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
        if !messages.isEmpty {
            alertMessage = messages.joined(separator: "\n\n")
        }
    }

    func installLocalWhisper() {
        guard !isInstallingRuntime else { return }
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

    func startRecording() async {
        guard recordingState == .idle, !isImporting else { return }
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
        recordingLevels = nil
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
            } onLevels: { [weak self] levels in
                Task { @MainActor [weak self] in
                    guard let self,
                          self.activeMeetingID == id,
                          case .recording = self.recordingState else {
                        return
                    }
                    self.recordingLevels = levels
                }
            }
            recordingState = .recording(startedAt: Date())
            refreshRecordingPreflight()
        } catch {
            recordingState = .idle
            activeMeetingID = nil
            recordingHealth = nil
            recordingLevels = nil
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
                recordingPath: store.relativeRecordingPath(for: artifact.mixedRecordingURL)
            )
            store.upsert(meeting)
            recordingState = .idle
            activeMeetingID = nil
            recordingHealth = nil
            recordingLevels = nil
            refreshRecordingPreflight()

            refreshRuntime()
            if isRuntimeInstalled {
                beginTranscription(id: id)
            } else {
                alertMessage = "Recording saved on this Mac. Install Local Whisper in Settings, then choose Transcribe."
            }
            return id
        } catch let recordingError {
            recordingState = .idle
            activeMeetingID = nil
            recordingHealth = nil
            recordingLevels = nil
            refreshRecordingPreflight()
            do {
                let recovered = try await Task.detached(priority: .userInitiated) {
                    try InterruptedRecordingRecovery.recover(in: directory)
                }.value
                if let recovered {
                    let fallbackTitle = "Recovered Meeting \(Date.now.formatted(date: .abbreviated, time: .shortened))"
                    let cleanTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
                    store.upsert(MeetingRecord(
                        id: id,
                        title: cleanTitle.isEmpty ? fallbackTitle : cleanTitle,
                        duration: recovered.duration,
                        recordingPath: store.relativeRecordingPath(for: recovered.recordingURL),
                        errorMessage: "The recording was recovered after a finishing error. The source files remain on this Mac, and transcription can be tried again."
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

    func cancelRecording() async {
        await recorder.cancel()
        recordingState = .idle
        activeMeetingID = nil
        recordingHealth = nil
        recordingLevels = nil
        refreshRecordingPreflight()
    }

    /// Imports an existing audio or video file as a new meeting and transcribes it. The file is
    /// copied into the recording library so the imported audio becomes the source of truth, exactly
    /// like a live recording. Whisper (via FFmpeg) decodes any supported container directly, so no
    /// conversion is needed here.
    func importRecording(from sourceURL: URL, title: String) async -> UUID? {
        guard recordingState == .idle, !isImporting else { return nil }
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
            if isRuntimeInstalled {
                beginTranscription(id: id)
            } else {
                alertMessage = "Recording imported and saved on this Mac. Install Local Whisper in Settings, then choose Transcribe."
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
        refreshRuntime()
        guard runtimeExecutableURL != nil else {
            alertMessage = LocalWhisperError.runtimeNotInstalled.localizedDescription
            return
        }
        guard transcription.enqueue(id) else { return }
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

    func summarize(id: UUID) {
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
            await performSummarization(id: id, apiKey: key, transcript: transcript, language: language)
            summarizationTasks[id] = nil
            activeSummarizationID = nil
        }
        summarizationTasks[id] = task
    }

    private func performSummarization(
        id: UUID,
        apiKey: String,
        transcript: String,
        language: String?
    ) async {
        let summarizer = ClaudeSummarizer(apiKey: apiKey)
        do {
            let summary = try await summarizer.summarize(transcript: transcript, language: language)
            store.update(id: id) { $0.summary = summary }
        } catch {
            alertMessage = error.localizedDescription
        }
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
        guard let meeting = store.meeting(id: id) else { return }
        guard let executableURL = runtimeExecutableURL else {
            alertMessage = LocalWhisperError.runtimeNotInstalled.localizedDescription
            return
        }
        store.update(id: id) {
            $0.status = .processing
            $0.errorMessage = nil
        }

        let client = LocalWhisperClient(
            executableURL: executableURL,
            modelDirectory: LocalWhisperRuntime.modelDirectory()
        )
        do {
            let result = try await client.transcribe(
                recordingAt: store.recordingURL(for: meeting),
                options: .accuracyFirst(
                    model: selectedModel,
                    language: selectedLanguage,
                    keyterms: store.vocabulary
                )
            ) { progress in
                await self.apply(progress: progress, to: id)
            }
            apply(result: result, to: id)
        } catch is CancellationError {
            handleCancellation(id: id)
        } catch {
            handle(error: error, id: id)
        }
    }

    private func apply(progress: LocalTranscriptionProgress, to id: UUID) {
        transcriptionProgress[id] = progress
        store.update(id: id) { $0.status = .processing }
    }

    private func apply(result: TranscriptionResult, to id: UUID) {
        store.update(id: id) {
            $0.status = .completed
            $0.transcriptText = result.segments.isEmpty
                ? result.text
                : TranscriptFormatter.timestamped(result.segments)
            $0.languageCode = result.languageCode
            $0.confidence = nil
            $0.segments = result.segments
            $0.errorMessage = nil
            // Freshly produced text is already final; never rebuild it from segments later.
            $0.transcriptNormalized = true
        }
        transcriptionProgress[id] = nil
    }

    private func handleCancellation(id: UUID) {
        store.update(id: id) {
            $0.status = .recorded
            $0.errorMessage = "Local transcription was cancelled. The recording is unchanged."
        }
        transcriptionProgress[id] = nil
    }

    private func handle(error: Error, id: UUID) {
        let recordingIsSafe = store.meeting(id: id).map {
            FileManager.default.fileExists(atPath: store.recordingURL(for: $0).path)
        } ?? false
        let message = recordingIsSafe
            ? "\(error.localizedDescription) The recording is safe on this Mac; choose Transcribe to try again."
            : error.localizedDescription
        store.update(id: id) {
            $0.status = .failed
            $0.errorMessage = message
        }
        transcriptionProgress[id] = nil
        alertMessage = message
    }

    private func runInstaller(scriptURL: URL, runtimeDirectory: URL) async throws {
        try await Task.detached(priority: .userInitiated) {
            try FileManager.default.createDirectory(
                at: runtimeDirectory,
                withIntermediateDirectories: true
            )
            let logURL = runtimeDirectory.appendingPathComponent("install.log")
            FileManager.default.createFile(atPath: logURL.path, contents: nil)
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
}
