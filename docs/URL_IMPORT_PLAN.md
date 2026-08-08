# Plan — Import audio from a link (YouTube first-class) and transcribe it

- **Status:** proposed, not started. No code written.
- **Proposed ticket:** `F175` (next free — `F174` is the highest ID in `git log` and `CHANGELOG.md`;
  the board and log are gitignored and absent from this checkout, so re-check
  `docs/TICKETS.md` "Next free ID" locally before claiming).
- **Area:** meetings · transcription · privacy · build
### Decisions taken with the user (2026-08-08)

| Decision | Choice |
|---|---|
| How a link import is marked | Typed `source` field on `MeetingRecord` **plus** an auto-applied `YouTube` tag |
| Where `yt-dlp` comes from | Installed into the existing Whisper venv by `setup-local-whisper.sh` |
| Accepted URLs | Any yt-dlp-supported URL; YouTube first-class |
| Captions | Always transcribe locally; the publisher's captions are kept only as a comparison reference |
| Downloaded format | 16 kHz mono 16-bit **WAV** — keeps per-segment re-run working; ~115 MB/hour |
| Playlist / channel URLs | Refused in v1; `--no-playlist` always |
| Long videos | Warn **and require explicit confirmation** above the threshold; never hard-capped |
| `docs/PRODUCT_SPEC.md` | **Left untouched** — see [Spec tension](#spec-tension-recorded-not-resolved) |

## What this adds

Paste a link → the app probes it, shows what it found (title, channel, duration, size) → downloads
just the audio into the meeting's own recording folder → the **existing** transcription pipeline runs
unchanged → the meeting appears in the library like any other, carrying a durable record of where it
came from.

## Why it is small

The app already does almost all of this. `AppModel.importRecording(from:title:)`
(`Sources/WhisperMeet/AppModel.swift:1104`) copies an arbitrary audio/video file into the library,
measures its duration, upserts a `MeetingRecord`, and auto-starts transcription. The pipeline behind
it — queue, engine selection, progress, failure classification, playback, export, summaries — is
format-agnostic and already serves imported files.

So this feature is **a downloader plus a provenance field**, not a new pipeline. The plan's job is
mostly to avoid the traps that a naive "download to temp, call importRecording" would hit. There are
nine of them, all verified in the current tree, listed under [Traps](#traps-verified-in-the-current-tree).

---

## Layer 1 — `Sources/WhisperCore/` (pure, Foundation-only, tested)

Per the WhisperCore purity rule (`AGENTS.md`), none of this may import `URLSession` or any framework.
The download *runs* here only as a `Process` subprocess contract, exactly like
`LocalWhisperClient`/`QwenASRClient` already do.

### `MediaSource.swift` — the provenance value

```swift
public struct MediaSource: Codable, Sendable, Equatable {
    public let kind: String        // "youtube" | "web" — a STRING, not a bare enum (see Trap 4)
    public let pageURL: String
    public let host: String
    public let videoID: String?
    public let uploader: String?   // channel
    public let uploadDate: Date?
    public let fetchedAt: Date
}
```

`kind` is a `String` with typed accessors, not a `Codable` enum. An `Optional` enum property does
**not** decode leniently: `decodeIfPresent` returns `nil` for an *absent* key but **throws** for an
unknown value. A future `kind` value would therefore make the whole meetings index fail to decode on
an older build. A string with a computed `isYouTube` avoids that permanently.

Also provides `suggestedTag` — `"YouTube"` for YouTube, otherwise the host — already trimmed to
`MeetingTags.maxLength` (32).

### `MediaSourceURL.swift` — pure validation and normalization

- Accept `http`/`https` only. Reject `file:`, `data:`, `javascript:`, and anything else.
- **Reject any URL whose string begins with `-`**, and always pass `--` before the URL in the
  argument vector. The pasted URL becomes a subprocess argument; without this, a crafted string is
  a yt-dlp flag-injection vector. This gets its own test.
- Recognize YouTube hosts (`youtube.com`, `m.youtube.com`, `youtu.be`, `music.youtube.com`,
  `/shorts/`) → `kind: "youtube"`, extract the video ID.
- Detect playlist/channel URLs so the caller can act on them deliberately rather than by accident.

### `MediaDownloadClient.swift` — the yt-dlp subprocess contract

Mirrors `LocalWhisperClient` in shape, including a `commandArguments` static that is unit-tested
without running anything (`LocalWhisperClientTests` precedent).

- `MediaDownloadRuntime.findExecutable()` — `Runtime/venv/bin/yt-dlp` first, then
  `/opt/homebrew/bin`, `/usr/local/bin`, `~/.local/bin`, exactly mirroring
  `LocalWhisperRuntime.findExecutable` (`LocalWhisperClient.swift:55`).
- `probe(url:)` → `yt-dlp --dump-single-json --no-playlist -- <url>`, returning title, duration,
  uploader, upload date, `filesize_approx`, `is_live`, availability. **Probing before downloading is
  what makes the storage guard and the duration warning possible at all** (see Trap 6).
- `download(url:into:progress:)` → writes `recording.wav` (see Trap 1 and Trap 2 for why both the
  format and the basename are forced). Needs a **stall timeout** and **process-group cancellation**
  that no existing client in this repo has — see Traps 15 and 16.
- `captions(url:into:)` → `--write-subs --write-auto-subs --sub-format vtt --skip-download`.
  Best-effort; a failure here never fails the import.
- `MediaDownloadError`: `runtimeNotInstalled`, `invalidURL`, `unavailable`, `ageRestricted`,
  `liveInProgress`, `networkFailed`, `extractorStale`, `processFailed`, `cancelled`.

### `MediaDownloadProgressParser.swift`

Parses yt-dlp's `--newline` progress lines (`[download]  42.3% of 12.34MiB at 1.23MiB/s ETA 00:07`)
into a `MediaDownloadProgress`. Pure, table-tested against real output — the same shape and testing
approach as `WhisperProgressParser.swift`.

### `MediaDownloadFailureClassifier.swift`

Mirrors `TranscriptionFailureClassifier.swift`, mapping stderr signatures to an action. The one new
action that matters is **`updateDownloader`**: YouTube changes its extraction constantly and yt-dlp
goes stale on a scale of weeks. When that happens, the honest guidance is "update the downloader",
not a blind "retry" that will fail identically. This is the single largest ongoing maintenance cost
of the feature and it deserves a first-class error state rather than a generic one.

### `SubtitleParser.swift` — and the two invariant breaches it must close

WebVTT/SRT → `[TranscriptSegment]`. The app already *writes* both formats
(`TranscriptExporter.swift:232,250`), so this is the missing inverse and its red-green test is a
clean round-trip: export segments → parse → assert identical. It must also handle YouTube
auto-caption quirks: inline `<c>` timing tags, positioning cues, and the rolling-caption duplication
where every line is emitted twice with different timings (without deduping, the reference transcript
is garbage).

**Two of the product's non-negotiable invariants can be breached through this parser**, because the
second-opinion sheet's adopt action writes the secondary text straight into `meeting.segments[].text`
(`AppModel.applySecondOpinionSpan:433`). Captions are not a passive reference once that button
exists — they are a write path into the transcript. Both breaches are cheap to close, and each gets
its own test:

- **Diarization by import.** Broadcast and YouTube captions routinely embed speaker labels — `>> `,
  `JOHN:`, `[Speaker 1]`, `- `. Adopting such a span would put speaker identity into a WhisperMeet
  transcript, which `docs/PRODUCT_SPEC.md` § "Explicit limitation" forbids outright. **The parser
  strips speaker-label prefixes before a segment is ever constructed.**
- **Translation by import.** `--write-auto-subs` with no `--sub-langs` pin can return YouTube's
  auto-**translated** caption tracks. Adopting one would make the transcript a translation, breaking
  "Preserve the original spoken language … never automatic translation". **Pin `--sub-langs` to the
  video's own language from the probe, and reject any track yt-dlp reports as translated.**

Related, lower severity: the product promises English/Mandarin detection
(`docs/PRODUCT_SPEC.md:16`), while a URL box invites arbitrary-language content. The existing
`LanguageConsistency` / `languageWarning` machinery already surfaces a mismatch, so this needs no new
mechanism — but the README should not imply link import is language-agnostic.

---

## Layer 2 — `AppModel` wiring (the headlessly testable seam)

New injected seams in the `F47` style (a mutable `@Sendable` closure assigned by tests after
construction, as `AppModel.recoverInterruptedRecording` does):

```swift
var probeMediaURL:   @Sendable (String) async throws -> MediaProbe
var downloadMedia:   @Sendable (String, URL, @Sendable (MediaDownloadProgress) -> Void) async throws -> URL
var downloadCaptions:@Sendable (String, URL) async throws -> URL?
```

New method `importFromURL(_:)`, in this order:

1. **Guard, and say why.** Same preconditions as `importRecording`, but every rejection sets
   `alertMessage`. Reuse the existing `isImporting` flag rather than adding a new one — it already
   gates every relevant control in `ContentView` (`:414`, `:532`, `:1233`, `:1266`, `:1450`), so the
   new path inherits all of that with no new wiring.
2. **Validate** the URL through `MediaSourceURL`.
3. **Probe.** Refuse live streams and playlist/channel URLs up front rather than starting an
   unbounded download.
4. **Duration confirmation.** Above the threshold (2 h), an explicit confirmation step before the
   download begins — same shape as the existing cancel-recording `confirmationDialog`
   (`ContentView.swift:369`). Never a hard cap: a legitimate 4-hour conference recording stays
   possible.
5. **Storage guard**, using the probe's `filesize_approx` — the existing guard reads
   `sourceURL.resourceValues(.fileSizeKey)` (`AppModel.swift:1112`), which is meaningless for a URL
   and silently sizes the check at `0 + 500 MB`.
6. **Write `source.json` into the meeting directory before downloading** (Trap 5), so provenance
   survives a crash mid-download.
7. **Download** straight into `store.recordingDirectoryURL(for: id)` as `recording.wav` — never to a
   temp file that is then copied, which would double peak disk for a long video.
8. **Adopt.** Extract the tail of `importRecording` (duration measurement → `store.upsert` →
   `refreshRuntime` → `beginTranscription`) into a shared
   `adoptImportedRecording(id:at:title:source:)`. Both entry points call it, so there stays exactly
   one place where a meeting becomes real. The record carries `source` and the auto tag —
   **prepended, not appended**: `MeetingTags.normalized(["YouTube"] + existing)`. `normalized`
   breaks out of its loop at 12 tags (`MeetingTags.swift:26`), so an appended marker is silently
   dropped on a meeting that is already at the cap, and the sidebar only renders `tags.prefix(4)`
   (`ContentView.swift:231`), so an appended marker can also be invisible in the library list.
9. **Captions, best-effort**, parsed into `referenceSegments`. Never blocks or fails the import.
10. `beginTranscription(id:)` — **unchanged**. Do not bypass it (Trap 3).

On cancellation or failure: remove the meeting directory, mirroring the existing catch at
`AppModel.swift:1148`.

### `MeetingRecord` schema (`Sources/WhisperMeet/MeetingStore.swift:31`)

Two new fields, both `Optional` — the established pattern documented in that struct's own comments
at lines 44–75, and non-negotiable (Trap 4):

```swift
/// Where this meeting's audio came from when it was not recorded on this Mac. Optional so meeting
/// indexes written before this feature still decode (F175).
var source: MediaSource?

/// The publisher's own captions for a link-imported meeting, parsed to segments and kept purely as a
/// reference for the existing second-opinion comparison. Never the transcript itself. Optional so
/// old indexes decode (F175).
var referenceSegments: [TranscriptSegment]?
```

---

## Layer 3 — SwiftUI (thin, presentation only)

- **Entry point** — a second button in `importPanel` (`ContentView.swift:525`): "Add from a Link…",
  beside "Import Recordings…", sharing its disabled binding. **Deliberately not a toolbar item**: the
  app has no toolbar at all today (zero `.toolbar` / `ToolbarItem` across `Sources/`), so adding one
  would be a new structural surface that also collides with the existing `.searchable` field.
- **Sheet** — URL field (pre-filled from the clipboard when it holds a URL), a probe step that shows
  title · channel · duration · estimated size before committing, then Download. Follows the existing
  `.sheet` + `PreflightTestSheet` pattern.
- **Progress lives in the sheet, and the sheet stays open through the download.** This is a real
  structural constraint, not a style choice: all existing transcription progress UI is keyed by an
  existing meeting id inside `statusCard` (`ContentView.swift:2035`), which renders only once the
  record exists. During a download there is no meeting yet, and Trap 7 forbids inventing a
  `.processing` placeholder. The sheet is therefore the only correct home for download progress —
  a determinate `ProgressView(value:)` driven by `mediaDownloadProgress` — and it hands off to the
  normal per-meeting progress card the moment the meeting is adopted.
- **Badge** — in the sidebar row (`ContentView.swift:229`), a small capsule with a `link` symbol and
  the host, rendered before the tag chips, driven by `meeting.source`.
- **Detail** — a provenance line under the title with the original link, and a "Compare with the
  video's captions" action.
- **Settings** — an "Update downloader" row beside the existing runtime installers, plus its
  installed state.

### The captions comparison costs almost no new UI

`TranscriptComparison.compare(_ primary:_ secondary:)` (`Sources/WhisperCore/TranscriptComparison.swift:29`)
already takes two `[TranscriptSegment]` arrays and produces agree/diverge/non-overlapping spans, and
the second-opinion sheet already renders them with a per-span "adopt this text" action
(`AppModel.applySecondOpinionSpan`, `:433`). Parsed captions are just a second `[TranscriptSegment]`,
so they drop into that surface directly. This is why "captions as reference" is cheap and "captions
as the transcript" would not have been.

---

## Scripts and build

- **`Scripts/setup-local-whisper.sh`** — add `yt-dlp` to the staging venv. Three separate
  constraints pin exactly where and how (Traps 10–12):
  - **After** the mandatory `openai-whisper` install and its `--help` verification (lines 105–110),
    so the meetings runtime is never left unverified behind an optional dependency;
  - **Before** the shebang-rewrite heredoc (line 126), or `bin/yt-dlp`'s console-script shebang
    still points at the staging path and is a dead "bad interpreter" after the atomic swap;
  - **Inside an `if ! …; then print -u2 …; fi`**, matching the `mlx-whisper` shape at lines 118–125.
    A bare `pip install` inherits `set -euo pipefail` from line 2, so one transient PyPI failure
    would abort the entire meetings-runtime install.

  **Do not add `bin/yt-dlp` to `venv_is_complete()` or `venv_works()`** (lines 24–36). Those two
  predicates decide whether a runtime is healthy; requiring yt-dlp would make every already-working
  install look broken and trigger a rollback to a backup that also lacks it.

  FFmpeg, which yt-dlp needs for audio extraction, is already installed by this script (line 96).
  **Version pinning is a deliberate exception to house convention**: `setup-qwen-asr.sh:15` and
  `setup-local-summarizer.sh:21` use exact `==` pins with revision and sha256 gates. yt-dlp is the
  opposite kind of dependency — a pin *guarantees* eventual breakage, because its whole job is to
  track a moving target. It floats, and the ticket records that as an intentional deviation.
- **`Scripts/update-yt-dlp.sh`** — new, small: `venv/bin/python -m pip install -U yt-dlp` under the
  same `shlock` lock file. Backs the Settings button. A full venv rebuild to refresh one downloader
  would be absurd.
- **`Scripts/build-app.sh`** — add the new script to the Resources copy block (lines 20–30).

---

## Tests

**`Tests/WhisperCoreTests/`** — pure, red-green:

| Suite | Asserts |
|---|---|
| `MediaSourceURLTests` | host variants, `youtu.be`, `/shorts/`, `?t=` timestamps, playlist detection; **rejects leading-`-` flag injection**; rejects non-http schemes |
| `MediaDownloadClientTests` | argument vector contains `--` before the URL and `--no-playlist`; output template is `recording.%(ext)s` |
| `MediaDownloadProgressParserTests` | real yt-dlp `--newline` lines → fraction/ETA |
| `MediaDownloadFailureClassifierTests` | real stderr signatures → private / age-restricted / geo-blocked / live / **stale-extractor → `updateDownloader`** |
| `SubtitleParserTests` | VTT and SRT round-trip against `TranscriptExporter`; a real auto-caption fixture with rolling duplicates collapses correctly; **`>> `, `JOHN:`, `[Speaker 1]` prefixes are stripped** (no-diarization invariant); **a translated caption track is rejected** (original-language invariant) |

**`Tests/WhisperMeetTests/MediaURLImportTests.swift`** — this is where the reachability red-green
lands, per `AGENTS.md` § "Wiring an unreachable core". Over a temp `MeetingStore(rootDirectory:)`
with the seams stubbed, asserting **through `AppModel.importFromURL`**, never a direct core call:

- a stubbed download produces a `MeetingRecord` carrying `source.isYouTube`, the auto tag, and the
  probed title, and enqueues transcription;
- a throwing download leaves no orphan directory and no meeting;
- the guards refuse while recording / importing / installing, **and set `alertMessage`**.

**`Scripts/tests/`** — a script-shape test asserting yt-dlp is installed best-effort after Whisper's
verification step, following the `WhisperHelperScriptTests` / `SummarizeLocalHelperScriptTests`
precedent of testing helper scripts without the real binary.

Baseline: `swift build` and `swift test` green, with **no test-count drop**.

---

## Docs

`docs/PRODUCT_SPEC.md` is **not** edited — see [Spec tension](#spec-tension-recorded-not-resolved)
for what is recorded instead. Updated:

- `docs/ROADMAP.md` — a shipped entry;
- `docs/CHANGELOG.md` — a cycle entry;
- `README.md` — the user workflow, plus the two plain-language disclosures below;
- `docs/RECOVERY.md` — one row: a link import interrupted mid-download.

**Two disclosures, stated once and not litigated in code.** Many sites' terms prohibit downloading,
and the content is usually someone else's copyrighted work; and the fetch reaches the video's host,
so that host sees your IP address and what you asked for. The app cannot resolve either. The link
sheet carries one plain line on each, and the README repeats them. These are disclosures, not gates.

---

## Traps (verified in the current tree)

Each of these would break a naive implementation. Every line reference was re-checked against the
working tree on 2026-08-08.

**1 — Opus/WebM is the real format trap.** yt-dlp's best audio for YouTube is usually `.webm`
(Opus). Qwen sends anything outside `{wav, flac, mp3, ogg}` through `afconvert`
(`AudioTranscoder.swift:16`), and AudioToolbox has no Opus decoder — so it fails. Whisper would
survive via FFmpeg, but the meeting would be silently Whisper-only. **Force the extraction format.**

**2 — Extract to 16 kHz mono 16-bit WAV named `recording.wav`.** Two independent constraints force
this:
- `InterruptedRecordingRecovery.importedRecordingCandidate` (`:151`) matches the basename
  `recording` **exactly**; any other name means an interrupted download is unrecoverable.
- `AppModel.makeSegmentClip` (`:489`, guard at `:499`) refuses anything that is not canonical
  RIFF/WAVE, so per-segment re-run is dead on a `.m4a`/`.mp3` meeting. WAV keeps that feature
  working — and 16 kHz mono is exactly what both engines want anyway, so it is also the smallest
  correct choice (~345 MB for a 3-hour video).

  The cost: `MeetingIntegrityChecker` applies a WAV-header/duration cross-check with a 1.0 s
  tolerance, so the indexed duration **must** come from measuring the written file (`loadDuration`
  via `AVURLAsset`, `AppModel.swift:1187`), never from the probe's metadata.

**3 — Do not bypass `beginTranscription`.** `performTranscription` hard-requires a settings snapshot
(`guard … transcriptionSettings.selection(for: id)`, `AppModel.swift:1404`). Calling
`performTranscription` directly silently no-ops.

**4 — The new fields must be `Optional`, and `kind` must be a `String`.** Swift's synthesized
`init(from:)` does not consult a property's default value, so a non-optional `source` makes **every
pre-existing meeting fail to decode** — and the failure compounds: the library loads empty, and the
next `persistMeetings()` overwrites *both* `meetings.json` and `meetings.backup.json`. That is
total, unrecoverable library loss from a one-line schema mistake. The `String` `kind` closes the
matching forward-compatibility hole for unknown enum values.

**5 — Provenance must be written before the download, not after.** `importRecording` upserts only
*after* the copy completes (`:1133`). For a file copy that window is milliseconds; for a 3-hour
download it is minutes. Write a `source.json` sidecar into the meeting directory first — mirroring
`source-tracks.json` — so an interrupted download is recoverable *as a link import* rather than as
an anonymous orphan folder.

**6 — The storage guard needs the probe's size.** As written it reads `.fileSizeKey` from the source
URL (`:1112`), which for a remote URL yields `0`, degrading the check to a flat 500 MB margin.

**7 — Never model an in-flight download as `MeetingStatus.processing`.** Every `.processing` meeting
is force-reset at launch to `.recorded` with "Local transcription was interrupted"
(`AppModel.swift:1394`) — which would be a false and confusing message.

**8 — Tags alone cannot carry provenance.** `MeetingStore.setTags` replaces the array wholesale
(`:306`), so the user can delete the marker; `MeetingTags.normalized` also caps at 12 tags and 32
characters and dedupes case-insensitively. The tag is a *mirror* of `source`, which is why the
chosen design has both.

**9 — Missing `.f32` tracks and `source-tracks.json` are not corruption.** That is already the
documented state of every imported meeting (`AppModel.swift:1714`, returning `[]` at `:1742`). Do
not "fix" it for link imports.

**10 — `venv_works()` must not learn about yt-dlp.** Covered in Scripts above, repeated here because
it is the one mistake that would break *existing* installs rather than only the new feature.

**11 — Install yt-dlp before the shebang rewrite** (`setup-local-whisper.sh:126`), or the executable
is dead the moment the venv is swapped into place.

**12 — The install must be `set -e`-exempt**, inside an `if !` condition, or a transient PyPI blip
takes down the whole meetings runtime install.

**13 — Sanitize `PATH` for the subprocess. This bug already shipped once.** A GUI-launched app
inherits a bare `PATH` with no `/opt/homebrew/bin`, so yt-dlp's *own* lookup of `ffmpeg` fails even
when FFmpeg is installed — the exact shape of the shipped `F132` defect. The download client must
prepend the Homebrew paths, following the existing `makeEnvironment` precedent.

But **do not copy `makeEnvironment` wholesale**: `QwenASRClient.swift:225` sets `HF_HUB_OFFLINE=1`
and `TRANSFORMERS_OFFLINE=1` precisely to keep model runs offline. Those belong to a transcription
client, not to a downloader.

**14 — FFmpeg is not guaranteed to exist.** It is installed only by `setup-local-whisper.sh:93`, and
`AudioTranscoder.swift:9` documents that the Qwen path was built deliberately so a Qwen-only user
never needs it. Since yt-dlp lives in the Whisper venv, a Qwen-only user has neither — the feature
must detect that and offer the Whisper runtime install rather than failing obscurely.

**15 — Cancelling the download does not kill ffmpeg.** `ProcessCancellationController.cancel()`
terminates only the direct child (`LocalWhisperClient.swift:301`), and `LocalSummarizer.swift:206`
already documents surviving `afconvert`/`ffmpeg` grandchildren as a known gap. yt-dlp spawns ffmpeg
for the WAV extraction, so cancelling mid-post-process orphans it. Either kill the process group or
record the limitation explicitly — silently inheriting a known bug is the one option that is not
acceptable.

**16 — No one-shot subprocess client in this repo has a timeout.** Verified absent from
`LocalWhisperClient`, `QwenASRClient`, and `LocalSummarizer`; the only watchdog anywhere is the warm
dictation engine's off-queue `DispatchWorkItem { process.terminate() }`. A transcriber that hangs is
at least making local progress; a *network* download that stalls hangs forever on a dead socket.
This client needs a **stall timeout** — no progress line for N seconds — more than any existing one
does. It is new work, not a pattern to copy.

**17 — A menu command must be added in two places or not at all.** Not planned here (the button
lives in `importPanel`), but recorded because it is a live trap: adding an entry to
`CommandCatalog.all` without a matching case in `AppEntry.route`'s switch (`:145`, `default: break`)
produces a menu item that is visible, enabled, and silently does nothing.

**Also:** nothing in the repo exercises `Bundle.main` resource lookup, so a forgotten `build-app.sh`
copy line for `update-yt-dlp.sh` passes `swift test` and fails only in the packaged `.app`. That
needs a manual check before release, not a test.

**Also worth doing:** `DiagnosticsBundleBuilder` uses an allow-list, so the new source URL is
excluded by default — confirm that stays true, since a pasted URL is new user data that should not
leak into a diagnostics bundle.

---

## Spec tension, recorded not resolved

`docs/PRODUCT_SPEC.md` stays untouched, by decision. That leaves a real tension worth naming rather
than burying: the spec calls the Claude summary "the one optional cloud path", and this feature adds
a second outbound network class. `AGENTS.md`'s Definition of done requires that "the non-negotiable
invariants in `docs/PRODUCT_SPEC.md` are intact", so a reviewer could reasonably challenge this.

The resolution is to make the tension **visible in the ticket rather than invisible in the code**:
the `F175` log entry records, under **Gaps**, that the spec was deliberately not amended and that
the fetch is inbound-only with nothing uploaded. No code behaves differently either way; what
changes is whether the next person discovers this by reading a note or by being surprised.

The user-facing disclosure still ships — the link sheet and the README both say plainly that the
request reaches the video's host, and that you are responsible for having the right to the content
you paste.

---

## Remaining assumptions

Everything material has been decided. These three are proceeding as stated unless overridden:

| # | Assumption | Reason |
|---|---|---|
| 1 | The meeting title is the video title verbatim, editable afterwards like any other | Matches the import path's fallback-to-filename behaviour (`AppModel.swift:1128`) |
| 2 | The downloaded audio is kept permanently | "The recording is the source of truth" — and playback, re-transcribe, and segment re-run all read it |
| 3 | Cookies / sign-in for private or age-restricted videos is out of scope for v1 | The failure is classified and explained rather than worked around |
| 4 | `createdAt` is the **download** time, not the video's publish date | Consistent with file import, and it keeps one meaning for "when" in the sidebar. The publish date is still kept, on `source.uploadDate` |
| 5 | A failed or cancelled download deletes its partial directory | Mirrors `importRecording`'s failure path (`AppModel.swift:1150`); no resume in v1 |
| 6 | No auto-summarize after a link import | Matches the recording and file-import paths, and summaries stay an explicit press |

### One question the plan does not settle

Should the whole feature sit behind an **off-by-default Settings toggle**? Every prior
boundary-crossing capability in this app is opt-in — Qwen is an explicit Apple-silicon opt-in, Claude
summaries require a saved key plus a confirmed press. A toggle would make the network path opt-in
rather than ambient, which is the strongest available answer to the spec tension below without
editing the spec at all.

It is not in the plan because it was not among the decisions taken, and it is cheap to add later —
one `@AppStorage` flag gating the button. Worth a decision before commit 5 (the SwiftUI surfaces),
not before commit 1.

## Rough shape of the work

Six commits, all referencing `F175`:

1. Pure WhisperCore types + their tests (`MediaSource`, `MediaSourceURL`, progress parser, failure
   classifier, subtitle parser)
2. The two `MeetingRecord` fields — the one genuinely dangerous commit (Trap 4)
3. `AppModel.importFromURL` + the extracted `adoptImportedRecording` seam + the red-green wiring test
4. `setup-local-whisper.sh`, `update-yt-dlp.sh`, `build-app.sh`
5. SwiftUI: link button, sheet, progress, sidebar badge, provenance line, Settings row
6. Docs

Commits 1–3 carry the risk; 4–6 are additive. `swift build` and `swift test` stay green after each,
with no test-count drop.
