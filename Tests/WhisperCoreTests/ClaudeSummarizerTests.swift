import Foundation
import Testing
@testable import WhisperCore

/// Captures the outgoing request and returns a canned response so ClaudeSummarizer
/// can be exercised without touching the network.
final class StubURLProtocol: URLProtocol {
    nonisolated(unsafe) static var requestBody: Data?
    nonisolated(unsafe) static var statusCode = 200
    nonisolated(unsafe) static var responseBody = Data()

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
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

@Test("A structured response decodes into a MeetingSummary")
func decodesStructuredResponse() async throws {
    StubURLProtocol.statusCode = 200
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
    StubURLProtocol.responseBody = try! JSONSerialization.data(withJSONObject: [
        "stop_reason": "refusal",
        "stop_details": ["explanation": "nope"],
        "content": []
    ])

    await #expect(throws: SummarizerError.refused("nope")) {
        try await makeSummarizer().summarize(transcript: "hello", language: nil)
    }
}

@Test("An empty transcript is rejected before any request")
func rejectsEmptyTranscript() async throws {
    await #expect(throws: SummarizerError.emptyTranscript) {
        try await makeSummarizer().summarize(transcript: "   ", language: nil)
    }
}

}
