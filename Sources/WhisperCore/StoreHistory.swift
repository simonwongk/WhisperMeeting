import Foundation

public enum StoreHistoryError: LocalizedError, Sendable, Equatable {
    /// The file's bytes no longer fingerprint to the value in its own name.
    case fingerprintMismatch(String)

    public var errorDescription: String? {
        switch self {
        case .fingerprintMismatch(let name):
            return "The saved copy \"\(name)\" does not match its own checksum, so it was not restored."
        }
    }
}

/// How much history to keep, counted in content and time — never in saves (F190).
///
/// **Never "the newest K saves".** `AppModel.performStartupRecovery` calls `store.upsert` once per
/// orphan folder and `upsert` persists, so the 2026-08-14 loop wrote *ten* generations inside one
/// launch. `recoverInterruptedTranscriptions` does the same per `.processing` meeting, and ordinary
/// debounced transcript editing does it in under a minute. A 5-deep save window would have been
/// emptied before the user ever opened the recovery list — destroying history in exactly the
/// incident shape this ticket exists for.
///
/// Under this policy those ten stub saves all have `recordCount == 0`, so the high-water rule pins
/// the seventeen-meeting generation indefinitely while the age anchors keep the hourly, daily and
/// weekly positions.
public struct RetentionPolicy: Sendable, Equatable {
    public var recentCount: Int
    /// Keep the newest generation older than each of these ages, in seconds.
    public var ageAnchors: [Int]
    public var pinHighWaterRecordCount: Bool
    public var byteBudget: Int
    public var maxConflictBranches: Int

    public init(
        recentCount: Int = 3,
        ageAnchors: [Int] = [3_600, 86_400, 604_800],
        pinHighWaterRecordCount: Bool = true,
        byteBudget: Int = 256 * 1024 * 1024,
        maxConflictBranches: Int = 20
    ) {
        self.recentCount = recentCount
        self.ageAnchors = ageAnchors
        self.pinHighWaterRecordCount = pinHighWaterRecordCount
        self.byteBudget = byteBudget
        self.maxConflictBranches = maxConflictBranches
    }

    public static let dictationLog = RetentionPolicy(recentCount: 2, ageAnchors: [86_400])
}

/// One generation on disk, as the directory scan sees it.
public struct RetainedGeneration: Sendable, Equatable {
    public let name: String
    public let sequence: UInt64
    public let fingerprint: String
    public let byteCount: Int
    public let wroteAtEpochSeconds: Int?
    public let recordCount: Int?
    /// False when the file's bytes no longer fingerprint to the value in its own name. Such an entry
    /// is reported rather than hidden, and `data(of:)` refuses it.
    public let bytesMatchName: Bool
}

/// Physically independent copies of past generations, beside the live store (F190).
///
/// `<stem>.history/g-<sequence padded to 9>-<fingerprint>.json`, copied from the staging file before
/// the primary is installed. **Content-addressed**, so the name alone identifies the bytes without
/// any ledger record — which is what makes a lagged or lost ledger update harmless: a directory scan
/// recovers everything.
///
/// **`link(2)` is never used, anywhere.** A hard link makes the retained generation an *alias* of the
/// live file, so `cp good.json meetings.json`, a shell redirect, `rsync --inplace` or any non-atomic
/// `Data.write(to:)` rewrites the archive through the live name — the archive destroyed by the exact
/// operation it exists to survive, and `docs/RECOVERY.md` tells users to use `cp`. `link` also bumps
/// the source's `st_ctime`, which is in F211's identity tuple, silently voiding the decode-skip on
/// every later save; and it can fail outright with `EPERM`/`ENOTSUP` on exFAT/SMB, which would turn a
/// retention step into a terminal save failure.
///
/// `FileManager.copyItem` issues `clonefile(2)` on APFS: distinct inode, copy-on-write, measured
/// 0.371 ms for 2.1 MB. On a volume without clone support it degrades to a real byte copy — slower,
/// never broken.
public struct StoreHistory: Sendable {
    public let directoryURL: URL
    private let io: StoreFileIO

    public init(primaryURL: URL, io: StoreFileIO = .live) {
        let stem = primaryURL.deletingPathExtension().lastPathComponent
        self.directoryURL = primaryURL.deletingLastPathComponent()
            .appendingPathComponent("\(stem).history", isDirectory: true)
        self.io = io
    }

    /// Copies the staged payload in as a new generation and returns its name, or nil when history is
    /// unavailable.
    ///
    /// Retention failure is **never fatal**: a volume that refuses the directory, or a plain file
    /// squatting the name, costs the archive and nothing else. Returning nil rather than throwing is
    /// how that stays true at every call site.
    @discardableResult
    public func record(
        stagedAt stagedURL: URL,
        generation: UInt64,
        fingerprint: String
    ) throws -> String? {
        // A plain FILE at `<stem>.history` must not become a terminal save failure, and
        // `createDirectory` would throw on it — so ask first.
        if let isDirectory = io.isDirectory(directoryURL), !isDirectory { return nil }
        do {
            try io.createDirectory(directoryURL, .createHistoryDirectory)
        } catch {
            return nil
        }
        let name = Self.name(generation: generation, fingerprint: fingerprint)
        do {
            try io.copyItem(stagedURL, directoryURL.appendingPathComponent(name), .retain)
        } catch StoreIOError.destinationExists {
            // Content-addressed: the same bytes under the same name are already archived. That is
            // success, not a collision — once the file really does hold those bytes.
            heal(from: stagedURL, to: directoryURL.appendingPathComponent(name))
            return name
        } catch {
            return nil
        }
        return name
    }

    /// Repairs a destination that already exists but is the wrong size.
    ///
    /// `copyItem` writes the destination path directly — no temp, no rename — so on a volume
    /// without clone support a crash mid-copy leaves a TRUNCATED file under a content-addressed
    /// name that promises the whole payload. Without this, every later retain of that generation
    /// catches `destinationExists`, reports success, and the damage is permanent (F237).
    ///
    /// Size only. Re-fingerprinting every archived generation is exactly the per-save cost F211
    /// removed, and same-size-different-bytes still fails safe: `retained()` flags it and
    /// `data(of:)` refuses it. The repair itself goes through a temp name and a rename, so this
    /// copy cannot leave the same wreck the last one did.
    private func heal(from stagedURL: URL, to destination: URL) {
        guard let staged = io.identity(stagedURL), let existing = io.identity(destination),
              staged.size != existing.size
        else { return }
        let temporary = destination.deletingLastPathComponent()
            .appendingPathComponent("\(destination.lastPathComponent).heal-\(UUID().uuidString)")
        guard (try? io.copyItem(stagedURL, temporary, .retain)) != nil else { return }
        // `.heal-` never parses as a generation, so a process death here leaves something inert
        // rather than something the recovery list would offer.
        if (try? io.rename(temporary, destination, .retain)) == nil {
            try? io.remove(temporary, .prune)
        }
    }

    /// `g-<sequence padded to 9>-<fingerprint>.json`
    static func name(generation: UInt64, fingerprint: String) -> String {
        "g-\(String(format: "%09llu", generation))-\(fingerprint).json"
    }

    /// Every generation on disk by NAME and SIZE only — `stat(2)`, no reads, no fingerprints.
    ///
    /// This is what the save path uses. `retained()` reads and re-fingerprints every entry to
    /// report whether its bytes still match its name, which is right for the recovery list and
    /// ruinous per save: at 2.6 MB and three generations it put ~8 MB of reads and three full
    /// fingerprints on the main actor every time the user typed. Pruning needs sizes, names and
    /// times, and `identity(_:)` supplies all three for the cost of a stat.
    ///
    /// `wroteAtEpochSeconds` is the file's mtime, which is what keeps the age anchors working with
    /// no ledger at all (F234). The ledger's time is better — it is the writer's own record, proof
    /// against a restore that rewrites timestamps — so `prune` prefers it and falls back to this.
    /// Without the fallback, a lost ledger silently reduced retention to "the newest 3", which is
    /// the 2026-08-14 shape with its specific defence removed, and contradicted design §1.2's
    /// promise that a lost ledger "can never lose a generation".
    func entries() -> [RetainedGeneration] {
        let names = (try? io.contentsOfDirectory(directoryURL, .listHistory)) ?? []
        return names.compactMap { name -> RetainedGeneration? in
            guard let parsed = Self.parse(name) else { return nil }
            let identity = io.identity(directoryURL.appendingPathComponent(name))
            return RetainedGeneration(
                name: name,
                sequence: parsed.sequence,
                fingerprint: parsed.fingerprint,
                byteCount: Int(identity?.size ?? 0),
                wroteAtEpochSeconds: identity?.modifiedSeconds,
                recordCount: nil,
                bytesMatchName: true
            )
        }
        .sorted { $0.sequence > $1.sequence }
    }

    /// Every generation on disk, newest first, joined with whatever the ledger knows.
    ///
    /// An entry whose bytes no longer match its name — or that cannot be read at all — is reported
    /// with `bytesMatchName == false` and `recordCount == nil`: never silently omitted (the user
    /// would think the generation vanished) and never silently served (they would restore bytes
    /// that are not the ones they chose).
    ///
    /// `bytesMatchName == false` therefore means "do not trust these bytes", conflating "wrong
    /// bytes" with "unreadable". Both refuse identically in `data(of:)`, so nothing here is unsafe;
    /// telling the two apart in the UI needs a distinct state, and belongs with F192's picker.
    public func retained(ledger: StoreLedger? = nil) -> [RetainedGeneration] {
        let records = Dictionary(
            (ledger?.history ?? []).compactMap { record -> (String, StoreLedger.Record)? in
                guard let name = record.historyName else { return nil }
                return (name, record)
            },
            uniquingKeysWith: { first, _ in first }
        )
        let names = (try? io.contentsOfDirectory(directoryURL, .listHistory)) ?? []
        return names.compactMap { name -> RetainedGeneration? in
            guard let parsed = Self.parse(name) else { return nil }
            let url = directoryURL.appendingPathComponent(name)
            let identity = io.identity(url)
            // A file we cannot READ is still a generation the user has (F236). Dropping it here
            // told them it had vanished, when a permission error or a mid-listing removal is what
            // actually happened — one of those is fixable and the other is worth knowing about.
            // It reports as not matching its name, which `data(of:)` already refuses, so the
            // failure stays safe as well as honest.
            let bytes = try? io.read(url, .readHistoryEntry)
            let matches = bytes.map { io.fingerprint($0) == parsed.fingerprint } ?? false
            let record = records[name]
            return RetainedGeneration(
                name: name,
                sequence: parsed.sequence,
                fingerprint: parsed.fingerprint,
                byteCount: bytes?.count ?? Int(identity?.size ?? 0),
                // Without a ledger the count is genuinely unknown, but the date is not: it is the
                // file's own mtime. "3 minutes ago · 0 meetings" beside "yesterday · 17 meetings"
                // is the discrimination this list exists to make, and half of it survives a lost
                // ledger for free (F234).
                wroteAtEpochSeconds: record?.wroteAtEpochSeconds ?? identity?.modifiedSeconds,
                recordCount: matches ? record?.recordCount : nil,
                bytesMatchName: matches
            )
        }
        .sorted { $0.sequence > $1.sequence }
    }

    /// The bytes of one generation, verified against its own name first.
    public func data(of generation: RetainedGeneration) throws -> Data {
        let bytes = try io.read(directoryURL.appendingPathComponent(generation.name), .readHistoryEntry)
        guard io.fingerprint(bytes) == generation.fingerprint else {
            throw StoreHistoryError.fingerprintMismatch(generation.name)
        }
        return bytes
    }

    /// How many unresolved conflict branches are on disk.
    public func conflictBranchCount() -> Int {
        ((try? io.contentsOfDirectory(directoryURL, .listHistory)) ?? [])
            .filter { $0.hasPrefix("conflict-") }
            .count
    }

    /// Removes **every** retained generation and conflict branch, and returns the names removed
    /// (F239).
    ///
    /// **Why this exists.** F190's retained generations hold meeting titles, transcripts, notes and
    /// summaries, so deleting a meeting removes its recording folder and leaves its *text* in every
    /// generation that predates the deletion. "Delete Meeting" therefore reads as erasure and is
    /// not. The bound was the retention policy's oldest age anchor — about a week — with one
    /// unbounded exception: `pinHighWaterRecordCount` pins the largest generation indefinitely, so
    /// on a library that is not growing the text stays forever. Before this the only remedy was the
    /// one `docs/RECOVERY.md` documents: deleting the directory by hand. F295 has since made the
    /// per-meeting removal automatic, a week after each delete; this remains the immediate,
    /// whole-history version (F450 corrected the places that still said otherwise).
    ///
    /// **`conflict-` branches go too, and that is a deliberate departure from `prune`.** `prune`
    /// never touches them because they are a losing writer's work and exist nowhere else, so only
    /// the user — having seen them — may remove them. This *is* the user asking, and a conflict
    /// branch is a full copy of the index: leaving them would answer "forget my history" with
    /// "most of it".
    ///
    /// **Not idempotent by accident but by nature**: forgetting an absent or already-empty history
    /// returns an empty list rather than failing, because "there is nothing left to forget" is the
    /// outcome the caller wanted.
    ///
    /// Throws if a file resists removal, so a caller cannot report erasure it did not achieve —
    /// the one guarantee a privacy command has to keep. Names removed before the failure are lost
    /// to the caller, which is why the error matters more than the list.
    @discardableResult
    public func forgetAll() throws -> [String] {
        guard io.isDirectory(directoryURL) == true else { return [] }
        let names = (try? io.contentsOfDirectory(directoryURL, .listHistory)) ?? []
        // Everything this directory holds: content-addressed generations AND conflict branches.
        // Filtered by the two shapes rather than removing whatever is present, so an unrelated file
        // someone put here is not deleted by a command that promised to clear history.
        let ours = names.filter { Self.parse($0) != nil || $0.hasPrefix("conflict-") }
        for name in ours {
            try io.remove(directoryURL.appendingPathComponent(name), .prune)
        }
        return ours
    }

    /// Deletes what no rule keeps, and returns the names it removed.
    ///
    /// `recordCounts` and `writtenAt` are keyed by history name and come from the ledger, so a
    /// generation the ledger never recorded simply has no count or time and is kept or dropped on
    /// the remaining rules. `liveFingerprints` are the primary's and backup's, so the bytes that are
    /// currently live are never deleted.
    ///
    /// `conflict-` files are **never** pruned here. They are a losing writer's work and exist
    /// nowhere else, so only the user — having seen them — may remove them.
    @discardableResult
    public func prune(
        policy: RetentionPolicy,
        now: Int,
        recordCounts: [String: Int],
        writtenAt: [String: Int],
        liveFingerprints: [String]
    ) -> [String] {
        let entries = entries().map { entry -> RetainedGeneration in
            guard let count = recordCounts[entry.name] else { return entry }
            return RetainedGeneration(
                name: entry.name, sequence: entry.sequence, fingerprint: entry.fingerprint,
                byteCount: entry.byteCount,
                wroteAtEpochSeconds: writtenAt[entry.name] ?? entry.wroteAtEpochSeconds,
                recordCount: count, bytesMatchName: entry.bytesMatchName
            )
        }
        guard !entries.isEmpty else { return [] }
        let live = Set(liveFingerprints)

        // Rule 1 — the newest `recentCount`.
        var keep = Set(entries.prefix(max(0, policy.recentCount)).map(\.name))

        // Rule 2 — one slot per age anchor: the NEWEST generation older than that age. Without this,
        // a user who notices a problem a week later has nothing to go back to.
        //
        // Held apart from `keep` because the byte budget below is allowed to trim these and is
        // never allowed to trim rules 1, 3 or 4 (design §7.2).
        let age = { (entry: RetainedGeneration) -> Int? in
            (writtenAt[entry.name] ?? entry.wroteAtEpochSeconds).map { now - $0 }
        }
        var anchored: Set<String> = []
        for anchor in policy.ageAnchors {
            if let match = entries.first(where: { (age($0) ?? -1) >= anchor }) {
                anchored.insert(match.name)
            }
        }

        // Rule 3 — the high-water record count, which is what defeats a save burst. Exactly one
        // pin: the greatest known count with no NEWER generation holding at least as many.
        if policy.pinHighWaterRecordCount {
            var best: RetainedGeneration?
            for entry in entries.reversed() {   // oldest first
                guard let count = entry.recordCount else { continue }
                if let incumbent = best, let incumbentCount = incumbent.recordCount,
                   count < incumbentCount { continue }
                best = entry
            }
            if let best { keep.insert(best.name) }
        }

        // Rule 4 — never delete bytes that are currently live.
        for entry in entries where live.contains(entry.fingerprint) { keep.insert(entry.name) }

        // A generation is pruned when NO rule keeps it. The budget does not get a vote here.
        var doomed = entries.filter { !keep.contains($0.name) && !anchored.contains($0.name) }

        // Then, and only then, the byte budget TRIMS what the rules kept — it never rescues what
        // they did not (design §7.2). The inverse reading is tempting, because more history is more
        // recoverable, but it turns the policy into "keep every generation that fits": ~100-120 of
        // them per store at a 2-3 MB index, ~1 GB per library across four stores, and a deleted
        // meeting's transcript surviving that many saves instead of the week §13 promises the user.
        // Retention depth is bought with the anchors, which are bounded, not with the budget, which
        // is a ceiling.
        //
        // Oldest-first, and only among rule-2 anchors: rules 1, 3 and 4 are exempt, so the budget
        // can never take the newest generations, the high-water pin, or bytes that are live.
        var keptBytes = entries
            .filter { keep.contains($0.name) || anchored.contains($0.name) }
            .reduce(0) { $0 + $1.byteCount }
        if keptBytes > policy.byteBudget {
            for entry in entries.reversed()
            where anchored.contains(entry.name) && !keep.contains(entry.name) {
                guard keptBytes > policy.byteBudget else { break }
                doomed.append(entry)
                keptBytes -= entry.byteCount
            }
        }

        var removed: [String] = []
        for entry in doomed {
            guard (try? io.remove(directoryURL.appendingPathComponent(entry.name), .prune)) != nil
            else { continue }
            removed.append(entry.name)
        }
        return removed
    }

    /// The alphabet `StoreFingerprint.of` emits — `%016llx`, sixteen lowercase hex characters. It
    /// is part of the on-disk format and pinned by golden values, so matching it exactly is a
    /// sound test of "did this build write that name".
    private static let fingerprintAlphabet = Set("0123456789abcdef")

    /// `g-000000042-0123456789abcdef.json` → (42, "0123456789abcdef"). nil for anything else,
    /// including a `conflict-` branch, which is never a generation.
    ///
    /// The fingerprint is checked against the alphabet, not merely counted to sixteen: a stranger's
    /// file that happens to fit the shape would otherwise join the retained set, where pruning
    /// would delete it (F237).
    static func parse(_ name: String) -> (sequence: UInt64, fingerprint: String)? {
        guard name.hasPrefix("g-"), name.hasSuffix(".json") else { return nil }
        let middle = name.dropFirst(2).dropLast(5)
        let parts = middle.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 2, let sequence = UInt64(parts[0]), parts[1].count == 16,
              parts[1].allSatisfy(fingerprintAlphabet.contains)
        else { return nil }
        return (sequence, String(parts[1]))
    }
}
