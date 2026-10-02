import Foundation

/// What the diagnostics bundle carries from inside one crash report (F389).
///
/// F370 put crash reports into the bundle as names and timestamps, because an `.ips` is full of
/// absolute paths and load addresses and the bundle promises neither (F70). That made the bundle a
/// pointer rather than a package: whoever was diagnosing still had to open the file by hand, which
/// is most of what made F356 take months. This reads the useful part out instead.
///
/// **An allowlist, never "everything minus paths".** Only these fields are read out:
///
/// - the app and OS version, from the header;
/// - the exception's type, signal and subtype;
/// - the termination's namespace and indicator;
/// - the application-specific information (`asi`), as "<image>: <text>";
/// - the crashed thread's frames, and the last exception backtrace, as "<image name> <symbol>".
///
/// Never the process path, an image's path, base or UUID, a frame's offset or source file, the
/// thread state, the reporter key, the user ID, the sleep/wake UUID, the incident ID, or any thread
/// but the crashed one. Every string that is kept goes through `DiagnosticsBundleBuilder.redactPaths`,
/// has its hex addresses replaced with `<addr>` and its control characters with spaces, and is
/// capped. The caps are `frameLimit` frames per list, `entryLimit` `asi` entries and `stringLimit`
/// characters a string.
///
/// **Free text is cut, not only redacted.** An `asi` entry and the exception subtype can carry
/// interpolated runtime text, and `redactPaths` recognises only ASCII path components with no space
/// in them. So before that cleaning, those two fields lose:
///
/// - what is between each pair of quotes — `"…"`, `“…”`, `'…'`, `‘…’`, `«…»`, `「…」`, `『…』` —
///   which becomes `<name>`, the quotes kept. A quote that never closes takes the rest of the string
///   with it ("<name>…"). The one exception is Apple's preamble "… uncaught exception '<name>',
///   reason: '<reason>'", when the name is an identifier and the reason's closing quote ends the
///   string: those two pairs of quotes are kept, and the reason between them is scrubbed like any
///   other free text;
/// - everything from the first path-like word on, which becomes `<path>…`: a `file:` URL, a
///   `<path>` already in the text, or a word with a `/` in it ("/Users/…", "~/…", "Recordings/…")
///   other than a Swift file ID (`Module/File.swift`). A word starts after the last space,
///   bracket, quote or `= : , ; |` before it, so an absolute path is cut whole, whatever spaces or
///   non-ASCII names follow its first `/`.
///
/// What this cannot see is text that is neither quoted nor in a path: a file name interpolated
/// bare ("cannot open Board Meeting.m4a") is carried, up to `stringLimit` characters, and so are the
/// words before the first `/` of a relative path that has a space in it. The versions, the
/// exception's type and signal, the termination fields and the frames come from the app's bundle,
/// the OS and the symbol table rather than from interpolated text, and keep the plain cleaning.
///
/// How much to carry was a scoping call made for this ticket, bounded by F70 (no transcript,
/// summary, vocabulary, titles or paths): the frames' symbols are the useful part, the binaries'
/// paths and addresses are not, so the digest names images by their short `name` only.
///
/// The format is JSON — a one-line header object, then the body object — and it is recognised by
/// whether it parses that way, not by the file's extension. Anything else gives nil — the
/// pre-Monterey text format still used for `.crash` files, a truncated write, a report with nothing
/// on the allowlist — and the report is then still listed by name.
public struct CrashReportDigest: Sendable, Equatable {
    /// Frames kept per list: the top of the crashed thread is where the reason is.
    public static let frameLimit = 25
    /// `asi` entries kept, across all images.
    public static let entryLimit = 8
    /// Characters kept per string; a longer one is cut and ends with "…".
    public static let stringLimit = 300

    /// `app_version (build_version)` from the header.
    public let appVersion: String?
    /// `os_version` from the header, e.g. "macOS 26.0 (25A354)".
    public let osVersion: String?
    public let exceptionType: String?
    public let exceptionSignal: String?
    public let exceptionSubtype: String?
    public let terminationNamespace: String?
    public let terminationIndicator: String?
    /// The `asi` field, one "<image>: <text>" per message, images in name order.
    public let applicationSpecificInformation: [String]
    /// The crashed thread's frames, top first, as "<image name> <symbol>"; "???" where either is absent.
    public let faultingThreadFrames: [String]
    /// The Objective-C exception's backtrace when the report has one (the NSException shape F356 had).
    public let lastExceptionBacktrace: [String]

    public init(
        appVersion: String? = nil,
        osVersion: String? = nil,
        exceptionType: String? = nil,
        exceptionSignal: String? = nil,
        exceptionSubtype: String? = nil,
        terminationNamespace: String? = nil,
        terminationIndicator: String? = nil,
        applicationSpecificInformation: [String] = [],
        faultingThreadFrames: [String] = [],
        lastExceptionBacktrace: [String] = []
    ) {
        self.appVersion = appVersion
        self.osVersion = osVersion
        self.exceptionType = exceptionType
        self.exceptionSignal = exceptionSignal
        self.exceptionSubtype = exceptionSubtype
        self.terminationNamespace = terminationNamespace
        self.terminationIndicator = terminationIndicator
        self.applicationSpecificInformation = applicationSpecificInformation
        self.faultingThreadFrames = faultingThreadFrames
        self.lastExceptionBacktrace = lastExceptionBacktrace
    }

    /// Reads a JSON crash report, or nil when it is not one or has nothing on the allowlist.
    ///
    /// Wrongly typed fields are skipped one by one, so an unexpected shape costs that field rather
    /// than the report: every cast is conditional and every index is range-checked.
    public static func parse(_ data: Data) -> CrashReportDigest? {
        guard let newline = data.firstIndex(of: UInt8(ascii: "\n")) else { return nil }
        guard let header = (try? JSONSerialization.jsonObject(with: data[data.startIndex..<newline])) as? [String: Any],
              let body = (try? JSONSerialization.jsonObject(with: data[data.index(after: newline)...])) as? [String: Any]
        else { return nil }

        let exception = body["exception"] as? [String: Any] ?? [:]
        let termination = body["termination"] as? [String: Any] ?? [:]
        let images = body["usedImages"] as? [Any] ?? []

        var faultingFrames: [String] = []
        if let index = body["faultingThread"] as? Int,
           let threads = body["threads"] as? [Any],
           threads.indices.contains(index),
           let thread = threads[index] as? [String: Any] {
            faultingFrames = frames(thread["frames"], images: images)
        }

        let version = (header["app_version"] as? String).map { app in
            (header["build_version"] as? String).map { "\(app) (\($0))" } ?? app
        }
        let digest = CrashReportDigest(
            appVersion: version.map(clean),
            osVersion: (header["os_version"] as? String).map(clean),
            exceptionType: (exception["type"] as? String).map(clean),
            exceptionSignal: (exception["signal"] as? String).map(clean),
            exceptionSubtype: (exception["subtype"] as? String).map(cleanFreeText),
            terminationNamespace: (termination["namespace"] as? String).map(clean),
            terminationIndicator: (termination["indicator"] as? String).map(clean),
            applicationSpecificInformation: applicationSpecificInformation(body["asi"]),
            faultingThreadFrames: faultingFrames,
            lastExceptionBacktrace: frames(body["lastExceptionBacktrace"], images: images)
        )
        // The versions alone are not a crash: a report must say something about what happened.
        let saysWhatHappened = digest.exceptionType != nil || digest.exceptionSignal != nil
            || digest.exceptionSubtype != nil || digest.terminationNamespace != nil
            || digest.terminationIndicator != nil || !digest.applicationSpecificInformation.isEmpty
            || !digest.faultingThreadFrames.isEmpty || !digest.lastExceptionBacktrace.isEmpty
        return saysWhatHappened ? digest : nil
    }

    /// The digest as the bundle emits it: only what is present, strings and arrays of strings only,
    /// so `JSONSerialization` can never be handed a type it would raise on.
    var jsonObject: [String: Any] {
        var object: [String: Any] = [:]
        let optionals: [(String, String?)] = [
            ("appVersion", appVersion), ("osVersion", osVersion),
            ("exceptionType", exceptionType), ("exceptionSignal", exceptionSignal),
            ("exceptionSubtype", exceptionSubtype),
            ("terminationNamespace", terminationNamespace), ("terminationIndicator", terminationIndicator),
        ]
        for (key, value) in optionals { if let value { object[key] = value } }
        let lists: [(String, [String])] = [
            ("applicationSpecificInformation", applicationSpecificInformation),
            ("faultingThreadFrames", faultingThreadFrames),
            ("lastExceptionBacktrace", lastExceptionBacktrace),
        ]
        for (key, value) in lists where !value.isEmpty { object[key] = value }
        return object
    }

    private static func frames(_ raw: Any?, images: [Any]) -> [String] {
        guard let list = raw as? [Any] else { return [] }
        return list.prefix(frameLimit).map { element in
            let frame = element as? [String: Any] ?? [:]
            var image = "???"
            if let index = frame["imageIndex"] as? Int, images.indices.contains(index),
               let name = (images[index] as? [String: Any])?["name"] as? String, !name.isEmpty {
                image = name
            }
            let symbol = (frame["symbol"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "???"
            return clean("\(image) \(symbol)")
        }
    }

    private static func applicationSpecificInformation(_ raw: Any?) -> [String] {
        guard let byImage = raw as? [String: Any] else { return [] }
        var entries: [String] = []
        for image in byImage.keys.sorted() {
            let messages: [String]
            if let list = byImage[image] as? [Any] {
                messages = list.compactMap { $0 as? String }
            } else if let single = byImage[image] as? String {
                messages = [single]
            } else {
                messages = []
            }
            for message in messages {
                guard entries.count < entryLimit else { return entries }
                entries.append(cleanFreeText("\(image): \(message)"))
            }
        }
        return entries
    }

    private static let hexAddress = try? NSRegularExpression(pattern: "0[xX][0-9A-Fa-f]+")

    /// Paths redacted, hex addresses replaced, control characters flattened, then capped — in that
    /// order, so a cap can never cut a path in a way that stops it being recognised.
    static func clean(_ text: String) -> String {
        var cleaned = DiagnosticsBundleBuilder.redactPaths(text)
        if let hexAddress {
            let range = NSRange(cleaned.startIndex..<cleaned.endIndex, in: cleaned)
            cleaned = hexAddress.stringByReplacingMatches(in: cleaned, range: range, withTemplate: "<addr>")
        }
        cleaned = String(cleaned.unicodeScalars.map { scalar -> Character in
            CharacterSet.controlCharacters.contains(scalar) ? " " : Character(scalar)
        })
        if cleaned.count > stringLimit {
            cleaned = String(cleaned.prefix(stringLimit)) + "…"
        }
        return cleaned
    }

    /// `clean` for the two fields that carry interpolated runtime text — an `asi` entry and the
    /// exception subtype — after their quoted names and everything from their first path-like word
    /// on are taken out (the type's doc lists exactly what).
    ///
    /// `redactPaths` alone is not enough here: it recognises only ASCII path components with no
    /// space in them, so it turned "/Users/jane/Movies/会议记录/季度规划会议.mov" into
    /// "<path>/会议记录/季度规划会议.mov", and kept a quoted file name whole. A file name can be a
    /// meeting title, which the bundle never carries (F70).
    static func cleanFreeText(_ text: String) -> String {
        clean(scrubbingFreeText(text))
    }

    /// Apple's uncaught-exception preamble. Its two pairs of quotes are delimiters, not names: the
    /// exception's name, matched only when it is an identifier as Apple's are, and the reason, which
    /// is the useful part of the report and is scrubbed like any other free text. Text that does not
    /// match all of it, to the reason's closing quote at the end, is scrubbed whole instead.
    private static let uncaughtException = try? NSRegularExpression(
        pattern: #"^(.*?uncaught exception )'([A-Za-z0-9_.$-]+)', reason: '(.*)'$"#,
        options: [.dotMatchesLineSeparators]
    )

    private static func scrubbingFreeText(_ text: String) -> String {
        let whole = NSRange(text.startIndex..<text.endIndex, in: text)
        if let uncaughtException,
           let match = uncaughtException.firstMatch(in: text, range: whole),
           let lead = Range(match.range(at: 1), in: text),
           let name = Range(match.range(at: 2), in: text),
           let reason = Range(match.range(at: 3), in: text) {
            let scrubbedLead = scrub(String(text[lead]))
            guard !scrubbedLead.cut else { return scrubbedLead.text }
            let scrubbedReason = scrub(String(text[reason]))
            return scrubbedLead.text + "'\(text[name])', reason: '" + scrubbedReason.text
                + (scrubbedReason.cut ? "" : "'")
        }
        return scrub(text).text
    }

    /// Quote characters and the character that closes each. Whatever is between them is replaced
    /// with `<name>`, the quotes kept.
    private static let quotePairs: [Character: Character] = [
        "\"": "\"", "“": "”", "'": "'", "‘": "’", "«": "»", "「": "」", "『": "』",
    ]

    /// Characters that end a word for the path search: whitespace and these.
    private static let wordBreaks: Set<Character> = [
        "=", ":", ",", ";", "(", ")", "[", "]", "{", "}", "<", ">", "|",
        "\"", "'", "“", "”", "‘", "’", "«", "»", "「", "」", "『", "』",
    ]

    /// Quoted names out, then cut at the first path-like word. `cut` says whether the end of `text`
    /// was dropped, so a caller stitching pieces together stops there.
    private static func scrub(_ text: String) -> (text: String, cut: Bool) {
        let named = redactingQuotedNames(text)
        if let start = firstPathLikeWord(in: named.text) {
            return (String(named.text[..<start]) + "<path>…", true)
        }
        return named
    }

    /// Replaces what is between each pair of quotes with `<name>`. A quote that never closes takes
    /// the rest of the text with it ("<name>…"). An ASCII `'` opens a quote only when it does not
    /// follow a letter or digit, and an ASCII `'` or `’` closes one only when it is not followed by
    /// one, so the apostrophes in "can't" and "Jane’s" are neither.
    private static func redactingQuotedNames(_ text: String) -> (text: String, cut: Bool) {
        let characters = Array(text)
        func isWordCharacter(_ position: Int) -> Bool {
            characters.indices.contains(position) && (characters[position].isLetter || characters[position].isNumber)
        }
        var output = ""
        var position = 0
        while position < characters.count {
            let quote = characters[position]
            guard let close = quotePairs[quote], quote != "'" || !isWordCharacter(position - 1) else {
                output.append(quote)
                position += 1
                continue
            }
            var end = position + 1
            while end < characters.count {
                if characters[end] == close, (close != "'" && close != "’") || !isWordCharacter(end + 1) { break }
                end += 1
            }
            output.append(quote)
            output += "<name>"
            guard end < characters.count else { return (output + "…", true) }
            output.append(close)
            position = end + 1
        }
        return (output, false)
    }

    /// Where the first path-like word starts: a `file:` URL, an already-substituted `<path>`, or the
    /// first word with a `/` in it — "/Users/…", "~/…", "Recordings/…" — other than a Swift file ID
    /// (`Module/File.swift`, which a trap message names and which is code, not a path on this Mac).
    /// A word runs from the last space or `wordBreaks` character before the `/`, so the cut lands
    /// before the whole of an absolute path however many spaces or non-ASCII names follow.
    private static func firstPathLikeWord(in text: String) -> String.Index? {
        var earliest = text.range(of: #"(?i)\bfile:"#, options: .regularExpression)?.lowerBound
        if let marker = text.range(of: "<path>")?.lowerBound, marker < (earliest ?? text.endIndex) {
            earliest = marker
        }
        var position = text.startIndex
        while position < text.endIndex, position < (earliest ?? text.endIndex) {
            guard !isWordBreak(text[position]) else {
                position = text.index(after: position)
                continue
            }
            let start = position
            while position < text.endIndex, !isWordBreak(text[position]) {
                position = text.index(after: position)
            }
            let word = text[start..<position]
            if word.contains("/"), word.range(of: #"^[A-Za-z_][A-Za-z0-9_]*/[A-Za-z0-9_.+-]+\.swift$"#,
                                                options: .regularExpression) == nil {
                return min(start, earliest ?? start)
            }
        }
        return earliest
    }

    private static func isWordBreak(_ character: Character) -> Bool {
        character.isWhitespace || wordBreaks.contains(character)
    }
}

public extension CrashReportInventory {
    /// How many of the newest reports Export Diagnostics reads into a digest. The rest are still
    /// listed by name and time.
    static let digestedReportLimit = 5

    /// A report larger than this is listed without a digest rather than read whole.
    static let digestReadLimit = 4 * 1024 * 1024

    /// The listing Export Diagnostics uses (F389): F370's `reports(in:newerThan: nil)`, with the
    /// newest `digestLimit` reports read into a `CrashReportDigest`.
    ///
    /// This reads the files' contents, which the launch notice never does — the notice runs on the
    /// path that recovers interrupted recordings and needs only that a crash happened. Only the
    /// export, which a person chose to run, reads inside a report, and all it keeps from one is
    /// the digest's allowlist.
    static func reportsForDiagnostics(
        in directory: URL,
        processName: String = "WhisperMeet",
        digestLimit: Int = digestedReportLimit,
        using fileManager: FileManager = .default
    ) -> [CrashReportRecord] {
        reports(in: directory, processName: processName, newerThan: nil, using: fileManager)
            .enumerated()
            .map { position, record in
                guard position < digestLimit else { return record }
                return CrashReportRecord(
                    fileName: record.fileName,
                    writtenAt: record.writtenAt,
                    digest: digest(of: directory.appendingPathComponent(record.fileName))
                )
            }
    }

    /// Nil on any failure: an unreadable, oversized or non-JSON report is listed without a digest.
    private static func digest(of url: URL) -> CrashReportDigest? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: digestReadLimit + 1),
              data.count <= digestReadLimit else { return nil }
        return CrashReportDigest.parse(data)
    }
}
