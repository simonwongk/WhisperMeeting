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

    /// The format the engines want, and what `transcodeToWAV` produces.
    static let targetSampleRate: UInt32 = 16_000
    static let targetChannels: UInt32 = 1

    public static func needsTranscoding(_ url: URL) -> Bool {
        guard nativelyDecodableExtensions.contains(url.pathExtension.lowercased()) else { return true }
        // "Natively decodable" is not "free to decode". Meetings are captured at 48 kHz mono
        // (`AudioCaptureEngine.targetSampleRate`), and mlx-audio then miniaudio-decodes the whole
        // recording, casts it to float64 and runs scipy `resample_poly` 48k -> 16k *inside* the ASR
        // process, on the critical path. Measured on a synthetic 47-minute 48 kHz mono WAV:
        // load_audio 2.83 s and 2.21 GB peak RSS, versus 0.06 s once pre-converted — while afconvert
        // does the same conversion in 0.29 s, off the model's memory budget.
        //
        // Only WAV is checked: its format is four cheap header bytes away. Reading a flac/mp3/ogg
        // header is not, and transcoding those on a guess would add work rather than remove it.
        guard url.pathExtension.lowercased() == "wav",
              let header = WAVInspection.header(at: url) else {
            // Unreadable, absent, or not a container we can inspect: keep today's behaviour. Claiming
            // a transcode is needed would hand afconvert a file it may not decode, turning a decode
            // the engine might well manage into a hard "unsupported file format".
            return false
        }
        return header.sampleRate != targetSampleRate || header.channels != targetChannels
    }

    /// Transcodes `input` to a 16 kHz mono 16-bit WAV at `output` via `/usr/bin/afconvert` (the recipe
    /// proven in `Scripts/bench/generate_clips.sh`). Throws `AudioTranscoderError.transcodeFailed` if
    /// afconvert is missing or exits non-zero (e.g. a container it cannot decode, like a video-only
    /// .mov) — the caller maps that to switch-engine guidance rather than a raw error.
    public static func transcodeToWAV(input: URL, output: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/afconvert")
        process.arguments = transcodeArguments(input: input, output: output)
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

    /// afconvert's arguments for `transcodeToWAV`.
    ///
    /// `--mix`, because `-c 1` alone "add[s]/remove[s] channels without regard to order": it keeps the
    /// left channel and drops the right, so a two-channel call recording lost one party (F796). But not
    /// for a recording known to hold one channel, where there is nothing to mix: afconvert exits 1 with
    /// "Couldn't set audio converter property (-50)" when `--mix` is given for an input already in the
    /// output's format — 16 kHz mono 16-bit integer PCM, in a WAV or a CAF — because no converter is
    /// made for it to be set on, and that is the WAV every link import holds (F941). Measured on macOS
    /// 27: without `--mix` that input converts; and a mono input of any rate has nothing to mix. A
    /// recording whose channels cannot be read here keeps `--mix`, the safe side for a stereo call;
    /// every such input measured converts with it (AAC, MP3, big-endian AIFF, movies with a video
    /// track), as do mono WAVs that are not exactly the output's format (24-bit, Float32, 48 kHz).
    static func transcodeArguments(input: URL, output: URL) -> [String] {
        let mix: [String] = knownChannelCount(of: input) == 1 ? [] : ["--mix"]
        return ["-f", "WAVE", "-d", "LEI16@16000", "-c", "1"] + mix + [input.path, output.path]
    }

    /// How many channels `url` holds, read from its header when it is a WAV or a CAF, by content and not
    /// by name; nil for anything else, or a header that cannot be read (F941). A bounded read of the
    /// first bytes, never the audio.
    static func knownChannelCount(of url: URL) -> Int? {
        if let header = WAVInspection.header(at: url) { return Int(header.channels) }
        // A CAF starts with its file header ('caff', version, flags: 8 bytes), and its first chunk must
        // be the audio description ('desc', a 64-bit size, then an AudioStreamBasicDescription, all
        // big-endian), whose mChannelsPerFrame is 24 bytes into the chunk's body (Core Audio Format
        // Specification, "CAF File Header" and "Audio Description Chunk").
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: 52), data.count == 52,
              WAVInspection.fourCC(data, 0) == "caff", WAVInspection.fourCC(data, 8) == "desc" else { return nil }
        var channels: UInt32 = 0
        for offset in 44..<48 { channels = channels << 8 | UInt32(data[data.startIndex + offset]) }
        return channels > 0 ? Int(channels) : nil
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
