# F188 item 1 — where to put a schema version, when there is nowhere to put one

**Status:** design note, 2026-09-17, whisper-62. **Decision required from the user.** No code.
**Ticket:** F188 item 1.

This exists because I had classified the whole item as "needs the user" when only the *decision*
does. The analysis does not, and doing it first is the difference between a question that takes two
minutes to answer and one that takes an afternoon.

## The problem, stated exactly

`meetings.json` is a **bare JSON array** of records. `BackupJSONStore.load()` does
`decoder.decode(Value.self, from: data)` where `Value` is `[MeetingRecord]`, so the top level is an
array and nothing else.

There is therefore nowhere to record a schema version — and the act of *creating* somewhere is
itself the incompatible change. Wrapping the array in `{"version": 2, "meetings": [...]}` means
every build that has ever shipped fails to decode the file on its next launch, which is
`F187`'s degraded read-only state at best and the 2026-08-14 wipe at worst. **The fence cannot be
erected without the first breakage being the fence itself.**

## What the fence is actually for

Worth being precise, because it narrows the options. From `LIBRARY_INDEX_WIPE_POSTMORTEM_2026-08-14`:
a newer build wrote a payload an older build could not read, and the older build overwrote it. The
fence's job is to let an **older** reader recognise "this file is from the future" and **refuse**
rather than overwrite.

That is a statement about *readers that already exist and cannot be changed*. Every option below
has to be judged on what a build shipped months ago does when it meets the new file — not on what a
future build does, which is the easy half.

## The three options

### A. One-time flag day — wrap the array in an envelope

`{"schemaVersion": 2, "meetings": [...]}`.

- **Old readers:** fail to decode. `F187`'s quarantine-and-degrade fires, so the library goes
  read-only with the bytes preserved. Not a wipe — `F190` made the write path refuse while degraded
  — but the user sees a broken library and has to recover.
- **Cost:** exactly the harm the fence exists to prevent, paid once, deliberately, to every user
  who ever downgrades across the boundary.
- **Benefit:** the only option where the version is unambiguous and cheap to read forever after.

### B. Per-record version field

Each `MeetingRecord` carries `"schemaVersion": 2`.

- **Old readers:** decode fine. An unknown key is ignored by `Codable`, which
  `PersistedRootSurvivalTests` now asserts. **No breakage at all.**
- **Cost:** the fence does not fence. An old reader that ignores the field cannot refuse on it, so
  it still overwrites. This option is a version *marker*, useful for diagnosis and migration, and
  not a guard — unless a future reader is changed to check it, which does nothing for the readers
  that already exist.
- **Benefit:** free to introduce, and it makes every record self-describing, which helps `F289`'s
  folder rebuild and any future migration.

### C. Sidecar version file

`meetings.schema.json` beside the index, holding `{"schemaVersion": 2}`.

- **Old readers:** decode the index fine and never look at the sidecar. **No breakage**, and also
  no refusal — same limitation as B for existing readers.
- **Cost:** a second file that can disagree with the first. `F190`'s whole design is about the
  primary, backup and ledger being consistent; adding a fourth file with its own failure modes, and
  one that is *advisory*, invites a state where the sidecar says 2 and the index is 1.
- **Benefit:** the index's bytes never change shape, so nothing that reads it today can break.

## What I would recommend, and the part that changes the question

**B now, A never, and accept that the fence is retrospective.**

The uncomfortable truth the three options share: **no change to the file can make an
already-shipped reader refuse.** A reader that does not know about versions cannot check one. So the
fence's stated goal — protect against a downgrade to an existing build — is **not achievable by a
format change at all**. Only A achieves it, and it achieves it by *being* the breakage.

That reframes the decision. It is not "which fence" but:

1. **Do we accept one deliberate breakage to protect all future ones (A)?** Defensible if
   downgrades are expected to keep happening. The user is the only person who knows whether they
   install old builds.
2. **Or do we accept that existing readers cannot be protected, mark the data for the future (B),
   and protect downgrades by a different mechanism entirely?**

If (2), the different mechanism is the one `F188` item 3 already names — the exclusive
library-instance guard — plus `F190`'s generations, which already make a bad write recoverable.
That is protection by *recovery and mutual exclusion* rather than by format, and both exist or are
specified.

I recommend (2) because `F190`, `F187`, `F193` and `F191` between them already turn "an old build
wrote something wrong" from a wipe into a recoverable incident, which is most of what A would buy —
and A's cost lands on the user, once, guaranteed, whereas its benefit is speculative.

## The decision I need

One of:

- **"Flag day"** — I implement A, with a migration that writes the envelope once and a release note
  that downgrading past this build requires the recovery flow.
- **"Mark it"** — I implement B: a `schemaVersion` on each record, no envelope, no breakage, and
  `F188` item 1 closes as "marked, not fenced" with this note as the reasoning.
- **"Neither yet"** — item 1 stays open with this note attached, and nothing is written. Costs
  nothing except that the next person re-derives the analysis.

## What I am not asking

Whether to *check* a version once one exists. That is free and obvious for future readers and needs
no decision. The question is only whether to pay A's breakage.
