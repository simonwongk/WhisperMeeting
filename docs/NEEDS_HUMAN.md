# Needs human

The queue of tickets blocked on a physical action or a decision only the user can make — each with a
**What I need from you:** line. How an entry arrives here, and the cap on this file, are governed by
the ticket rules in [`../AGENTS.md`](../AGENTS.md); open work stays in [`TICKETS.md`](TICKETS.md).

---

## F275 — Confirm the capture restart on the hardware, and set the padding cap

**Status:** the code is shipped and tested; these two things cannot be settled without you.

**What I need from you:** two physical runs and one number.

**The runs.** The restart decision is pinned by tests, but no test can prove that rebuilding an
`SCStream` after a display disappears actually resumes audio on a real Mac — that depends on
ScreenCaptureKit's behaviour, not on this code.

1. **Docked, lid closed.** Start a recording with an external display connected, close the lid, keep
   talking for a minute, reopen. Expected: recording continues, and a banner says it resumed after a
   display was disconnected with the gap marked as silence. This is the case that lost you 63
   minutes of a meeting, so it is the one worth doing first.
2. **Undocked, lid closed.** Same, but with no external display, so the Mac actually sleeps. Expected:
   the recording is finalized and saved, and the banner says so rather than the app silently showing
   a recording that is no longer running.

If you can, note the `SCStream` error each time — `log show --last 10m --predicate 'subsystem ==
"com.whispermeet.app"' | grep -i restart` will show what the app logged.

**The number: how long a gap may be padded before the meeting is split instead.** Default shipped:
**5 minutes**. Padding a gap writes real silence into the audio so that timestamps after it still
line up with the clock; the trade is disk, at **384 KB per second** of silence across the two raw
tracks:

| Gap padded | Disk it costs | Reasonable? |
|---|---|---|
| 1 min | 23 MB | clearly fine |
| 5 min (current default) | 115 MB | a coffee break, still one meeting |
| 30 min | 690 MB | a long lunch — probably two meetings |
| 8 h (lid shut overnight) | 11 GB | clearly not |

Being wrong either way is harmless: too low and you get two meetings instead of one, too high and
you get more silence. Nothing about the timeline breaks at any value. Say a number and I will change
the default; leave it and 5 minutes stands.

---

F243 was decided by the user on 2026-09-16 and moved to `TICKETS.md`: a silence gate may drop a
chunk only when it is COMPLETELY silent. The broader near-silent gate the estimate was based on
was not authorised.
