# Ticket log

Append-only record of every ticket closed. Newest first. Open work lives in
[`TICKETS.md`](TICKETS.md).

**Write real evidence, not intent.** Paste actual command output. "Tests pass" is not a log entry;
`✔ Test run with 178 tests passed` is. If a fix could not be verified the usual way, say exactly
what was skipped and why — an honest gap is useful, a glossed one is a trap for the next agent.

Never edit or delete an existing entry. If an entry turns out to be wrong, append a new one that
corrects it and say which entry it supersedes.

The log entry template lives in [`../AGENTS.md`](../AGENTS.md).

---

## F93 — Quality gate red: `-warnings-as-errors` build fails on `DiagnosticsBundleBuilder.swift`

- **Outcome:** duplicate
- **Closed:** 2026-07-31 by Claude Code (runtime lane)
- **Commits:** `0777d94` (the fix, under F111)
- **Duplicate of:** `F111`

**Root cause.** The recovery lane filed F93 for the same defect the runtime lane independently found
and filed as **F111**: `DiagnosticsBundleBuilder.json`'s `[String: Any]` literal makes Swift 6.1.2
resolve `meeting.<field> ?? <default>` to the optional-returning `??` overload, coercing `String?` to
`Any` — a warning that `quality-check.sh`'s release `-warnings-as-errors` step turns into an error.
Both tickets were filed on 2026-07-31 as concurrent lanes raced the same red gate; F93 and F111 are
one issue.

**Fix.** Landed under **F111** (`0777d94`): bind the three nil-coalesced values to explicitly-typed
locals so the non-optional `(T?, T) -> T` overload is chosen. F93 itself correctly predicted that its
own one-line proposal (`(errorMessage ?? "") as String` on line 65 only) was insufficient — patching
one site exposes the same error at another; F111 pins all three sites (`languageCode`,
`recordingBytes`, `errorMessage`). See the F111 entry for full RED/GREEN evidence and the added
nil-optional coverage test.

**Evidence.**

The gate is green on `main` as of F111's merge (`aed4b5b`):

```text
[3/4] Building production code with warnings as errors
[4/4] Packaging and signing WhisperMeet.app
✔ Test run with 240 tests passed after 1.145 seconds.
Quality check passed.
```

**Gaps.** none — closed as a duplicate; the fix, tests, and evidence live in F111. (Board note: the
recovery lane filed F93 without bumping the `Next free ID` line, which still reads `F93`; that shared
counter is not the runtime lane's to edit and is left as-is.)

---

## F30 — Qwen alignment failure silently drops every timestamp

- **Outcome:** fixed
- **Closed:** 2026-07-31 by transcription lane (Opus 4.8)
- **Commits:** `fd56622` (F30 fix + tests + spec)
- **Reachability:** Qwen meeting finishes → `AppModel.performTranscription` → `AppModel.apply(result:to:)`
  (`AppModel.swift:991`) stores `result.alignmentWarning` onto the `MeetingRecord` → the user opens the
  completed meeting and `TranscriptDetailView.transcriptSection` (`ContentView.swift:1785`) renders a
  plain-language advisory. The red-green test lands on the app-level `apply(result:)` hop
  (`Tests/WhisperMeetTests/QwenAlignmentWarningPersistenceTests.swift`); the SwiftUI advisory has no
  view harness and is manual (**Not planned:** the `WhisperMeet` target has no GUI-render test rig).

**Root cause.** Two independent silent-drop paths, only one of which F28 addressed. (1) When Qwen's
forced aligner *succeeds* (emits `alignedItems`, reports no warning) but `QwenAlignedTranscript.segments`
cannot reconcile those word timings with the punctuated transcript, it returns `[]` at one of its five
guard sites — so the result carried empty segments AND a nil `alignmentWarning` (F28 only routed the
helper's *own* warning, which is nil here). (2) Even when a warning existed, `AppModel.apply(result:)`
never copied `result.alignmentWarning` onto the stored `MeetingRecord`, and no view read it — so it
never reached the user regardless. Net effect: a Qwen meeting could complete with untimestamped text
and no explanation.

**Fix.** Three layers. (a) WhisperCore: `QwenASRClient.alignmentWarning(text:segments:payload:)` now
returns a plain-language note whenever the transcript has text but no reconciled segments — preferring
the helper's diagnostic when present, otherwise explaining the Swift-side mismatch — and returns nil
only when timestamps actually exist. Guarded on `segments.isEmpty` so it can never claim "unavailable"
over a seekable transcript (review finding, locked by `helperWarningSuppressedWhenSegmentsReconcile`).
(b) App wiring: `MeetingRecord.alignmentWarning` (optional, so old indexes decode) carried through
`apply(result:)`. (c) SwiftUI: a one-line advisory in `transcriptSection`, shown above the transcript
whenever the field is set. `PRODUCT_SPEC.md` amended to document the no-timestamp fallback so the spec
matches actual behaviour. Incidental: `postTranscriptionNotification` now binds `NSApp` instead of
force-unwrapping it (nil in a headless test) so the `apply` hop is testable — identical production
behaviour (`NSApp` is never nil in the running app).

**Evidence.**

Fails before the fix — the core silent-drop and the persistence hop:

```text
✘ Test "Unreconcilable Qwen alignment surfaces a warning even when the helper reported none (F30)" recorded an issue at QwenAlignmentDropWarningTests.swift:29:5: Expectation failed: (result.alignmentWarning → nil) != nil
✘ Test "A timestamp-less Qwen transcript with no helper warning still surfaces a warning (F30)" recorded an issue at QwenAlignmentDropWarningTests.swift:43:5: Expectation failed: (result.alignmentWarning → nil) != nil
✘ Test "A Qwen alignment warning is persisted onto the meeting through the app-level apply (F30)" recorded an issue at QwenAlignmentWarningPersistenceTests.swift:46:5: Expectation failed: (stored?.alignmentWarning?.contains("Timestamp alignment unavailable") → nil) == true
```

Passes after; the full suite grew 233 → 239 on this branch (+6: 4 core, 2 persistence):

```text
✔ Test "Unreconcilable Qwen alignment surfaces a warning even when the helper reported none (F30)" passed after 0.001 seconds.
✔ Test "A timestamp-less Qwen transcript with no helper warning still surfaces a warning (F30)" passed after 0.001 seconds.
✔ Test "A helper warning is suppressed when segments still reconcile (F30)" passed after 0.001 seconds.
✔ Test "A Qwen alignment warning is persisted onto the meeting through the app-level apply (F30)" passed after 0.214 seconds.
✔ Test run with 239 tests passed after 1.197 seconds.
```

Real installed Qwen model over a bench clip (`Scripts/bench/clips/en1.wav`) — the decoded contract
`makeResult` reads is intact, and a clean transcript yields timestamps and no warning:

```text
keys: ['alignedItems', 'alignmentWarning', 'language', 'text']
language: en
text: Can you send me the quarterly report by Friday afternoon?
alignedItems count: 10
alignmentWarning: None
first item: {'text': 'Can', 'start': 0.0, 'end': 0.16}
```

Release + `-warnings-as-errors` build: **my code is clean** — verified by temporarily applying F93's
fix locally, which made `swift build -c release -Xswiftc -warnings-as-errors` reach `Build complete!`
with zero diagnostics in any file I touched, then reverting. The gate's step 3 is otherwise red on the
pre-existing, cross-lane **F93** (`DiagnosticsBundleBuilder.swift`, a diagnostics/build file outside
this lane; F83 was likewise merged with F93 open).

**Gaps.** Partial alignment (keeping the sentences that *did* reconcile instead of dropping all
timestamps) is deferred as **F100** — F30 makes the all-or-nothing drop *visible* but does not change
it. The SwiftUI advisory has no automated view test (**Not planned:** no GUI-render harness in the
`WhisperMeet` target); manual check: transcribe a Qwen meeting whose alignment fails, open it, confirm
the orange "Timestamp alignment unavailable…" advisory appears above the transcript and is absent on a
cleanly aligned meeting. The whole-repo gate cannot pass green until **F93** is fixed by the
diagnostics/build owner (F93's own one-line proposed fix is incomplete — patching line 65 exposes the
same error on line 60).

---

## F111 — Shared quality gate was red: release build failed under `-warnings-as-errors`

- **Outcome:** fixed
- **Closed:** 2026-07-31 by Claude Code (runtime lane)
- **Commits:** `5156fab` (file), `0777d94` (fix), `32c24b1` (test), `7f42174` (close + this entry)
- **Reachability:** n/a — build-infrastructure fix. It changes no runtime behaviour and adds no user
  surface; the touched code (`DiagnosticsBundleBuilder.json`) is already reached by
  `DiagnosticsBundleBuilderTests` and will be wired to the app by F86. The "surface" restored is the
  shared quality gate itself: `Scripts/quality-check.sh` step [3/4] now compiles clean.

**Root cause.** `DiagnosticsBundleBuilder.json` builds a `[[String: Any]]` where three values are
`meeting.<field> ?? <default>`. Because the dictionary's value type is `Any`, Swift 6.1.2 resolves
`??` there to the `(T?, T?) -> T?` overload — the literal default (`""`, `-1`) is promoted to
optional — so each result is `String?`/`Int64?` and is implicitly coerced to `Any`. That is a
warning, and `quality-check.sh` compiles the release build with `-Xswiftc -warnings-as-errors`, which
turned it into a hard error. Introduced by F70 (`03e4694`, 19 commits back). It escaped notice because
the *shipping* build (`Scripts/build-app.sh`, plain `-c release`) and `swift test` are both unaffected
— only the gate's warnings-as-errors step trips it, and that step is easy to miss when its output is
piped (e.g. through `tee`/`tail`, which report the pipe's exit code, not the build's). It blocked
**every** lane, since a `fixed` close requires the gate to "pass whole".

**Fix.** Bind the three nil-coalesced values to explicitly-typed locals
(`let languageCode: String = meeting.languageCode ?? ""`, `let recordingBytes: Int64 = … ?? -1`,
`let errorMessage: String = … ?? ""`) before the literal, forcing the non-optional `(T?, T) -> T`
overload so the values are non-optional `String`/`Int64` and coerce to `Any` cleanly. All three sites
are pinned, not just the one the compiler happened to flag on a given incremental build (the reported
line shifted between 60 and 65 run-to-run). Emitted JSON bytes are unchanged. This is the right layer:
the gate's `-warnings-as-errors` is a real guarantee worth keeping, so the code is fixed rather than
the gate weakened.

**Evidence.**

Before — clean release build with the gate's flags fails:

```text
$ rm -rf .build/release && swift build -c release -Xswiftc -warnings-as-errors
Sources/WhisperCore/DiagnosticsBundleBuilder.swift:65:33: error: expression implicitly coerced from 'String?' to 'Any'
```

After — same command passes, and no coercion warning remains anywhere:

```text
$ rm -rf .build/release && swift build -c release -Xswiftc -warnings-as-errors && echo PASS
Build complete! (17.86s)
PASS
$ swift build -c release 2>&1 | grep -E 'coerced|warning:' || echo NONE
NONE
```

New test locks the nil-optional default path the fix covers (fails-safe against future drift):

```text
✔ Test "Diagnostics bundle encodes nil optionals as the documented defaults" passed after 0.066 seconds.
```

Full gate passes whole:

```text
[1/4] Checking the candidate diff for whitespace errors
[2/4] Running the complete test suite
✔ Test run with 234 tests passed after 1.125 seconds.
[3/4] Building production code with warnings as errors
[4/4] Packaging and signing WhisperMeet.app
Quality check passed.
```

Test count **+1** (233 → 234 from this ticket's origin/main baseline): the added nil-optional
coverage test. No test was removed.

**Gaps.** The RED/GREEN here is the **release build**, not a `swift test` case — the runtime output is
byte-identical, so there is no behavioural assertion that would fail before and pass after; a build
that compiles clean is the honest evidence (the F29/F110 tooling precedent). The added test guards the
nil-default output, not the compile warning itself. **Not planned:** locking the exact full byte
output of the bundle — the builder's determinism is already covered and pinning every byte would make
the test brittle to intentional field additions.

---

## F110 — `generate_clips.sh` was committed non-executable, so F29's reproducibility gap stayed open

- **Outcome:** fixed
- **Closed:** 2026-07-31 by Claude Code (runtime lane)
- **Commits:** `587fdae` (mode change, by simonwang), `a3c1e9f` (file), `287e754` (close + this entry)
- **Reachability:** n/a — tooling only; no user-facing code path. The "surface" is a developer running
  `Scripts/bench/generate_clips.sh` from a fresh checkout, which now has the executable bit.

**Root cause.** F29 closed the "benchmark table is unreproducible" ticket by making a fresh checkout
re-synthesise the gitignored clips with `Scripts/bench/generate_clips.sh` (F29 Gap 1). That script was
added to the index with mode `100644`. `git` records the executable bit; a `100644` script cannot be
run as `./generate_clips.sh` from a clean clone without a manual `chmod`. So F29's own remedy did not
work on the checkout it was written for — the reproducibility hole was still open. The other five
tracked shell scripts had been committed `100755` all along; only this one was missed.

**Fix.** The executable bit was recorded on `generate_clips.sh` (`587fdae`, a pure `100644 → 100755`
mode change with an identical blob `2b8e82e → 2b8e82e`, landed on `main` by simonwang). This ticket
then verified the bit across **every** tracked shell script — not just the one F29 named — so the
class of defect is closed, not just the instance.

**Evidence.**

`587fdae` is a mode-only change (blob unchanged), i.e. exactly recording the executable bit:

```text
$ git show 587fdae --raw --format='%s'
chore(scripts): record executable bit so a fresh worktree can run them
:100644 100755 2b8e82e 2b8e82e M	Scripts/bench/generate_clips.sh
```

Every tracked shell script now carries mode `100755`; none remain `100644`:

```text
$ git ls-files -s '*.sh'
100755 2b8e82ebfd6b197ca583c8d247089bb317317923 0	Scripts/bench/generate_clips.sh
100755 882a6593611abe1ce14648df0645e57508fbb68f 0	Scripts/build-app.sh
100755 8418bce58816e304e17499c153c0c84bd7c95ff4 0	Scripts/install-app.sh
100755 a4f637a28de0440e2db75c67e505814577d2fe67 0	Scripts/quality-check.sh
100755 54a053b8348a628c770f4df5b3648d84b9e11694 0	Scripts/setup-local-whisper.sh
100755 61d948af8ee4ef1ab3918fca640433ca804cd815 0	Scripts/setup-qwen-asr.sh

$ git ls-files -s '*.sh' | grep '^100644' || echo "NONE at 100644"
NONE at 100644
```

`generate_clips.sh` is self-contained (drives macOS `say`/`afconvert`, invokes no other repo script),
so its own bit is the whole reproducibility dependency; with it set, `./Scripts/bench/generate_clips.sh`
runs from a fresh checkout.

**Gaps.** No red-green test: this is a tooling/permissions change with no product behaviour to cover —
git file modes are not observable from `swift test`, and asserting a test here would be theatre (the
F29 entry's own Gap 2 is the precedent). The full suite is unaffected at **233 tests** (0 delta from
this ticket's origin/main baseline). The deeper reproducibility caveat F29 named — synthetic `say`
clips differ across macOS versions/voices, so numbers are reproducible for *a given clip set*, not
universally — is unchanged and remains a **Not planned:** limitation of synthetic corpora (committing
binary audio is a separate product decision, not deferred work).

---

## F83 — Reachable meeting-integrity sweep: startup fold + Settings "Verify Library"

- **Outcome:** fixed
- **Closed:** 2026-07-31 by Claude Code (Opus 4.8) / simonwang
- **Commits:** `aff961d`
- **Reachability:** two user-triggerable surfaces reach the F66 core. (1) App launch (`AppEntry` `.task`)
  → `AppModel.performStartupRecovery()` → `verifyLibraryIntegrity()` → the `checkMeetingIntegrity`
  seam → `MeetingIntegrityChecker.check` → findings joined into `alertMessage` → the root `.alert`
  (`ContentView.swift:97`). (2) Settings → `SettingsView` "Verify Library" button →
  `AppModel.verifyLibrary()` → the same sweep → `alertMessage`.

**Root cause.** F66 shipped a tested `MeetingIntegrityChecker` + `WAVInspection` in WhisperCore with no
caller; the user-facing half was deferred. So a truncated/empty/inconsistent recording was flagged only
by code nothing ran.

**Fix (three layers; pattern now in AGENTS.md "Wiring an unreachable core").**

- Layer 1 (WhisperCore, unchanged): `MeetingIntegrityChecker.check` / `WAVInspection`.
- Layer 2 (AppModel, tested): `verifyLibraryIntegrity()` sweeps `store.meetings`, builds a
  `MeetingIntegrityDescriptor` per meeting from `store.recordingURL(for:)` + the on-disk
  `source-tracks.json` frame counts + the index duration, and runs the check via an injectable
  `checkMeetingIntegrity` `@Sendable` seam (mirrors F47's `recoverInterruptedRecording`). Folded into
  `performStartupRecovery` after orphan recovery; findings surface through the existing `alertMessage`.
  Read-only — reports, never repairs or deletes.
- Layer 3 (SettingsView, manual): a thin "Verify Library" button → `verifyLibrary()`.

**Evidence.**

Red-green lands on the AppModel wiring layer. Fails before (stub `verifyLibraryIntegrity()` returns `[]`):

```text
✘ Test "Library integrity sweep flags a truncated WAV and a frame-mismatched source track through the app-level call (F83)" recorded an issue at LibraryIntegrityTests.swift:119:5: Expectation failed: (results.count → 0) == 2
```

Fails before for the launch path (the integrity fold reverted):

```text
✘ Test "Integrity findings surface through startup recovery's alert without touching audio (F83)" recorded an issue at LibraryIntegrityTests.swift:150:5: Expectation failed: (model.alertMessage?.contains("Corrupt meeting") → nil) == true
```

Passes after; full suite grew 230 → 233:

```text
✔ Test "Library integrity sweep flags a truncated WAV and a frame-mismatched source track through the app-level call (F83)" passed after 0.215 seconds.
✔ Test "Integrity findings surface through startup recovery's alert without touching audio (F83)" passed after 0.191 seconds.
✔ Test "Library sweep routes findings through the injected checker seam and skips recording-less meetings (F83)" passed after 0.156 seconds.
✔ Test run with 233 tests passed after 1.108 seconds.
```

Read-only invariant asserted: each test re-stats the recording after the sweep and expects the byte
size unchanged (144 bytes for the truncated fixture). Fixtures are synthesized in a temp
`MeetingStore(rootDirectory:)`; the healthy meeting copies a real `Scripts/bench/clips/en1.wav` — no
real user meeting is read or touched.

**Gaps.** Not planned: an automated view test for the "Verify Library" button click or the launch alert
presentation — the `WhisperMeet` target has no SwiftUI render harness. Its target method
`verifyLibrary()` and the whole sweep are tested; only the literal click/alert are not. Manual check:
`Scripts/build-app.sh && open .build/WhisperMeet.app`; Settings → "Meeting library" → "Verify Library"
reports "no audio problems" on a healthy library. To see a finding, record a throwaway meeting (never
an important one), quit, truncate its `~/Library/Application Support/WhisperMeet/Recordings/<uuid>/meeting.wav`
on disk, then relaunch (the startup alert names it) or press "Verify Library" again; confirm the message
says the recording looks truncated and "were not changed", and that the file's byte size is unchanged
afterward.

## F28 — `WhisperCore` is no longer framework-free

- **Outcome:** fixed
- **Closed:** 2026-07-30 by Claude Code (Opus 4.8) / simonwang
- **Commits:** `<this commit>`

**Root cause.** `QwenASRClient.swift` imported `os` and constructed a `Logger` inside the library,
breaking the "pure, framework-free" contract and hiding the Qwen alignment-failure warning in OSLog
where neither callers nor tests could observe it. `WarmWhisperDictationEngine.swift` also imports
`Darwin` (for `SIGKILL`), which has no Foundation equivalent.

**Fix.** Added `TranscriptionResult.alignmentWarning` (defaulted nil) and route the Qwen warning
through it via an extracted, testable `QwenASRClient.makeResult(...)`; removed `import os` and the
`Logger` call. Documented the `Darwin`/`SIGKILL` import in `CLAUDE.md` as the one sanctioned exception
and stated the "surface diagnostics through return values" rule.

**Evidence.**

`WhisperCore` imports are now Foundation only, plus the sanctioned Darwin:

```text
   1 import Darwin
  45 import Foundation
```

The warning is observable — fails before the fix (warning not surfaced):

```text
✘ Test "Qwen alignment warning is observable through the transcription result" recorded an issue at QwenAlignmentWarningTests.swift:13:5: Expectation failed: (result.alignmentWarning?.contains("KeyError: text") → nil) == true
```

Passes after; full suite grew 229 → 230:

```text
✔ Test "Qwen alignment warning is observable through the transcription result" passed after 0.001 seconds.
✔ Test run with 230 tests passed after 1.145 seconds.
```

**Gaps.** The warning is now in the result and testable; surfacing it in the UI (and amending
`PRODUCT_SPEC.md`) is F30. No live-model run — the change is pure result plumbing.

## F58 — Post-meeting recording-health report: persist why a recording was bad

- **Outcome:** fixed
- **Closed:** 2026-07-30 by Claude Code (Opus 4.8) / simonwang
- **Commits:** `<this commit>`

**Feature.** The live `RecordingHealthSnapshot.warnings` were thrown away on stop. Added a pure
`RecordingHealthReport` (distinct warnings, worst status reached, per-channel total stale seconds,
whether system audio was ever detected) and `RecordingHealthMonitor.report()` which folds it across
every `snapshot(...)`. Made `RecordingHealthWarning`/`RecordingHealthStatus`/`RecordingHealthReport`
`Codable` and added optional `MeetingRecord.healthReport` (old indexes still decode).

**Invariants.** Advisory only, derived from level data already computed during capture; audio
untouched; channel-level (mic vs system), never speaker identity; local-only.

**Evidence.**

Fails before the fix (mic stale-seconds accrual disabled):

```text
✘ Test "Health report folds warnings, worst status, and mic stale seconds" recorded an issue at RecordingHealthReportTests.swift:21:5: Expectation failed: (report.microphoneStaleSeconds → 0.0) == (8 → 8.0)
```

Passes after (folds `.systemAudioNotDetected`, worst `.atRisk`, mic stale-seconds 8, never-detected;
plus a Codable round-trip); full suite grew 227 → 229:

```text
✔ Test "Health report folds warnings, worst status, and mic stale seconds" passed after 0.001 seconds.
✔ Test "A RecordingHealthReport round-trips through Codable" passed after 0.001 seconds.
✔ Test run with 229 tests passed after 1.144 seconds.
```

**Gaps.** The report fold + persistence field are tested. Calling `monitor.report()` on stop, storing
it into `MeetingRecord.healthReport`, and rendering the one-line advisory are follow-up app wiring.

**Follow-up filed:** F79 (2026-07-31) — the deferred app wiring is now tracked on the board.

## F75 — Local automatic backups with hash verification and retention

- **Outcome:** fixed
- **Closed:** 2026-07-30 by Claude Code (Opus 4.8) / simonwang
- **Commits:** `<this commit>`

**Feature.** Put the decidable logic in WhisperCore as pure functions: `BackupPlan.compute` (over
`BackupFile` descriptors — same path + same hash ⇒ skip, else copy), `BackupRetention.prune`
(`.keepLatest(N)` / `.keepWithinDays(N, now:)` → generations to drop), and `BackupVerification`
(post-copy expected-vs-actual hash).

**Invariants.** Local-only decisions over descriptors; the source is never modified or deleted —
retention prunes only destination generations; no diarization/language involvement.

**Evidence.**

Fails before the fix (the same-hash skip disabled) — an unchanged file is re-copied:

```text
✘ Test "Backup plan skips unchanged files, schedules changed and new ones" recorded an issue at BackupPlanTests.swift:20:5: Expectation failed: (action("a") → .copy) == .skip
```

Passes after (unchanged→skip, changed/new→copy; keep-3 drops exactly the oldest; hash mismatch →
verification failure); full suite grew 224 → 227:

```text
✔ Test "Backup plan skips unchanged files, schedules changed and new ones" passed after 0.001 seconds.
✔ Test "keep-3 retention prunes exactly the 4th-oldest and older" passed after 0.001 seconds.
✔ Test "Backup verification fails on a post-copy hash mismatch" passed after 0.001 seconds.
✔ Test run with 227 tests passed after 1.141 seconds.
```

**Gaps.** The three decidable cores are tested. The thin `BackupCoordinator` (the `FileManager` copy
in `Task.detached` from `store.rootDirectory` to a user-chosen folder, pre-copy free-space check) is
follow-up app wiring.

**Follow-up filed:** F90 (2026-07-31) — the deferred app wiring is now tracked on the board.

## F66 — Meeting-library integrity self-check: flag missing/truncated audio without touching it

- **Outcome:** fixed
- **Closed:** 2026-07-30 by Claude Code (Opus 4.8) / simonwang
- **Commits:** `<this commit>`

**Feature.** Added a pure `WAVInspection` (reads the 44-byte RIFF/WAVE header — header bytes + file
size only) and `MeetingIntegrityChecker.check(_:)` over a lightweight `MeetingIntegrityDescriptor`,
returning `[IntegrityFinding]`: `.recordingMissing`, `.recordingEmpty`, `.wavHeaderUnreadable`,
`.wavTruncated(declared:actual:)`, `.sourceTrackFrameMismatch(...)`, `.durationInconsistent(...)`.

**Invariants.** Read-only — parses headers and stats sizes, never opens or deletes audio; it flags,
never repairs by deletion; local-only.

**Evidence.**

Fails before the fix (truncation check defeated):

```text
✘ Test "Integrity checker flags missing, truncated, and frame-mismatched audio; healthy returns none" recorded an issue at MeetingIntegrityCheckerTests.swift:62:5: Expectation failed: truncated.contains { if case .wavTruncated = $0 { return true }; return false }
```

Passes after (truncated WAV → `.wavTruncated`; short `.f32` → `.sourceTrackFrameMismatch`; missing wav
→ `.recordingMissing`; healthy dir → []); full suite 224:

```text
✔ Test "Integrity checker flags missing, truncated, and frame-mismatched audio; healthy returns none" passed after 0.004 seconds.
✔ Test run with 224 tests passed after 1.133 seconds.
```

**Gaps.** `WAVInspection` is new and used by the checker; unifying `InterruptedRecordingRecovery`'s
own header parse onto it (safe, behind the recovery tests) is a follow-up. Folding the check into
`performStartupRecovery` + a Settings "Verify library" action is app wiring. (Noted separately: the
subprocess-timing test "retire() waits for an idle helper process to actually exit" flaked once during
this run and passed on re-run — a known real-process timing sensitivity, unrelated to this change.)

**Follow-up filed:** F83 (2026-07-31) — the deferred app wiring is now tracked on the board.

## F62 — Menu-bar recording controls with live status

- **Outcome:** fixed
- **Closed:** 2026-07-30 by Claude Code (Opus 4.8) / simonwang
- **Commits:** `<this commit>`

**Feature.** Added a pure `MenuBarRecording.make(...)` → `MenuBarRecordingPresentation`: an SF Symbol,
a live status title ("Recording 05:23" / "Finishing…" / "Transcribing…" / "Not recording"), per-item
enablement (Start / Stop & Transcribe / Add Marker / Cancel), and `cancelNeedsConfirmation` (always
true — Cancel is the only destructive path).

**Invariants.** Recording stays source-of-truth (Stop uses the no-mutation-on-failure path; Cancel
stays behind confirmation); local-only; no diarization/translation.

**Evidence.**

Fails before the fix (Add Marker mis-disabled while recording):

```text
✘ Test "Menu bar recording presentation reflects idle / recording / stopping / importing" recorded an issue at MenuBarRecordingTests.swift:21:5: Expectation failed: (recording → MenuBarRecordingPresentation(... addMarkerEnabled: false ...)).addMarkerEnabled → false
```

Passes after (idle → Start enabled, Stop/Marker disabled; recording(323s) → "Recording 05:23", Stop &
Marker enabled, cancelNeedsConfirmation true; stopping/importing → actions disabled); full suite grew
222 → 223:

```text
✔ Test "Menu bar recording presentation reflects idle / recording / stopping / importing" passed after 0.001 seconds.
✔ Test run with 223 tests passed after 1.097 seconds.
```

**Gaps.** The presentation core is tested; extending the `MenuBarExtra` to render it (Start / Stop /
Add Marker / guarded Cancel) is follow-up SwiftUI (menu wiring verified manually per the ticket).

**Follow-up filed:** F80 (2026-07-31) — the deferred app wiring is now tracked on the board.

## F65 — Glossary auto-correction: reviewable spelling normalization toward the user's vocabulary

- **Outcome:** fixed
- **Closed:** 2026-07-30 by Claude Code (Opus 4.8) / simonwang
- **Commits:** `<this commit>`

**Feature.** Added a pure `GlossaryCorrector.corrections(vocabulary:segments:)`. For each term it
scans 1–3 word windows per segment, normalizes both (CJK-safe alphanumerics-lowercase), and proposes
the best window whose longest-common-subsequence ratio meets a 0.5 threshold — skipping exact matches
(already correct), too-distant tokens, and cross-script candidates (LCS ≈ 0). Returns
`{segmentIndex, from, to}` proposals for the user to review; nothing auto-applies. This is the only
path that brings custom vocabulary to the Qwen transcript without a model API.

**Invariants.** Pure string logic; recording untouched; corrections are user-reviewed and
same-language (never translation); no diarization.

**Evidence.**

Fails before the fix (similarity threshold raised to 0.95) — the near-miss is not proposed:

```text
✘ Test "Glossary corrector proposes near-miss corrections and skips exact/cross-script/distant" recorded an issue at GlossaryCorrectorTests.swift:18:5: Expectation failed: (near.first?.to → nil) == "Kubernetes"
```

Passes after ("cooper netties" → "Kubernetes" exactly once; exact/cross-script/distant → none); full
suite grew 221 → 222:

```text
✔ Test "Glossary corrector proposes near-miss corrections and skips exact/cross-script/distant" passed after 0.001 seconds.
✔ Test run with 222 tests passed after 1.114 seconds.
```

**Gaps.** The matcher is tested. The review sheet (mirroring `VocabularySuggestionSheet`) that applies
accepted proposals is follow-up UI.

**Follow-up filed:** F82 (2026-07-31) — the deferred app wiring is now tracked on the board.

## F73 — Second opinion: re-transcribe with the other engine and compare divergences

- **Outcome:** fixed
- **Closed:** 2026-07-30 by Claude Code (Opus 4.8) / simonwang
- **Commits:** `<this commit>`

**Feature.** Added a pure `TranscriptComparison.compare(_:_:)` aligning two `[TranscriptSegment]` by
time overlap (falling back to normalized-text match when a side has no timestamps) and returning
`TranscriptComparisonSpan`s marked `.agree` / `.diverge` (carrying both engines' text) / `.nonOverlapping`.

**Invariants.** Pure read-only comparison; both engines only read the WAV (source-of-truth safe);
local-only; no diarization; original-language.

**Evidence.**

Fails before the fix (divergence detection disabled) — a differing segment is not flagged:

```text
✘ Test "Transcript comparison marks agreement, divergence, and non-overlap" recorded an issue at TranscriptComparisonTests.swift:21:5: Expectation failed: (diff.filter { $0.kind == .diverge }.count → 0) == 1
```

Passes after (identical → all agree; one differing word → one divergence with both texts; disjoint
timelines → non-overlapping); full suite grew 220 → 221:

```text
✔ Test "Transcript comparison marks agreement, divergence, and non-overlap" passed after 0.001 seconds.
✔ Test run with 221 tests passed after 1.138 seconds.
```

**Gaps.** The comparison core is tested. The "Second opinion" action (running the non-selected engine
on the same WAV under the single-run guard, then a comparison sheet with replace/keep) is follow-up;
the Qwen side depends on reliable timestamps (F30).

**Follow-up filed:** F88 (2026-07-31) — the deferred app wiring is now tracked on the board.

## F69 — App-wide keyboard command catalog + main-menu Commands + shortcuts help

- **Outcome:** fixed
- **Closed:** 2026-07-30 by Claude Code (Opus 4.8) / simonwang
- **Commits:** `<this commit>`

**Feature.** Added a pure `CommandCatalog`: `AppCommand`s (id, title, section, keyEquivalent,
`CommandModifiers`, `CommandEnablement`) plus `displayShortcut(for:)` and an `AppCommandState`-driven
enablement. Commands: toggle recording (⌘R), Add Marker (⇧⌘M, while recording), Cancel Recording…
(no shortcut, while recording), Keyboard Shortcuts (⌘/).

**Invariants.** Purely additive keyboard/menu surface described as data; no audio/transcript
mutation; local-only; no diarization/translation.

**Evidence.**

Fails before the fix (Add Marker enablement weakened to `.always`):

```text
✘ Test "No two commands share a shortcut; display strings and enablement are correct" recorded an issue at CommandCatalogTests.swift:23:5: Expectation failed: !((addMarker.enablement → .always).isEnabled(AppCommandState(isRecording: false) ...) → true)
```

Passes after (no (key, modifiers) collisions; exact display strings "⇧⌘M"/"⌘R"/nil; Add Marker
enabled only while recording); full suite grew 219 → 220:

```text
✔ Test "No two commands share a shortcut; display strings and enablement are correct" passed after 0.001 seconds.
✔ Test run with 220 tests passed after 1.157 seconds.
```

**Gaps.** The catalog is fully tested. Wiring it into a `.commands { CommandMenu }` and a
render-from-catalog Keyboard Shortcuts sheet is follow-up SwiftUI.

**Follow-up filed:** F85 (2026-07-31) — the deferred app wiring is now tracked on the board.

## F77 — Per-segment re-run: re-transcribe a single flagged span

- **Outcome:** fixed
- **Closed:** 2026-07-30 by Claude Code (Opus 4.8) / simonwang
- **Commits:** `<this commit>`

**Feature.** Added two pure pieces: `SegmentAudioRange.byteRange(...)` maps a segment's time span to a
byte range in `meeting.wav` using the fixed 16-bit-mono PCM layout `WAVWriter` writes (44-byte header,
2 bytes/sample), and `TranscriptSegmentSplice.splice(_:replacingIndex:with:)` replaces one segment
with a re-run's segments, re-anchoring the clip-relative timestamps by the original segment's start
and re-flowing order.

**Invariants.** Reads `meeting.wav` only (the app writes a disposable temp clip); recording is the
source of truth, untouched; original language preserved; no diarization.

**Evidence.**

Fails before the fix (offset anchoring removed) — re-run timestamps collide / mis-order:

```text
✘ Test "TranscriptSegmentSplice replaces one segment and anchors the re-run timestamps" recorded an issue at SegmentRerunTests.swift:31:5: Expectation failed: (Set(starts).count → 3) == (starts.count → 4)
```

Passes after (byte offsets `44 + t·16000·2`; splice yields 4 ordered segments); full suite grew
217 → 219:

```text
✔ Test "SegmentAudioRange maps a time span to WAV byte offsets" passed after 0.001 seconds.
✔ Test "TranscriptSegmentSplice replaces one segment and anchors the re-run timestamps" passed after 0.001 seconds.
✔ Test run with 219 tests passed after 1.121 seconds.
```

**Gaps.** The two pure pieces are fully tested. The WhisperMeet wiring (the codebase's first WAV
sub-range READ, writing a temp clip via `WAVWriter.wavData`, running the chosen engine, and splicing
back) is follow-up; on Qwen it also depends on reliable segment timestamps (F30).

**Follow-up filed:** F92 (2026-07-31) — the deferred app wiring is now tracked on the board.

## F76 — Suggest a meeting title from the local Calendar

- **Outcome:** fixed
- **Closed:** 2026-07-30 by Claude Code (Opus 4.8) / simonwang
- **Commits:** `<this commit>`

**Feature.** Added a pure `CalendarTitleMatcher` over a framework-free `CalendarEventSummary`:
`bestTitle(forRecordingStartedAt:in:tolerance:)` returns the title of an event whose `[start, end]`
contains the recording start (overlaps resolved deterministically — earliest start, then title),
else the closest event whose start is within `tolerance`, else nil.

**Invariants.** Pure matching over supplied summaries; no network; associates a TITLE only, never
speaker identity; transcription language unaffected.

**Evidence.**

Fails before the fix (overlap tie-break removed) — input order wins instead of earliest start:

```text
✘ Test "Calendar matcher picks a containing event, then the nearest within tolerance" recorded an issue at CalendarTitleMatcherTests.swift:34:5: Expectation failed: (CalendarTitleMatcher.bestTitle(...) ...) == "Earlier"
```

Passes after (containing event; 2-min-before within tolerance; no-nearby → nil; overlap → earliest);
full suite grew 216 → 217:

```text
✔ Test "Calendar matcher picks a containing event, then the nearest within tolerance" passed after 0.001 seconds.
✔ Test run with 217 tests passed after 1.118 seconds.
```

**Gaps.** The matcher is fully tested. EventKit wiring (a new framework dependency + a
privacy-sensitive Calendar permission) is deliberately left as follow-up — adding a privacy-sensitive
dependency should be an explicit choice, not automatic. When added, it degrades silently to the
existing auto-title if access is denied.

**Follow-up filed:** F91 (2026-07-31) — the deferred app wiring is now tracked on the board.

## F70 — Privacy-safe diagnostics bundle (audio- and transcript-excluded)

- **Outcome:** fixed
- **Closed:** 2026-07-30 by Claude Code (Opus 4.8) / simonwang
- **Commits:** `<this commit>`

**Feature.** Added a pure `DiagnosticsBundleBuilder`. Its `DiagnosticsInput` deliberately carries the
sensitive fields (transcript, summary, vocabulary) so the builder can prove — by never emitting them
— that a support bundle excludes them. `json(_:)` emits only structural metadata (ids, epoch
timestamps, durations, status, language code, segment/marker counts, byte sizes, error messages,
vocabulary term COUNT) as deterministic (`.sortedKeys`) JSON.

**Invariants.** Local-only (returns a string; the app writes a local file); excludes transcript
text, summaries, and vocabulary terms by construction; no absolute paths; no audio.

**Evidence.**

Fails before the fix (transcript deliberately leaked into the payload):

```text
✘ Test "Diagnostics bundle excludes transcript/summary/vocabulary and is deterministic JSON" recorded an issue at DiagnosticsBundleBuilderTests.swift:22:5: Expectation failed: !((out → "{ ...").contains("SECRET-TRANSCRIPT"))
```

Passes after (excludes SECRET-TRANSCRIPT / SECRET-SUMMARY / AcmeCorp; valid JSON; byte-identical
across runs); full suite grew 215 → 216:

```text
✔ Test "Diagnostics bundle excludes transcript/summary/vocabulary and is deterministic JSON" passed after 0.003 seconds.
✔ Test run with 216 tests passed after 1.087 seconds.
```

**Gaps.** The builder is fully tested; the Settings "Export diagnostics…" action that maps
`MeetingRecord`s into `DiagnosticsInput` and writes the file is follow-up wiring.

**Follow-up filed:** F86 (2026-07-31) — the deferred app wiring is now tracked on the board.

## F74 — Compact recording HUD overlay for backgrounded meetings

- **Outcome:** fixed
- **Closed:** 2026-07-30 by Claude Code (Opus 4.8) / simonwang
- **Commits:** `<this commit>`

**Feature.** Added a pure `RecordingHUD` core: `make(...)` returns a `RecordingHUDState`
(elapsedText, statusLine, topWarning, level) selecting the single most-severe warning from a
`RecordingHealthSnapshot` (severity rank consistent with `overallStatus`), and `shouldPresent`
gates on recording-AND-backgrounded.

**Invariants.** Display-only derivation; reads state, never mutates/deletes audio; local-only; no
diarization/translation.

**Evidence.**

Fails before the fix (severity mis-ranked) — a lower-severity warning wins:

```text
✘ Test "Recording HUD surfaces the most-severe warning and formats elapsed time" recorded an issue at RecordingHUDTests.swift:19:5: Expectation failed: (state.topWarning → "No system audio detected") == "Low storage — recording may stop soon"
```

Passes after (most-severe warning; "5:23" elapsed; finishing state; shouldPresent gating); full suite
grew 214 → 215:

```text
✔ Test "Recording HUD surfaces the most-severe warning and formats elapsed time" passed after 0.001 seconds.
✔ Test run with 215 tests passed after 1.113 seconds.
```

**Gaps.** The `RecordingHUD` state core is fully tested; the `NonActivatingPanel`-based overlay view
is follow-up UI (and the ticket flags an overlap with F62 — if only one background-awareness surface
is funded, prefer F62's menu bar).

**Follow-up filed:** F89 (2026-07-31) — the deferred app wiring is now tracked on the board.

## F71 — VoiceOver labels and Dynamic Type for recording, meeting, and transcript surfaces

- **Outcome:** fixed
- **Closed:** 2026-07-30 by Claude Code (Opus 4.8) / simonwang
- **Commits:** `<this commit>`

**Feature.** Added a pure `AccessibilityPhrase` module over framework-free primitives: `meetingRow`
("Team sync, transcript ready, 42 minutes"), `recordButton`, `marker`, `levelMeter`. Attached the
`meetingRow` spoken label to the sidebar row (`.accessibilityElement(children: .ignore)` +
`.accessibilityLabel`).

**Invariants.** Read-only labels describing state; meeting-row phrasing never implies identified
speakers; local-only; original language echoed verbatim.

**Evidence.**

Fails before the fix (`completed` status phrasing wrong):

```text
✘ Test "Accessibility phrases render exact spoken strings" recorded an issue at AccessibilityPhraseTests.swift:7:5: Expectation failed: (AccessibilityPhrase.meetingRow(... "completed" ...) → "Team sync, completed, 42 minutes") == "Team sync, transcript ready, 42 minutes"
```

Passes after; full suite grew 213 → 214:

```text
✔ Test "Accessibility phrases render exact spoken strings" passed after 0.001 seconds.
✔ Test run with 214 tests passed after 1.103 seconds.
```

**Gaps.** The `AccessibilityPhrase` core is fully tested and the primary `meetingRow` label is
attached. Attaching `recordButton`/`marker`/`levelMeter` labels throughout the read view and replacing
the fixed transcript font sizes with semantic text styles / `@ScaledMetric` (Dynamic Type) remain
follow-up UI work; an Accessibility Inspector audit is manual (not possible in this harness).

**Follow-up filed:** F87 (2026-07-31) — the deferred app wiring is now tracked on the board.

## F56 — Persist an overall transcript confidence into the header and Meeting Notes

- **Outcome:** fixed
- **Closed:** 2026-07-30 by Claude Code (Opus 4.8) / simonwang
- **Commits:** `<this commit>`

**Feature.** `MeetingRecord.confidence` was dead (forced nil). Revived it: `AppModel.apply(result:)`
now sets `confidence` from `TranscriptQuality.review(result.segments).confidence` (nil when unscored,
so no false claim). Added a "## Confidence" section to `MeetingNotesExporter.markdown`: an
"NN% clean — K of M segments flagged" headline plus a worst-first list (`flaggedBySeverity`) with each
flagged passage's MM:SS and `SegmentQualityFlag.reason`. The whole section is gated on
`!isUnscored && !isEdited` so an unscored or edited transcript makes no claim. Builds on F55, so this
now works for Qwen/legacy transcripts too.

**Invariants.** Read-only over segments; audio untouched; unscored/edited transcripts make no
confidence claim (never fabricates trust); no diarization/translation.

**Evidence.**

Fails before the fix (confidence section suppressed):

```text
✘ Test "Meeting notes emit a confidence section only for a scored, unedited transcript" recorded an issue at MeetingNotesExporterTests.swift:111:5: Expectation failed: (md → "# t ...").contains("## Confidence")
```

Passes after (67% clean / "1 of 3 segments flagged" / flagged MM:SS; edited & unscored transcripts
emit no section); full suite grew 212 → 213:

```text
✔ Test "Meeting notes emit a confidence section only for a scored, unedited transcript" passed after 0.001 seconds.
✔ Test run with 213 tests passed after 1.105 seconds.
```

**Gaps.** The exporter section is red-green tested; the revived header label (`AppModel` → SwiftUI) is
not view-tested in this harness.

## F55 — Engine-agnostic repetition flag: text-derived quality review for Qwen/legacy transcripts

- **Outcome:** fixed
- **Closed:** 2026-07-30 by Claude Code (Opus 4.8) / simonwang
- **Commits:** `<this commit>`

**Feature.** `TranscriptQuality` only scored segments carrying Whisper's metrics, so the quality
banner never appeared for Qwen/legacy transcripts (all metrics nil) — including Qwen's most common
failure, a degenerate loop. Added a pure `textCompressionRatio(_:)` (total/distinct token count —
word-level for space-delimited text, character-level for CJK runs) and used it in `classify` when
`compressionRatio == nil`, so `.repetitive` is reachable from text alone. A metric-less segment with
text now counts toward `scoredCount` (so `isUnscored` flips to false). `.lowConfidence`/
`.likelySilence` remain gated on real model metrics.

**Invariants.** Read-only classification; audio untouched; no translation; speaker stays nil;
framework-free (pure-Swift text math).

**Evidence.**

Fails before the fix (text heuristic disabled) — a metric-less loop is not flagged:

```text
✘ Test "Text-only repetition is flagged without model metrics; clean metric-less text stays unflagged" recorded an issue at TranscriptQualityTests.swift:182:5: Expectation failed: (report.flagged.first?.flags.contains(.repetitive) → nil) == true
```

Passes after; full suite grew 211 → 212:

```text
✔ Test "Text-only repetition is flagged without model metrics; clean metric-less text stays unflagged" passed after 0.001 seconds.
✔ Test run with 212 tests passed after 1.105 seconds.
```

**Note on updated tests.** Two existing tests used metric-less segments WITH text as stand-ins for
"unscored". Since F55 makes those scored, they were updated to use empty-text metric-less segments
(the now-truly-unscored case); their intent and assertions (`scoredCount`, `confidence` math) are
preserved.

**Gaps.** The text heuristic is a repetition proxy, not Whisper's exact zlib ratio; it targets
degenerate loops (the failure that matters), not subtle repetition.

## F61 — Self-contained printable HTML transcript export

- **Outcome:** fixed
- **Closed:** 2026-07-30 by Claude Code (Opus 4.8) / simonwang
- **Commits:** `<this commit>`

**Feature.** The only single-file human-readable export was Markdown. Added an `.html` format + an
`html(_ request:)` renderer: a standalone document with an inline `<style>` (no external
CSS/fonts/images), HTML-escaped text (`&`,`<`,`>`,`"`), per-segment MM:SS anchors, and an optional
markers table of contents. Appears in the Export menu via `allCases`.

**Invariants.** Fully local — the no-external-URL assertion structurally enforces it; original
language preserved verbatim (only HTML-escaped); no diarization; recording untouched.

**Evidence.**

Fails before the fix (HTML escaping disabled) — raw `<script>` leaks into the document:

```text
✘ Test "HTML export is self-contained, escaped, and offline" recorded an issue at TranscriptExporterTests.swift:215:5: Expectation failed: !((html → "<!DOCTYPE html> ...").contains("<script>"))
✘ Test run with 1 test failed after 0.002 seconds with 3 issues.
```

Passes after (escaping; exactly one `<html`/`<style>`; no `http://`/`https://`; every segment
timestamp present; empty transcript → valid minimal doc); full suite grew 210 → 211:

```text
✔ Test "HTML export is self-contained, escaped, and offline" passed after 0.002 seconds.
✔ Test run with 211 tests passed after 1.140 seconds.
```

**Gaps.** None on the renderer. Uses the `allCases` Export menu; no view test in this harness.

## F60 — Chapters export: turn recording markers into a chapter list + chaptered transcript

- **Outcome:** fixed
- **Closed:** 2026-07-30 by Claude Code (Opus 4.8) / simonwang
- **Commits:** `<this commit>`

**Feature.** Markers only produced a flat "## Markers" list. Added a pure `TranscriptChapters` that
partitions `[0, duration)` into chapters bounded by marker offsets (leading chapter prepended only
when the first marker starts after 0; no markers → one full-duration chapter), assigns each segment
to the chapter whose `[start, end)` contains its start (boundary-start → later chapter), and renders
either a "MM:SS Title" list or a chaptered Markdown transcript. Added `.chapterList` /
`.chapteredMarkdown` to `TranscriptExportFormat` (they appear in the Export menu via `allCases`), a
defaulted `markers` on `TranscriptExportRequest`, and pass `current.orderedMarkers` at the call site.

**Invariants.** Timestamps only — chapters are time ranges, never speakers; fully local;
original-language text copied verbatim; WAV never read/modified.

**Evidence.**

Fails before the fix (segment boundary handling broken to `<= end`) — a boundary segment leaks into
the earlier chapter:

```text
✘ Test "Markers partition the timeline into chapters with correct ranges and segment assignment" recorded an issue at TranscriptChaptersTests.swift:26:5: Expectation failed: (chapters[0].segments.map(\.text) → ["a", "b"]) == ["a"]
```

Passes after (partition ranges, leading chapter, no-marker single chapter, "Marker N" fallback);
full suite grew 207 → 210:

```text
✔ Test "Markers partition the timeline into chapters with correct ranges and segment assignment" passed after 0.001 seconds.
✔ Test "A leading chapter is prepended when the first marker starts after 0" passed after 0.001 seconds.
✔ Test "No markers yields a single full-duration chapter" passed after 0.001 seconds.
✔ Test run with 210 tests passed after 1.290 seconds.
```

**Gaps.** None on the partition logic. The two new formats render via the existing `allCases` Export
menu; no view test in this harness.

## F59 — Faceted meeting search: filter by language, status, duration, and date

- **Outcome:** fixed
- **Closed:** 2026-07-30 by Claude Code (Opus 4.8) / simonwang
- **Commits:** `<this commit>`

**Feature.** Sidebar search only substring-matched title+transcript. Added a pure `MeetingQuery`:
`parse(_:)` peels `lang:`, `status:`, `before:`/`after:YYYY-MM-DD`, and `min:`/`max:` duration tokens
(malformed tokens fall back to free text), leaving the remainder as free text; `matches(_ facets:)`
checks the constraints and delegates free text to `TextSearch.matches`. Wired into `filteredMeetings`
(building `MeetingFacets` from the record) and updated the `.searchable` prompt.

**Invariants.** Read-only over fields already in the index; no audio/network; language is a filter
facet only (never changes `--task transcribe`); no diarization.

**Evidence.**

Fails before the fix (the `min:` duration check disabled) — a 10-minute meeting matches `min:30m`:

```text
✘ Test "MeetingQuery filters by language, duration, and date facets" recorded an issue at MeetingQueryTests.swift:34:5: Expectation failed: !((MeetingQuery.parse("min:30m") ...).matches(... durationSeconds: 600.0 ...) → true)
```

Passes after (incl. the explicit free-text regression guard — a bare word matches identically to a
direct `TextSearch.matches`); full suite grew 205 → 207:

```text
✔ Test "MeetingQuery filters by language, duration, and date facets" passed after 0.002 seconds.
✔ Test "A bare-word MeetingQuery matches identically to a direct TextSearch call" passed after 0.002 seconds.
✔ Test run with 207 tests passed after 1.125 seconds.
```

**Gaps.** None on the query logic. The `.searchable` prompt hints at the token syntax; a richer
facet-picker UI is optional future polish.

## F63 — Summary style controls for the opt-in Claude summary

- **Outcome:** fixed
- **Closed:** 2026-07-30 by Claude Code (Opus 4.8) / simonwang
- **Commits:** `<this commit>`

**Feature.** The summarizer used one fixed prompt shape. Added `SummaryStyle` (`.balanced` default,
`.brief`, `.detailed`, `.actionItemsFocused`), threaded it through the `MeetingSummarizer` protocol
(`summarize(transcript:language:style:)` with a source-compatible 2-arg convenience defaulting to
balanced) and into `ClaudeSummarizer.systemPrompt(language:style:)` via `styleGuidance`. The response
schema and the "do not translate" clause are unchanged for every style.

**Invariants.** Strictly within the one sanctioned cloud exception — no new upload path; the
original-language clause is preserved and asserted for every style; no diarization.

**Evidence.**

Fails before the fix (style guidance omitted from the prompt):

```text
✘ Test "Summary style changes the system prompt but not the schema or the do-not-translate clause" recorded an issue at ClaudeSummarizerTests.swift:150:5: Expectation failed: (ClaudeSummarizer.systemPrompt(language: nil, style: .brief).lowercased() → "you summarize ...").contains("brief")
✘ ...:172:5: Expectation failed: (brief.system → "You summarize ...") != detailed.system
```

Passes after (URLProtocol stub confirms schema byte-identical across styles while the prompt differs);
full suite grew 204 → 205:

```text
✔ Test "Summary style changes the system prompt but not the schema or the do-not-translate clause" passed after 0.008 seconds.
✔ Test run with 205 tests passed after 1.146 seconds.
```

**Gaps.** The tested core + protocol threading are done; the compact style picker + Regenerate button
in the summary UI is a follow-up (SwiftUI, not view-tested here). `AppModel.summarize` still uses the
balanced default until the picker is wired.

**Follow-up filed:** F81 (2026-07-31) — the deferred app wiring is now tracked on the board.

## F67 — Meeting tags with click-to-filter sidebar

- **Outcome:** fixed
- **Closed:** 2026-07-30 by Claude Code (Opus 4.8) / simonwang
- **Commits:** `<this commit>`

**Feature.** The sidebar had no organizing axis beyond free-text search. Added a pure `MeetingTags`
(`normalized` — trim/drop-empty/length-cap/case-insensitive-dedupe/count-cap; `matches` — AND/OR),
optional `MeetingRecord.tags` (old indexes decode), `MeetingStore.setTags(id:_:)`, a comma-separated
tag editor in the detail view, and tag chips in the sidebar row.

**Invariants.** Pure label metadata in `meetings.json`; never reads/mutates audio; no network; tags
are user labels, never speaker identity; transcription language untouched.

**Evidence.**

Fails before the fix (dedupe made case-sensitive):

```text
✘ Test "Tag normalization trims, drops empties, dedupes case-insensitively, and caps" recorded an issue at MeetingTagsTests.swift:7:5: Expectation failed: (MeetingTags.normalized(["Budget", "budget", "  ", "Hiring", "BUDGET"]) → ["Budget", "budget", "Hiring", "BUDGET"]) == ["Budget", "Hiring"]
```

Passes after, full suite grew 202 → 204:

```text
✔ Test "Tag normalization trims, drops empties, dedupes case-insensitively, and caps" passed after 0.001 seconds.
✔ Test "Tag matching honors AND / OR and an empty selection matches all" passed after 0.001 seconds.
✔ Test run with 204 tests passed after 1.143 seconds.
```

**Gaps.** Delivered the tested core + persistence + editor + chips. The sidebar tag-FILTER UI (a
selected-tags predicate composing into `filteredMeetings`) is a follow-up on top of the tested
`matches`. Legacy decode of an index without `tags` follows the same optional-field mechanism proven
by the F64 `legacyIndexWithoutPinnedDecodes` test (tags decodes to nil).

**Follow-up filed:** F84 (2026-07-31) — the deferred app wiring is now tracked on the board.

## F72 — Per-meeting notes field, searchable and exported

- **Outcome:** fixed
- **Closed:** 2026-07-30 by Claude Code (Opus 4.8) / simonwang
- **Commits:** `<this commit>`

**Feature.** There was no neutral per-meeting scratchpad (agenda/attendee notes) separate from the
transcript and summary. Added optional `MeetingRecord.notes` (old indexes decode), a `notes:` param
to `MeetingNotesExporter.markdown` emitting a "## Notes" section above "## Transcript", included notes
in `filteredMeetings`' searched fields, and added a plain notes editor to `TranscriptDetailView`
(flushes via `update(id:)`).

**Invariants.** Index-only text; no audio read/write; local-only — notes are NOT sent to Claude
(`summarize` takes only the transcript, so notes are excluded by construction); no diarization.

**Evidence.**

Fails before the fix (Notes section emission neutralized):

```text
✘ Test "Meeting notes export includes a Notes section only when notes are present" recorded an issue at MeetingNotesExporterTests.swift:77:5: Expectation failed: (withNotes → "# Weekly Sync ...").contains("## Notes")
```

Passes after (both the exporter section test and the note-searchability test), full suite grew
200 → 202:

```text
✔ Test "Meeting notes export includes a Notes section only when notes are present" passed after 0.001 seconds.
✔ Test "A note-only term matches once notes is included in the searched fields" passed after 0.001 seconds.
✔ Test run with 202 tests passed after 1.135 seconds.
```

**Gaps.** The "notes never sent to Claude" invariant holds by construction (not asserted by a test —
`summarize` has no notes parameter). The SwiftUI notes editor flushes per edit via `update(id:)`
(same write pattern as the transcript editor; the F40 debounce concern applies but notes are short).

## F57 — Local notification when a meeting transcription finishes or fails

- **Outcome:** fixed
- **Closed:** 2026-07-30 by Claude Code (Opus 4.8) / simonwang
- **Commits:** `<this commit>`

**Feature.** A long transcription reported nothing on completion. Added a pure
`TranscriptionNotification` (`content(title:outcome:segmentCount:)` → (title, body) for
completed/failed, nil for cancelled; `shouldNotify(outcome:appIsActive:)` suppressing while
frontmost), and wired it into `AppModel.apply(result:)` (completed) and `handle(error:)` (failed),
reusing the dictation `UNUserNotificationCenter` pattern.

**Invariants.** Local OS notification only — nothing uploaded, Claude path untouched; the body carries
only the meeting title + outcome, never transcript content; recording/transcript unchanged.

**Evidence.**

Fails before the fix (frontmost suppression removed from `shouldNotify`):

```text
✘ Test "Transcription notification content and gating rules" recorded an issue at TranscriptionNotificationTests.swift:18:5: Expectation failed: !(TranscriptionNotification.shouldNotify(outcome: .completed, appIsActive: true) → true)
✘ Test run with 1 test failed after 0.001 seconds with 1 issue.
```

Passes after, full suite grew 199 → 200:

```text
✔ Test "Transcription notification content and gating rules" passed after 0.001 seconds.
✔ Test run with 200 tests passed after 1.095 seconds.
```

**Gaps.** The pure content/gating is tested; the actual `UNUserNotificationCenter` post + best-effort
authorization is not (matches the existing untested dictation `notifyClipboard`). Tap-to-select-meeting
(a `UNUserNotificationCenterDelegate`) is a follow-up, not implemented here.

## F68 — Structured transcription-failure classification and retry ergonomics

- **Outcome:** fixed
- **Closed:** 2026-07-30 by Claude Code (Opus 4.8) / simonwang
- **Commits:** `<this commit>`

**Feature.** `AppModel.handle(error:)` stored an unstructured message and flipped to `.failed`, so the
single Transcribe button couldn't tell a transient crash (retry) from runtime-not-installed (install)
from missing/empty audio (re-import). Added a pure `TranscriptionFailureClassifier` mapping both
`LocalWhisperError` and `QwenASRError` (identical case shapes) plus `CancellationError` to a
`FailureCategory { action, explanation }` with a `SuggestedAction` (`installRuntime` / `reimport` /
`retry` / `none`). Wired it into `handle(error:)`: the stored message is now the actionable
explanation, keeping the underlying subprocess detail for retry-class failures.

**Invariants.** Pure deterministic mapping — no audio access, no language logic, local-only; it
classifies an existing failure, source-of-truth untouched. Distinct from F30.

**Evidence.**

Fails before the fix (`installRuntime` mapping neutralized to `.retry`):

```text
✘ Test "Transcription failures classify into actionable categories" recorded an issue at TranscriptionFailureClassifierTests.swift:11:5: Expectation failed: (TranscriptionFailureClassifier.classify(QwenASRError.runtimeNotInstalled).action → .retry) == .installRuntime
✘ Test run with 1 test failed after 0.001 seconds with 2 issues.
```

Passes after, full suite grew 198 → 199:

```text
✔ Test "Transcription failures classify into actionable categories" passed after 0.001 seconds.
✔ Test run with 199 tests passed after 1.135 seconds.
```

**Gaps.** The classifier and its use in `handle(error:)` are covered; rendering a distinct
action-specific button in the SwiftUI detail (vs the improved message) is a follow-up, not view-tested
here. `insufficientStorage` / `audioTooShort` categories are documented as reachable only if those
error cases are introduced.

## F64 — Pin important meetings to the top of the sidebar

- **Outcome:** fixed
- **Closed:** 2026-07-30 by Claude Code (Opus 4.8) / simonwang
- **Commits:** `<this commit>`

**Feature.** Meetings were strictly reverse-chronological, so a reference/recurring recording sank
out of view. Added optional `pinned: Bool?` to `MeetingRecord` (old indexes still decode), a pure
`MeetingOrdering.sorted(_:)` (pinned first, then newest `createdAt`), replaced both inline store sorts
with it, and added `MeetingStore.togglePin(id:)`. UI: Pin/Unpin in the row context menu and a
`pin.fill` badge on pinned rows.

**Invariants.** A single ordering flag in the index; audio/source tracks untouched; no
network/diarization.

**Evidence.**

Fails before the fix (pin priority removed from `MeetingOrdering`) — the pinned older meeting sorts by
date:

```text
✘ Test "Pinned meetings sort first, then newest createdAt" recorded an issue at MeetingOrderingTests.swift:17:5: Expectation failed: (sorted.map(\.title) → ["new", "pinned", "old"]) == ["pinned", "new", "old"]
✘ Test run with 1 test failed after 0.001 seconds with 1 issue.
```

Passes after, full suite grew 196 → 198:

```text
✔ Test "Pinned meetings sort first, then newest createdAt" passed after 0.001 seconds.
✔ Test "A meetings index written before the pinned field still decodes" passed after 0.001 seconds.
✔ Test run with 198 tests passed after 2.284 seconds.
```

**Gaps.** Delivered pin-first ordering everywhere + a pin badge rather than a separate
"Pinned"/"Meetings" sidebar section (the section split is cosmetic on top of the ordering). The
SwiftUI context menu / badge are not view-tested in this harness.

## F37 — Dictation is blocked while a *meeting* model runtime installs

- **Outcome:** fixed
- **Closed:** 2026-07-30 by Claude Code (Opus 4.8) / simonwang
- **Commits:** `<this commit>`

**Root cause.** `AppEntry` folded `isInstallingRecognitionRuntime` into dictation's `isMicrophoneBusy`
predicate. The pause during a meeting-runtime install is intended (a multi-GB install contends for
CPU/memory), but expressing it as a microphone conflict was inaccurate and undocumented, and the
`DictationController` itself had no first-class notion of the reason.

**Fix.** Confirmed the behavior is intended and made it first-class: added
`DictationController.configureRuntimeInstalling(_:)` and a distinct guard in `handlePressStart`
(logs "a recognition model is installing (avoids CPU/memory contention)"), wired separately from
`isMicrophoneBusy` in `AppEntry`. Documented it in `docs/QUICK_DICTATION_DESIGN.md` as a deliberate
contention guard.

**Evidence.**

Fails before the fix (install guard neutralized) — a press during an install starts capture:

```text
✘ Test "Dictation is paused while a recognition runtime is installing, then resumes" recorded an issue at DictationToggleRecoveryTests.swift:155:5: Expectation failed: (controller.status → .listening) != .listening
✘ Test run with 1 test failed after 0.008 seconds with 2 issues.
```

Passes after, full suite grew 195 → 196:

```text
✔ Test "Dictation is paused while a recognition runtime is installing, then resumes" passed after 0.005 seconds.
✔ Test run with 196 tests passed after 1.132 seconds.
```

**Gaps.** The user-facing overlay remains the shared brief "busy" pill (a tiny non-activating panel);
the accurate reason is surfaced in logs/diagnostics and the design doc. Enriching the overlay with a
distinct install message is a possible follow-up, not required by this ticket.

## F36 — The Qwen subprocess contract has no upstream documentation anchor

- **Outcome:** fixed
- **Closed:** 2026-07-30 by Claude Code (Opus 4.8) / simonwang
- **Commits:** `<this commit>`

**Root cause.** The definition of done requires live-doc verification for the Whisper **or Qwen**
contract "per AGENTS.md", but AGENTS.md's Upstream-documentation section named only whisperai.com and
github.com/openai/whisper — the Qwen / `mlx-audio` call contract was unanchored, so the rule could not
be followed as written.

**Fix.** Added a Qwen3-ASR paragraph to AGENTS.md. It names the pinned package (`mlx-audio==0.3.1`
from `Scripts/setup-qwen-asr.sh`), scopes the contract (`generate(language=, chunk_duration=,
min_chunk_duration=)` plus segment/alignment shapes), and — since there is no hosted API reference —
requires citing the **installed package source** for the pinned version (mirroring how the F24 entry
cited `mlx_whisper/transcribe.py:175`), plus re-verifying and recording a citation on any pin bump.

**Evidence.** Documentation-only. Verified the pinned version against the installer
(`Scripts/setup-qwen-asr.sh:15,125` → `mlx-audio==0.3.1`). No behavior change → no
fails-before/passes-after test.

**Gaps.** The upstream GitHub URL is intentionally not asserted (unverified); the anchor points at the
installed package source, which is the reliable citation for a pinned dependency.

## F34 — `QUICK_DICTATION_DESIGN.md` still locks dictation to Whisper turbo

- **Outcome:** fixed
- **Closed:** 2026-07-30 by Claude Code (Opus 4.8) / simonwang
- **Commits:** `<this commit>`

**Root cause.** The design spec still said "shares only the local Whisper runtime" and listed
"Transcription engine | Local Whisper `turbo`", but `DictationController` now offers a Whisper/Qwen
selector — so the doc contradicted shipped behavior.

**Fix.** Updated `docs/QUICK_DICTATION_DESIGN.md`: an update note + the Decisions table now describe
the Settings engine selector (Whisper `turbo` default; Qwen3-ASR 1.7B MLX 8-bit opt-in on Apple
silicon) and state that the vocabulary `initial_prompt` applies to Whisper only. The "Original
language only" bullet now notes Qwen returns original-language recognition.

**Evidence.** Documentation-only. Verified against current code: `DictationController` defaults the
stored engine to `.whisperTurbo`; `DictationTranscriptionEngine.qwenBalanced.supportsVocabularyPrompt`
is `false` (asserted by `dictationModelCapabilitiesAreExplicit`). No behavior change → no
fails-before/passes-after test.

**Gaps.** None applicable — docs ticket.

## F54 — CHANGELOG intro test-count claim is stale

- **Outcome:** fixed
- **Closed:** 2026-07-30 by Claude Code (Opus 4.8) / simonwang
- **Commits:** `<this commit>`

**Root cause.** The CHANGELOG opening summary pinned "Test count grew 28 → 157" while later cycle
entries recorded 169/176/178, and the live suite is now 195 — the header contradicted the file's own
evidence and would go stale again with any new number.

**Fix.** Reworded the intro to state the suite has grown from 28 across rounds and to point readers at
each cycle's own recorded count, rather than pinning a single fragile figure.

**Evidence.** Documentation-only change (no behavior, so no fails-before/passes-after test). Verified
by inspection: `docs/CHANGELOG.md:6` no longer states a specific total; the per-cycle counts below it
remain the authoritative figures. The live Swift suite at close: `✔ Test run with 195 tests passed`.

**Gaps.** None applicable — docs ticket.

## F35 — `SelectableDictationEngine.replace` is a non-atomic read → await → write

- **Outcome:** fixed
- **Closed:** 2026-07-30 by Claude Code (Opus 4.8) / simonwang
- **Commits:** `<this commit>`

**Root cause.** `replace` read `current`, awaited `retire()`, then installed. The `NSLock` cannot be
held across the `await`, so two concurrent replaces both read the same engine and both retired it,
and one installed engine was then overwritten without being retired (a leaked resident model). Safety
depended entirely on a `@MainActor` guard in `DictationController` — in the other module — despite the
class advertising `@unchecked Sendable`.

**Fix.** Serialized replacements inside the class: each `replace` enqueues a task that first awaits
the previous replacement's task, then reads `current`, retires it, and installs. A synchronous
`enqueueReplace` helper holds the `NSLock` only to chain the task (no lock held across an await). The
class is now self-sufficient.

**Evidence.**

Fails before the fix — the initial engine is retired twice and both replacements leak:

```text
✘ Test "Concurrent engine replacements retire the initial engine once and leak none" recorded an issue at DictationModelSelectionTests.swift:96:5: Expectation failed: (initial.shutdownCount → 2) == 1
✘ ...:97:5: Expectation failed: (first.shutdownCount + second.shutdownCount → 0) == 1
✘ Test run with 1 test failed after 0.022 seconds with 2 issues.
```

Passes after, full suite grew 194 → 195:

```text
✔ Test "Concurrent engine replacements retire the initial engine once and leak none" passed after 0.048 seconds.
✔ Test run with 195 tests passed after 2.035 seconds.
```

**Gaps.** None. The test forces the interleaving with a suspending `retire()` in the spy.

## F53 — Qwen empty/silent clip surfaces a raw Python traceback

- **Outcome:** fixed
- **Closed:** 2026-07-30 by Claude Code (Opus 4.8) / simonwang
- **Commits:** `<this commit>`

**Root cause.** On empty text the helper did `raise RuntimeError(...)` before writing any output, so
the process exited non-zero. `QwenASRClient.run` hits its `terminationStatus == 0` guard first and
threw `.processFailed` with the captured traceback, so the dedicated `.emptyTranscript` ("No speech
was detected") guard could never fire — a raw traceback in a modal, inconsistent with the Whisper
path.

**Fix.** The empty-text branch now writes an empty-text payload (`{"text":"", …}`) via a new
`write_payload()` helper and returns 0, so the client reads it, sees empty text, and surfaces
`.emptyTranscript`. The normal path uses the same `write_payload()`.

**Evidence.** `python3 Scripts/tests/test_qwen_transcribe.py`, driving `main()` with a fake mlx /
mlx_audio (the empty case returns exit 0 + `{"text":""}`). Fails before the fix (empty branch
restored to `raise`):

```text
    raise RuntimeError("Qwen3-ASR returned an empty transcript.")  # RED-GREEN old behavior
RuntimeError: Qwen3-ASR returned an empty transcript.
Ran 7 tests in 0.002s
FAILED (errors=1)
```

Passes after:

```text
Ran 7 tests in 0.002s
OK
```

**Gaps.** `main()` is exercised with injected fake mlx modules (the heavy imports are deferred inside
`main()`), not the real mlx-audio runtime. The client-side `.emptyTranscript` guard is unchanged and
already covered by `QwenASRClient` tests; this fixes the helper so that guard is reachable.

## F51 — Qwen segment parsing is unguarded; a schema drift discards the whole transcript

- **Outcome:** fixed
- **Closed:** 2026-07-30 by Claude Code (Opus 4.8) / simonwang
- **Commits:** `<this commit>`

**Root cause.** `align_chunks` is try/except-wrapped so an alignment failure preserves the text, but
the ASR segment extraction that runs before it (`for segment in transcription.segments`, indexing
`segment["text"/"start"/"end"]`) had no guard. A schema drift there raised `KeyError`/`AttributeError`
out of `main()`, exiting non-zero before the payload (with the full text) was written, so
`QwenASRClient` reported `.processFailed` and the user lost a transcript that existed.

**Fix.** Extracted the segment extraction into `build_chunks(segments)` wrapped in try/except: on any
failure it degrades to `([], warning)` and prints a stderr note, mirroring `align_chunks`. `main()`
now writes the payload with the full `text`, `alignedItems: []`, and the `alignmentWarning` set to
`alignment_warning or chunk_warning`.

**Evidence.** `python3 Scripts/tests/test_qwen_transcribe.py`. Fails before the fix (guard removed) —
the drift raises out of `build_chunks`:

```text
    if segment["text"].strip()
KeyError: 'text'
Ran 6 tests in 0.001s
FAILED (errors=1)
```

Passes after (`build_chunks` degrades to `[], warning`):

```text
Ran 6 tests in 0.000s
OK
```

**Gaps.** `build_chunks` is unit-tested directly (pure function). The end-to-end `main()` path (empty
`chunks` → payload still written) is validated by inspection + the `ast.parse` check, not a live
mlx-audio run — the change is defensive Python around already-produced ASR output, not the
`generate()` call contract.

## F41 — Qwen auto-detect labels any transcript containing a single CJK character as `zh`

- **Outcome:** fixed
- **Closed:** 2026-07-30 by Claude Code (Opus 4.8) / simonwang
- **Commits:** `<this commit>`

**Root cause.** Under `--language auto`, the top-level language label was
`"zh" if alignment_language(text, "auto") == "Chinese" else "en"`, and `alignment_language` returns
"Chinese" on ANY CJK character. So a mostly-English meeting mentioning one Chinese name ("meet in
北京") was labeled `zh`, disagreeing with Whisper on the same audio and biasing the Claude summary
language.

**Fix.** Added a pure `detected_language_code(text)` that labels `zh` only when CJK is the MAJORITY
of non-whitespace characters, and used it for the top-level `language_code`. The per-chunk aligner
heuristic (`alignment_language`) is unchanged, as the ticket scoped.

**Evidence.** New Python unit tests (`python3 Scripts/tests/test_qwen_transcribe.py`) — the helper's
pure functions are importable without mlx. Fails before the fix (function body reverted to the old
any-CJK rule):

```text
    self.assertEqual(qwen.detected_language_code("Let's meet in 北京 next week"), "en")
AssertionError: 'zh' != 'en'
FAILED (failures=1)
```

Passes after:

```text
test_empty_is_en ... ok
test_mostly_chinese_is_zh ... ok
test_mostly_english_with_one_cjk_name_is_en ... ok
test_pure_english_is_en ... ok
Ran 4 tests in 0.000s
OK
```

Swift suite unaffected: `✔ Test run with 194 tests passed`.

**Gaps.** Verified via a new Python test harness (not part of `swift test`; the 194 count is Swift
only). No live mlx-audio run — the change is to pure post-processing of the ASR text, not the
`generate()` call contract, so no upstream doc fetch applies.

## F49 — Vocabulary import is UTF-8-only; one bad file aborts the whole batch

- **Outcome:** fixed
- **Closed:** 2026-07-30 by Claude Code (Opus 4.8) / simonwang
- **Commits:** `<this commit>`

**Root cause.** `VocabularyExtractor.extract` decoded txt/md/markdown/csv with
`String(contentsOf:encoding:.utf8)`, which throws on any non-UTF-8 file (Excel CSV as Windows-1252,
UTF-16, Latin-1). The batch importer ran `try urls.flatMap(extract)` in one do/catch, so a single
non-UTF-8 file threw and imported zero terms — even though CSV is a documented import format.

**Fix.** Two changes: (1) `readText(from:)` tolerant reader — the file's declared encoding first
(via `usedEncoding:`), then a fallback list (utf8, utf16, windowsCP1252, isoLatin1); (2)
`extractBatch(from:)` collects per-file failures instead of aborting, returning merged first-seen-
deduplicated terms plus the failed URLs. `importDocuments` now calls `extractBatch` and reports a
partial-success message ("N files… skipped") instead of one blanket error.

**Evidence.**

Fails before the fix (tolerant read reverted to UTF-8-only) — the UTF-16 file throws, and in the
batch its terms are lost while it lands in `failed`:

```text
✘ Test "Vocabulary import reads a non-UTF-8 (UTF-16) document" recorded an issue at VocabularyExtractorEncodingTests.swift:13:2: Caught error: Error Domain=NSCocoaErrorDomain Code=259 "The file couldn’t be opened because it isn’t in the correct format."
✘ Test "Vocabulary batch import skips a bad file and keeps the good files' terms" recorded an issue at VocabularyExtractorEncodingTests.swift:39:5: Expectation failed: (result.terms → ["Grafana"]).contains("Kubernetes")
✘ Test run with 2 tests failed after 0.052 seconds with 3 issues.
```

Passes after, full suite grew 192 → 194:

```text
✔ Test "Vocabulary import reads a non-UTF-8 (UTF-16) document" passed after 0.098 seconds.
✔ Test "Vocabulary batch import skips a bad file and keeps the good files' terms" passed after 0.140 seconds.
✔ Test run with 194 tests passed after 1.122 seconds.
```

**Gaps.** The batch-abort fix (inline `flatMap` → `extractBatch`) is verified via `extractBatch`'s
resilience test; the old inline `flatMap` lived in the SwiftUI view and is not directly red-green
tested. The `importDocuments` rewrite to call `extractBatch` is exercised only by the extractor tests
(no view test in this harness).

## F47 — Startup orphan-recovery aborts all remaining orphans on the first throwing folder

- **Outcome:** fixed
- **Closed:** 2026-07-30 by Claude Code (Opus 4.8) / simonwang
- **Commits:** `<this commit>`

**Root cause.** `performStartupRecovery` wrapped the whole `for orphan in …` loop in a single
do/catch. `InterruptedRecordingRecovery.recover()` does throwing I/O, so a throw on orphan N
propagated to the one catch and skipped every later orphan. Since orphans iterate in stable
`createdAt` order, one persistently-broken folder blocked recovery of all later ones on every launch.

**Fix.** Wrapped the per-orphan recover call in its own do/catch: a failure appends a per-folder
message ("could not be rebuilt and was left untouched") and `continue`s to the next orphan. The
folder is never deleted (raw tracks preserved). The outer catch still guards `orphanedRecordings()`
itself (a genuine can't-scan abort). To make it testable, the recover step is now an injectable
`@Sendable` seam on `AppModel` defaulting to the real rebuild.

**Evidence.**

Fails before the fix (per-orphan catch removed, injectable seam kept) — the middle throw aborts the
loop, so only the first orphan is recovered:

```text
✘ Test "A throwing orphan folder does not block recovery of the others" recorded an issue at StartupRecoveryResilienceTests.swift:61:5: Expectation failed: (model.store.meetings.count → 1) == 2
✘ Test run with 1 test failed after 0.217 seconds with 1 issue.
```

Passes after, full suite grew 191 → 192 (first headless `AppModel` test):

```text
✔ Test "A throwing orphan folder does not block recovery of the others" passed after 0.861 seconds.
✔ Test run with 192 tests passed after 1.085 seconds.
```

**Gaps.** The test injects a fake recover that throws on the 2nd of 3 real on-disk orphan folders
rather than crafting a folder that makes the real `recover()` throw; the resilience behavior (per-
orphan isolation) is what's under test, and the real recover path is unchanged.

## F46 — Preflight headline contradicts its own microphone note on transient-only capture

- **Outcome:** fixed
- **Closed:** 2026-07-30 by Claude Code (Opus 4.8) / simonwang
- **Commits:** `<this commit>`

**Root cause.** A lone transient (peak ≥ silentCeiling but crest factor > 20) is not sustained, so
`isCapturing` was false and the headline fell into the generic "No microphone audio was captured"
branch — while `micNote` (via `isTransientOnly`) simultaneously said "Only a brief sound (a click or
tap) was detected". Headline and note contradicted each other.

**Fix.** Added a transient-specific headline branch (reusing `isTransientOnly`) ahead of the generic
"no audio" branch, so the headline agrees with the note. `isReady` stays false — a click is correctly
not treated as speech.

**Evidence.**

Fails before the fix:

```text
✘ Test "A transient-only microphone gets a headline that agrees with its note, not a false 'no audio'" recorded an issue at PreflightTestTests.swift:180:5: Expectation failed: !((report.headline → "No microphone audio was captured — fix this before your meeting.").contains("No microphone audio was captured") → true)
✘ Test run with 1 test failed after 0.001 seconds with 2 issues.
```

Passes after, full suite grew 190 → 191:

```text
✔ Test "A transient-only microphone gets a headline that agrees with its note, not a false 'no audio'" passed after 0.001 seconds.
✔ Test run with 191 tests passed after 1.091 seconds.
```

**Gaps.** None. Pure WhisperCore verdict logic; readiness gating unchanged.

## F45 — ClaudeSummarizer never handles `stop_reason == "max_tokens"`

- **Outcome:** fixed
- **Closed:** 2026-07-30 by Claude Code (Opus 4.8) / simonwang
- **Commits:** `<this commit>`

**Root cause.** `decodeSummary` branched only on `stop_reason == "refusal"`. On a token-cap hit the
API returns HTTP 200 with `stop_reason == "max_tokens"` and truncated JSON, so the decode failed and
surfaced `.unreadableResponse` ("Claude returned a summary the app could not read") — misleading and
non-actionable, since a retry at the same cap fails again.

**Fix.** Detect `stop_reason == "max_tokens"` before decoding and throw a new `SummarizerError`
`.responseTruncated` with actionable guidance ("cut off at the length limit… summarize a shorter
transcript, or raise the summary length limit"). Also raised the default `maxTokens` 4_000 → 8_000 to
reduce how often long meetings hit the cap.

**Evidence.**

Fails before the fix (only the truncation-detection change stashed; the enum case stays) — the bug's
`.unreadableResponse` is thrown:

```text
✘ Test "A max_tokens stop reason surfaces as a distinct truncation error, not unreadable" recorded an issue at ClaudeSummarizerTests.swift:135:11: Expectation failed: expected error "responseTruncated" of type SummarizerError, but "unreadableResponse" of type SummarizerError was thrown instead
✘ Test run with 1 test failed after 0.006 seconds with 1 issue.
```

Passes after, full suite grew 189 → 190:

```text
✔ Test "A max_tokens stop reason surfaces as a distinct truncation error, not unreadable" passed after 0.008 seconds.
✔ Test run with 190 tests passed after 1.095 seconds.
```

**Gaps.** The Claude API contract (`stop_reason` values, `output_config` json_schema) was not
re-fetched from live docs this cycle; the `max_tokens` value is a documented, long-standing Anthropic
stop reason and the change only adds a branch on it. Not exercised against a live API call (the
`URLProtocol` stub mirrors the documented 200+truncated-JSON shape).

## F42 — Export strips a leading clock-like token as a timestamp on non-timestamped transcripts

- **Outcome:** fixed
- **Closed:** 2026-07-30 by Claude Code (Opus 4.8) / simonwang
- **Commits:** `<this commit>`

**Root cause.** Both export paths consumed a leading `\d{1,3}:\d{2}` token as a timestamp without
checking the transcript was genuinely timestamped: `stripTimestamps` for plain text and
`transcriptLines` (inside `effectiveSegments`) for SRT/VTT/JSON. A verbatim, non-timestamped
transcript (e.g. an unaligned Qwen result) whose line began "3:00 PM kickoff" lost "3:00" — plain
text became "PM kickoff" and subtitles emitted a cue mis-timed to 00:03:00. `isTimestamped` could not
be used as the gate because it false-positives on prose like "3:00 PM".

**Fix.** Gate on whether timed segments actually back the transcript, which is the real invariant:
the export request always pairs `transcriptText` with the meeting's `segments`, and `transcriptText`
is only ever in `MM:SS  text` form when it was generated from segments. Plain text now strips only
when `!segments.isEmpty`; `effectiveSegments` short-circuits to a single full-duration cue carrying
the verbatim text when there are no segments. This is the right layer — the exporter already owns the
segment/cue derivation.

**Evidence.**

The new regression fails before the fix:

```text
✘ Test "Export does not strip a leading clock-like token from a non-timestamped transcript" recorded an issue at TranscriptExporterTests.swift:43:5: Expectation failed: (TranscriptExporter.render(.plainText, request) → "PM kickoff") == "3:00 PM kickoff"
✘ Test run with 1 test failed after 0.002 seconds with 3 issues.
```

Passes after, full suite 189:

```text
✔ Test "Export does not strip a leading clock-like token from a non-timestamped transcript" passed after 0.001 seconds.
✔ Test run with 189 tests passed after 1.096 seconds.
```

**Note on an updated test.** `stripsThreeDigitMinuteTimestamps` previously passed `segments: []` with
genuinely-timestamped text — an input impossible in the real app (verified: `ContentView` builds the
export request from the same record's `transcriptText` + `segments`). It was updated to carry the two
backing segments; its assertion and expected output ("Almost there.\nWrap up.") are unchanged, so the
3-digit-minute stripping it targets is still exercised.

**Gaps.** None. Behavior verified against the real export-request construction path.

## F44 — WebVTT/SubRip export writes cue text unescaped

- **Outcome:** fixed
- **Closed:** 2026-07-30 by Claude Code (Opus 4.8) / simonwang
- **Commits:** `<this commit>`

**Root cause.** `vtt`/`srt` embedded the raw segment text with no escaping. WebVTT decodes entities
and forbids a literal `-->` in a cue payload, so an edited transcript containing `&`, `<`, `>`, or a
stray `-->` produced spec-invalid WebVTT (and SRT could mis-interpret a `<tag>`).

**Fix.** Added `escapeCueText(_:escapeAmpersand:)`: WebVTT escapes `&`→`&amp;`, `<`→`&lt;`,
`>`→`&gt;` in order (escaping `>` also turns any `-->` into `--&gt;`, satisfying the no-arrow rule);
SubRip escapes only `<`/`>` because it does not decode `&` (so "AT&T" stays literal). Applied in both
renderers.

**Evidence.**

Fails before the fix — the unescaped payload keeps a second literal `-->` and raw `<>`:

```text
✘ Test "WebVTT and SubRip escape special characters in cue text" recorded an issue at TranscriptExporterTests.swift:45:5: Expectation failed: (vtt.components(separatedBy: "-->").count - 1 → 2) == 1
✘ ...:49:5: Expectation failed: (srt.components(separatedBy: "-->").count - 1 → 2) == 1
✘ Test run with 1 test failed after 0.002 seconds with 4 issues.
```

Passes after, full suite grew 187 → 188:

```text
✔ Test "WebVTT and SubRip escape special characters in cue text" passed after 0.002 seconds.
✔ Test run with 188 tests passed after 1.101 seconds.
```

**Gaps.** None. Escaping is applied to cue payload only; the timestamp separator line is unaffected.

## F43 — In-transcript find double-counts overlapping/duplicate query terms

- **Outcome:** fixed
- **Closed:** 2026-07-30 by Claude Code (Opus 4.8) / simonwang
- **Commits:** `<this commit>`

**Root cause.** `TextSearch.occurrenceRanges` searched each whitespace-split term independently and
concatenated the hits, only sorting the result. Two terms covering the same visible text — a
duplicated word ("the the") or a substring pair ("meet"/"meeting") — produced overlapping ranges, so
`occurrences` counted the same region twice and Prev/Next stepped onto visually identical positions.

**Fix.** After sorting, merge overlapping ranges into their union (a range is dropped if fully
contained, or extends the previous one if it overhangs). Adjacent-but-non-overlapping matches stay
distinct. Both counting (`occurrences`) and highlighting read the merged list, so they now agree.

**Evidence.**

Fails before the fix:

```text
✘ Test "Overlapping query terms count and highlight one merged region, not two" recorded an issue at TextSearchTests.swift:41:5: Expectation failed: (overlapping.count → 2) == 1
✘ ...:42:5: Expectation failed: (overlapping.map { ... } → ["meet", "meeting"]) == ["meeting"]
✘ ...:45:5: Expectation failed: (TextSearch.occurrences("the the", in: ["the cat"]).count → 2) == 1
✘ Test run with 1 test failed after 0.001 seconds with 3 issues.
```

Passes after, full suite grew 186 → 187:

```text
✔ Test "Overlapping query terms count and highlight one merged region, not two" passed after 0.001 seconds.
✔ Test run with 187 tests passed after 1.098 seconds.
```

**Gaps.** None. Pure WhisperCore change; the ContentView highlight/navigation now consume the deduped
list transitively (no view test in this harness).

## F39 — Changing the dictation trigger key leaves `hotkeyActive`/`status` stale

- **Outcome:** fixed
- **Closed:** 2026-07-30 by Claude Code (Opus 4.8) / simonwang
- **Commits:** `<this commit>`

**Root cause.** The `hotkey` didSet restarted the tap with `_ = hotkeyMonitor.start(hotkey:)` and
discarded the `Bool`, unlike `apply()` which reflects it into `hotkeyActive`/`status`. So after
enable-without-Accessibility (`.error`), granting Accessibility, then changing the key, the tap was
re-created successfully but `status` stayed `.error` and `hotkeyActive` stayed false (and the reverse
failure was silent). The diagnostics row and menu-bar glyph then disagreed with reality until the
user toggled dictation off/on.

**Fix.** Extracted the start-and-reflect logic into `applyHotkeyStart()` and called it from both
`apply()` and the `hotkey` didSet, so the re-tap result is always applied. Used the `HotkeyMonitoring`
seam from F38 to inject a fake monitor with a controllable `start()` result.

**Evidence.**

Fails before the fix (old didSet discards the result) — the re-tap succeeds but `status` stays
`.error`:

```text
✘ Test "Changing the dictation hotkey re-syncs status from the re-tap result" recorded an issue at HotkeyChangeResyncTests.swift:42:5: Expectation failed: (controller.status → .error("Enable Accessibility (and, if needed, Input Monitoring) for WhisperMeet in System Settings → Privacy & Security.")) == .idle
✘ Test run with 1 test failed after 0.007 seconds with 1 issue.
```

Passes after, full suite grew 185 → 186:

```text
✔ Test "Changing the dictation hotkey re-syncs status from the re-tap result" passed after 0.012 seconds.
✔ Test run with 186 tests passed after 1.052 seconds.
```

**Review.** Self-review: `applyHotkeyStart()` is a behavior-preserving extraction of `apply()`'s
existing start/status logic, now shared; the only change is that the didSet reflects the result. The
"dictation enabled" log now precedes the (possible) error log — cosmetic only.

**Gaps.** `hotkeyActive` is `private`, so the test asserts the user-visible `status` (which
`applyHotkeyStart` sets together with `hotkeyActive` in the same branch) rather than reading
`hotkeyActive` directly. No runtime helper/model adapter touched.

## F78 — Toggle-mode dictation desyncs after the F50 capture watchdog auto-finalizes

- **Outcome:** fixed
- **Closed:** 2026-07-30 by Claude Code (Opus 4.8) / simonwang
- **Commits:** `<this commit>`

**Root cause.** Filed during the F38 review. F38 cleared toggle state on *refused* starts, but a
successful toggle start latches `toggledOn = true` and relies on a user end-edge to clear it. The F50
capture watchdog finalizes a stuck `.listening` session by calling `beginTranscriptionIfNeeded()`
from its `onTimeout` closure with no hotkey edge, so `toggledOn` stayed `true`. The user's next press
was then read as the "stop" edge (`onPressEnd` → no-op, nothing recording); only the press after that
started a new capture.

**Fix.** Call `hotkeyMonitor.resetToggleState()` in the watchdog `onTimeout` closure, right after
finalizing — the one capture-end path that has no user edge. It is deliberately NOT placed inside
`beginTranscriptionIfNeeded()` (the normal press-driven stop already cleared the toggle via its edge)
and is a no-op in hold mode.

**Evidence.**

Fails before the fix (reset neutralized) — the post-watchdog press is swallowed:

```text
✘ Test "After the capture watchdog auto-finalizes a toggle dictation, the next press starts a new one" recorded an issue at DictationToggleRecoveryTests.swift:118:5: Expectation failed: (recorder → WhisperMeetTests.FakeDictationRecorder).isRecording → false
✘ Test "After the capture watchdog auto-finalizes a toggle dictation, the next press starts a new one" recorded an issue at DictationToggleRecoveryTests.swift:119:5: Expectation failed: (controller.status → .idle) == .listening
✘ Test run with 1 test failed after 0.446 seconds with 2 issues.
```

Passes after, full suite grew 184 → 185:

```text
✔ Test "After the capture watchdog auto-finalizes a toggle dictation, the next press starts a new one" passed after 0.018 seconds.
✔ Test run with 185 tests passed after 1.071 seconds.
```

**Gaps.** The test drives the watchdog via an injected `captureSleep` that fires only the first
armed capture; real-clock firing at the 120 s cap is not wall-clock tested (same seam F50 uses). No
runtime helper/model adapter touched.

## F38 — Toggle-mode dictation hotkey desyncs when a press-start is refused

- **Outcome:** fixed
- **Closed:** 2026-07-30 by Claude Code (Opus 4.8) / simonwang
- **Commits:** `<this commit>`

**Root cause.** In toggle mode `HotkeyMonitor.dispatch` flips `toggledOn` on every down edge and
derives start-vs-end from the result. `DictationController.handlePressStart` could refuse the start
(feature disabled / model switching, microphone busy, or a still-in-flight session returning `.busy`)
without informing the monitor, so the monitor kept believing dictation was "on". The next press then
fired an `onPressEnd` edge that no-ops (`recorder.isRecording` is false), inverting the on/off state
and swallowing one or two presses before capture actually began.

**Fix.** Added `HotkeyMonitoring.resetToggleState()` (a protocol seam; `HotkeyMonitor` clears
`toggledOn`) and made `HotkeyMonitor` injectable into `DictationController`. `handlePressStart` now
calls `hotkeyMonitor.resetToggleState()` on every refusal path (disabled/switching, mic-busy,
session `.busy`, and the defensive `default`), and `startCapture()` resets on its engine-failure
`catch`. A successful start never resets, so toggle stays latched and the next press correctly stops.
The reset is a harmless no-op in hold mode (which never reads `toggledOn`). This is the right layer:
the controller owns the accept/refuse decision, so it must own telling the monitor when a start did
not take. Shared headless test fakes were extracted to `DictationTestSupport.swift`.

**Evidence.**

The regression fails before the fix (toggle reset on the mic-busy refusal neutralized) — the second
press fires a no-op end edge, so capture never starts:

```text
✘ Test "A refused toggle-mode start does not invert the hotkey; the next press still starts capture" recorded an issue at DictationToggleRecoveryTests.swift:55:5: Expectation failed: (recorder → WhisperMeetTests.FakeDictationRecorder).isRecording → false
✘ Test "A refused toggle-mode start does not invert the hotkey; the next press still starts capture" recorded an issue at DictationToggleRecoveryTests.swift:56:5: Expectation failed: (controller.status → .disabled) == .listening
✘ Test run with 1 test failed after 0.325 seconds with 2 issues.
```

It passes with the fix restored:

```text
✔ Test "A refused toggle-mode start does not invert the hotkey; the next press still starts capture" passed after 0.052 seconds.
```

Build clean and the full suite grew by the new test (183 → 184):

```text
Build complete! (3.62s)
✔ Test run with 184 tests passed after 1.077 seconds.
```

**Review.** Adversarially reviewed (independent subagent): confirmed the success path leaves toggle
latched, the `.busy` reset does not drop an in-flight transcript, `toggledOn` is genuinely
main-thread-only (CGEventTap source is on the main run loop), and the red→green is legitimate. The
review surfaced a distinct, related desync — the F50 watchdog auto-finalize also leaves `toggledOn`
latched — filed as **F78** (out of F38's stated scope).

**Gaps.** The `default:` reset in `handlePressStart` is unreachable today (`DictationSession.handle`
returns only `.startCapture` or `.busy` for `.startPressed`); kept as defensive. No runtime
helper/model adapter touched, so no real-model run applies.

## F50 — Hold-mode dictation has no capture cap or stuck-listen watchdog

- **Outcome:** fixed
- **Closed:** 2026-07-30 by Claude Code (Opus 4.8) / simonwang
- **Commits:** `af8ddbd` (claim), `e8a0692` (fix)

**Root cause.** Two independent ways for hold-mode dictation to wedge in `.listening` with the mic
hot. (1) `DictationController` armed no timeout on `.listening`; capture ended only on a matching
`handlePressEnd`, so a dropped release edge left it listening forever while `MicDictationRecorder`
appended every chunk to an unbounded `samples` array (~64 KB/s at 16 kHz Float32). (2) On
`.tapDisabledByTimeout`/`.tapDisabledByUserInput`, `HotkeyMonitor` re-enabled the tap but dropped
the events during the disabled window; the modifier path self-heals from absolute flag state, but
the keyDown/keyUp path used for F-keys (an explicitly recommended trigger) did not — a missed key-up
left `keyDown = true` and every subsequent press was swallowed by the autorepeat guard.

**Fix.** Added `DictationCaptureWatchdog` (armed on `.listening`, cancelled on finalize/disable) that
finalizes the session after the maximum capture duration, so a missed release self-recovers to idle.
Backed it with a hard-capped `BoundedAudioSampleBuffer` (`WhisperCore`, pure/`Sendable`) as an
independent backstop against unbounded queue growth if the main actor can't fire the watchdog in
time. `HotkeyMonitor.recoverFromDisabledTap()` resynchronizes `keyDown` from live hardware key state
(`CGEventSource.keyState`) on tap re-enable. Introduced injection seams (`DictationRecording` /
`DictationOverlayPresenting` protocols, injectable `logStore`/timeout/sleep, `activateOnInit`) so the
recovery paths are testable headlessly without mic/Accessibility hardware.

**Evidence.**

The two behavioral regressions fail with the fix neutralized (watchdog `arm()` and the key-state
resync temporarily disabled), reproducing the exact wedge — controller stuck in `.listening` with
the recorder still hot, and the F-key press swallowed after a missed release:

```text
✘ Test "A missed dictation release stops recording and recovers the controller to idle" recorded an issue at DictationControllerWatchdogTests.swift:88:5: Expectation failed: (recorder.stopCount → 0) == 1
✘ Test "A missed dictation release stops recording and recovers the controller to idle" recorded an issue at DictationControllerWatchdogTests.swift:89:5: Expectation failed: !((recorder → ...FakeDictationRecorder).isRecording → true → true)
✘ Test "A missed dictation release stops recording and recovers the controller to idle" recorded an issue at DictationControllerWatchdogTests.swift:90:5: Expectation failed: (controller.status → .listening) == .idle
✘ Test "A disabled event tap resynchronizes a missed F-key release" recorded an issue at HotkeyMonitorRecoveryTests.swift:36:5: Expectation failed: (presses.value → 1) == 2
✘ Test run with 2 tests failed after 0.025 seconds with 4 issues.
```

They pass with the fix restored:

```text
✔ Test "A missed dictation release stops recording and recovers the controller to idle" passed after 0.007 seconds.
✔ Test "A disabled event tap resynchronizes a missed F-key release" passed after 0.025 seconds.
✔ Test run with 2 tests passed after 0.025 seconds.
```

The full quality gate (build + both suites) passed:

```text
Build complete! (0.42s)
✔ Test run with 183 tests passed after 1.075 seconds.
```

**Gaps.** The watchdog's real-clock firing at the 120 s ceiling is proven only with an injected
instant `sleep` (unit-verified in `watchdogFinalizesStuckCapture` and the controller integration
test), not by a 120 s wall-clock hold on hardware. No model runtime/adapter was touched, so no
real-model run applies.

## F48 — `AudioCaptureEngine.stop()` could wedge the engine after a finalization failure

- **Outcome:** fixed
- **Closed:** 2026-07-30 by Codex / root
- **Commits:** `69def10`, `9a9731a`

**Root cause.** `AudioCaptureEngine.stop()` registered `defer { reset() }` only after both raw-track
writers finished. If either writer threw while closing its file handle, `stop()` exited before
resetting the active stream. Every later `start()` therefore hit the already-active guard and
returned without starting capture or installing health/level callbacks, while the app could still
show a recording state.

**Fix.** Registered reset immediately after `stop()` validates the active capture session, so every
exit path releases the stream. A track-finalization error now also invokes the existing best-effort
partial-track preservation path before propagating the original error. Added a headless
`WhisperMeetTests` target and a narrow injected capture seam: the regression makes track
finalization throw, proves preservation runs, then proves a subsequent `start()` proceeds and
delivers both callbacks without accessing microphone/screen hardware or user data. Updated
`CLAUDE.md` to document that test boundary.

**Evidence.**

The regression failed before the lifecycle fix:

```text
◇ Test "A failed stop releases the capture session and preserves partial tracks" started.
✘ Expectation failed: expected error of type AudioCaptureError,
  but "finishingTrack" of type ExpectedFailure was thrown instead
✘ Expectation failed: (stopCount → 2) == 1
✘ Expectation failed: preservedPartialTracks
✘ Test run with 1 test failed after 0.001 seconds with 3 issues.
```

It passed after the fix and after the review-strengthened restart/callback assertions:

```text
Build complete! (1.11s)
◇ Test "A failed stop releases the capture session and preserves partial tracks" started.
✔ Test "A failed stop releases the capture session and preserves partial tracks" passed after 0.001 seconds.
✔ Test run with 1 test passed after 0.001 seconds.
```

The final repository quality gate passed:

```text
[1/4] Checking the candidate diff for whitespace errors
[2/4] Running the complete test suite
✔ Test run with 179 tests passed after 1.058 seconds.
[3/4] Building production code with warnings as errors
Build complete! (12.39s)
[4/4] Packaging and signing WhisperMeet.app
Build complete! (11.15s)
.build/WhisperMeet.app: replacing existing signature
/Users/simonwang/Documents/Whisper/.build/WhisperMeet.app
Quality check passed.
```

Two-axis review initially found an outdated Core-only testing rule and incomplete restart coverage.
After the documentation and test corrections, both reviewers reported no remaining standards or
F48/spec findings.

**Gaps.** No live microphone/screen recording was started: the failure requires a writer close
error, which the injected test reproduces deterministically without risking a user's recording.
No model run was applicable because F48 does not touch a model adapter or runtime helper. The first
sandboxed test attempt could not compile because Swift's module cache was outside the writable
workspace; the approved rerun used a writable temporary compiler cache and produced the red/green
results above.

---

## F29 — The benchmark table in `CHANGELOG.md` could not be reproduced from the repo

- **Outcome:** fixed
- **Closed:** 2026-07-30 by Claude Code
- **Commits:** `c2c141c`

**Root cause.** The two-engine table published in the F24 entry was produced by a driver written in
a session scratchpad and never committed. Nothing in the repo could re-run or falsify it — the same
claim-without-artifact pattern that let F24 itself hide for so long. `Scripts/bench/benchmark.py`
looks like the relevant tool but is not: it loads candidate models with its own loaders to compare
engine families, and never speaks to the shipped helper subprocesses.

**Fix.** Added `Scripts/bench/dictation-ab.py`. It spawns both **production** helpers with the exact
argv `WarmWhisperDictationEngine` / `WarmQwenDictationEngine` use, including the Qwen offline
environment, and speaks the real `{"wavPath", "language", "initialPrompt"}` wire protocol. That is
the distinction that matters: a model-level benchmark cannot see F24, but this script fails loudly
on it. The `CHANGELOG.md` entry now cites the command and states which numbers are deterministic.

**Evidence.**

The script caught a real stale-helper condition on its first run — the installed Whisper helper
still predated the F24 fix, because the app syncs only the selected engine's helper and Qwen was
selected (that is F25, reproduced live):

```text
== turbo ==
turbo: helper never reported ready.
Detected language: English
```

After syncing the installed helper from the app bundle the way the app itself does (`80e86bdaf487` →
`a1d671e3e6da`), the full comparison ran:

```text
| engine | cold start | warm per clip | en | zh | code-switch |
|---|---|---|---|---|---|
| Qwen3-ASR 1.7B | 2.2 s | 0.31 s | 0.000 | 0.000 | 0.000 |
| Whisper Turbo | 9.5 s | 1.39 s | 0.025 | 0.049 | 0.000 |
```

Compared against the originally published table (2.8 s / 8.6 s cold, 0.36 s / 1.43 s warm): the
**error rates reproduced exactly**, and latency moved about 15 %. The changelog now says so rather
than implying the timings are fixed.

Suite unaffected and still green:

```text
✔ Test run with 178 tests passed after 1.100 seconds.
```

**Gaps.** Two, both now stated in the changelog rather than hidden:

1. `Scripts/bench/clips/*.wav` are **gitignored** — only `references.json` is tracked. A fresh
   checkout must run `Scripts/bench/generate_clips.sh`, which re-synthesises the clips with macOS
   `say`. A different macOS version or voice set will produce different audio, so error rates are
   reproducible for *a given clip set*, not universally. Committing the clips would close this
   properly; it was not done here because it adds binary audio to the repo and deserves its own
   decision. **Follow-up `F110`:** the script was committed non-executable (`100644`), so a fresh
   worktree could not actually run this remedy; the executable bit was recorded and every tracked
   shell script verified `100755` — see the F110 entry above.
2. No failing-test-first evidence, because this ticket changed tooling and documentation, not
   product behaviour. The definition of done requires that test for behaviour changes; asserting one
   here would be theatre.

---

## F24 — Whisper dictation helper polluted its own JSON protocol with stdout chatter

- **Outcome:** fixed
- **Closed:** 2026-07-30 by Claude Code
- **Commits:** `64455ec`, `5975d02` (doc correction)

**Root cause.** `Scripts/whisper_dictate_server.py` passed `verbose=False` to
`mlx_whisper.transcribe`. Whisper documents `False` as *"minimal details"*, and the library guards
its prints with `if verbose is not None` — so `False` still writes `Detected language: X` to
**stdout**, which is the wire carrying this helper's newline-delimited JSON protocol. Verified
against the live openai/whisper source per `AGENTS.md` and against the installed
`mlx_whisper/transcribe.py:175`.

Auto-detect is the default dictation language, so this fired on warm-up *and* on every automatic
request. `WarmWhisperDictationEngine.ensureRunning` read the chatter line instead of
`{"ready": true}`, failed both decodes, and threw `"Dictation helper failed to start."`
`FallbackDictationEngine` then silently dropped to the batch Whisper CLI. **Whisper Turbo — the
default dictation engine — had never actually used its warm path.** Text still came out, which is
why it went unnoticed for so long. Qwen was never affected; its helper only writes JSON.

**Fix.** Two layers, because either alone leaves the failure class open:
1. The helper passes `verbose=None`, the only value Whisper treats as silent.
2. `WarmWhisperDictationEngine.readLine` skips stdout lines that are not JSON objects, recording
   them as diagnostics. The skip happens inside the watchdog window on purpose, so chatter cannot
   buy a stalled helper extra time. Without this, one stray line desyncs the stream permanently —
   every later response answers the previous request.

**Evidence.**

Raw stdout captured from the *installed* runtime before the fix:

```text
--- raw stdout lines during warm-up ---
  [0] 'Detected language: English\n'
  [1] '{"ready": true}\n'
--- request with language=null (app default) ---
  [0] 0.84s 'Detected language: English\n'
  [1] 1.56s '{"text": "Can you send me the quarterly report by Friday afternoon?", ...}'
```

New tests failing before the fix:

```text
✘ Test "Whisper dictation helper keeps stdout pure JSON when the model auto-detects language"
  ↳ non-JSON line on the wire: Detected language: English
  ↳ Expectation failed: (lines.count → 4) == 2
✘ Test run with 1 test failed after 0.032 seconds with 4 issues.
```

Passing after:

```text
✔ Test "Helper chatter on stdout is skipped instead of being read as a protocol message" passed
✔ Test "Whisper dictation helper keeps stdout pure JSON when the model auto-detects language" passed
✔ Test run with 178 tests passed after 1.095 seconds.
```

Real installed models, all ten `Scripts/bench/clips`, `language: null` — the comparison that could
not run before because Turbo never reached readiness:

```text
qwen3-asr-1.7b-8bit    cold-start   2.8s | warm/clip 0.36s | en 0.000 zh 0.000 cs 0.000
turbo                  cold-start   8.6s | warm/clip 1.43s | en 0.025 zh 0.049 cs 0.000
```

Release build, packaging, and install:

```text
Build complete! (10.82s)          # swift build -c release -Xswiftc -warnings-as-errors
/Applications/WhisperMeet.app: valid on disk
/Applications/WhisperMeet.app: satisfies its Designated Requirement
whisper_dictate_server.py  app=a1d671e3e6da repo=a1d671e3e6da
```

**Gaps.** Turbo's non-zero error rates are mostly formatting rather than misrecognition (`ten`→`10`,
`三点`→`3点`); the single true error was `纪要`→`记要`. The corpus is small and synthetic, so treat the
table as a smoke test of the wire path, not a general accuracy claim — the real microphone
comparison is filed as F27. The installed `Runtime/whisper_dictate_server.py` was still the pre-fix
copy after install because only the selected engine's helper is synced; filed as F25.

---

*Log created 2026-07-30.*
