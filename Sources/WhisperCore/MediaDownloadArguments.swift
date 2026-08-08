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
    public static func probe(url: String) -> [String] {
        [
            "--dump-single-json",
            "--no-playlist",
            "--no-warnings",
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
            "--no-playlist",
            "--newline",                       // one progress line at a time, for the progress parser
            "-f", "bestaudio/best",
            "--extract-audio",
            "--audio-format", "wav",
            // Force 16 kHz mono 16-bit at the ffmpeg post-processing step.
            "--postprocessor-args", "ExtractAudio+ffmpeg:-ar 16000 -ac 1 -sample_fmt s16",
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
            "--no-playlist",
            "--skip-download",
            "--write-subs",
            "--write-auto-subs",
            "--sub-format", "vtt",
            "--sub-langs", subLangs,
            "-o", template,
            "--",
            url,
        ]
    }
}
