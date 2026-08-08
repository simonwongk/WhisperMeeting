import Foundation

/// The `yt-dlp` argument vectors, built purely so they are unit-tested without running anything — the
/// `LocalWhisperClient.commandArguments` precedent (F183). Three invariants are load-bearing and each is
/// asserted by a test:
///
/// - **`--` precedes the URL** in every vector (defense in depth against flag injection from a pasted
///   string, alongside `MediaSourceURL`'s leading-`-` rejection).
/// - **`--no-playlist`** in every vector (v1 imports a single item, never a playlist/channel).
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
            // ffmpeg would otherwise write. `-map_metadata -1 -fflags +bitexact` matter for correctness,
            // not tidiness: ffmpeg's WAV muxer emits a LIST/INFO chunk (its encoder tag) between `fmt `
            // and `data`, and this app's WAV readers — MeetingIntegrityChecker, the interrupted-recording
            // duration probe, and the per-segment clip slicer — all read the data-chunk size at the fixed
            // offset 40. With a LIST chunk present they read ITS size instead, so every link import would
            // be reported as damaged forever, a crash-recovered import would be indexed with a ~1 ms
            // duration, and segment re-runs would slice metadata bytes as PCM.
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
            ? "\(directory)captions.%(ext)s"
            : "\(directory)/captions.%(ext)s"
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

    /// Keeps only a plain BCP-47-ish language code (letters, digits, and single hyphens). Anything else
    /// falls back to a literal match on the raw value being impossible, so no captions are fetched — the
    /// safe direction, since captions are an optional reference.
    static func sanitizedSubLangs(_ raw: String) -> String {
        let allowed = raw.unicodeScalars.allSatisfy {
            CharacterSet.alphanumerics.contains($0) || $0 == "-"
        }
        return allowed && !raw.isEmpty && raw.count <= 20 ? raw : "none"
    }
}
