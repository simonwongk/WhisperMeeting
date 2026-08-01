# Needs human

The queue of tickets blocked on a physical action or a decision only the user can make — each with a
**What I need from you:** line. How an entry arrives here, and the cap on this file, are governed by
the ticket rules in [`../AGENTS.md`](../AGENTS.md); open work stays in [`TICKETS.md`](TICKETS.md).

---

### F130 — Visually verify tag click-to-filter and its VoiceOver actions (F84)

- **Status:** needs-human
- **Owner:** —
- **Severity:** low
- **Area:** meetings
- **Filed:** 2026-08-01 by Claude Code (Opus 4.8)

**What I need from you** (~1 minute in the app):

1. Give two meetings the same tag (right-click a meeting → add tags).
2. In the sidebar, **click a tag chip** on a meeting row. The list should narrow to meetings carrying
   that tag and the chip should highlight — **and clicking the chip must NOT also open/select that
   meeting**; the tap should filter, not navigate. Click it again to clear.
3. Type in the search box with a tag still selected: results should be the intersection (search AND
   tag stack).
4. **VoiceOver:** turn it on, focus a meeting row, open its actions (VO + Command + Space) — confirm a
   "Filter by tag <name>" action is offered and toggles the filter.

Say "all good", or describe anything off — especially if a chip tap selects the meeting instead of
filtering, which would need a gesture fix.

**Problem.** F84 wired tag filtering — the filter logic (`MeetingLibraryFilter`) is unit-tested and the
build is green — but the chip lives inside a `List(selection:)` row, so whether a chip tap filters vs.
triggers row selection (and whether the VoiceOver actions surface) can only be confirmed on screen.

**Impact.** Craft/accessibility only; the filter logic is proven. A gesture conflict would make tapping
a tag select the meeting instead of filtering it.

**Verification.** The checklist above; any artifact seen is filed as its own ticket.
