import Foundation

/// Summarizes a transcript with the Claude API over raw HTTPS (there is no
/// official Anthropic Swift SDK). Uses structured outputs so the response is a
/// JSON object matching `MeetingSummary` rather than free text to scrape.
public struct ClaudeSummarizer: MeetingSummarizer {
    public static let defaultModel = "claude-opus-4-8"

    private let apiKey: String
    private let model: String
    private let maxTokens: Int
    private let baseURL: URL
    private let session: URLSession

    public init(
        apiKey: String,
        model: String = defaultModel,
        maxTokens: Int = 8_000,
        baseURL: URL = URL(string: "https://api.anthropic.com")!,
        session: URLSession = .shared
    ) {
        self.apiKey = apiKey
        self.model = model
        self.maxTokens = maxTokens
        self.baseURL = baseURL
        self.session = session
    }

    public func summarize(
        transcript: String,
        language: String?,
        style: SummaryStyle,
        template: MeetingTemplate
    ) async throws -> MeetingSummary {
        let trimmed = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw SummarizerError.missingAPIKey
        }
        guard !trimmed.isEmpty else { throw SummarizerError.emptyTranscript }

        let request = try makeRequest(transcript: trimmed, language: language, style: style, template: template)
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw SummarizerError.requestFailed(error.localizedDescription)
        }

        guard let http = response as? HTTPURLResponse else {
            throw SummarizerError.unreadableResponse
        }
        guard http.statusCode == 200 else {
            throw SummarizerError.httpStatus(http.statusCode, Self.errorMessage(from: data))
        }
        return try Self.decodeSummary(from: data)
    }

    private func makeRequest(transcript: String, language: String?, style: SummaryStyle, template: MeetingTemplate) throws -> URLRequest {
        var request = URLRequest(url: baseURL.appendingPathComponent("v1/messages"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")

        let body: [String: Any] = [
            "model": model,
            "max_tokens": maxTokens,
            "system": Self.systemPrompt(language: language, style: style, template: template),
            "messages": [
                ["role": "user", "content": transcript]
            ],
            "output_config": [
                "format": [
                    "type": "json_schema",
                    "schema": Self.schema
                ]
            ]
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return request
    }

    static func systemPrompt(
        language: String?,
        style: SummaryStyle = .balanced,
        template: MeetingTemplate = .general
    ) -> String {
        var prompt = """
        You summarize meeting transcripts. Read the transcript and produce:
        - summary: a concise paragraph capturing what the meeting was about and what was decided.
        - keyPoints: the most important points, decisions, and topics, one per item.
        - actionItems: concrete follow-up tasks or to-dos raised in the meeting, one per item. \
        Use an empty array if there are none.
        Write the summary, key points, and action items in the same language as the transcript. \
        Do not translate. Return only the fields requested.
        """
        prompt += "\n" + styleGuidance(style)
        // Template guidance reshapes how the fields are organized (F178) — it never changes the schema
        // or the do-not-translate clause above. Empty for `.general`, so the base prompt is unchanged.
        let templateGuidance = template.guidance
        if !templateGuidance.isEmpty {
            prompt += "\n" + templateGuidance
        }
        if let language, !language.isEmpty {
            prompt += "\nThe transcript's detected language code is \"\(language)\"."
        }
        return prompt
    }

    /// Style-specific guidance appended to the system prompt. The response schema and the
    /// original-language clause above are unchanged for every style (F63).
    static func styleGuidance(_ style: SummaryStyle) -> String {
        switch style {
        case .balanced:
            return "Aim for a balanced level of detail."
        case .brief:
            return "Be brief: a short summary, only the most essential key points, and only clearly-stated action items."
        case .detailed:
            return "Be thorough and detailed: a fuller summary and comprehensive key points, without padding."
        case .actionItemsFocused:
            return "Focus on action items: capture every concrete follow-up task, owner, and deadline mentioned; keep the summary and key points concise."
        }
    }

    static var schema: [String: Any] {
        [
            "type": "object",
            "properties": [
                "summary": ["type": "string"],
                "keyPoints": ["type": "array", "items": ["type": "string"]],
                "actionItems": ["type": "array", "items": ["type": "string"]]
            ],
            "required": ["summary", "keyPoints", "actionItems"],
            "additionalProperties": false
        ]
    }

    static func errorMessage(from data: Data) -> String {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let error = object["error"] as? [String: Any],
              let message = error["message"] as? String else {
            let raw = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return raw.isEmpty ? "No details provided." : String(raw.prefix(500))
        }
        return message
    }

    static func decodeSummary(from data: Data) throws -> MeetingSummary {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw SummarizerError.unreadableResponse
        }
        if let stopReason = object["stop_reason"] as? String {
            if stopReason == "refusal" {
                let details = (object["stop_details"] as? [String: Any])?["explanation"] as? String
                throw SummarizerError.refused(details ?? "No explanation provided.")
            }
            // A token-cap hit returns HTTP 200 with truncated JSON; decoding it would misreport a
            // truncation as an unreadable/garbled response. Surface an actionable error instead (F45).
            if stopReason == "max_tokens" {
                throw SummarizerError.responseTruncated
            }
        }
        guard let content = object["content"] as? [[String: Any]] else {
            throw SummarizerError.unreadableResponse
        }
        let text = content
            .first { ($0["type"] as? String) == "text" }?["text"] as? String
        guard let text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw SummarizerError.emptyResponse
        }
        guard let jsonData = text.data(using: .utf8),
              let summary = try? JSONDecoder().decode(MeetingSummary.self, from: jsonData) else {
            throw SummarizerError.unreadableResponse
        }
        return summary
    }
}
