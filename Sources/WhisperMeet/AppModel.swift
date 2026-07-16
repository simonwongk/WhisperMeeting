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
    @Published private(set) var transcriptionProgress: [UUID: TranscriptionProgress] = [:]
    @Published var apiKey: String
    @Published var alertMessage: String?

    let store: MeetingStore
    private let recorder: AudioCaptureEngine
    private let client: WhisperAIClient
    private let keychain: KeychainStore

    convenience init() {
        self.init(
            store: MeetingStore(),
            recorder: AudioCaptureEngine(),
            client: WhisperAIClient(),
            keychain: KeychainStore()
        )
    }

    init(
        store: MeetingStore,
        recorder: AudioCaptureEngine,
        client: WhisperAIClient,
        keychain: KeychainStore
    ) {
        self.store = store
        self.recorder = recorder
        self.client = client
        self.keychain = keychain
        apiKey = keychain.loadAPIKey()
    }

    var hasValidAPIKey: Bool {
        apiKey.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("wai_")
    }

    func saveAPIKey() {
        do {
            try keychain.saveAPIKey(apiKey)
        } catch {
            alertMessage = error.localizedDescription
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

    func stopRecording(
        title: String,
        expectedSpeakers: Int?
    ) async -> UUID? {
        guard let id = activeMeetingID else { return nil }
        recordingState = .stopping
        do {
            let artifact = try await recorder.stop()
            let relativePath = artifact.mixedRecordingURL.path
                .replacingOccurrences(of: store.rootDirectory.path + "/", with: "")
            let fallbackTitle = "Meeting \(Date.now.formatted(date: .abbreviated, time: .shortened))"
            let meeting = MeetingRecord(
                id: id,
                title: title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    ? fallbackTitle
                    : title.trimmingCharacters(in: .whitespacesAndNewlines),
                duration: artifact.duration,
                recordingPath: relativePath
            )
            store.upsert(meeting)
            recordingState = .idle
            activeMeetingID = nil

            if hasValidAPIKey {
                Task { await transcribe(id: id, expectedSpeakers: expectedSpeakers) }
            } else {
                alertMessage = "Recording saved. Add your wai_… key in Settings, then choose Transcribe."
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

    func transcribe(id: UUID, expectedSpeakers: Int? = nil) async {
        guard hasValidAPIKey, let meeting = store.meeting(id: id) else {
            alertMessage = "Add a valid WhisperAI API key in Settings first."
            return
        }
        store.update(id: id) {
            $0.status = .uploading
            $0.errorMessage = nil
        }

        do {
            let result = try await client.transcribe(
                recordingAt: store.recordingURL(for: meeting),
                apiKey: apiKey.trimmingCharacters(in: .whitespacesAndNewlines),
                options: .accuracyFirst(
                    keyterms: store.vocabulary,
                    expectedSpeakers: expectedSpeakers
                )
            ) { progress in
                await self.apply(progress: progress, to: id)
            }
            store.update(id: id) {
                $0.status = .completed
                $0.transcriptID = result.id
                $0.transcriptText = result.text
                $0.languageCode = result.languageCode
                $0.confidence = result.confidence
                $0.segments = result.segments
                $0.errorMessage = nil
            }
            transcriptionProgress[id] = nil
        } catch is CancellationError {
            store.update(id: id) { $0.status = .recorded }
            transcriptionProgress[id] = nil
        } catch {
            store.update(id: id) {
                $0.status = .failed
                $0.errorMessage = error.localizedDescription
            }
            transcriptionProgress[id] = nil
            alertMessage = error.localizedDescription
        }
    }

    private func apply(progress: TranscriptionProgress, to id: UUID) {
        transcriptionProgress[id] = progress
        store.update(id: id) { meeting in
            switch progress {
            case .uploading: meeting.status = .uploading
            case .queued: meeting.status = .queued
            case .processing, .fetchingTranscript: meeting.status = .processing
            }
        }
    }
}
