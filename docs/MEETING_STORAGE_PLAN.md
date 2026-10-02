# Meeting Storage Implementation Plan (F795, F796)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or
> superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Show each meeting's disk usage. Let the user shrink a meeting, by hand, to one AAC recording, deleting the
original audio only after the replacement is verified and the index saved.

**Architecture:**
- **WhisperCore** holds the pure rules (`MeetingStoragePlan`): names, deletion order, the "worth it" rule and
  refusals. It also holds the `afconvert` encoder (`AudioCompressor`).
- **WhisperMeet** holds the disk reads: allocated sizes, and AVAudioFile decoding.
- **`AppModel`** holds the reachable flow, which follows the Rebuild Audio shape: request, then confirmation, then
  `perform(confirmed:)`, then detached work, then main-actor commits. Its F47-style injectable seams carry the
  red-green tests.
- **SwiftUI** is a thin binding: a header chip and button, a confirmation dialog, a Settings row and a Storage sheet.

**Tech Stack:** Swift 6.2 tools in Swift 5 language mode, Swift Testing, AVFoundation (`AVAudioFile`),
`/usr/bin/afconvert`, SwiftUI.

**Spec:** [`MEETING_STORAGE_DESIGN.md`](MEETING_STORAGE_DESIGN.md), approved by the user on 2026-10-02.

## Global Constraints

- Output: AAC-LC, 16 kHz, mono, `-b 32000`, `.m4a`, encoded in two steps. Step 1 is
  `AudioTranscoder.transcodeToWAV` with `--mix`; step 2 is `afconvert -f m4af -d aac -b 32000`.
- Output names keep the stem:
  - `meeting.wav` becomes `meeting.m4a`;
  - `meeting-recovered.wav` becomes `meeting-recovered.m4a`;
  - `recording.<ext>` becomes `recording.m4a`;
  - an already-`.m4a` name is replaced in place under its own spelling.
- Nothing original is removed before `MeetingStore.replaceRecordingPath` returns `true`, or, for an in-place
  replacement, before `replaceItemAt` succeeds.
- Deletion order:
  1. the manifests;
  2. the raw tracks;
  3. superseded rebuilds, `.shrink-*` and `.meeting.wav.mixing`;
  4. the old recordings.
- Delete only names on the planner's list. Every other file is kept.
- Worth it only if *E* ≤ *R* − *R*/4. Predicted *E* = duration × 4,100 B/s. Verification tolerance is 0.5 s.
- Free space needed: duration × 32,000 B/s, plus predicted *E*, plus 100,000,000 bytes.
- Manual only: nothing runs without a press, and every shrink goes through a confirmation.
- `meetings.json` gains no field.
- No public closure default argument in WhisperCore (the F718 guard). AppModel seams are internal.
- Use `Int64(saturating:)` for every Double→Int64 conversion.
- Tests use synthetic audio only, never a user's library.
- Never `git add -A`. Every commit message names `F795` or `F796`.

## Review Focus

These five inputs are not exercised by any spec bullet. Each is pinned by a test in the task named.

1. **An import named with an upper-case extension (`recording.M4A`).** On APFS, `recording.m4a` is the same file, so
   writing one and deleting the other would delete the output. The output must keep the input's spelling, and the
   deletion list must exclude it case-insensitively. Task 2.
2. **A batch where one meeting fails.** The rest still shrink, and the summary names the failure. Task 6.
3. **A meeting whose `recordingPath` is not inside its own `Recordings/<id>/` folder.** It is refused, and nothing on
   disk is touched. Task 6.
4. **A stale, unreferenced `meeting.m4a` already in the folder,** left by an earlier failed save whose cleanup also
   failed. It is replaced, not reported as "file exists". Task 6.
5. **A meeting whose length cannot be read** (the index says 0 and AVAudioFile cannot open the file). It is refused
   with `.cannotMeasureLength`, and the encoder never runs. Tasks 2 and 6.

## Execution notes (read once)

- **Where to work.** Use the worktree `/Users/simonwang/Documents/Whisper/.claude/worktrees/f795` on branch
  `f795-meeting-storage`, made from `main`.
- **How to run tests on this Mac** (Command Line Tools only). Define `ST` once per shell:

  ```bash
  FW=/Library/Developer/CommandLineTools/Library/Developer/Frameworks
  LIB=/Library/Developer/CommandLineTools/Library/Developer/usr/lib
  ST="swift test --disable-sandbox --no-parallel -Xswiftc -F -Xswiftc $FW -Xlinker -rpath -Xlinker $FW -Xlinker -rpath -Xlinker $LIB"
  $ST --filter <swiftFunctionName>
  ```

- `--filter` matches the Swift **function** name. Always read the reported test count: a filter that matches nothing
  exits 0.
- **The gate:** `zsh Scripts/quality-check.sh`, with its output unfiltered. It refuses untracked files.

---

### Task 1: Downmix stereo when transcoding (F796)

**Files:**
- Modify: `Sources/WhisperCore/AudioTranscoder.swift:43-46`
- Test: `Tests/WhisperCoreTests/AudioTranscoderTests.swift` (append)

**Interfaces:**
- Produces: `AudioTranscoder.transcodeToWAV(input:output:)` (signature unchanged) now writes a *mixed* mono WAV.

- [ ] **Step 1: Claim F796.**

  ```bash
  python3 .claude/cw-sweep/board.py claim F796 --owner "claude-work (whisper-40)"
  ```

- [ ] **Step 2: Write the failing test.** Append it to `AudioTranscoderTests.swift`:

```swift
// F796 — afconvert's `-c 1` "add[s]/remove[s] channels without regard to order": it keeps the left
// channel and discards the right, so Qwen lost one party of a two-channel call recording entirely.
// `--mix` downmixes. Measured before the fix: right-only 440 Hz tone (RMS 8485) -> mono RMS 0.0.
private func writeStereoTone(rightOnly: Bool, at url: URL) throws {
    let rate: UInt32 = 48_000, frames: UInt32 = 48_000, channels: UInt16 = 2, bits: UInt16 = 16
    let dataBytes = frames * UInt32(channels) * UInt32(bits / 8)
    var data = Data()
    func a32(_ v: UInt32) { data.append(contentsOf: withUnsafeBytes(of: v.littleEndian) { Array($0) }) }
    func a16(_ v: UInt16) { data.append(contentsOf: withUnsafeBytes(of: v.littleEndian) { Array($0) }) }
    data.append(contentsOf: Array("RIFF".utf8)); a32(36 + dataBytes); data.append(contentsOf: Array("WAVE".utf8))
    data.append(contentsOf: Array("fmt ".utf8)); a32(16); a16(1); a16(channels); a32(rate)
    a32(rate * UInt32(channels) * UInt32(bits / 8)); a16(channels * bits / 8); a16(bits)
    data.append(contentsOf: Array("data".utf8)); a32(dataBytes)
    for i in 0..<Int(frames) {
        let tone = Int16(12_000 * sin(2 * Double.pi * 440 * Double(i) / Double(rate)))
        a16(UInt16(bitPattern: rightOnly ? 0 : tone))   // left
        a16(UInt16(bitPattern: tone))                   // right
    }
    try data.write(to: url)
}

/// RMS of a 16-bit PCM WAV's `data` chunk, walking chunks (afconvert may write others first).
func pcm16RMS(ofWAVAt url: URL) throws -> Double {
    let bytes = [UInt8](try Data(contentsOf: url))
    var index = 12
    while index + 8 <= bytes.count {
        let id = String(decoding: bytes[index..<index + 4], as: UTF8.self)
        let size = Int(UInt32(bytes[index + 4]) | UInt32(bytes[index + 5]) << 8
            | UInt32(bytes[index + 6]) << 16 | UInt32(bytes[index + 7]) << 24)
        if id == "data" {
            let end = min(bytes.count, index + 8 + size)
            var sum = 0.0, count = 0
            var cursor = index + 8
            while cursor + 1 < end {
                let sample = Double(Int16(bitPattern: UInt16(bytes[cursor]) | UInt16(bytes[cursor + 1]) << 8))
                sum += sample * sample; count += 1; cursor += 2
            }
            return count == 0 ? 0 : (sum / Double(count)).squareRoot()
        }
        index += 8 + size + (size & 1)
    }
    return 0
}

@Test("A right-channel-only stereo import is not silenced by the mono transcode (F796)")
func transcodeMixesStereoInsteadOfKeepingTheLeftChannel() throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("F796-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    let rightOnly = dir.appendingPathComponent("right-only.wav")
    try writeStereoTone(rightOnly: true, at: rightOnly)

    let out = dir.appendingPathComponent("out.wav")
    try AudioTranscoder.transcodeToWAV(input: rightOnly, output: out)

    // A mix of a full-scale tone and silence is half its RMS (8485 -> ~4242); the discard was 0.
    #expect(try pcm16RMS(ofWAVAt: out) > 3_000)
}
```

- [ ] **Step 3: Run it and watch it fail.**
  - Run: `$ST --filter transcodeMixesStereoInsteadOfKeepingTheLeftChannel`
  - Expected: 1 test, FAIL, the RMS is 0.

- [ ] **Step 4: Implement.** In `transcodeToWAV`, change the arguments line and add the comment:

```swift
        // `--mix`, because `-c 1` alone "add[s]/remove[s] channels without regard to order": it keeps
        // the left channel and drops the right, so a two-channel call recording lost one party (F796).
        process.arguments = ["-f", "WAVE", "-d", "LEI16@16000", "-c", "1", "--mix", input.path, output.path]
```

- [ ] **Step 5: Run it and watch it pass.** Then run the whole transcoder file.
  - Run: `$ST --filter transcodeMixesStereoInsteadOfKeepingTheLeftChannel`, then `$ST --filter audioTranscoder`.
  - Expected: PASS. Every test in `AudioTranscoderTests` still passes.

- [ ] **Step 6: Run the real model (log evidence; not committed).**
  - Build a stereo file with `Scripts/bench/clips/en1.wav` on the right channel only and silence on the left. Use
    Python's `wave` module with frames interleaved `(0, s)`.
  - Transcribe it through the installed Qwen runtime, using a throwaway env-gated test in `WhisperMeetTests` that
    calls `QwenASRClient` with `QwenASRRuntime`'s installed paths, as the sweep's real-model smoke did.
  - Do this before the fix, then after.
  - Expected: before, empty or nonsense text; after, the en1 sentence.
  - Delete the throwaway test.

- [ ] **Step 7: Commit.**

```bash
git add Sources/WhisperCore/AudioTranscoder.swift Tests/WhisperCoreTests/AudioTranscoderTests.swift
git commit -m "fix(transcription): mix stereo to mono instead of dropping the right channel (F796)"
```

---

### Task 2: The pure planner, `MeetingStoragePlan` (F795)

**Files:**
- Create: `Sources/WhisperCore/MeetingStoragePlan.swift`
- Test: `Tests/WhisperCoreTests/MeetingStoragePlanTests.swift`

**Interfaces:**
- Produces, all `public`:
  - `MeetingStoragePlan.FolderEntry(name: String, bytes: Int64)`
  - `outputName(forRecordingNamed:) -> String?`
  - `isShrunkCapture(_:) -> Bool`
  - `removableFiles(in:keeping:) -> [FolderEntry]`, returned in deletion order
  - `reclaimableBytes(in:recordingName:outputName:) -> Int64`
  - `predictedOutputBytes(durationSeconds:) -> Int64`
  - `isWorthShrinking(encodedBytes:reclaimableBytes:) -> Bool`
  - `totalBytes(_:) -> Int64`
  - `MeetingStoragePlan.DiskFacts` (`recordingName`, `recordingExists`, `inOwnFolder`, `hasIntegrityProblem`,
    `rebuildOffered`, `durationSeconds`, `entries`)
  - `MeetingStoragePlan.LiveFacts` (`libraryReadOnly`, `captureOrImportInProgress`, `meetingBusy`, `backupRunning`,
    `anotherShrinkRunning`)
  - `MeetingStoragePlan.Unavailability`, with a `message: String`
  - `unavailability(disk:live:) -> Unavailability?`

- [ ] **Step 1: Write the failing tests** in `Tests/WhisperCoreTests/MeetingStoragePlanTests.swift`:

```swift
import Foundation
import Testing
@testable import WhisperCore

// F795 — the rules Shrink acts on, with no disk involved (docs/MEETING_STORAGE_DESIGN.md).

private typealias Entry = MeetingStoragePlan.FolderEntry

private let capture: [Entry] = [
    Entry(name: "meeting.wav", bytes: 345_600_000),
    Entry(name: "system-audio.f32", bytes: 691_200_000),
    Entry(name: "microphone-audio.f32", bytes: 691_200_000),
    Entry(name: "source-tracks.json", bytes: 2_000),
    Entry(name: "notes.md", bytes: 40_000),
    Entry(name: "session.json", bytes: 1_000),
    Entry(name: "diarization.json", bytes: 9_000),
    Entry(name: "ask-embeddings.f32", bytes: 300_000),
    Entry(name: "ask-embeddings.json", bytes: 4_000),
    Entry(name: "meeting-recovered-superseded-1.wav", bytes: 100_000_000),
    Entry(name: ".shrink-ABC.m4a", bytes: 9_000),
    Entry(name: "something-unknown.bin", bytes: 7),
]

@Test("The shrunk name keeps the stem, so provenance survives a lost index (F795)")
func shrinkOutputNameKeepsTheStem() {
    #expect(MeetingStoragePlan.outputName(forRecordingNamed: "meeting.wav") == "meeting.m4a")
    #expect(MeetingStoragePlan.outputName(forRecordingNamed: "meeting-recovered.wav") == "meeting-recovered.m4a")
    #expect(MeetingStoragePlan.outputName(forRecordingNamed: "recording.mp4") == "recording.m4a")
    #expect(MeetingStoragePlan.outputName(forRecordingNamed: "recording.wav") == "recording.m4a")
    #expect(MeetingStoragePlan.outputName(forRecordingNamed: "meeting.m4a") == "meeting.m4a")
    #expect(MeetingStoragePlan.outputName(forRecordingNamed: "notes.md") == nil)
    #expect(MeetingStoragePlan.outputName(forRecordingNamed: "") == nil)
    #expect(MeetingStoragePlan.outputName(forRecordingNamed: "recording") == nil)
}

@Test("An upper-case .M4A import is replaced under its own spelling, never deleted as a leftover (F795)")
func shrinkOutputNameKeepsAnExistingM4ASpelling() {
    // On APFS `recording.M4A` and `recording.m4a` are one file: writing one and deleting the other
    // would delete the shrink's own output. Review Focus 1.
    #expect(MeetingStoragePlan.outputName(forRecordingNamed: "recording.M4A") == "recording.M4A")
    let removable = MeetingStoragePlan.removableFiles(
        in: [Entry(name: "recording.M4A", bytes: 10)], keeping: "recording.m4a"
    )
    #expect(removable.isEmpty)
}

@Test("Shrink removes only listed audio files, manifests first and the old recording last (F795)")
func shrinkRemovesListedFilesInSafeOrder() {
    let removable = MeetingStoragePlan.removableFiles(in: capture, keeping: "meeting.m4a").map(\.name)
    #expect(removable == [
        "source-tracks.json",
        "microphone-audio.f32", "system-audio.f32",
        ".shrink-ABC.m4a", "meeting-recovered-superseded-1.wav",
        "meeting.wav",
    ])
    for kept in ["notes.md", "session.json", "diarization.json", "ask-embeddings.f32",
                 "ask-embeddings.json", "something-unknown.bin"] {
        #expect(!removable.contains(kept), "\(kept) must be kept")
    }
}

@Test("An import's original file is removed, and its provenance and captions are kept (F795)")
func shrinkRemovesTheImportOriginalOnly() {
    let entries = [Entry(name: "recording.mp4", bytes: 900_000_000), Entry(name: "source.json", bytes: 800),
                   Entry(name: "captions.en.vtt", bytes: 5_000), Entry(name: "recording.m4a", bytes: 9_000)]
    #expect(MeetingStoragePlan.removableFiles(in: entries, keeping: "recording.m4a").map(\.name) == ["recording.mp4"])
}

@Test("Shrinking saves at least a quarter of what it frees, or it is refused (F795)")
func shrinkWorthItRule() {
    #expect(MeetingStoragePlan.isWorthShrinking(encodedBytes: 75, reclaimableBytes: 100))
    #expect(!MeetingStoragePlan.isWorthShrinking(encodedBytes: 76, reclaimableBytes: 100))
    #expect(!MeetingStoragePlan.isWorthShrinking(encodedBytes: 0, reclaimableBytes: 0))
    #expect(MeetingStoragePlan.isWorthShrinking(encodedBytes: 0, reclaimableBytes: .max))
    // An in-place replacement frees the recording it overwrites.
    let inPlace = MeetingStoragePlan.reclaimableBytes(
        in: [Entry(name: "recording.m4a", bytes: 1_000)], recordingName: "recording.m4a", outputName: "recording.m4a"
    )
    #expect(inPlace == 1_000)
}

@Test("Predicted size reads correctly at the extremes, not merely without trapping (F795)")
func shrinkPredictionSaturates() {
    #expect(MeetingStoragePlan.predictedOutputBytes(durationSeconds: 3_600) == 14_760_000)
    #expect(MeetingStoragePlan.predictedOutputBytes(durationSeconds: 1e30) == .max)
    #expect(MeetingStoragePlan.predictedOutputBytes(durationSeconds: -5) == 0)
    #expect(MeetingStoragePlan.predictedOutputBytes(durationSeconds: .nan) == 0)
    #expect(MeetingStoragePlan.totalBytes([Entry(name: "a", bytes: .max), Entry(name: "b", bytes: 1)]) == .max)
}

private func disk(_ name: String = "meeting.wav", entries: [Entry] = capture, duration: TimeInterval = 3_600,
                  exists: Bool = true, ownFolder: Bool = true, problem: Bool = false,
                  rebuild: Bool = false) -> MeetingStoragePlan.DiskFacts {
    MeetingStoragePlan.DiskFacts(recordingName: name, recordingExists: exists, inOwnFolder: ownFolder,
                                 hasIntegrityProblem: problem, rebuildOffered: rebuild,
                                 durationSeconds: duration, entries: entries)
}

@Test("Each refusal is reported, in the order a person can act on (F795)")
func shrinkRefusalsAndTheirOrder() {
    let idle = MeetingStoragePlan.LiveFacts()
    #expect(MeetingStoragePlan.unavailability(disk: disk(), live: idle) == nil)
    #expect(MeetingStoragePlan.unavailability(disk: disk(ownFolder: false), live: idle) == .unsupportedRecording)
    #expect(MeetingStoragePlan.unavailability(disk: disk(exists: false), live: idle) == .recordingMissing)
    #expect(MeetingStoragePlan.unavailability(disk: disk(problem: true), live: idle) == .damaged(rebuildOffered: false))
    #expect(MeetingStoragePlan.unavailability(disk: disk(rebuild: true), live: idle) == .damaged(rebuildOffered: true))
    #expect(MeetingStoragePlan.unavailability(disk: disk(duration: 0), live: idle) == .cannotMeasureLength)
    let compact = disk("recording.m4a", entries: [Entry(name: "recording.m4a", bytes: 14_800_000)])
    #expect(MeetingStoragePlan.unavailability(disk: compact, live: idle) == .nothingToGain)
    let shrunk = disk("meeting.m4a", entries: [Entry(name: "meeting.m4a", bytes: 14_800_000),
                                               Entry(name: "notes.md", bytes: 9)])
    #expect(MeetingStoragePlan.unavailability(disk: shrunk, live: idle) == .alreadyShrunk)
    var live = idle; live.libraryReadOnly = true
    #expect(MeetingStoragePlan.unavailability(disk: disk(), live: live) == .libraryReadOnly)
    live = idle; live.captureOrImportInProgress = true
    #expect(MeetingStoragePlan.unavailability(disk: disk(), live: live) == .captureOrImportInProgress)
    live = idle; live.meetingBusy = true
    #expect(MeetingStoragePlan.unavailability(disk: disk(), live: live) == .meetingBusy)
    live = idle; live.backupRunning = true
    #expect(MeetingStoragePlan.unavailability(disk: disk(), live: live) == .backupRunning)
    live = idle; live.anotherShrinkRunning = true
    #expect(MeetingStoragePlan.unavailability(disk: disk(), live: live) == .anotherShrinkRunning)
    // Facts about the meeting are said before busy states that clear on their own.
    live = idle; live.meetingBusy = true
    #expect(MeetingStoragePlan.unavailability(disk: disk(problem: true), live: live) == .damaged(rebuildOffered: false))
}

@Test("A shrunk capture with leftovers is finished, not refused as damaged or compact (F795)")
func shrinkResumeModeIgnoresEncodeRefusals() {
    // The app stopped mid-delete: the index already names meeting.m4a and a raw track survived.
    let leftovers = disk("meeting.m4a", entries: [Entry(name: "meeting.m4a", bytes: 14_800_000),
                                                  Entry(name: "system-audio.f32", bytes: 691_200_000)],
                         duration: 0, problem: true, rebuild: true)
    #expect(MeetingStoragePlan.unavailability(disk: leftovers, live: .init()) == nil)
}
```

- [ ] **Step 2: Run them and watch them fail.**
  - Run: `$ST --filter shrink`
  - Expected: a build error, "cannot find 'MeetingStoragePlan' in scope".

- [ ] **Step 3: Implement** `Sources/WhisperCore/MeetingStoragePlan.swift`:

```swift
import Foundation

/// What Shrink (F795) may remove from a meeting's folder, what it writes, and when it is refused.
///
/// Pure: it sees names and sizes, never the disk, so each rule in `docs/MEETING_STORAGE_DESIGN.md`
/// is a unit test. The app collects the facts (`DiskFacts`, `LiveFacts`) and acts on the answers.
public enum MeetingStoragePlan {
    /// One regular file in a meeting's folder: its name relative to the folder, and its size on disk.
    public struct FolderEntry: Sendable, Equatable {
        public let name: String
        public let bytes: Int64
        public init(name: String, bytes: Int64) {
            self.name = name
            self.bytes = bytes
        }
    }

    /// AAC at `-b 32000` measured 32,928 bit/s on a bench clip (F795): about 4,116 bytes a second.
    public static let predictedBytesPerSecond: Double = 4_100

    /// The shrunk recording's name, or nil for a recording Shrink does not handle.
    ///
    /// The stem is kept and only the extension changes, because the stem is how
    /// `InterruptedRecordingRecovery.finalizedRecording` tells a capture, a rebuild (F273) and an
    /// import apart after a lost index. A name that is already `.m4a` keeps its exact spelling: on a
    /// case-insensitive volume `recording.M4A` and `recording.m4a` are one file, and writing one then
    /// deleting the other would delete the output.
    public static func outputName(forRecordingNamed name: String) -> String? {
        let url = URL(fileURLWithPath: name)
        let stem = url.deletingPathExtension().lastPathComponent
        let ext = url.pathExtension.lowercased()
        guard !ext.isEmpty else { return nil }
        switch stem {
        case "meeting", "meeting-recovered":
            guard ext == "wav" || ext == "m4a" else { return nil }
        case "recording":
            break
        default:
            return nil
        }
        return ext == "m4a" ? name : stem + ".m4a"
    }

    /// Whether `name` is a recording Shrink wrote for an in-app capture or rebuild. Such a meeting is
    /// never encoded again; Shrink only finishes removing what an interrupted run left behind.
    public static func isShrunkCapture(_ name: String) -> Bool {
        name == "meeting.m4a" || name == "meeting-recovered.m4a"
    }

    /// The files Shrink removes, in the order it removes them. Only names on this list are ever removed.
    ///
    /// The order is what keeps a folder from looking damaged if the app stops partway (design, step 7):
    /// manifests before tracks, so Verify Library never sees a track shorter than its manifest; tracks
    /// before the old WAVs, so `SourceRebuild.offer` never sees tracks with no complete WAV.
    public static func removableFiles(in entries: [FolderEntry], keeping outputName: String) -> [FolderEntry] {
        let keep = outputName.lowercased()
        func rank(_ name: String) -> Int? {
            let lower = name.lowercased()
            guard lower != keep else { return nil }
            switch lower {
            case "source-tracks.json", "source-tracks.recovered.json": return 0
            case "system-audio.f32", "microphone-audio.f32": return 1
            case ".meeting.wav.mixing": return 2
            case "meeting.wav", "meeting-recovered.wav": return 3
            default: break
            }
            if lower.hasPrefix(".shrink-") { return 2 }
            if lower.hasPrefix("meeting-recovered-superseded-"), lower.hasSuffix(".wav") { return 2 }
            let url = URL(fileURLWithPath: lower)
            if url.deletingPathExtension().lastPathComponent == "recording", !url.pathExtension.isEmpty { return 3 }
            return nil
        }
        return entries
            .compactMap { entry in rank(entry.name).map { (entry, $0) } }
            .sorted { $0.1 != $1.1 ? $0.1 < $1.1 : $0.0.name < $1.0.name }
            .map(\.0)
    }

    /// *R* in the design: what a shrink frees. Every removable file, plus the recording itself when
    /// the output replaces it in place.
    public static func reclaimableBytes(in entries: [FolderEntry], recordingName: String, outputName: String) -> Int64 {
        var total = totalBytes(removableFiles(in: entries, keeping: outputName))
        if recordingName.lowercased() == outputName.lowercased(),
           let recording = entries.first(where: { $0.name.lowercased() == recordingName.lowercased() }) {
            total = totalBytes([FolderEntry(name: "", bytes: total), recording])
        }
        return total
    }

    /// The predicted size of the encoded `.m4a`, before encoding.
    public static func predictedOutputBytes(durationSeconds: TimeInterval) -> Int64 {
        guard durationSeconds.isFinite || durationSeconds == .infinity else { return 0 }
        return Int64(saturating: Swift.max(0, durationSeconds) * predictedBytesPerSecond)
    }

    /// Worth it only when it saves at least a quarter of what it frees: *E* ≤ *R* − *R*/4.
    public static func isWorthShrinking(encodedBytes: Int64, reclaimableBytes: Int64) -> Bool {
        guard reclaimableBytes > 0 else { return false }
        return encodedBytes <= reclaimableBytes - reclaimableBytes / 4
    }

    /// The sum of `entries`, saturating rather than trapping.
    public static func totalBytes(_ entries: [FolderEntry]) -> Int64 {
        entries.reduce(Int64(0)) { sum, entry in
            let (value, overflow) = sum.addingReportingOverflow(Swift.max(0, entry.bytes))
            return overflow ? .max : value
        }
    }

    /// What the disk says about one meeting, gathered off the main actor.
    public struct DiskFacts: Sendable, Equatable {
        public var recordingName: String
        public var recordingExists: Bool
        /// The recording sits directly in the meeting's own `Recordings/<id>/` folder.
        public var inOwnFolder: Bool
        /// Verify Library reports a problem (`IntegrityFinding.isProblem`) for this recording.
        public var hasIntegrityProblem: Bool
        public var rebuildOffered: Bool
        /// The recording's decoded length when it could be read, else the index's duration.
        public var durationSeconds: TimeInterval
        public var entries: [FolderEntry]

        public init(recordingName: String, recordingExists: Bool, inOwnFolder: Bool, hasIntegrityProblem: Bool,
                    rebuildOffered: Bool, durationSeconds: TimeInterval, entries: [FolderEntry]) {
            self.recordingName = recordingName
            self.recordingExists = recordingExists
            self.inOwnFolder = inOwnFolder
            self.hasIntegrityProblem = hasIntegrityProblem
            self.rebuildOffered = rebuildOffered
            self.durationSeconds = durationSeconds
            self.entries = entries
        }
    }

    /// The app's state at the moment of asking. These clear on their own.
    public struct LiveFacts: Sendable, Equatable {
        public var libraryReadOnly = false
        public var captureOrImportInProgress = false
        public var meetingBusy = false
        public var backupRunning = false
        public var anotherShrinkRunning = false
        public init() {}
    }

    public enum Unavailability: Sendable, Equatable {
        case unsupportedRecording
        case recordingMissing
        case damaged(rebuildOffered: Bool)
        case cannotMeasureLength
        case alreadyShrunk
        case nothingToGain
        case libraryReadOnly
        case captureOrImportInProgress
        case meetingBusy
        case backupRunning
        case anotherShrinkRunning

        public var message: String {
            switch self {
            case .unsupportedRecording:
                return "This recording isn't stored in its own meeting folder, so Shrink can't tidy it safely."
            case .recordingMissing:
                return "The recording file is missing, so there is nothing to shrink."
            case .damaged(rebuildOffered: true):
                return "This recording is incomplete. Use Rebuild Audio first: shrinking now would keep the damage and delete the raw tracks that can repair it."
            case .damaged(rebuildOffered: false):
                return "Verify Library reports a problem with this recording, so it isn't shrunk: the damage would be kept and the original deleted."
            case .cannotMeasureLength:
                return "This recording's length can't be read, so a compressed copy couldn't be checked against it."
            case .alreadyShrunk:
                return "Already shrunk."
            case .nothingToGain:
                return "Already compact: shrinking would save less than a quarter of its space."
            case .libraryReadOnly:
                return "The library is read-only, so nothing can be changed."
            case .captureOrImportInProgress:
                return "Finish recording or importing first."
            case .meetingBusy:
                return "Wait for this meeting's transcription, speaker analysis or rebuild to finish."
            case .backupRunning:
                return "Wait for the backup to finish."
            case .anotherShrinkRunning:
                return "Another meeting is being shrunk."
            }
        }
    }

    /// Why Shrink can't run now, or nil when it can. Facts about the meeting come first, because they
    /// never clear on their own; busy states come last.
    public static func unavailability(disk: DiskFacts, live: LiveFacts) -> Unavailability? {
        guard disk.inOwnFolder, let output = outputName(forRecordingNamed: disk.recordingName) else {
            return .unsupportedRecording
        }
        guard disk.recordingExists else { return .recordingMissing }
        if isShrunkCapture(disk.recordingName) {
            // Resume mode: nothing is encoded, so damage and size rules about an encode don't apply.
            if removableFiles(in: disk.entries, keeping: output).isEmpty { return .alreadyShrunk }
        } else {
            if disk.hasIntegrityProblem || disk.rebuildOffered {
                return .damaged(rebuildOffered: disk.rebuildOffered)
            }
            guard disk.durationSeconds.isFinite, disk.durationSeconds > 0 else { return .cannotMeasureLength }
            let reclaim = reclaimableBytes(in: disk.entries, recordingName: disk.recordingName, outputName: output)
            let predicted = predictedOutputBytes(durationSeconds: disk.durationSeconds)
            if !isWorthShrinking(encodedBytes: predicted, reclaimableBytes: reclaim) { return .nothingToGain }
        }
        if live.libraryReadOnly { return .libraryReadOnly }
        if live.captureOrImportInProgress { return .captureOrImportInProgress }
        if live.meetingBusy { return .meetingBusy }
        if live.backupRunning { return .backupRunning }
        if live.anotherShrinkRunning { return .anotherShrinkRunning }
        return nil
    }
}
```

> The guard in `predictedOutputBytes` lets `+infinity` through to saturate at `.max`, and turns NaN into 0.
> `Int64(saturating:)` already maps `+inf` to `.max`. The explicit NaN check is there because `max(0, .nan)`
> returns 0 only by argument order, and that is not something to rely on.

- [ ] **Step 4: Run them and watch them pass.**
  - Run: `$ST --filter shrink`
  - Expected: 8 tests, all pass.

- [ ] **Step 5: Commit.**

```bash
git add Sources/WhisperCore/MeetingStoragePlan.swift Tests/WhisperCoreTests/MeetingStoragePlanTests.swift
git commit -m "feat(meetings): the pure rules for shrinking a meeting's storage (F795)"
```

---

### Task 3: The real encoder and decoder (F795)

**Files:**
- Create: `Sources/WhisperCore/AudioCompressor.swift`
- Create: `Sources/WhisperMeet/DecodedAudio.swift`
- Create: `Sources/WhisperMeet/MeetingStorageMeter.swift`
- Test: `Tests/WhisperMeetTests/ShrinkEncoderTests.swift`. It lives in WhisperMeetTests because it needs `DecodedAudio`.

**Interfaces:**
- Consumes: `AudioTranscoder.transcodeToWAV` (Task 1) and `MeetingStoragePlan.FolderEntry` (Task 2).
- Produces:
  - `AudioCompressor.compressSpeech(input: URL, output: URL, workingWAV: URL) throws`
  - `AudioCompressor.bitRate`
  - `DecodedAudio.declaredDuration(of: URL) -> TimeInterval?`
  - `DecodedAudio.fullyDecodedDuration(of: URL) throws -> TimeInterval`
  - `MeetingStorageMeter.entries(in folder: URL) -> [MeetingStoragePlan.FolderEntry]`

- [ ] **Step 1: Write the failing tests** in `Tests/WhisperMeetTests/ShrinkEncoderTests.swift`:

```swift
import AVFoundation
import Foundation
import Testing
@testable import WhisperCore
@testable import WhisperMeet

// F795 — the real afconvert encode and AVAudioFile decode Shrink depends on. /usr/bin/afconvert
// ships with macOS, the CI runner included, so this is a normal test and not a gated one.

private func benchClip(_ name: String) -> URL {
    SourceAssertion.url("Scripts/bench/clips/\(name).wav")
}

@Test("A bench clip shrinks to 16 kHz mono AAC whose decoded length matches (F795)")
func shrinkEncodesABenchClip() throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ShrinkEnc-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    let out = dir.appendingPathComponent("meeting.m4a")
    let work = dir.appendingPathComponent(".shrink-work.wav")

    try AudioCompressor.compressSpeech(input: benchClip("en1"), output: out, workingWAV: work)

    #expect(!FileManager.default.fileExists(atPath: work.path), "the working WAV is removed")
    let file = try AVAudioFile(forReading: out)
    #expect(file.fileFormat.settings[AVFormatIDKey] as? UInt32 == kAudioFormatMPEG4AAC)
    #expect(file.fileFormat.channelCount == 1)
    #expect(file.fileFormat.sampleRate == 16_000)
    let original = try #require(DecodedAudio.declaredDuration(of: benchClip("en1")))
    #expect(abs(try DecodedAudio.fullyDecodedDuration(of: out) - original) < 0.1)
    // About 4.1 KB a second; a generous band, since the clip is 3 s and the container has overhead.
    let bytes = try #require(try out.resourceValues(forKeys: [.fileSizeKey]).fileSize)
    #expect(bytes < Int(original * 8_000) + 8_000)
}

@Test("A truncated .m4a fails the full decode rather than passing on its header (F795)")
func shrinkFullDecodeRejectsATruncatedFile() throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ShrinkTrunc-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    let out = dir.appendingPathComponent("meeting.m4a")
    try AudioCompressor.compressSpeech(input: benchClip("en2"), output: out,
                                       workingWAV: dir.appendingPathComponent(".w.wav"))
    let data = try Data(contentsOf: out)
    try data.prefix(data.count / 2).write(to: out)
    let original = try #require(DecodedAudio.declaredDuration(of: benchClip("en2")))
    let decoded = try? DecodedAudio.fullyDecodedDuration(of: out)
    #expect(decoded == nil || abs(decoded! - original) > 0.5)
}

@Test("Storage counts every file in the folder, nested ones too, by size on disk (F795)")
func storageMeterCountsTheWholeFolder() throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("Meter-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir.appendingPathComponent("sub"), withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    try Data(count: 1_000_000).write(to: dir.appendingPathComponent("meeting.wav"))
    try Data(count: 10).write(to: dir.appendingPathComponent("sub/extra.bin"))
    let before = MeetingStorageMeter.entries(in: dir)
    #expect(Set(before.map(\.name)) == ["meeting.wav", "sub/extra.bin"])
    #expect(MeetingStoragePlan.totalBytes(before) >= 1_000_010)
    // Re-measured, not cached: Foundation caches resource values per URL instance (F698).
    try Data(count: 2_000_000).write(to: dir.appendingPathComponent("meeting.wav"))
    #expect(MeetingStoragePlan.totalBytes(MeetingStorageMeter.entries(in: dir)) >= 2_000_010)
}
```

- [ ] **Step 2: Run them and watch them fail.**
  - Run: `$ST --filter "shrinkEncodesABenchClip|shrinkFullDecodeRejectsATruncatedFile|storageMeterCountsTheWholeFolder"`
  - Expected: a build error, "cannot find 'AudioCompressor'".

- [ ] **Step 3: Implement** `Sources/WhisperCore/AudioCompressor.swift`:

```swift
import Foundation

/// Encodes a recording to compact speech audio for Shrink (F795): AAC-LC, 16 kHz, mono, in `.m4a`.
///
/// Two afconvert runs, because one loses audio. `-c 1` keeps only the left channel, and `--mix`,
/// which fixes that for WAV output, measurably does not apply when the output is AAC: a right-only
/// stereo file encoded straight to AAC decoded to silence (F796). So step one is the same mixed
/// 16 kHz mono WAV the engines are given, and step two encodes that mono file.
public enum AudioCompressor {
    /// The AAC target in bits per second. 32 kbps measured 32,928 bit/s, about 14.8 MB an hour.
    public static let bitRate = 32_000

    /// Writes `output`, using `workingWAV` as scratch and removing it afterwards. The caller puts
    /// both beside the recording, so the final rename into place stays on one volume.
    public static func compressSpeech(input: URL, output: URL, workingWAV: URL) throws {
        defer { try? FileManager.default.removeItem(at: workingWAV) }
        try AudioTranscoder.transcodeToWAV(input: input, output: workingWAV)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/afconvert")
        process.arguments = ["-f", "m4af", "-d", "aac", "-b", String(bitRate), workingWAV.path, output.path]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        do {
            try process.run()
        } catch {
            throw AudioTranscoderError.transcodeFailed("afconvert could not be launched: \(error.localizedDescription)")
        }
        // As in `transcodeToWAV`: the pipes carry only small log lines, so read-to-EOF then wait cannot deadlock.
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            try? FileManager.default.removeItem(at: output)
            throw AudioTranscoderError.transcodeFailed(String(decoding: data.suffix(2_000), as: UTF8.self))
        }
    }
}
```

  Then `Sources/WhisperMeet/DecodedAudio.swift`:

```swift
import AVFoundation
import Foundation

/// Lengths of audio files, read through AVFoundation (F795).
enum DecodedAudio {
    enum Failure: LocalizedError {
        case unreadable(String)
        var errorDescription: String? {
            switch self { case let .unreadable(reason): return "The compressed audio could not be read back: \(reason)" }
        }
    }

    /// The length the container declares, without decoding. Nil when AVAudioFile cannot open it.
    static func declaredDuration(of url: URL) -> TimeInterval? {
        guard let file = try? AVAudioFile(forReading: url), file.processingFormat.sampleRate > 0 else { return nil }
        return Double(file.length) / file.processingFormat.sampleRate
    }

    /// The length obtained by decoding every packet. A file whose header promises more than its
    /// packets deliver fails here, which is why Shrink checks this and not the header (design, step 4).
    static func fullyDecodedDuration(of url: URL) throws -> TimeInterval {
        let file = try AVAudioFile(forReading: url)
        let format = file.processingFormat
        guard format.sampleRate > 0,
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 65_536) else {
            throw Failure.unreadable("no decodable audio format")
        }
        var frames: AVAudioFramePosition = 0
        while file.framePosition < file.length {
            try file.read(into: buffer)
            guard buffer.frameLength > 0 else { break }
            frames += AVAudioFramePosition(buffer.frameLength)
        }
        return Double(frames) / format.sampleRate
    }
}
```

  Then `Sources/WhisperMeet/MeetingStorageMeter.swift`:

```swift
import Foundation
import WhisperCore

/// Reads a meeting folder's files and their sizes on disk (F795). Fresh URLs every call: Foundation
/// caches resource values per URL instance, which is what defeated F326's re-check (F698).
enum MeetingStorageMeter {
    static func entries(in folder: URL) -> [MeetingStoragePlan.FolderEntry] {
        let keys: [URLResourceKey] = [.isRegularFileKey, .totalFileAllocatedSizeKey, .fileAllocatedSizeKey, .fileSizeKey]
        let root = URL(fileURLWithPath: folder.path, isDirectory: true).standardizedFileURL
        guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: keys) else {
            return []
        }
        var entries: [MeetingStoragePlan.FolderEntry] = []
        for case let found as URL in enumerator {
            let url = URL(fileURLWithPath: found.path)
            guard let values = try? url.resourceValues(forKeys: Set(keys)), values.isRegularFile == true else { continue }
            let bytes = values.totalFileAllocatedSize ?? values.fileAllocatedSize ?? values.fileSize ?? 0
            let name = String(url.standardizedFileURL.path.dropFirst(root.path.count + 1))
            entries.append(.init(name: name, bytes: Int64(bytes)))
        }
        return entries
    }
}
```

- [ ] **Step 4: Run them and watch them pass.**
  - Run: the Step 2 filter.
  - Expected: 3 tests, all pass.
  - If the truncation test shows that AVAudioFile tolerates a half file *and* reports the full length, then the
    verification design is wrong. Stop and report it rather than loosening the test.

- [ ] **Step 5: Commit.**

```bash
git add Sources/WhisperCore/AudioCompressor.swift Sources/WhisperMeet/DecodedAudio.swift \
  Sources/WhisperMeet/MeetingStorageMeter.swift Tests/WhisperMeetTests/ShrinkEncoderTests.swift
git commit -m "feat(meetings): encode speech to AAC and verify it by full decode (F795)"
```

---

### Task 4: Let the store repoint a recording, and report whether it saved (F795)

**Files:**
- Modify: `Sources/WhisperMeet/MeetingStore.swift`:
  - add `replaceRecordingPath(id:with:)` after `update(id:_:)` (about `:1260-1267`);
  - make `ownRecordingFolder(of:)` internal (`:1646`);
  - give `recordingURL(for:)` its fallback (`:851-853`).
- Test: `Tests/WhisperMeetTests/ShrinkStoreTests.swift`

**Interfaces:**
- Produces:
  - `MeetingStore.replaceRecordingPath(id: UUID, with relativePath: String) -> Bool`
  - `MeetingStore.ownRecordingFolder(of:) -> URL?`, now internal
  - the `recordingURL(for:)` `.m4a` fallback

- [ ] **Step 1: Write the failing tests:**

```swift
import Foundation
import Testing
@testable import WhisperCore
@testable import WhisperMeet

// F795 — the save Shrink commits through. Shaped like `delete(ids:)` (F451): the save is the first
// effect, and a save that fails puts the record back, so nothing on disk is ever deleted for an
// index that still names it.

private func root() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("ShrinkStore-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

@Test("Repointing a recording saves it, and a reopened library sees the new path (F795)")
@MainActor
func shrinkReplaceRecordingPathPersists() throws {
    let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
    let id = UUID()
    let store = MeetingStore(rootDirectory: root)
    store.upsert(MeetingRecord(id: id, title: "Standup", recordingPath: "Recordings/\(id)/meeting.wav", status: .completed))
    #expect(store.replaceRecordingPath(id: id, with: "Recordings/\(id)/meeting.m4a"))
    #expect(MeetingStore(rootDirectory: root).meeting(id: id)?.recordingPath == "Recordings/\(id)/meeting.m4a")
}

@Test("A repoint that loses a race keeps the old path and is not offered back (F795)")
@MainActor
func shrinkReplaceRecordingPathLostRaceRollsBack() throws {
    let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
    let id = UUID()
    MeetingStore(rootDirectory: root).upsert(
        MeetingRecord(id: id, title: "Standup", recordingPath: "Recordings/\(id)/meeting.wav", status: .completed))
    let store = MeetingStore(rootDirectory: root)
    let rival = BackupJSONStore<[MeetingRecord]>(
        primaryURL: root.appendingPathComponent("meetings.json"),
        backupURL: root.appendingPathComponent("meetings.backup.json"),
        writer: "ffff9999", recordCount: { $0.count })
    let existing = try rival.load()
    _ = try rival.save([MeetingRecord(id: id, title: "Renamed elsewhere",
                                      recordingPath: "Recordings/\(id)/meeting.wav", status: .completed)],
                       expecting: existing?.token)

    #expect(!store.replaceRecordingPath(id: id, with: "Recordings/\(id)/meeting.m4a"))
    #expect(store.meeting(id: id)?.recordingPath == "Recordings/\(id)/meeting.wav")
    // "Keep my change" must not be able to re-save a path whose file the shrink has removed.
    #expect(!store.meetings.contains { $0.recordingPath.hasSuffix(".m4a") })
}

@Test("A record that still names meeting.wav finds the shrunk meeting.m4a beside it (F795)")
@MainActor
func shrinkRecordingURLFallsBackToTheShrunkFile() throws {
    let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
    let id = UUID()
    let folder = root.appendingPathComponent("Recordings/\(id)", isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    try Data([1]).write(to: folder.appendingPathComponent("meeting.m4a"))
    let store = MeetingStore(rootDirectory: root)
    let stale = MeetingRecord(id: id, title: "Restored", recordingPath: "Recordings/\(id)/meeting.wav", status: .completed)
    #expect(store.recordingURL(for: stale).lastPathComponent == "meeting.m4a")
    // With the WAV present, the WAV is the answer: the fallback never hides a real file.
    try Data([1]).write(to: folder.appendingPathComponent("meeting.wav"))
    #expect(store.recordingURL(for: stale).lastPathComponent == "meeting.wav")
}
```

- [ ] **Step 2: Run them and watch them fail.**
  - Run: `$ST --filter shrinkReplaceRecordingPath`, then `$ST --filter shrinkRecordingURLFallsBack`
  - Expected: a build error, "has no member 'replaceRecordingPath'". Once that compiles, the fallback test fails.

- [ ] **Step 3: Implement.** Add this after `update(id:_:)`:

```swift
    /// Repoints a meeting at a new recording file and reports whether the index save landed (F795).
    ///
    /// Shrink deletes the old audio only after this returns true, so this is shaped like
    /// `delete(ids:)` (F451): the save is the first effect, and a failed save puts the record back. A
    /// lost race re-reads the library without offering the change back, because the shrink removes
    /// its new file when this fails, and "Keep my change" would then re-save a path to nothing.
    func replaceRecordingPath(id: UUID, with relativePath: String) -> Bool {
        guard editMutationIsAllowed() else { return false }
        guard let index = meetings.firstIndex(where: { $0.id == id }) else { return false }
        let before = meetings
        meetings[index].recordingPath = relativePath
        meetings[index].schemaVersion = MeetingRecord.currentSchemaVersion
        guard persistMeetings() else {
            meetings = before
            if writeConflict?.isRace == true { beginConflictRecovery() }
            return false
        }
        scheduleNotesSidecarWrite(for: id)
        return true
    }
```

  Replace `recordingURL(for:)` with:

```swift
    func recordingURL(for meeting: MeetingRecord) -> URL {
        let indexed = rootDirectory.appendingPathComponent(meeting.recordingPath)
        // A record that still names a capture's WAV after Shrink replaced it (F795): an older index
        // generation restored by Recover Library, or another copy's stale record. Only those two
        // names, and only when the named file is absent, so the fallback never hides a real file.
        let name = indexed.lastPathComponent
        guard name == "meeting.wav" || name == "meeting-recovered.wav",
              !FileManager.default.fileExists(atPath: indexed.path) else { return indexed }
        let shrunk = indexed.deletingPathExtension().appendingPathExtension("m4a")
        return FileManager.default.fileExists(atPath: shrunk.path) ? shrunk : indexed
    }
```

  At `:1646`, change `private func ownRecordingFolder(of meeting:` to `func ownRecordingFolder(of meeting:`.

- [ ] **Step 4: Run them and watch them pass.** Then run the delete and race suites, which share this code.
  - Run: `$ST --filter "shrinkReplaceRecordingPath|shrinkRecordingURLFallsBack|delete|Race"`
  - Expected: all pass, and the reported count is more than 3.

- [ ] **Step 5: Commit.**

```bash
git add Sources/WhisperMeet/MeetingStore.swift Tests/WhisperMeetTests/ShrinkStoreTests.swift
git commit -m "feat(meetings): repoint a recording with a save that reports, and find a shrunk file (F795)"
```

---

### Task 5: Recognise shrunk recordings in speaker analysis and folder rebuild (F795)

**Files:**
- Modify: `Sources/WhisperMeet/AppModel.swift:1992`, the `nativeRecordingFileNames` set.
- Modify: `Sources/WhisperCore/InterruptedRecordingRecovery.swift:145-183`, `finalizedRecording`.
- Test: `Tests/WhisperMeetTests/ShrunkRecordingRecognitionTests.swift`

**Interfaces:**
- Produces: `finalizedRecording(in:)` returns `meeting.m4a` as `.existingCapture` and `meeting-recovered.m4a` as
  `.rebuiltSourceTracks`, each when non-empty, after both WAV names and before an import.

- [ ] **Step 1: Write the failing tests:**

```swift
import Foundation
import Testing
@testable import WhisperCore
@testable import WhisperMeet

// F795 — a shrunk capture keeps its stem so it is still recognised as what it is: speaker analysis
// still runs on it, and a lost index still rebuilds it with the right provenance (F273). Verify
// Library and Rebuild Audio are pinned as unchanged: a shrunk folder has neither tracks nor manifest.

private func folder() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("Shrunk-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

@Test("A lost index rebuilds a shrunk capture and a shrunk rebuild with their own provenance (F795)")
func shrunkCapturesAreFinalizedRecordings() throws {
    let dir = try folder(); defer { try? FileManager.default.removeItem(at: dir) }
    try Data([1, 2, 3]).write(to: dir.appendingPathComponent("meeting.m4a"))
    #expect(InterruptedRecordingRecovery.finalizedRecording(in: dir)?.source == .existingCapture)
    try FileManager.default.removeItem(at: dir.appendingPathComponent("meeting.m4a"))
    try Data([1, 2, 3]).write(to: dir.appendingPathComponent("meeting-recovered.m4a"))
    #expect(InterruptedRecordingRecovery.finalizedRecording(in: dir)?.source == .rebuiltSourceTracks)
}

@Test("An empty shrunk file is not a finalized recording (F795)")
func anEmptyShrunkFileIsNotFinalized() throws {
    let dir = try folder(); defer { try? FileManager.default.removeItem(at: dir) }
    try Data().write(to: dir.appendingPathComponent("meeting.m4a"))
    #expect(InterruptedRecordingRecovery.finalizedRecording(in: dir) == nil)
}

@Test("A shrunk folder has no Verify Library problem and no Rebuild Audio offer (F795)")
func aShrunkFolderLooksHealthy() throws {
    let dir = try folder(); defer { try? FileManager.default.removeItem(at: dir) }
    let m4a = dir.appendingPathComponent("meeting.m4a")
    try Data(count: 4_000).write(to: m4a)
    let findings = MeetingIntegrityChecker.check(MeetingIntegrityDescriptor(
        recordingURL: m4a, sourceTracks: [], indexDurationSeconds: 3, rawTracksWithoutManifest: false))
    #expect(!findings.contains { $0.isProblem })
    #expect(SourceRebuild.offer(in: dir, currentDuration: 3) == nil)
}

@Test("Speaker analysis accepts a shrunk capture as a native recording (F795)")
@MainActor
func speakerAnalysisAcceptsAShrunkCapture() throws {
    let root = try folder(); defer { try? FileManager.default.removeItem(at: root) }
    let model = AppModel(store: MeetingStore(rootDirectory: root), recorder: AudioCaptureEngine(),
                         defaults: UserDefaults(suiteName: "Shrunk.\(UUID().uuidString)")!)
    let id = UUID()
    let meeting = MeetingRecord(id: id, title: "Sync", duration: 3, recordingPath: "Recordings/\(id)/meeting.m4a",
                                status: .completed, transcriptText: "Hi.",
                                segments: [TranscriptSegment(speaker: nil, start: 0, end: 1, text: "Hi.")])
    #expect(model.speakerAnalysisUnavailability(for: meeting) != .unsupportedRecording)
}
```

  > Check the `MeetingIntegrityDescriptor` initializer labels against `MeetingIntegrityChecker.swift:158-190` and
  > `AppModel.swift:6929-6934` before running. Match them exactly.

- [ ] **Step 2: Run them and watch them fail.**
  - Run: `$ST --filter "shrunkCapturesAreFinalizedRecordings|anEmptyShrunkFileIsNotFinalized|aShrunkFolderLooksHealthy|speakerAnalysisAcceptsAShrunkCapture"`
  - Expected:
    - `shrunkCaptures…` and `speakerAnalysis…` FAIL;
    - `aShrunkFolderLooksHealthy` PASSES already, which is correct, because it pins behaviour that is unchanged;
    - `anEmptyShrunk…` PASSES already, as a guard for the new code.

- [ ] **Step 3: Implement.**

  In `AppModel.swift`, make the set read:

```swift
    private static let nativeRecordingFileNames: Set<String> = [
        "meeting.wav", "meeting-recovered.wav",
        // A capture Shrink compressed keeps its stem (F795). Analysis decodes through AudioTranscoder,
        // which reads .m4a, and an import stays `recording.*`, so this widens nothing else.
        "meeting.m4a", "meeting-recovered.m4a",
    ]
```

  Update the doc comment above it so it no longer says "the canonical recording file names capture and
  interrupted-recording recovery write". It should say what the set now holds.

  In `finalizedRecording(in:)`, after the WAV loop and before the import check, insert:

```swift
        // A capture Shrink compressed (F795) keeps its stem, so it keeps its provenance. WhisperCore
        // cannot decode AAC, so its duration is 0 here, exactly as a non-WAV import's is below; the
        // index normally carries it, and this path runs only after the index was lost.
        for (name, source) in [
            ("meeting.m4a", RecoveredRecording.Source.existingCapture),
            ("meeting-recovered.m4a", RecoveredRecording.Source.rebuiltSourceTracks),
        ] {
            let url = directory.appendingPathComponent(name)
            if let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size > 0 {
                return RecoveredRecording(recordingURL: url, duration: 0, source: source)
            }
        }
```

  Update `finalizedRecording`'s doc comment: "The three names…" becomes the five names, with a sentence on the
  shrunk two.

- [ ] **Step 4: Run them and watch them pass.** Also run the existing recovery and diarization suites.
  - Run: `$ST --filter "Shrunk|shrunk|finalized|Finalized|Diarization|diarization|FolderRebuild"`
  - Expected: all pass.
  - Then look at how `FolderRebuild` uses `RecoveredRecording.duration` for a non-WAV import, and confirm that a
    0 duration is handled the same way for `meeting.m4a`. Record what you find in the log's Gaps section.

- [ ] **Step 5: Commit.**

```bash
git add Sources/WhisperMeet/AppModel.swift Sources/WhisperCore/InterruptedRecordingRecovery.swift \
  Tests/WhisperMeetTests/ShrunkRecordingRecognitionTests.swift
git commit -m "feat(meetings): a shrunk capture is still a native recording with its provenance (F795)"
```

---

### Task 6: The AppModel shrink flow, and the backup flag (F795)

**Files:**
- Create: `Sources/WhisperMeet/AppModel+Shrink.swift`, an extension holding the flow, so `AppModel.swift` grows
  only by its stored properties.
- Modify: `Sources/WhisperMeet/AppModel.swift`:
  - add the stored properties next to `sourceRebuildRunningID` (about `:586`);
  - in `backUpLibrary` (`:3018-3043`), set `isBackingUp` and refuse while a shrink runs.
- Test: `Tests/WhisperMeetTests/ShrinkFlowTests.swift`

**Interfaces:**
- Consumes: everything from Tasks 2–5.
- Produces, used by Task 7's views:
  - `AppModel.ShrinkRequest` (`meetingIDs`, `titles`, `currentBytes`, `predictedBytes`, `skipped`,
    `includesUntranscribed`, `includesVideo`)
  - `pendingShrink: ShrinkRequest?`
  - `shrinkRunningID: UUID?`
  - `isBackingUp: Bool`
  - `storageFacts: [UUID: MeetingStoragePlan.DiskFacts]`
  - `storageBytes(for:) -> Int64?`
  - `refreshStorage(ids:) async`
  - `shrinkUnavailability(for:) -> MeetingStoragePlan.Unavailability?`
  - `requestShrink(ids:)`
  - `performShrink(confirmed:) -> Task<Void, Never>?`
  - `cancelShrink()`
  - `static shrinkConfirmationTitle(_:)` and `static shrinkConfirmationMessage(_:)`
  - the seams `encodeForShrink`, `decodedDurationForShrink`, `declaredDurationForShrink`, `storageEntries`,
    `availableBytesForShrink`

- [ ] **Step 1: Write the failing tests** in `Tests/WhisperMeetTests/ShrinkFlowTests.swift`:

```swift
import Foundation
import Testing
@testable import WhisperCore
@testable import WhisperMeet

// F795 — Shrink through the app-level call, over a real temp library. The encoder and decoder are
// seams (F47), so each test can make the encode succeed, fail or lie about its length. The order is
// the claim: nothing original is removed until the index names the new file.

/// Records that a `@Sendable` seam ran. A captured `var` cannot be mutated from one.
private final class CallFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var called = false
    func set() { lock.lock(); called = true; lock.unlock() }
    var value: Bool { lock.lock(); defer { lock.unlock() }; return called }
}

@MainActor
private struct Fixture {
    let root: URL
    let model: AppModel
    let id: UUID
    let folder: URL

    // 60 s, so the predicted output (246 KB) is well under a quarter of these small files and the
    // worth-it rule passes; an hour's prediction (14.8 MB) would make them "already compact".
    init(recordingName: String = "meeting.wav", duration: TimeInterval = 60,
         recordingPath: String? = nil, extraFiles: [String: Int] = [:]) throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("ShrinkFlow-\(UUID().uuidString)")
        id = UUID()
        folder = root.appendingPathComponent("Recordings/\(id.uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        // Sparse-free real bytes, sized like an hour so the worth-it rule passes.
        var files: [String: Int] = [recordingName: 3_000_000, "system-audio.f32": 6_000_000,
                                    "microphone-audio.f32": 6_000_000, "source-tracks.json": 100,
                                    "notes.md": 50, "diarization.json": 20]
        files.merge(extraFiles) { $1 }
        for (name, size) in files { try Data(count: size).write(to: folder.appendingPathComponent(name)) }
        model = AppModel(store: MeetingStore(rootDirectory: root), recorder: AudioCaptureEngine(),
                         defaults: UserDefaults(suiteName: "ShrinkFlow.\(UUID().uuidString)")!)
        model.store.upsert(MeetingRecord(
            id: id, title: "Weekly sync", duration: duration,
            recordingPath: recordingPath ?? "Recordings/\(id.uuidString)/\(recordingName)",
            status: .completed, transcriptText: "Hi."))
        // Seams: a fake encode writes a small file; lengths agree unless a test says otherwise.
        model.encodeForShrink = { _, output, _ in try Data(count: 15_000).write(to: output) }
        model.decodedDurationForShrink = { _ in duration }
        model.declaredDurationForShrink = { _ in duration }
        model.availableBytesForShrink = { _ in .max }
    }

    func exists(_ name: String) -> Bool {
        FileManager.default.fileExists(atPath: folder.appendingPathComponent(name).path)
    }

    /// What `meetings.json` says on disk, read without opening a second `MeetingStore`.
    func persistedPath() -> String? {
        let reader = BackupJSONStore<[MeetingRecord]>(
            primaryURL: root.appendingPathComponent("meetings.json"),
            backupURL: root.appendingPathComponent("meetings.backup.json"),
            writer: "test-reader", recordCount: { $0.count })
        return (try? reader.load())??.value.first { $0.id == id }?.recordingPath
    }

    func shrink() async {
        await model.refreshStorage(ids: [id])
        model.requestShrink(ids: [id])
        await model.performShrink(confirmed: true)?.value
    }
}

@Test("Shrink replaces the audio, keeps the rest, and the index names the new file (F795)")
@MainActor
func shrinkReplacesTheAudioAndKeepsEverythingElse() async throws {
    let f = try Fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
    await f.shrink()
    #expect(f.exists("meeting.m4a"))
    for gone in ["meeting.wav", "system-audio.f32", "microphone-audio.f32", "source-tracks.json"] {
        #expect(!f.exists(gone), "\(gone) should be removed")
    }
    #expect(f.exists("notes.md") && f.exists("diarization.json"))
    #expect(f.persistedPath()?.hasSuffix("/meeting.m4a") == true)
    #expect(f.model.alertMessage?.contains("Shrunk") == true)
}

@Test("Nothing original is removed until the saved index names the new file (F795)")
@MainActor
func shrinkSavesTheIndexBeforeRemovingAnything() async throws {
    let f = try Fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
    var pathAtFirstRemoval: String?
    f.model.willRemoveForShrink = { _ in
        if pathAtFirstRemoval == nil { pathAtFirstRemoval = f.persistedPath() }
    }
    await f.shrink()
    #expect(pathAtFirstRemoval?.hasSuffix("/meeting.m4a") == true)
}

@Test("A failed index save keeps every original and leaves no new file (F795)")
@MainActor
func shrinkFailedSaveKeepsEverything() async throws {
    let f = try Fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
    await f.model.refreshStorage(ids: [f.id])
    f.model.requestShrink(ids: [f.id])
    // Another copy commits first, so this session's save loses the compare-and-swap.
    let rival = BackupJSONStore<[MeetingRecord]>(
        primaryURL: f.root.appendingPathComponent("meetings.json"),
        backupURL: f.root.appendingPathComponent("meetings.backup.json"),
        writer: "ffff9999", recordCount: { $0.count })
    let existing = try rival.load()
    _ = try rival.save(existing?.value ?? [], expecting: existing?.token)
    await f.model.performShrink(confirmed: true)?.value
    for kept in ["meeting.wav", "system-audio.f32", "microphone-audio.f32", "source-tracks.json"] {
        #expect(f.exists(kept), "\(kept) must survive a failed save")
    }
    #expect(!f.exists("meeting.m4a"))
}

@Test("A length mismatch or a failed encode changes nothing and leaves no temp files (F795)")
@MainActor
func shrinkVerificationFailureChangesNothing() async throws {
    for mode in ["mismatch", "throws"] {
        let f = try Fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        if mode == "mismatch" {
            f.model.decodedDurationForShrink = { _ in 1_800 }
        } else {
            f.model.encodeForShrink = { _, _, _ in throw AudioTranscoderError.transcodeFailed("boom") }
        }
        await f.shrink()
        #expect(f.exists("meeting.wav") && f.exists("system-audio.f32"), "\(mode)")
        #expect(!f.exists("meeting.m4a"), "\(mode)")
        let hidden = try FileManager.default.contentsOfDirectory(atPath: f.folder.path).filter { $0.hasPrefix(".shrink-") }
        #expect(hidden.isEmpty, "\(mode): \(hidden)")
        #expect(f.model.store.meeting(id: f.id)?.recordingPath.hasSuffix("/meeting.wav") == true)
    }
}

@Test("A refused shrink touches nothing: not its own folder, or a length that can't be read (F795)")
@MainActor
func shrinkRefusalsTouchNothing() async throws {
    // Review Focus 3: a recording outside its own Recordings/<id>/ folder.
    let odd = try Fixture(recordingPath: "Elsewhere/meeting.wav")
    defer { try? FileManager.default.removeItem(at: odd.root) }
    let encoded = CallFlag()
    odd.model.encodeForShrink = { _, _, _ in encoded.set() }
    await odd.shrink()
    #expect(!encoded.value && odd.exists("system-audio.f32"))
    // Review Focus 5: no length anywhere, so the encoder never runs.
    let unknown = try Fixture(duration: 0)
    defer { try? FileManager.default.removeItem(at: unknown.root) }
    unknown.model.declaredDurationForShrink = { _ in nil }
    unknown.model.encodeForShrink = { _, _, _ in encoded.set() }
    await unknown.model.refreshStorage(ids: [unknown.id])
    #expect(unknown.model.shrinkUnavailability(for: try #require(unknown.model.store.meeting(id: unknown.id)))
            == .cannotMeasureLength)
    await unknown.shrink()
    #expect(!encoded.value && unknown.exists("meeting.wav"))
}

@Test("A stale unreferenced meeting.m4a is replaced, not reported as existing (F795)")
@MainActor
func shrinkReplacesAStaleOutputFile() async throws {
    // Review Focus 4: left by an earlier failed save whose cleanup also failed.
    let f = try Fixture(extraFiles: ["meeting.m4a": 7]); defer { try? FileManager.default.removeItem(at: f.root) }
    await f.shrink()
    let size = try f.folder.appendingPathComponent("meeting.m4a").resourceValues(forKeys: [.fileSizeKey]).fileSize
    #expect(size == 15_000)
    #expect(!f.exists("meeting.wav"))
}

@Test("A resumed shrink removes leftovers without encoding again (F795)")
@MainActor
func shrinkResumeRemovesLeftoversOnly() async throws {
    let f = try Fixture(recordingName: "meeting.m4a", extraFiles: ["meeting.wav": 3_000_000])
    defer { try? FileManager.default.removeItem(at: f.root) }
    let encoded = CallFlag()
    f.model.encodeForShrink = { _, _, _ in encoded.set() }
    await f.shrink()
    #expect(!encoded.value)
    #expect(f.exists("meeting.m4a") && !f.exists("meeting.wav") && !f.exists("system-audio.f32"))
}

@Test("Every prefix of the deletion order leaves a folder that looks healthy (F795)")
@MainActor
func shrinkStopAnywhereNeverLooksDamaged() throws {
    let f = try Fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
    // Write a real manifest with matching frame counts, so the check is meaningful.
    let frames = 6_000_000 / 4
    let manifest = """
    {"systemAudio":{"file":"system-audio.f32","frameCount":\(frames)},
     "microphoneAudio":{"file":"microphone-audio.f32","frameCount":\(frames)}}
    """
    try Data(manifest.utf8).write(to: f.folder.appendingPathComponent("source-tracks.json"))
    try WAVWriter.wavData(from: [Float](repeating: 0.1, count: 48_000), sampleRate: 48_000)
        .write(to: f.folder.appendingPathComponent("meeting.wav"))
    try Data(count: 15_000).write(to: f.folder.appendingPathComponent("meeting.m4a"))
    let order = MeetingStoragePlan.removableFiles(in: MeetingStorageMeter.entries(in: f.folder), keeping: "meeting.m4a")
    for entry in order {
        try FileManager.default.removeItem(at: f.folder.appendingPathComponent(entry.name))
        let m4a = f.folder.appendingPathComponent("meeting.m4a")
        let findings = MeetingIntegrityChecker.check(MeetingIntegrityDescriptor(
            recordingURL: m4a, sourceTracks: AppModel.sourceTracks(in: f.folder), indexDurationSeconds: 1,
            rawTracksWithoutManifest: false))
        #expect(!findings.contains { $0.isProblem }, "after removing \(entry.name)")
        #expect(SourceRebuild.offer(in: f.folder, currentDuration: 1) == nil, "after removing \(entry.name)")
    }
}

@Test("A batch shrinks every eligible meeting and names the one that failed (F795)")
@MainActor
func shrinkBatchContinuesPastAFailure() async throws {
    // Review Focus 2.
    let f = try Fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
    let second = UUID()
    let secondFolder = f.root.appendingPathComponent("Recordings/\(second.uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: secondFolder, withIntermediateDirectories: true)
    try Data(count: 3_000_000).write(to: secondFolder.appendingPathComponent("meeting.wav"))
    f.model.store.upsert(MeetingRecord(id: second, title: "Second", duration: 60,
                                       recordingPath: "Recordings/\(second.uuidString)/meeting.wav",
                                       status: .completed, transcriptText: "Hi."))
    let failing = f.folder.appendingPathComponent("meeting.wav").path
    f.model.encodeForShrink = { input, output, _ in
        if input.path == failing { throw AudioTranscoderError.transcodeFailed("boom") }
        try Data(count: 15_000).write(to: output)
    }
    await f.model.refreshStorage(ids: [f.id, second])
    f.model.requestShrink(ids: [f.id, second])
    await f.model.performShrink(confirmed: true)?.value
    #expect(FileManager.default.fileExists(atPath: secondFolder.appendingPathComponent("meeting.m4a").path))
    #expect(f.exists("meeting.wav"))
    #expect(f.model.alertMessage?.contains("Weekly sync") == true)
}

@Test("Backup and Shrink refuse each other (F795)")
@MainActor
func shrinkAndBackupAreExclusive() async throws {
    let f = try Fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
    await f.model.refreshStorage(ids: [f.id])
    f.model.isBackingUpForTesting = true
    #expect(f.model.shrinkUnavailability(for: try #require(f.model.store.meeting(id: f.id))) == .backupRunning)
}
```

  > Two test-only hooks are named here, and Step 3 defines both:
  > - `willRemoveForShrink`, a `(String) -> Void` called on the main actor before each removal. It defaults to doing
  >   nothing.
  > - `isBackingUpForTesting`, a settable mirror of `isBackingUp` under `#if DEBUG`.

- [ ] **Step 2: Run them and watch them fail.**
  - Run: `$ST --filter shrink`
  - Expected: a build error, "has no member 'encodeForShrink'".

- [ ] **Step 3: Implement.**

  First, the stored properties in `AppModel.swift`, next to `sourceRebuildRunningID`:

```swift
    // Shrink (F795). See AppModel+Shrink.swift and docs/MEETING_STORAGE_DESIGN.md.
    @Published var pendingShrink: ShrinkRequest?
    @Published private(set) var shrinkRunningID: UUID?
    /// True while a library backup runs. Nothing recorded this before F795; Shrink must not
    /// delete files a backup is reading, and a backup must not start while Shrink deletes.
    @Published private(set) var isBackingUp = false
    @Published private(set) var storageFacts: [UUID: MeetingStoragePlan.DiskFacts] = [:]
    var encodeForShrink: @Sendable (_ input: URL, _ output: URL, _ workingWAV: URL) throws -> Void = {
        try AudioCompressor.compressSpeech(input: $0, output: $1, workingWAV: $2)
    }
    var decodedDurationForShrink: @Sendable (URL) throws -> TimeInterval = { try DecodedAudio.fullyDecodedDuration(of: $0) }
    var declaredDurationForShrink: @Sendable (URL) -> TimeInterval? = { DecodedAudio.declaredDuration(of: $0) }
    var storageEntries: @Sendable (URL) -> [MeetingStoragePlan.FolderEntry] = { MeetingStorageMeter.entries(in: $0) }
    var availableBytesForShrink: @Sendable (URL) -> Int64? = { url in
        (try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]))?
            .volumeAvailableCapacityForImportantUsage
    }
    /// Called before each file Shrink removes. Lets a test observe the order (F795).
    var willRemoveForShrink: (String) -> Void = { _ in }
    #if DEBUG
    var isBackingUpForTesting: Bool {
        get { isBackingUp }
        set { isBackingUp = newValue }
    }
    #endif
```

  In `backUpLibrary`, after the `guard !isRecordingActive, !isImporting` block:

```swift
        guard shrinkRunningID == nil else {
            alertMessage = "Wait for the meeting being shrunk to finish before backing up the library."
            return
        }
        isBackingUp = true
        defer { isBackingUp = false }
```

  Then create `Sources/WhisperMeet/AppModel+Shrink.swift`:

```swift
import Foundation
import UniformTypeIdentifiers
import WhisperCore

/// Shrink (F795): see each meeting's size, and replace a meeting's audio with one compressed
/// recording. The shape is Rebuild Audio's: request, confirmation, `perform(confirmed:)`, then the
/// heavy work detached and every store mutation on the main actor. docs/MEETING_STORAGE_DESIGN.md.
extension AppModel {
    struct ShrinkRequest: Equatable {
        struct Skipped: Equatable {
            let title: String
            let reason: MeetingStoragePlan.Unavailability
        }
        let meetingIDs: [UUID]
        let titles: [String]
        let currentBytes: Int64
        let predictedBytes: Int64
        let skipped: [Skipped]
        let includesUntranscribed: Bool
        let includesVideo: Bool
    }

    /// The meeting's measured size, or nil before it has been measured.
    func storageBytes(for id: UUID) -> Int64? {
        storageFacts[id].map { MeetingStoragePlan.totalBytes($0.entries) }
    }

    /// The library total over meetings measured so far.
    var measuredLibraryBytes: Int64 {
        MeetingStoragePlan.totalBytes(storageFacts.values.map { .init(name: "", bytes: MeetingStoragePlan.totalBytes($0.entries)) })
    }

    /// Measures these meetings off the main actor and caches what the disk says.
    func refreshStorage(ids: [UUID]) async {
        for id in ids {
            guard let meeting = store.meeting(id: id) else { storageFacts[id] = nil; continue }
            storageFacts[id] = await diskFacts(for: meeting)
        }
    }

    /// Why Shrink can't run for this meeting now, or nil when it can.
    func shrinkUnavailability(for meeting: MeetingRecord) -> MeetingStoragePlan.Unavailability? {
        guard let disk = storageFacts[meeting.id] else { return nil }
        return MeetingStoragePlan.unavailability(disk: disk, live: liveShrinkFacts(for: meeting.id))
    }

    func requestShrink(ids: [UUID]) {
        var eligible: [MeetingRecord] = [], skipped: [ShrinkRequest.Skipped] = []
        var current: Int64 = 0, predicted: Int64 = 0
        for id in ids {
            guard let meeting = store.meeting(id: id), let disk = storageFacts[id] else { continue }
            if let reason = MeetingStoragePlan.unavailability(disk: disk, live: liveShrinkFacts(for: id)) {
                skipped.append(.init(title: meeting.title, reason: reason)); continue
            }
            eligible.append(meeting)
            let total = MeetingStoragePlan.totalBytes(disk.entries)
            let output = MeetingStoragePlan.outputName(forRecordingNamed: disk.recordingName) ?? disk.recordingName
            let reclaim = MeetingStoragePlan.isShrunkCapture(disk.recordingName)
                ? MeetingStoragePlan.totalBytes(MeetingStoragePlan.removableFiles(in: disk.entries, keeping: output))
                : MeetingStoragePlan.reclaimableBytes(in: disk.entries, recordingName: disk.recordingName, outputName: output)
            let encoded = MeetingStoragePlan.isShrunkCapture(disk.recordingName)
                ? 0 : MeetingStoragePlan.predictedOutputBytes(durationSeconds: disk.durationSeconds)
            current = MeetingStoragePlan.totalBytes([.init(name: "", bytes: current), .init(name: "", bytes: total)])
            predicted = MeetingStoragePlan.totalBytes([.init(name: "", bytes: predicted),
                                                       .init(name: "", bytes: Swift.max(0, total - reclaim)),
                                                       .init(name: "", bytes: encoded)])
        }
        guard !eligible.isEmpty else {
            alertMessage = skipped.first.map { "“\($0.title)” can't be shrunk now. \($0.reason.message)" }
                ?? "There is nothing to shrink."
            return
        }
        pendingShrink = ShrinkRequest(
            meetingIDs: eligible.map(\.id), titles: eligible.map(\.title),
            currentBytes: current, predictedBytes: predicted, skipped: skipped,
            includesUntranscribed: eligible.contains { $0.transcriptText.isEmpty },
            includesVideo: eligible.contains {
                UTType(filenameExtension: URL(fileURLWithPath: $0.recordingPath).pathExtension)?.conforms(to: .movie) == true
            }
        )
    }

    func cancelShrink() { pendingShrink = nil }

    /// Runs the confirmed shrink, one meeting at a time. Nil unless `confirmed`; the returned task is
    /// the work, for a caller (a test) that waits for it.
    @discardableResult
    func performShrink(confirmed: Bool) -> Task<Void, Never>? {
        guard confirmed, let request = pendingShrink else { return nil }
        pendingShrink = nil
        return Task {
            var lines: [String] = []
            for id in request.meetingIDs {
                lines.append(await shrinkOne(id: id).sentence)
            }
            lines += request.skipped.map { "“\($0.title)” was skipped. \($0.reason.message)" }
            alertMessage = lines.joined(separator: "\n\n")
        }
    }

    enum ShrinkOutcome {
        case shrunk(title: String, before: Int64, after: Int64, unremoved: Int)
        case alreadyCompact(title: String)
        case refused(title: String, reason: MeetingStoragePlan.Unavailability)
        case failed(title: String, message: String)

        var sentence: String {
            let size = { (bytes: Int64) in ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file) }
            switch self {
            case let .shrunk(title, before, after, unremoved):
                var text = "Shrunk “\(title)” from \(size(before)) to \(size(after))."
                if unremoved > 0 {
                    text += " \(unremoved) file(s) could not be removed; Shrink again to finish."
                }
                return text
            case let .alreadyCompact(title):
                return "“\(title)” was not changed: \(MeetingStoragePlan.Unavailability.nothingToGain.message)"
            case let .refused(title, reason):
                return "“\(title)” was not changed. \(reason.message)"
            case let .failed(title, message):
                return "“\(title)” could not be shrunk, and nothing was removed. \(message)"
            }
        }
    }

    // MARK: - The sequence (design, part 2)

    private func shrinkOne(id: UUID) async -> ShrinkOutcome {
        guard let meeting = store.meeting(id: id) else {
            return .failed(title: "A meeting", message: "It is no longer in the library.")
        }
        let disk = await diskFacts(for: meeting)
        storageFacts[id] = disk
        if let reason = MeetingStoragePlan.unavailability(disk: disk, live: liveShrinkFacts(for: id)) {
            return .refused(title: meeting.title, reason: reason)
        }
        guard libraryAcceptsChanges("Shrinking a meeting"),
              let folder = store.ownRecordingFolder(of: meeting),
              let output = MeetingStoragePlan.outputName(forRecordingNamed: disk.recordingName) else {
            return .refused(title: meeting.title, reason: .unsupportedRecording)
        }
        shrinkRunningID = id
        defer { shrinkRunningID = nil }
        let before = MeetingStoragePlan.totalBytes(disk.entries)

        if !MeetingStoragePlan.isShrunkCapture(disk.recordingName) {
            let recordingURL = store.recordingURL(for: meeting)
            let token = UUID().uuidString
            let tempM4A = folder.appendingPathComponent(".shrink-\(token).m4a")
            let tempWAV = folder.appendingPathComponent(".shrink-\(token).wav")
            let encode = encodeForShrink, decode = decodedDurationForShrink, free = availableBytesForShrink
            let expected = disk.durationSeconds
            let needed = MeetingStoragePlan.totalBytes([
                .init(name: "", bytes: Int64(saturating: expected * 32_000)),
                .init(name: "", bytes: MeetingStoragePlan.predictedOutputBytes(durationSeconds: expected)),
                .init(name: "", bytes: 100_000_000),
            ])
            let encoded: Result<Int64, Error> = await Task.detached(priority: .userInitiated) {
                do {
                    if let available = free(folder), available < needed {
                        throw ShrinkFailure.insufficientSpace(needed: needed, available: available)
                    }
                    try encode(recordingURL, tempM4A, tempWAV)
                    let decoded = try decode(tempM4A)
                    guard abs(decoded - expected) <= 0.5 else {
                        throw ShrinkFailure.lengthMismatch(expected: expected, decoded: decoded)
                    }
                    let size = (try? tempM4A.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? nil
                    return .success(Int64(size ?? 0))
                } catch {
                    try? FileManager.default.removeItem(at: tempM4A)
                    try? FileManager.default.removeItem(at: tempWAV)
                    return .failure(error)
                }
            }.value
            let encodedBytes: Int64
            switch encoded {
            case let .failure(error):
                return .failed(title: meeting.title, message: error.localizedDescription)
            case let .success(bytes):
                encodedBytes = bytes
            }
            let reclaim = MeetingStoragePlan.reclaimableBytes(in: disk.entries, recordingName: disk.recordingName, outputName: output)
            guard MeetingStoragePlan.isWorthShrinking(encodedBytes: encodedBytes, reclaimableBytes: reclaim) else {
                try? FileManager.default.removeItem(at: tempM4A)
                return .alreadyCompact(title: meeting.title)
            }
            // Commit (design, step 6).
            let final = folder.appendingPathComponent(output)
            do {
                if FileManager.default.fileExists(atPath: final.path) {
                    _ = try FileManager.default.replaceItemAt(final, withItemAt: tempM4A)
                } else {
                    try FileManager.default.moveItem(at: tempM4A, to: final)
                }
            } catch {
                try? FileManager.default.removeItem(at: tempM4A)
                return .failed(title: meeting.title, message: error.localizedDescription)
            }
            if output.lowercased() != disk.recordingName.lowercased() {
                let relative = (meeting.recordingPath as NSString).deletingLastPathComponent + "/" + output
                guard store.replaceRecordingPath(id: id, with: relative) else {
                    try? FileManager.default.removeItem(at: final)
                    return .failed(title: meeting.title,
                                   message: store.storageErrorMessage ?? "The library could not be saved.")
                }
            }
        }

        // Delete (design, step 7), in the planner's order, only names on its list.
        let removable = MeetingStoragePlan.removableFiles(in: storageEntries(folder), keeping: output)
        var unremoved = 0
        for entry in removable {
            willRemoveForShrink(entry.name)
            let url = folder.appendingPathComponent(entry.name)
            do {
                try await Task.detached { try FileManager.default.removeItem(at: url) }.value
            } catch {
                unremoved += 1
            }
        }
        let after = await diskFacts(for: store.meeting(id: id) ?? meeting)
        storageFacts[id] = after
        return .shrunk(title: meeting.title, before: before,
                       after: MeetingStoragePlan.totalBytes(after.entries), unremoved: unremoved)
    }

    enum ShrinkFailure: LocalizedError {
        case insufficientSpace(needed: Int64, available: Int64)
        case lengthMismatch(expected: TimeInterval, decoded: TimeInterval)
        var errorDescription: String? {
            let size = { (b: Int64) in ByteCountFormatter.string(fromByteCount: b, countStyle: .file) }
            switch self {
            case let .insufficientSpace(needed, available):
                return "Shrinking needs about \(size(needed)) free while it works, and \(size(available)) is available."
            case let .lengthMismatch(expected, decoded):
                return "The compressed copy was \(TranscriptFormatter.clock(decoded)) long instead of \(TranscriptFormatter.clock(expected)), so it was discarded."
            }
        }
    }

    // MARK: - Facts

    private func liveShrinkFacts(for id: UUID) -> MeetingStoragePlan.LiveFacts {
        var live = MeetingStoragePlan.LiveFacts()
        live.libraryReadOnly = store.isDegraded
        live.captureOrImportInProgress = isRecordingActive || isImporting
        live.meetingBusy = transcription.contains(id) || diarizationRunningID == id
            || segmentReTranscriptionRunningID == id || sourceRebuildRunningID == id
        live.backupRunning = isBackingUp
        live.anotherShrinkRunning = shrinkRunningID != nil
        return live
    }

    /// Reads the disk for one meeting, off the main actor.
    private func diskFacts(for meeting: MeetingRecord) async -> MeetingStoragePlan.DiskFacts {
        let recordingURL = store.recordingURL(for: meeting)
        let folder = store.ownRecordingFolder(of: meeting)
        let descriptor = integrityDescriptorForShrink(meeting)
        let entries = storageEntries, declared = declaredDurationForShrink
        let indexDuration = meeting.duration
        return await Task.detached(priority: .utility) {
            let name = recordingURL.lastPathComponent
            let exists = FileManager.default.fileExists(atPath: recordingURL.path)
            let problem = descriptor.map { MeetingIntegrityChecker.check($0).contains { $0.isProblem } } ?? false
            let directory = folder ?? recordingURL.deletingLastPathComponent()
            let rebuild = SourceRebuild.offer(in: directory, currentDuration: indexDuration) != nil
            let length = declared(recordingURL) ?? (indexDuration > 0 ? indexDuration : 0)
            return MeetingStoragePlan.DiskFacts(
                recordingName: name, recordingExists: exists,
                inOwnFolder: folder != nil && recordingURL.deletingLastPathComponent().standardizedFileURL.path
                    == folder?.standardizedFileURL.path,
                hasIntegrityProblem: problem, rebuildOffered: rebuild,
                durationSeconds: length, entries: folder.map(entries) ?? [])
        }.value
    }
}
```

  `diskFacts` needs the private `integrityDescriptor(for:)`. Add a one-line internal forwarder next to it in
  `AppModel.swift`:

```swift
    /// The same read-only descriptor Verify Library builds, for Shrink's damage refusal (F795).
    func integrityDescriptorForShrink(_ meeting: MeetingRecord) -> MeetingIntegrityDescriptor? {
        integrityDescriptor(for: meeting)
    }
```

  > Check before compiling:
  > - Do `isImporting`, `segmentReTranscriptionRunningID` and `diarizationRunningID` exist under those exact names?
  >   (`grep -n` each.)
  > - Is `store.storageErrorMessage` the store's message property?
  > - Is `AppModel.sourceTracks(in:)` static and internal? It is `static func` at about `:6940`.
  >
  > If `UniformTypeIdentifiers` is not yet imported anywhere in WhisperMeet, the import is fine: that target is not
  > under the WhisperCore allowlist guard.

- [ ] **Step 4: Run them and watch them pass.**
  - Run: `$ST --filter shrink`
  - Expected: every `shrink*` test passes, including Task 2's.
  - Then run `$ST --filter "Backup|backup"` to check that the backup guard did not regress.

- [ ] **Step 5: Check the discrimination.**
  - Move the `store.replaceRecordingPath` call to *after* the delete loop.
  - Run `shrinkSavesTheIndexBeforeRemovingAnything`, and confirm it FAILS.
  - Restore the call.
  - Run `git diff` to confirm no mutation remains.

- [ ] **Step 6: Commit.**

```bash
git add Sources/WhisperMeet/AppModel.swift Sources/WhisperMeet/AppModel+Shrink.swift \
  Tests/WhisperMeetTests/ShrinkFlowTests.swift
git commit -m "feat(meetings): shrink a meeting, saving the index before any audio is removed (F795)"
```

---

### Task 7: The interface (F795)

**Files:**
- Create: `Sources/WhisperMeet/MeetingStorageView.swift` for the Storage sheet.
- Modify: `Sources/WhisperMeet/ContentView.swift`:
  - `header(_:)` at `:3412-3460`: a storage chip, and a Shrink… button that carries the reason in its help;
  - `TranscriptDetailView`'s dialogs, beside the Rebuild Audio dialog at `:2964-2981`: the Shrink confirmation;
  - the timeline view's `.id(meetingID)` at `:3744`, which must also key on `recordingPath`;
  - Settings ▸ Meeting library at `:1584-1600`: the Storage row and the Show Storage… sheet.
- Test: `Tests/WhisperMeetTests/ShrinkReachabilityTests.swift`

**Interfaces:**
- Consumes: Task 6's API.

- [ ] **Step 1: Write the failing source guard.** This is the F306 shape, with comments stripped.

```swift
import Foundation
import Testing
@testable import WhisperMeet

// F795 — the target cannot render views (F174), so reachability is asserted on the source, with
// comments stripped so a sentence about the button cannot satisfy it (F285).

@Test("The meeting page and Settings reach Shrink and its gate (F795)")
func shrinkIsReachableFromTheInterface() throws {
    let content = try SourceAssertion.uncommentedSource("Sources/WhisperMeet/ContentView.swift")
    #expect(content.contains("model.requestShrink(ids:"))
    #expect(content.contains("model.performShrink(confirmed: true)"))
    #expect(content.contains("model.shrinkUnavailability(for:"))
    #expect(content.contains("model.storageBytes(for:"))
    #expect(content.contains("MeetingStorageView("))
    let sheet = try SourceAssertion.uncommentedSource("Sources/WhisperMeet/MeetingStorageView.swift")
    #expect(sheet.contains("model.requestShrink(ids:"))
    #expect(sheet.contains("model.refreshStorage(ids:"))
}

@Test("The transcript player reloads when a shrink changes the recording's path (F795)")
func shrinkReloadsThePlayer() throws {
    let content = try SourceAssertion.uncommentedSource("Sources/WhisperMeet/ContentView.swift")
    #expect(content.contains(".id([meetingID.uuidString, meeting.recordingPath])"))
}
```

- [ ] **Step 2: Run it and watch it fail.**
  - Run: `$ST --filter "shrinkIsReachableFromTheInterface|shrinkReloadsThePlayer"`
  - Expected: FAIL. The build fails if `MeetingStorageView.swift` is missing, because `uncommentedSource` throws;
    either way it is red.

- [ ] **Step 3: Implement the header.**
  - In `header(_:)`'s `HStack`, after the confidence chip and before `Spacer()`:

```swift
                if let bytes = model.storageBytes(for: meeting.id) {
                    metadataChip(ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file),
                                 systemImage: "internaldrive")
                        .accessibilityLabel("Storage: \(ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file))")
                }
```

  - After the `Show Recording in Finder` button:

```swift
                let shrinkReason = model.shrinkUnavailability(for: meeting)
                if shrinkReason != .alreadyShrunk {
                    Button("Shrink…") { model.requestShrink(ids: [meeting.id]) }
                        .disabled(shrinkReason != nil || model.storageBytes(for: meeting.id) == nil)
                        .help(shrinkReason?.message ?? "Replace this meeting's audio with a compressed copy and delete the original.")
                }
```

  - On the header's outer `VStack`, add the measuring hook. The key changes whenever a stop, rebuild or shrink
    changes the facts:

```swift
        .task(id: [meeting.id.uuidString, meeting.recordingPath, meeting.status.rawValue]) {
            await model.refreshStorage(ids: [meeting.id])
        }
```

- [ ] **Step 4: Implement the confirmation.** Put it next to the Rebuild Audio `confirmationDialog` in
  `TranscriptDetailView`. Then, in `AppModel+Shrink.swift`, add the two static copy functions. They are testable
  because they are static.

```swift
        .confirmationDialog(
            model.pendingShrink.map(AppModel.shrinkConfirmationTitle) ?? "",
            isPresented: .init(
                get: { model.pendingShrink != nil },
                set: { if !$0 { model.cancelShrink() } }
            ),
            titleVisibility: .visible
        ) {
            Button("Shrink", role: .destructive) { model.performShrink(confirmed: true) }
            Button("Cancel", role: .cancel) { model.cancelShrink() }
        } message: {
            if let request = model.pendingShrink { Text(AppModel.shrinkConfirmationMessage(request)) }
        }
```

```swift
    static func shrinkConfirmationTitle(_ request: ShrinkRequest) -> String {
        request.meetingIDs.count == 1 ? "Shrink “\(request.titles[0])”?" : "Shrink \(request.meetingIDs.count) meetings?"
    }

    static func shrinkConfirmationMessage(_ request: ShrinkRequest) -> String {
        let size = { (b: Int64) in ByteCountFormatter.string(fromByteCount: b, countStyle: .file) }
        var text = "This replaces the recording with compressed audio: about \(size(request.currentBytes)) → about \(size(request.predictedBytes)). "
            + "The original recording and its raw tracks are deleted permanently. "
            + "Playback, transcription and summaries keep working. "
            + "Rebuild Audio and re-running a single segment will no longer be available."
        if request.includesUntranscribed {
            text += " A meeting that hasn't been transcribed yet will be transcribed from the compressed audio."
        }
        if request.includesVideo { text += " For a video, the picture is removed; only the audio is kept." }
        if !request.skipped.isEmpty { text += " \(request.skipped.count) selected meeting(s) can't be shrunk and will be skipped." }
        return text
    }
```

  Add a copy test to `ShrinkFlowTests.swift`. It asserts the three promises the confirmation makes: what changes,
  that the deletion is permanent, and what is lost.

```swift
@Test("The confirmation says what changes, that it is permanent, and what is lost (F795)")
func shrinkConfirmationStatesItsPromises() {
    let request = AppModel.ShrinkRequest(meetingIDs: [UUID()], titles: ["Weekly sync"], currentBytes: 1_728_000_000,
                                         predictedBytes: 14_800_000, skipped: [], includesUntranscribed: false,
                                         includesVideo: true)
    let text = AppModel.shrinkConfirmationMessage(request)
    #expect(AppModel.shrinkConfirmationTitle(request) == "Shrink “Weekly sync”?")
    #expect(text.contains("deleted permanently"))
    #expect(text.contains("Rebuild Audio"))
    #expect(text.contains("picture is removed"))
}
```

- [ ] **Step 5: Implement the player key.** At `:3744`, replace `.id(meetingID)` with
  `.id([meetingID.uuidString, meeting.recordingPath])`. Add this comment:

  > The player's `StateObject` holds the recording URL it was built with. After Shrink (F795) changes the path, the
  > old file is gone, so the view is keyed on the path too.

  Check that `meeting` is in scope at that line. If the bound name differs, use it, and update the guard's literal
  to match.

- [ ] **Step 6: Implement the Settings row and the sheet.**
  - In the `Meeting library` section, after the Verify Library caption:

```swift
                HStack {
                    Label(storageSummary, systemImage: "internaldrive")
                    Spacer()
                    Button("Show Storage…") { showingStorage = true }
                        .buttonStyle(.bordered)
                }
                Text("Lists each meeting by the space it uses. Shrink replaces a meeting's audio with a compressed copy and deletes the original; it only runs when you press it.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
```

  - Add `@State private var showingStorage = false` to `SettingsView`.
  - Add `.sheet(isPresented: $showingStorage) { MeetingStorageView(model: model, store: model.store) }` on the
    `Form`.
  - Add a computed `storageSummary`, for example "Meetings use 48.2 GB", which reads "Meeting storage" before the
    sheet has measured.
  - Add `.task { await model.refreshStorage(ids: model.store.meetings.map(\.id)) }` on the row.
  - Then create `Sources/WhisperMeet/MeetingStorageView.swift`:

```swift
import SwiftUI
import WhisperCore

/// Every meeting by the space it uses, largest first, with Shrink per row and for a selection (F795).
/// Presentation only: every decision is `AppModel`'s.
struct MeetingStorageView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var store: MeetingStore
    @Environment(\.dismiss) private var dismiss
    @State private var selection: Set<UUID> = []

    private var rows: [MeetingRecord] {
        store.meetings.sorted { (model.storageBytes(for: $0.id) ?? -1) > (model.storageBytes(for: $1.id) ?? -1) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Meeting storage").font(.title2.bold())
            Text("Meetings use \(ByteCountFormatter.string(fromByteCount: model.measuredLibraryBytes, countStyle: .file)).")
                .foregroundStyle(.secondary)
            List(rows, id: \.id, selection: $selection) { meeting in
                HStack {
                    VStack(alignment: .leading) {
                        Text(meeting.title)
                        if let reason = model.shrinkUnavailability(for: meeting), reason != .alreadyShrunk {
                            Text(reason.message).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                    Text(meeting.createdAt.formatted(date: .abbreviated, time: .omitted)).foregroundStyle(.secondary)
                    Text(model.storageBytes(for: meeting.id).map {
                        ByteCountFormatter.string(fromByteCount: $0, countStyle: .file)
                    } ?? "Measuring…")
                        .monospacedDigit()
                        .frame(minWidth: 80, alignment: .trailing)
                    Button(model.shrinkUnavailability(for: meeting) == .alreadyShrunk ? "Shrunk" : "Shrink…") {
                        model.requestShrink(ids: [meeting.id])
                    }
                    .disabled(model.shrinkUnavailability(for: meeting) != nil || model.storageBytes(for: meeting.id) == nil)
                }
            }
            .frame(minWidth: 620, minHeight: 360)
            HStack {
                Button("Shrink Selected…") { model.requestShrink(ids: Array(selection)) }
                    .disabled(selection.isEmpty || model.shrinkRunningID != nil)
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .task { await model.refreshStorage(ids: store.meetings.map(\.id)) }
        .confirmationDialog(
            model.pendingShrink.map(AppModel.shrinkConfirmationTitle) ?? "",
            isPresented: .init(get: { model.pendingShrink != nil }, set: { if !$0 { model.cancelShrink() } }),
            titleVisibility: .visible
        ) {
            Button("Shrink", role: .destructive) { model.performShrink(confirmed: true) }
            Button("Cancel", role: .cancel) { model.cancelShrink() }
        } message: {
            if let request = model.pendingShrink { Text(AppModel.shrinkConfirmationMessage(request)) }
        }
    }
}
```

  > Two dialogs bound to `pendingShrink` could both present: the meeting page's and the sheet's. While the sheet is
  > open, the page's dialog must not also present. Guard the page's `get:` with
  > `model.pendingShrink != nil && !model.isStorageSheetOpen`. Add `@Published var isStorageSheetOpen = false` to
  > `AppModel`, set by the sheet's `.onAppear` and `.onDisappear`. Add `isStorageSheetOpen` to the source guard's
  > expectations.
  >
  > The alert that reports the outcome is `alertMessage`. Check that it presents while the sheet is open; if it
  > presents only on the main window, also show the outcome inside the sheet with a `Text(model.alertMessage ?? "")`.

- [ ] **Step 7: Run it and watch it pass.**
  - Run: `$ST --filter "shrinkIsReachableFromTheInterface|shrinkReloadsThePlayer|shrinkConfirmationStatesItsPromises"`
  - Expected: PASS.
  - Then run `swift build` with warnings as errors, the way the gate does: `zsh Scripts/quality-check.sh` runs it
    in Task 9.

- [ ] **Step 8: Commit.**

```bash
git add Sources/WhisperMeet/ContentView.swift Sources/WhisperMeet/MeetingStorageView.swift \
  Sources/WhisperMeet/AppModel.swift Sources/WhisperMeet/AppModel+Shrink.swift \
  Tests/WhisperMeetTests/ShrinkReachabilityTests.swift Tests/WhisperMeetTests/ShrinkFlowTests.swift
git commit -m "feat(ui): show each meeting's storage and offer Shrink on its page and in Settings (F795)"
```

---

### Task 8: Accuracy measured, and the docs (F795)

**Files:**
- Create: `Scripts/bench/shrink_accuracy.py`, a reusable measurement.
- Modify: `docs/PRODUCT_SPEC.md`, `docs/RECOVERY.md`, `README.md`, `docs/README.md` (the plan's row).

- [ ] **Step 1: Write the measurement script.**
  - For each clip in `Scripts/bench/clips/*.wav`:
    1. upsample to 48 kHz with `afconvert -f WAVE -d LEI16@48000`, which is what a capture is;
    2. shrink it with the two-step recipe;
    3. transcribe both versions with the installed CLI: `…/Runtime/venv/bin/whisper <file> --model large
       --model_dir …/Models --task transcribe --output_format json --output_dir <tmp>`;
    4. score both against `references.json` with `benchmark.py`'s `score()`, importing it the way `benchmark.py`
       loads `qwen_meeting_engine`.
  - Print one row per clip, with the error rate before, after, and the delta.
  - Run it with the bench venv's Python if `jiwer` and `opencc` are only there:
    `~/Library/Caches/WhisperMeet-Bench/venv/bin/python`.

- [ ] **Step 2: Run it. Paste the full table into the log.**
  - **Acceptance:** no clip's error rate rises by more than 1 percentage point.
  - If one does, set `AudioCompressor.bitRate = 48_000` and run it again.
  - If 24 kbps also passes, report that, and leave the choice to the user.

- [ ] **Step 3: Run Qwen once on a shrunk clip.** Use the throwaway env-gated test from Task 1, pointed at a
  shrunk `.m4a`. Delete the test afterwards.

- [ ] **Step 4: Edit the docs.**
  - `PRODUCT_SPEC.md:11`: append "…, until the user explicitly shrinks a meeting (Shrink Meeting replaces its audio
    with one compressed recording)."
  - `PRODUCT_SPEC.md`, the Recovery boundary: "**Cancel Recording**, **Delete Meeting** and **Shrink Meeting** are
    explicit user actions and remain intentionally destructive; Shrink deletes the original audio and raw tracks
    after its compressed copy is verified and saved."
  - `RECOVERY.md`: add a "A shrunk meeting" subsection after the file list. It holds `meeting.m4a` (or
    `meeting-recovered.m4a` / `recording.m4a`) plus the text files, and no raw tracks or manifest. Rebuild Audio
    and segment re-run (F660) are unavailable. A backup made before shrinking still holds the originals.
  - `README.md`: one line under the features list.

- [ ] **Step 5: Commit.**

```bash
git add Scripts/bench/shrink_accuracy.py docs/PRODUCT_SPEC.md docs/RECOVERY.md README.md docs/README.md
git commit -m "docs(meetings): Shrink is a third deliberate deletion; accuracy measured (F795)"
```

---

### Task 9: Gate, review, close (F795, F796)

- [ ] **Step 1: Run the full gate.**
  - Run `zsh Scripts/quality-check.sh 2>&1 | tee /private/tmp/claude-501/-Users-simonwang-Documents-Whisper/8805d284-c117-4530-9535-c15b6760517a/scratchpad/f795-gate.log`,
    then read the file.
  - Expected: `Quality check passed`, and a test count above 2446 plus the new tests.
- [ ] **Step 2: Get an independent whole-branch review.** Use a fresh `opus` reviewer agent, given:
  - the spec;
  - this plan;
  - `git diff main...f795-meeting-storage`;
  - the instruction to revert each fix and confirm its test fails.

  Fix what it confirms, and run the gate again.
- [ ] **Step 3: Do the manual click-through on an installed build.** This needs the user's go-ahead, because it
  replaces `/Applications/WhisperMeet.app`. Use a synthetic meeting only, never a real one:
  - the storage chip;
  - Shrink… with its confirmation;
  - the result alert;
  - the Settings row and the sheet;
  - Shrink Selected;
  - a disabled row's reason.
- [ ] **Step 4: Merge and close.**
  - Fast-forward `main` to the branch.
  - Close F796 and F795 in `docs/TICKET_LOG.md` with the real outputs: red, green, gate, the accuracy table and the
    Qwen run.
  - F795's Reachability line: header `Shrink…` → `AppModel.requestShrink(ids:)` → confirmation →
    `performShrink(confirmed:)` → `shrinkOne(id:)`; and Settings ▸ Meeting library ▸ Show Storage… →
    `MeetingStorageView` → the same.
  - Gaps:
    - segment re-run waits on F660;
    - folder rebuild gives `meeting.m4a` a 0 duration, with the Task 5 finding;
    - Not planned: a GUI test, because the target has no view-render harness.
  - Write the CHANGELOG entry.
  - Do not push unless the user asks. When they do, run `Scripts/verify-push.sh` and observe CI.
