import Foundation
import WhisperCore

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
    @Published private(set) var activeTranscriptionID: UUID?
    @Published private(set) var transcriptionProgress: [UUID: LocalTranscriptionProgress] = [:]
    @Published private(set) var runtimeExecutableURL: URL?
    @Published private(set) var isInstallingRuntime = false
    @Published private(set) var installationMessage: String?
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

    private static let modelKey = "localWhisperModel"
    private static let languageKey = "localWhisperLanguage"

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
    }

    var isRuntimeInstalled: Bool {
        runtimeExecutableURL != nil
    }

    var hasActiveTranscription: Bool {
        activeTranscriptionID != nil
    }

    func refreshRuntime() {
        runtimeExecutableURL = LocalWhisperRuntime.findExecutable()
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
        guard recordingState == .idle else { return }
        recordingState = .starting
        let id = UUID()
        do {
            let directory = try store.recordingDirectory(for: id)
            try await recorder.start(in: directory)
            activeMeetingID = id
            recordingState = .recording(startedAt: Date())
        } catch {
            recordingState = .idle
            activeMeetingID = nil
            alertMessage = error.localizedDescription
        }
    }

    func stopRecording(title: String) async -> UUID? {
        guard let id = activeMeetingID else { return nil }
        recordingState = .stopping
        do {
            let artifact = try await recorder.stop()
            let relativePath = artifact.mixedRecordingURL.path
                .replacingOccurrences(of: store.rootDirectory.path + "/", with: "")
            let fallbackTitle = "Meeting \(Date.now.formatted(date: .abbreviated, time: .shortened))"
            let cleanTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
            let meeting = MeetingRecord(
                id: id,
                title: cleanTitle.isEmpty ? fallbackTitle : cleanTitle,
                duration: artifact.duration,
                recordingPath: relativePath
            )
            store.upsert(meeting)
            recordingState = .idle
            activeMeetingID = nil

            refreshRuntime()
            if isRuntimeInstalled {
                beginTranscription(id: id)
            } else {
                alertMessage = "Recording saved on this Mac. Install Local Whisper in Settings, then choose Transcribe."
            }
            return id
        } catch {
            recordingState = .idle
            activeMeetingID = nil
            alertMessage = error.localizedDescription
            return nil
        }
    }

    func cancelRecording() async {
        await recorder.cancel()
        recordingState = .idle
        activeMeetingID = nil
    }

    func beginTranscription(id: UUID) {
        guard transcriptionTasks[id] == nil else { return }
        guard activeTranscriptionID == nil else {
            alertMessage = "Another meeting is being transcribed. Start this one after it finishes."
            return
        }
        refreshRuntime()
        guard runtimeExecutableURL != nil else {
            alertMessage = LocalWhisperError.runtimeNotInstalled.localizedDescription
            return
        }
        activeTranscriptionID = id
        let task = Task {
            await performTranscription(id: id)
            transcriptionTasks[id] = nil
            activeTranscriptionID = nil
        }
        transcriptionTasks[id] = task
    }

    func cancelTranscription(id: UUID) {
        transcriptionTasks[id]?.cancel()
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
        guard let meeting = store.meeting(id: id),
              let executableURL = runtimeExecutableURL else {
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
            $0.transcriptText = result.text
            $0.languageCode = result.languageCode
            $0.confidence = nil
            $0.segments = result.segments
            $0.errorMessage = nil
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
        store.update(id: id) {
            $0.status = .failed
            $0.errorMessage = error.localizedDescription
        }
        transcriptionProgress[id] = nil
        alertMessage = error.localizedDescription
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
