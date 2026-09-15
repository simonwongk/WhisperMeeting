# Needs human

The queue of tickets blocked on a physical action or a decision only the user can make — each with a
**What I need from you:** line. How an entry arrives here, and the cap on this file, are governed by
the ticket rules in [`../AGENTS.md`](../AGENTS.md); open work stays in [`TICKETS.md`](TICKETS.md).

---

### F243 — Decide whether Qwen meeting transcription may skip near-silent chunks (~8.6% faster)

- **Filed:** 2026-09-15 by whisper-62, from F242
- **Severity:** low (a speed/accuracy trade, nothing is broken)

**What I need from you:** a yes or no on dropping near-silent 60 s chunks before transcription.

**The trade.** F240 measured that a batch containing two near-silent chunks discarded 52.1% of its
decode steps — those chunks emitted only 7 and 21 tokens, yet each still paid a full audio-encoder
pass and a full prefill, both compute-bound. Declining to transcribe them (rather than recovering
part of the waste afterwards, which F240's row eviction already does) is estimated at about 8.6% of
the run — larger than everything F240 shipped combined.

**Why it is your call and not mine.** It changes the transcript. A chunk the gate judges silent
contributes no text, so genuinely quiet speech — someone far from the mic, a whispered aside — would
be dropped rather than transcribed badly. The product exists for "people who need an *accurate*
record of a meeting", so I am not willing to trade recall for 8.6% without you saying so.

**If you say yes,** it needs a threshold chosen against real recordings, and F241's fixture first —
the committed bench clips contain no silence, so there is currently no way to test it.

F176 ("Install and select full Xcode so the Swift Testing suite can run") was closed `invalid` on
2026-08-08: its observation was right that a *bare* `swift test` fails on this toolchain, but its
blocking claim was wrong. `Scripts/quality-check.sh` already supplies the framework/rpath flags that
F166 added, and it runs the **full suite** here — 435 tests green on the day F176 was closed. Installing
full Xcode remains a convenience for running `swift test` directly; it is not a prerequisite for
verifying a change. See `TICKET_LOG.md` for the evidence.
