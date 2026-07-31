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
    case responseTruncated
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
        case .responseTruncated:
            return "Claude's summary was cut off at the length limit. Summarize a shorter transcript, or raise the summary length limit and try again."
        case .unreadableResponse:
            return "Claude returned a summary the app could not read."
        case .emptyResponse:
            return "Claude returned an empty summary."
        }
    }
}

/// The shape/length of an opt-in Claude summary. Never changes the response schema or the
/// original-language ("do not translate") clause — only the style guidance (F63).
public enum SummaryStyle: String, Sendable, Equatable, CaseIterable {
    case balanced           // default: a balanced level of detail
    case brief              // short summary, only the most essential points
    case detailed           // fuller summary, comprehensive key points
    case actionItemsFocused // emphasize concrete follow-up tasks
}

/// Produces a `MeetingSummary` from a transcript. Implemented by the cloud
/// `ClaudeSummarizer` today; a local engine can adopt the same interface later.
public protocol MeetingSummarizer: Sendable {
    func summarize(transcript: String, language: String?, style: SummaryStyle) async throws -> MeetingSummary
}

public extension MeetingSummarizer {
    /// Source-compatible convenience for callers that don't choose a style (defaults to balanced).
    func summarize(transcript: String, language: String?) async throws -> MeetingSummary {
        try await summarize(transcript: transcript, language: language, style: .balanced)
    }
}
