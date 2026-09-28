import CryptoKit
import Foundation

/// What a backup generation contains, written inside it (F191 slice D).
///
/// Completeness rested entirely on an EMPTY marker file. That is a true statement about the run
/// that wrote it and says nothing about the bytes: after publication a generation can be truncated
/// by a failing disk, a sync client, a partial copy to another volume, or a user moving files, and
/// the marker still says complete.
///
/// This exists for slice E. A restore writes a generation over the user's live library, so it has
/// to be able to tell whether what it is about to copy is intact — and an empty file cannot answer
/// that.
///
/// **The ticket calls this "authenticated". It is not, and the difference is worth stating rather
/// than glossing: this provides INTEGRITY, not authenticity.** Authentication needs a secret, and
/// there is nowhere to keep one that an attacker able to rewrite the manifest could not also read —
/// the key would sit in the same folder as the thing it signs. Anyone who edits a generation can
/// recompute this digest. What it honestly detects is accidental corruption and truncation, which
/// is the failure that actually happens to a backup folder.
struct BackupManifest: Codable, Equatable, Sendable {
    /// One file in the generation. `size` is here specifically so truncation — the common
    /// corruption — is catchable without hashing gigabytes.
    struct Entry: Codable, Equatable, Sendable {
        let relativePath: String
        let size: Int64
        let sha256: String
    }

    static let fileName = ".backup-manifest.json"

    let generation: String
    let createdAtEpoch: Int
    let files: [Entry]
    /// SHA-256 over a canonical rendering of `files`, so a manifest that is itself truncated or
    /// edited without care is detectable before any file is read.
    let digest: String

    /// The digest of a file list. Canonical: sorted by path, one `path\tsize\thash` line each, so
    /// the value does not depend on JSON key order or on the order the files were walked.
    static func digest(of files: [Entry]) -> String {
        let canonical = files
            .sorted { $0.relativePath < $1.relativePath }
            .map { "\($0.relativePath)\t\($0.size)\t\($0.sha256)" }
            .joined(separator: "\n")
        return SHA256.hash(data: Data(canonical.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }

    init(generation: String, createdAtEpoch: Int, files: [Entry], digest: String) {
        self.generation = generation
        self.createdAtEpoch = createdAtEpoch
        self.files = files
        self.digest = digest
    }

    /// Builds a manifest whose digest matches its own contents.
    init(generation: String, createdAtEpoch: Int, files: [Entry]) {
        self.init(
            generation: generation,
            createdAtEpoch: createdAtEpoch,
            files: files,
            digest: Self.digest(of: files)
        )
    }

    func write(to generationDirectory: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(self).write(
            to: generationDirectory.appendingPathComponent(Self.fileName),
            options: .atomic
        )
    }

    /// The manifest a generation carries, or nil when it has none — which is the ordinary state of
    /// a generation written before this existed, not an error.
    ///
    /// Collapses two very different situations to the same `nil` (F557): "no file at all" (an
    /// older backup, nothing wrong) and "a file is there but truncated or otherwise undecodable"
    /// (this generation's own evidence is damaged). `verify` below must NOT make the same
    /// collapse — it needs `readOutcome` to tell those apart.
    static func read(in generationDirectory: URL) -> BackupManifest? {
        if case let .present(manifest) = readOutcome(in: generationDirectory) { return manifest }
        return nil
    }

    /// Whether `.backup-manifest.json` is absent, present and readable, or present and damaged
    /// (F557). The distinction `read` cannot make: an absent manifest means an older backup, which
    /// stays restorable through the "Restore Anyway" override; a damaged one means this
    /// generation's own integrity evidence cannot be trusted, which "Restore Anyway" must NOT
    /// override — those are different questions to ask the user and this is the tri-state that
    /// keeps them different all the way to `BackupRestorePlan`.
    enum ReadOutcome: Equatable {
        case absent
        case present(BackupManifest)
        /// The file exists but did not decode — truncated JSON, garbage bytes, or any other
        /// corruption. Distinct from `.absent`: this generation is not "from an earlier version",
        /// it is damaged.
        case corrupt
    }

    static func readOutcome(in generationDirectory: URL) -> ReadOutcome {
        let url = generationDirectory.appendingPathComponent(fileName)
        guard let data = try? Data(contentsOf: url) else { return .absent }
        guard let manifest = try? JSONDecoder().decode(BackupManifest.self, from: data) else {
            return .corrupt
        }
        return .present(manifest)
    }

    /// What a verification found.
    struct VerificationResult: Equatable, Sendable {
        /// Every file the manifest names is present and matches, to the depth that was checked.
        let isIntact: Bool
        /// There was no manifest to check against.
        ///
        /// Deliberately separate from `!isIntact`. "This generation is damaged" and "this
        /// generation cannot be verified" are different things to tell a user about to restore, and
        /// collapsing them would either refuse a perfectly good pre-slice-D backup or present an
        /// unchecked one as verified.
        let isUnverifiable: Bool
        let problems: [String]
    }

    /// Checks a generation against its manifest.
    ///
    /// `deep: false` compares presence and size only — no file is read. That catches a missing or
    /// truncated file, which is the common corruption, in milliseconds. It CANNOT catch a file
    /// rewritten to the same length; that limit is asserted by a test rather than left to be
    /// discovered, and it is why `deep` exists.
    ///
    /// `deep: true` re-hashes every file. Correct and slow — minutes on a library of recordings —
    /// so a dry run offers it rather than forcing it. Forcing it would make the dry run unusable;
    /// omitting it would let silent corruption through. The caller chooses and the result says
    /// which was done.
    static func verify(in generationDirectory: URL, deep: Bool) throws -> VerificationResult {
        let manifest: BackupManifest
        switch readOutcome(in: generationDirectory) {
        case .absent:
            // No manifest at all — an older backup, not a defect. Stays restorable through the
            // explicit "Restore Anyway" override (F557).
            return VerificationResult(
                isIntact: false,
                isUnverifiable: true,
                problems: ["This backup has no manifest, so its contents cannot be checked. It was made by an earlier version of WhisperMeet."]
            )
        case .corrupt:
            // A manifest file IS there but does not decode — truncated JSON from an interrupted
            // copy, garbage from a failing disk, or a sync client that wrote half of it (F557).
            // This is damage, not "an earlier version": `isUnverifiable: false` here is what keeps
            // "Restore Anyway" from appearing for it (`BackupRestorePlan.requiresExplicitOverride`
            // is exactly `isUnverifiable`), because there is no override that makes trusting a
            // provably-damaged file list correct.
            return VerificationResult(
                isIntact: false,
                isUnverifiable: false,
                problems: ["This backup's manifest is damaged and could not be read, so this generation's contents cannot be trusted. This backup may be corrupted or incomplete."]
            )
        case let .present(found):
            manifest = found
        }
        var problems: [String] = []
        if digest(of: manifest.files) != manifest.digest {
            problems.append("The backup manifest does not match its own contents, so the list of files in this backup cannot be trusted.")
        }
        let fileManager = FileManager.default
        for entry in manifest.files {
            let url = generationDirectory.appendingPathComponent(entry.relativePath)
            guard let attributes = try? fileManager.attributesOfItem(atPath: url.path),
                  let size = (attributes[.size] as? NSNumber)?.int64Value else {
                problems.append("Missing from this backup: \(entry.relativePath)")
                continue
            }
            if size != entry.size {
                problems.append("Wrong size in this backup: \(entry.relativePath)")
                continue
            }
            if deep, try BackupCoordinator.sha256(of: url) != entry.sha256 {
                problems.append("Contents changed since the backup was made: \(entry.relativePath)")
            }
        }
        return VerificationResult(
            isIntact: problems.isEmpty,
            isUnverifiable: false,
            problems: problems
        )
    }
}
