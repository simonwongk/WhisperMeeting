import Foundation

public enum StoreHistoryError: Error, Sendable, Equatable {
    /// The file's bytes no longer fingerprint to the value in its own name.
    case fingerprintMismatch(String)
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
            // success, not a collision.
            return name
        } catch {
            return nil
        }
        return name
    }

    /// `g-<sequence padded to 9>-<fingerprint>.json`
    static func name(generation: UInt64, fingerprint: String) -> String {
        "g-\(String(format: "%09llu", generation))-\(fingerprint).json"
    }

    /// Every generation on disk, newest first, joined with whatever the ledger knows.
    ///
    /// An entry whose bytes no longer match its name is reported with `bytesMatchName == false` and
    /// `recordCount == nil` — never silently omitted (the user would think the generation vanished)
    /// and never silently served (they would restore bytes that are not the ones they chose).
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
            guard let bytes = try? io.read(directoryURL.appendingPathComponent(name), .readHistoryEntry)
            else { return nil }
            let matches = io.fingerprint(bytes) == parsed.fingerprint
            let record = records[name]
            return RetainedGeneration(
                name: name,
                sequence: parsed.sequence,
                fingerprint: parsed.fingerprint,
                byteCount: bytes.count,
                wroteAtEpochSeconds: record?.wroteAtEpochSeconds,
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
        let entries = retained().map { entry -> RetainedGeneration in
            guard entry.recordCount == nil, let count = recordCounts[entry.name] else { return entry }
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
        let age = { (entry: RetainedGeneration) -> Int? in
            (writtenAt[entry.name] ?? entry.wroteAtEpochSeconds).map { now - $0 }
        }
        for anchor in policy.ageAnchors {
            if let anchored = entries.first(where: { (age($0) ?? -1) >= anchor }) {
                keep.insert(anchored.name)
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

        var doomed = entries.filter { !keep.contains($0.name) }

        // Then the byte budget, which governs only what the rules did NOT already keep. If the
        // keeps alone exceed the budget they are still kept: the budget exists to bound disk use,
        // never to lose the last good generation. Newest-first, so what survives is the most recent
        // history the budget can afford.
        let keptBytes = entries.filter { keep.contains($0.name) }.reduce(0) { $0 + $1.byteCount }
        var remaining = max(0, policy.byteBudget - keptBytes)
        var affordable: Set<String> = []
        for entry in doomed where entry.byteCount <= remaining {
            remaining -= entry.byteCount
            affordable.insert(entry.name)
        }
        doomed.removeAll { affordable.contains($0.name) }

        var removed: [String] = []
        for entry in doomed {
            guard (try? io.remove(directoryURL.appendingPathComponent(entry.name), .prune)) != nil
            else { continue }
            removed.append(entry.name)
        }
        return removed
    }

    /// `g-000000042-0123456789abcdef.json` → (42, "0123456789abcdef"). nil for anything else,
    /// including a `conflict-` branch, which is never a generation.
    static func parse(_ name: String) -> (sequence: UInt64, fingerprint: String)? {
        guard name.hasPrefix("g-"), name.hasSuffix(".json") else { return nil }
        let middle = name.dropFirst(2).dropLast(5)
        let parts = middle.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 2, let sequence = UInt64(parts[0]), parts[1].count == 16 else {
            return nil
        }
        return (sequence, String(parts[1]))
    }
}
