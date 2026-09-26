import Foundation

/// The `yt-dlp` argument vectors, built purely so they are unit-tested without running anything — the
/// `LocalWhisperClient.commandArguments` precedent (F183). Three invariants are load-bearing and each is
/// asserted by a test:
///
/// - **`--` precedes the URL** in every vector (defense in depth against flag injection from a pasted
///   string, alongside `MediaSourceURL`'s leading-`-` rejection).
/// - **`--no-playlist`** in every vector, so a URL that names both a video and a playlist fetches the
///   video. It does nothing for a URL that names only a playlist or channel; the probe refuses those
///   (`MediaDownloadClient.parseProbe`, F495), because v1 imports a single item.
/// - **Audio is forced to 16 kHz mono 16-bit WAV named `recording`** — required so the interrupted-
///   recovery basename match and per-segment re-run (canonical RIFF/WAVE) keep working (Traps 1–2), and
///   so a Qwen-only user isn't handed an Opus/WebM file AudioToolbox can't decode.
///
/// NOTE: the core flags here are stable yt-dlp API; the exact ffmpeg post-processor recipe should be
/// confirmed against an installed `yt-dlp` before release (there is none in this environment) — recorded
/// as a gap on the ticket, not guessed silently.
public enum MediaDownloadArguments {
    /// The output basename the rest of the app requires (Trap 2). yt-dlp fills the real extension.
    public static let outputBasename = "recording"
    /// The caption fetch's output basename; yt-dlp writes each track as `captions.<lang>.vtt`.
    public static let captionsBasename = "captions"

    /// Probe metadata (title/duration/uploader/filesize/live) without downloading — this is what makes
    /// the storage guard and the duration warning possible before an unbounded fetch.
    ///
    /// `--ignore-config` is on every vector: without it a user's `yt-dlp.conf` is merged in silently, so
    /// what actually runs is not the contract these arguments are tested against (it could re-enable
    /// playlists, change the output template, or add post-processors).
    public static func probe(url: String) -> [String] {
        [
            "--ignore-config",
            "--dump-single-json",
            "--no-playlist",
            "--no-warnings",
            // Report sizes for the format that will actually be fetched. Without this the probe measures
            // the default (video+audio) selection, so the storage guard reserves far more than the
            // audio-only download needs and can refuse an import that would comfortably fit.
            "-f", "bestaudio/best",
            "--",
            url,
        ]
    }

    /// Download just the audio, transcoded to 16 kHz mono 16-bit WAV, straight into the meeting folder.
    public static func download(url: String, intoDirectory directory: String) -> [String] {
        let template = directory.hasSuffix("/")
            ? "\(directory)\(outputBasename).%(ext)s"
            : "\(directory)/\(outputBasename).%(ext)s"
        return [
            "--ignore-config",
            "--no-playlist",
            "--newline",                       // one progress line at a time, for the progress parser
            "-f", "bestaudio/best",
            "--extract-audio",
            "--audio-format", "wav",
            // Force 16 kHz mono 16-bit at the ffmpeg post-processing step, and suppress the metadata
            // ffmpeg would otherwise write. `-map_metadata -1 -fflags +bitexact` keep ffmpeg's WAV muxer
            // from emitting a LIST/INFO chunk (its encoder tag) between `fmt ` and `data`. When this was
            // written, this app's WAV readers — MeetingIntegrityChecker, the interrupted-recording
            // duration probe, and the per-segment clip slicer — all read the data-chunk size at the fixed
            // offset 40, so a LIST chunk made every link import read as damaged, a crash-recovered import
            // ~1 ms long, and segment re-runs slice metadata bytes as PCM. All three now walk the chunks
            // (F224, F435, F471); the flags stay as defence in depth, and the 16-bit mono part is still
            // what the per-segment re-run requires.
            "--postprocessor-args",
            "ExtractAudio+ffmpeg:-ar 16000 -ac 1 -sample_fmt s16 -map_metadata -1 -fflags +bitexact",
            "-o", template,
            "--",
            url,
        ]
    }

    /// Best-effort caption fetch, pinned to `subLangs` (the video's own language from the probe) so an
    /// auto-**translated** track can never be adopted into the transcript (original-language invariant).
    public static func captions(url: String, intoDirectory directory: String, subLangs: String) -> [String] {
        let template = directory.hasSuffix("/")
            ? "\(directory)\(captionsBasename).%(ext)s"
            : "\(directory)/\(captionsBasename).%(ext)s"
        return [
            "--ignore-config",
            "--no-playlist",
            "--skip-download",
            "--write-subs",
            "--write-auto-subs",
            "--sub-format", "vtt",
            // `--sub-langs` is a pattern, not a literal code (it supports regex and an `all` keyword), and
            // the value comes from the site's own metadata — so it is sanitized before it gets here, or
            // a hostile `language` field could re-open the auto-translated-caption hole this pin closes.
            "--sub-langs", sanitizedSubLangs(subLangs),
            "-o", template,
            "--",
            url,
        ]
    }

    /// Keeps only a value shaped like a BCP 47 tag — a 2–3 letter language, then `-` subtags of 2–8
    /// ASCII letters or digits — and never `all`, yt-dlp's alias for every track, manual and automatic
    /// (F495). Nothing in that shape is regex syntax or yt-dlp's leading-`-` discard. Anything else
    /// becomes `none`, which matches no track, so no captions are fetched — the safe direction, since
    /// captions are an optional reference.
    static func sanitizedSubLangs(_ raw: String) -> String {
        let tag = #"\A[A-Za-z]{2,3}(-[A-Za-z0-9]{2,8})*\z"#
        guard raw.count <= 20, raw.lowercased() != "all",
              raw.range(of: tag, options: .regularExpression) != nil else { return "none" }
        return raw
    }
}
