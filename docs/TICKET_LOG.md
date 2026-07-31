# Ticket log

Append-only record of every ticket closed. Newest first. Open work lives in
[`TICKETS.md`](TICKETS.md).

**Write real evidence, not intent.** Paste actual command output. "Tests pass" is not a log entry;
`✔ Test run with 178 tests passed` is. If a fix could not be verified the usual way, say exactly
what was skipped and why — an honest gap is useful, a glossed one is a trap for the next agent.

Never edit or delete an existing entry. If an entry turns out to be wrong, append a new one that
corrects it and say which entry it supersedes.

## Entry template

```markdown
## F<n> — <summary>

- **Outcome:** fixed | wontfix | invalid | duplicate
- **Closed:** YYYY-MM-DD by <agent/session>
- **Commits:** `<sha>`

**Root cause.** Why it happened, not just what changed.

**Fix.** What changed, and why that is the right layer to change.

**Evidence.**

​```text
<real command output — failing test before, passing after, build, real-model run>
​```

**Gaps.** Anything not verified, and why. Write "none" only if that is true.
```

---

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
   decision.
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
