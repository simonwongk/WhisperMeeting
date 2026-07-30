# Ticket board

**Single source of truth for outstanding work.** Every coding agent working on WhisperMeet — Claude
Code, Codex, or any other — MUST read this file before starting, file what it finds here, and record
what it resolves in [`TICKET_LOG.md`](TICKET_LOG.md).

This file holds **open** work only. Closed tickets move to the log; do not accumulate history here.

Related, and deliberately separate:
- [`ROADMAP.md`](ROADMAP.md) — prioritized *feature* backlog for improvement rounds. Aspirational.
- [`CHANGELOG.md`](CHANGELOG.md) — narrative record of shipped cycles, written for a human reader.
- [`TICKET_LOG.md`](TICKET_LOG.md) — append-only record of every ticket closed, with real evidence.

A roadmap item becomes a ticket when someone commits to doing it. A ticket is a concrete, verifiable
unit of work with an owner-independent definition of done.

## Rules for agents

1. **Read this file first.** If you are about to do work that is not on the board, file it as a
   ticket before you start, so parallel agents can see it.
2. **File what you find.** Any defect, regression, unverified claim, or follow-up you discover during
   other work gets a ticket — even if you are not going to fix it. Do not leave findings only in a
   chat reply; that context dies with the session.
3. **Claim before you work.** Set `Status: in-progress` and put your agent/session identifier in
   `Owner` in the same commit that starts the work. Never take a ticket already `in-progress`.
4. **Never delete a ticket.** Close it by moving the entry to `TICKET_LOG.md` with an outcome — that
   includes `wontfix` and `invalid`. Deleting loses the reasoning.
5. **One ticket, one commit trail.** Reference the ID in every commit message that touches it, in the
   existing repo style: `fix(dictation): keep helper stdout pure JSON (F24)`.
6. **Log on close.** Append to `TICKET_LOG.md` with real command output, not a summary of intent. The
   repo's culture is evidence over assertion — see the existing entries.

## ID allocation

IDs are `F<n>`, continuing the finding-ID series already used in commits and `CHANGELOG.md`.
**F1–F23 are consumed** by earlier review rounds (they predate this file and were never persisted —
their outcomes live in `CHANGELOG.md`).

**Next free ID: `F28`.** When you file a ticket, take the next ID and bump this line in the same
commit. If you hit a collision because another agent raced you, take the next free one and move on.

## Status vocabulary

| Status | Meaning |
|---|---|
| `open` | Filed, unclaimed, ready for anyone. |
| `in-progress` | Claimed. `Owner` is set. Do not touch. |
| `blocked` | Cannot proceed. `Blocked by:` states exactly what is needed and from whom. |
| `needs-human` | Requires a physical action or a decision only the user can make. |

Closed states (`fixed`, `wontfix`, `invalid`, `duplicate`) exist only in `TICKET_LOG.md`.

## Definition of done

A ticket may only be closed `fixed` when all of these hold:

- `swift build` and `swift test` both pass, and the test count did not silently drop.
- Behaviour changes are covered by a test that **fails before the fix and passes after**. State both
  results in the log. A fix with no failing-test-first evidence is not done.
- If the change touches the Whisper or Qwen subprocess contract, the live official docs were fetched
  and checked per [`../AGENTS.md`](../AGENTS.md) — flags and model names are never guessed.
- If the change touches a runtime helper or model adapter, it was exercised against the **real
  installed model**, not only a stub. Stubs cannot catch upstream API drift.
- The non-negotiable invariants in [`PRODUCT_SPEC.md`](PRODUCT_SPEC.md) are intact: local-only except
  opt-in Claude summaries, the recording is the source of truth, no diarization, original language
  only.
- No user meeting, recording, index, or transcript was read or modified for testing. Use
  `Scripts/bench/clips`.

## Ticket template

```markdown
### F<n> — <one-line summary>

- **Status:** open
- **Owner:** —
- **Severity:** high | medium | low
- **Area:** dictation | meetings | transcription | recovery | ui | build | docs
- **Filed:** YYYY-MM-DD by <agent/session>

**Problem.** What is wrong, and the evidence it is wrong. Cite `file.swift:line`.

**Impact.** Who or what breaks, and how it presents to the user.

**Proposed fix.** Optional. Say so if you are unsure.

**Verification.** How the fixer will prove it is done.
```

---

# Open tickets

### F25 — A shipped helper-script fix does not reach disk until its engine is selected

- **Status:** open
- **Owner:** —
- **Severity:** low
- **Area:** dictation
- **Filed:** 2026-07-30 by Claude Code (review of `e9bca61`)

**Problem.** `DictationController.ensureHelperInstalled()`
(`Sources/WhisperMeet/Dictation/DictationController.swift:209`) syncs only the *currently selected*
engine's helper from the app bundle. After F24 shipped in `64455ec`, the installed
`Runtime/whisper_dictate_server.py` on this machine — which has Qwen selected — stayed at the old
hash `80e86bdaf487` while the bundle carried the fixed `a1d671e3e6da`.

**Impact.** Not a correctness bug today: the sync runs at `DictationController.swift:152` *before*
the replacement engine is constructed, so the fixed helper is always on disk before it is used. But
on-disk state does not reflect the shipped build, which makes diagnostics and manual inspection
misleading, and it means a helper fix is one user action away from mattering rather than applied on
update.

**Proposed fix.** Sync both engines' helpers on launch (or whenever the bundle version changes)
rather than only the selected one. Cheap — a content comparison and a small file write.

**Verification.** Install a build whose Whisper helper differs from the runtime copy while Qwen is
selected; assert the runtime copy matches the bundle after launch without switching engines.

### F26 — Dictation diagnostics go stale when the model is changed

- **Status:** open
- **Owner:** —
- **Severity:** low
- **Area:** ui
- **Filed:** 2026-07-30 by Claude Code (review of `e9bca61`)

**Problem.** `DictationView` refreshes `diag` on `onAppear`, on the Refresh button, and when a
self-test finishes (`Sources/WhisperMeet/DictationView.swift:38,60,90`) — but not when
`dictation.selectedEngine` changes. The model picker lives in `SettingsView`, a separate window.

**Impact.** Changing the recognition model in Settings leaves the Dictation tab showing the previous
engine's rows — including the `"\(diag.engineName) runtime"` label and an Install/Repair button that
targets the wrong runtime — until the user presses Refresh.

**Proposed fix.** `.onChange(of: dictation.selectedEngine) { _, _ in diag = dictation.diagnostics() }`.

**Verification.** Not unit-testable (SwiftUI view; the `WhisperMeet` target has no test suite).
Verify manually with both windows open, and say so explicitly in the log.

### F27 — Whisper vs Qwen dictation is unverified with a real microphone

- **Status:** needs-human
- **Owner:** —
- **Severity:** medium
- **Area:** dictation
- **Filed:** 2026-07-30 by Claude Code

**Problem.** The two engines have only been compared on the synthetic `Scripts/bench/clips` corpus,
fed to the helpers as files. Real push-to-talk adds microphone capture, room noise, accents, variable
clip length, and end-to-end release-to-text latency, none of which the file-fed comparison exercises.

**Impact.** Any recommendation to prefer Qwen for dictation rests on clean synthetic audio and a
zero-error result that is almost certainly optimistic. The 0.36 s vs 1.43 s per-clip gap is the more
robust half of the finding, but it still excludes capture and delivery.

**Blocked by:** the user. Automated key injection is correctly rejected by the app's global hotkey
path, and microphone input cannot be synthesised — a person must hold the trigger and speak.

**Verification.** Same phrase through both engines with noise, accents, and mixed English/Mandarin.
Record release-to-text latency and any corrections needed. Append the numbers to `TICKET_LOG.md` and
correct the benchmark claims in `CHANGELOG.md` if they do not hold up.

---

*Board created 2026-07-30. Seeded from the review of `e9bca61` and `64455ec`.*
