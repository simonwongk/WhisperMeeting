import Foundation

/// Encodes a recording to compact speech audio for Shrink (F795): AAC-LC, 16 kHz, mono, in `.m4a`.
///
/// Two afconvert runs, because one loses audio. `-c 1` keeps only the left channel, and `--mix`,
/// which fixes that for WAV output, measurably does not apply when the output is AAC: a right-only
/// stereo file encoded straight to AAC decoded to silence (F796). So step one is the same mixed
/// 16 kHz mono WAV the engines are given, and step two encodes that mono file.
public enum AudioCompressor {
    /// The AAC target in bits per second. 32 kbps measured 32,928 bit/s, about 14.8 MB an hour.
    public static let bitRate = 32_000

    /// Writes `output`, using `workingWAV` as scratch and removing it afterwards. The caller puts
    /// both beside the recording, so the final rename into place stays on one volume.
    public static func compressSpeech(input: URL, output: URL, workingWAV: URL) throws {
        defer { try? FileManager.default.removeItem(at: workingWAV) }
        try AudioTranscoder.transcodeToWAV(input: input, output: workingWAV)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/afconvert")
        process.arguments = ["-f", "m4af", "-d", "aac", "-b", String(bitRate), workingWAV.path, output.path]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        do {
            try process.run()
        } catch {
            throw AudioTranscoderError.transcodeFailed("afconvert could not be launched: \(error.localizedDescription)")
        }
        // As in `transcodeToWAV`: the pipes carry only small log lines, so read-to-EOF then wait cannot deadlock.
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            try? FileManager.default.removeItem(at: output)
            throw AudioTranscoderError.transcodeFailed(String(decoding: data.suffix(2_000), as: UTF8.self))
        }
    }
}
