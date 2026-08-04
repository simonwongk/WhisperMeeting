# Ticket board

**The rules for this board — how to file, claim, close, and log tickets, plus the ID scheme, status
vocabulary, definition of done, and the ticket template — live in [`../AGENTS.md`](../AGENTS.md).
Read them before touching this file.** This file holds **open** work only; closed tickets move to
[`TICKET_LOG.md`](TICKET_LOG.md), and tickets blocked on a human action or decision move to
[`NEEDS_HUMAN.md`](NEEDS_HUMAN.md).

**Next free ID: `F164`.**

---

# Open tickets

Use the [work dashboard](tickets-dashboard.html) for a scan-first view. This Markdown file is the
authoritative queue: claim only a ticket that is `open`, and read [`NEEDS_HUMAN.md`](NEEDS_HUMAN.md)
before starting work that depends on a person.

## Ready to claim

### F150 — WAV UInt32 data-size field overflows for a single meeting longer than ~12.4 h

- **Status:** open
- **Owner:** —
- **Severity:** low
- **Area:** recording
- **Filed:** 2026-08-03 by Claude Code (Opus 4.8), from F148 #2

**Problem.** `meeting.wav` is 48 kHz mono 16-bit (96 000 B/s), so the `UInt32` `data`-chunk size
(`AudioCaptureEngine.swift:686`, clamped) and the wrapping RIFF size (`WAVWriter.swift:14`) overflow
at ~44 739 s ≈ 12.43 h. Samples are still written to disk, but strict readers (incl. ffmpeg) honor
the declared size and would ignore everything past ~4 GB. No meeting-duration cap exists.

**Impact.** A very long meeting can appear truncated when exported, played, or transcribed by a
strict WAV reader even though its later samples remain on disk.

**Proposed fix.** Cap/segment continuous recordings before 4 GB, or write
RF64/WAVE-with-extended-size; at minimum warn near the limit.

**Verification.** A synthetic >4 GB write is read back fully (or split).

### F151 — Mid-recording capture gaps drift because only the initial presentation offset is applied

- **Status:** open
- **Owner:** —
- **Severity:** low
- **Area:** recording
- **Filed:** 2026-08-03 by Claude Code (Opus 4.8), from F148 #3

**Problem.** `FloatTrackWriter` records a presentation time only for the first buffer
(`AudioCaptureEngine.swift:587-589`) and writes subsequent buffers contiguously with no gap
detection; the mixer pads only by the initial offset (`:641-654`). If ScreenCaptureKit drops/stalls
buffers mid-recording, post-gap samples pack earlier than their true time and the two channels
desync for the rest of the meeting. **Magnitude is runtime-dependent** (needs a buffer-drop repro).

**Impact.** A capture interruption can permanently misalign microphone and system audio after the
gap, degrading the accuracy of the resulting meeting recording and transcript.

**Proposed fix.** Detect inter-buffer PTS gaps and insert silence to preserve alignment.

**Verification.** Induce a mid-capture drop and compare channel alignment vs wall-clock.

### F152 — Qwen helper loads the whole decoded recording before chunking; long-meeting validation pending

- **Status:** open
- **Owner:** —
- **Severity:** low
- **Area:** transcription
- **Filed:** 2026-08-03 by Claude Code (Opus 4.8), from F148 #4

**Problem.** `Scripts/qwen_transcribe.py:126` decodes the entire file into one array before
chunking, and retains it for alignment slicing (~230 MB for 60 min @16 kHz mono float32, plus
decode/model working set). No 30–60 min real-meeting run with peak-RSS measurement exists.

**Impact.** Long recordings may consume enough memory to slow, fail, or make the opt-in Qwen path
unreliable before its real-meeting envelope is known.

**Proposed fix.** Validate a 30–60 min real run (measure peak RSS); if needed, stream/downcast.

**Verification.** Record peak RSS for a 60-min transcription within an acceptable envelope.

### F153 — Cancellation doesn't kill descendant processes (ffmpeg/afconvert)

- **Status:** open
- **Owner:** —
- **Severity:** low
- **Area:** transcription
- **Filed:** 2026-08-03 by Claude Code (Opus 4.8), from F148 #5

**Problem.** `ProcessCancellationController.cancel` sends SIGTERM to the direct child PID only
(`LocalWhisperClient.swift:321-328`); no process group is created/signaled, so a grandchild
`ffmpeg`/ `afconvert` spawned by the helper can survive a cancel (transient stray CPU/IO; no data
loss).

**Impact.** A canceled transcription can continue consuming CPU, storage, or audio-decoding
resources until its descendant process exits on its own.

**Proposed fix.** Start the child in its own process group and `killpg` on cancel.

**Verification.** Cancel mid-decode and confirm no orphaned decoder remains.

### F154 — OSLog logs `.public` error text that can include absolute paths

- **Status:** open
- **Owner:** —
- **Severity:** low
- **Area:** privacy
- **Filed:** 2026-08-03 by Claude Code (Opus 4.8), from F148 #7

**Problem.** Capture/dictation failures log `\(error.localizedDescription, privacy: .public)`
(`AudioCaptureEngine.swift:187-189`, `Dictation/DictationController.swift:212,270,372,433`), which
can embed absolute paths in the unified system log (Console/sysdiagnose). F141 redacted the
diagnostics *bundle*; this is the separate OSLog surface.

**Impact.** A local support or system-diagnostic log can expose private filesystem structure even
though exported diagnostics already redact it.

**Proposed fix.** Drop `.public` on `localizedDescription` or log a redacted/last-path-component
form (reuse `DiagnosticsBundleBuilder.redactPaths`).

**Verification.** A capture error logs without the absolute path.

### F155 — Qwen aligner treats any CJK character as Chinese on English-dominant chunks

- **Status:** open
- **Owner:** —
- **Severity:** low
- **Area:** transcription
- **Filed:** 2026-08-03 by Claude Code (Opus 4.8), from F148 #8

**Problem.** The per-chunk aligner language is `Chinese` if a chunk contains ANY CJK scalar
(`Scripts/qwen_transcribe.py:25-28`), unlike top-level detection's majority rule. An English
sentence with one CJK token is aligned as Chinese, possibly degrading its word timings. Bounded: on
alignment failure the full text is preserved (no dropped text). **Reliability impact needs a runtime
repro.**

**Impact.** Code-switched or English-dominant meetings can receive less accurate word timestamps
for affected chunks, weakening transcript navigation without losing their text.

**Proposed fix.** Use the majority-script rule per chunk too (or a threshold).

**Verification.** Compare aligner timing quality on an English-dominant single-CJK chunk under both
heuristics.

### F158 — Centralize the remaining shared motion durations

- **Status:** open
- **Owner:** —
- **Severity:** low
- **Area:** ui
- **Filed:** 2026-08-03 by /root, from F157 documentation audit

**Problem.** `DesignSystem.swift:57` hard-codes the reduced-motion fade duration and
`ContentView.swift:2996` separately hard-codes a segment-highlight duration. The existing design
system already centralizes other motion values, so these two values can drift without a named
semantic role.

**Impact.** Small visual changes can become inconsistent and harder to tune accessibly across the
app.

**Proposed fix.** Add named design-system motion tokens and replace the two inline durations.

**Verification.** Exercise the relevant state changes with and without Reduce Motion and confirm no
raw duplicate duration remains at the cited call sites.

### F159 — Prevent an older copy-prompt task from clearing newer feedback

- **Status:** open
- **Owner:** —
- **Severity:** low
- **Area:** ui
- **Filed:** 2026-08-03 by /root, from F157 documentation audit

**Problem.** Every press in `ContentView.swift:1583-1591` starts an independent two-second task that
sets `didCopyPrompt` to false. A task from an earlier press can therefore clear the confirmation
shortly after a later press.

**Impact.** The "Prompt Copied" acknowledgement can disappear too early during repeated use.

**Proposed fix.** Store and cancel the pending reset task before scheduling a replacement.

**Verification.** A focused state test proves a second press keeps the confirmation visible for its
full window; manually press the control twice in quick succession.

### F160 — Avoid recomputing find-highlight ranges on every playback redraw

- **Status:** open
- **Owner:** —
- **Severity:** low
- **Area:** ui
- **Filed:** 2026-08-03 by /root, from F157 documentation audit

**Problem.** `ContentView.swift:3021-3033` recalculates `TextSearch.occurrenceRanges` and rebuilds
an `AttributedString` for every visible matching segment. Playback updates the active state
repeatedly, so a long searched transcript can repeat this work on each redraw.

**Impact.** Long transcripts may spend unnecessary CPU time while playing back with search active.

**Proposed fix.** Cache occurrence ranges or highlighted text when the search query/segments change,
not when playback position changes.

**Verification.** Profile or instrument a long searched transcript during playback and show the
range work does not repeat per playback tick.

### F161 — Give async self-test and installer results a gentle entrance

- **Status:** open
- **Owner:** —
- **Severity:** low
- **Area:** ui
- **Filed:** 2026-08-03 by /root, from F157 documentation audit

**Problem.** The self-test result in `DictationView.swift:52-56` and installer completion messages
in `ContentView.swift:1233-1238,1262-1266` appear without the app's existing `gentleFade`
transition.

**Impact.** Completion feedback arrives as an abrupt layout change rather than a readable payoff
moment.

**Proposed fix.** Apply the established Reduce-Motion-safe transition at these async state
boundaries.

**Verification.** Manually complete each action with Reduce Motion both on and off; the result
should fade in without unwanted layout motion.

### F162 — Animate the meeting-row status-color handoff

- **Status:** open
- **Owner:** —
- **Severity:** low
- **Area:** ui
- **Filed:** 2026-08-03 by /root, from F157 documentation audit

**Problem.** The meeting-row status dot changes directly from the status switch at
`ContentView.swift:211-213,267-273` with no value-scoped color animation when a meeting moves
between recorded, processing, completed, or failed.

**Impact.** A meaningful state change has no visual continuity in the primary meeting list.

**Proposed fix.** Add a short color-only animation scoped to `meeting.status`.

**Verification.** Manually observe each reachable status transition and confirm the list does not
animate unrelated filtering or selection changes.

### F163 — Make the documentation formatter preserve the Quick Dictation design guide

- **Status:** open
- **Owner:** —
- **Severity:** low
- **Area:** docs
- **Filed:** 2026-08-03 by /root, from F157 documentation audit

**Problem.** `python3 Scripts/format-docs.py` refuses `docs/QUICK_DICTATION_DESIGN.md` with
`content drift at token 161: 'now' -> '>'`, so its safety check cannot format that durable guide.

**Impact.** A routine documentation-format pass exits nonzero even when all requested edits are safe.

**Proposed fix.** Reproduce the tokenization edge case with a focused test and correct the formatter
without weakening its word-stream safety guarantee.

**Verification.** The focused regression test fails before the fix and passes after; the formatter then
completes successfully without changing the guide's non-code word stream.
