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
    public init(text: String?, language: String?, error: String?) {
        self.text = text
        self.language = language
        self.error = error
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
    public init(text: String, languageCode: String?) {
        self.text = text
        self.languageCode = languageCode
    }
}

/// A source of transcripts for quick dictation. Implementations may hold a warm model.
public protocol DictationEngine: Sendable {
    func warmUp() async throws
    func transcribe(wavAt url: URL, language: WhisperLanguage, initialPrompt: String?) async throws -> DictationResult
    func shutdown()
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
