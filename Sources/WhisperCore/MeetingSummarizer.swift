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
    /// The on-device summarization model is not installed yet (F164). The user is offered an install
    /// rather than a dead end — mirrors `QwenASRError.runtimeNotInstalled`.
    case modelNotInstalled
    /// The local summarizer subprocess failed; the string carries its captured diagnostics tail (F164).
    case helperFailed(String)

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
            return "The summarizer returned an empty summary."
        case .modelNotInstalled:
            return "Install the local summarization model in Settings to create summaries on this Mac."
        case let .helperFailed(message):
            return "The local summarizer could not finish: \(message)"
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

/// Which engine produces a meeting summary. `local` (on-device, keyless, private) is the default;
/// `claude` is the opt-in cloud upgrade behind the same `MeetingSummarizer` protocol (F164).
public enum SummarizationEngine: String, Codable, CaseIterable, Sendable, Hashable {
    case local
    case claude

    public var displayName: String {
        switch self {
        case .local: return "Local (private, on-device)"
        case .claude: return "Claude (cloud)"
        }
    }
}

/// Produces a `MeetingSummary` from a transcript. Implemented by the on-device `LocalSummarizer`
/// (the keyless default) and the cloud `ClaudeSummarizer` (opt-in) behind one interface (F164).
public protocol MeetingSummarizer: Sendable {
    func summarize(transcript: String, language: String?, style: SummaryStyle) async throws -> MeetingSummary
}

public extension MeetingSummarizer {
    /// Source-compatible convenience for callers that don't choose a style (defaults to balanced).
    func summarize(transcript: String, language: String?) async throws -> MeetingSummary {
        try await summarize(transcript: transcript, language: language, style: .balanced)
    }
}
