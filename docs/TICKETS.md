# Ticket board

**The rules for this board — how to file, claim, close, and log tickets, plus the ID scheme, status
vocabulary, definition of done, and the ticket template — live in [`../AGENTS.md`](../AGENTS.md).
Read them before touching this file.** This file holds **open** work only; closed tickets move to
[`TICKET_LOG.md`](TICKET_LOG.md), and tickets blocked on a human action or decision move to
[`NEEDS_HUMAN.md`](NEEDS_HUMAN.md).

**Next free ID: `F79`.**

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

### F40 — Transcript Edit view double-writes the whole meetings index on every keystroke

- **Status:** open
- **Owner:** —
- **Severity:** medium
- **Area:** ui
- **Filed:** 2026-07-30 by Claude Code (fix sweep, verified)

**Problem.** The transcript editor binding's setter calls
`store.update(id:) { $0.transcriptText = value }` on every keystroke
(`Sources/WhisperMeet/ContentView.swift:1709-1712`). `MeetingStore.update` runs on `@MainActor` and
unconditionally calls `persistMeetings()` (`MeetingStore.swift:209-213`), which JSON-encodes the
ENTIRE `meetings` array and performs a crash-safe backup-then-primary double write. There is no
debounce/coalescing.

**Impact.** For a large library or long transcript, editing re-serializes and writes megabytes to
disk twice per keystroke on the main thread — typing lag, possible cursor/IME-composition jumps (the
app supports Mandarin), and multiplied disk wear.

**Proposed fix.** Hold the edited text in `@State` and flush to the store on a debounce timer and on
blur/teardown, mirroring `EditableMeetingTitle`'s commit-on-blur pattern.

**Verification.** Count `meetingFiles.save` calls while applying N keystrokes and assert it
coalesces to roughly one write after idle rather than N. Fails before, passes after.

### F52 — `setup-local-whisper.sh` installs the default runtime with no atomic staging/backup

- **Status:** open
- **Owner:** —
- **Severity:** low
- **Area:** build
- **Filed:** 2026-07-30 by Claude Code (fix sweep, verified)

**Problem.** The default meetings runtime is built directly into the live `$runtime_directory/venv`
(`Scripts/setup-local-whisper.sh:25,29`); `pip install --upgrade openai-whisper` uninstalls the old
package before installing the new one, so a failure in that window (network drop, build error, disk
full) leaves the previously-working runtime broken with no rollback. The sibling `setup-qwen-asr.sh`
guards the optional path with a staging dir + backup + atomic rename + restore-on-failure
(`:122-186`); the more-critical default path has none of that.

**Impact.** Re-running the installer to upgrade (or a transient failure during first install) can
leave the user unable to transcribe any meeting until a successful re-run. Recordings are untouched
(recording-first invariant holds); recoverable by re-running.

**Proposed fix.** Build into a staging venv, verify `venv/bin/whisper --help`, then swap it in
atomically, keeping the prior venv as a restore-on-failure backup — the pattern `setup-qwen-asr.sh`
already uses.

**Verification.** From a known-good venv, force the pip upgrade to fail (unreachable index) and
assert the pre-existing `venv/bin/whisper --help` still exits 0 after the script fails. Fails
before, passes after.
