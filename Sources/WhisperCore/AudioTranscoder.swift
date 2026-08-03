import Foundation

/// Transcodes a recording the selected engine can't natively decode into 16 kHz mono 16-bit WAV using
/// macOS's built-in `afconvert` (AudioToolbox — no ffmpeg needed), so imported containers still
/// transcribe. Used decode-first before handing audio to the Qwen helper: mlx-audio's miniaudio can't
/// read .mp4/.mov/.aiff/.caf, and afconvert can (F118). The original recording is never modified — the
/// transcode always writes to a fresh temp file.
public enum AudioTranscoder {
    /// Extensions mlx-audio's miniaudio decodes WITHOUT ffmpeg (wav/flac/mp3/ogg). Everything else —
    /// including .m4a/.aac (which mlx-audio would otherwise hand to ffmpeg) and video/other containers —
    /// is transcoded first via afconvert, so a Qwen-only user doesn't need ffmpeg installed at all (F145).
    public static let nativelyDecodableExtensions: Set<String> = ["wav", "flac", "mp3", "ogg"]

    public static func needsTranscoding(_ url: URL) -> Bool {
        !nativelyDecodableExtensions.contains(url.pathExtension.lowercased())
    }

    /// Transcodes `input` to a 16 kHz mono 16-bit WAV at `output` via `/usr/bin/afconvert` (the recipe
    /// proven in `Scripts/bench/generate_clips.sh`). Throws `AudioTranscoderError.transcodeFailed` if
    /// afconvert is missing or exits non-zero (e.g. a container it cannot decode, like a video-only
    /// .mov) — the caller maps that to switch-engine guidance rather than a raw error.
    public static func transcodeToWAV(input: URL, output: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/afconvert")
        process.arguments = ["-f", "WAVE", "-d", "LEI16@16000", "-c", "1", input.path, output.path]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        do {
            try process.run()
        } catch {
            throw AudioTranscoderError.transcodeFailed("afconvert could not be launched: \(error.localizedDescription)")
        }
        // afconvert writes audio to the output file; stdout/stderr carry only small log lines, so a
        // read-to-EOF then wait cannot deadlock on a full pipe.
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw AudioTranscoderError.transcodeFailed(String(decoding: data.suffix(2_000), as: UTF8.self))
        }
    }
}

public enum AudioTranscoderError: LocalizedError, Equatable {
    case transcodeFailed(String)

    public var errorDescription: String? {
        switch self {
        case let .transcodeFailed(log):
            return "unsupported file format — could not decode this recording. \(log)"
        }
    }
}
