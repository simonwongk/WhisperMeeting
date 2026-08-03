# Ticket board

**The rules for this board — how to file, claim, close, and log tickets, plus the ID scheme, status
vocabulary, definition of done, and the ticket template — live in [`../AGENTS.md`](../AGENTS.md).
Read them before touching this file.** This file holds **open** work only; closed tickets move to
[`TICKET_LOG.md`](TICKET_LOG.md), and tickets blocked on a human action or decision move to
[`NEEDS_HUMAN.md`](NEEDS_HUMAN.md).

**Next free ID: `F149`.**

---

# Open tickets

_Filed 2026-08-03 from an external read-only audit of this session's work (at `22d60bd`). The three
most urgent (F92 transcript loss, F92 non-WAV slicing, backup free-space false-reject) were fixed
immediately — see F134/F135/F136 in [`TICKET_LOG.md`](TICKET_LOG.md). The rest are below._

### F137 — Backup safety: numeric-folder pruning can delete unrelated user data; no source/dest guard

- **Status:** open
- **Owner:** —
- **Severity:** critical
- **Area:** recovery
- **Filed:** 2026-08-03 by Claude Code (Opus 4.8), from audit

**Problem.** `BackupCoordinator` (F90) writes generations as top-level integer-named dirs directly under
the chosen folder and prunes **any** numeric subfolder there — so backing up into a folder that contains
e.g. `2024/` can delete it (`BackupCoordinator.swift:80,122`). There is also no check that the destination
is inside the source library (or vice versa), so backing up into the library recursively grows future
backups (`:35`). A failed run leaves a partial numeric dir that later looks like a complete generation
(`:52`). Related: backup runs on the main actor and can run mid-recording over changing files, and it
enumerates the **whole** Application Support dir (models/runtimes), not just the meeting library
(`MeetingStore.swift:155`).

**Impact.** Potential deletion of unrelated user files (critical), corrupt/huge backups, UI stalls. F90 is
**live in the installed app**, so this risk is real now.

**Proposed fix (on-disk layout change — needs owner sign-off).** Write generations only under a dedicated
managed subfolder (e.g. `<chosen>/WhisperMeet Backups/`) and prune only generations there; refuse when
source/dest overlap; stage each generation and mark it `.complete`, pruning only marked generations and
cleaning stale partials; scope the source to the meeting library (Recordings/ + meetings.json +
vocabulary.json); guard against running while recording; move copy/hash off the main actor.

**Verification.** Red-green: a destination containing a non-generation numeric folder is never pruned;
overlapping source/dest is refused; an interrupted generation is not treated as complete; the library is
scoped correctly. Manual: back up, confirm only the managed subfolder is touched.

### F138 — Transcript/notes edits can be lost on app termination (debounce not flushed on quit)

- **Status:** open
- **Owner:** —
- **Severity:** high
- **Area:** ui
- **Filed:** 2026-08-03 by Claude Code (Opus 4.8), from audit

**Problem.** F40/F133 debounce index writes (0.5 s) and flush only on editor `.onDisappear`
(`MeetingStore.swift:276`), not on app termination (`AppEntry.swift`). A normal quit within the debounce
window — or a crash/force-quit — loses the last edit.

**Proposed fix.** Flush pending edits on `applicationWillTerminate`/scene-inactive; consider a shorter
debounce or write-through on focus change. **Verification.** Test that a pending edit is flushed by the
termination hook; manual quit-after-typing check.

### F139 — Keyboard-command cancel has no confirmation and can race Stop/finalization

- **Status:** open
- **Owner:** —
- **Severity:** high
- **Area:** ui
- **Filed:** 2026-08-03 by Claude Code (Opus 4.8), from audit

**Problem.** The ⌘-command "Cancel Recording" path (`AppEntry.swift:137`, F85) invokes
`cancelRecording()` with no confirmation (unlike the menu-bar two-step and the main-window dialog), and
cancel/stop are not serialized against a simultaneous finalization (`AudioCaptureEngine.swift:272`).

**Proposed fix.** Route the command through the same confirmation as the UI; serialize stop/cancel so a
cancel during `.stopping` can't corrupt finalization. **Verification.** Test the guard rejects/serializes;
manual race check.

### F140 — Normal transcription and the runtime installer don't guard against an active auxiliary run

- **Status:** open
- **Owner:** —
- **Severity:** high
- **Area:** transcription
- **Filed:** 2026-08-03 by Claude Code (Opus 4.8), from audit

**Problem.** Second-opinion/segment-rerun (F88/F92) guard against each other and normal transcription via
`isRunningAuxiliaryEngine`, but `beginTranscription`/`performTranscription` (`AppModel.swift:1002`) and the
Qwen installer do **not** check `isRunningAuxiliaryEngine` — so a normal transcription or model install can
start atop an in-flight auxiliary engine run, contending for CPU/model.

**Proposed fix.** Make the busy-guard symmetric: normal transcription + installer also refuse while an
auxiliary run is active. **Verification.** Test that begin/install is rejected while an auxiliary run is in
flight.

### F141 — Diagnostics export can leak absolute paths despite the "path-free" promise

- **Status:** open
- **Owner:** —
- **Severity:** high
- **Area:** privacy
- **Filed:** 2026-08-03 by Claude Code (Opus 4.8), from audit

**Problem.** The Settings copy promises structural-only, path-free diagnostics, but raw error strings are
exported (`DiagnosticsExport.swift:16`) and subprocess/transcoder diagnostics can carry absolute paths
(`DiagnosticsBundleBuilder.swift:49`; also the Qwen traceback / afconvert stderr surfaced via F118).

**Proposed fix.** Redact home/absolute paths from any error text before it enters the diagnostics bundle
(and consider the same for OSLog). **Verification.** Red-green: an error string containing `/Users/<name>/…`
is redacted in the exported bundle.

### F142 — "Second opinion": false "No differences" on engine-launch failure; no engine/language snapshot

- **Status:** open
- **Owner:** —
- **Severity:** medium
- **Area:** transcription
- **Filed:** 2026-08-03 by Claude Code (Opus 4.8), from audit

**Problem.** When the other engine fails to launch, `computeSecondOpinion` sets an alert but leaves
`secondOpinionSpans` nil, and the open sheet renders nil as "No differences to show"
(`ContentView.swift` SecondOpinionSheet). It also picks the "other" engine relative to **current**
Settings, not the engine/language the meeting was actually transcribed with, so it can re-run the same
engine or a changed language (`AppModel.swift:327`).

**Proposed fix.** Distinguish "failed", "running", and "no differences" states in the sheet; persist the
meeting's engine/language (or snapshot at transcription time) and compare against that.
**Verification.** Test the failure state doesn't read as agreement; test the compared engine is the
genuine alternative.

### F143 — Library integrity flags valid imported (non-WAV) media as corrupt

- **Status:** open
- **Owner:** —
- **Severity:** medium
- **Area:** meetings
- **Filed:** 2026-08-03 by Claude Code (Opus 4.8), from audit

**Problem.** `MeetingIntegrityChecker` (`:78`) assumes every recording is a RIFF/WAV; an imported
`.m4a/.mp3/.mp4/…` meeting is reported as a truncated/corrupt WAV. **Proposed fix.** Only apply WAV
inspection to `.wav` recordings; treat other containers as opaque (existence/size only).
**Verification.** Red-green: an imported non-WAV meeting produces no false corruption finding.

### F144 — A partial-segment transcription result can discard its fuller `text`

- **Status:** open
- **Owner:** —
- **Severity:** medium
- **Area:** transcription
- **Filed:** 2026-08-03 by Claude Code (Opus 4.8), from audit

**Problem.** `apply(result:to:)` (`AppModel.swift:1168`) renders segments whenever there is ≥1, without
checking they reconstruct the full `text`; a result with a few segments but a fuller `text` loses content.
**Proposed fix.** When segments don't cover `text`, fall back to (or reconcile with) the full text.
**Verification.** Red-green over a result whose segments are shorter than `text`.

### F145 — Qwen-only user can still fail to import .m4a/.aac (ffmpeg not verified by installer)

- **Status:** open
- **Owner:** —
- **Severity:** medium
- **Area:** transcription
- **Filed:** 2026-08-03 by Claude Code (Opus 4.8), from audit

**Problem.** mlx-audio delegates `.m4a/.aac` to ffmpeg (`AudioTranscoder.swift:9` treats them as native),
but `setup-qwen-asr.sh` (`:123`) neither installs nor verifies ffmpeg — so a Qwen-only user importing those
still fails. **Proposed fix.** Either have the Qwen installer ensure ffmpeg, or add `.m4a/.aac` to the
decode-first (afconvert) set so they don't depend on ffmpeg. **Verification.** Real-runtime: `.m4a` import
transcribes on a Qwen-only setup.

### F146 — Cancel/Delete swallow filesystem errors (may claim success or orphan audio)

- **Status:** open
- **Owner:** —
- **Severity:** medium
- **Area:** meetings
- **Filed:** 2026-08-03 by Claude Code (Opus 4.8), from audit

**Problem.** Deletion paths (`MeetingStore.swift:313`, `AudioCaptureEngine.swift:280`) `try?`-swallow
errors, so a failed audio removal can still report success or leave the index/audio inconsistent.
**Proposed fix.** Surface removal failures; keep index and audio consistent on partial failure.
**Verification.** Red-green with an un-removable file (e.g. permissions) → error surfaced, no false success.

### F147 — Dashboard generator refuses the valid zero-open-tickets state; F123 log stale

- **Status:** open
- **Owner:** —
- **Severity:** low
- **Area:** tooling
- **Filed:** 2026-08-03 by Claude Code (Opus 4.8), from audit

**Problem.** `generate-tickets-dashboard.py:240` aborts when it parses zero active tickets, so a genuinely
empty board can't refresh (it conflates "empty" with "parse failed"). Separately, F123's log entry
describes the old JS dashboard, not the current static generator. **Proposed fix.** Emit a valid
"no open tickets" dashboard when the parse clearly succeeded but is empty (distinguish from a parse error);
add a correction note to F123. **Verification.** Generator produces a dashboard from an empty board.

### F148 — Verify (or refute) the 8 suspicious audit risks with targeted reproductions

- **Status:** open
- **Owner:** —
- **Severity:** medium
- **Area:** transcription
- **Filed:** 2026-08-03 by Claude Code (Opus 4.8), from audit

**Problem.** The audit listed 8 unconfirmed risks needing reproduction: startup-recovery overwriting good
index fields on a path mismatch; >4 GB / >12.4 h RIFF size overflow; capture-gap timestamp drift; the
Qwen helper loading the whole decoded file before chunking (+ the still-pending 30–60 min real-meeting
validation); process-tree cancellation (ffmpeg descendants); `../` path-traversal in a corrupt index;
OSLog path leakage; and the CJK-as-Chinese alignment heuristic on English-dominant code-switching.
**Proposed fix.** Reproduce each; convert confirmed ones into their own tickets, close refuted ones with
evidence. **Verification.** Each item has a recorded repro or refutation.

_(History note: the audit also flagged process-integrity gaps — missing `in-progress` states, post-close
log edits, evidence not always pasted, and the absent F94–F99 / F102–F109 ID ranges. These are
process/bookkeeping items to reconcile, not runtime defects; tracked here rather than as code tickets.)_
