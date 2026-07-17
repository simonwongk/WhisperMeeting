import Foundation

public enum WhisperModel: String, Codable, CaseIterable, Sendable, Hashable {
    case large
    case turbo

    public var displayName: String {
        switch self {
        case .large: "Large — best accuracy"
        case .turbo: "Turbo — much faster"
        }
    }
}

public enum WhisperLanguage: String, Codable, CaseIterable, Sendable, Hashable {
    case automatic
    case english
    case chinese

    public var displayName: String {
        switch self {
        case .automatic: "Detect automatically"
        case .english: "English"
        case .chinese: "Chinese (Mandarin)"
        }
    }

    var commandLineValue: String? {
        switch self {
        case .automatic: nil
        case .english: "English"
        case .chinese: "Chinese"
        }
    }
}

public struct LocalTranscriptionOptions: Sendable, Equatable {
    public let model: WhisperModel
    public let language: WhisperLanguage
    public let keyterms: [String]

    public static func accuracyFirst(
        model: WhisperModel = .large,
        language: WhisperLanguage = .automatic,
        keyterms: [String] = []
    ) -> Self {
        Self(model: model, language: language, keyterms: keyterms)
    }
}

public enum LocalTranscriptionProgress: Sendable, Equatable {
    case loadingModel
    case transcribing
}

public struct TranscriptSegment: Codable, Sendable, Equatable, Identifiable {
    public var id: String {
        "\(speaker ?? "")-\(start ?? -1)-\(end ?? -1)-\(text)"
    }

    public var speaker: String?
    public var start: Double?
    public var end: Double?
    public var text: String

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
