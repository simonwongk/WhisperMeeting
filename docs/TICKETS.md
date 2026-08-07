# Ticket board

**The rules for this board — how to file, claim, close, and log tickets, plus the ID scheme, status
vocabulary, definition of done, and the ticket template — live in [`../AGENTS.md`](../AGENTS.md).
Read them before touching this file.** This file holds **open** work only; closed tickets move to
[`TICKET_LOG.md`](TICKET_LOG.md), and tickets blocked on a human action or decision move to
[`NEEDS_HUMAN.md`](NEEDS_HUMAN.md).

**Next free ID: `F175`.**

---

# Open tickets

Use the [work dashboard](tickets-dashboard.html) for a scan-first view. This Markdown file is the
authoritative queue: claim only a ticket that is `open`, and read [`NEEDS_HUMAN.md`](NEEDS_HUMAN.md)
before starting work that depends on a person.

## Ready to claim

### F174 — Visually verify the tag chip editor and the transcript Improve menu (incl. VoiceOver)

- **Status:** open
- **Owner:** —
- **Severity:** low
- **Area:** ui
- **Filed:** 2026-08-07 by Claude Code (Fable 5), from F171/F172 close

**Problem.** F171 (token-style tag chips + notes placeholder) and F172 (grouped "Improve" menu +
status row) shipped with headless tests for the pure logic only — the `WhisperMeet` target has no
view-render harness, so the visual pass and a VoiceOver walk-through are outstanding.

**Impact.** A layout or accessibility defect in the new editor/menu would go unnoticed until a
user hits it.

**Proposed fix.** In the running app, on a completed meeting: type `budget, hiring` in the Tags
well (chips must form on the comma), press Return, press Backspace twice in the empty field (chips
retract newest-first), click a chip's × control, click a "+" reuse chip, and confirm the notes
placeholder shows and clears. Open "Improve" and confirm all four items read in full with no
truncation at the default window width; trigger Suggest Vocabulary and confirm the named status
row appears. Repeat the tag pass under VoiceOver (chips must announce "Remove tag …" / reuse chips
"Add tag …") and with Reduce Motion on.

From the F159/F160/F173 closes (loop iteration 1), also: double-press "Copy AI Prompt" and the
transcript "Copy" quickly — the confirmation must stay for its full window after the second press;
search a long transcript and play it back — highlights stay correct while the active segment moves;
start "Correct with Local AI" on meeting A and open meeting B — B must show no correction status
row.

From the F158/F161/F162 closes (loop iteration 2), also with Reduce Motion both off and on: run
the dictation self-test — its result fades in without layout jumps; watch an installer finish —
the completion message fades in; record + transcribe a short meeting — the sidebar status dot
cross-fades between colors, and list filtering/selection never animates it.

**Verification.** Each step above passes; any failure gets its own ticket.

### F168 — `quality-check.sh` cold run: step [4] debug build trips the F121 watchdog

- **Status:** open
- **Owner:** —
- **Severity:** low
- **Area:** build
- **Filed:** 2026-08-05 by Claude Code (Opus 4.8), from F166

**Problem.** Step [4] runs `swift test` against an isolated clang-module cache
(`CLANG_MODULE_CACHE_PATH` / `XDG_CACHE_HOME` under `$TMPDIR/whispermeet-quality`). On a cold
`.build/debug`, a from-scratch build of the project exceeds the 600 s F121 watchdog, so the watchdog
fires and the gate exits 1 even though nothing hung — a false "F121 helper hang". The watchdog comment
assumes a warm cache ("Normal runs finish in seconds").

**Impact.** A cold gate run (fresh checkout, or after `.build` is cleared) fails at step [4] on build
time, not a real hang or test failure — misleading, and the run is wasted.

**Proposed fix.** Warm the build before the timed section (e.g. build outside the watchdog), or scale
the watchdog when the build is cold, or bump the default `WHISPERMEET_TEST_TIMEOUT` when no warm
`.build/debug` exists — keeping the F121 hang protection for warm runs.

**Verification.** A cold `quality-check.sh` run (after removing `.build/debug`) completes step [4]
without a false watchdog kill.

### F167 — No startup reclaim for an interrupted local-summarizer install

- **Status:** open
- **Owner:** —
- **Severity:** low
- **Area:** build
- **Filed:** 2026-08-04 by Claude Code (Opus 4.8), from F164

**Problem.** `Scripts/setup-local-summarizer.sh` reclaims orphaned `.Summarizer-backup-*` /
`.Summarizer-install-*` artifacts on its next run, and a failed install restores the prior model via
its cleanup trap, so nothing is stranded permanently. But unlike the Qwen3-ASR path (F33's
`reclaimInterruptedQwenInstall` + `QWEN_INSTALL_RECOVERY_ONLY`), there is no launch-time reclaim seam
for the summarizer runtime — an interrupted install is only reclaimed when the user next opens the
installer.

**Impact.** After a crash mid-install a `.Summarizer-backup-*` can sit until the next install attempt.
Low severity: the activated model still works, and the backup is reclaimed on the next install.

**Proposed fix.** Add a `runSummarizerInstallRecovery` seam + startup reclaim mirroring
`reclaimInterruptedQwenInstall`, or a recovery-only mode invoked at launch.

**Verification.** Simulate an interrupted install (leftover `.Summarizer-backup-*`) and confirm launch
reclaim restores/cleans it.

### F170 — Surface a reference-file picker for the local AI transcript-correction pass

- **Status:** open
- **Owner:** —
- **Severity:** low
- **Area:** transcription
- **Filed:** 2026-08-05 by Claude Code (Opus 4.8), from F165

**Problem.** F165 shipped on-device transcript correction guided by the business vocabulary, but only
the vocabulary reaches the model. The `reference:` document is fully plumbed —
`LocalTranscriptCorrector.correct(transcript:vocabulary:reference:)`, the prompt assembly
(`userContent`), `AppModel.proposeLocalCorrections(for:reference:)`, and the `correctorIncludesReference`
test all carry it — but the "Correct with local AI" button (`ContentView.swift` `TranscriptDetailView`)
passes `reference: nil`; there is no UI to choose a reference file.

**Impact.** A user who has a spec/glossary document richer than the flat vocabulary list cannot use it to
guide correction, even though the whole path already supports it — the stated v1 of F165 ("+ a reference
file") is only half surfaced.

**Proposed fix.** Add a file picker (`.fileImporter`) to the correction flow that reads a text/markdown
file and passes its contents to `proposeLocalCorrections(for:reference:)`. Guard the size against the
model's context window; the F165 ticket's embeddings + retrieval idea (`mlx-community`
Qwen3-Embedding-0.6B) is the escalation only when a reference outgrows the context.

**Verification.** A synthetic transcript is corrected toward a spelling that appears **only** in the
supplied reference file (not the vocabulary); a headless wiring test threads the reference through the
seam, and the raw recording and edited segments stay untouched.

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
