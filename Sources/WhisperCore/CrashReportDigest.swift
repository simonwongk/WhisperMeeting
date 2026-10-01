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
/// but the crashed one. Every string that is kept still goes through
/// `DiagnosticsBundleBuilder.redactPaths`, has its hex addresses replaced with `<addr>`, and is
/// capped, because `asi` and an exception subtype can carry interpolated runtime text. The caps are
/// `frameLimit` frames per list, `entryLimit` `asi` entries and `stringLimit` characters a string.
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
            exceptionSubtype: (exception["subtype"] as? String).map(clean),
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
                entries.append(clean("\(image): \(message)"))
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
