# Sidebar Multi-Select Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Shift-click selects a range of meetings in the sidebar, ⌘-click toggles individual ones, and a multi-selection can be deleted or tagged in one action.

**Architecture:** The sidebar's single `List` selection changes from `SidebarItem?` to `Set<SidebarItem>`, which is what gives macOS shift-range and ⌘-toggle for free. Navigation items caught in a range are filtered out of a derived `selectedMeetingIDs`. Batch actions go through new `MeetingStore` methods that check the read-only guard once and write the index once, rather than looping the per-meeting methods.

**Tech Stack:** Swift 6 toolchain in Swift 5 language mode, SwiftPM, SwiftUI, swift-testing (`@Test`/`#expect`), macOS 15+.

**Design:** `docs/superpowers/specs/2026-08-14-sidebar-multi-select-design.md`

---

## Global Constraints

- Tests are swift-testing (`@Test("display name")`, `#expect`, `#require`) — never XCTest.
- `MeetingStore` and `AppModel` are `@MainActor`. `Sources/WhisperCore/` is Foundation-only and `Sendable`.
- Never write to `~/Library/Application Support/WhisperMeet/` from a test. Use `FileManager.default.temporaryDirectory` with a UUID subdirectory and a `defer` cleanup.
- Document invariants in code comments with the ticket id, matching existing style.
- **Test command** (this Mac has Command Line Tools only; plain `swift test` cannot find swift-testing):

```bash
FW=/Library/Developer/CommandLineTools/Library/Developer/Frameworks
LIB=/Library/Developer/CommandLineTools/Library/Developer/usr/lib
swift test --disable-sandbox --no-parallel \
  -Xswiftc -F -Xswiftc "$FW" \
  -Xlinker -rpath -Xlinker "$FW" \
  -Xlinker -rpath -Xlinker "$LIB" --filter "<name>"
```

  Keep the flags byte-identical between runs so SwiftPM does not rebuild.
- **`--filter` matches the Swift FUNCTION name** (case-sensitive regex), **not** the `@Test("...")` display string. A display-name filter matches zero tests and still exits 0, which looks exactly like a pass. Always check the reported test count.
- Current full-suite baseline: **488 passing**.
- **Never run `Scripts/format-docs.py`** — it ignores its arguments and reformats every doc in the repo.
- **Do not use `git checkout <file>`** to undo an experiment; use a scratchpad copy.

## File Structure

| File | Responsibility |
|---|---|
| `Sources/WhisperMeet/MeetingStore.swift` | New `delete(ids:)`, `addTag(_:to:)`, `removeTag(_:from:)` — one guard, one index write each. |
| `Sources/WhisperMeet/AppModel.swift` | New `deleteMeetings(ids:)` that cancels each transcription then delegates to the store. |
| `Sources/WhisperMeet/ContentView.swift` | `Set<SidebarItem>` selection, `selectedMeetingIDs`, batch context menu, batch confirmation dialog. |
| `Sources/WhisperMeet/MeetingBatchView.swift` *(new)* | The detail pane shown for a 2+ meeting selection: count, titles, delete button, batch tag editor. Kept out of `ContentView.swift`, which is already ~3,700 lines. |
| `Tests/WhisperMeetTests/BatchMeetingActionsTests.swift` *(new)* | Store-level batch delete and batch tag behaviour, including the read-only refusal. |

---

### Task 1: `MeetingStore.delete(ids:)` deletes many with one index write

**Files:**
- Modify: `Sources/WhisperMeet/MeetingStore.swift` (add after `delete(id:)`, which currently ends around `:487`)
- Test: `Tests/WhisperMeetTests/BatchMeetingActionsTests.swift` *(new)*

**Interfaces:**
- Consumes: `mutationIsAllowed()`, `recordingURL(for:)`, `isWithinLibrary(_:)`, `removeRecordingDirectory`, `persistMeetings()`.
- Produces: `@discardableResult func delete(ids: [UUID]) -> [UUID]` (the ids actually removed).

- [x] **Step 1: Write the failing tests**

Create `Tests/WhisperMeetTests/BatchMeetingActionsTests.swift`:

```swift
import Foundation
import Testing
@testable import WhisperMeet
@testable import WhisperCore

/// A writable library holding `count` meetings, each with a real recording directory and a file in it.
@MainActor
private func makeLibrary(count: Int) throws -> (MeetingStore, URL, [UUID]) {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("WhisperMeetBatch-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let store = MeetingStore(rootDirectory: root)
    var ids: [UUID] = []
    for index in 0..<count {
        let id = UUID()
        let directory = root.appendingPathComponent("Recordings/\(id.uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("audio".utf8).write(to: directory.appendingPathComponent("meeting.wav"))
        store.upsert(MeetingRecord(
            id: id,
            title: "Meeting \(index)",
            recordingPath: "Recordings/\(id.uuidString)/meeting.wav",
            status: .completed,
            transcriptText: "transcript \(index)"
        ))
        ids.append(id)
    }
    return (store, root, ids)
}

@Test("Deleting several meetings writes the index once, not once per meeting")
@MainActor
func batchDeleteWritesTheIndexOnce() throws {
    let (store, root, ids) = try makeLibrary(count: 3)
    defer { try? FileManager.default.removeItem(at: root) }
    let before = store.persistCount

    store.delete(ids: ids)

    #expect(store.meetings.isEmpty)
    #expect(store.persistCount == before + 1)
    for id in ids {
        let directory = root.appendingPathComponent("Recordings/\(id.uuidString)", isDirectory: true)
        #expect(!FileManager.default.fileExists(atPath: directory.path))
    }
}

@Test("A meeting whose directory cannot be removed is kept, and the rest still delete")
@MainActor
func batchDeleteKeepsWhatItCouldNotRemove() throws {
    let (store, root, ids) = try makeLibrary(count: 3)
    defer { try? FileManager.default.removeItem(at: root) }
    let stubborn = ids[1]
    store.removeRecordingDirectory = { url in
        if url.lastPathComponent == stubborn.uuidString {
            throw NSError(domain: "test", code: 1)
        }
        try FileManager.default.removeItem(at: url)
    }

    store.delete(ids: ids)

    #expect(store.meetings.map(\.id) == [stubborn])
    #expect(store.storageErrorMessage != nil)
}
```

`MeetingRecord.id` and `.createdAt` are `let` (`MeetingStore.swift:32, 34`), so they **must** be passed through the initializer — assigning after construction will not compile. The argument list above mirrors the one `makeBackupRecoveredStore` already uses in `Tests/WhisperMeetTests/DegradedLibraryTests.swift:46-54`, so the remaining parameters have defaults.

- [x] **Step 2: Run the tests to verify they fail**

Run with `--filter "batchDelete"`. Expected: FAIL to compile — `delete(ids:)` does not exist.

- [x] **Step 3: Write the implementation**

Add to `MeetingStore` immediately after `delete(id:)`:

```swift
    /// Deletes several meetings in one pass: one read-only check, one index write. Looping
    /// `delete(id:)` would run a full index write per meeting, the same cost F40 removed from
    /// per-keystroke transcript edits.
    ///
    /// Per record this keeps both existing invariants: the containment check that stops a corrupt or
    /// empty `recordingPath` resolving outside the library (F148 #6), and the read-only guard ahead of
    /// any filesystem side effect, because `removeRecordingDirectory` runs before the index is
    /// persisted (F187). Returns the ids actually removed.
    @discardableResult
    func delete(ids: [UUID]) -> [UUID] {
        guard mutationIsAllowed() else { return [] }
        var removed: [UUID] = []
        var keptTitles: [String] = []
        var escapedLibrary = false
        for id in ids {
            guard let meeting = meeting(id: id) else { continue }
            let directory = recordingURL(for: meeting).deletingLastPathComponent()
            guard isWithinLibrary(directory),
                  directory.standardizedFileURL != rootDirectory.standardizedFileURL else {
                // Index entry only — nothing on disk is touched, exactly as `delete(id:)` does.
                removed.append(id)
                escapedLibrary = true
                continue
            }
            do {
                try removeRecordingDirectory(directory)
                removed.append(id)
            } catch {
                // Don't half-delete: keep the meeting so the library stays consistent.
                keptTitles.append(meeting.title)
            }
        }
        guard !removed.isEmpty else {
            if !keptTitles.isEmpty {
                storageErrorMessage = Self.batchDeleteFailureMessage(keptTitles)
            }
            return []
        }
        let removing = Set(removed)
        meetings.removeAll { removing.contains($0.id) }
        persistMeetings()
        // After `persistMeetings()`, which clears `storageErrorMessage` on a successful write.
        if !keptTitles.isEmpty {
            storageErrorMessage = Self.batchDeleteFailureMessage(keptTitles)
        } else if escapedLibrary {
            storageErrorMessage = "One or more meetings had a recording path outside the library, so no files were deleted from disk for them; they were removed from the list."
        }
        return removed
    }

    private static func batchDeleteFailureMessage(_ titles: [String]) -> String {
        let names = titles.map { "“\($0)”" }.joined(separator: ", ")
        return "\(titles.count) meeting(s) could not have their recordings removed, so they were kept to avoid an inconsistent library: \(names)."
    }
```

- [x] **Step 4: Run the tests to verify they pass**

Run with `--filter "batchDelete"`, then the **full suite with no `--filter`**. Expected: PASS, suite 488 + 2.

- [x] **Step 5: Commit**

```bash
git add Sources/WhisperMeet/MeetingStore.swift Tests/WhisperMeetTests/BatchMeetingActionsTests.swift
git commit -m "feat(meetings): delete several meetings with one index write"
```

---

### Task 2: Batch delete is refused while the library is read-only

This is the most important test in the plan. Batch delete is a **new** way to violate F187's central invariant — that no mutation, and specifically no audio removal, happens while the index is not known-complete.

**Files:**
- Test: `Tests/WhisperMeetTests/BatchMeetingActionsTests.swift` (append)

- [x] **Step 1: Write the failing test**

`Tests/WhisperMeetTests/DegradedLibraryTests.swift` already has a helper `makeBackupRecoveredStore()` that returns a **degraded store containing a real record and a real `.wav`**. It is `private` to that file, so write a local equivalent here rather than changing its access level:

```swift
@Test("Batch delete is refused while the library is read-only, and removes no audio")
@MainActor
func batchDeleteRefusedWhileDegraded() throws {
    // Seed a writable library, then corrupt only the primary index so the backup loads:
    // that yields `.recoveredFromBackup`, which is degraded AND still has records and audio.
    let (_, root, ids) = try makeLibrary(count: 2)
    let primary = root.appendingPathComponent("meetings.json")
    let backup = root.appendingPathComponent("meetings.backup.json")
    // `BackupJSONStore.save()` writes the PREVIOUS primary into the backup, so after two upserts the
    // backup is one generation behind and holds only one meeting. Copy the primary across first, or
    // this fixture silently tests a one-record library and the count assertion below is meaningless.
    try? FileManager.default.removeItem(at: backup)
    try FileManager.default.copyItem(at: primary, to: backup)
    try Data("broken-primary".utf8).write(to: primary)

    let store = MeetingStore(rootDirectory: root)
    defer { try? FileManager.default.removeItem(at: root) }
    #expect(store.isDegraded)
    #expect(store.meetings.count == 2)
    let before = store.persistCount
    var removalAttempted = false
    store.removeRecordingDirectory = { _ in removalAttempted = true }

    store.delete(ids: ids)

    #expect(!removalAttempted)
    #expect(store.meetings.count == 2)
    #expect(store.persistCount == before)
    for id in ids {
        let wav = root.appendingPathComponent("Recordings/\(id.uuidString)/meeting.wav")
        #expect(FileManager.default.fileExists(atPath: wav.path))
    }
    #expect(store.storageErrorMessage != nil)
}
```

Verify the seeding actually produces `.recoveredFromBackup` before relying on it — `BackupJSONStore.save()` writes identical primary and backup copies, and `load()` falls through to the backup when the primary does not decode. If `#expect(store.isDegraded)` fails, the fixture is wrong, not the guard.

- [x] **Step 2: Run the test to verify it fails**

Temporarily delete the `guard mutationIsAllowed() else { return [] }` line from `delete(ids:)`, run with `--filter "batchDeleteRefusedWhileDegraded"`, and confirm it goes **red with the audio actually removed** — not merely with a flag unset. Restore the guard from a scratchpad copy (**not** `git checkout`). Record that red output in your report; this branch has repeatedly shipped tests that passed with their guard deleted.

- [x] **Step 3: No implementation needed**

Task 1's guard already satisfies this. If the test passes without removing the guard, the fixture is not actually degraded — fix the fixture.

- [x] **Step 4: Run the full suite**

Expected: PASS, suite 488 + 3.

- [x] **Step 5: Commit**

```bash
git add Tests/WhisperMeetTests/BatchMeetingActionsTests.swift
git commit -m "test(meetings): batch delete removes no audio while the library is read-only"
```

---

### Task 3: Batch tagging with one index write

**Files:**
- Modify: `Sources/WhisperMeet/MeetingStore.swift` (add after `setTags(id:_:)`, currently `:426-430`)
- Test: `Tests/WhisperMeetTests/BatchMeetingActionsTests.swift` (append)

**Interfaces:**
- Produces: `func addTag(_ tag: String, to ids: [UUID])`, `func removeTag(_ tag: String, from ids: [UUID])`.

- [x] **Step 1: Write the failing tests**

```swift
@Test("Adding a tag to several meetings writes the index once and applies to all")
@MainActor
func batchAddTagWritesOnce() throws {
    let (store, root, ids) = try makeLibrary(count: 3)
    defer { try? FileManager.default.removeItem(at: root) }
    store.setTags(id: ids[0], ["existing"])
    let before = store.persistCount

    store.addTag("  Budget  ", to: ids)

    #expect(store.persistCount == before + 1)
    for id in ids {
        let tags = store.meeting(id: id)?.tags ?? []
        #expect(tags.contains("Budget"))          // trimmed by MeetingTags.normalized
    }
    #expect(store.meeting(id: ids[0])?.tags?.contains("existing") == true)
}

@Test("Removing a tag takes it off every selected meeting and leaves others alone")
@MainActor
func batchRemoveTagWritesOnce() throws {
    let (store, root, ids) = try makeLibrary(count: 3)
    defer { try? FileManager.default.removeItem(at: root) }
    store.addTag("shared", to: ids)
    store.setTags(id: ids[2], ["shared", "keep"])
    let before = store.persistCount

    store.removeTag("shared", from: [ids[0], ids[2]])

    #expect(store.persistCount == before + 1)
    #expect(store.meeting(id: ids[0])?.tags?.contains("shared") != true)
    #expect(store.meeting(id: ids[1])?.tags?.contains("shared") == true)
    #expect(store.meeting(id: ids[2])?.tags == ["keep"])
}
```

- [x] **Step 2: Run the tests to verify they fail**

Run with `--filter "batchAddTag"` then `--filter "batchRemoveTag"`. Expected: FAIL to compile — the methods do not exist.

- [x] **Step 3: Write the implementation**

```swift
    /// Adds one tag across a selection with a single index write (F40's rule: don't write per record).
    /// Normalization goes through `MeetingTags.normalized`, exactly as `setTags(id:_:)` does, so the
    /// batch and single paths cannot diverge.
    func addTag(_ tag: String, to ids: [UUID]) {
        guard mutationIsAllowed() else { return }
        let target = Set(ids)
        var changed = false
        for index in meetings.indices where target.contains(meetings[index].id) {
            let merged = MeetingTags.normalized((meetings[index].tags ?? []) + [tag])
            guard merged != meetings[index].tags else { continue }
            meetings[index].tags = merged.isEmpty ? nil : merged
            changed = true
        }
        guard changed else { return }
        persistMeetings()
    }

    /// Removes one tag from every meeting in the selection, matched case-insensitively so it agrees
    /// with `MeetingTags.normalized`'s own de-duplication rule.
    func removeTag(_ tag: String, from ids: [UUID]) {
        guard mutationIsAllowed() else { return }
        let target = Set(ids)
        let needle = tag.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !needle.isEmpty else { return }
        var changed = false
        for index in meetings.indices where target.contains(meetings[index].id) {
            guard let existing = meetings[index].tags else { continue }
            let remaining = existing.filter { $0.lowercased() != needle }
            guard remaining.count != existing.count else { continue }
            meetings[index].tags = remaining.isEmpty ? nil : remaining
            changed = true
        }
        guard changed else { return }
        persistMeetings()
    }
```

Read `Sources/WhisperCore/MeetingTags.swift:17-30` first and confirm `normalized` de-duplicates case-insensitively and caps length — the `removeTag` matching above assumes it does.

- [x] **Step 4: Run the tests to verify they pass**

Then the full suite. Expected: PASS, suite 488 + 5.

- [x] **Step 5: Commit**

```bash
git add Sources/WhisperMeet/MeetingStore.swift Tests/WhisperMeetTests/BatchMeetingActionsTests.swift
git commit -m "feat(meetings): add and remove a tag across a selection in one write"
```

---

### Task 4: `AppModel.deleteMeetings(ids:)`

`AppModel.deleteMeeting(id:)` (`:1607-1610`) cancels the meeting's transcription before deleting. A batch delete must do the same for each, or a running transcription would outlive its meeting.

**Files:**
- Modify: `Sources/WhisperMeet/AppModel.swift` (add immediately after `deleteMeeting(id:)` at `:1607-1610`)
- Test: `Tests/WhisperMeetTests/BatchMeetingActionsTests.swift` (append)

- [x] **Step 1: Write the failing test**

```swift
@Test("Deleting a selection cancels each meeting's transcription first")
@MainActor
func batchDeleteCancelsTranscriptions() throws {
    let (store, root, ids) = try makeLibrary(count: 2)
    defer { try? FileManager.default.removeItem(at: root) }
    let defaults = try #require(UserDefaults(suiteName: "BatchDelete-\(UUID().uuidString)"))
    let model = AppModel(store: store, recorder: AudioCaptureEngine(), defaults: defaults)

    model.deleteMeetings(ids: ids)

    #expect(store.meetings.isEmpty)
    for id in ids {
        #expect(!model.isQueuedForTranscription(id))
    }
}
```

The `AppModel(store:recorder:defaults:)` seam is the established one — see `Tests/WhisperMeetTests/CancelConfirmationTests.swift:6-11`. `AudioCaptureEngine()` touches no hardware; only `start` does. `isQueuedForTranscription(_:)` exists at `AppModel.swift:353`.

- [x] **Step 2: Run the test to verify it fails**

Run with `--filter "batchDeleteCancelsTranscriptions"`. Expected: FAIL to compile — `deleteMeetings(ids:)` does not exist.

- [x] **Step 3: Write the implementation**

```swift
    /// Deletes a whole selection. Cancels each meeting's transcription first, exactly as
    /// `deleteMeeting(id:)` does, then removes them in a single index write.
    func deleteMeetings(ids: [UUID]) {
        for id in ids { cancelTranscription(id: id) }
        store.delete(ids: ids)
    }
```

- [x] **Step 4: Run the test to verify it passes**, then the full suite. Expected: PASS, suite 488 + 6.

- [x] **Step 5: Commit**

```bash
git add Sources/WhisperMeet/AppModel.swift Tests/WhisperMeetTests/BatchMeetingActionsTests.swift
git commit -m "feat(meetings): cancel transcriptions when deleting a selection"
```

---

### Task 5: The sidebar selection becomes a set

This task is a pure refactor — no behaviour change beyond shift/⌘ selection becoming possible. Every existing read and write of `selection` must be updated together or the file will not compile.

**Files:**
- Modify: `Sources/WhisperMeet/ContentView.swift:27, 68, 126, 167-169, 182, 185`

- [x] **Step 1: Change the state and add the derived property**

Replace `ContentView.swift:27`:

```swift
    @State private var selection: SidebarItem? = .record
```

with:

```swift
    // A set, not an optional: this is what gives the sidebar macOS's native shift-range and
    // ⌘-toggle selection. Navigation rows share the list with meetings, so a shift-range can
    // include them; `selectedMeetingIDs` filters them out rather than trying to make them
    // unselectable, which a single SwiftUI `List` cannot express.
    @State private var selection: Set<SidebarItem> = [.record]
```

Add next to `filteredMeetings` (after `:64`):

```swift
    /// The selected meetings in sidebar order. Navigation items in the selection are ignored, so a
    /// shift-range that crosses the Meetings section boundary never "selects Settings".
    private var selectedMeetingIDs: [UUID] {
        let chosen = Set(selection.compactMap { item -> UUID? in
            if case let .meeting(id) = item { return id }
            return nil
        })
        return filteredMeetings.map(\.id).filter { chosen.contains($0) }
    }

    /// The single selected item, when exactly one thing is selected.
    private var singleSelection: SidebarItem? {
        selection.count == 1 ? selection.first : nil
    }
```

- [x] **Step 2: Update every existing use of `selection`**

There are four, and all must change:

1. `:126` — `selection = .meeting(request.meetingID)` becomes `selection = [.meeting(request.meetingID)]`
2. `:167-169` — the post-delete reset becomes:

```swift
                if selection.contains(.meeting(meeting.id)) {
                    selection = [.record]
                }
```

3. `:182` — `switch selection ?? .record` becomes `switch singleSelection ?? .record`
4. `:185` — the `RecordMeetingView` callback `selection = .meeting(meetingID)` becomes `selection = [.meeting(meetingID)]`

`List(selection: $selection)` at `:68` needs no change — the binding type does the work.

- [x] **Step 3: Build and run the full suite**

```bash
swift build 2>&1 | tail -5
```

Then the full suite with no `--filter`. Expected: builds clean, **488 + 6 passing**, no behaviour change. A compile error here means a `selection` use was missed — search the file for `selection` and check each hit.

- [x] **Step 4: Commit**

```bash
git add Sources/WhisperMeet/ContentView.swift
git commit -m "refactor(ui): sidebar selection becomes a set to allow shift-range selection"
```

**Note on testing `selectedMeetingIDs`.** The design document lists a unit test for it, but it is a
`private` computed property on a SwiftUI `View` in a target with no view-render harness — there is no
seam to reach it without making it internal purely for a test, which would be worse than the coverage
is worth. Its two behaviours (ignore navigation items, return sidebar order) are covered by the manual
verification in Task 8. Say so explicitly in the log entry rather than leaving the design's test list
looking unimplemented.

---

### Task 6: Batch delete from the sidebar

**Files:**
- Modify: `Sources/WhisperMeet/ContentView.swift:29, 97-109, 152-177`

- [x] **Step 1: Widen the pending deletion state**

Replace `:29`:

```swift
    @State private var pendingDeletion: MeetingRecord?
```

with:

```swift
    /// Meetings awaiting delete confirmation. A list rather than one record, so a multi-selection
    /// confirms once and names everything it is about to remove.
    @State private var pendingDeletion: [MeetingRecord] = []
```

- [x] **Step 2: Offer the batch action in the context menu**

Replace the `.contextMenu` block at `:97-109` with:

```swift
                            .contextMenu {
                                // Right-clicking inside a multi-selection acts on the whole
                                // selection; right-clicking outside it keeps the single-row menu,
                                // which is the Finder grammar users already expect.
                                let batch = selectedMeetingIDs.count > 1
                                    && selectedMeetingIDs.contains(meeting.id)
                                if batch {
                                    Button("Delete \(selectedMeetingIDs.count) Meetings", role: .destructive) {
                                        let chosen = Set(selectedMeetingIDs)
                                        pendingDeletion = store.meetings.filter { chosen.contains($0.id) }
                                    }
                                } else {
                                    Button((meeting.pinned ?? false) ? "Unpin" : "Pin to Top") {
                                        withAnimation(reduceMotion ? nil : .uiSpring) {
                                            store.togglePin(id: meeting.id)
                                        }
                                    }
                                    Button("Delete Meeting", role: .destructive) {
                                        pendingDeletion = [meeting]
                                    }
                                }
                            }
```

- [x] **Step 3: Make the confirmation dialog handle a list**

Replace the `.confirmationDialog` block at `:152-177` with:

```swift
        .confirmationDialog(
            pendingDeletion.count > 1
                ? "Permanently delete \(pendingDeletion.count) meetings?"
                : "Permanently delete this meeting?",
            isPresented: Binding(
                get: { !pendingDeletion.isEmpty },
                set: { if !$0 { pendingDeletion = [] } }
            ),
            titleVisibility: .visible
        ) {
            Button("Delete Recording and Transcript", role: .destructive) {
                let doomed = pendingDeletion
                guard !doomed.isEmpty else { return }
                // Only the list mutation animates (rows collapse); the selection swap stays outside
                // the transaction so the detail column changes instantly (F116).
                withAnimation(reduceMotion ? nil : .uiSpring) {
                    model.deleteMeetings(ids: doomed.map(\.id))
                }
                let removed = Set(doomed.map { SidebarItem.meeting($0.id) })
                selection.subtract(removed)
                if selection.isEmpty { selection = [.record] }
                pendingDeletion = []
            }
            Button("Keep Meeting", role: .cancel) {
                pendingDeletion = []
            }
        } message: {
            if pendingDeletion.count > 1 {
                Text("This removes the local recording, its source tracks, and its transcript for each of:\n\n"
                    + pendingDeletion.map { "• \($0.title)" }.joined(separator: "\n")
                    + "\n\nThis action cannot be undone by WhisperMeet.")
            } else {
                Text("This removes the local recording, its source tracks, and its transcript. This action cannot be undone by WhisperMeet.")
            }
        }
```

- [x] **Step 4: Build and run the full suite**

Expected: builds clean, 488 + 6 passing. No test covers the SwiftUI layer; the store-level behaviour is already covered by Tasks 1-4.

- [x] **Step 5: Commit**

```bash
git add Sources/WhisperMeet/ContentView.swift
git commit -m "feat(ui): delete a whole sidebar selection behind one confirmation"
```

---

### Task 7: The batch detail pane with mixed-state tagging

**Files:**
- Create: `Sources/WhisperMeet/MeetingBatchView.swift`
- Modify: `Sources/WhisperMeet/ContentView.swift` (the `detail` computed property at `:180-182`)

`ContentView.swift` is already ~3,700 lines, so the new pane goes in its own file.

- [x] **Step 1: Create the view**

```swift
// Sources/WhisperMeet/MeetingBatchView.swift
import SwiftUI
import WhisperCore

/// The detail pane for a multi-meeting sidebar selection: what is selected, and the two actions that
/// make sense across many meetings at once. Tagging is add/remove only — never "replace the tag set" —
/// because a mixed selection has tags the user cannot see, and replacing would silently destroy them.
struct MeetingBatchView: View {
    @ObservedObject var store: MeetingStore
    let meetingIDs: [UUID]
    let onDelete: () -> Void
    @State private var draft = ""

    private var meetings: [MeetingRecord] {
        let chosen = Set(meetingIDs)
        return store.meetings.filter { chosen.contains($0.id) }
    }

    /// Every tag across the selection, with whether it is on all of them or only some.
    private var tagStates: [(tag: String, onAll: Bool)] {
        var counts: [String: Int] = [:]
        var display: [String: String] = [:]
        for meeting in meetings {
            for tag in Set((meeting.tags ?? []).map { $0.lowercased() }) {
                counts[tag, default: 0] += 1
            }
            for tag in meeting.tags ?? [] where display[tag.lowercased()] == nil {
                display[tag.lowercased()] = tag
            }
        }
        return counts.keys.sorted()
            .map { (display[$0] ?? $0, counts[$0] == meetings.count) }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("\(meetings.count) meetings selected")
                    .font(.title2).bold()

                VStack(alignment: .leading, spacing: 4) {
                    ForEach(meetings) { meeting in
                        Text(meeting.title).font(.callout).foregroundStyle(.secondary)
                    }
                }

                Divider()

                Text("Tags").font(.headline)
                Text("Adding applies to all selected meetings. A dimmed tag is only on some of them.")
                    .font(.caption).foregroundStyle(.secondary)

                WrapLayout(spacing: 6) {
                    ForEach(tagStates, id: \.tag) { state in
                        HStack(spacing: 4) {
                            Text(state.tag)
                            Button {
                                store.removeTag(state.tag, from: meetingIDs)
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("Remove tag \(state.tag) from all selected meetings")
                        }
                        .padding(.horizontal, 8).padding(.vertical, 3)
                        .background(.quaternary, in: Capsule())
                        .opacity(state.onAll ? 1 : 0.55)
                    }
                    TextField("Add a tag to all…", text: $draft)
                        .textFieldStyle(.plain)
                        .frame(width: 170)
                        .onSubmit {
                            let tag = draft.trimmingCharacters(in: .whitespacesAndNewlines)
                            guard !tag.isEmpty else { return }
                            store.addTag(tag, to: meetingIDs)
                            draft = ""
                        }
                }

                Divider()

                Button("Delete \(meetings.count) Meetings…", role: .destructive, action: onDelete)
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
```

`WrapLayout` is declared `private struct WrapLayout: Layout` at `ContentView.swift:3059`, so a new file **cannot** see it. Before writing this view, drop the `private`:

```swift
// ContentView.swift:3059 — used by TagChipsEditor here and by MeetingBatchView in its own file.
struct WrapLayout: Layout {
```

That is the whole change; `TagChipsEditor`'s use of it is unaffected.

- [x] **Step 2: Route the detail pane to it**

Replace the opening of `detail` at `:180-182`:

```swift
    @ViewBuilder
    private var detail: some View {
        switch singleSelection ?? .record {
```

with:

```swift
    @ViewBuilder
    private var detail: some View {
        if selectedMeetingIDs.count > 1 {
            MeetingBatchView(store: store, meetingIDs: selectedMeetingIDs) {
                let chosen = Set(selectedMeetingIDs)
                pendingDeletion = store.meetings.filter { chosen.contains($0.id) }
            }
        } else {
            singleDetail
        }
    }

    @ViewBuilder
    private var singleDetail: some View {
        switch singleSelection ?? .record {
```

The rest of the existing `switch` body is unchanged — it becomes the body of `singleDetail`.

- [x] **Step 3: Build and run the full suite**

Expected: builds clean, 488 + 6 passing.

- [x] **Step 4: Commit**

```bash
git add Sources/WhisperMeet/MeetingBatchView.swift Sources/WhisperMeet/ContentView.swift
git commit -m "feat(ui): batch pane for a multi-meeting selection with mixed-state tagging

WrapLayout loses its `private` so the new file can share it rather than
duplicating the layout."
```

---

### Task 8: Gate, manual verification, and the ticket

- [x] **Step 1: Run the full gate**

```bash
Scripts/quality-check.sh
```

Expected: all five steps pass.

- [ ] **Step 2: Manual verification** *(outstanding — the installer refused while WhisperMeet was running; signed candidate at `.build/WhisperMeet.app`. Checklist recorded in the F199 ticket entry.)*

The `WhisperMeet` target has no view-render harness, so the selection interaction cannot be tested (`AGENTS.md`, "Wiring an unreachable core"). Install and check by hand:

```bash
Scripts/install-app.sh
open /Applications/WhisperMeet.app
```

Confirm: click a meeting, shift-click a lower one — the range selects; ⌘-click toggles one out; the detail pane shows the batch view with the right count; right-click inside the selection offers "Delete N Meetings"; the confirmation names every meeting; adding a tag applies to all and a partly-applied tag renders dimmed; deleting the selection removes exactly those meetings and their audio.

Record these steps in the log entry and mark the absence of a GUI test **"Not planned:"** — a harness limitation, not deferred work.

- [x] **Step 3: File the ticket entry**

Add the feature to `docs/TICKETS.md` using the template in `AGENTS.md` at the board's current next free ID (check the header of `docs/TICKETS.md`), advance the "Next free ID" line at the top of the file, then regenerate and validate:

```bash
python3 Scripts/generate-tickets-dashboard.py
python3 Scripts/generate-tickets-dashboard.py --check
```

**Do not** run `Scripts/format-docs.py`.

- [x] **Step 4: Commit** *(the ticket docs are local-only per the 2026-08-07 gitignore policy, so `git add -A` had nothing to stage; the durable F199 trail commit is the plan-checkbox commit instead, matching the F198 precedent.)*

```bash
git add -A
git commit -m "feat(ui): shift-select a range of meetings for batch delete and tagging"
```
