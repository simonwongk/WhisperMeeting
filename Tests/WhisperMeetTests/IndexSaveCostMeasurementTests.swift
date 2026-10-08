import Foundation
import Testing
@testable import WhisperCore
@testable import WhisperMeet

/// F526 — what one library edit costs the main actor at 1,000 meetings, measured rather than
/// asserted. Opt-in, because it writes several hundred MB and its numbers are machine-specific:
///
/// ```
/// F526_MEASURE=1 swift test --disable-sandbox --no-parallel --filter indexSaveCostAtScale
/// F526_MEASURE=1 F526_MEETINGS=250 swift test … --filter indexSaveCostAtScale   # a smaller library
/// ```
///
/// The records are the real `MeetingRecord`, shaped like a transcribed 45-minute meeting: ~700
/// Whisper segments with their three quality metrics and the timestamped transcript text — the
/// shape that puts ~274 KB of index in each meeting. Every number goes to stderr; no timing is
/// asserted, because a threshold here would be a flaky test on someone else's hardware (F211's
/// rule). The `#require`s are the preconditions that make a number mean what it says — the store
/// really loaded the library, and each edit really saved — and the one `#expect` is that the
/// element-wise encoding the store now uses wrote the same bytes as the whole-array encoder at full
/// size.
///
/// Measured 2026-10-08 on an 11-core Mac shared with other builds, optimized build
/// (`-c release -Xswiftc -enable-testing -Xswiftc -DDEBUG`), 274 MB index: before F526 a steady
/// edit took 2,035 ms and the first edit after launch 6,352 ms; after, 443–471 ms and 487–551 ms.
@MainActor
@Test(
    "Index save cost at a 1,000-meeting library (F526)",
    .enabled(if: ProcessInfo.processInfo.environment["F526_MEASURE"] == "1")
)
func indexSaveCostAtScale() throws {
    let environment = ProcessInfo.processInfo.environment
    let meetingCount = environment["F526_MEETINGS"].flatMap(Int.init) ?? 1_000
    let segmentCount = environment["F526_SEGMENTS"].flatMap(Int.init) ?? 700

    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("F526Bench-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }

    let records = syntheticLibrary(meetings: meetingCount, segments: segmentCount)

    // The library on disk, written by the same store type the app uses, twice: a real library has a
    // backup and a ledger, and the first save after launch reads both.
    let seed = BackupJSONStore<[MeetingRecord]>(
        primaryURL: root.appendingPathComponent("meetings.json"),
        backupURL: root.appendingPathComponent("meetings.backup.json"),
        recordCount: { $0.count }
    )
    try seed.save(records)
    try seed.save(records)
    let bytes = try Data(contentsOf: root.appendingPathComponent("meetings.json"))
    report("library: \(meetingCount) meetings x \(segmentCount) segments, \(megabytes(bytes.count)) index")

    // Components, each alone.
    let pretty = JSONEncoder()
    pretty.outputFormatting = [.prettyPrinted, .sortedKeys]
    pretty.dateEncodingStrategy = .iso8601
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    let encode = try median(3) { _ = try pretty.encode(records) }
    report("encode, prettyPrinted+sortedKeys: \(ms(encode))")
    let makeEncoder = BackupJSONStore<[MeetingRecord]>.makeEncoder
    let elementwise = try median(3) { _ = try ConcurrentArrayEncoding.encode(records, makeEncoder: makeEncoder) }
    report("encode, element-wise on every core (what the meeting store does): \(ms(elementwise))")
    let identical = try ConcurrentArrayEncoding.encode(records, makeEncoder: makeEncoder) == makeEncoder().encode(records)
    report("element-wise bytes identical to the whole-array encoder's: \(identical)")
    #expect(identical)
    let decode = try median(3) { _ = try decoder.decode([MeetingRecord].self, from: bytes) }
    report("decode: \(ms(decode))")
    let fingerprint = try median(3) { _ = StoreFingerprint.of(bytes) }
    report("fingerprint: \(ms(fingerprint))")
    let scratch = root.appendingPathComponent("scratch.json")
    let write = try median(3) { try bytes.write(to: scratch, options: .atomic) }
    report("write .atomic: \(ms(write))")
    let read = try median(3) { _ = try Data(contentsOf: scratch) }
    report("read: \(ms(read))")

    // The app's own path: launch, the first edit after it, then ordinary edits.
    var store: MeetingStore?
    let launch = try measure { store = MeetingStore(rootDirectory: root, transcriptWriteDebounce: 3_600) }
    let library = try #require(store)
    try #require(library.meetings.count == meetingCount, "the store must load the whole library")
    try #require(library.health == .complete)
    report("launch (MeetingStore.init, load): \(ms(launch))")

    let ids = library.meetings.map(\.id)
    let first = try measure { library.togglePin(id: ids[0]) }
    try #require(library.persistCommitCount == 1, "the first edit must actually reach disk")
    report("first edit after launch (togglePin -> save): \(ms(first))")

    var commits = library.persistCommitCount
    let steady = try median(5) {
        library.togglePin(id: ids[0])
        commits += 1
    }
    try #require(library.persistCommitCount == commits, "every steady edit must actually reach disk")
    report("steady edit (togglePin -> save), median of 5: \(ms(steady))")

    // The typing path: an in-memory edit, then the debounced flush that saves it.
    library.editNotes(id: ids[1], text: "agenda")
    let flush = try measure { library.flushPendingEdits() }
    try #require(library.persistCommitCount == commits + 1, "the flush must actually reach disk")
    report("debounced notes flush: \(ms(flush))")
}

/// `meetings` transcribed meetings of `segments` segments each.
private func syntheticLibrary(meetings: Int, segments: Int) -> [MeetingRecord] {
    (0..<meetings).map { m in
        let lines: [TranscriptSegment] = (0..<segments).map { s in
            let start = Double(s) * 3.9 + Double(m % 7) / 10
            return TranscriptSegment(
                speaker: nil,
                start: start,
                end: start + 3.71,
                text: " and then we agreed the release would slip to the following sprint, item \(s)",
                avgLogprob: -0.2 - Double(s).squareRoot() / 97,
                noSpeechProb: 0.01 + Double(s % 13) / 1_009,
                compressionRatio: 1.3 + Double(s % 11) / 31
            )
        }
        return MeetingRecord(
            title: "Meeting \(m) — quarterly planning and review",
            createdAt: Date(timeIntervalSince1970: 1_700_000_000 + Double(m * 3_600)),
            duration: Double(segments) * 3.9,
            recordingPath: "Recordings/\(UUID().uuidString)/meeting.m4a",
            status: .completed,
            transcriptText: TranscriptFormatter.timestamped(lines),
            languageCode: "en",
            confidence: 0.87,
            segments: lines,
            transcriptNormalized: true,
            tags: ["planning", "q3"],
            transcriptionEngine: .whisperLarge,
            requestedLanguage: "automatic"
        )
    }
}

private func measure(_ body: () throws -> Void) throws -> Double {
    let start = ContinuousClock.now
    try body()
    let elapsed = ContinuousClock.now - start
    return Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
}

private func median(_ runs: Int, _ body: () throws -> Void) throws -> Double {
    var samples: [Double] = []
    for _ in 0..<runs { samples.append(try measure(body)) }
    return samples.sorted()[samples.count / 2]
}

private func ms(_ seconds: Double) -> String { String(format: "%.0f ms", seconds * 1_000) }
private func megabytes(_ count: Int) -> String { String(format: "%.1f MB", Double(count) / 1e6) }
private func report(_ line: String) { FileHandle.standardError.write(Data("    [F526] \(line)\n".utf8)) }
