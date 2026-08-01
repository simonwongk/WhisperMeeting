# Needs human

The queue of tickets blocked on a physical action or a decision only the user can make — each with a
**What I need from you:** line. How an entry arrives here, and the cap on this file, are governed by
the ticket rules in [`../AGENTS.md`](../AGENTS.md); open work stays in [`TICKETS.md`](TICKETS.md).

---

### F124 — Feel-check the five executed motion plans (F119)

- **Status:** needs-human
- **Owner:** —
- **Severity:** low
- **Area:** ui
- **Filed:** 2026-07-31 by Claude Code (Fable 5, apple-design redesign session)

**What I need from you** (plain version — open the app and spend ~3 minutes; one session also
covers F117 below):

1. **Playback scrolling.** Open a finished meeting, press play, keep "Follow" on, then drag the
   player's position slider around. The transcript should glide along smoothly — no jittery
   restarts. Then type something in "Find in transcript": the list should jump instantly (no
   sliding). Click the little up/down arrows next to it: those SHOULD slide smoothly.
2. **The orange "…may need a look" banner.** While audio is playing, click it. The view should go
   to that line and stay there (the Follow button turns itself off) — not get dragged back to the
   playing line a second later.
3. **Dictation.** Hold your dictation key, say something, let go. The black pill should feel
   quick: "Pasted" appears promptly, the text in the pill never slides sideways, and the little
   bars move with your voice.
4. **Buttons.** Press and HOLD any small text button (like "Check Again") or an orange marker
   chip. It should visibly dim the instant you press down (the chip also shrinks a touch).
5. **Volume bar.** On the recording screen, talk quietly: only green should show. The bar should
   have to reach far right before any orange appears.
6. **Health card.** While recording, stay silent for a few seconds or mute the system audio: the
   "Recording is healthy" line should softly fade to the warning — not blink/snap.
7. **Reduce Motion.** Turn on System Settings → Accessibility → Motion → Reduce Motion, and
   repeat 1, 3, and 6. Everything should still gently fade, but nothing should slide or bounce.

Say "all good" in chat, or describe anything that looks off.

**Problem.** All five F119 plans are executed, workflow-verified, and green on build/tests, but
SwiftUI has no render harness — feel is verifiable only on screen.

**Impact.** Craft only; a mis-judged value (press-dim depth, scroll spring, meter reveal) would
ship unnoticed.

**Verification.** The checklist above; anything off is filed as its own ticket.

### F117 — Eyeball the five F116 motion seams (and arbitrate one verifier disagreement)

- **Status:** needs-human
- **Owner:** —
- **Severity:** low
- **Area:** ui
- **Filed:** 2026-07-31 by Claude Code (Fable 5, apple-design redesign session)

**What I need from you** (plain version — same app session as F124 above):

1. **When a transcription finishes** (watch the meeting page as it completes): the "processing"
   card should smoothly fade away as the summary and transcript fade in. **The important part:**
   nothing should visibly jump, snap, or briefly pile on top of each other.
2. **Pin a meeting** (right-click → Pin to Top): the row should glide to the top, not teleport.
   **Delete one:** the row should collapse away smoothly. And typing in search must stay instant.
3. **Press Summarize** on a meeting: the spinner should fade into the finished summary.
4. **Add or remove vocabulary terms:** the list should update smoothly, not pop.
5. **Run "Test Recording…"**: the sheet's steps (countdown → analyzing → result) should
   cross-fade into each other, not hard-swap.

Item 1 is the one I most need your eyes on — it settles an internal disagreement about how these
fades behave. Say "all good" or describe what you saw.

**Problem.** The F116 seams are build/test/workflow-verified but SwiftUI has no render harness, and
one round-2 verifier claim about transition layout mechanics contradicts established SwiftUI
behavior — only looking at the running app settles it.

**Impact.** Craft only; a wrong call here means a visible snap at the app's payoff moment.

**Verification.** The checklist above; any artifact seen is filed as its own ticket.
