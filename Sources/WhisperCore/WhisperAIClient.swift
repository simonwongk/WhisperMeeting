import Foundation

public enum WhisperAIError: LocalizedError, Sendable, Equatable {
    case invalidAPIKey
    case invalidResponse
    case http(statusCode: Int, message: String)
    case transcriptionFailed(String)
    case missingTranscriptText

    public var errorDescription: String? {
        switch self {
        case .invalidAPIKey:
            return "Enter a WhisperAI API key beginning with wai_."
        case .invalidResponse:
            return "WhisperAI returned an unreadable response."
        case let .http(statusCode, message):
            return "WhisperAI request failed (\(statusCode)): \(message)"
        case let .transcriptionFailed(message):
            return "Transcription failed: \(message)"
        case .missingTranscriptText:
            return "WhisperAI completed the job without transcript text."
        }
    }
}

public struct WhisperAIClient: Sendable {
    public typealias Sleep = @Sendable (Duration) async throws -> Void
    public typealias ProgressHandler = @Sendable (TranscriptionProgress) async -> Void

    private let transport: any HTTPTransport
    private let sleep: Sleep
    private let baseURL: URL
    private let pollInterval: Duration

    public init(
        transport: any HTTPTransport = URLSessionTransport(),
        baseURL: URL = URL(string: "https://api.whisperai.com/v1")!,
        pollInterval: Duration = .seconds(3),
        sleep: @escaping Sleep = { duration in
            try await Task.sleep(for: duration)
        }
    ) {
        self.transport = transport
        self.baseURL = baseURL
        self.pollInterval = pollInterval
        self.sleep = sleep
    }

    public func transcribe(
        recordingAt fileURL: URL,
        apiKey: String,
        options: TranscriptionOptions = .accuracyFirst(),
        onProgress: @escaping ProgressHandler = { _ in }
    ) async throws -> TranscriptionResult {
        guard apiKey.hasPrefix("wai_"), apiKey.count > 4 else {
            throw WhisperAIError.invalidAPIKey
        }

        try Task.checkCancellation()
        await onProgress(.uploading)
        let uploadURL = try await upload(recordingAt: fileURL, apiKey: apiKey)

        let initial = try await submit(
            audioURL: uploadURL,
            apiKey: apiKey,
            options: options
        )
        await onProgress(progress(for: initial.status))

        var transcript = initial
        while transcript.status == .queued || transcript.status == .processing {
            try Task.checkCancellation()
            try await sleep(pollInterval)
            transcript = try await fetchTranscript(id: transcript.id, apiKey: apiKey)
            await onProgress(progress(for: transcript.status))
        }

        if transcript.status == .error {
            throw WhisperAIError.transcriptionFailed(
                transcript.error ?? "Unknown transcription error"
            )
        }
        guard transcript.status == .completed else {
            throw WhisperAIError.invalidResponse
        }
        guard let text = transcript.text, !text.isEmpty else {
            throw WhisperAIError.missingTranscriptText
        }

        await onProgress(.fetchingTranscript)
        let paragraphSegments: [TranscriptSegment]
        let paragraphConfidence: Double?
        do {
            let paragraphs = try await fetchParagraphs(id: transcript.id, apiKey: apiKey)
            paragraphSegments = paragraphs.paragraphs.filter { !$0.text.isEmpty }
            paragraphConfidence = paragraphs.confidence
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            paragraphSegments = []
            paragraphConfidence = nil
        }
        let utterances = transcript.utterances?.filter { !$0.text.isEmpty } ?? []
        return TranscriptionResult(
            id: transcript.id,
            text: text,
            languageCode: transcript.languageCode,
            audioDuration: transcript.audioDuration,
            confidence: transcript.confidence ?? paragraphConfidence,
            segments: utterances.isEmpty ? paragraphSegments : utterances
        )
    }

    private func upload(recordingAt fileURL: URL, apiKey: String) async throws -> String {
        var request = authenticatedRequest(
            url: baseURL.appendingPathComponent("upload"),
            method: "POST",
            apiKey: apiKey
        )
        request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")

        let (data, response) = try await uploadWithRetry(request: request, fileURL: fileURL)
        try validate(response: response, data: data)
        return try decoder.decode(UploadResponse.self, from: data).uploadUrl
    }

    private func submit(
        audioURL: String,
        apiKey: String,
        options: TranscriptionOptions
    ) async throws -> TranscriptResponse {
        var request = authenticatedRequest(
            url: baseURL.appendingPathComponent("transcript"),
            method: "POST",
            apiKey: apiKey
        )
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try encoder.encode(SubmissionRequest(
            audioURL: audioURL,
            languageDetection: true,
            speakerLabels: true,
            punctuate: true,
            formatText: true,
            disfluencies: false,
            keytermsPrompt: options.keyterms.isEmpty ? nil : options.keyterms,
            speakersExpected: options.expectedSpeakers
        ))

        let (data, response) = try await transport.data(for: request)
        try validate(response: response, data: data)
        return try decoder.decode(TranscriptResponse.self, from: data)
    }

    private func fetchTranscript(id: String, apiKey: String) async throws -> TranscriptResponse {
        let request = authenticatedRequest(
            url: baseURL.appendingPathComponent("transcript").appendingPathComponent(id),
            method: "GET",
            apiKey: apiKey
        )
        let (data, response) = try await dataWithRetry(for: request)
        try validate(response: response, data: data)
        return try decoder.decode(TranscriptResponse.self, from: data)
    }

    private func fetchParagraphs(id: String, apiKey: String) async throws -> ParagraphsResponse {
        let request = authenticatedRequest(
            url: baseURL
                .appendingPathComponent("transcript")
                .appendingPathComponent(id)
                .appendingPathComponent("paragraphs"),
            method: "GET",
            apiKey: apiKey
        )
        let (data, response) = try await dataWithRetry(for: request)
        try validate(response: response, data: data)
        return try decoder.decode(ParagraphsResponse.self, from: data)
    }

    private func authenticatedRequest(url: URL, method: String, apiKey: String) -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue(apiKey, forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 60
        return request
    }

    private func validate(response: HTTPURLResponse, data: Data) throws {
        guard (200..<300).contains(response.statusCode) else {
            let message = (try? decoder.decode(ErrorResponse.self, from: data).error)
                ?? String(data: data, encoding: .utf8)
                ?? HTTPURLResponse.localizedString(forStatusCode: response.statusCode)
            throw WhisperAIError.http(statusCode: response.statusCode, message: message)
        }
    }

    private func uploadWithRetry(
        request: URLRequest,
        fileURL: URL
    ) async throws -> (Data, HTTPURLResponse) {
        var retryNumber = 0
        while true {
            let result = try await transport.upload(for: request, fromFile: fileURL)
            guard shouldRetry(result.1.statusCode), retryNumber < 3 else {
                return result
            }
            try await sleep(retryDelay(response: result.1, retryNumber: retryNumber))
            retryNumber += 1
            try Task.checkCancellation()
        }
    }

    private func dataWithRetry(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        var retryNumber = 0
        while true {
            let result = try await transport.data(for: request)
            guard shouldRetry(result.1.statusCode), retryNumber < 3 else {
                return result
            }
            try await sleep(retryDelay(response: result.1, retryNumber: retryNumber))
            retryNumber += 1
            try Task.checkCancellation()
        }
    }

    private func shouldRetry(_ statusCode: Int) -> Bool {
        statusCode == 429 || (500...599).contains(statusCode)
    }

    private func retryDelay(response: HTTPURLResponse, retryNumber: Int) -> Duration {
        if let value = response.value(forHTTPHeaderField: "Retry-After"),
           let seconds = Double(value),
           seconds >= 0 {
            return .milliseconds(Int64(seconds * 1_000))
        }
        return .seconds(1 << retryNumber)
    }

    private func progress(for status: TranscriptStatus) -> TranscriptionProgress {
        switch status {
        case .queued:
            return .queued
        case .processing, .completed, .error:
            return .processing
        }
    }

    private var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        return encoder
    }

    private var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return decoder
    }
}

private struct UploadResponse: Decodable {
    let uploadUrl: String
}

private struct SubmissionRequest: Encodable {
    let audioURL: String
    let languageDetection: Bool
    let speakerLabels: Bool
    let punctuate: Bool
    let formatText: Bool
    let disfluencies: Bool
    let keytermsPrompt: [String]?
    let speakersExpected: Int?
}

private enum TranscriptStatus: String, Decodable {
    case queued
    case processing
    case completed
    case error
}

private struct TranscriptResponse: Decodable {
    let id: String
    let status: TranscriptStatus
    let text: String?
    let languageCode: String?
    let audioDuration: Double?
    let confidence: Double?
    let error: String?
    let utterances: [TranscriptSegment]?
}

private struct ParagraphsResponse: Decodable {
    let id: String
    let confidence: Double?
    let audioDuration: Double?
    let paragraphs: [TranscriptSegment]

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        confidence = try container.decodeIfPresent(Double.self, forKey: .confidence)
        audioDuration = try container.decodeIfPresent(Double.self, forKey: .audioDuration)
        paragraphs = try container.decodeIfPresent([TranscriptSegment].self, forKey: .paragraphs) ?? []
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case confidence
        case audioDuration
        case paragraphs
    }
}

private struct ErrorResponse: Decodable {
    let error: String
}
