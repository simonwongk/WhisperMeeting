import Foundation
import WhisperCore

enum MeetingStatus: String, Codable, Sendable {
    case recorded
    case processing
    case completed
    case failed

    init(from decoder: Decoder) throws {
        let value = try decoder.singleValueContainer().decode(String.self)
        switch value {
        case "recorded": self = .recorded
        case "uploading", "queued", "processing": self = .processing
        case "completed": self = .completed
        case "failed": self = .failed
        default: self = .recorded
        }
    }

    var title: String {
        switch self {
        case .recorded: "Ready to transcribe"
        case .processing: "Transcribing"
        case .completed: "Completed"
        case .failed: "Needs attention"
        }
    }
}

struct MeetingRecord: Codable, Identifiable, Sendable, Equatable {
    let id: UUID
    var title: String
    let createdAt: Date
    var duration: TimeInterval
    var recordingPath: String
    var status: MeetingStatus
    var transcriptText: String
    var languageCode: String?
    var confidence: Double?
    var segments: [TranscriptSegment]
    var errorMessage: String?
    var summary: MeetingSummary?
    /// Whether the transcript text has been finalized (either freshly produced with inline
    /// timestamps, or migrated once from an older plain-text transcript). Optional so meeting
    /// indexes written before this field still decode. Once true, `transcriptText` is never
    /// rebuilt from `segments`, so user edits are safe.
    var transcriptNormalized: Bool?

    init(
        id: UUID = UUID(),
        title: String,
        createdAt: Date = Date(),
        duration: TimeInterval = 0,
        recordingPath: String = "",
        status: MeetingStatus = .recorded,
        transcriptText: String = "",
        languageCode: String? = nil,
        confidence: Double? = nil,
        segments: [TranscriptSegment] = [],
        errorMessage: String? = nil,
        summary: MeetingSummary? = nil,
        transcriptNormalized: Bool? = nil
    ) {
        self.id = id
        self.title = title
        self.createdAt = createdAt
        self.duration = duration
        self.recordingPath = recordingPath
        self.status = status
        self.transcriptText = transcriptText
        self.languageCode = languageCode
        self.confidence = confidence
        self.segments = segments
        self.errorMessage = errorMessage
        self.summary = summary
        self.transcriptNormalized = transcriptNormalized
    }
}

struct OrphanedRecording: Sendable, Equatable {
    let id: UUID
    let directory: URL
    let createdAt: Date
}

@MainActor
final class MeetingStore: ObservableObject {
    @Published private(set) var meetings: [MeetingRecord] = []
    @Published var vocabulary: [String] = []
    @Published private(set) var storageErrorMessage: String?

    private(set) var startupRecoveryMessages: [String] = []

    let rootDirectory: URL
    private let meetingFiles: BackupJSONStore<[MeetingRecord]>
    private let vocabularyFiles: BackupJSONStore<[String]>

    init(rootDirectory: URL? = nil) {
        let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first!
        self.rootDirectory = rootDirectory
            ?? appSupport.appendingPathComponent("WhisperMeet", isDirectory: true)
        meetingFiles = BackupJSONStore(
            primaryURL: self.rootDirectory.appendingPathComponent("meetings.json"),
            backupURL: self.rootDirectory.appendingPathComponent("meetings.backup.json")
        )
        vocabularyFiles = BackupJSONStore(
            primaryURL: self.rootDirectory.appendingPathComponent("vocabulary.json"),
            backupURL: self.rootDirectory.appendingPathComponent("vocabulary.backup.json")
        )

        do {
            try FileManager.default.createDirectory(
                at: self.rootDirectory,
                withIntermediateDirectories: true
            )
        } catch {
            startupRecoveryMessages.append(
                "WhisperMeet could not open its storage folder: \(error.localizedDescription)"
            )
            return
        }
        loadMeetings()
        loadVocabulary()
    }

    func recordingDirectory(for id: UUID) throws -> URL {
        let directory = recordingDirectoryURL(for: id)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    func recordingDirectoryURL(for id: UUID) -> URL {
        rootDirectory
            .appendingPathComponent("Recordings", isDirectory: true)
            .appendingPathComponent(id.uuidString, isDirectory: true)
    }

    func recordingURL(for meeting: MeetingRecord) -> URL {
        rootDirectory.appendingPathComponent(meeting.recordingPath)
    }

    func relativeRecordingPath(for url: URL) -> String {
        url.standardizedFileURL.path.replacingOccurrences(
            of: rootDirectory.standardizedFileURL.path + "/",
            with: ""
        )
    }

    func orphanedRecordings() throws -> [OrphanedRecording] {
        let recordingsDirectory = rootDirectory
            .appendingPathComponent("Recordings", isDirectory: true)
        guard FileManager.default.fileExists(atPath: recordingsDirectory.path) else {
            return []
        }
        let indexedDirectories = Set(meetings.map {
            recordingURL(for: $0).deletingLastPathComponent().standardizedFileURL.path
        })
        let urls = try FileManager.default.contentsOfDirectory(
            at: recordingsDirectory,
            includingPropertiesForKeys: [.isDirectoryKey, .creationDateKey],
            options: [.skipsHiddenFiles]
        )
        return urls.compactMap { url in
            guard !indexedDirectories.contains(url.standardizedFileURL.path),
                  let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .creationDateKey]),
                  values.isDirectory == true,
                  let id = UUID(uuidString: url.lastPathComponent) else {
                return nil
            }
            return OrphanedRecording(
                id: id,
                directory: url,
                createdAt: values.creationDate ?? .now
            )
        }
        .sorted { $0.createdAt < $1.createdAt }
    }

    func upsert(_ meeting: MeetingRecord) {
        if let index = meetings.firstIndex(where: { $0.id == meeting.id }) {
            meetings[index] = meeting
        } else {
            meetings.append(meeting)
        }
        meetings.sort { $0.createdAt > $1.createdAt }
        persistMeetings()
    }

    func update(id: UUID, _ mutation: (inout MeetingRecord) -> Void) {
        guard let index = meetings.firstIndex(where: { $0.id == id }) else { return }
        mutation(&meetings[index])
        persistMeetings()
    }

    func meeting(id: UUID) -> MeetingRecord? {
        meetings.first { $0.id == id }
    }

    func delete(id: UUID) {
        guard let meeting = meeting(id: id) else { return }
        let directory = recordingURL(for: meeting).deletingLastPathComponent()
        try? FileManager.default.removeItem(at: directory)
        meetings.removeAll { $0.id == id }
        persistMeetings()
    }

    func addVocabulary(_ terms: [String]) {
        vocabulary = Self.promptSafeTerms(vocabulary + terms)
        persistVocabulary()
    }

    func removeVocabulary(_ term: String) {
        vocabulary.removeAll { $0 == term }
        persistVocabulary()
    }

    func clearStorageError() {
        storageErrorMessage = nil
    }

    private static func normalizeTerm(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func promptSafeTerms(_ values: [String]) -> [String] {
        let candidates = Array(Set(values.map(normalizeTerm).filter { !$0.isEmpty }))
            .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
        var result: [String] = []
        var characterCount = 0
        for term in candidates where result.count < 100 {
            let separatorCount = result.isEmpty ? 0 : 2
            guard characterCount + separatorCount + term.count <= 1_000 else { continue }
            result.append(term)
            characterCount += separatorCount + term.count
        }
        return result
    }

    private func persistMeetings() {
        do {
            try meetingFiles.save(meetings)
            storageErrorMessage = nil
        } catch {
            storageErrorMessage = "Meeting changes could not be saved. The recording files and last readable index copy remain on this Mac. \(error.localizedDescription)"
        }
    }

    private func persistVocabulary() {
        do {
            try vocabularyFiles.save(vocabulary)
            storageErrorMessage = nil
        } catch {
            storageErrorMessage = "Vocabulary changes could not be saved. The last readable copy remains on this Mac. \(error.localizedDescription)"
        }
    }

    private func loadMeetings() {
        do {
            guard let result = try meetingFiles.load() else { return }
            meetings = result.value.sorted { $0.createdAt > $1.createdAt }
            if result.source == .backup {
                startupRecoveryMessages.append(
                    "The meeting index was damaged, so WhisperMeet restored the previous readable backup. No recording folders were deleted."
                )
                try meetingFiles.save(meetings)
            }
        } catch {
            startupRecoveryMessages.append(error.localizedDescription)
        }
    }

    private func loadVocabulary() {
        do {
            guard let result = try vocabularyFiles.load() else { return }
            vocabulary = Self.promptSafeTerms(result.value)
            if result.source == .backup {
                startupRecoveryMessages.append(
                    "The vocabulary index was damaged, so WhisperMeet restored the previous readable backup."
                )
                try vocabularyFiles.save(vocabulary)
            }
        } catch {
            startupRecoveryMessages.append(error.localizedDescription)
        }
    }
}
