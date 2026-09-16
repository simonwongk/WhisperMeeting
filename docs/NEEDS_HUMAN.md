# Needs human

The queue of tickets blocked on a physical action or a decision only the user can make — each with a
**What I need from you:** line. How an entry arrives here, and the cap on this file, are governed by
the ticket rules in [`../AGENTS.md`](../AGENTS.md); open work stays in [`TICKETS.md`](TICKETS.md).

---

### F243 — Decide whether Qwen meeting transcription may skip near-silent chunks

- **Status:** needs-human
- **Owner:** simonwang
- **Severity:** low
- **Area:** transcription
- **Filed:** 2026-09-16 by whisper-62, from F242

**What I need from you:** a yes or no on dropping near-silent 60 s chunks before transcription.

**Problem.** F240 measured that a batch containing two near-silent chunks discarded 52.1% of its
decode steps — those chunks emitted only 7 and 21 tokens, yet each still paid a full audio-encoder
pass and a full prefill, both compute-bound. A silence gate before `plan_batches` in
`Scripts/qwen_transcribe.py` would decline to transcribe them, rather than recovering part of the
waste afterwards as F240's row eviction does. Estimated at about 8.6% of the run — larger than
everything F240 shipped combined.

**Impact.** It changes the transcript, which is why it is not mine to decide. A chunk the gate judges
silent contributes no text, so genuinely quiet speech — someone far from the microphone, a whispered
aside — would be dropped rather than transcribed badly. `README.md` states the app is for "people who
need an *accurate* record of a meeting", so this trades recall for speed against the product's stated
purpose.

**Verification.** If approved: a threshold chosen against real recordings, F241's fixture landed
first (the committed bench clips contain no silence, so there is currently no way to test a gate at
all), and a measurement showing which utterances the chosen threshold drops. If declined: close this
entry `won't-fix` and record the reason in `TICKET_LOG.md` so it is not re-proposed.
