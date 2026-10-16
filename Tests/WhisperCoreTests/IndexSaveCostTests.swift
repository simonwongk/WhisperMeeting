import Foundation
import Testing
@testable import WhisperCore

// F526 — what a save costs after a load, and how the meeting index is encoded.
//
// Measured on a 1,000-meeting library (274 MB, `IndexSaveCostMeasurementTests` in WhisperMeetTests):
// a steady save was ~2.0 s, nearly all of it one `JSONEncoder` pass over the whole index, and the first
// save after launch ~6.4 s, because it also decoded the primary — which `load()` had just decoded and
// never recorded in F211's memory — and the backup, which nothing had ever proved. These pin the two
// mechanisms that remove that: what a load proves, a save does not decode again; and an opted-in
// array store encodes its elements one at a time (so they can be encoded on every core), with bytes
// identical to the whole-array encoder's.

// MARK: - Counting decodes

/// Decodes per test run, keyed by a run id carried in every element, so tests running in parallel
/// cannot read each other's counts.
private final class DecodeTally: @unchecked Sendable {
    static let shared = DecodeTally()
    private let lock = NSLock()
    private var counts: [String: Int] = [:]
    func record(_ run: String) { lock.withLock { counts[run, default: 0] += 1 } }
    func count(_ run: String) -> Int { lock.withLock { counts[run] ?? 0 } }
}

private struct CountedEntry: Codable, Equatable {
    let run: String
    let title: String

    init(run: String, title: String) {
        self.run = run
        self.title = title
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        run = try container.decode(String.self, forKey: .run)
        title = try container.decode(String.self, forKey: .title)
        DecodeTally.shared.record(run)
    }
}

private struct Library {
    let directory: URL
    var primaryURL: URL { directory.appendingPathComponent("meetings.json") }
    var backupURL: URL { directory.appendingPathComponent("meetings.backup.json") }

    func store(io: StoreFileIO = .live) -> BackupJSONStore<[CountedEntry]> {
        BackupJSONStore<[CountedEntry]>(
            primaryURL: primaryURL, backupURL: backupURL, io: io, recordCount: { $0.count }
        )
    }
}

/// A library with a primary AND a decodable backup, as every library has after its second save.
private func seededLibrary(run: String) throws -> Library {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("IndexSaveCost-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let library = Library(directory: directory)
    let writer = library.store()
    try writer.save((0..<5).map { CountedEntry(run: run, title: "entry \($0)") })
    try writer.save((0..<6).map { CountedEntry(run: run, title: "entry \($0)") })
    return library
}

@Test("The first save after a load decodes neither copy again (F526)")
func theFirstSaveAfterALoadDecodesNothing() throws {
    let run = UUID().uuidString
    let library = try seededLibrary(run: run)
    defer { try? FileManager.default.removeItem(at: library.directory) }

    // A fresh store is a new launch: nothing in its memory.
    let launched = library.store()
    let loaded = try #require(try launched.load())
    let decodedByLoad = DecodeTally.shared.count(run)

    try launched.save(loaded.value + [CountedEntry(run: run, title: "edited")], expecting: loaded.token)

    let decodedBySave = DecodeTally.shared.count(run) - decodedByLoad
    #expect(decodedBySave == 0, "the first save after a load decoded \(decodedBySave) records again")
}

@Test("A copy that changed after the load is decoded again, and quarantined if it does not decode (F526)")
func aCopyChangedAfterTheLoadIsNotTrusted() throws {
    let run = UUID().uuidString
    let library = try seededLibrary(run: run)
    defer { try? FileManager.default.removeItem(at: library.directory) }
    let launched = library.store()
    let loaded = try #require(try launched.load())

    // Rewritten IN PLACE after the load proved it: same inode, so only the identity's ctime moves.
    let damaged = Data("{ not an index".utf8)
    try damaged.write(to: library.backupURL)

    let outcome = try launched.save(loaded.value, expecting: loaded.token)

    #expect(!outcome.quarantined.isEmpty, "a backup that no longer decodes was overwritten without a copy")
    let kept = try outcome.quarantined.map { try Data(contentsOf: library.directory.appendingPathComponent($0)) }
    #expect(kept.contains(damaged))
}

@Test("A backup replaced while the load was proving it is not recorded as proved (F526)")
func aBackupReplacedDuringTheProofIsNotTrusted() throws {
    let run = UUID().uuidString
    let library = try seededLibrary(run: run)
    defer { try? FileManager.default.removeItem(at: library.directory) }

    // Same length on purpose: a record taken after the decode, checking only that two stats agree
    // and the size matches, would attribute these bytes to the decode of the old ones.
    let original = try Data(contentsOf: library.backupURL)
    let swapped = Data(repeating: UInt8(ascii: "x"), count: original.count)
    let backupPath = library.backupURL.path
    let swaps = SwapOnce()
    var io = StoreFileIO.live
    io.read = { url, phase in
        let bytes = try StoreFileIO.live.read(url, phase)
        // The load's read of the backup returns the old bytes; another writer then replaces the file.
        if url.path == backupPath, swaps.take() { try swapped.write(to: url, options: .atomic) }
        return bytes
    }
    let launched = library.store(io: io)
    let loaded = try #require(try launched.load())
    #expect(!swaps.available, "the load never read the backup, so this test proved nothing")

    let outcome = try launched.save(loaded.value, expecting: loaded.token)

    let kept = try outcome.quarantined.map { try Data(contentsOf: library.directory.appendingPathComponent($0)) }
    #expect(kept.contains(swapped), "the replaced backup was overwritten without being copied aside")
}

private final class SwapOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var remaining = true
    var available: Bool { lock.withLock { remaining } }
    func take() -> Bool {
        lock.withLock {
            defer { remaining = false }
            return remaining
        }
    }
}

/// Armed by the test once the load is done, so the swap below lands on the SAVE's read of the primary.
private final class Flag: @unchecked Sendable {
    private let lock = NSLock()
    private var set = false
    var isSet: Bool { lock.withLock { set } }
    func raise() { lock.withLock { set = true } }
}

// MARK: - F908: a save records only what it read

/// `save` step 3 reads the primary, decodes it (or skips on a memory hit), and then recorded it in
/// F211's memory from stats taken AFTER the decode, checking only that two stats agree and the size
/// matches — so a same-size foreign write landing between the read and that record was remembered as
/// decoded though its bytes never were. The rotation then cloned that file into the backup and
/// remembered the clone too, and the next save, trusting the memory, replaced an undecodable backup
/// without the F187 quarantine. The record now takes the primary's identity BEFORE the read (the load
/// path's F526 rule), and the rotation remembers its clone only while the source is still that file.
@Test("A primary replaced between a save's read and its record is not remembered as decoded, and the next save still quarantines the backup cloned from it (F908)")
func aPrimaryReplacedDuringASaveIsNotTrusted() throws {
    let run = UUID().uuidString
    let library = try seededLibrary(run: run)
    defer { try? FileManager.default.removeItem(at: library.directory) }
    // Same length on purpose: the record's two stats agree and the size matches.
    let original = try Data(contentsOf: library.primaryURL)
    let swapped = Data(repeating: UInt8(ascii: "x"), count: original.count)
    let primaryPath = library.primaryURL.path
    let swaps = SwapOnce()
    let armed = Flag()
    var io = StoreFileIO.live
    io.read = { url, phase in
        let bytes = try StoreFileIO.live.read(url, phase)
        // The save's read of the primary returns the old bytes; another writer then replaces the file.
        if url.path == primaryPath, armed.isSet, swaps.take() { try swapped.write(to: url, options: .atomic) }
        return bytes
    }
    let store = library.store(io: io)
    let loaded = try #require(try store.load())
    armed.raise()

    let first = try store.save(loaded.value + [CountedEntry(run: run, title: "entry 6")], expecting: loaded.token)
    #expect(!swaps.available, "the save never read the primary, so this test proved nothing")
    // The rotation clones whatever is at the primary when it runs: the foreign bytes.
    try #require(try Data(contentsOf: library.backupURL) == swapped, "fixture: the rotation did not clone the replaced primary")

    let second = try store.save(loaded.value, expecting: first.token)

    let kept = try second.quarantined.map { try Data(contentsOf: library.directory.appendingPathComponent($0)) }
    #expect(kept.contains(swapped), "an undecodable backup, remembered as decoded from bytes that were never decoded, was replaced without being copied aside")
}

/// Step 3's record alone, with no rotation after it (the review of Wave 7 lane Y, P3): a save reads
/// the primary, has it replaced under it, and then loses its compare-and-swap, so step 9 never
/// overwrites the record. In the test above step 9's record of the installed primary hid a wrong
/// step-3 record, and only `rotate`'s proof was exercised — a mutant with step 3's stats taken after
/// the read survived it. Here that mutant remembers the replaced, undecodable primary as decoded, and
/// the next save replaces it without the F187 quarantine.
@Test("A save that loses its compare-and-swap after a swap under its read leaves no false record of the primary (F908)")
func aSaveThatLosesAfterASwapUnderItsReadLeavesNoFalseRecord() throws {
    let run = UUID().uuidString
    let library = try seededLibrary(run: run)
    defer { try? FileManager.default.removeItem(at: library.directory) }
    let primaryPath = library.primaryURL.path
    let swaps = SwapOnce()
    let armed = Flag()
    var io = StoreFileIO.live
    io.read = { url, phase in
        let bytes = try StoreFileIO.live.read(url, phase)
        if url.path == primaryPath, armed.isSet, swaps.take() {
            try Data(repeating: UInt8(ascii: "x"), count: bytes.count).write(to: url, options: .atomic)
        }
        return bytes
    }
    let store = library.store(io: io)
    let loaded = try #require(try store.load())
    _ = try store.save(loaded.value + [CountedEntry(run: run, title: "entry 6")], expecting: loaded.token)
    armed.raise()
    // A stale token: this save reads the primary (swapped under it) and then loses the race.
    #expect(throws: (any Error).self) {
        _ = try store.save(loaded.value + [CountedEntry(run: run, title: "entry 7")], expecting: loaded.token)
    }
    #expect(!swaps.available, "fixture: the losing save never read the primary")
    let swapped = try Data(contentsOf: library.primaryURL)
    try #require(swapped.allSatisfy { $0 == UInt8(ascii: "x") }, "fixture: the primary was not replaced")

    let third = try store.save(loaded.value)

    let kept = try third.quarantined.map { try Data(contentsOf: library.directory.appendingPathComponent($0)) }
    #expect(kept.contains(swapped), "an undecodable primary, remembered as decoded from bytes that were never decoded, was replaced without being copied aside")
}

// MARK: - F985: a save records what it renamed only while it is still the file it renamed

/// How a foreign writer replaces a file in the instant after this save's own `rename`.
enum ForeignSameSizeWrite: String, CaseIterable, Sendable {
    /// Temp file and rename: a new inode at the path.
    case atomicReplace
    /// Truncate and write through the same inode: only the modification time moves.
    case inPlace

    func write(_ data: Data, to url: URL) throws {
        switch self {
        case .atomicReplace: try data.write(to: url, options: .atomic)
        case .inPlace: try data.write(to: url)
        }
    }
}

/// `save` step 9 renames its staging file onto the primary and `rotate` renames its clone onto the
/// backup, and each then recorded the file at the path in F211's memory on two stats that agreed and
/// a size that matched. A same-size foreign write landing just after the rename passed both, so its
/// bytes were remembered as decoded, and the next save rotated (or replaced) them without the F187
/// quarantine. F526's before/after identity cannot be used, because `rename` changes the ctime; the
/// record now requires the file at the path to be the one that was renamed — same device, inode,
/// size and modification time.
@Test(
    "A same-size foreign write just after a save's install or rotation is not remembered as decoded (F985)",
    arguments: [StoreWritePhase.install, .rotateBackup], ForeignSameSizeWrite.allCases
)
func aForeignWriteJustAfterARenameIsNotTrusted(phase: StoreWritePhase, write: ForeignSameSizeWrite) throws {
    let run = UUID().uuidString
    let library = try seededLibrary(run: run)
    defer { try? FileManager.default.removeItem(at: library.directory) }
    let target = phase == .install ? library.primaryURL : library.backupURL
    let targetPath = target.path
    let swaps = SwapOnce()
    let armed = Flag()
    let swappedBytes = SwapRecord()
    var io = StoreFileIO.live
    io.rename = { source, destination, renamePhase in
        try StoreFileIO.live.rename(source, destination, renamePhase)
        // Another writer replaces the file this save just renamed into place, keeping its size.
        guard armed.isSet, renamePhase == phase, destination.path == targetPath, swaps.take() else { return }
        let renamed = try Data(contentsOf: destination)
        let foreign = Data(repeating: UInt8(ascii: "x"), count: renamed.count)
        try write.write(foreign, to: destination)
        swappedBytes.set(foreign)
    }
    let store = library.store(io: io)
    let loaded = try #require(try store.load())
    armed.raise()

    _ = try store.save(loaded.value + [CountedEntry(run: run, title: "entry 6")], expecting: loaded.token)
    let foreign = try #require(swappedBytes.value, "fixture: the save never renamed onto \(target.lastPathComponent)")
    try #require(try Data(contentsOf: target) == foreign, "fixture: the foreign write did not land")

    // Unchecked, so the compare-and-swap cannot refuse it over the foreign primary: the only thing
    // between the foreign bytes and a replacement without a copy is the decode memory.
    let next = try store.save(loaded.value)

    let kept = try next.quarantined.map { try Data(contentsOf: library.directory.appendingPathComponent($0)) }
    #expect(kept.contains(foreign), "bytes written over \(target.lastPathComponent) after this save's rename were remembered as decoded and replaced without being copied aside")
}

private final class SwapRecord: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Data?
    var value: Data? { lock.withLock { stored } }
    func set(_ data: Data) { lock.withLock { stored = data } }
}

// MARK: - Element-wise encoding

/// Every shape the meeting index has: nested objects and arrays, empty ones, optionals both ways,
/// keyed maps (sorted), dates, and strings with everything `JSONEncoder` escapes.
private struct Shape: Codable, Equatable {
    struct Inner: Codable, Equatable {
        var label: String?
        var values: [Double]
    }
    var id: Int
    var title: String
    var note: String?
    var when: Date
    var amount: Double
    var flags: [Bool]
    var children: [Inner]
    var empty: [Inner]
    var map: [String: Int]
    var nested: Inner?
}

private func shapes(_ count: Int) -> [Shape] {
    let awkward = [
        "", "plain", "line one\nline two", "tab\tand\r\nCRLF", "quote \" and backslash \\",
        "slash / and control \u{01}\u{1F}", "中文 and emoji 🎙️", "e\u{301} decomposed", "\u{2028}\u{2029}",
    ]
    let amounts: [Double] = [0, -0.0, 1e300, -2.5e-300, 0.1, 1.0 / 7]
    return (0..<count).map { i in
        let children: [Shape.Inner] = (0..<(i % 4)).map { c in
            Shape.Inner(label: c.isMultiple(of: 2) ? "c\(c)" : nil, values: [Double(c), 0.5])
        }
        let map: [String: Int] = i.isMultiple(of: 5) ? [:] : ["zeta": i, "alpha": -i, "Mid": 0]
        let nested: Shape.Inner? = i.isMultiple(of: 2) ? Shape.Inner(label: nil, values: []) : nil
        return Shape(
            id: i,
            title: awkward[i % awkward.count],
            note: i.isMultiple(of: 3) ? nil : awkward[(i + 1) % awkward.count],
            // Whole seconds: `.iso8601` drops fractions, so a fractional date could not round-trip.
            when: Date(timeIntervalSince1970: 1_700_000_000 + Double(i) * 3_601),
            amount: amounts[i % amounts.count],
            flags: i.isMultiple(of: 2) ? [] : [true, false],
            children: children,
            empty: [],
            map: map,
            nested: nested
        )
    }
}

@Test("Element-wise encoding is byte-identical to the whole-array encoder (F526)", arguments: [0, 1, 2, 3, 17, 257])
func elementwiseEncodingIsByteIdentical(count: Int) throws {
    let value = shapes(count)
    let whole = try BackupJSONStore<[Shape]>.makeEncoder().encode(value)
    let elementwise = try ConcurrentArrayEncoding.encode(value, makeEncoder: BackupJSONStore<[Shape]>.makeEncoder)
    #expect(elementwise == whole)
    // And whatever the bytes, the value is the same one.
    #expect(try JSONDecoder.store.decode([Shape].self, from: elementwise) == value)
}

@Test("Element-wise encoding matches the whole-array encoder without pretty-printing too (F526)")
func elementwiseCompactEncodingIsByteIdentical() throws {
    let value = shapes(40)
    let compact: () -> JSONEncoder = {
        let encoder = BackupJSONStore<[Shape]>.makeEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }
    #expect(try ConcurrentArrayEncoding.encode(value, makeEncoder: compact) == compact().encode(value))
}

/// Records, per run, how deep in the document each element was when it encoded itself.
private final class DepthTally: @unchecked Sendable {
    static let shared = DepthTally()
    private let lock = NSLock()
    private var depths: [String: [Int]] = [:]
    func record(_ run: String, _ depth: Int) { lock.withLock { depths[run, default: []].append(depth) } }
    func depths(_ run: String) -> [Int] { lock.withLock { depths[run] ?? [] } }
}

private struct DepthWitness: Codable {
    let run: String
    func encode(to encoder: Encoder) throws {
        DepthTally.shared.record(run, encoder.codingPath.count)
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(run, forKey: .run)
    }
}

@Test("A store opted into element-wise encoding encodes each element as its own document (F526)", arguments: [true, false])
func optedInStoresEncodeElementwise(optedIn: Bool) throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("Elementwise-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let run = UUID().uuidString
    let store = BackupJSONStore<[DepthWitness]>(
        primaryURL: directory.appendingPathComponent("index.json"),
        backupURL: directory.appendingPathComponent("index.backup.json"),
        encodesElementsConcurrently: optedIn
    )

    try store.save((0..<8).map { _ in DepthWitness(run: run) })

    // At the top of its own document an element's coding path is empty; inside the whole array it
    // is its index. Only the first can be encoded on another thread.
    let expected: [Int] = Array(repeating: optedIn ? 0 : 1, count: 8)
    #expect(DepthTally.shared.depths(run) == expected)
}

/// A value `JSONEncoder` refuses: a non-finite `Double` under the default `.throw` strategy.
private struct Fragile: Codable, Equatable { let value: Double }

/// One element that cannot be encoded fails the whole save, and nothing is written (the lane-V
/// review's V5). The element-wise encoder spreads the elements over lanes, records the first error
/// and throws it; if it swallowed that error the parts it never filled would be spliced in empty, and
/// an opted-in store would install an index that does not decode — the next launch would open the
/// previous backup, read-only, one save behind. The same guarantee the whole-array encoder gives by
/// throwing, and the reason `save` encodes before any IO.
@Test("One element that cannot be encoded fails the whole save, and nothing is written (F526)")
func anElementThatCannotEncodeFailsTheSaveAndWritesNothing() throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("ElementEncodeFailure-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let primaryURL = directory.appendingPathComponent("meetings.json")
    let backupURL = directory.appendingPathComponent("meetings.backup.json")
    let store = BackupJSONStore<[Fragile]>(
        primaryURL: primaryURL,
        backupURL: backupURL,
        recordCount: { $0.count },
        encodesElementsConcurrently: true
    )
    // Two saves, so the backup (the first) differs from the primary and a rotation would show.
    try store.save([Fragile(value: 1)])
    let saved = [Fragile(value: 1), Fragile(value: 2)]
    try store.save(saved)
    let primaryBefore = try Data(contentsOf: primaryURL)
    let backupBefore = try Data(contentsOf: backupURL)

    // Enough elements to spread over every lane, with the bad one in the middle of one of them.
    var values = (0..<200).map { Fragile(value: Double($0)) }
    values[137] = Fragile(value: .nan)

    #expect(throws: EncodingError.self) {
        try ConcurrentArrayEncoding.encode(values, makeEncoder: BackupJSONStore<[Fragile]>.makeEncoder)
    }
    #expect(throws: EncodingError.self) { try store.save(values) }

    #expect(try Data(contentsOf: primaryURL) == primaryBefore, "a failed element-wise encode replaced the index")
    #expect(try Data(contentsOf: backupURL) == backupBefore, "a failed element-wise encode rotated the backup")
    let names = try FileManager.default.contentsOfDirectory(atPath: directory.path)
    #expect(!names.contains { $0.contains(".stage-") || $0.contains(".rotate-") }, "left behind: \(names)")
    #expect(try store.load()?.value == saved)
}

private extension JSONDecoder {
    static var store: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
