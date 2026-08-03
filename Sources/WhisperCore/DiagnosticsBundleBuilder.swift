import Foundation

/// Per-meeting data handed to the diagnostics builder. It deliberately CARRIES the sensitive fields
/// (transcript, summary) so the builder can prove — by never emitting them — that a support bundle
/// excludes them (F70).
public struct DiagnosticsInput: Sendable {
    public struct Meeting: Sendable {
        public let id: String
        public let createdAtEpoch: Int
        public let durationSeconds: Int
        public let status: String
        public let languageCode: String?
        public let segmentCount: Int
        public let markerCount: Int
        public let recordingBytes: Int64?
        public let errorMessage: String?
        // Sensitive — accepted but never emitted:
        public let transcriptText: String
        public let summary: String?

        public init(
            id: String, createdAtEpoch: Int, durationSeconds: Int, status: String,
            languageCode: String?, segmentCount: Int, markerCount: Int, recordingBytes: Int64?,
            errorMessage: String?, transcriptText: String, summary: String?
        ) {
            self.id = id
            self.createdAtEpoch = createdAtEpoch
            self.durationSeconds = durationSeconds
            self.status = status
            self.languageCode = languageCode
            self.segmentCount = segmentCount
            self.markerCount = markerCount
            self.recordingBytes = recordingBytes
            self.errorMessage = errorMessage
            self.transcriptText = transcriptText
            self.summary = summary
        }
    }

    public let meetings: [Meeting]
    public let vocabulary: [String] // count only is emitted, never the terms

    public init(meetings: [Meeting], vocabulary: [String]) {
        self.meetings = meetings
        self.vocabulary = vocabulary
    }
}

/// Builds a deterministic, privacy-safe diagnostics bundle. By construction it emits only structural
/// metadata — ids, timestamps, durations, status, language code, counts, byte sizes, and error
/// messages — never transcript text, summaries, vocabulary terms, or absolute paths (F70).
public enum DiagnosticsBundleBuilder {
    /// Replaces absolute POSIX paths (two or more `/name` components) with `<path>` so a raw error
    /// message — a Qwen traceback, afconvert stderr, recovery text — can't leak home/absolute paths into
    /// the "path-free" bundle. Non-path text (e.g. "3/4", "read/write") is untouched (F141).
    public static func redactPaths(_ text: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: #"/[A-Za-z0-9._-]+(?:/[A-Za-z0-9._%+~-]+)+"#) else {
            return text
        }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return regex.stringByReplacingMatches(in: text, range: range, withTemplate: "<path>")
    }

    public static func json(_ input: DiagnosticsInput) -> String {
        let meetings: [[String: Any]] = input.meetings.map { meeting in
            // Bind the nil-coalesced values to explicitly-typed locals so `??` resolves to the
            // non-optional `(T?, T) -> T` overload. Inside the `[String: Any]` literal the contextual
            // type is `Any`, and Swift otherwise picks `(T?, T?) -> T?`, leaving the result optional
            // and emitting a `String?`/`Int64?` → `Any` coercion warning the release gate promotes to
            // an error (F111). Output bytes are unchanged.
            let languageCode: String = meeting.languageCode ?? ""
            let recordingBytes: Int64 = meeting.recordingBytes ?? -1
            let errorMessage: String = redactPaths(meeting.errorMessage ?? "")
            return [
                "id": meeting.id,
                "createdAt": meeting.createdAtEpoch,
                "durationSeconds": meeting.durationSeconds,
                "status": meeting.status,
                "languageCode": languageCode,
                "segmentCount": meeting.segmentCount,
                "markerCount": meeting.markerCount,
                "recordingBytes": recordingBytes,
                "hasError": meeting.errorMessage != nil,
                "errorMessage": errorMessage,
            ]
        }
        let payload: [String: Any] = [
            "meetingCount": input.meetings.count,
            "vocabularyTermCount": input.vocabulary.count,
            "meetings": meetings,
        ]
        guard let data = try? JSONSerialization.data(
            withJSONObject: payload,
            options: [.sortedKeys, .prettyPrinted, .withoutEscapingSlashes]
        ), let string = String(data: data, encoding: .utf8) else {
            return "{}"
        }
        return string
    }
}
