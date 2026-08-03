# Ticket board

**The rules for this board — how to file, claim, close, and log tickets, plus the ID scheme, status
vocabulary, definition of done, and the ticket template — live in [`../AGENTS.md`](../AGENTS.md).
Read them before touching this file.** This file holds **open** work only; closed tickets move to
[`TICKET_LOG.md`](TICKET_LOG.md), and tickets blocked on a human action or decision move to
[`NEEDS_HUMAN.md`](NEEDS_HUMAN.md).

**Next free ID: `F150`.**

---

# Open tickets

_Filed 2026-08-03 from an external read-only audit of this session's work (at `22d60bd`). The three
most urgent (F92 transcript loss, F92 non-WAV slicing, backup free-space false-reject) were fixed
immediately — see F134/F135/F136 in [`TICKET_LOG.md`](TICKET_LOG.md). The rest are below._

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
