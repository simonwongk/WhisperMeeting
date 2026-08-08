# Needs human

The queue of tickets blocked on a physical action or a decision only the user can make — each with a
**What I need from you:** line. How an entry arrives here, and the cap on this file, are governed by
the ticket rules in [`../AGENTS.md`](../AGENTS.md); open work stays in [`TICKETS.md`](TICKETS.md).

---

**The queue is currently empty — nothing is blocked on a human.**

F176 ("Install and select full Xcode so the Swift Testing suite can run") was closed `invalid` on
2026-08-08: its observation was right that a *bare* `swift test` fails on this toolchain, but its
blocking claim was wrong. `Scripts/quality-check.sh` already supplies the framework/rpath flags that
F166 added, and it runs the **full suite** here — 435 tests green on the day F176 was closed. Installing
full Xcode remains a convenience for running `swift test` directly; it is not a prerequisite for
verifying a change. See `TICKET_LOG.md` for the evidence.
