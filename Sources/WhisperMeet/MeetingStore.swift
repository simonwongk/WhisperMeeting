import Foundation
import WhisperCore

enum MeetingStatus: String, Codable, Sendable {
    case recorded
    case uploading
    case queued
    case processing
    case completed
    case failed

    var title: String {
        switch self {
        case .recorded: "Ready to transcribe"
        case .uploading: "Uploading"
        case .queued: "Queued"
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
    var transcriptID: String?
    var transcriptText: String
    var languageCode: String?
    var confidence: Double?
    var segments: [TranscriptSegment]
    var speakerNames: [String: String]
    var errorMessage: String?

    init(
        id: UUID = UUID(),
        title: String,
        createdAt: Date = Date(),
        duration: TimeInterval = 0,
        recordingPath: String = "",
        status: MeetingStatus = .recorded,
        transcriptID: String? = nil,
        transcriptText: String = "",
        languageCode: String? = nil,
        confidence: Double? = nil,
        segments: [TranscriptSegment] = [],
        speakerNames: [String: String] = [:],
        errorMessage: String? = nil
    ) {
        self.id = id
        self.title = title
        self.createdAt = createdAt
        self.duration = duration
        self.recordingPath = recordingPath
        self.status = status
        self.transcriptID = transcriptID
        self.transcriptText = transcriptText
        self.languageCode = languageCode
        self.confidence = confidence
        self.segments = segments
        self.speakerNames = speakerNames
        self.errorMessage = errorMessage
    }
}

@MainActor
final class MeetingStore: ObservableObject {
    @Published private(set) var meetings: [MeetingRecord] = []
    @Published var vocabulary: [String] = []

    let rootDirectory: URL
    private let indexURL: URL
    private let vocabularyURL: URL
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    init(rootDirectory: URL? = nil) {
        let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first!
        self.rootDirectory = rootDirectory
            ?? appSupport.appendingPathComponent("WhisperMeet", isDirectory: true)
        indexURL = self.rootDirectory.appendingPathComponent("meetings.json")
        vocabularyURL = self.rootDirectory.appendingPathComponent("vocabulary.json")

        encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        do {
            try FileManager.default.createDirectory(
                at: self.rootDirectory,
                withIntermediateDirectories: true
            )
            if let data = try? Data(contentsOf: indexURL) {
                meetings = try decoder.decode([MeetingRecord].self, from: data)
                    .sorted { $0.createdAt > $1.createdAt }
            }
            if let data = try? Data(contentsOf: vocabularyURL) {
                vocabulary = try decoder.decode([String].self, from: data)
            }
        } catch {
            assertionFailure("Could not initialize meeting storage: \(error)")
        }
    }

    func recordingDirectory(for id: UUID) throws -> URL {
        let directory = rootDirectory
            .appendingPathComponent("Recordings", isDirectory: true)
            .appendingPathComponent(id.uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    func recordingURL(for meeting: MeetingRecord) -> URL {
        rootDirectory.appendingPathComponent(meeting.recordingPath)
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
        let combined = vocabulary + terms
        vocabulary = Array(Set(combined.map(Self.normalizeTerm).filter { !$0.isEmpty }))
            .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
        persistVocabulary()
    }

    func removeVocabulary(_ term: String) {
        vocabulary.removeAll { $0 == term }
        persistVocabulary()
    }

    private static func normalizeTerm(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func persistMeetings() {
        do {
            try encoder.encode(meetings).write(to: indexURL, options: .atomic)
        } catch {
            assertionFailure("Could not save meetings: \(error)")
        }
    }

    private func persistVocabulary() {
        do {
            try encoder.encode(vocabulary).write(to: vocabularyURL, options: .atomic)
        } catch {
            assertionFailure("Could not save vocabulary: \(error)")
        }
    }
}
