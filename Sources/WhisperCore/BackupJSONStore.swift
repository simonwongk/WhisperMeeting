import Foundation

public enum BackupJSONStoreError: LocalizedError, Sendable, Equatable {
    case noReadableCopy(primary: String, backup: String, quarantined: [String])
    /// Another writer committed a generation since this one read. The body being saved was copied
    /// aside under `preservedAs`, so neither update is lost (F190).
    case generationConflict(
        primary: String,
        expected: GenerationToken,
        found: GenerationToken,
        preservedAs: String
    )
    /// The same race, except the losing body could NOT be copied aside. Says so plainly rather than
    /// claiming a preservation that did not happen (the F187 honesty rule).
    case generationConflictNotPreserved(
        primary: String,
        expected: GenerationToken,
        found: GenerationToken,
        reason: String
    )

    public var errorDescription: String? {
        switch self {
        case let .generationConflict(primary, _, _, preservedAs):
            return "Another copy of WhisperMeet changed \(primary) first, so these changes were not applied to it. They were saved aside as \(preservedAs) and nothing was overwritten."
        case let .generationConflictNotPreserved(primary, _, _, reason):
            return "Another copy of WhisperMeet changed \(primary) first, so these changes were not applied — and they could not be copied aside either (\(reason)). Nothing on disk was changed, and nothing was overwritten."
        case let .noReadableCopy(primary, backup, quarantined):
            // Claim only the preservation that actually happened (F187). The prior wording promised
            // preservation unconditionally while nothing preserved anything.
            guard !quarantined.isEmpty else {
                return "Neither \(primary) nor its backup \(backup) could be read, and neither could be copied aside. Nothing was changed on disk."
            }
            return "Neither \(primary) nor its backup \(backup) could be read. The exact bytes were copied aside as \(quarantined.joined(separator: " and ")) and nothing was overwritten."
        }
    }
}

/// A value rebuilt from a partly-unreadable file, plus the records that had to be left behind.
public struct SalvagedValue<Value>: Sendable where Value: Sendable {
    public let value: Value
    public let parkedIdentifiers: [String]

    public init(value: Value, parkedIdentifiers: [String]) {
        self.value = value
        self.parkedIdentifiers = parkedIdentifiers
    }
}

/// Which files this process has already proved decodable, identified by their exact bytes on disk
/// (F211).
///
/// It remembers an *identity*, never the contents. An earlier draft cached the bytes too, which was
/// worse on both axes that matter here: it held two whole serialized generations per store forever
/// (~4.2 MB today, ~24 MB at a hundred meetings — the opposite of the memory behaviour this work is
/// for), and it let a foreign write that landed between `write` and `stat` poison the entry so that
/// *our* stale bytes would be served for the foreign file's identity. Re-reading is a few
/// milliseconds; the `Codable` decode of a deeply nested index is tens. Skipping only the decode
/// keeps nearly all the win and leaves the bytes always coming from disk.
///
/// A reference type on purpose: `BackupJSONStore` is a struct, and every copy of it addresses the
/// same files, so they must share one memory.
private final class DecodableFileMemory: @unchecked Sendable {
    /// Enough of `stat` to tell "still exactly the bytes I proved" from "somebody wrote here".
    /// `ctime` is included so an *in-place* overwrite is caught too: an atomic replace changes the
    /// inode, but `cp` onto the path or an editor saving in place does not, and on a
    /// coarse-mtime volume (SMB, exFAT) a same-size rewrite could otherwise land on the same
    /// second and read as unchanged.
    struct Identity: Equatable {
        let device: Int32
        let inode: UInt64
        let size: Int64
        let modifiedSeconds: Int
        let modifiedNanoseconds: Int
        let changedSeconds: Int
        let changedNanoseconds: Int

        init?(path: String) {
            var info = stat()
            guard stat(path, &info) == 0 else { return nil }
            device = info.st_dev
            inode = info.st_ino
            size = Int64(info.st_size)
            modifiedSeconds = info.st_mtimespec.tv_sec
            modifiedNanoseconds = info.st_mtimespec.tv_nsec
            changedSeconds = info.st_ctimespec.tv_sec
            changedNanoseconds = info.st_ctimespec.tv_nsec
        }
    }

    private let lock = NSLock()
    private var proven: [String: Identity] = [:]

    /// Records that the file at `path` currently holds `byteCount` decodable bytes.
    ///
    /// Takes the identity twice and keeps it only if both agree, and only if the size matches what
    /// was written. A foreign writer that slipped in between the write and the check would move one
    /// of them, and the entry is dropped rather than attributed to bytes we never verified.
    func remember(path: String, byteCount: Int) {
        guard let first = Identity(path: path),
              let second = Identity(path: path),
              first == second,
              first.size == Int64(byteCount)
        else {
            forget(path)
            return
        }
        lock.lock()
        proven[path] = first
        lock.unlock()
    }

    /// Whether the file is still, byte for byte, one this process already decoded successfully.
    func isProvenDecodable(path: String) -> Bool {
        guard let current = Identity(path: path) else { return false }
        lock.lock()
        defer { lock.unlock() }
        return proven[path] == current
    }

    func forget(_ path: String) {
        lock.lock()
        proven.removeValue(forKey: path)
        lock.unlock()
    }
}

public struct BackupJSONStore<Value: Codable & Sendable> {
    public struct LoadResult {
        public let value: Value
        public let health: PersistedStoreHealth
        /// The generation these bytes are. Thread it back into `save(expecting:)` (F190).
        public let token: GenerationToken?
        /// What the load observed and could not silently fix. Diagnostics through return values,
        /// never a log line — `WhisperCore` has no logger and this is why that is fine.
        public let repairs: [StoreRepair]

        public init(
            value: Value,
            health: PersistedStoreHealth,
            token: GenerationToken? = nil,
            repairs: [StoreRepair] = []
        ) {
            self.value = value
            self.health = health
            self.token = token
            self.repairs = repairs
        }
    }

    /// What a load or save observed and worked around, rather than failed on (F190).
    public enum StoreRepair: Sendable, Equatable {
        /// Our own crash between install and commit.
        case adoptedUnrecordedPrimary(fingerprint: String)
        /// An old bundle or a hand-restore wrote the legacy pair.
        case adoptedForeignRotation(fingerprint: String)
        case ledgerUnreadable
        case ledgerNewerFormat(Int)
        case historyUnavailable(reason: String)
    }

    /// What actually happened during one save (F190).
    public struct SaveOutcome: Sendable, Equatable {
        public let token: GenerationToken
        public let parent: GenerationToken?
        /// What actually committed, in order.
        public let phases: [StoreWritePhase]
        public let retainedName: String?
        public let prunedNames: [String]
        /// True when the BODY is durable but the ledger commit did not land. **Not an error.**
        public let ledgerLagged: Bool
        public let adoptedUnrecordedPrimary: Bool
        public let adoptedForeignRotation: Bool
        public let quarantined: [String]
        public let conflictBranchBacklog: Int
    }

    private let primaryURL: URL
    private let backupURL: URL
    private let fileManager: FileManager
    /// Every filesystem effect in the write path goes through this, so a test can fail exactly one
    /// (F190). `fileManager` survives alongside it only for the `fileExists` probes in `load()`;
    /// it is not an IO seam and never was.
    private let io: StoreFileIO
    private let writer: String
    private let retention: RetentionPolicy
    /// Top-level element count, for the retention high-water pin and the recovery list. The value is
    /// already in memory (`{ $0.count }` for the array stores), so this is free — never a
    /// `JSONSerialization` re-parse of the payload.
    private let recordCount: (@Sendable (Value) -> Int?)?

    private var ledgerURL: URL {
        let stem = primaryURL.deletingPathExtension().lastPathComponent
        return primaryURL.deletingLastPathComponent().appendingPathComponent("\(stem).ledger.json")
    }
    private var history: StoreHistory { StoreHistory(primaryURL: primaryURL, io: io) }
    /// Optional element-wise recovery so one bad record costs one record, not the whole library (F187).
    private let salvage: (@Sendable (Data) -> SalvagedValue<Value>?)?
    private let decodableMemory = DecodableFileMemory()

    public init(
        primaryURL: URL,
        backupURL: URL,
        fileManager: FileManager = .default,
        io: StoreFileIO = .live,
        writer: String = StoreWriterNonce.forThisProcess,
        retention: RetentionPolicy = .init(),
        recordCount: (@Sendable (Value) -> Int?)? = nil,
        salvage: (@Sendable (Data) -> SalvagedValue<Value>?)? = nil
    ) {
        self.primaryURL = primaryURL
        self.backupURL = backupURL
        self.fileManager = fileManager
        self.io = io
        self.writer = writer
        self.retention = retention
        self.recordCount = recordCount
        self.salvage = salvage
    }

    public func load() throws -> LoadResult? {
        let primaryExists = fileManager.fileExists(atPath: primaryURL.path)
        let backupExists = fileManager.fileExists(atPath: backupURL.path)

        let ledger = StoreLedger.read(at: ledgerURL, using: io)
        var repairs: [StoreRepair] = []
        if ledger == nil, io.fileExists(ledgerURL) { repairs.append(.ledgerUnreadable) }

        if primaryExists,
           let data = try? io.read(primaryURL, .readPrimary),
           let value = try? decoder.decode(Value.self, from: data) {
            return LoadResult(
                value: value,
                health: .complete,
                token: token(for: data, ledger: ledger),
                repairs: repairs
            )
        }
        if backupExists,
           let data = try? io.read(backupURL, .readBackup),
           let value = try? decoder.decode(Value.self, from: data) {
            // Deliberately NO token. These bytes are the backup, not the primary, so they are not
            // the generation a `save(expecting:)` would be swapping against — handing one back
            // would let a degraded load arm a checked write over a primary nobody read.
            return LoadResult(value: value, health: .recoveredFromBackup, repairs: repairs)
        }
        guard primaryExists || backupExists else { return nil }

        // Preserve first, then try to rescue individual records from the preserved bytes.
        var quarantined: [String] = []
        if let name = try StoreQuarantine.preserve(fileAt: primaryURL, using: io) {
            quarantined.append(name)
        }
        if let name = try StoreQuarantine.preserve(fileAt: backupURL, using: io) {
            quarantined.append(name)
        }

        if let salvage {
            for (url, phase) in [(primaryURL, StoreWritePhase.readPrimary),
                                 (backupURL, StoreWritePhase.readBackup)] {
                guard let data = try? io.read(url, phase), let rescued = salvage(data) else { continue }
                return LoadResult(
                    value: rescued.value,
                    health: .partiallySalvaged(parkedIdentifiers: rescued.parkedIdentifiers)
                )
            }
        }

        throw BackupJSONStoreError.noReadableCopy(
            primary: primaryURL.lastPathComponent,
            backup: backupURL.lastPathComponent,
            quarantined: quarantined
        )
    }

    /// Returns normally **if and only if** `value` is durable at `primaryURL` (F190).
    ///
    /// Every existing call site is `try store.save(x); errorMessage = nil`, so anything weaker than
    /// that postcondition silently reports success for changes that are not on disk. Its mirror is
    /// just as load-bearing: the *ledger* commit runs after the body is installed and therefore
    /// never throws — reporting "changes could not be saved" for changes that are saved could
    /// provoke a caller rollback of durable data.
    ///
    /// `expecting: nil` means unchecked — today's last-writer-wins — and is the compatibility
    /// default every pre-F190 caller relies on. It is an accepted hole, not an oversight: a
    /// production caller should thread the token from `load()` or the previous `SaveOutcome`.
    @discardableResult
    public func save(
        _ value: Value,
        expecting: GenerationToken? = nil,
        now: Int = Int(Date().timeIntervalSince1970)
    ) throws -> SaveOutcome {
        var phases: [StoreWritePhase] = []
        var repairs: [StoreRepair] = []

        // 1. prepareDirectory — byte-identical to the pre-F190 first line, and a no-op when the
        //    directory exists. `<stem>.history/` is deliberately NOT created here:
        //    `saveRefusesWhenQuarantineFails` runs against a 0o500 directory and must still fail at
        //    the quarantine, and a directory create would throw EACCES first.
        try io.createDirectory(primaryURL.deletingLastPathComponent(), .prepareDirectory)
        phases.append(.prepareDirectory)
        sweepOurOwnStaleTemporaries()

        // 2. encode — no IO, so an encoding failure changes nothing on disk.
        let newData = try encoder.encode(value)
        let newFingerprint = io.fingerprint(newData)

        // 3. classify — read-only, and read each file AT MOST ONCE.
        //
        // The primary is read exactly once and the bytes serve both jobs: the decode proof and the
        // compare-and-swap's fingerprint. Reading it twice cost a second 2.6 MB read per save.
        // It is ALWAYS read — only the `Codable` decode is skipped on an F211 memory hit — because
        // the fingerprint is the CAS's input, and a CAS decided from a cached fingerprint would
        // promote that memory from an optimisation into the sole authority on whether to clobber
        // another writer.
        let primaryBytes = try? io.read(primaryURL, .readPrimary)
        let existingPrimary = primaryBytes.flatMap { bytes -> Data? in
            if decodableMemory.isProvenDecodable(path: primaryURL.path) { return bytes }
            return (try? decoder.decode(Value.self, from: bytes)) == nil ? nil : bytes
        }
        if existingPrimary != nil {
            decodableMemory.remember(path: primaryURL.path, byteCount: primaryBytes?.count ?? 0)
        }
        let primaryFingerprint = primaryBytes.map { io.fingerprint($0) }

        // The backup is NOT read when this process has already proved it decodable. Its *bytes* are
        // never used any more — the rotation is a clone of the primary — so only the *proof* is
        // needed, and the identity tuple is exactly that proof. A genuine extension of F211, and it
        // is safe for the same reason: a foreign write moves the inode or the ctime and misses.
        let backupDecodable: Bool
        if decodableMemory.isProvenDecodable(path: backupURL.path) {
            backupDecodable = true
        } else {
            backupDecodable = readableData(at: backupURL) != nil
        }
        let ledgerIdentityBeforeWrite = io.identity(ledgerURL)
        let ledger = StoreLedger.read(at: ledgerURL, using: io)
        if ledger == nil, io.fileExists(ledgerURL) { repairs.append(.ledgerUnreadable) }

        // 4. quarantine — F187, verbatim. Anything that exists and does not decode is copied aside
        //    before anything can replace it, and a preserve failure throws with nothing written.
        //    The ledger is derived metadata: discarded and rebuilt, never quarantined.
        var quarantined: [String] = []
        if existingPrimary == nil,
           let name = try StoreQuarantine.preserve(fileAt: primaryURL, using: io) {
            quarantined.append(name)
        }
        if !backupDecodable,
           let name = try StoreQuarantine.preserve(fileAt: backupURL, using: io) {
            quarantined.append(name)
        }
        if !quarantined.isEmpty { phases.append(.quarantine) }

        // 5. compareAndSwap — read-only except the conflict branch. First matching rule wins.
        let decision = try compareAndSwap(
            expecting: expecting,
            primaryDecodable: existingPrimary != nil,
            primaryFingerprint: primaryFingerprint,
            primaryByteCount: primaryBytes?.count,
            ledger: ledger,
            newData: newData,
            newFingerprint: newFingerprint,
            phases: &phases
        )
        if decision.adoptedUnrecordedPrimary, let fingerprint = primaryFingerprint {
            repairs.append(.adoptedUnrecordedPrimary(fingerprint: fingerprint))
        }
        if decision.adoptedForeignRotation, let fingerprint = primaryFingerprint {
            repairs.append(.adoptedForeignRotation(fingerprint: fingerprint))
        }
        let sequence = (decision.parent?.sequence ?? ledger?.current.sequence ?? 0) + 1

        // 6. stage — the ONLY payload-sized write in the whole save (there were two before). Same
        //    directory, therefore same volume, therefore the later rename is atomic.
        let nonce = String(format: "%08x", UInt32.random(in: .min ... .max))
        let stem = primaryURL.deletingPathExtension().lastPathComponent
        let stagingURL = primaryURL.deletingLastPathComponent()
            .appendingPathComponent("\(stem).json.stage-\(nonce)")
        try io.writeAtomically(newData, stagingURL, .stage)
        phases.append(.stage)

        // 7. retain — also the transaction's INTENT RECORD: it exists before the primary changes, so
        //    a crash between install and commit leaves a primary whose fingerprint is provably an
        //    F190 writer's body (CAS rule 7). One artifact, two jobs — no separate journal to keep
        //    consistent. Never fatal.
        var historyAvailable = true
        var retainedName: String?
        do {
            retainedName = try history.record(
                stagedAt: stagingURL, generation: sequence, fingerprint: newFingerprint
            )
            if retainedName == nil {
                historyAvailable = false
                repairs.append(.historyUnavailable(reason: "the history directory could not be used"))
            } else {
                phases.append(.retain)
            }
        } catch {
            historyAvailable = false
            repairs.append(.historyUnavailable(reason: error.localizedDescription))
        }

        // 8. rotateBackup — reproduces the pre-F190 `existingPrimary ?? existingBackup ?? newData`
        //    exactly, with clones instead of byte writes. FATAL on failure, matching today: a failed
        //    rotation aborts before the primary changes, so the previous generation always survives.
        decodableMemory.forget(backupURL.path)
        if let outgoing = existingPrimary {
            try rotate(from: primaryURL, byteCount: outgoing.count, nonce: nonce)
            phases.append(.rotateBackup)
        } else if !backupDecodable {
            try rotate(from: stagingURL, byteCount: newData.count, nonce: nonce)
            phases.append(.rotateBackup)
        }
        // else: the outgoing primary is undecodable and the backup is decodable — leave the backup
        // exactly as it is. It is the only readable copy of the previous generation.

        // 9. install — DURABILITY POINT A. Nothing after this can lose the user's value, and nothing
        //    touches the primary's inode afterwards (in particular no `link(2)`), so its ctime stays
        //    put and F211's memory stays warm for the next save.
        decodableMemory.forget(primaryURL.path)
        try io.rename(stagingURL, primaryURL, .install)
        decodableMemory.remember(path: primaryURL.path, byteCount: newData.count)
        phases.append(.install)

        let token = GenerationToken(
            sequence: sequence,
            fingerprint: newFingerprint,
            byteCount: newData.count,
            writer: writer,
            verified: true
        )

        // 10. commit — the ledger's atomic rename is the commit point. NEVER fatal.
        let ledgerLagged = commitLedger(
            token: token,
            parent: decision.parent,
            previousLedger: ledger,
            identityBeforeWrite: ledgerIdentityBeforeWrite,
            retainedName: retainedName,
            historyAvailable: historyAvailable,
            recordCount: recordCount?(value),
            now: now,
            phases: &phases
        )

        // 11. prune — best-effort, never throws, never a `conflict-` entry. Reuses the fingerprints
        //     already computed rather than re-reading anything.
        let pruned = pruneHistory(
            ledger: StoreLedger.read(at: ledgerURL, using: io),
            liveFingerprints: [newFingerprint, primaryFingerprint].compactMap { $0 },
            now: now
        )
        if !pruned.isEmpty { phases.append(.prune) }

        return SaveOutcome(
            token: token,
            parent: decision.parent,
            phases: phases,
            retainedName: retainedName,
            prunedNames: pruned,
            ledgerLagged: ledgerLagged,
            adoptedUnrecordedPrimary: decision.adoptedUnrecordedPrimary,
            adoptedForeignRotation: decision.adoptedForeignRotation,
            quarantined: quarantined,
            conflictBranchBacklog: history.conflictBranchCount()
        )
    }

    private struct CASDecision {
        let parent: GenerationToken?
        var adoptedUnrecordedPrimary = false
        var adoptedForeignRotation = false
    }

    /// The compare-and-swap. Content only — never sequence numbers, so a writer that resets or
    /// forges its numbering cannot thereby claim to have read bytes it never read.
    ///
    /// Rule order matters. Rule 6 fires before 7 and 8 so a genuine F190 sibling that *did* commit
    /// is caught as a conflict rather than adopted.
    private func compareAndSwap(
        expecting: GenerationToken?,
        primaryDecodable: Bool,
        primaryFingerprint: String?,
        primaryByteCount: Int?,
        ledger: StoreLedger?,
        newData: Data,
        newFingerprint: String,
        phases: inout [StoreWritePhase]
    ) throws -> CASDecision {
        // 1 — unchecked: the compatibility default.
        guard let expecting else { return CASDecision(parent: nil) }
        // 2 — nothing there to conflict with.
        guard let primaryFingerprint, let primaryByteCount else { return CASDecision(parent: nil) }
        // 3 — undecodable and already quarantined: the F187 ladder, not a race.
        guard primaryDecodable else { return CASDecision(parent: nil) }
        // 4 — the common case: the primary is exactly what the caller read.
        if expecting.matches(fingerprint: primaryFingerprint, byteCount: primaryByteCount) {
            return CASDecision(parent: expecting)
        }

        let adopted = GenerationToken(
            sequence: ledger?.current.sequence ?? 0,
            fingerprint: primaryFingerprint,
            byteCount: primaryByteCount,
            writer: writer,
            verified: false
        )
        // 5 — no ledger at all: a pre-F190 library, an old bundle's write, or a hand-restore.
        guard let ledger else { return CASDecision(parent: adopted) }
        // 6 — an F190 sibling committed. A real race.
        if ledger.current.fingerprint != primaryFingerprint {
            // 7 — an F190 body installed but not yet recorded: our own crash between install and
            //     commit, or a sibling's lagging commit. The history entry is the proof.
            let names = (try? io.contentsOfDirectory(history.directoryURL, .listHistory)) ?? []
            if names.contains(where: { StoreHistory.parse($0)?.fingerprint == primaryFingerprint }) {
                var decision = CASDecision(parent: adopted)
                decision.adoptedUnrecordedPrimary = true
                return decision
            }
            // 8 — the legacy rotation signature: a non-F190 writer rotated our current generation
            //     into the backup and installed its own, which proves the foreign primary descends
            //     from us.
            //
            // The backup is read HERE and nowhere else. Rules 1-7 cover every ordinary save, so
            // fingerprinting the backup eagerly in `classify` bought nothing and cost a 2.6 MB read
            // plus a fingerprint on every keystroke-debounced write.
            let backupFingerprint = (try? io.read(backupURL, .readBackup)).map { io.fingerprint($0) }
            if let backupFingerprint, backupFingerprint == ledger.current.fingerprint {
                var decision = CASDecision(parent: adopted)
                decision.adoptedForeignRotation = true
                return decision
            }
        }

        // 6 and 9 — CONFLICT. Fails closed: the losing body is copied aside, or the error says
        // plainly that it was not. Either way nothing else on disk changed, so the winner's
        // generation is untouched.
        let found = GenerationToken(
            sequence: ledger.current.sequence,
            fingerprint: primaryFingerprint,
            byteCount: primaryByteCount,
            writer: ledger.current.writer,
            verified: true
        )
        let name = "conflict-\(String(format: "%09llu", expecting.sequence + 1))-\(writer)-\(newFingerprint).json"
        do {
            try io.createDirectory(history.directoryURL, .createHistoryDirectory)
            try io.writeAtomically(newData, history.directoryURL.appendingPathComponent(name),
                                   .preserveConflictBranch)
            phases.append(.preserveConflictBranch)
        } catch {
            throw BackupJSONStoreError.generationConflictNotPreserved(
                primary: primaryURL.lastPathComponent,
                expected: expecting,
                found: found,
                reason: error.localizedDescription
            )
        }
        throw BackupJSONStoreError.generationConflict(
            primary: primaryURL.lastPathComponent,
            expected: expecting,
            found: found,
            preservedAs: name
        )
    }

    /// Clones `source` to a sibling temp, then renames it onto the backup. A clone rather than a
    /// byte write, so the 2.1 MB payload is written once per save instead of twice.
    private func rotate(from source: URL, byteCount: Int, nonce: String) throws {
        let temporary = backupURL.deletingLastPathComponent()
            .appendingPathComponent("\(backupURL.lastPathComponent).rotate-\(nonce)")
        // No pre-remove: the name carries a fresh nonce per save, so it cannot already exist, and
        // design §3 specifies copy-then-rename with nothing else. An extra seam call here also made
        // `.rotateBackup` occur a variable number of times per save, which broke occurrence-targeted
        // fault injection for no benefit.
        try io.copyItem(source, temporary, .rotateBackup)
        try io.rename(temporary, backupURL, .rotateBackup)
        decodableMemory.remember(path: backupURL.path, byteCount: byteCount)
    }

    /// Writes the new ledger unless someone else moved it since `classify`. Returns whether the
    /// commit lagged. **Never throws** — the body is already durable.
    private func commitLedger(
        token: GenerationToken,
        parent: GenerationToken?,
        previousLedger: StoreLedger?,
        identityBeforeWrite: StoreFileIdentity?,
        retainedName: String?,
        historyAvailable: Bool,
        recordCount: Int?,
        now: Int,
        phases: inout [StoreWritePhase]
    ) -> Bool {
        // Someone else rewrote the ledger since we read it, so ours is already stale. Do not
        // overwrite: a lagged ledger costs one generation of lineage certainty, and the history
        // entry still identifies this generation by content.
        guard io.identity(ledgerURL) == identityBeforeWrite else { return true }

        let record = StoreLedger.Record(
            sequence: token.sequence,
            fingerprint: token.fingerprint,
            byteCount: token.byteCount,
            writer: token.writer,
            wroteAtEpochSeconds: now,
            parentFingerprint: parent?.fingerprint,
            recordCount: recordCount,
            historyName: retainedName
        )
        let outgoing = previousLedger?.current
        var entries = [record]
        entries.append(contentsOf: (previousLedger?.history ?? []).filter {
            $0.fingerprint != record.fingerprint
        })
        let ledger = StoreLedger(
            current: record,
            previous: outgoing,
            history: Array(entries.prefix(64)),
            historyAvailable: historyAvailable,
            writerRealm: "none"
        )
        guard let outcome = try? StoreLedger.write(ledger, to: ledgerURL, using: io),
              outcome == .written
        else { return true }
        phases.append(.commit)
        return false
    }

    private func pruneHistory(
        ledger: StoreLedger?,
        liveFingerprints: [String],
        now: Int
    ) -> [String] {
        var counts: [String: Int] = [:]
        var times: [String: Int] = [:]
        for record in ledger?.history ?? [] {
            guard let name = record.historyName else { continue }
            if let count = record.recordCount { counts[name] = count }
            times[name] = record.wroteAtEpochSeconds
        }
        return history.prune(
            policy: retention, now: now, recordCounts: counts, writtenAt: times,
            liveFingerprints: liveFingerprints
        )
    }

    /// Sweeps only OUR OWN stale temporaries — Foundation cleans up its own `.atomic` temps, and
    /// deleting anything else in the library directory is not this type's business.
    private func sweepOurOwnStaleTemporaries() {
        let stem = primaryURL.deletingPathExtension().lastPathComponent
        let directory = primaryURL.deletingLastPathComponent()
        let markers = ["\(stem).json.stage-", "\(backupURL.lastPathComponent).rotate-"]
        for name in (try? io.contentsOfDirectory(directory, .prepareDirectory)) ?? [] {
            guard markers.contains(where: { name.hasPrefix($0) }) else { continue }
            try? io.remove(directory.appendingPathComponent(name), .prepareDirectory)
        }
    }

    /// Every retained generation on disk, newest first.
    public func retainedGenerations() throws -> [RetainedGeneration] {
        history.retained(ledger: StoreLedger.read(at: ledgerURL, using: io))
    }

    /// Conflict branches awaiting a decision. They are never pruned automatically.
    public func conflictBranches() throws -> [RetainedGeneration] {
        let names = (try? io.contentsOfDirectory(history.directoryURL, .listHistory)) ?? []
        return names.filter { $0.hasPrefix("conflict-") }.compactMap { name in
            guard let bytes = try? io.read(
                history.directoryURL.appendingPathComponent(name), .readHistoryEntry
            ) else { return nil }
            return RetainedGeneration(
                name: name, sequence: 0, fingerprint: io.fingerprint(bytes),
                byteCount: bytes.count, wroteAtEpochSeconds: nil, recordCount: nil,
                bytesMatchName: true
            )
        }
    }

    /// The generation the primary's bytes are.
    ///
    /// `verified` is false whenever no ledger record describes these exact bytes — a pre-F190
    /// library, an old bundle's write, a hand-restore. Such a generation is *fully writable*; the
    /// flag only records that its lineage is unknown, which is what Invariant L requires.
    private func token(for data: Data, ledger: StoreLedger?) -> GenerationToken {
        let fingerprint = io.fingerprint(data)
        let recorded = ledger?.current
        let verified = recorded?.fingerprint == fingerprint && recorded?.byteCount == data.count
        return GenerationToken(
            sequence: verified ? (recorded?.sequence ?? 0) : (recorded?.sequence ?? 0),
            fingerprint: fingerprint,
            byteCount: data.count,
            writer: verified ? (recorded?.writer ?? writer) : writer,
            verified: verified
        )
    }

    /// `readableData`, minus the *decode* when this file is still exactly one this process already
    /// decoded successfully (F211). The bytes always come from disk; only the proof is reused.
    ///
    /// The identity check is the whole safety argument: an atomic replace changes the inode and an
    /// in-place rewrite changes ctime, so any foreign write misses the memory and takes the full
    /// decode — which is what keeps F187's preserve-before-overwrite rule exactly as strict as it
    /// was. Worth it because the skipped work is a `Codable` decode of the entire index on the main
    /// actor, and it grows with the library: 61 ms per save at 2.6 MB, 352 ms at a hundred meetings.
    private func knownOrReadableData(at url: URL) -> Data? {
        guard let data = try? io.read(url, url == primaryURL ? .readPrimary : .readBackup) else {
            return nil
        }
        if decodableMemory.isProvenDecodable(path: url.path) { return data }
        guard (try? decoder.decode(Value.self, from: data)) != nil else { return nil }
        decodableMemory.remember(path: url.path, byteCount: data.count)
        return data
    }

    private func readableData(at url: URL) -> Data? {
        guard let data = try? io.read(url, url == primaryURL ? .readPrimary : .readBackup),
              (try? decoder.decode(Value.self, from: data)) != nil else {
            return nil
        }
        return data
    }

    private var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    private var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
