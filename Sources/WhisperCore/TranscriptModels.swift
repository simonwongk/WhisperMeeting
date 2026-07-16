import Foundation

public struct TranscriptionOptions: Sendable, Equatable {
    public let keyterms: [String]
    public let expectedSpeakers: Int?

    public static func accuracyFirst(
        keyterms: [String] = [],
        expectedSpeakers: Int? = nil
    ) -> Self {
        Self(
            keyterms: keyterms,
            expectedSpeakers: expectedSpeakers
        )
    }
}

public enum TranscriptionProgress: Sendable, Equatable {
    case uploading
    case queued
    case processing
    case fetchingTranscript
}

public struct TranscriptSegment: Codable, Sendable, Equatable, Identifiable {
    public var id: String {
        "\(speaker ?? "")-\(start ?? -1)-\(end ?? -1)-\(text)"
    }

    public let speaker: String?
    public let start: Double?
    public let end: Double?
    public let text: String

    public init(
        speaker: String?,
        start: Double?,
        end: Double?,
        text: String
    ) {
        self.speaker = speaker
        self.start = start
        self.end = end
        self.text = text
    }
}

public struct TranscriptionResult: Sendable, Equatable {
    public let id: String
    public let text: String
    public let languageCode: String?
    public let audioDuration: Double?
    public let confidence: Double?
    public let segments: [TranscriptSegment]

    public init(
        id: String,
        text: String,
        languageCode: String?,
        audioDuration: Double?,
        confidence: Double?,
        segments: [TranscriptSegment]
    ) {
        self.id = id
        self.text = text
        self.languageCode = languageCode
        self.audioDuration = audioDuration
        self.confidence = confidence
        self.segments = segments
    }
}
