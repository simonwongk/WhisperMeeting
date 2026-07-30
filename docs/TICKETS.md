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
2. **File what you find.** Any defect, regression, unverified claim, or follow-up you discover
   during other work gets a ticket — even if you are not going to fix it. Do not leave findings only
   in a chat reply; that context dies with the session.
3. **Claim before you work.** Set `Status: in-progress` and put your agent/session identifier in
   `Owner` in the same commit that starts the work. Never take a ticket already `in-progress`.
4. **Never delete a ticket.** Close it by moving the entry to `TICKET_LOG.md` with an outcome — that
   includes `wontfix` and `invalid`. Deleting loses the reasoning.
5. **One ticket, one commit trail.** Reference the ID in every commit message that touches it, in
   the existing repo style: `fix(dictation): keep helper stdout pure JSON (F24)`.
6. **Log on close.** Append to `TICKET_LOG.md` with real command output, not a summary of intent.
   The repo's culture is evidence over assertion — see the existing entries.

## ID allocation

IDs are `F<n>`, continuing the finding-ID series already used in commits and `CHANGELOG.md`.
**F1–F23 are consumed** by earlier review rounds (they predate this file and were never persisted —
their outcomes live in `CHANGELOG.md`).

**Next free ID: `F38`.** When you file a ticket, take the next ID and bump this line in the same
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
- The non-negotiable invariants in [`PRODUCT_SPEC.md`](PRODUCT_SPEC.md) are intact: local-only
  except opt-in Claude summaries, the recording is the source of truth, no diarization, original
  language only.
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

**Reproduced 2026-07-30 while fixing F29.** `Scripts/bench/dictation-ab.py` drives the *installed*
helpers, so it hit the stale copy and failed exactly as F24 did —
`turbo: helper never reported ready. / Detected language: English` — until the bundle copy was
synced by hand. This is no longer only a tidiness concern: any tool or diagnostic that reads the
installed runtime sees pre-fix code.

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

**Proposed fix.**
`.onChange(of: dictation.selectedEngine) { _, _ in diag = dictation.diagnostics() }`.

**Verification.** Not unit-testable (SwiftUI view; the `WhisperMeet` target has no test suite).
Verify manually with both windows open, and say so explicitly in the log.

### F27 — Whisper vs Qwen dictation is unverified with a real microphone

- **Status:** needs-human
- **Owner:** —
- **Severity:** medium
- **Area:** dictation
- **Filed:** 2026-07-30 by Claude Code

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

### F28 — `WhisperCore` is no longer framework-free

- **Status:** open
- **Owner:** —
- **Severity:** medium
- **Area:** build
- **Filed:** 2026-07-30 by Claude Code (two-axis review, standards)

**Problem.** `CLAUDE.md` states `WhisperCore` is "pure, `Sendable`, **framework-free** logic". Two
files now break that. 29 of 31 WhisperCore files import Foundation only; these are the exceptions:
- `Sources/WhisperCore/QwenASRClient.swift:2` — `import os`, and `:144` constructs
  `Logger(subsystem: "com.whispermeet.app", …)` inside the library. This also breaks *pure*: the
  alignment-failure warning becomes an OSLog side effect instead of being surfaced in
  `TranscriptionResult`, so neither callers nor tests can observe it. The app-identity string
  belongs in the `WhisperMeet` target.
- `Sources/WhisperCore/WarmWhisperDictationEngine.swift:2` — `import Darwin`, for `SIGKILL` at
  `:344`. Same rule, weaker case: there is no Foundation equivalent.

**Impact.** Erodes the split that makes `WhisperCore` unit-testable without a GUI. The
`QwenASRClient` case additionally hides a real diagnostic from tests, which is how the F24 class of
bug survives.

**Proposed fix.** Return the alignment warning through `TranscriptionResult` and let `WhisperMeet`
log it. For `SIGKILL`, either accept `import Darwin` with a documented exception in `CLAUDE.md`, or
move the force-stop into the app target.

**Verification.** `grep -rn "^import " Sources/WhisperCore/*.swift` shows Foundation only (plus any
exception `CLAUDE.md` explicitly sanctions); a test asserts the alignment warning is observable.

### F30 — Qwen alignment failure silently drops every timestamp

- **Status:** open
- **Owner:** —
- **Severity:** medium
- **Area:** transcription
- **Filed:** 2026-07-30 by Claude Code (two-axis review, both axes)

**Problem.** `PRODUCT_SPEC.md:18` requires "editable **timestamped** transcript segments", and `:27`
requires failures surfaced "in plain language". `QwenAlignedTranscript.swift` returns `[]` at five
guard sites (`:24,30,36,39,51`) — mapping is all-or-nothing, so a single mismatch anywhere drops
*every* timestamp. `AppModel.apply(result:to:)` (`AppModel.swift:965`) then stores untimestamped
plain text. The only trace is an `os.Logger` line (`QwenASRClient.swift:143-148`), which the user
never sees. `PRODUCT_SPEC.md` was edited in this same range but line 18 was left untouched.

**Impact.** A Qwen meeting can silently produce a transcript with no timestamps — no seek, no
playback sync — and the user is given no reason why.

**Proposed fix.** Surface the warning in the UI, and consider partial alignment (keep the sentences
that did map) instead of all-or-nothing. Amend `PRODUCT_SPEC.md:18` to state the documented
fallback.

**Verification.** Force an alignment mismatch; assert the user-visible explanation appears and that
`PRODUCT_SPEC.md` matches actual behaviour.

### F31 — Qwen meeting transcription reports no progress or ETA

- **Status:** open
- **Owner:** —
- **Severity:** medium
- **Area:** transcription
- **Filed:** 2026-07-30 by Claude Code (two-axis review, spec)

**Problem.** `QwenASRClient.swift:118-119` emits only `.preparing` / `.loadingModel` and never
`.transcribing` with a fraction. `ContentView.swift:1596-1601` therefore shows "Loading the
recognition model…" with an indeterminate bar for the entire run.

**Impact.** A one-hour Qwen meeting looks hung. The "transcription progress + ETA" delivered in
Round 0 (`ROADMAP.md`) silently does not apply to the newer engine.

**Verification.** A long Qwen run advances a determinate bar.

### F32 — "Original language only" is unenforced and untested on the Qwen path

- **Status:** open
- **Owner:** —
- **Severity:** medium
- **Area:** transcription
- **Filed:** 2026-07-30 by Claude Code (two-axis review, spec)

**Problem.** `PRODUCT_SPEC.md:16` forbids automatic translation. Whisper enforces it structurally by
pinning `--task transcribe`. Qwen has no equivalent: `Scripts/qwen_transcribe.py:74-78` passes a
language name into the model call, and nothing in the codebase asserts the output language matches
the input.

**Impact.** A non-negotiable invariant rests on model behaviour rather than on an enforced contract.
Upstream drift would be silent.

**Evidence it currently holds.** All ten `Scripts/bench/clips` returned original-language text on
2026-07-30 (en/zh/code-switch, zero error). That is empirical, not structural, and the corpus is
synthetic.

**Verification.** A regression test that fails if a Mandarin clip comes back in English.

### F33 — Installer crash recovery is only reachable from tests

- **Status:** open
- **Owner:** —
- **Severity:** medium
- **Area:** recovery
- **Filed:** 2026-07-30 by Claude Code (two-axis review, spec)

**Problem.** `Scripts/setup-qwen-asr.sh` gates its recovery branch on `QWEN_INSTALL_RECOVERY_ONLY`
(`:23`, `:99`). The only caller is `Tests/WhisperCoreTests/QwenInstallerRecoveryTests.swift:76` —
the app never invokes it.

**Impact.** `PRODUCT_SPEC.md:29-30` promises the previous runtime is preserved on failure. That
holds only within a single install process. After a force-quit mid-install, a ~4 GB backup directory
is orphaned and Qwen reports "not installed" until the user manually reinstalls.

**Verification.** Kill an install mid-run; on next launch the backup is reclaimed or removed without
user action.

### F34 — `QUICK_DICTATION_DESIGN.md` still locks dictation to Whisper turbo

- **Status:** open
- **Owner:** —
- **Severity:** low
- **Area:** docs
- **Filed:** 2026-07-30 by Claude Code (two-axis review, spec)

**Problem.** `docs/QUICK_DICTATION_DESIGN.md:44` still records "Transcription engine | Local Whisper
`turbo`" and `:16` "shares only the local Whisper runtime", while
`DictationController.swift:109-116` now offers Qwen. The only authorization for the change is the
same cycle's own work log.

**Impact.** The design doc contradicts shipped behaviour, so it can no longer be trusted as the spec
for this feature — which is what the Spec review axis judges against.

**Verification.** The design doc describes the selector, its default, and the vocabulary limitation.

### F35 — `SelectableDictationEngine.replace` is a non-atomic read → await → write

- **Status:** open
- **Owner:** —
- **Severity:** low
- **Area:** dictation
- **Filed:** 2026-07-30 by Claude Code (two-axis review, standards)

**Problem.** `DictationProtocol.swift:83-95`. The `NSLock` makes each accessor safe, but `replace`
reads `current`, awaits `retire()`, then installs — so two concurrent replaces can both retire the
same engine. Safety today comes only from the `@MainActor` `isActive` / `isSwitchingModel` guard in
`DictationController.setSelectedEngine`, which lives in the *other* target.

**Impact.** No data race; a logical one. The class advertises `@unchecked Sendable`, implying it is
self-sufficient, but its correctness depends on a caller in another module.

**Proposed fix.** Serialize `replace` inside the class, or document the caller contract on the type.

**Verification.** Two concurrent `replace` calls leave exactly one live engine.

### F36 — The Qwen subprocess contract has no upstream documentation anchor

- **Status:** open
- **Owner:** —
- **Severity:** low
- **Area:** docs
- **Filed:** 2026-07-30 by Claude Code (two-axis review, standards)

**Problem.** `docs/TICKETS.md:61` requires live-doc verification "per `../AGENTS.md`" for the
Whisper **or Qwen** contract, but `AGENTS.md` names only whisperai.com and
github.com/openai/whisper. There is no Qwen / `mlx-audio` source listed, so the Qwen call contract
(`Scripts/qwen_transcribe.py:70-75`, `Scripts/qwen_dictate_server.py:24-29` —
`generate(language=, chunk_duration=, min_chunk_duration=)`) is unanchored.
`docs/ASR_EVALUATION_LOG_2026-07-29.md:9-13` claims docs "were checked" but cites no URL or version,
unlike the F24 entry which cites `mlx_whisper/transcribe.py:175`.

**Impact.** A rule that cannot be followed as written. Qwen API drift would not be caught.

**Proposed fix.** Add the pinned `mlx-audio` source to `AGENTS.md`, or require citing the installed
package source (as F24 did) when no upstream doc exists.

### F37 — Dictation is blocked while a *meeting* model runtime installs

- **Status:** open
- **Owner:** —
- **Severity:** low
- **Area:** dictation
- **Filed:** 2026-07-30 by Claude Code (two-axis review, spec)

**Problem.** `AppEntry.swift:14-17` folds `model.isInstallingRecognitionRuntime` into dictation's
`isMicrophoneBusy`. The spec only required the reverse (a meeting must not start while dictation
owns the mic).

**Impact.** Probably desirable — a multi-GB install contends for CPU and memory — but it is
undocumented, and it is not a microphone conflict, so expressing it as "microphone busy" makes the
reason opaque to the user and to future readers.

**Verification.** Confirm the behaviour is intended, then document it and give it an accurate
user-facing reason.

---

*Board created 2026-07-30. Seeded from the review of `e9bca61` and `64455ec`.* *F28–F37 added
2026-07-30 from the two-axis review of `7e048ff...HEAD`.*
