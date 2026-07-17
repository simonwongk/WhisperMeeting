import Foundation

/// The structured result of summarizing a meeting transcript.
public struct MeetingSummary: Codable, Sendable, Equatable {
    public var summary: String
    public var keyPoints: [String]
    public var actionItems: [String]

    public init(summary: String, keyPoints: [String], actionItems: [String]) {
        self.summary = summary
        self.keyPoints = keyPoints
        self.actionItems = actionItems
    }
}

public enum SummarizerError: LocalizedError, Sendable, Equatable {
    case missingAPIKey
    case emptyTranscript
    case requestFailed(String)
    case httpStatus(Int, String)
    case refused(String)
    case unreadableResponse
    case emptyResponse

    public var errorDescription: String? {
        switch self {
        case .missingAPIKey:
            return "Add a Claude API key in Settings to create summaries."
        case .emptyTranscript:
            return "This meeting has no transcript to summarize yet."
        case let .requestFailed(message):
            return "The summary request could not be sent: \(message)"
        case let .httpStatus(code, message):
            if code == 401 {
                return "Claude rejected the API key. Check it in Settings. (\(message))"
            }
            return "Claude returned an error (HTTP \(code)): \(message)"
        case let .refused(message):
            return "Claude declined to summarize this transcript: \(message)"
        case .unreadableResponse:
            return "Claude returned a summary the app could not read."
        case .emptyResponse:
            return "Claude returned an empty summary."
        }
    }
}

/// Produces a `MeetingSummary` from a transcript. Implemented by the cloud
/// `ClaudeSummarizer` today; a local engine can adopt the same interface later.
public protocol MeetingSummarizer: Sendable {
    func summarize(transcript: String, language: String?) async throws -> MeetingSummary
}
