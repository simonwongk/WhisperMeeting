import Foundation

/// Pure reading of a 16-bit PCM WAV's 44-byte RIFF/WAVE header — header bytes and file size only,
/// never the audio body. Shared between recovery and the integrity check (F66).
public enum WAVInspection {
    public struct Header: Sendable, Equatable {
        public let channels: UInt32
        public let sampleRate: UInt32
        public let bitsPerSample: UInt32
        public let declaredDataBytes: UInt32
    }

    public static func header(at url: URL) -> Header? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: 44), data.count == 44,
              String(data: data[0..<4], encoding: .ascii) == "RIFF",
              String(data: data[8..<12], encoding: .ascii) == "WAVE" else {
            return nil
        }
        return Header(
            channels: UInt32(le16(data, 22)),
            sampleRate: le32(data, 24),
            bitsPerSample: UInt32(le16(data, 34)),
            declaredDataBytes: le32(data, 40)
        )
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
                    let requiredBytes = Int64(44) + Int64(header.declaredDataBytes)
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
