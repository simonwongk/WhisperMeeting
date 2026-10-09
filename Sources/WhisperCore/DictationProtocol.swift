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
    /// True on a warm-up `error` whose cause is the model's first-run download (F827), so the app can
    /// tell "the model is still downloading" from "this helper cannot run here". Absent from every
    /// older helper and every other reply → nil.
    public var downloadFailed: Bool?
    public init(
        text: String?, language: String?, error: String?, noSpeechProb: Double? = nil,
        downloadFailed: Bool? = nil
    ) {
        self.text = text
        self.language = language
        self.error = error
        self.noSpeechProb = noSpeechProb
        self.downloadFailed = downloadFailed
    }
}

/// The warm dictation engine's model could not be downloaded: the helper reported the download
/// failed, or reported progress and then none for the stall window (F827).
///
/// A **reason to try again, not a reason to fall back**. `FallbackDictationEngine` exists for "the
/// warm helper cannot run on this machine"; the batch engine it falls back to downloads a second
/// ~1.5 GB model of its own, on the same link, with no way to resume it. Falling back on this error
/// switched the whole session to the slow engine, and since F522 it did so after minutes, not 30.
/// On the helper's resumable path the partial download is kept, so the next warm-up resumes it.
public struct DictationModelDownloadError: LocalizedError, Equatable, Sendable {
    public let message: String

    public init(_ message: String) {
        self.message = message
    }

    public var errorDescription: String? { message }
}

/// One dictation-refinement request to `refine_server.py` (F200). The system prompt travels with
/// every request so Swift stays the single source of truth for prompt content.
public struct RefineRequest: Codable, Equatable, Sendable {
    public var text: String
    public var systemPrompt: String
    public var maxTokens: Int
    public init(text: String, systemPrompt: String, maxTokens: Int) {
        self.text = text
        self.systemPrompt = systemPrompt
        self.maxTokens = maxTokens
    }
}

/// The refine helper's reply: corrected text, or an error message. Same one-line JSON framing as
/// `DictationResponse`.
public struct RefineResponse: Codable, Equatable, Sendable {
    public var text: String?
    public var error: String?
    public init(text: String?, error: String?) {
        self.text = text
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
    /// An ISO 639-1 code whenever the engine named a language the app pins ("en", "zh"), because
    /// `init` normalises through `WhisperLanguage.code(forReported:)` (F447). Every dictation helper
    /// echoes a pinned language back as the name it was sent, and the refine prompt keys on codes,
    /// so doing it here means no engine can hand refinement a name.
    public let languageCode: String?
    /// Lowest per-segment `no_speech_prob` for the clip (nil if the engine can't report it). A high
    /// value means the clip was likely silence/noise — used to gate prompt-echo suppression so a
    /// confident real dictation is never silently discarded.
    public let noSpeechProb: Double?
    public init(text: String, languageCode: String?, noSpeechProb: Double? = nil) {
        self.text = text
        self.languageCode = WhisperLanguage.code(forReported: languageCode)
        self.noSpeechProb = noSpeechProb
    }
}

/// A source of transcripts for quick dictation. Implementations may hold a warm model.
public protocol DictationEngine: Sendable {
    func warmUp() async throws
    /// Wakes a resident model with one tiny request, so weights the system compressed or paged out
    /// while it sat idle come back in now rather than on the user's clip (F891). A no-op when nothing
    /// is resident: a fresh helper is hot from its own startup pass. Never required to succeed.
    func touch() async throws
    func transcribe(wavAt url: URL, language: WhisperLanguage, initialPrompt: String?) async throws -> DictationResult
    func shutdown()
    /// Temporarily frees a resident model and waits until its child process has exited. Unlike
    /// `retire()`, the same engine may warm again for a later dictation.
    func evict() async
    /// Permanently stops this instance and waits until queued process work has drained. Model
    /// selection uses this stronger lifecycle boundary so two resident models cannot overlap.
    func retire() async
    /// Tells `observer` when the engine's model starts (`true`) and stops (`false`) downloading
    /// (F823), or stops telling anyone when it is nil. Only the warm Whisper helper downloads; every
    /// other engine never calls it. Called from the engine's own queue, never the main thread.
    func observeModelDownload(_ observer: DictationModelDownloadObserver?)
    /// Tells `observer` how far that download has got (F859), between its `true` and its `false`,
    /// whenever the engine learns a new figure; nil stops telling anyone. An engine that cannot
    /// measure its download (a helper too old to send byte counts) never calls it, and the download
    /// is then shown without a figure, as before.
    func observeModelDownloadProgress(_ observer: DictationModelDownloadProgressObserver?)
}

/// Receives a dictation engine's model-download state (F823): `true` when the first-run download
/// starts reporting progress, `false` when it ends — finished, failed, stalled or stopped.
public typealias DictationModelDownloadObserver = @Sendable (Bool) -> Void

/// Receives how far a dictation engine's model download has got (F859).
public typealias DictationModelDownloadProgressObserver = @Sendable (DictationModelDownloadProgress) -> Void

/// How far a dictation model's download has got (F859): a fraction, and the download's size when
/// the engine knows it. The warm helper reports bytes; openai-whisper's own download (the batch
/// engine, F860) is read off its progress bar, which gives a percentage only.
public struct DictationModelDownloadProgress: Equatable, Sendable {
    /// In `0...1`.
    public let fractionCompleted: Double
    /// The whole download's size in bytes, or nil when the engine does not know it.
    public let totalBytes: Int64?

    /// From a byte count, or nil for one that is not a measurement (a total of zero or less, or a
    /// negative count) — a helper's numbers are input, not facts.
    public init?(downloadedBytes: Int64, totalBytes: Int64) {
        guard totalBytes > 0, downloadedBytes >= 0 else { return nil }
        self.fractionCompleted = min(1, Double(downloadedBytes) / Double(totalBytes))
        self.totalBytes = totalBytes
    }

    /// From a fraction, clamped to `0...1` (NaN is 0).
    public init(fractionCompleted: Double, totalBytes: Int64? = nil) {
        self.fractionCompleted = fractionCompleted.isNaN ? 0 : min(1, max(0, fractionCompleted))
        self.totalBytes = totalBytes.flatMap { $0 > 0 ? $0 : nil }
    }

    /// Whole percent, rounded down so 100 means finished: `0...100`.
    public var percent: Int {
        min(100, max(0, Int(saturating: (fractionCompleted * 100).rounded(.down))))
    }
}

public extension DictationEngine {
    /// Nothing resident to wake: the batch engine, and every fake.
    func touch() async throws {}

    func evict() async {
        shutdown()
    }

    func retire() async {
        shutdown()
    }

    /// An engine with no model download of its own has nothing to report.
    func observeModelDownload(_ observer: DictationModelDownloadObserver?) {}

    /// Nor any progress to report (F859).
    func observeModelDownloadProgress(_ observer: DictationModelDownloadProgressObserver?) {}
}

/// Stable engine boundary for Quick Dictation. The recorder always produces the same WAV; replacing
/// this delegate changes only transcription and immediately releases the previous resident model.
public final class SelectableDictationEngine: DictationEngine, @unchecked Sendable {
    private let lock = NSLock()
    private var engine: DictationEngine
    private var pendingReplace: Task<Void, Never>?
    /// Handed to every engine installed later too (F823), so a model switch keeps reporting.
    private var downloadObserver: DictationModelDownloadObserver?
    /// The same for the download's progress (F859).
    private var downloadProgressObserver: DictationModelDownloadProgressObserver?

    public init(engine: DictationEngine) {
        self.engine = engine
    }

    public func replace(with replacement: DictationEngine) async {
        // Serialize replacements: each waits for the previous one to finish before reading the
        // current engine, so two concurrent `replace` calls cannot both retire the same engine or
        // install one that is then overwritten without retiring it (F35).
        await enqueueReplace(replacement).value
    }

    private func enqueueReplace(_ replacement: DictationEngine) -> Task<Void, Never> {
        lock.lock()
        defer { lock.unlock() }
        let prior = pendingReplace
        let task = Task { [self] in
            await prior?.value
            let previous = current
            await previous.retire()
            install(replacement)
        }
        pendingReplace = task
        return task
    }

    private func install(_ replacement: DictationEngine) {
        lock.lock()
        defer { lock.unlock() }
        engine = replacement
        // Under the lock, so an `observeModelDownload` racing this cannot be overwritten by the
        // observer read here. An engine's own `observeModelDownload` only stores the closure.
        replacement.observeModelDownload(downloadObserver)
        replacement.observeModelDownloadProgress(downloadProgressObserver)
    }

    public func observeModelDownload(_ observer: DictationModelDownloadObserver?) {
        lock.lock()
        defer { lock.unlock() }
        downloadObserver = observer
        engine.observeModelDownload(observer)
    }

    public func observeModelDownloadProgress(_ observer: DictationModelDownloadProgressObserver?) {
        lock.lock()
        defer { lock.unlock() }
        downloadProgressObserver = observer
        engine.observeModelDownloadProgress(observer)
    }

    public func warmUp() async throws {
        try await current.warmUp()
    }

    public func touch() async throws {
        try await current.touch()
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

    public func evict() async {
        await current.evict()
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
    /// A mode this build cannot read, such as a newer build's, decodes as hold on the same key
    /// (F548). It used to fail the whole decode, and `DictationController` then armed Right Option,
    /// a key the user never chose. Hold, because in hold mode the microphone is on only while the
    /// key is down. Encoding is still synthesized, so the bytes written for a known mode are
    /// unchanged.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        keyCode = try container.decode(UInt16.self, forKey: .keyCode)
        mode = (try? container.decode(String.self, forKey: .mode)).flatMap(Mode.init(rawValue:)) ?? .hold
    }
    /// Right Option (kVK_RightOption = 0x3D = 61), hold-to-talk. The out-of-box default.
    public static let rightOption = DictationHotkey(keyCode: 61, mode: .hold)
}
