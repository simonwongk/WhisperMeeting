# Ticket board

**The rules for this board — how to file, claim, close, and log tickets, plus the ID scheme, status
vocabulary, definition of done, and the ticket template — live in [`../AGENTS.md`](../AGENTS.md).
Read them before touching this file.** This file holds **open** work only; closed tickets move to
[`TICKET_LOG.md`](TICKET_LOG.md), and tickets blocked on a human action or decision move to
[`NEEDS_HUMAN.md`](NEEDS_HUMAN.md).

**Next free ID: `F157`.**

---

# Open tickets

_The audit's urgent/confirmed defects were fixed (F92 loss, backup safety F137, and F138–F148 in the log,
including the two data-safety items F148 #1/#6). What remains below are the Low-severity, bounded-impact
findings from the F148 suspicious-risk investigation._

### F150 — WAV UInt32 data-size field overflows for a single meeting longer than ~12.4 h

- **Status:** open
- **Owner:** —
- **Severity:** low
- **Area:** recording
- **Filed:** 2026-08-03 by Claude Code (Opus 4.8), from F148 #2

**Problem.** `meeting.wav` is 48 kHz mono 16-bit (96 000 B/s), so the `UInt32` `data`-chunk size
(`AudioCaptureEngine.swift:686`, clamped) and the wrapping RIFF size (`WAVWriter.swift:14`) overflow at
~44 739 s ≈ 12.43 h. Samples are still written to disk, but strict readers (incl. ffmpeg) honor the
declared size and would ignore everything past ~4 GB. No meeting-duration cap exists.

**Proposed fix.** Cap/segment continuous recordings before 4 GB, or write RF64/WAVE-with-extended-size;
at minimum warn near the limit. **Verification.** A synthetic >4 GB write is read back fully (or split).

### F151 — Mid-recording capture gaps drift because only the initial presentation offset is applied

- **Status:** open
- **Owner:** —
- **Severity:** low
- **Area:** recording
- **Filed:** 2026-08-03 by Claude Code (Opus 4.8), from F148 #3

**Problem.** `FloatTrackWriter` records a presentation time only for the first buffer
(`AudioCaptureEngine.swift:587-589`) and writes subsequent buffers contiguously with no gap detection;
the mixer pads only by the initial offset (`:641-654`). If ScreenCaptureKit drops/stalls buffers
mid-recording, post-gap samples pack earlier than their true time and the two channels desync for the
rest of the meeting. **Magnitude is runtime-dependent** (needs a buffer-drop repro).

**Proposed fix.** Detect inter-buffer PTS gaps and insert silence to preserve alignment.
**Verification.** Induce a mid-capture drop and compare channel alignment vs wall-clock.

### F152 — Qwen helper loads the whole decoded recording before chunking; long-meeting validation pending

- **Status:** open
- **Owner:** —
- **Severity:** low
- **Area:** transcription
- **Filed:** 2026-08-03 by Claude Code (Opus 4.8), from F148 #4

**Problem.** `Scripts/qwen_transcribe.py:126` decodes the entire file into one array before chunking, and
retains it for alignment slicing (~230 MB for 60 min @16 kHz mono float32, plus decode/model working set).
No 30–60 min real-meeting run with peak-RSS measurement exists. **Proposed fix.** Validate a 30–60 min
real run (measure peak RSS); if needed, stream/downcast. **Verification.** Recorded peak-RSS for a
60-min transcription within an acceptable envelope.

### F153 — Cancellation doesn't kill descendant processes (ffmpeg/afconvert)

- **Status:** open
- **Owner:** —
- **Severity:** low
- **Area:** transcription
- **Filed:** 2026-08-03 by Claude Code (Opus 4.8), from F148 #5

**Problem.** `ProcessCancellationController.cancel` sends SIGTERM to the direct child PID only
(`LocalWhisperClient.swift:321-328`); no process group is created/signaled, so a grandchild `ffmpeg`/
`afconvert` spawned by the helper can survive a cancel (transient stray CPU/IO; no data loss). **Proposed
fix.** Start the child in its own process group and `killpg` on cancel. **Verification.** Cancel mid-decode
and confirm no orphaned decoder remains.

### F154 — OSLog logs `.public` error text that can include absolute paths

- **Status:** open
- **Owner:** —
- **Severity:** low
- **Area:** privacy
- **Filed:** 2026-08-03 by Claude Code (Opus 4.8), from F148 #7

**Problem.** Capture/dictation failures log `\(error.localizedDescription, privacy: .public)`
(`AudioCaptureEngine.swift:187-189`, `Dictation/DictationController.swift:212,270,372,433`), which can
embed absolute paths in the unified system log (Console/sysdiagnose). F141 redacted the diagnostics
*bundle*; this is the separate OSLog surface. **Proposed fix.** Drop `.public` on `localizedDescription`
or log a redacted/last-path-component form (reuse `DiagnosticsBundleBuilder.redactPaths`).
**Verification.** A capture error logs without the absolute path.

### F155 — Qwen aligner treats any CJK character as Chinese on English-dominant chunks

- **Status:** open
- **Owner:** —
- **Severity:** low
- **Area:** transcription
- **Filed:** 2026-08-03 by Claude Code (Opus 4.8), from F148 #8

**Problem.** The per-chunk aligner language is `Chinese` if a chunk contains ANY CJK scalar
(`Scripts/qwen_transcribe.py:25-28`), unlike top-level detection's majority rule. An English sentence with
one CJK token is aligned as Chinese, possibly degrading its word timings. Bounded: on alignment failure
the full text is preserved (no dropped text). **Reliability impact needs a runtime repro.** **Proposed
fix.** Use the majority-script rule per chunk too (or a threshold). **Verification.** Compare aligner
timing quality on an English-dominant single-CJK chunk under both heuristics.
