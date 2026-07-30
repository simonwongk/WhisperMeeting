import Foundation

public struct RecoveredRecording: Sendable, Equatable {
    public enum Source: Sendable, Equatable {
        case existingCapture
        case importedRecording
        case rebuiltSourceTracks
    }

    public let recordingURL: URL
    public let duration: TimeInterval
    public let source: Source

    public var wasRebuiltFromRawTracks: Bool { source == .rebuiltSourceTracks }
}

public enum InterruptedRecordingRecovery {
    private static let systemFile = "system-audio.f32"
    private static let microphoneFile = "microphone-audio.f32"

    /// Removes a recording directory only when it contains no entries at all.
    @discardableResult
    public static func removeIfEmpty(in directory: URL) throws -> Bool {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: directory.path) else { return false }
        let contents = try fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        )
        guard contents.isEmpty else { return false }
        try fileManager.removeItem(at: directory)
        return true
    }

    public static func recover(
        in directory: URL,
        sampleRate: Double = 48_000
    ) throws -> RecoveredRecording? {
        let fileManager = FileManager.default
        for name in ["meeting.wav", "meeting-recovered.wav"] {
            let url = directory.appendingPathComponent(name)
            if let duration = wavDuration(at: url) {
                try writeRecoveryManifestIfNeeded(
                    in: directory,
                    sampleRate: sampleRate,
                    alignment: "captured-timeline"
                )
                return RecoveredRecording(
                    recordingURL: url,
                    duration: duration,
                    source: .existingCapture
                )
            }
        }

        // An imported recording keeps a single `recording.<ext>` file and no raw source tracks, so
        // it cannot be rebuilt from `.f32` data — recognize it directly instead of reporting that
        // there was not enough audio.
        if let imported = importedRecording(in: directory) {
            let duration = wavDuration(at: imported)
            return RecoveredRecording(
                recordingURL: imported,
                duration: duration ?? 0,
                source: .importedRecording
            )
        }

        let systemURL = directory.appendingPathComponent(systemFile)
        let microphoneURL = directory.appendingPathComponent(microphoneFile)
        let systemFrames = frameCount(at: systemURL)
        let microphoneFrames = frameCount(at: microphoneURL)
        let totalFrames = max(systemFrames, microphoneFrames)
        guard totalFrames > 0 else { return nil }

        let outputURL = directory.appendingPathComponent("meeting-recovered.wav")
        if fileManager.fileExists(atPath: outputURL.path) {
            try fileManager.removeItem(at: outputURL)
        }
        fileManager.createFile(atPath: outputURL.path, contents: nil)
        let output = try FileHandle(forWritingTo: outputURL)
        defer { try? output.close() }
        try ThrowingFileHandleIO.write(Data(repeating: 0, count: 44), to: output)

        let systemReader = try RawFloatReader(url: systemFrames > 0 ? systemURL : nil)
        let microphoneReader = try RawFloatReader(url: microphoneFrames > 0 ? microphoneURL : nil)
        let chunkSize: Int64 = 8_192
        var writtenFrames: Int64 = 0
        while writtenFrames < totalFrames {
            let count = Int(min(chunkSize, totalFrames - writtenFrames))
            let systemSamples = systemReader.read(frameCount: count)
            let microphoneSamples = microphoneReader.read(frameCount: count)
            var pcm = [Int16](repeating: 0, count: count)
            for index in pcm.indices {
                let systemSample = systemSamples[index]
                let microphoneSample = microphoneSamples[index]
                let bothActive = abs(systemSample) > 0.01 && abs(microphoneSample) > 0.01
                let mixed = bothActive
                    ? (systemSample + microphoneSample) * 0.5
                    : (systemSample + microphoneSample) * 0.95
                pcm[index] = Int16(max(-1, min(1, mixed)) * Float(Int16.max))
            }
            try pcm.withUnsafeBytes {
                try ThrowingFileHandleIO.write(Data($0), to: output)
            }
            writtenFrames += Int64(count)
        }

        let dataByteCount = UInt32(clamping: writtenFrames * 2)
        try output.seek(toOffset: 0)
        try ThrowingFileHandleIO.write(
            wavHeader(
                sampleRate: UInt32(sampleRate),
                dataByteCount: dataByteCount
            ),
            to: output
        )
        try writeRecoveryManifestIfNeeded(
            in: directory,
            sampleRate: sampleRate,
            alignment: "zero-aligned-after-interruption"
        )
        return RecoveredRecording(
            recordingURL: outputURL,
            duration: Double(writtenFrames) / sampleRate,
            source: .rebuiltSourceTracks
        )
    }

    /// Finds an imported recording file (`recording.<ext>`) in a folder that has no live-capture
    /// artifacts, so an imported meeting that fell out of the index can be re-indexed on launch.
    private static func importedRecording(in directory: URL) -> URL? {
        guard let candidate = importedRecordingCandidate(in: directory),
              let values = try? candidate.resourceValues(forKeys: [.fileSizeKey]),
              (values.fileSize ?? 0) > 0 else {
            return nil
        }
        return candidate
    }

    /// Returns the protected imported file even when it is empty or otherwise not recoverable. The
    /// app uses this to create one persistent "Needs attention" entry instead of repeating a
    /// startup warning while still preserving the file for inspection.
    public static func importedRecordingCandidate(in directory: URL) -> URL? {
        guard let contents = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey]
        ) else {
            return nil
        }
        return contents.first { url in
            guard url.deletingPathExtension().lastPathComponent == "recording",
                  !url.pathExtension.isEmpty,
                  let values = try? url.resourceValues(forKeys: [.isRegularFileKey]) else {
                return false
            }
            return values.isRegularFile == true
        }
    }

    private static func frameCount(at url: URL) -> Int64 {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = attributes[.size] as? NSNumber else {
            return 0
        }
        return size.int64Value / Int64(MemoryLayout<Float>.size)
    }

    private static func wavDuration(at url: URL) -> TimeInterval? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let fileSize = (attributes[.size] as? NSNumber)?.uint64Value else {
            return nil
        }
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let header = try? handle.read(upToCount: 44),
              header.count == 44,
              String(data: header[0..<4], encoding: .ascii) == "RIFF",
              String(data: header[8..<12], encoding: .ascii) == "WAVE" else {
            return nil
        }
        let channels = UInt32(littleEndianUInt16(in: header, at: 22))
        let sampleRate = littleEndianUInt32(in: header, at: 24)
        let bitsPerSample = UInt32(littleEndianUInt16(in: header, at: 34))
        let dataByteCount = littleEndianUInt32(in: header, at: 40)
        let bytesPerSecond = sampleRate * channels * bitsPerSample / 8
        let requiredFileSize = UInt64(44) + UInt64(dataByteCount)
        guard bytesPerSecond > 0,
              dataByteCount > 0,
              requiredFileSize <= fileSize else {
            return nil
        }
        return Double(dataByteCount) / Double(bytesPerSecond)
    }

    private static func littleEndianUInt16(in data: Data, at index: Int) -> UInt16 {
        UInt16(data[index]) | (UInt16(data[index + 1]) << 8)
    }

    private static func littleEndianUInt32(in data: Data, at index: Int) -> UInt32 {
        UInt32(data[index])
            | (UInt32(data[index + 1]) << 8)
            | (UInt32(data[index + 2]) << 16)
            | (UInt32(data[index + 3]) << 24)
    }

    private static func writeRecoveryManifestIfNeeded(
        in directory: URL,
        sampleRate: Double,
        alignment: String
    ) throws {
        let capturedManifest = directory.appendingPathComponent("source-tracks.json")
        let recoveredManifest = directory.appendingPathComponent("source-tracks.recovered.json")
        guard !FileManager.default.fileExists(atPath: capturedManifest.path),
              !FileManager.default.fileExists(atPath: recoveredManifest.path) else {
            return
        }
        let manifest = RecoveredSourceManifest(
            recoveryAlignment: alignment,
            systemAudio: .init(
                file: systemFile,
                format: "float32-little-endian",
                sampleRate: sampleRate,
                channels: 1,
                frameCount: frameCount(at: directory.appendingPathComponent(systemFile))
            ),
            microphoneAudio: .init(
                file: microphoneFile,
                format: "float32-little-endian",
                sampleRate: sampleRate,
                channels: 1,
                frameCount: frameCount(at: directory.appendingPathComponent(microphoneFile))
            )
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(manifest).write(to: recoveredManifest, options: .atomic)
    }

    private static func wavHeader(sampleRate: UInt32, dataByteCount: UInt32) -> Data {
        var data = Data()
        data.appendASCII("RIFF")
        data.appendLittleEndian(36 &+ dataByteCount)
        data.appendASCII("WAVE")
        data.appendASCII("fmt ")
        data.appendLittleEndian(UInt32(16))
        data.appendLittleEndian(UInt16(1))
        data.appendLittleEndian(UInt16(1))
        data.appendLittleEndian(sampleRate)
        data.appendLittleEndian(sampleRate * 2)
        data.appendLittleEndian(UInt16(2))
        data.appendLittleEndian(UInt16(16))
        data.appendASCII("data")
        data.appendLittleEndian(dataByteCount)
        return data
    }
}

private struct RecoveredSourceManifest: Codable {
    struct Track: Codable {
        let file: String
        let format: String
        let sampleRate: Double
        let channels: Int
        let frameCount: Int64
    }

    let recoveryAlignment: String
    let systemAudio: Track
    let microphoneAudio: Track
}

private final class RawFloatReader {
    private let handle: FileHandle?

    init(url: URL?) throws {
        handle = try url.map(FileHandle.init(forReadingFrom:))
    }

    deinit {
        try? handle?.close()
    }

    func read(frameCount: Int) -> [Float] {
        var result = [Float](repeating: 0, count: frameCount)
        guard let handle,
              let data = try? handle.read(upToCount: frameCount * MemoryLayout<Float>.size),
              !data.isEmpty else {
            return result
        }
        data.withUnsafeBytes { bytes in
            let source = bytes.bindMemory(to: Float.self)
            for index in 0..<min(source.count, result.count) {
                result[index] = source[index]
            }
        }
        return result
    }
}

private extension Data {
    mutating func appendASCII(_ value: String) {
        append(contentsOf: value.utf8)
    }

    mutating func appendLittleEndian<T: FixedWidthInteger>(_ value: T) {
        var value = value.littleEndian
        Swift.withUnsafeBytes(of: &value) { append(contentsOf: $0) }
    }
}
