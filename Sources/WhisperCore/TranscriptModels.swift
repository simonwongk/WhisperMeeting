import Foundation

public enum WhisperModel: String, Codable, CaseIterable, Sendable, Hashable {
    case large
    case turbo

    public var displayName: String {
        switch self {
        case .large: "Large — best accuracy"
        case .turbo: "Turbo — much faster"
        }
    }
}

public enum MeetingTranscriptionEngine: String, Codable, CaseIterable, Sendable, Hashable {
    case whisperLarge = "large"
    case whisperTurbo = "turbo"
    case qwenBalanced = "qwen3-asr-1.7b-8bit"

    public var displayName: String {
        switch self {
        case .whisperLarge: "Whisper Large — best-established"
        case .whisperTurbo: "Whisper Turbo — fast"
        case .qwenBalanced: "Qwen3-ASR 1.7B — fast + accurate"
        }
    }

    /// The engine's bare name, for use inside a sentence. `displayName` carries a trailing
    /// qualifier ("Whisper Large — best-established") that reads badly mid-message (F262).
    public var shortDisplayName: String {
        switch self {
        case .whisperLarge: "Whisper Large"
        case .whisperTurbo: "Whisper Turbo"
        case .qwenBalanced: "Qwen3-ASR"
        }
    }

    public var whisperModel: WhisperModel? {
        switch self {
        case .whisperLarge: .large
        case .whisperTurbo: .turbo
        case .qwenBalanced: nil
        }
    }

    public var isSupportedOnCurrentMac: Bool {
        switch self {
        case .whisperLarge, .whisperTurbo:
            return true
        case .qwenBalanced:
            #if arch(arm64)
            return true
            #else
            return false
            #endif
        }
    }

    public static var availableCases: [Self] {
        allCases.filter(\.isSupportedOnCurrentMac)
    }
}

/// The two engines suitable for short, latency-sensitive push-to-talk clips. This is intentionally
/// separate from meeting selection: Quick Dictation never offers Whisper Large, and changing one
/// workflow's preference must not silently change the other.
public enum DictationTranscriptionEngine: String, Codable, CaseIterable, Sendable, Hashable {
    case whisperTurbo = "turbo"
    case qwenBalanced = "qwen3-asr-1.7b-8bit"

    public var displayName: String {
        switch self {
        case .whisperTurbo: "Whisper Turbo"
        case .qwenBalanced: "Qwen3-ASR 1.7B"
        }
    }

    /// Whisper exposes `initial_prompt`; the current Qwen MLX API does not. Keeping the capability
    /// explicit prevents the UI from promising vocabulary guidance that the selected engine ignores.
    public var supportsVocabularyPrompt: Bool {
        self == .whisperTurbo
    }

    public var isSupportedOnCurrentMac: Bool {
        switch self {
        case .whisperTurbo:
            return true
        case .qwenBalanced:
            #if arch(arm64)
            return true
            #else
            return false
            #endif
        }
    }

    public static var availableCases: [Self] {
        allCases.filter(\.isSupportedOnCurrentMac)
    }
}

public enum WhisperLanguage: String, Codable, CaseIterable, Sendable, Hashable {
    case automatic
    case english
    case chinese

    public var displayName: String {
        switch self {
        case .automatic: "Detect automatically"
        case .english: "English"
        case .chinese: "Chinese (Mandarin)"
        }
    }

    public var commandLineValue: String? {
        switch self {
        case .automatic: nil
        case .english: "English"
        case .chinese: "Chinese"
        }
    }
}

public struct LocalTranscriptionOptions: Sendable, Equatable {
    public let model: WhisperModel
    public let language: WhisperLanguage
    public let keyterms: [String]

    public static func accuracyFirst(
        model: WhisperModel = .large,
        language: WhisperLanguage = .automatic,
        keyterms: [String] = []
    ) -> Self {
        Self(model: model, language: language, keyterms: keyterms)
    }
}

/// Live progress of a local Whisper run, derived from the CLI's own output. `fractionCompleted`
/// and `estimatedSecondsRemaining` are populated once the CLI starts reporting a progress bar;
/// before that they are `nil` and the UI shows an indeterminate indicator.
public struct LocalTranscriptionProgress: Sendable, Equatable {
    public enum Phase: Sendable, Equatable {
        /// The app has spawned the process but Whisper has not reported anything yet.
        case preparing
        /// Whisper is loading a model that already exists on disk.
        case loadingModel
        /// Whisper is downloading a model for the first time (only on first use of a model).
        case downloadingModel
        /// Whisper is transcribing audio.
        case transcribing
    }

    public var phase: Phase
    public var fractionCompleted: Double?
    public var estimatedSecondsRemaining: TimeInterval?

    public init(
        phase: Phase,
        fractionCompleted: Double? = nil,
        estimatedSecondsRemaining: TimeInterval? = nil
    ) {
        self.phase = phase
        self.fractionCompleted = fractionCompleted.map { min(1, max(0, $0)) }
        self.estimatedSecondsRemaining = estimatedSecondsRemaining.map { max(0, $0) }
    }

    public static let preparing = LocalTranscriptionProgress(phase: .preparing)
    public static let loadingModel = LocalTranscriptionProgress(phase: .loadingModel)
    public static let transcribing = LocalTranscriptionProgress(phase: .transcribing)
}

public struct TranscriptSegment: Codable, Sendable, Equatable, Identifiable {
    public var id: String {
        "\(speaker ?? "")-\(start ?? -1)-\(end ?? -1)-\(text)"
    }

    public var speaker: String?
    public var start: Double?
    public var end: Double?
    public var text: String

    /// Whisper per-segment confidence metrics, retained for quality review.
    /// `nil` on transcripts produced before this feature (and on the dictation path);
    /// consumers treat a segment without metrics as *unscored*, never as flagged.
    public var avgLogprob: Double?
    public var noSpeechProb: Double?
    public var compressionRatio: Double?

    public init(
        speaker: String?,
        start: Double?,
        end: Double?,
        text: String,
        avgLogprob: Double? = nil,
        noSpeechProb: Double? = nil,
        compressionRatio: Double? = nil
    ) {
        self.speaker = speaker
        self.start = start
        self.end = end
        self.text = text
        self.avgLogprob = avgLogprob
        self.noSpeechProb = noSpeechProb
        self.compressionRatio = compressionRatio
    }
}

public enum TranscriptFormatter {
    /// Renders segments as one line per segment, each prefixed with an `MM:SS` timestamp.
    public static func timestamped(_ segments: [TranscriptSegment]) -> String {
        segments
            .map { segment -> String in
                let text = segment.text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard let start = segment.start else { return text }
                return "\(timestamp(start))  \(text)"
            }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
    }

    /// Whether `transcriptText` has diverged from what the Whisper `segments` render to — i.e. the
    /// user edited it. Once true, segment-derived overlays (quality flags, marker context) no longer
    /// describe the shown text and should be dropped. False when there are no segments to compare
    /// against or the text is empty.
    public static func isEdited(transcriptText: String, segments: [TranscriptSegment]) -> Bool {
        guard !segments.isEmpty else { return false }
        let shown = transcriptText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !shown.isEmpty else { return false }
        return shown != timestamped(segments).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Whether the text already begins (on its first non-empty line) with an `MM:SS` prefix.
    public static func isTimestamped(_ text: String) -> Bool {
        guard let firstLine = text
            .split(whereSeparator: \.isNewline)
            .first(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }) else {
            return false
        }
        return String(firstLine).range(
            of: #"^\s*\d{1,3}:\d{2}(:\d{2})?\s"#,
            options: .regularExpression
        ) != nil
    }

    /// Whole seconds, clamped in Double space BEFORE the conversion (F287).
    ///
    /// `Int(Double)` traps rather than saturating, so `max(0, Int(seconds))` — which is what these
    /// two formatters did — never gets to clamp anything: the conversion crashes first. `isFinite`
    /// is not the guard either, because 1e30 is perfectly finite and still far past `Int.max`.
    ///
    /// This is reachable from a *decodable* index, which is what makes it worse than the cases F250
    /// and F187 handle. `MeetingRecord.duration` is a plain `Double`, so a corrupt or hand-edited
    /// `meetings.json` carrying `1e30` decodes cleanly, reports `.complete` health, and then takes
    /// the app down while it draws the sidebar. Lenient decoding cannot help: the value decoded
    /// fine. Same shape as the three F287 siblings in the capture path, where a 30-second cap was
    /// applied after the conversion it was meant to bound.
    ///
    /// A clamped value is deliberately still formatted as a duration rather than as an error. The
    /// index said something impossible and nothing here can know what was meant; showing an
    /// implausibly long time is honest about that, and showing a small one would not be.
    private static func wholeSeconds(_ seconds: Double) -> Int {
        // 1e15 seconds is ~31 million years — beyond any real recording, and far enough inside
        // `Int.max` that the arithmetic below cannot overflow either. Picking the cap in Double
        // space is the whole point: `Double(Int.max)` is not exactly representable, so comparing
        // against it is its own trap waiting to happen.
        guard seconds.isFinite, seconds > 0 else { return 0 }
        return Int(min(seconds.rounded(), 1e15))
    }

    public static func timestamp(_ seconds: Double) -> String {
        let total = wholeSeconds(seconds)
        // `%02ld` for the same reason as `clock` below: the minute field here is unbounded, because
        // this format has no hours component at all.
        return String(format: "%02ld:%02d", total / 60, total % 60)
    }

    /// A duration as `M:SS`, or `H:MM:SS` once it reaches an hour.
    public static func clock(_ seconds: Double) -> String {
        let total = wholeSeconds(seconds)
        let secs = total % 60
        let minutes = (total / 60) % 60
        let hours = total / 3600
        // `%ld`, not `%d`: `String(format:)` reads `%d` as 32-bit off the varargs list, so an hour
        // count past `Int32.max` wraps to a negative number. Found by the clamp test above, which
        // printed "-1395096463:46:40" for a clamped value — the trap was fixed and the formatting
        // was still wrong, one layer down. `%ld` matches `Int`'s width on every platform this ships
        // to. Minutes and seconds stay `%02d` because they are always 0-59.
        return hours > 0
            ? String(format: "%ld:%02d:%02d", hours, minutes, secs)
            : String(format: "%ld:%02d", minutes, secs)
    }

    /// Removes a leading `MM:SS`/`H:MM:SS` timestamp from each line, for a clean plain-text export.
    public static func stripTimestamps(_ text: String) -> String {
        text
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { line -> String in
                String(line).replacingOccurrences(
                    of: #"^\s*\d{1,3}:\d{2}(:\d{2})?\s+"#,
                    with: "",
                    options: .regularExpression
                )
            }
            .joined(separator: "\n")
    }
}

public struct TranscriptionResult: Sendable, Equatable {
    public let id: String
    public let text: String
    public let languageCode: String?
    public let audioDuration: Double?
    public let confidence: Double?
    public let segments: [TranscriptSegment]
    /// A plain-language note when timestamp alignment was unavailable but the complete text was
    /// preserved. Surfaced through the result (not an OSLog side effect) so callers/tests can observe
    /// it and the UI can explain it (F28). `nil` on the Whisper path.
    public let alignmentWarning: String?

    public init(
        id: String,
        text: String,
        languageCode: String?,
        audioDuration: Double?,
        confidence: Double?,
        segments: [TranscriptSegment],
        alignmentWarning: String? = nil
    ) {
        self.id = id
        self.text = text
        self.languageCode = languageCode
        self.audioDuration = audioDuration
        self.confidence = confidence
        self.segments = segments
        self.alignmentWarning = alignmentWarning
    }
}
