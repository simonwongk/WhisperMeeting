# Sidebar multi-select — design

**Date:** 2026-08-14
**Status:** approved (approach A, add/remove tag semantics)

**Goal:** Shift-click selects a range of meetings in the sidebar, ⌘-click toggles individual ones, and
a multi-selection can be deleted or tagged in one action.

---

## Current state

`ContentView` has a single `List(selection: $selection)` (`ContentView.swift:68`) whose selection is
`SidebarItem?` — single selection. `SidebarItem` (`:9-16`) is one enum holding both navigation
destinations and meetings:

```swift
private enum SidebarItem: Hashable {
    case record, vocabulary, askMeetings, dictation, settings
    case meeting(UUID)
}
```

The detail pane is `switch selection ?? .record` (`:182`). Per-meeting actions today are a context
menu with Pin and Delete (`:97-109`); delete routes through `pendingDeletion: MeetingRecord?` and a
`confirmationDialog` (`:29`, `:155-173`).

## Approach

**Approach A — one list, `Set<SidebarItem>` selection.** SwiftUI's macOS `List` provides shift-range
and ⌘-toggle natively once the selection binding is a `Set`, so the interaction needs no custom
hit-testing.

Rejected alternatives:
- *Two lists* (nav single-select, meetings `Set<UUID>`): semantically cleaner, but it restructures
  `NavigationSplitView`, gives two independently scrolling lists, and risks not looking like a normal
  macOS sidebar. Larger than the feature warrants.
- *Explicit multi-select mode* with checkboxes: unambiguous, but it is an iOS pattern, adds a mode,
  and it is not shift-click — which is the requested behavior.

---

## 1. Selection model

`selection` becomes `Set<SidebarItem>`, defaulting to `[.record]`.

Add one derived property:

```swift
/// Meetings currently selected, in sidebar order. Navigation items caught in a shift-range are
/// ignored — a range that crosses the Meetings section boundary should not "select Settings".
private var selectedMeetingIDs: [UUID]
```

It filters `selection` for `.meeting(id)` cases and orders them by their position in
`filteredMeetings`, so anything that displays or acts on the selection is deterministic.

The one existing write to `selection` — `RecordMeetingView`'s completion callback at `:185` — becomes
`selection = [.meeting(meetingID)]`.

**Accepted trade-off:** a shift-drag spanning the navigation section technically puts nav items in the
set. They are ignored, so the effect is invisible; the alternative (making nav rows unselectable in a
multi-selection) is not expressible in a single SwiftUI `List`.

## 2. Detail pane

```
selectedMeetingIDs.count >= 2  ->  MeetingBatchView (new)
otherwise                      ->  today's switch, on the single selected item
empty selection                ->  .record
```

No existing pane changes. `MeetingBatchView` shows the count, the selected titles, a delete button,
and the tag editor described below.

## 3. Where the actions live

Both, following macOS convention:

- **Context menu.** Right-clicking a row that is part of a multi-selection offers "Delete N
  Meetings" and the tag actions, instead of the single-row Pin/Delete menu. Right-clicking a row
  *outside* the selection keeps today's single-row behavior.
- **Batch pane.** The same actions, discoverable without a right-click.

## 4. Delete semantics

One confirmation for the whole selection. The dialog names every meeting and states plainly that
their recordings will be deleted from disk, with a count. `pendingDeletion` becomes a list rather than
a single record; the existing `confirmationDialog` pattern is reused.

Two existing invariants carry over per record and are **not** negotiable:

- **F148 #6** — each directory is checked with `isWithinLibrary` and must not be the library root, so
  a corrupt or empty `recordingPath` can never resolve outside the library.
- **F187** — the mutation guard runs *before* any filesystem side effect, because
  `removeRecordingDirectory` runs before the index is persisted.

**Partial failure** follows single `delete`'s existing rule: a meeting whose directory cannot be
removed is kept in the library rather than half-deleted, and the error message names which ones
failed. The rest still delete.

## 5. Tag semantics — add/remove, never replace

The batch tag editor shows the **union** of tags across the selection:

- a tag on **every** selected meeting renders solid;
- a tag on **some** renders dimmed (mixed state).

Adding applies the tag to all selected meetings. Removing removes it from all. There is no
"replace the tag set" operation in batch, because that would silently destroy tags the user cannot
see on a mixed selection.

Reuses the existing `TagChipsEditor` (`ContentView.swift:3105`) where practical, extended to render
the mixed state.

## 6. Store API — one write, not N

Batch actions must not loop the per-meeting methods. `delete(id:)` and `setTags(id:_:)` each call
`persistMeetings()`/`persistVocabulary()`, so deleting ten meetings today would mean ten full index
writes. This codebase already debounces per-keystroke writes for that reason (F40).

New methods on `MeetingStore`:

```swift
func delete(ids: [UUID])
func addTag(_ tag: String, to ids: [UUID])
func removeTag(_ tag: String, from ids: [UUID])
```

Each one:
1. calls `mutationIsAllowed()` **once**, as its first statement;
2. mutates the in-memory `meetings` array for every affected record;
3. calls `persistMeetings()` **once**.

Tag values go through `MeetingTags.normalized` exactly as `setTags(id:_:)` does, so batch and single
paths cannot diverge.

## 7. Testing

`Tests/WhisperMeetTests/` additions, swift-testing, temp dir + UUID + `defer`:

- `delete(ids:)` persists exactly once — `persistCount == before + 1` for a multi-record delete.
- `delete(ids:)` is refused entirely while the library is degraded, with **no** directory removed.
  This is the F187 invariant and the most important test in the set; it must be red without the
  guard.
- Partial failure: with a stubbed `removeRecordingDirectory` that throws for one record, that meeting
  is kept, the others are deleted, and the error names the failure.
- Batch tag persists once and applies to every selected meeting; normalization matches `setTags`.
- `selectedMeetingIDs` ignores navigation items and returns sidebar order.

The SwiftUI selection binding itself has no view-render harness (`AGENTS.md`, "Wiring an unreachable
core"), so shift-click behavior is verified manually and the absence of a GUI test is recorded as
**"Not planned:"** — a harness limitation, not deferred work.

## 8. Out of scope

- Batch transcription of a selection (the existing all-ready-meetings action covers the need).
- A trash/undo area for deleted meetings.
- Multi-select for anything other than meetings.
