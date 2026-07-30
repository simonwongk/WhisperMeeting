import Foundation

public struct DictationRequest: Codable, Equatable, Sendable {
    public var wavPath: String
    public var language: String?
    public var initialPrompt: String?
    public init(wavPath: String, language: String?, initialPrompt: String?) {
        self.wavPath = wavPath
        self.language = language
        self.initialPrompt = initialPrompt
    }
}

public struct DictationResponse: Codable, Equatable, Sendable {
    public var text: String?
    public var language: String?
    public var error: String?
    /// Lowest per-segment `no_speech_prob` the helper saw (most speech-like segment). Used to tell a
    /// real dictation from a silence-driven prompt echo. Absent from older helpers → decodes to nil.
    public var noSpeechProb: Double?
    public init(text: String?, language: String?, error: String?, noSpeechProb: Double? = nil) {
        self.text = text
        self.language = language
        self.error = error
        self.noSpeechProb = noSpeechProb
    }
}

/// Newline-delimited JSON framing shared with `whisper_dictate_server.py`. `JSONEncoder` never emits
/// literal newlines, so one physical line is exactly one JSON message.
public enum DictationWireProtocol {
    public static func encodeLine<T: Encodable>(_ value: T) throws -> Data {
        var data = try JSONEncoder().encode(value)
        data.append(0x0A)
        return data
    }

    public static func decodeResponse(line: Data) throws -> DictationResponse {
        try JSONDecoder().decode(DictationResponse.self, from: line)
    }

    /// Removes and returns the first complete `\n`-terminated line from `buffer`, or nil if none yet.
    public static func takeLine(_ buffer: inout Data) -> Data? {
        guard let newline = buffer.firstIndex(of: 0x0A) else { return nil }
        let line = buffer.subdata(in: buffer.startIndex..<newline)
        buffer.removeSubrange(buffer.startIndex...newline)
        return line
    }
}

public struct DictationResult: Sendable, Equatable {
    public let text: String
    public let languageCode: String?
    /// Lowest per-segment `no_speech_prob` for the clip (nil if the engine can't report it). A high
    /// value means the clip was likely silence/noise — used to gate prompt-echo suppression so a
    /// confident real dictation is never silently discarded.
    public let noSpeechProb: Double?
    public init(text: String, languageCode: String?, noSpeechProb: Double? = nil) {
        self.text = text
        self.languageCode = languageCode
        self.noSpeechProb = noSpeechProb
    }
}

/// A source of transcripts for quick dictation. Implementations may hold a warm model.
public protocol DictationEngine: Sendable {
    func warmUp() async throws
    func transcribe(wavAt url: URL, language: WhisperLanguage, initialPrompt: String?) async throws -> DictationResult
    func shutdown()
    /// Permanently stops this instance and waits until queued process work has drained. Model
    /// selection uses this stronger lifecycle boundary so two resident models cannot overlap.
    func retire() async
}

public extension DictationEngine {
    func retire() async {
        shutdown()
    }
}

/// Stable engine boundary for Quick Dictation. The recorder always produces the same WAV; replacing
/// this delegate changes only transcription and immediately releases the previous resident model.
public final class SelectableDictationEngine: DictationEngine, @unchecked Sendable {
    private let lock = NSLock()
    private var engine: DictationEngine

    public init(engine: DictationEngine) {
        self.engine = engine
    }

    public func replace(with replacement: DictationEngine) async {
        let previous = current
        await previous.retire()
        install(replacement)
    }

    private func install(_ replacement: DictationEngine) {
        lock.lock()
        engine = replacement
        lock.unlock()
    }

    public func warmUp() async throws {
        try await current.warmUp()
    }

    public func transcribe(
        wavAt url: URL,
        language: WhisperLanguage,
        initialPrompt: String?
    ) async throws -> DictationResult {
        try await current.transcribe(
            wavAt: url,
            language: language,
            initialPrompt: initialPrompt
        )
    }

    public func shutdown() {
        current.shutdown()
    }

    private var current: DictationEngine {
        lock.lock()
        defer { lock.unlock() }
        return engine
    }
}

public struct DictationHotkey: Codable, Equatable, Sendable {
    public enum Mode: String, Codable, Sendable { case hold, toggle }
    public var keyCode: UInt16
    public var mode: Mode
    public init(keyCode: UInt16, mode: Mode) {
        self.keyCode = keyCode
        self.mode = mode
    }
    /// Right Option (kVK_RightOption = 0x3D = 61), hold-to-talk. The out-of-box default.
    public static let rightOption = DictationHotkey(keyCode: 61, mode: .hold)
}
