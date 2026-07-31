# Needs human

The queue of tickets blocked on a physical action or a decision only the user can make — each with a
**What I need from you:** line. How an entry arrives here, and the cap on this file, are governed by
the ticket rules in [`../AGENTS.md`](../AGENTS.md); open work stays in [`TICKETS.md`](TICKETS.md).

---

### F27 — Whisper vs Qwen dictation is unverified with a real microphone

- **Status:** needs-human
- **Owner:** —
- **Severity:** medium
- **Area:** dictation
- **Filed:** 2026-07-30 by Claude Code

**What I need from you:** with a real microphone, hold push-to-talk and speak the same phrase through
both dictation engines (Whisper and Qwen) — including noisy, accented, and mixed English/Mandarin
takes — then record the release-to-text latency and any corrections needed. Automated key injection
is (correctly) rejected by the global-hotkey path and microphone input cannot be synthesised, so only
a person can produce this evidence.

**Problem.** The two engines have only been compared on the synthetic `Scripts/bench/clips` corpus,
fed to the helpers as files. Real push-to-talk adds microphone capture, room noise, accents,
variable clip length, and end-to-end release-to-text latency, none of which the file-fed comparison
exercises.

**Impact.** Any recommendation to prefer Qwen for dictation rests on clean synthetic audio and a
zero-error result that is almost certainly optimistic. The 0.36 s vs 1.43 s per-clip gap is the more
robust half of the finding, but it still excludes capture and delivery.

**Blocked by:** the user. Automated key injection is correctly rejected by the app's global hotkey
path, and microphone input cannot be synthesised — a person must hold the trigger and speak.

**Verification.** Same phrase through both engines with noise, accents, and mixed English/Mandarin.
Record release-to-text latency and any corrections needed. Append the numbers to `TICKET_LOG.md` and
correct the benchmark claims in `CHANGELOG.md` if they do not hold up.
