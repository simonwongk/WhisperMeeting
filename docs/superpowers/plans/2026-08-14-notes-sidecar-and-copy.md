# Notes Sidecar + Copyable Summaries Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Every transcript and summary is automatically mirrored as a human-readable `notes.md` beside its audio, and summary content is selectable and copyable per section.

**Architecture:** `MeetingStore` gains a single markdown composer (shared with the manual Export… button so they can never drift) and a debounced, compare-first sidecar writer hooked into the four mutation methods, plus an idempotent startup backfill called from `AppModel.performStartupRecovery` after the degraded early-return. The sidecar is write-only insurance: never read by the app, never written while degraded, never creates folders, failures silent by design.

**Tech Stack:** Swift 6 toolchain in Swift 5 language mode, SwiftPM, SwiftUI, swift-testing (`@Test`/`#expect`), macOS 15+.

**Design:** `docs/superpowers/specs/2026-08-14-notes-sidecar-and-copy-design.md`

---

## Global Constraints

- Tests are swift-testing (`@Test("display name")`, `#expect`, `#require`) — never XCTest.
- `MeetingStore` and `AppModel` are `@MainActor`. `Sources/WhisperCore/` is Foundation-only and `Sendable` — this plan does not touch it.
- Never write to `~/Library/Application Support/WhisperMeet/` from a test; temp dir + UUID + `defer` cleanup.
- Document invariants in comments with the ticket id `(F198)`.
- **Test command** (Command Line Tools only; plain `swift test` cannot find swift-testing):

```bash
FW=/Library/Developer/CommandLineTools/Library/Developer/Frameworks
LIB=/Library/Developer/CommandLineTools/Library/Developer/usr/lib
swift test --disable-sandbox --no-parallel \
  -Xswiftc -F -Xswiftc "$FW" \
  -Xlinker -rpath -Xlinker "$FW" \
  -Xlinker -rpath -Xlinker "$LIB" --filter "<name>"
```

  Keep flags byte-identical between runs so SwiftPM does not rebuild.
- **`--filter` matches the Swift FUNCTION name** (case-sensitive regex), not the `@Test("...")` display string; a display-name filter matches zero tests and still exits 0. Always check the reported count.
- Current full-suite baseline: **488 passing**.
- **Never run `Scripts/format-docs.py`** (ignores arguments, reformats every doc). **Never use `git checkout <file>`** to undo an experiment; use a scratchpad copy.

## File Structure

| File | Responsibility |
|---|---|
| `Sources/WhisperMeet/MeetingStore.swift` | `notesMarkdown(for:)`, the debounced compare-first sidecar writer, backfill method. |
| `Sources/WhisperMeet/AppModel.swift` | One call: backfill from `performStartupRecovery` after the degraded early-return. |
| `Sources/WhisperMeet/ContentView.swift` | Export… reuses `notesMarkdown(for:)`; text selection; per-section copy buttons. |
| `Tests/WhisperMeetTests/NotesSidecarTests.swift` *(new)* | Sidecar behaviour: debounced write, compare-first, degraded refusal, audio-less skip, backfill idempotence. |

---

### Task 1: One markdown composer, shared by Export… and the sidecar

**Files:**
- Modify: `Sources/WhisperMeet/MeetingStore.swift` (add near `recordingURL(for:)`)
- Modify: `Sources/WhisperMeet/ContentView.swift:3018-3032` (`exportMeetingNotes`)
- Test: `Tests/WhisperMeetTests/NotesSidecarTests.swift` *(new)*

- [ ] **Step 1: Write the failing test**

```swift
import Foundation
import Testing
@testable import WhisperMeet
@testable import WhisperCore

@MainActor
private func makeStore() throws -> (MeetingStore, URL) {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("WhisperMeetSidecar-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    // Large debounce so tests drive flushes explicitly (the F40 pattern).
    return (MeetingStore(rootDirectory: root, transcriptWriteDebounce: 999), root)
}

@MainActor
private func seedMeeting(in store: MeetingStore, root: URL, transcript: String = "hello world") throws -> MeetingRecord {
    let id = UUID()
    let directory = root.appendingPathComponent("Recordings/\(id.uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    try Data("audio".utf8).write(to: directory.appendingPathComponent("meeting.wav"))
    let meeting = MeetingRecord(
        id: id,
        title: "Planning sync",
        recordingPath: "Recordings/\(id.uuidString)/meeting.wav",
        status: .completed,
        transcriptText: transcript
    )
    store.upsert(meeting)
    return meeting
}

@Test("The sidecar composer produces exactly what the manual export produces")
@MainActor
func notesMarkdownMatchesTheExporter() throws {
    let (store, root) = try makeStore()
    defer { try? FileManager.default.removeItem(at: root) }
    let meeting = try seedMeeting(in: store, root: root)

    let composed = store.notesMarkdown(for: meeting)
    let direct = MeetingNotesExporter.markdown(
        title: meeting.title,
        dateText: meeting.createdAt.formatted(date: .abbreviated, time: .shortened),
        durationSeconds: meeting.duration,
        languageCode: meeting.languageCode,
        summary: meeting.summary,
        transcriptText: meeting.transcriptText,
        notes: meeting.notes,
        markers: meeting.orderedMarkers,
        segments: meeting.segments
    )
    #expect(composed == direct)
    #expect(composed.contains("Planning sync"))
    #expect(composed.contains("hello world"))
}
```

- [ ] **Step 2: Run to verify it fails**

Run with `--filter "notesMarkdownMatchesTheExporter"`. Expected: FAIL to compile — `notesMarkdown(for:)` does not exist.

- [ ] **Step 3: Implement**

Add to `MeetingStore`:

```swift
    /// The one composition of a meeting's human-readable notes document (F198). The manual Export…
    /// button and the automatic sidecar both call this, so the two can never drift.
    func notesMarkdown(for meeting: MeetingRecord) -> String {
        MeetingNotesExporter.markdown(
            title: meeting.title,
            dateText: meeting.createdAt.formatted(date: .abbreviated, time: .shortened),
            durationSeconds: meeting.duration,
            languageCode: meeting.languageCode,
            summary: meeting.summary,
            transcriptText: meeting.transcriptText,
            notes: meeting.notes,
            markers: meeting.orderedMarkers,
            segments: meeting.segments
        )
    }
```

Then replace the body of `ContentView.exportMeetingNotes(meeting:)` (`:3018-3032`) so it composes through the store:

```swift
    private func exportMeetingNotes(meeting: MeetingRecord) {
        let current = store.meeting(id: meeting.id) ?? meeting
        saveExport(store.notesMarkdown(for: current), suggestedName: "\(current.title) Notes", fileExtension: "md")
    }
```

- [ ] **Step 4: Run to verify it passes**, then the full suite. Expected: PASS, 488 + 1.

- [ ] **Step 5: Commit**

```bash
git add Sources/WhisperMeet/MeetingStore.swift Sources/WhisperMeet/ContentView.swift Tests/WhisperMeetTests/NotesSidecarTests.swift
git commit -m "refactor(meetings): one composer for the notes document (F198)"
```

---

### Task 2: The debounced, compare-first sidecar writer

**Files:**
- Modify: `Sources/WhisperMeet/MeetingStore.swift`
- Test: `Tests/WhisperMeetTests/NotesSidecarTests.swift` (append)

- [ ] **Step 1: Write the failing tests**

```swift
@Test("A transcript edit writes notes.md beside the audio after the flush")
@MainActor
func transcriptEditWritesTheSidecar() throws {
    let (store, root) = try makeStore()
    defer { try? FileManager.default.removeItem(at: root) }
    let meeting = try seedMeeting(in: store, root: root)

    store.editTranscript(id: meeting.id, text: "corrected text")
    store.flushPendingEdits()
    store.flushPendingNotesSidecars()

    let sidecar = root.appendingPathComponent("Recordings/\(meeting.id.uuidString)/notes.md")
    let written = try String(contentsOf: sidecar, encoding: .utf8)
    let current = try #require(store.meeting(id: meeting.id))
    #expect(written == store.notesMarkdown(for: current))
    #expect(written.contains("corrected text"))
}

@Test("Identical content is not rewritten — a pin toggle leaves the sidecar untouched")
@MainActor
func identicalContentIsNotRewritten() throws {
    let (store, root) = try makeStore()
    defer { try? FileManager.default.removeItem(at: root) }
    let meeting = try seedMeeting(in: store, root: root)
    store.flushPendingNotesSidecars()
    let before = store.sidecarWriteCount

    // A pin change routes through the hooked `update(id:)` here; the pin is not part of the notes
    // document, so the composed content is identical and the file must not be rewritten.
    store.update(id: meeting.id) { $0.pinned = true }
    store.flushPendingNotesSidecars()

    #expect(store.sidecarWriteCount == before)
}

@Test("A meeting whose recording folder is missing is skipped without creating anything")
@MainActor
func audioLessMeetingIsSkipped() throws {
    let (store, root) = try makeStore()
    defer { try? FileManager.default.removeItem(at: root) }
    let meeting = MeetingRecord(
        id: UUID(),
        title: "Transcript only",
        recordingPath: "",
        status: .completed,
        transcriptText: "kept text"
    )
    store.upsert(meeting)

    store.flushPendingNotesSidecars()

    #expect(store.sidecarWriteCount == 0)
    #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("Recordings").path))
}
```

- [ ] **Step 2: Run to verify they fail**

`--filter "transcriptEditWritesTheSidecar"` etc. Expected: FAIL to compile — `flushPendingNotesSidecars`/`sidecarWriteCount` do not exist.

- [ ] **Step 3: Implement**

Add to `MeetingStore`, near `pendingIndexFlush` (`:246`):

```swift
    /// Meetings whose notes sidecar is stale. Flushed together, debounced like the index (F40).
    private var pendingSidecarIDs: Set<UUID> = []
    private var pendingSidecarFlush: Task<Void, Never>?
    /// Count of sidecar files actually written — lets tests assert the compare-first rule.
    private(set) var sidecarWriteCount = 0
```

The scheduler and writer:

```swift
    /// Marks a meeting's notes.md stale and schedules the debounced rewrite (F198).
    private func scheduleNotesSidecarWrite(for id: UUID) {
        pendingSidecarIDs.insert(id)
        pendingSidecarFlush?.cancel()
        let delay = transcriptWriteDebounce
        pendingSidecarFlush = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled else { return }
            await MainActor.run { self?.flushPendingNotesSidecars() }
        }
    }

    /// Writes every pending notes.md now. Write-only insurance for the text a wiped index would
    /// otherwise take with it (F198): the app never reads these back, they are regenerable from the
    /// index at any time, and a failed write therefore loses nothing — which is why failures here are
    /// silent BY DESIGN, unlike the F187 fixes, where the failing store was the source of truth.
    /// Never writes while degraded, and never creates a folder.
    func flushPendingNotesSidecars() {
        pendingSidecarFlush?.cancel()
        pendingSidecarFlush = nil
        guard !isDegraded else { return }        // F187's read-only promise stays absolute
        let ids = pendingSidecarIDs
        pendingSidecarIDs = []
        for id in ids {
            guard let meeting = meeting(id: id), !meeting.recordingPath.isEmpty else { continue }
            let directory = recordingURL(for: meeting).deletingLastPathComponent()
            guard isWithinLibrary(directory),
                  FileManager.default.fileExists(atPath: directory.path) else { continue }
            let composed = notesMarkdown(for: meeting)
            let sidecarURL = directory.appendingPathComponent("notes.md")
            if let existing = try? String(contentsOf: sidecarURL, encoding: .utf8), existing == composed {
                continue
            }
            do {
                try composed.write(to: sidecarURL, atomically: true, encoding: .utf8)
                sidecarWriteCount += 1
            } catch {
                // Silent by design — see the doc comment above.
            }
        }
    }
```

Hook the four mutators — one line each, after their mutation:
- `upsert(_:)` → `scheduleNotesSidecarWrite(for: record.id)` (use the actual parameter name)
- `update(id:_:)` → `scheduleNotesSidecarWrite(for: id)`
- `editTranscript(id:text:)` → `scheduleNotesSidecarWrite(for: id)`
- `editNotes(id:text:)` → `scheduleNotesSidecarWrite(for: id)`

Also make `flushPendingEdits()` (`:418`) call `flushPendingNotesSidecars()` as its last line, so the existing quit-time flush points (`AppModel.swift:1693`, `ContentView.swift:2218,2943`) cover the sidecar too.

Note `togglePin` (`:433-439`) calls `persistMeetings()` directly and is deliberately **not** hooked — the pin is not part of the notes document. The `identicalContentIsNotRewritten` test above routes its pin change through `update(id:)` for exactly that reason: it exercises the hook while keeping the composed content identical.

- [ ] **Step 4: Run to verify they pass**, then the full suite. Expected: PASS, 488 + 4.

- [ ] **Step 5: Commit**

```bash
git add Sources/WhisperMeet/MeetingStore.swift Tests/WhisperMeetTests/NotesSidecarTests.swift
git commit -m "feat(meetings): mirror each transcript and summary as notes.md beside its audio (F198)"
```

---

### Task 3: Backfill at startup, refused while degraded

**Files:**
- Modify: `Sources/WhisperMeet/MeetingStore.swift`
- Modify: `Sources/WhisperMeet/AppModel.swift` (`performStartupRecovery`, after the degraded early-return block that ends around `:709`)
- Test: `Tests/WhisperMeetTests/NotesSidecarTests.swift` (append)

- [ ] **Step 1: Write the failing tests**

```swift
@Test("Backfill writes a sidecar for every existing meeting, and a second run writes nothing")
@MainActor
func backfillIsIdempotent() throws {
    let (store, root) = try makeStore()
    defer { try? FileManager.default.removeItem(at: root) }
    let a = try seedMeeting(in: store, root: root, transcript: "first meeting")
    let b = try seedMeeting(in: store, root: root, transcript: "second meeting")

    store.backfillNotesSidecars()
    let afterFirst = store.sidecarWriteCount
    #expect(afterFirst == 2)
    for meeting in [a, b] {
        let sidecar = root.appendingPathComponent("Recordings/\(meeting.id.uuidString)/notes.md")
        #expect(FileManager.default.fileExists(atPath: sidecar.path))
    }

    store.backfillNotesSidecars()
    #expect(store.sidecarWriteCount == afterFirst)
}

@Test("No sidecar is written while the library is read-only")
@MainActor
func noSidecarWhileDegraded() throws {
    let (seedStore, root) = try makeStore()
    let meeting = try seedMeeting(in: seedStore, root: root)
    defer { try? FileManager.default.removeItem(at: root) }
    // Corrupt only the primary; copy it to the backup first so the reopened store still holds the
    // record (`.recoveredFromBackup` — degraded AND populated).
    let primary = root.appendingPathComponent("meetings.json")
    let backup = root.appendingPathComponent("meetings.backup.json")
    try? FileManager.default.removeItem(at: backup)
    try FileManager.default.copyItem(at: primary, to: backup)
    try Data("broken-primary".utf8).write(to: primary)

    let store = MeetingStore(rootDirectory: root, transcriptWriteDebounce: 999)
    #expect(store.isDegraded)
    #expect(!store.meetings.isEmpty)

    store.backfillNotesSidecars()
    store.flushPendingNotesSidecars()

    let sidecar = root.appendingPathComponent("Recordings/\(meeting.id.uuidString)/notes.md")
    #expect(!FileManager.default.fileExists(atPath: sidecar.path))
    #expect(store.sidecarWriteCount == 0)
}
```

- [ ] **Step 2: Run to verify they fail**

Expected: FAIL to compile — `backfillNotesSidecars` does not exist.

- [ ] **Step 3: Implement**

```swift
    /// One idempotent sweep: make sure every meeting that has a recording folder also has an
    /// up-to-date notes.md (F198). Covers everything transcribed before this feature existed.
    /// Compare-first, so a library whose sidecars are current writes nothing. Refused while
    /// degraded — the F187 read-only promise covers derived files too.
    func backfillNotesSidecars() {
        guard !isDegraded else { return }
        for meeting in meetings {
            pendingSidecarIDs.insert(meeting.id)
        }
        flushPendingNotesSidecars()
    }
```

In `AppModel.performStartupRecovery`, add **after** the degraded early-return block (so a degraded
launch never reaches it — defense in depth on top of the method's own guard):

```swift
        // Every meeting's transcript and summary is mirrored as notes.md beside its audio, so the
        // text survives even an index loss (F198). Idempotent: an up-to-date library writes nothing.
        store.backfillNotesSidecars()
```

- [ ] **Step 4: Verify the degraded test is genuinely red without the guard**

Temporarily remove `guard !isDegraded else { return }` from `flushPendingNotesSidecars()` AND from `backfillNotesSidecars()`, run `--filter "noSidecarWhileDegraded"`, confirm it fails **with the sidecar actually created**. Restore from a scratchpad copy. Record the output.

- [ ] **Step 5: Run the full suite.** Expected: PASS, 488 + 6.

- [ ] **Step 6: Commit**

```bash
git add Sources/WhisperMeet/MeetingStore.swift Sources/WhisperMeet/AppModel.swift Tests/WhisperMeetTests/NotesSidecarTests.swift
git commit -m "feat(meetings): backfill notes.md for every existing meeting at startup (F198)"
```

---

### Task 4: Selectable text and per-section copy

**Files:**
- Modify: `Sources/WhisperMeet/ContentView.swift` (`summaryBody` at `:2448`, the transcript text view, `ActionItemCard`)

No unit tests — the target has no view-render harness; manual verification in Task 5.

- [ ] **Step 1: Enable selection**

In `summaryBody` (`:2448-2458`): add `.textSelection(.enabled)` to `Text(summary.summary)` and to the key-points `VStack`. In `ActionItemCard`, add `.textSelection(.enabled)` to the `Text` that renders `item.text` (find it in the card body — selection on the text only, not the toggle/owner/due controls). Find the transcript's reading-mode `Text` (near the copy button at `:2706`) and enable selection there too, plus the notes `TextEditor` is already selectable — leave it.

- [ ] **Step 2: Add the per-section copy buttons**

In `summaryBody`, put a small copy button in the "Key points" and "Action items" header rows, matching the existing whole-summary `Button("Copy")` at `:2385` (plain buttons, no acknowledgment state — consistent with that precedent):

```swift
            if !summary.keyPoints.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("Key points").font(.subheadline.bold())
                        Button("Copy") { copy(summary.keyPoints.map { "• \($0)" }.joined(separator: "\n")) }
                            .controlSize(.small)
                            .help("Copy the key points only")
                    }
                    ForEach(summary.keyPoints.indices, id: \.self) { index in
                        Text("• \(summary.keyPoints[index])")
                    }
                    .textSelection(.enabled)
                }
            }
            if !summary.actionItems.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("Action items").font(.subheadline.bold())
                        Button("Copy") { copy(summary.actionItems.map(MeetingNotesExporter.actionItemLine).joined(separator: "\n")) }
                            .controlSize(.small)
                            .help("Copy the action items only, with owner and due date")
                    }
                    // ... existing ActionItemCard ForEach unchanged ...
                }
            }
```

`copy(_:)` already exists at `:2971` (NSPasteboard). `MeetingNotesExporter.actionItemLine` is already used at `:2495`, so owner/due/done render identically to the whole-summary copy.

- [ ] **Step 3: Build and run the full suite.** Expected: builds clean, 488 + 6 passing.

- [ ] **Step 4: Commit**

```bash
git add Sources/WhisperMeet/ContentView.swift
git commit -m "feat(ui): selectable summary text and per-section copy (F198)"
```

---

### Task 5: Docs, gate, ticket, manual verification

- [ ] **Step 1: RECOVERY.md** — add one line to the file-layout section: each `Recordings/<id>/` folder holds a human-readable `notes.md` mirroring the meeting's transcript, summary and action items, regenerated automatically; it is write-only insurance and safe to copy or read with any editor. Wrap by hand — **do not run `Scripts/format-docs.py`**.

- [ ] **Step 2: Run the gate**

```bash
Scripts/quality-check.sh
```

Expected: all five steps pass.

- [ ] **Step 3: File the ticket** — add this feature to `docs/TICKETS.md` using the template in `AGENTS.md` at the board's **current** next free ID (check the header line — it should read F198), advance the header, regenerate and `--check` the dashboard. Also update `docs/superpowers/plans/2026-08-14-sidebar-multi-select.md` Task 8, which stale-claims "next free ID is **F198**" — change it to "the board's current next free ID".

- [ ] **Step 4: Manual verification** (record in the log entry; GUI tests "Not planned:" — no view-render harness):

```bash
Scripts/install-app.sh
open /Applications/WhisperMeet.app
```

Confirm: existing meetings gain `notes.md` in their recording folders on launch; editing a transcript updates it after a pause; the summary text is mouse-selectable; Key points / Action items each copy just their section; the whole-summary Copy still works.

- [ ] **Step 5: Commit**

```bash
git add -A
git commit -m "docs(meetings): notes.md sidecar recorded in RECOVERY.md; ticket filed (F198)"
```
