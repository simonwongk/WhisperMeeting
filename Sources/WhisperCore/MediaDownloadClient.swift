import Foundation

public enum MediaDownloadError: LocalizedError, Equatable {
    case runtimeNotInstalled
    case ffmpegMissing
    case playlistNotSupported
    case liveInProgress
    case unreadableProbe
    case missingOutput
    /// A classified `yt-dlp` failure — carries the plain-language explanation for the UI.
    case failed(MediaDownloadFailureInfo)
    case stalled

    public var errorDescription: String? {
        switch self {
        case .runtimeNotInstalled:
            return "The downloader isn't installed yet. Install the local Whisper runtime in Settings — it includes the downloader."
        case .ffmpegMissing:
            return "FFmpeg is required to extract audio from a link. Install the local Whisper runtime in Settings, which installs it."
        case .playlistNotSupported:
            return "That link points to a playlist or channel. Paste a link to a single video."
        case .liveInProgress:
            return "That's a live or upcoming stream. Try again once it has finished."
        case .unreadableProbe:
            return "The downloader returned details this app could not read."
        case .missingOutput:
            return "The download finished but no audio file was produced."
        case let .failed(info):
            return info.explanation
        case .stalled:
            return "The download stopped making progress, so it was cancelled. Check your connection and try again."
        }
    }
}

/// Locates the `yt-dlp` executable. It is installed into the **existing Whisper venv** by
/// `setup-local-whisper.sh`, so a user who has the meetings runtime already has the downloader; the
/// Homebrew/`~/.local` fallbacks mirror `LocalWhisperRuntime.findExecutable` (F183).
public enum MediaDownloadRuntime {
    public static func managedExecutable(applicationSupport: URL? = nil) -> URL {
        LocalWhisperRuntime.managedDirectory(applicationSupport: applicationSupport)
            .appendingPathComponent("venv/bin/yt-dlp")
    }

    public static func findExecutable(applicationSupport: URL? = nil) -> URL? {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let candidates = [
            managedExecutable(applicationSupport: applicationSupport),
            URL(fileURLWithPath: "/opt/homebrew/bin/yt-dlp"),
            URL(fileURLWithPath: "/usr/local/bin/yt-dlp"),
            home.appendingPathComponent(".local/bin/yt-dlp"),
        ]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    /// yt-dlp needs FFmpeg to extract audio. `setup-local-whisper.sh` installs it, but a Qwen-only user
    /// has neither — detect that rather than failing obscurely (Trap 14).
    public static func findFFmpeg() -> URL? {
        let candidates = [
            URL(fileURLWithPath: "/opt/homebrew/bin/ffmpeg"),
            URL(fileURLWithPath: "/usr/local/bin/ffmpeg"),
        ]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }
}

/// The `yt-dlp` subprocess contract (F183): probe a link, download just its audio as a canonical WAV,
/// and optionally fetch the publisher's captions as a reference. Runs through `ProcessGroupRunner`, so a
/// cancel kills yt-dlp *and* the ffmpeg it spawns, and a stalled network transfer aborts.
public struct MediaDownloadClient: Sendable {
    /// No output for this long means the transfer is stuck (a dead socket), not merely slow.
    ///
    /// It is generous on purpose. yt-dlp is **silent by design** while ffmpeg post-processes the audio
    /// after the bytes have arrived, and that pass can run for minutes on a multi-hour recording — a
    /// tight timeout would kill a perfectly healthy import and delete its folder. The watchdog only has
    /// to beat "hung forever", so it is sized to comfortably exceed the longest legitimate silence.
    public static let defaultStallTimeout: TimeInterval = 600

    private let executableURL: URL
    private let stallTimeout: TimeInterval

    public init(executableURL: URL, stallTimeout: TimeInterval = defaultStallTimeout) {
        self.executableURL = executableURL
        self.stallTimeout = stallTimeout
    }

    /// Resolves the installed downloader, or throws the actionable "not installed" error.
    public static func installed(stallTimeout: TimeInterval = defaultStallTimeout) throws -> MediaDownloadClient {
        guard let executable = MediaDownloadRuntime.findExecutable() else {
            throw MediaDownloadError.runtimeNotInstalled
        }
        return MediaDownloadClient(executableURL: executable, stallTimeout: stallTimeout)
    }

    public func probe(url: String) async throws -> MediaProbe {
        let runner = ProcessGroupRunner()
        let outcome = try await Self.mappingErrors {
            // `.parsedResult`: the probe payload is a single JSON line that is parsed as a whole, so it
            // must never be truncated the way a diagnostic log tail can be.
            try await runner.run(
                executableURL: executableURL,
                arguments: MediaDownloadArguments.probe(url: url),
                environment: Self.makeEnvironment(),
                stallTimeout: stallTimeout,
                outputUse: .parsedResult
            )
        }
        guard outcome.exitStatus == 0 else {
            throw MediaDownloadError.failed(MediaDownloadFailureClassifier.classify(stderr: outcome.output))
        }
        return try Self.parseProbe(outcome.output)
    }

    /// Translates the runner's low-level failures into actionable `MediaDownloadError`s. Without this the
    /// most likely network failure — a stall — would surface to the user as a raw Swift enum description,
    /// and `MediaDownloadError.stalled`'s written explanation would be dead code.
    static func mappingErrors<T>(_ body: () async throws -> T) async throws -> T {
        do {
            return try await body()
        } catch let error as ProcessGroupRunnerError {
            switch error {
            case .stalled:
                throw MediaDownloadError.stalled
            case .spawnFailed:
                throw MediaDownloadError.runtimeNotInstalled
            }
        }
    }

    /// Downloads the audio into `directory` as a canonical `recording.wav` and returns its URL.
    public func download(
        url: String,
        into directory: URL,
        progress: (@Sendable (MediaDownloadProgress) -> Void)? = nil
    ) async throws -> URL {
        // yt-dlp shells out to ffmpeg for the WAV extraction, and a Qwen-only user has neither installed
        // (only setup-local-whisper.sh provides them). Detect that here rather than surfacing yt-dlp's
        // own obscure post-processing error.
        guard MediaDownloadRuntime.findFFmpeg() != nil else { throw MediaDownloadError.ffmpegMissing }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let runner = ProcessGroupRunner()
        let parser = ParserBox()
        let outcome = try await Self.mappingErrors {
            try await runner.run(
                executableURL: executableURL,
                arguments: MediaDownloadArguments.download(url: url, intoDirectory: directory.path),
                environment: Self.makeEnvironment(),
                stallTimeout: stallTimeout
            ) { chunk in
                if let update = parser.consume(chunk) { progress?(update) }
            }
        }
        guard outcome.exitStatus == 0 else {
            throw MediaDownloadError.failed(MediaDownloadFailureClassifier.classify(stderr: outcome.output))
        }
        let expected = directory.appendingPathComponent("\(MediaDownloadArguments.outputBasename).wav")
        guard FileManager.default.fileExists(atPath: expected.path) else {
            throw MediaDownloadError.missingOutput
        }
        return expected
    }

    /// Best-effort captions, pinned to `subLangs` so an auto-translated track is never fetched. Returns
    /// an empty array rather than throwing — a caption failure must never fail the import.
    public func captions(url: String, into directory: URL, subLangs: String) async -> [TranscriptSegment] {
        let runner = ProcessGroupRunner()
        guard let outcome = try? await runner.run(
            executableURL: executableURL,
            arguments: MediaDownloadArguments.captions(
                url: url, intoDirectory: directory.path, subLangs: subLangs
            ),
            environment: Self.makeEnvironment(),
            stallTimeout: stallTimeout
        ), outcome.exitStatus == 0 else {
            return []
        }
        let files = (try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil
        )) ?? []
        guard let vtt = files.first(where: { $0.pathExtension.lowercased() == "vtt" }),
              let text = try? String(contentsOf: vtt, encoding: .utf8) else {
            return []
        }
        return SubtitleParser.parse(text)
    }

    /// Maps `yt-dlp --dump-single-json` output onto `MediaProbe`. Pure and unit-tested against a real
    /// payload shape, so the contract is checked without running the downloader.
    public static func parseProbe(_ output: String) throws -> MediaProbe {
        // yt-dlp may print warnings before the JSON; take the last line that parses as an object.
        let candidates = output
            .split(whereSeparator: { $0 == "\n" || $0 == "\r" })
            .map(String.init)
            .filter { $0.hasPrefix("{") }
        guard let json = candidates.last, let data = json.data(using: .utf8),
              let payload = try? JSONDecoder().decode(YtDlpProbeOutput.self, from: data) else {
            throw MediaDownloadError.unreadableProbe
        }
        return MediaProbe(
            title: payload.title,
            durationSeconds: payload.duration,
            uploader: payload.uploader ?? payload.channel,
            uploadDate: payload.uploadDate.flatMap(Self.parseUploadDate),
            approximateBytes: payload.filesizeApprox ?? payload.filesize,
            isLive: payload.isLive ?? false,
            language: payload.language
        )
    }

    /// yt-dlp reports `upload_date` as `YYYYMMDD`. Deterministic (POSIX locale, UTC).
    static func parseUploadDate(_ raw: String) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyyMMdd"
        return formatter.date(from: raw)
    }

    /// A GUI-launched app inherits a bare `PATH` with no `/opt/homebrew/bin`, so yt-dlp's own lookup of
    /// `ffmpeg` fails even when FFmpeg is installed — the exact shape of the shipped F132 defect. The
    /// offline flags from the transcription clients are deliberately NOT copied: they belong to a model
    /// run, and this process must reach the network (Trap 13).
    public static func makeEnvironment(
        base: [String: String] = ProcessInfo.processInfo.environment
    ) -> [String: String] {
        var environment = base
        let existingPath = environment["PATH"] ?? "/usr/bin:/bin"
        environment["PATH"] = "/opt/homebrew/bin:/usr/local/bin:\(existingPath)"
        environment["PYTHONUNBUFFERED"] = "1"
        environment.removeValue(forKey: "HF_HUB_OFFLINE")
        environment.removeValue(forKey: "TRANSFORMERS_OFFLINE")
        return environment
    }
}

/// Holds the streaming progress parser across the runner's output callbacks.
private final class ParserBox: @unchecked Sendable {
    private let lock = NSLock()
    private var parser = MediaDownloadProgressParser()

    func consume(_ chunk: String) -> MediaDownloadProgress? {
        lock.lock()
        defer { lock.unlock() }
        return parser.consume(chunk)
    }
}

/// The subset of `yt-dlp --dump-single-json` this app reads.
struct YtDlpProbeOutput: Decodable {
    let title: String?
    let duration: Double?
    let uploader: String?
    let channel: String?
    let uploadDate: String?
    let filesizeApprox: Int64?
    let filesize: Int64?
    let isLive: Bool?
    let language: String?

    enum CodingKeys: String, CodingKey {
        case title, duration, uploader, channel, language, filesize
        case uploadDate = "upload_date"
        case filesizeApprox = "filesize_approx"
        case isLive = "is_live"
    }
}
