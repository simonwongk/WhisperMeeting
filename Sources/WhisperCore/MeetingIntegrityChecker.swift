import Foundation

/// Pure reading of a 16-bit PCM WAV's RIFF/WAVE header — header bytes and file size only, never the
/// audio body. Shared between recovery, the integrity check (F66) and speaker analysis.
///
/// The chunks are WALKED rather than read at fixed offsets (F224). A canonical header does put
/// `fmt ` at 12 and `data` at 36, and this file assumed that for two years, but macOS's own
/// `afconvert` — which `AudioTranscoder.transcodeToWAV` runs before analysis — writes a 4 KB `FLLR`
/// padding chunk between the two. Offset 40 then lands on the filler's size (4044), so a
/// half-hour recording measured as 0.13 seconds and every diarization turn in it "exceeded" the
/// recording. Found by running the real models over a real converted file.
public enum WAVInspection {
    public struct Header: Sendable, Equatable {
        public let channels: UInt32
        public let sampleRate: UInt32
        public let bitsPerSample: UInt32
        public let declaredDataBytes: UInt32
        /// Byte offset of the first audio sample — 44 for a canonical header, more when a writer
        /// inserted chunks before `data`. What "the file is long enough" has to be measured from.
        public let dataOffset: UInt32
    }

    /// How far in the `data` chunk is looked for. `afconvert`'s filler is 4 KB; 64 KB leaves room
    /// for a writer with more to say while keeping this a bounded read of a file that may be
    /// gigabytes.
    static let maximumHeaderScanBytes = 65_536

    public static func header(at url: URL) -> Header? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: maximumHeaderScanBytes), data.count >= 44,
              fourCC(data, 0) == "RIFF", fourCC(data, 8) == "WAVE" else {
            return nil
        }

        var channels: UInt16?
        var sampleRate: UInt32?
        var bitsPerSample: UInt16?
        var index = 12
        while index + 8 <= data.count {
            let identifier = fourCC(data, index)
            let size = le32(data, index + 4)
            let body = index + 8
            if identifier == "fmt ", size >= 16, body + 16 <= data.count {
                channels = le16(data, body + 2)
                sampleRate = le32(data, body + 4)
                bitsPerSample = le16(data, body + 14)
            } else if identifier == "data" {
                guard let channels, let sampleRate, let bitsPerSample else { return nil }
                return Header(
                    channels: UInt32(channels),
                    sampleRate: sampleRate,
                    bitsPerSample: UInt32(bitsPerSample),
                    declaredDataBytes: size,
                    dataOffset: UInt32(body)
                )
            }
            // RIFF chunks are word-aligned, so an odd-sized one carries a pad byte.
            index = body + Int(size) + Int(size % 2)
        }
        // RIFF/WAVE with no `data` chunk in reach. Returning a guess here is how a file with no
        // audio at all gets reported as healthy.
        return nil
    }

    static func fourCC(_ data: Data, _ index: Int) -> String? {
        let start = data.startIndex + index
        guard start + 4 <= data.endIndex else { return nil }
        return String(data: data[start..<(start + 4)], encoding: .ascii)
    }

    static func le16(_ data: Data, _ index: Int) -> UInt16 {
        UInt16(data[data.startIndex + index]) | (UInt16(data[data.startIndex + index + 1]) << 8)
    }

    static func le32(_ data: Data, _ index: Int) -> UInt32 {
        UInt32(data[data.startIndex + index])
            | (UInt32(data[data.startIndex + index + 1]) << 8)
            | (UInt32(data[data.startIndex + index + 2]) << 16)
            | (UInt32(data[data.startIndex + index + 3]) << 24)
    }
}

public enum IntegrityFinding: Sendable, Equatable {
    case recordingMissing
    case recordingEmpty
    case wavHeaderUnreadable
    case wavTruncated(declaredBytes: Int64, actualBytes: Int64)
    case sourceTrackFrameMismatch(track: String, expectedFrames: Int64, actualFrames: Int64)
    case durationInconsistent(headerSeconds: Double, indexSeconds: Double)
}

public struct MeetingIntegrityDescriptor: Sendable {
    public struct SourceTrack: Sendable {
        public let name: String
        public let url: URL
        public let expectedFrameCount: Int64
        public init(name: String, url: URL, expectedFrameCount: Int64) {
            self.name = name
            self.url = url
            self.expectedFrameCount = expectedFrameCount
        }
    }

    public let recordingURL: URL
    public let sourceTracks: [SourceTrack]
    public let indexDurationSeconds: Double?

    public init(recordingURL: URL, sourceTracks: [SourceTrack], indexDurationSeconds: Double?) {
        self.recordingURL = recordingURL
        self.sourceTracks = sourceTracks
        self.indexDurationSeconds = indexDurationSeconds
    }
}

/// Flags a meeting whose audio is missing, empty, truncated, or inconsistent with its index —
/// reading headers and file sizes only, never opening or deleting audio (F66).
public enum MeetingIntegrityChecker {
    static let durationToleranceSeconds = 1.0

    public static func check(_ descriptor: MeetingIntegrityDescriptor) -> [IntegrityFinding] {
        var findings: [IntegrityFinding] = []
        let fileManager = FileManager.default

        if !fileManager.fileExists(atPath: descriptor.recordingURL.path) {
            findings.append(.recordingMissing)
        } else {
            let actualBytes = fileSize(descriptor.recordingURL)
            if actualBytes == 0 {
                findings.append(.recordingEmpty)
            } else if descriptor.recordingURL.pathExtension.lowercased() == "wav" {
                // WAV inspection (header/truncation/duration) only applies to in-app WAV recordings.
                // Imported non-WAV containers (.m4a/.mp3/.mp4/…) are opaque here — existence + non-empty
                // only — so a valid import is never mislabeled as a corrupt WAV (F143).
                if let header = WAVInspection.header(at: descriptor.recordingURL) {
                    // From where the audio actually starts, not from a presumed 44 (F224): a file
                    // with a filler chunk is longer than its data chunk by more than the header.
                    let requiredBytes = Int64(header.dataOffset) + Int64(header.declaredDataBytes)
                    if requiredBytes > actualBytes {
                        findings.append(.wavTruncated(declaredBytes: requiredBytes, actualBytes: actualBytes))
                    }
                    if let indexDuration = descriptor.indexDurationSeconds {
                        let bytesPerSecond = Double(header.sampleRate * header.channels * header.bitsPerSample / 8)
                        if bytesPerSecond > 0 {
                            let headerDuration = Double(header.declaredDataBytes) / bytesPerSecond
                            if abs(headerDuration - indexDuration) > durationToleranceSeconds {
                                findings.append(.durationInconsistent(headerSeconds: headerDuration, indexSeconds: indexDuration))
                            }
                        }
                    }
                } else {
                    findings.append(.wavHeaderUnreadable)
                }
            }
        }

        for track in descriptor.sourceTracks {
            let actualFrames = fileSize(track.url) / Int64(MemoryLayout<Float>.size)
            if actualFrames < track.expectedFrameCount {
                findings.append(.sourceTrackFrameMismatch(
                    track: track.name, expectedFrames: track.expectedFrameCount, actualFrames: actualFrames
                ))
            }
        }

        return findings
    }

    static func fileSize(_ url: URL) -> Int64 {
        ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? NSNumber)?.int64Value ?? 0
    }
}
