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
    /// Crash reports macOS wrote for this app (F370): names and timestamps, plus each report's
    /// `CrashReportDigest` when it has one (F389) — an allowlist read out of the `.ips`, never the
    /// file itself, which is full of absolute paths this bundle promises to carry none of.
    public let crashReports: [CrashReportRecord]

    public init(
        meetings: [Meeting],
        vocabulary: [String],
        crashReports: [CrashReportRecord] = []
    ) {
        self.meetings = meetings
        self.vocabulary = vocabulary
        self.crashReports = crashReports
    }
}

/// Builds a deterministic, privacy-safe diagnostics bundle. By construction it emits only structural
/// metadata — ids, timestamps, durations, status, language code, counts, byte sizes, error
/// messages, and each crash report's allowlisted digest (F389) — never transcript text, summaries,
/// vocabulary terms, or absolute paths (F70).
public enum DiagnosticsBundleBuilder {
    /// Replaces each path in `text` with `<path>`, so a raw error message — a Qwen traceback,
    /// afconvert stderr, recovery text — cannot carry a home folder, a folder name or a file name
    /// (which can be a meeting title) into the "path-free" bundle or a `.public` log line (F141, F791).
    ///
    /// **Where a path starts:** at a `file:` URL, a `~/`, or a `/` that begins two components
    /// ("/Users/…", "Recordings/<id>/…"), widened back to the start of its word. "3/4" and
    /// "read/write" are not paths and are left alone.
    ///
    /// **Where it ends — fail closed (F791).** A name can hold spaces and any script, so where a path
    /// ends in free text is a guess, and a guess that stops too early leaks the rest of the name: the
    /// F141 pattern stopped at the first space or non-ASCII character and left
    /// "<path>/会议记录/季度规划会议.mov" and "<path> Support<path> Meeting Q3.m4a". So a path ends
    /// early in one case only: at a component ending in an extension this app's paths end in
    /// (`recognisedExtensions`) that is followed by the end of the line, by punctuation that cannot be
    /// more of a name (`pathEndPunctuation`), or by whitespace — or a `.`, `!` or `?` ending a
    /// sentence — with no further `/` on the line (a later `/` means the component may be a folder
    /// in the middle of a longer path). Anything else is redacted from the
    /// path to the end of its line, as `<path>…`. The line is the limit, so a traceback keeps its
    /// later lines, and its final error with them.
    ///
    /// What this cannot see: a name that itself has a recognised extension followed by a space or
    /// punctuation in the middle ("notes.txt draft") ends early, and a name with a line break in it
    /// is cut at the break. A bare file name with no `/` is not a path and is kept.
    public static func redactPaths(_ text: String) -> String {
        var output = ""
        var line: [Character] = []
        for character in text {
            if character.isNewline {
                output += redactingPaths(inLine: line)
                output.append(character)
                line.removeAll(keepingCapacity: true)
            } else {
                line.append(character)
            }
        }
        return output + redactingPaths(inLine: line)
    }

    /// The extensions a path may end at without taking the rest of its line (F791): the audio and
    /// video an import or a recording can be, and what the library and its runtimes keep beside them.
    /// One missing from here only redacts more.
    static let recognisedExtensions: Set<String> = [
        "wav", "wave", "m4a", "mp3", "mp4", "m4v", "mov", "webm", "mkv", "avi", "aac", "flac", "ogg",
        "oga", "opus", "caf", "aif", "aiff", "amr", "3gp",
        "f32", "json", "jsonl", "txt", "md", "log", "vtt", "srt", "plist", "ips", "part",
        "py", "pyc", "swift", "sh", "dylib", "so", "safetensors", "bin", "npz", "gguf", "zip",
    ]

    /// Characters that end a word, besides whitespace — where a path's word starts. Shared with
    /// `CrashReportDigest`, which cuts its free text at the first path-like word.
    static let pathWordBreaks: Set<Character> = [
        "=", ":", ",", ";", "(", ")", "[", "]", "{", "}", "<", ">", "|",
        "\"", "'", "“", "”", "‘", "’", "«", "»", "「", "」", "『", "』",
    ]

    /// What may follow a recognised extension and end the path there without a later-`/` check:
    /// closing quotes and brackets, separators, and the backslash of an escaped quote in a
    /// `String(describing:)` payload.
    private static let pathEndPunctuation: Set<Character> = [
        "\"", "'", "’", "”", "»", "」", "』", ")", "]", "}", ">", ",", ";", ":", "|", "\\", "`",
    ]

    private static func isPathWordBreak(_ character: Character) -> Bool {
        character.isWhitespace || pathWordBreaks.contains(character)
    }

    private static func redactingPaths(inLine line: [Character]) -> String {
        var output = ""
        var position = 0
        while let trigger = firstPathTrigger(in: line, from: position) {
            var start = trigger
            while start > position, !isPathWordBreak(line[start - 1]) { start -= 1 }
            output += String(line[position..<start])
            if let end = recognisedPathEnd(in: line, from: trigger) {
                output += "<path>"
                position = end
            } else {
                // Whatever is left of the line goes, and "…" says so — unless the path was all of it.
                output += line[trigger...].contains(where: \.isWhitespace) ? "<path>…" : "<path>"
                position = line.count
            }
        }
        return output + String(line[position...])
    }

    /// The first index at or after `position` where a path starts: `file:` not inside a word, `~/`
    /// at the start of one, or a `/` followed by a component, another `/` and the start of a second.
    private static func firstPathTrigger(in line: [Character], from position: Int) -> Int? {
        let count = line.count
        var index = position
        while index < count {
            let character = line[index]
            if character == "/" {
                var next = index + 1
                while next < count, line[next] != "/", !line[next].isWhitespace { next += 1 }
                if next > index + 1, next + 1 < count, line[next] == "/",
                   line[next + 1] != "/", !line[next + 1].isWhitespace {
                    return index
                }
            } else if character == "~", index + 2 < count, line[index + 1] == "/",
                      !line[index + 2].isWhitespace,
                      index == 0 || isPathWordBreak(line[index - 1]) {
                return index
            } else if character == "f" || character == "F", index + 5 < count,
                      String(line[index..<index + 5]).lowercased() == "file:", line[index + 5] == "/",
                      index == 0 || !(line[index - 1].isLetter || line[index - 1].isNumber) {
                return index
            }
            index += 1
        }
        return nil
    }

    /// Where a path starting at `start` ends, when that can be recognised: just after the first
    /// recognised extension that nothing more of a name can follow. Nil means it cannot be.
    private static func recognisedPathEnd(in line: [Character], from start: Int) -> Int? {
        let count = line.count
        var dot = start
        while dot < count {
            defer { dot += 1 }
            guard line[dot] == "." else { continue }
            var end = dot + 1
            while end < count, line[end].isASCII, line[end].isLetter || line[end].isNumber { end += 1 }
            guard end > dot + 1,
                  recognisedExtensions.contains(String(line[(dot + 1)..<end]).lowercased()) else { continue }
            guard end < count else { return end }
            let next = line[end]
            let endsASentence = ".!?".contains(next) && (end + 1 == count || line[end + 1].isWhitespace)
            if next.isWhitespace || endsASentence {
                // A later `/` means this may be a folder in the middle of a longer path.
                if !line[end...].contains("/") { return end }
            } else if pathEndPunctuation.contains(next) {
                return end
            }
        }
        return nil
    }

    /// Error text destined for the unified system log (F154): path-redacted, so `.public` OSLog
    /// interpolations can never leak absolute paths into Console/sysdiagnose. One named entry
    /// point so new log sites don't hand-roll (or forget) the redaction.
    public static func publicLogDescription(_ error: some Error) -> String {
        redactPaths(error.localizedDescription)
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
        // F370: the bundle used to contain nothing about crashes at all, so the one artifact a
        // support question needs was the one thing it could not carry. Names and epochs, plus the
        // command that recovers an exception reason the report may not have. F389 adds each
        // report's digest, read by allowlist, with its free text cut at the first path and its quoted
        // names redacted (`CrashReportDigest` says exactly what), rather than quoting the `.ips`,
        // which would put absolute paths into a bundle whose whole guarantee is that it has none (F70).
        let crashReports: [[String: Any]] = input.crashReports.map { report in
            var entry: [String: Any] = [
                "name": report.fileName,
                "writtenAt": Int(saturating: report.writtenAt.timeIntervalSince1970),
            ]
            if let digest = report.digest { entry["digest"] = digest.jsonObject }
            return entry
        }
        var payload: [String: Any] = [
            "meetingCount": input.meetings.count,
            "vocabularyTermCount": input.vocabulary.count,
            "meetings": meetings,
            "crashReportCount": input.crashReports.count,
            "crashReports": crashReports,
        ]
        if let oldest = input.crashReports.last {
            payload["crashLogCommand"] = CrashReportInventory.logShowCommand(since: oldest.writtenAt)
        }
        guard let data = try? JSONSerialization.data(
            withJSONObject: payload,
            options: [.sortedKeys, .prettyPrinted, .withoutEscapingSlashes]
        ), let string = String(data: data, encoding: .utf8) else {
            return "{}"
        }
        return string
    }
}
