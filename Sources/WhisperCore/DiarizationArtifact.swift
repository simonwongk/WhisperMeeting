import Foundation

/// Which runtime and models produced a result. Recorded so a rerun after a model change is
/// recognizable, and so the scorecard can attribute a number to an exact stack (F218).
public struct DiarizationProducer: Codable, Sendable, Equatable {
    public let runtimeID: String
    public let runtimeVersion: String
    public let segmentationModelSHA256: String
    public let embeddingModelSHA256: String
    public let clusterThreshold: Double

    public init(runtimeID: String, runtimeVersion: String, segmentationModelSHA256: String,
                embeddingModelSHA256: String, clusterThreshold: Double) {
        self.runtimeID = runtimeID
        self.runtimeVersion = runtimeVersion
        self.segmentationModelSHA256 = segmentationModelSHA256
        self.embeddingModelSHA256 = embeddingModelSHA256
        self.clusterThreshold = clusterThreshold
    }
}

/// Identifies the audio a result belongs to. The hash is what makes a result *stale* rather than
/// wrong when the recording changes.
public struct DiarizationRecordingReference: Codable, Sendable, Equatable {
    public let relativePath: String
    public let sha256: String
    public let durationSeconds: TimeInterval

    public init(relativePath: String, sha256: String, durationSeconds: TimeInterval) {
        self.relativePath = relativePath
        self.sha256 = sha256
        self.durationSeconds = durationSeconds
    }
}

/// The versioned per-recording sidecar written to `Recordings/<meeting-uuid>/diarization.json`.
///
/// It deliberately holds no embedding, no voiceprint, no audio, no copied transcript text, and no
/// global cluster id — only anonymous intervals, the provenance needed to detect staleness, and the
/// aliases a person typed for this one meeting (F218).
public struct DiarizationArtifactV1: Codable, Sendable, Equatable {
    public static let currentSchemaVersion = 1
    public static let maximumAliasLength = 64

    public let schemaVersion: Int
    public let meetingID: UUID
    public let recording: DiarizationRecordingReference
    public let transcriptTimingFingerprint: String
    public let producer: DiarizationProducer
    public let createdAt: Date
    public let turns: [SpeakerTurn]
    /// Cluster id rendered in decimal → the alias a person typed. A `[Int: String]` would encode as
    /// a flat JSON array, which is unreadable in a file a person may inspect.
    public var aliases: [String: String]

    public init(
        schemaVersion: Int = DiarizationArtifactV1.currentSchemaVersion,
        meetingID: UUID,
        recording: DiarizationRecordingReference,
        transcriptTimingFingerprint: String,
        producer: DiarizationProducer,
        createdAt: Date,
        turns: [SpeakerTurn],
        aliases: [String: String]
    ) {
        self.schemaVersion = schemaVersion
        self.meetingID = meetingID
        self.recording = recording
        self.transcriptTimingFingerprint = transcriptTimingFingerprint
        self.producer = producer
        self.createdAt = createdAt
        self.turns = turns
        self.aliases = aliases
    }
}

public enum DiarizationArtifactError: Error, Sendable, Equatable {
    /// The bytes are not decodable as this artifact at all.
    case unreadable
    /// Written by a newer build. Preserve it; never rewrite it.
    case newerSchema(Int)
    /// Decodable but not trustworthy. The payload names the failed rule.
    case malformed(String)
}

extension JSONEncoder {
    /// Stable output so an unchanged artifact re-encodes byte-identically and never causes a
    /// spurious rewrite.
    public static var diarization: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }
}

extension JSONDecoder {
    public static var diarization: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}

/// Strict read/write for the sidecar. Both directions validate: a file we cannot fully trust
/// produces an error the caller turns into "Speaker labels unavailable; your transcript is safe",
/// never a partially-applied result — and never a file this codec would refuse to read back.
public enum DiarizationArtifactCodec {
    public static func encode(_ artifact: DiarizationArtifactV1) throws -> Data {
        // Symmetric with `decode` on purpose. Writing a sidecar this same codec then rejects turns a
        // failed analysis into a "corrupt file" the user has to interpret on some later launch, far
        // from the cause; failing here reports the thing that actually went wrong, and leaves the
        // previous sidecar in place.
        try validate(artifact)
        return try JSONEncoder.diarization.encode(artifact)
    }

    public static func decode(_ data: Data) throws -> DiarizationArtifactV1 {
        // The version is read before the whole value, so a newer schema is reported as such rather
        // than as corruption — the two get very different handling on disk.
        if let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let version = object["schemaVersion"] as? Int,
           version > DiarizationArtifactV1.currentSchemaVersion {
            throw DiarizationArtifactError.newerSchema(version)
        }
        guard let artifact = try? JSONDecoder.diarization.decode(DiarizationArtifactV1.self, from: data) else {
            throw DiarizationArtifactError.unreadable
        }
        try validate(artifact)
        return artifact
    }

    /// Every rule a trustworthy sidecar obeys, in one place so reading and writing can never drift
    /// apart. The file may have been written by anything — another build, an editor, a sync client —
    /// so nothing here is assumed from the in-memory type alone.
    private static func validate(_ artifact: DiarizationArtifactV1) throws {
        guard artifact.schemaVersion == DiarizationArtifactV1.currentSchemaVersion else {
            throw DiarizationArtifactError.malformed("schemaVersion")
        }
        guard artifact.recording.durationSeconds.isFinite, artifact.recording.durationSeconds >= 0 else {
            throw DiarizationArtifactError.malformed("duration")
        }
        do {
            _ = try SpeakerTurns.validate(artifact.turns, durationSeconds: artifact.recording.durationSeconds)
        } catch let error as SpeakerTurnValidationError {
            throw DiarizationArtifactError.malformed(String(describing: error))
        }
        for (key, alias) in artifact.aliases {
            guard let clusterID = Int(key), clusterID >= 0 else {
                throw DiarizationArtifactError.malformed("aliasKey")
            }
            // `.count` is grapheme clusters: one Character can be 40 KB of combining marks, so 64
            // of them is 2.5 MB and still passes a count-only bound — and the sidecar becomes the
            // text dump this bound exists to prevent. 4x admits any legitimate 64-character alias.
            guard alias.count <= DiarizationArtifactV1.maximumAliasLength,
                  alias.utf8.count <= 4 * DiarizationArtifactV1.maximumAliasLength else {
                throw DiarizationArtifactError.malformed("aliasLength")
            }
        }
        // The two digest fields are the only places voice data or transcript text could be smuggled
        // into a file whose whole promise is that it holds neither. A length bound in the CODEC is
        // what makes that promise enforceable; a bound asserted only in a test asserts the test's
        // own fixture. `TranscriptTimingFingerprint.compute` is always 16 ASCII hex digits, and the
        // hex+ASCII gate is what makes the character count a byte count as well.
        guard artifact.transcriptTimingFingerprint.count <= 32,
              artifact.transcriptTimingFingerprint.allSatisfy({ $0.isHexDigit && $0.isASCII }) else {
            throw DiarizationArtifactError.malformed("fingerprint")
        }
        // Bytes, not characters: one Character can be tens of kilobytes of combining marks, so a
        // grapheme-count bound is no bound at all on a file that may have been written by anything.
        for digest in [artifact.recording.sha256,
                       artifact.producer.segmentationModelSHA256,
                       artifact.producer.embeddingModelSHA256] where digest.utf8.count > 64 {
            throw DiarizationArtifactError.malformed("digest")
        }
    }
}
