import Foundation
import Testing
@testable import WhisperCore

/// Captures the outgoing request and returns a canned response so ClaudeSummarizer
/// can be exercised without touching the network.
final class StubURLProtocol: URLProtocol {
    nonisolated(unsafe) static var requestBody: Data?
    nonisolated(unsafe) static var requestTimeoutInterval: TimeInterval?
    nonisolated(unsafe) static var statusCode = 200
    nonisolated(unsafe) static var responseBody = Data()
    /// When set, `startLoading` fails the request with this URLError code instead of returning
    /// `responseBody` — for F474, simulating a timed-out request that URLSession genuinely sent.
    nonisolated(unsafe) static var failWithErrorCode: URLError.Code?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.requestTimeoutInterval = request.timeoutInterval
        if let code = Self.failWithErrorCode {
            client?.urlProtocol(self, didFailWithError: URLError(code))
            return
        }
        // URLProtocol strips httpBody into httpBodyStream, so read the stream.
        if let stream = request.httpBodyStream {
            stream.open()
            var data = Data()
            let size = 4096
            let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: size)
            defer { buffer.deallocate(); stream.close() }
            while stream.hasBytesAvailable {
                let read = stream.read(buffer, maxLength: size)
                if read <= 0 { break }
                data.append(buffer, count: read)
            }
            Self.requestBody = data
        } else {
            Self.requestBody = request.httpBody
        }

        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: Self.statusCode,
            httpVersion: nil,
            headerFields: ["Content-Type": "application/json"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Self.responseBody)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

private func makeSummarizer() -> ClaudeSummarizer {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [StubURLProtocol.self]
    return ClaudeSummarizer(apiKey: "test-key", session: URLSession(configuration: configuration))
}

private func successResponse(_ summaryJSON: String) -> Data {
    let payload: [String: Any] = [
        "stop_reason": "end_turn",
        "content": [["type": "text", "text": summaryJSON]]
    ]
    return try! JSONSerialization.data(withJSONObject: payload)
}

// Serialized: the stub shares process-wide static state, so these must not
// run concurrently with one another.
@Suite(.serialized)
struct ClaudeSummarizerTests {

@Test("The request targets the messages endpoint with the transcript and a JSON schema")
func requestIsWellFormed() async throws {
    StubURLProtocol.statusCode = 200
    StubURLProtocol.failWithErrorCode = nil
    StubURLProtocol.responseBody = successResponse(
        #"{"summary":"s","keyPoints":[],"actionItems":[]}"#
    )
    StubURLProtocol.requestBody = nil

    _ = try await makeSummarizer().summarize(transcript: "我们讨论了太极", language: "zh")

    let body = try #require(StubURLProtocol.requestBody)
    let object = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
    #expect(object["model"] as? String == ClaudeSummarizer.defaultModel)
    let messages = try #require(object["messages"] as? [[String: Any]])
    #expect(messages.first?["content"] as? String == "我们讨论了太极")
    let format = (object["output_config"] as? [String: Any])?["format"] as? [String: Any]
    #expect(format?["type"] as? String == "json_schema")
    let system = try #require(object["system"] as? String)
    #expect(system.contains("same language"))
}

// F474 — a non-streaming request with max_tokens 8,000 has nothing to send back until generation
// finishes, and URLSession's (and URLRequest's) default timeoutInterval is 60 s — far shorter than
// a long summary can take. The request must ask for enough time, matching the official Anthropic
// SDKs' own 10-minute non-streaming default (client config: "timeout default 10 min").
@Test("The request sets a generation-sized timeout, not URLSession's 60 s default (F474)")
func requestTimeoutIsSizedForGeneration() async throws {
    StubURLProtocol.statusCode = 200
    StubURLProtocol.failWithErrorCode = nil
    StubURLProtocol.responseBody = successResponse(
        #"{"summary":"s","keyPoints":[],"actionItems":[]}"#
    )
    StubURLProtocol.requestTimeoutInterval = nil

    _ = try await makeSummarizer().summarize(transcript: "hello", language: nil)

    let timeout = try #require(StubURLProtocol.requestTimeoutInterval)
    #expect(timeout == ClaudeSummarizer.requestTimeoutInterval)
    #expect(timeout >= 600, "URLSession's 60 s default is nowhere near enough for a non-streaming summary")
}

// F474 — a timed-out request is not the same event as a request that never left this Mac.
// URLSession genuinely sent the bytes; it just gave up waiting for a reply. `.requestFailed`'s
// copy ("could not be sent") is a claim about a state the app does not know to be true, so a
// timeout gets its own case with copy that does not make that claim.
@Test("A timed-out request is reported honestly, not as one that could not be sent (F474)")
func timeoutIsNotReportedAsUnsent() async throws {
    StubURLProtocol.failWithErrorCode = .timedOut

    await #expect(throws: SummarizerError.requestTimedOut) {
        try await makeSummarizer().summarize(transcript: "hello", language: nil)
    }
    let message = SummarizerError.requestTimedOut.localizedDescription
    #expect(!message.contains("could not be sent"))
}

@Test("A structured response decodes into a MeetingSummary")
func decodesStructuredResponse() async throws {
    StubURLProtocol.statusCode = 200
    StubURLProtocol.failWithErrorCode = nil
    StubURLProtocol.responseBody = successResponse(
        #"{"summary":"Discussed the roadmap.","keyPoints":["Ship v1","Hire QA"],"actionItems":["Email the vendor"]}"#
    )

    let result = try await makeSummarizer().summarize(transcript: "hello", language: "en")
    #expect(result.summary == "Discussed the roadmap.")
    #expect(result.keyPoints == ["Ship v1", "Hire QA"])
    #expect(result.actionItems == ["Email the vendor"])
}

@Test("A 401 surfaces as an httpStatus error")
func mapsAuthFailure() async throws {
    StubURLProtocol.statusCode = 401
    StubURLProtocol.failWithErrorCode = nil
    StubURLProtocol.responseBody = try! JSONSerialization.data(
        withJSONObject: ["error": ["message": "invalid x-api-key"]]
    )

    await #expect(throws: SummarizerError.httpStatus(401, "invalid x-api-key")) {
        try await makeSummarizer().summarize(transcript: "hello", language: nil)
    }
}

@Test("A refusal stop reason surfaces as a refused error")
func mapsRefusal() async throws {
    StubURLProtocol.statusCode = 200
    StubURLProtocol.failWithErrorCode = nil
    StubURLProtocol.responseBody = try! JSONSerialization.data(withJSONObject: [
        "stop_reason": "refusal",
        "stop_details": ["explanation": "nope"],
        "content": []
    ])

    await #expect(throws: SummarizerError.refused("nope")) {
        try await makeSummarizer().summarize(transcript: "hello", language: nil)
    }
}

@Test("A max_tokens stop reason surfaces as a distinct truncation error, not unreadable")
func mapsTruncation() async throws {
    StubURLProtocol.statusCode = 200
    StubURLProtocol.failWithErrorCode = nil
    // HTTP 200 with a truncated JSON payload — decoding this would throw .unreadableResponse.
    StubURLProtocol.responseBody = try! JSONSerialization.data(withJSONObject: [
        "stop_reason": "max_tokens",
        "content": [["type": "text", "text": #"{"summary":"partial answer that ran out of to"#]]
    ])

    await #expect(throws: SummarizerError.responseTruncated) {
        try await makeSummarizer().summarize(transcript: "hello", language: nil)
    }
}

@Test("An empty transcript is rejected before any request")
func rejectsEmptyTranscript() async throws {
    await #expect(throws: SummarizerError.emptyTranscript) {
        try await makeSummarizer().summarize(transcript: "   ", language: nil)
    }
}

@Test("Summary style changes the system prompt but not the schema or the do-not-translate clause")
func summaryStyleControls() async throws {
    // Prompt-level: each style adds its guidance; the original-language clause survives every style.
    #expect(ClaudeSummarizer.systemPrompt(language: nil, style: .brief).lowercased().contains("brief"))
    #expect(ClaudeSummarizer.systemPrompt(language: nil, style: .actionItemsFocused).lowercased().contains("action item"))
    for style in SummaryStyle.allCases {
        #expect(ClaudeSummarizer.systemPrompt(language: "en", style: style).contains("Do not translate"))
    }

    // Request-level: the response schema is byte-identical across styles; only the system prompt changes.
    func capture(_ style: SummaryStyle) async throws -> (schema: Data, system: String) {
        StubURLProtocol.statusCode = 200
        StubURLProtocol.failWithErrorCode = nil
        StubURLProtocol.responseBody = successResponse(#"{"summary":"s","keyPoints":[],"actionItems":[]}"#)
        StubURLProtocol.requestBody = nil
        _ = try await makeSummarizer().summarize(transcript: "hi", language: nil, style: style)
        let body = try #require(StubURLProtocol.requestBody)
        let object = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        let schema = ((object["output_config"] as? [String: Any])?["format"] as? [String: Any])?["schema"] as Any
        let schemaData = try JSONSerialization.data(withJSONObject: schema, options: [.sortedKeys])
        let system = try #require(object["system"] as? String)
        return (schemaData, system)
    }
    let brief = try await capture(.brief)
    let detailed = try await capture(.detailed)
    #expect(brief.schema == detailed.schema) // schema unchanged across styles
    #expect(brief.system != detailed.system) // system prompt did change
}

}
