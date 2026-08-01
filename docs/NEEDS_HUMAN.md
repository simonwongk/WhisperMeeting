# Needs human

The queue of tickets blocked on a physical action or a decision only the user can make — each with a
**What I need from you:** line. How an entry arrives here, and the cap on this file, are governed by
the ticket rules in [`../AGENTS.md`](../AGENTS.md); open work stays in [`TICKETS.md`](TICKETS.md).

---

### F117 — Eyeball the five F116 motion seams (and arbitrate one verifier disagreement)

- **Status:** needs-human
- **Owner:** —
- **Severity:** low
- **Area:** ui
- **Filed:** 2026-07-31 by Claude Code (Fable 5, apple-design redesign session)

**What I need from you:** run `open .build/WhisperMeet.app` (already built) and glance at the five
new transitions: (1) a transcription finishing — the status card should cross-fade into the
summary/transcript, **watch specifically for any hard snap or transient stacking** (this arbitrates
a verifier disagreement recorded in `docs/UI_REDESIGN_LOG.md` § Implementation notes); (2) pin and
delete a meeting — rows should glide/collapse, and **typing in search must stay instant**;
(3) Summarize — spinner should fade into the summary; (4) add/remove vocabulary terms; (5) the
Test Recording sheet's phase changes. Optionally repeat (1) and (5) with Reduce Motion on — you
should still get a quick fade, but no movement. Report findings (or "all good") in chat.

**Problem.** The F116 seams are build/test/workflow-verified but SwiftUI has no render harness, and
one round-2 verifier claim about transition layout mechanics contradicts established SwiftUI
behavior — only looking at the running app settles it.

**Impact.** Craft only; a wrong call here means a visible snap at the app's payoff moment.

**Verification.** The checklist above; any artifact seen is filed as its own ticket.
