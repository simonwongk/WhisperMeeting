import Foundation
import Testing
@testable import WhisperCore

@Test("A recording is uploaded, submitted with accuracy options, and polled to completion")
func transcribesRecordingEndToEnd() async throws {
    let audioURL = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString)
        .appendingPathExtension("wav")
    try Data("recording".utf8).write(to: audioURL)
    defer { try? FileManager.default.removeItem(at: audioURL) }

    let transport = ScriptedTransport([
        .json(200, #"{"upload_url":"https://api.whisperai.com/v1/uploads/up_123"}"#),
        .json(200, #"{"id":"tr_123","status":"queued"}"#),
        .json(200, #"{"id":"tr_123","status":"processing"}"#),
        .json(200, #"{"id":"tr_123","status":"completed","text":"你好，welcome.","language_code":"zh"}"#),
        .json(200, #"{"id":"tr_123","paragraphs":[{"speaker":"A","start":0,"end":1.2,"text":"你好，welcome."}]}"#)
    ])
    let client = WhisperAIClient(
        transport: transport,
        sleep: { _ in }
    )

    let result = try await client.transcribe(
        recordingAt: audioURL,
        apiKey: "wai_test",
        options: .accuracyFirst(
            keyterms: ["WhisperMeet", "客户成功"],
            expectedSpeakers: 2
        )
    )

    #expect(result.id == "tr_123")
    #expect(result.text == "你好，welcome.")
    #expect(result.languageCode == "zh")
    #expect(result.segments == [
        TranscriptSegment(speaker: "A", start: 0, end: 1.2, text: "你好，welcome.")
    ])

    let requests = await transport.requests
    #expect(requests.map(\.url.path) == [
        "/v1/upload",
        "/v1/transcript",
        "/v1/transcript/tr_123",
        "/v1/transcript/tr_123",
        "/v1/transcript/tr_123/paragraphs"
    ])
    #expect(requests.allSatisfy { $0.authorization == "wai_test" })
    #expect(requests[0].bodyKind == .file)

    let submission = try #require(requests[1].jsonBody)
    #expect(submission["audio_url"] as? String == "https://api.whisperai.com/v1/uploads/up_123")
    #expect(submission["language_detection"] as? Bool == true)
    #expect(submission["speaker_labels"] as? Bool == true)
    #expect(submission["punctuate"] as? Bool == true)
    #expect(submission["format_text"] as? Bool == true)
    #expect(submission["disfluencies"] as? Bool == false)
    #expect(submission["keyterms_prompt"] as? [String] == ["WhisperMeet", "客户成功"])
    #expect(submission["speakers_expected"] as? Int == 2)
}

@Test("A rate-limited upload respects Retry-After and succeeds")
func retriesRateLimitedUpload() async throws {
    let audioURL = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString)
        .appendingPathExtension("wav")
    try Data("recording".utf8).write(to: audioURL)
    defer { try? FileManager.default.removeItem(at: audioURL) }

    let transport = ScriptedTransport([
        .json(429, #"{"error":"Slow down"}"#, headers: ["Retry-After": "2"]),
        .json(200, #"{"upload_url":"https://api.whisperai.com/v1/uploads/up_retry"}"#),
        .json(200, #"{"id":"tr_retry","status":"completed","text":"Done."}"#),
        .json(200, #"{"id":"tr_retry","paragraphs":[]}"#)
    ])
    let delays = DelayRecorder()
    let client = WhisperAIClient(
        transport: transport,
        sleep: { duration in await delays.record(duration) }
    )

    let result = try await client.transcribe(
        recordingAt: audioURL,
        apiKey: "wai_test"
    )

    #expect(result.text == "Done.")
    #expect(await delays.values == [.seconds(2)])
    #expect(await transport.requests.count == 4)
}

@Test("Completed transcript text is preserved when paragraphs are unavailable")
func preservesCompletedTextWithoutParagraphs() async throws {
    let audioURL = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString)
        .appendingPathExtension("wav")
    try Data("recording".utf8).write(to: audioURL)
    defer { try? FileManager.default.removeItem(at: audioURL) }

    let transport = ScriptedTransport([
        .json(200, #"{"upload_url":"https://api.whisperai.com/v1/uploads/up_plain"}"#),
        .json(200, #"{"id":"tr_plain","status":"completed","text":"Original transcript."}"#),
        .json(404, #"{"error":"Paragraphs not available"}"#)
    ])
    let client = WhisperAIClient(transport: transport, sleep: { _ in })

    let result = try await client.transcribe(
        recordingAt: audioURL,
        apiKey: "wai_test"
    )

    #expect(result.text == "Original transcript.")
    #expect(result.segments.isEmpty)
}

@Test("Speaker-labelled utterances are preferred over display paragraphs")
func preservesSpeakerUtterances() async throws {
    let audioURL = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString)
        .appendingPathExtension("wav")
    try Data("recording".utf8).write(to: audioURL)
    defer { try? FileManager.default.removeItem(at: audioURL) }

    let transport = ScriptedTransport([
        .json(200, #"{"upload_url":"https://api.whisperai.com/v1/uploads/up_speakers"}"#),
        .json(200, #"{"id":"tr_speakers","status":"completed","text":"Hello. 你好。","utterances":[{"speaker":"A","start":0,"end":1,"text":"Hello."},{"speaker":"B","start":1,"end":2,"text":"你好。"}]}"#),
        .json(200, #"{"id":"tr_speakers","paragraphs":[{"start":0,"end":2,"text":"Hello. 你好。"}]}"#)
    ])
    let client = WhisperAIClient(transport: transport, sleep: { _ in })

    let result = try await client.transcribe(
        recordingAt: audioURL,
        apiKey: "wai_test"
    )

    #expect(result.segments.map(\.speaker) == ["A", "B"])
    #expect(result.segments.map(\.text) == ["Hello.", "你好。"])
}

private actor ScriptedTransport: HTTPTransport {
    struct Request: Sendable {
        enum BodyKind: Sendable { case data, file }

        let url: URL
        let authorization: String?
        let bodyKind: BodyKind
        let jsonData: Data?

        var jsonBody: [String: Any]? {
            guard let jsonData else { return nil }
            return try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any]
        }
    }

    struct Response: Sendable {
        let statusCode: Int
        let body: Data
        let headers: [String: String]

        static func json(
            _ statusCode: Int,
            _ body: String,
            headers: [String: String] = [:]
        ) -> Self {
            Self(statusCode: statusCode, body: Data(body.utf8), headers: headers)
        }
    }

    private var responses: [Response]
    private(set) var requests: [Request] = []

    init(_ responses: [Response]) {
        self.responses = responses
    }

    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        requests.append(Request(
            url: try #require(request.url),
            authorization: request.value(forHTTPHeaderField: "Authorization"),
            bodyKind: .data,
            jsonData: request.httpBody
        ))
        return try nextResponse(for: request)
    }

    func upload(for request: URLRequest, fromFile fileURL: URL) async throws -> (Data, HTTPURLResponse) {
        requests.append(Request(
            url: try #require(request.url),
            authorization: request.value(forHTTPHeaderField: "Authorization"),
            bodyKind: .file,
            jsonData: nil
        ))
        return try nextResponse(for: request)
    }

    private func nextResponse(for request: URLRequest) throws -> (Data, HTTPURLResponse) {
        let scripted = responses.removeFirst()
        guard let url = request.url else {
            throw TestTransportError.missingURL
        }
        let response = try #require(HTTPURLResponse(
            url: url,
            statusCode: scripted.statusCode,
            httpVersion: nil,
            headerFields: ["Content-Type": "application/json"].merging(
                scripted.headers,
                uniquingKeysWith: { _, scripted in scripted }
            )
        ))
        return (scripted.body, response)
    }
}

private enum TestTransportError: Error {
    case missingURL
}

private actor DelayRecorder {
    private(set) var values: [Duration] = []

    func record(_ duration: Duration) {
        values.append(duration)
    }
}
