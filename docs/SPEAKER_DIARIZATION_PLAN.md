# Speaker diarization implementation plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use `superpowers:subagent-driven-development` (recommended) or `superpowers:executing-plans` to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ship optional, post-meeting, entirely local speaker-turn analysis that labels a completed transcript with anonymous per-meeting clusters, never identifies a person, and never changes the recording, the transcript, or any existing output path.

**Architecture:** A pinned native `sherpa-onnx` binary runs as a subprocess over a 16 kHz mono copy of the canonical recording. Its anonymous turns are validated by Foundation-only code in `WhisperCore`, stored in a strict versioned `Recordings/<uuid>/diarization.json` sidecar, and reconciled into a **display-only** overlay at render time. `TranscriptSegment.speaker` is never populated; `meetings.json` never changes.

**Tech Stack:** Swift 6 (language mode 5, swift-tools 6.2), SwiftPM, swift-testing, SwiftUI, zsh installer scripts, Python 3 for the benchmark harness. **One third-party dependency: FluidAudio, WhisperMeet target only.**

**Spec:** [`SPEAKER_DIARIZATION_PRD.md`](SPEAKER_DIARIZATION_PRD.md) and [`DIARIZATION_RUNTIME_DECISION.md`](DIARIZATION_RUNTIME_DECISION.md) (created in Task 1).

**Tickets:** F216 (Task 1), F217 (Tasks 15–17), F218 (Tasks 2–8), F219 (Tasks 7, 9–11), F220 (Tasks 12–14), F221 (Task 17).

## Global constraints

- **WhisperCore purity.** Every file in `Sources/WhisperCore/` imports only `Foundation`. No `CryptoKit`, `AVFoundation`, `AppKit`, `SwiftUI`, `CoreML`, or any third-party runtime. The single sanctioned exception (`Darwin` in `WarmWhisperDictationEngine.swift`) is not extended.
- **One third-party SwiftPM dependency, authorised 2026-09-13.** FluidAudio, pinned `exact: "0.15.7"`, on the **WhisperMeet target only**; `WhisperCore` keeps its Foundation-only rule. The original constraint was "no new SwiftPM dependency"; the product owner lifted it after sherpa-onnx failed real-meeting validation and FluidAudio passed the same test. The manifest moved to swift-tools 6.2 solely so `traits: []` can keep FluidAudio's unrelated NemoTextProcessing Rust staticlib out of the shipped binary — verified: 0 `rustfst`, 0 `NemoTextProcessing`, 0 `flate2` symbols in the release executable. See `DIARIZATION_RUNTIME_DECISION.md` §1.
- **`TranscriptSegment.speaker` stays `nil`.** Never write a label into it. `TranscriptFormatter.isEdited` compares `transcriptText` against `TranscriptFormatter.timestamped(segments)`, so a populated `speaker` would mark every existing meeting user-edited; `speaker` is also part of `TranscriptSegment.id`, which is SwiftUI's row identity.
- **No label leaves the default paths.** `transcriptText`, `notes.md`, Copy, search, the nine existing export formats, local summaries, and the Claude request stay label-free. Only the two new labeled formats carry them.
- **No `meetings.json` schema change and no new `MeetingStatus` case.**
- **Persisted enums decode leniently or fail closed** (`AGENTS.md:425-426`).
- **Analysis makes no network call.** The runtime binary links no network framework and exports no socket symbols; both facts are asserted by tests.
- **Never identify a person.** No UI string may say "recognized", "verified", "identified", or imply a channel maps to a person. `AccessibilityPhrase.swift:4` already binds this.
- **A single-cluster result shows no labels at all.** If analysis distinguishes exactly one voice, suppress labelling entirely and say so plainly. Measured on the F217 corpus: 2 of 16 fixtures at threshold 0.30 (3 of 16 at 0.40) collapse a genuine two-person conversation into one cluster. Labelling every row "Speaker 1" is worthless for a real monologue and actively misleading for a failed separation — and it sets an alias trap, because renaming that single cluster to "Alice" then attributes the other person's words to Alice. Suppressing is strictly better in both cases.
- **Apple silicon only**, matching the existing Qwen3-ASR constraint.
- **Runtime pins** (from the F216 decision; every hash independently re-verified):
  - `sherpa-onnx` `1.13.8`, asset `sherpa-onnx-v1.13.8-osx-arm64-shared-no-tts.tar.bz2`, sha256 `91b96512c4fa1960f8a9ed5360a6c8dda53a4b5015d0590244f14086a234557a`
  - `bin/sherpa-onnx-offline-speaker-diarization` sha256 `e1170a93308867d8e343ac22a00b46b1d8e786c763c32a17caff07cf934ff66f`
  - `lib/libonnxruntime.dylib` sha256 `3567d114f7299d559993e536d605a6f46d7bc9d2542004accc80ee9bf5457f0b`
  - segmentation asset `sherpa-onnx-pyannote-segmentation-3-0.tar.bz2` sha256 `24615ee884c897d9d2ba09bb4d30da6bb1b15e685065962db5b02e76e4996488`, `model.onnx` sha256 `220ad67ca923bef2fa91f2390c786097bf305bceb5e261d4af67b38e938e1079`, `LICENSE` sha256 `14d7016ad68e7394d6e6b78d96cc2ae431c905287b89674cfdf021e79e62b8ba`
  - embedding `3dspeaker_speech_campplus_sv_zh_en_16k-common_advanced.onnx` sha256 `aa3cfc16963a10586a9393f5035d6d6b57e98d358b347f80c2a30bf4f00ceba2`
  - clustering threshold **0.40** — re-derived on the F217 corpus (F216's 0.3 was calibrated on five two-speaker clips); `num-threads=4`, never `--clustering.num-clusters`, never `model.int8.onnx`
  - The upstream release path segment `speaker-recongition-models` is **misspelled upstream**. Hard-code it; `speaker-recognition-models` returns 404.
- **Verification command** (this Mac has Command Line Tools only, so plain `swift test` fails with `no such module 'Testing'`):

```bash
FW=/Library/Developer/CommandLineTools/Library/Developer/Frameworks
LIB=/Library/Developer/CommandLineTools/Library/Developer/usr/lib
swift test --disable-sandbox --no-parallel \
  -Xswiftc -F -Xswiftc "$FW" \
  -Xlinker -rpath -Xlinker "$FW" \
  -Xlinker -rpath -Xlinker "$LIB" --filter "<swiftFunctionName>"
```

Keep the flags byte-identical between runs so SwiftPM does not rebuild. `--filter` matches the **Swift function name**, not the `@Test("…")` display string; a wrong filter matches nothing and still exits 0, so always confirm the reported test count.

## File structure

| File | Responsibility |
|---|---|
| `Sources/WhisperCore/SpeakerTurn.swift` | `SpeakerTurn`, `SpeakerTurnKind`, interval validation |
| `Sources/WhisperCore/TranscriptTimingFingerprint.swift` | Non-crypto fingerprint over segment timings |
| `Sources/WhisperCore/SpeakerOverlay.swift` | Pure turn→segment reconciliation (display only) |
| `Sources/WhisperCore/DiarizationArtifact.swift` | `DiarizationArtifactV1` envelope + strict codec |
| `Sources/WhisperCore/DiarizationOutputParser.swift` | Pure parser for the runtime's stdout/stderr grammar |
| `Sources/WhisperCore/LocalDiarizationClient.swift` | Subprocess adapter + `DiarizationRuntime` paths |
| `Sources/WhisperCore/AccessibilityPhrase.swift` | *(modify)* VoiceOver phrase for an inferred label |
| `Sources/WhisperCore/TranscriptExporter.swift` | *(modify)* two labeled formats, excluded from the standard set |
| `Sources/WhisperMeet/DiarizationArtifactStore.swift` | Sidecar I/O, atomic write, quarantine, staleness, hashing |
| `Sources/WhisperMeet/AppModel.swift` | *(modify)* seam, guards, cancel, install, per-meeting state |
| `Sources/WhisperMeet/ContentView.swift` | *(modify)* menu entry, sheet, row labels, legend, rename, export |
| `Scripts/setup-speaker-diarization.sh` | Pinned installer: download, verify, prune, activate, reclaim |
| `Resources/THIRD-PARTY-NOTICES.txt` | Attribution required by Apache-2.0 / MIT / BSD-2-Clause |
| `Scripts/bench/diarization/generate_corpus.py` | Manifest-driven synthetic corpus from macOS voices |
| `Scripts/bench/diarization/score_diarization.py` | DER/JER scorer with Hungarian mapping and collar |
| `Scripts/bench/diarization/manifest.json` | Fixture definitions, ground truth, hashes |

---

## Task 1: F216 decision record and policy amendment

Docs only. This must land **before** any runtime code, because `AGENTS.md:142-143` makes "no diarization" a definition-of-done gate and F216's verification line requires the policy decision recorded first.

**Files:**
- Create: `docs/DIARIZATION_RUNTIME_DECISION.md`
- Modify: `docs/PRODUCT_SPEC.md:68-72`, `README.md:23-25`, `README.md:231-236`, `docs/ROADMAP.md:3-6`, `docs/ROADMAP.md:90-93`, `AGENTS.md:142-143`, `docs/README.md`, `docs/SPEAKER_DIARIZATION_PRD.md`
- Modify: `docs/TICKETS.md` (claim F216–F221)

- [ ] **Step 1: Write the decision record**

Create `docs/DIARIZATION_RUNTIME_DECISION.md` from the F216 evidence: the selected runtime and every pin, the licence/attribution ledger, why not FluidAudio, the offline evidence (symbol inspection + sandbox run), the measured accuracy/RTF/RSS table, the installer contract, the helper contract (argv, stdout grammar, exit codes), and the residual risks. Every hash must be the real one from Global Constraints.

- [ ] **Step 2: Amend `docs/PRODUCT_SPEC.md`**

Replace the `## Explicit limitation` body (lines 70-72) with the PRD's approved amendment text. Keep the heading. The new text must state: explicit, post-meeting, entirely local; anonymous per-meeting clusters; user rename for that meeting only; never infer/enroll/verify identity, match across meetings, or infer role/gender/demographics/sentiment; never send audio, embeddings, turns, or aliases to a service; recording and original transcript unchanged; default views, notes, ordinary exports, search, and both summary paths exclude labels; labeled export is a separate affirmative action.

- [ ] **Step 3: Amend `README.md`**

Line 23-25: the "two things the app deliberately will not do" sentence must stop claiming the app does not label speakers, while keeping the `#speaker-limitation` anchor valid. Keep the heading `## Speaker limitation` at line 231 **unchanged** — the in-page anchor depends on it — and rewrite its body to describe the optional local feature and its limits.

- [ ] **Step 4: Amend `docs/ROADMAP.md`**

Line 3-6: replace "no speaker diarization" in the invariant list with the bounded allowance. Line 90-93: move the "Any cloud/on-device speaker diarization surfaced as identified speakers" entry — cloud diarization and *identified* speakers stay deferred; anonymous local turns no longer are. Leave line 62-64 (a historical Round 2 entry) alone.

- [ ] **Step 5: Amend `AGENTS.md:142-143`**

Replace "no diarization" in the definition-of-done invariant list with the bounded wording, so the gate stays meaningful rather than contradicting shipped code.

- [ ] **Step 6: Keep the import-side invariant intact**

Do **not** change `Sources/WhisperCore/SubtitleParser.swift`. Fetched captions still strip `>>`, `JOHN:`, `[Speaker 1]`. Add one sentence to the amended PRODUCT_SPEC section saying so explicitly: *analysis produces labels locally; imported third-party captions still never carry speaker claims into a transcript.*

- [ ] **Step 7: Update `docs/README.md` and the PRD**

Change the `SPEAKER_DIARIZATION_PRD.md` row so it no longer says the policy is unapproved; add a row for `DIARIZATION_RUNTIME_DECISION.md` and one for this plan, matching the existing row format. In the PRD, mark the FluidAudio-first recommendation superseded, pointing at the decision record.

- [ ] **Step 8: Claim the tickets**

In `docs/TICKETS.md`, set F216–F221 to `in-progress` with an owner. (The board is gitignored/local-only; keep it in step with the code commit, which must reference the ticket ID.)

- [ ] **Step 9: Verify the docs build and commit**

Run: `python3 Scripts/generate-tickets-dashboard.py --check` and confirm it passes. Then:

```bash
git add -A
git commit -m "docs(diarization): approve the bounded local speaker-turn policy and pin the runtime (F216)"
```

---

## Task 2: `SpeakerTurn` and interval validation

**Files:**
- Create: `Sources/WhisperCore/SpeakerTurn.swift`
- Test: `Tests/WhisperCoreTests/SpeakerTurnTests.swift`

**Interfaces:**
- Produces: `SpeakerTurn`, `SpeakerTurnKind`, `SpeakerTurnValidationError`, `SpeakerTurns.validate(_:durationSeconds:)`

- [ ] **Step 1: Write the failing tests**

```swift
import Foundation
import Testing
@testable import WhisperCore

// F218 — a diarization result is untrusted input. Every malformed interval must be rejected
// before it can reach storage or the UI, and the canonical fixture must survive intact.

private func turn(_ start: Double, _ end: Double, _ cluster: Int = 0,
                  _ kind: SpeakerTurnKind = .speech) -> SpeakerTurn {
    SpeakerTurn(startSeconds: start, endSeconds: end, clusterID: cluster, kind: kind)
}

@Test("A canonical ordered turn list validates unchanged")
func validationAcceptsCanonicalTurns() throws {
    let turns = [turn(0, 5), turn(5, 10, 1), turn(10, 12)]
    let validated = try SpeakerTurns.validate(turns, durationSeconds: 12)
    #expect(validated == turns)
}

@Test("Non-finite bounds are rejected")
func validationRejectsNonFinite() {
    #expect(throws: SpeakerTurnValidationError.notFinite) {
        try SpeakerTurns.validate([turn(0, .nan)], durationSeconds: 10)
    }
    #expect(throws: SpeakerTurnValidationError.notFinite) {
        try SpeakerTurns.validate([turn(.infinity, 1)], durationSeconds: 10)
    }
}

@Test("Negative, reversed, and zero-length intervals are rejected")
func validationRejectsImpossibleIntervals() {
    #expect(throws: SpeakerTurnValidationError.negativeStart) {
        try SpeakerTurns.validate([turn(-1, 5)], durationSeconds: 10)
    }
    #expect(throws: SpeakerTurnValidationError.reversedInterval) {
        try SpeakerTurns.validate([turn(5, 5)], durationSeconds: 10)
    }
    #expect(throws: SpeakerTurnValidationError.reversedInterval) {
        try SpeakerTurns.validate([turn(6, 5)], durationSeconds: 10)
    }
}

@Test("A turn beyond the recording duration is rejected")
func validationRejectsOutOfRange() {
    #expect(throws: SpeakerTurnValidationError.exceedsDuration) {
        try SpeakerTurns.validate([turn(0, 11)], durationSeconds: 10)
    }
}

@Test("A negative cluster id is rejected")
func validationRejectsNegativeCluster() {
    #expect(throws: SpeakerTurnValidationError.negativeCluster) {
        try SpeakerTurns.validate([turn(0, 5, -1)], durationSeconds: 10)
    }
}

@Test("Unsorted turns are rejected rather than silently reordered")
func validationRejectsUnsortedTurns() {
    #expect(throws: SpeakerTurnValidationError.unsortedTurns) {
        try SpeakerTurns.validate([turn(5, 10), turn(0, 4)], durationSeconds: 10)
    }
}

@Test("An absurd turn count is rejected so a malformed file cannot exhaust memory")
func validationRejectsTooManyTurns() {
    let many = (0..<(SpeakerTurns.maximumTurnCount + 1)).map { index in
        turn(Double(index) * 0.001, Double(index) * 0.001 + 0.0005)
    }
    #expect(throws: SpeakerTurnValidationError.tooManyTurns) {
        try SpeakerTurns.validate(many, durationSeconds: 100_000)
    }
}

@Test("An unknown persisted kind decodes leniently as uncertain, never as confident speech")
func unknownKindDecodesAsUncertain() throws {
    let json = Data(#"{"startSeconds":0,"endSeconds":1,"clusterID":0,"kind":"telepathy"}"#.utf8)
    let decoded = try JSONDecoder().decode(SpeakerTurn.self, from: json)
    #expect(decoded.kind == .uncertain)
}

@Test("A duration tolerance absorbs floating-point drift at the very end of a recording")
func validationToleratesEndOfFileRounding() throws {
    // The runtime reports its own duration to 3 dp; a turn may end a hair past ours.
    let turns = [turn(0, 12.0004)]
    let validated = try SpeakerTurns.validate(turns, durationSeconds: 12)
    #expect(validated.count == 1)
}
```

- [ ] **Step 2: Run the tests and verify they fail**

Run the verification command with `--filter "validationAccepts|validationRejects|unknownKindDecodes|validationTolerates"`.
Expected: FAIL — `cannot find 'SpeakerTurns' in scope`.

- [ ] **Step 3: Write the implementation**

```swift
import Foundation

/// What a diarization interval claims. Anonymous by construction — a kind never names a person,
/// and `uncertain`/`overlap` exist so ambiguity can be shown rather than resolved silently (F218).
public enum SpeakerTurnKind: String, Codable, Sendable, Equatable {
    /// One voice cluster is active.
    case speech
    /// More than one voice may be active; no single label may be shown.
    case overlap
    /// The runtime produced an interval it could not attribute with confidence.
    case uncertain

    /// Lenient decoding: a kind written by a newer build must not fail the whole artifact, and an
    /// unrecognized claim must degrade to "uncertain" rather than to confident speech
    /// (`AGENTS.md` — enums reachable from a persisted type decode leniently or fail closed).
    public init(from decoder: Decoder) throws {
        let value = try decoder.singleValueContainer().decode(String.self)
        self = SpeakerTurnKind(rawValue: value) ?? .uncertain
    }
}

/// One anonymous voice-cluster interval. `clusterID` is dense and local to a single result — it is
/// never a person, never stable across reruns, and never compared across meetings.
public struct SpeakerTurn: Codable, Sendable, Equatable {
    public let startSeconds: TimeInterval
    public let endSeconds: TimeInterval
    public let clusterID: Int
    public let kind: SpeakerTurnKind

    public init(startSeconds: TimeInterval, endSeconds: TimeInterval, clusterID: Int, kind: SpeakerTurnKind) {
        self.startSeconds = startSeconds
        self.endSeconds = endSeconds
        self.clusterID = clusterID
        self.kind = kind
    }
}

public enum SpeakerTurnValidationError: Error, Sendable, Equatable {
    case notFinite
    case negativeStart
    case reversedInterval
    case exceedsDuration
    case negativeCluster
    case unsortedTurns
    case tooManyTurns
}

/// Validation for untrusted diarization output — a model result, a file written by another build,
/// or a corrupted sidecar. Nothing reaches storage or the UI without passing through here (F218).
public enum SpeakerTurns {
    /// A 12-hour meeting at one turn per second is 43 200; 200 000 is far above any real result and
    /// far below anything that could exhaust memory.
    public static let maximumTurnCount = 200_000

    /// The runtime reports times to three decimal places against its own duration probe, which can
    /// round a hair past ours. Tolerate that, not a real out-of-range claim.
    public static let durationTolerance: TimeInterval = 0.05

    /// Rejects any interval that is impossible, out of range, or out of order. Turns are never
    /// silently repaired or reordered: a result we cannot trust is one we do not show.
    public static func validate(
        _ turns: [SpeakerTurn],
        durationSeconds: TimeInterval
    ) throws -> [SpeakerTurn] {
        guard turns.count <= maximumTurnCount else { throw SpeakerTurnValidationError.tooManyTurns }
        let limit = max(0, durationSeconds) + durationTolerance
        var previousStart = -Double.greatestFiniteMagnitude
        for turn in turns {
            guard turn.startSeconds.isFinite, turn.endSeconds.isFinite else {
                throw SpeakerTurnValidationError.notFinite
            }
            guard turn.startSeconds >= 0 else { throw SpeakerTurnValidationError.negativeStart }
            guard turn.endSeconds > turn.startSeconds else {
                throw SpeakerTurnValidationError.reversedInterval
            }
            guard turn.endSeconds <= limit else { throw SpeakerTurnValidationError.exceedsDuration }
            guard turn.clusterID >= 0 else { throw SpeakerTurnValidationError.negativeCluster }
            guard turn.startSeconds >= previousStart else {
                throw SpeakerTurnValidationError.unsortedTurns
            }
            previousStart = turn.startSeconds
        }
        return turns
    }
}
```

- [ ] **Step 4: Run the tests and verify they pass**

Expected: PASS, 9 tests.

- [ ] **Step 5: Commit**

```bash
git add Sources/WhisperCore/SpeakerTurn.swift Tests/WhisperCoreTests/SpeakerTurnTests.swift
git commit -m "feat(diarization): add anonymous speaker-turn value type and strict validation (F218)"
```

---

## Task 3: Transcript timing fingerprint

A changed transcript timing must invalidate a cached overlay without rewriting turns. CryptoKit is barred from `WhisperCore`, and the threat model is accident rather than forgery, so this is a stable non-crypto fingerprint — the same argument `docs/LIBRARY_INDEX_TRANSACTION_DESIGN.md:973` makes for `StoreFingerprint`.

**Files:**
- Create: `Sources/WhisperCore/TranscriptTimingFingerprint.swift`
- Test: `Tests/WhisperCoreTests/TranscriptTimingFingerprintTests.swift`

**Interfaces:**
- Produces: `TranscriptTimingFingerprint.compute(_ segments: [TranscriptSegment]) -> String`

- [ ] **Step 1: Write the failing tests**

```swift
import Foundation
import Testing
@testable import WhisperCore

// F218 — the overlay is cached against the timings it was computed from. The fingerprint must
// change when timings change and stay put when only the text changes, or a stale overlay survives.

private func seg(_ start: Double?, _ end: Double?, _ text: String) -> TranscriptSegment {
    TranscriptSegment(speaker: nil, start: start, end: end, text: text)
}

@Test("The fingerprint is stable across calls for the same timings")
func fingerprintIsStable() {
    let segments = [seg(0, 1, "a"), seg(1, 2, "b")]
    #expect(TranscriptTimingFingerprint.compute(segments) == TranscriptTimingFingerprint.compute(segments))
}

@Test("Editing only the text leaves the timing fingerprint unchanged")
func fingerprintIgnoresText() {
    let before = TranscriptTimingFingerprint.compute([seg(0, 1, "hello"), seg(1, 2, "world")])
    let after = TranscriptTimingFingerprint.compute([seg(0, 1, "HELLO"), seg(1, 2, "WORLD")])
    #expect(before == after)
}

@Test("Changing a timing changes the fingerprint")
func fingerprintTracksTimings() {
    let before = TranscriptTimingFingerprint.compute([seg(0, 1, "a"), seg(1, 2, "b")])
    let after = TranscriptTimingFingerprint.compute([seg(0, 1, "a"), seg(1, 2.5, "b")])
    #expect(before != after)
}

@Test("Adding or removing a segment changes the fingerprint")
func fingerprintTracksSegmentCount() {
    let before = TranscriptTimingFingerprint.compute([seg(0, 1, "a")])
    let after = TranscriptTimingFingerprint.compute([seg(0, 1, "a"), seg(1, 2, "b")])
    #expect(before != after)
}

@Test("Missing timings are represented distinctly rather than collapsing to zero")
func fingerprintDistinguishesMissingTimings() {
    let missing = TranscriptTimingFingerprint.compute([seg(nil, nil, "a")])
    let zeroed = TranscriptTimingFingerprint.compute([seg(0, 0, "a")])
    #expect(missing != zeroed)
}

@Test("An empty transcript has a defined fingerprint")
func fingerprintHandlesEmpty() {
    #expect(!TranscriptTimingFingerprint.compute([]).isEmpty)
}
```

- [ ] **Step 2: Run the tests and verify they fail**

`--filter "fingerprint"`. Expected: FAIL — `cannot find 'TranscriptTimingFingerprint' in scope`.

- [ ] **Step 3: Write the implementation**

```swift
import Foundation

/// A stable fingerprint over a transcript's *timings only*, used to detect that a cached speaker
/// overlay no longer describes the current segments (F218).
///
/// Deliberately not a cryptographic hash: `CryptoKit` is a framework import barred from WhisperCore,
/// and the threat model here is accidental drift — a re-run, a segment splice — not forgery. FNV-1a
/// over the quantized bounds is enough to notice a change, and it is dependency-free.
public enum TranscriptTimingFingerprint {
    /// Milliseconds. Finer resolution would make the fingerprint sensitive to float formatting;
    /// coarser would miss a real re-alignment.
    private static let quantum: Double = 1000

    public static func compute(_ segments: [TranscriptSegment]) -> String {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        func mix(_ value: UInt64) {
            hash ^= value
            hash = hash &* 0x0000_0100_0000_01B3
        }
        // The count is mixed in first so a prefix can never fingerprint as the whole.
        mix(UInt64(truncatingIfNeeded: segments.count))
        for segment in segments {
            mix(quantized(segment.start))
            mix(quantized(segment.end))
        }
        return String(format: "%016llx", hash)
    }

    /// `nil` maps to a reserved sentinel so a segment without timings can never fingerprint the same
    /// as one that genuinely starts at zero.
    private static func quantized(_ value: Double?) -> UInt64 {
        guard let value, value.isFinite else { return UInt64.max }
        return UInt64(bitPattern: Int64((value * quantum).rounded()))
    }
}
```

- [ ] **Step 4: Run the tests and verify they pass**

Expected: PASS, 6 tests.

- [ ] **Step 5: Commit**

```bash
git add Sources/WhisperCore/TranscriptTimingFingerprint.swift Tests/WhisperCoreTests/TranscriptTimingFingerprintTests.swift
git commit -m "feat(diarization): fingerprint transcript timings so a stale overlay is detectable (F218)"
```

---

## Task 4: The pure overlay reconciler

The heart of the conservative display policy. Shaped exactly like `TranscriptChapters`: `public enum`, all statics, value results, `[start, end)` half-open, no I/O.

**Files:**
- Create: `Sources/WhisperCore/SpeakerOverlay.swift`
- Test: `Tests/WhisperCoreTests/SpeakerOverlayTests.swift`

**Interfaces:**
- Consumes: `SpeakerTurn`, `SpeakerTurnKind` (Task 2)
- Produces: `SpeakerOverlayLabel`, `SpeakerOverlayRow`, `SpeakerOverlay.rows(segments:turns:recordingDuration:)`, `SpeakerOverlay.clusterIDs(in:)`, `SpeakerOverlay.minimumCoverage`, `SpeakerOverlay.minimumMargin`

- [ ] **Step 1: Write the failing tests**

```swift
import Foundation
import Testing
@testable import WhisperCore

// F218 — the reconciler is where a persuasive-but-wrong label gets stopped. Each test pins one
// clause of the PRD rule: 80% coverage, a 20-point margin, and an overlap veto. Without the
// implementation every case below returns nothing at all.

private func seg(_ start: Double?, _ end: Double?, _ text: String = "x") -> TranscriptSegment {
    TranscriptSegment(speaker: nil, start: start, end: end, text: text)
}

private func turn(_ start: Double, _ end: Double, _ cluster: Int,
                  _ kind: SpeakerTurnKind = .speech) -> SpeakerTurn {
    SpeakerTurn(startSeconds: start, endSeconds: end, clusterID: cluster, kind: kind)
}

@Test("A segment fully covered by one cluster gets that label")
func overlayLabelsAnUnambiguousSegment() {
    let rows = SpeakerOverlay.rows(
        segments: [seg(0, 10)],
        turns: [turn(0, 10, 0)],
        recordingDuration: 10
    )
    #expect(rows == [SpeakerOverlayRow(segmentIndex: 0, label: .speaker(clusterID: 0))])
}

@Test("A segment split evenly between two clusters gets no label")
func overlaySplitSegmentIsUnlabeled() {
    let rows = SpeakerOverlay.rows(
        segments: [seg(0, 10)],
        turns: [turn(0, 5, 0), turn(5, 10, 1)],
        recordingDuration: 10
    )
    #expect(rows == [SpeakerOverlayRow(segmentIndex: 0, label: .uncertain)])
}

@Test("Coverage just below the 80% floor abstains; just above it labels")
func overlayHonoursTheCoverageFloor() {
    // 79% of the segment, the rest silence — below the floor.
    let below = SpeakerOverlay.rows(
        segments: [seg(0, 100)],
        turns: [turn(0, 79, 0)],
        recordingDuration: 100
    )
    #expect(below == [SpeakerOverlayRow(segmentIndex: 0, label: .uncertain)])

    let above = SpeakerOverlay.rows(
        segments: [seg(0, 100)],
        turns: [turn(0, 81, 0)],
        recordingDuration: 100
    )
    #expect(above == [SpeakerOverlayRow(segmentIndex: 0, label: .speaker(clusterID: 0))])
}

@Test("A runner-up within 20 points blocks the label even when coverage is high")
func overlayHonoursTheMargin() {
    // Cluster 0 covers 55%, cluster 1 covers 45%: total coverage is 100% but the margin is 10pt.
    let rows = SpeakerOverlay.rows(
        segments: [seg(0, 100)],
        turns: [turn(0, 55, 0), turn(55, 100, 1)],
        recordingDuration: 100
    )
    #expect(rows == [SpeakerOverlayRow(segmentIndex: 0, label: .uncertain)])
}

@Test("An overlap turn intersecting the segment vetoes any label")
func overlayVetoesOnOverlap() {
    // Cluster 0 would otherwise clear both thresholds.
    let rows = SpeakerOverlay.rows(
        segments: [seg(0, 100)],
        turns: [turn(0, 100, 0), turn(40, 45, 1, .overlap)],
        recordingDuration: 100
    )
    #expect(rows == [SpeakerOverlayRow(segmentIndex: 0, label: .overlapping)])
}

@Test("An uncertain turn covering the segment yields uncertain, never a cluster name")
func overlayPropagatesUncertainty() {
    let rows = SpeakerOverlay.rows(
        segments: [seg(0, 10)],
        turns: [turn(0, 10, 0, .uncertain)],
        recordingDuration: 10
    )
    #expect(rows == [SpeakerOverlayRow(segmentIndex: 0, label: .uncertain)])
}

@Test("A segment with no covering turn is unlabeled, not assigned to the nearest speaker")
func overlayLeavesUncoveredSegmentsUnlabeled() {
    let rows = SpeakerOverlay.rows(
        segments: [seg(50, 60)],
        turns: [turn(0, 10, 0)],
        recordingDuration: 100
    )
    #expect(rows == [SpeakerOverlayRow(segmentIndex: 0, label: .unlabeled)])
}

@Test("A segment without timings is unlabeled rather than guessed")
func overlaySkipsUntimedSegments() {
    let rows = SpeakerOverlay.rows(
        segments: [seg(nil, nil)],
        turns: [turn(0, 10, 0)],
        recordingDuration: 10
    )
    #expect(rows == [SpeakerOverlayRow(segmentIndex: 0, label: .unlabeled)])
}

@Test("An open-ended segment falls back to the next start, then the recording duration")
func overlayResolvesOpenEndedSegments() {
    let rows = SpeakerOverlay.rows(
        segments: [seg(0, nil), seg(10, nil)],
        turns: [turn(0, 10, 0), turn(10, 20, 1)],
        recordingDuration: 20
    )
    #expect(rows == [
        SpeakerOverlayRow(segmentIndex: 0, label: .speaker(clusterID: 0)),
        SpeakerOverlayRow(segmentIndex: 1, label: .speaker(clusterID: 1))
    ])
}

@Test("No turns at all leaves every segment unlabeled")
func overlayWithNoTurnsLabelsNothing() {
    let rows = SpeakerOverlay.rows(
        segments: [seg(0, 1), seg(1, 2)],
        turns: [],
        recordingDuration: 2
    )
    #expect(rows.allSatisfy { $0.label == .unlabeled })
}

@Test("Cluster ids are listed in first-appearance order for a stable legend")
func overlayListsClustersInFirstAppearanceOrder() {
    let rows = [
        SpeakerOverlayRow(segmentIndex: 0, label: .speaker(clusterID: 2)),
        SpeakerOverlayRow(segmentIndex: 1, label: .uncertain),
        SpeakerOverlayRow(segmentIndex: 2, label: .speaker(clusterID: 0)),
        SpeakerOverlayRow(segmentIndex: 3, label: .speaker(clusterID: 2))
    ]
    #expect(SpeakerOverlay.clusterIDs(in: rows) == [2, 0])
}

@Test("Reconciling a long transcript against many turns stays linear")
func overlayIsLinearOnLongInput() {
    // 5 000 segments x 5 000 turns would be 25M interval tests if this were quadratic; the merge
    // walk keeps it linear, and this test exists because the playback tick regressed exactly that
    // way before (see TranscriptPlayback's O(n^2) note).
    let segments = (0..<5_000).map { index in seg(Double(index), Double(index) + 1) }
    let turns = (0..<5_000).map { index in turn(Double(index), Double(index) + 1, index % 3) }
    let rows = SpeakerOverlay.rows(segments: segments, turns: turns, recordingDuration: 5_000)
    #expect(rows.count == 5_000)
    #expect(rows[0].label == .speaker(clusterID: 0))
    #expect(rows[4_999].label == .speaker(clusterID: 4_999 % 3))
}
```

- [ ] **Step 2: Run the tests and verify they fail**

`--filter "overlay"`. Expected: FAIL — `cannot find 'SpeakerOverlay' in scope`.

- [ ] **Step 3: Write the implementation**

```swift
import Foundation

/// What the transcript row shows for one segment. `speaker` is the only case that names a cluster,
/// and it is reached only when the conservative rule below is satisfied (F218).
public enum SpeakerOverlayLabel: Sendable, Equatable {
    /// One anonymous cluster covers this segment unambiguously.
    case speaker(clusterID: Int)
    /// More than one voice may be active here.
    case overlapping
    /// Voices are present but no single one can be named.
    case uncertain
    /// No diarization turn covers this segment at all.
    case unlabeled
}

public struct SpeakerOverlayRow: Sendable, Equatable {
    public let segmentIndex: Int
    public let label: SpeakerOverlayLabel

    public init(segmentIndex: Int, label: SpeakerOverlayLabel) {
        self.segmentIndex = segmentIndex
        self.label = label
    }
}

/// Pure reconciliation of anonymous diarization turns with timed ASR segments (F218).
///
/// This produces a *display overlay* and nothing else: `TranscriptSegment` is never mutated,
/// `transcriptText` is never touched, and the audio is never read. The thresholds are fixed policy,
/// not user-facing "confidence" controls — a benchmark may revise them only with a documented
/// before/after comparison on a held-out corpus.
///
/// Half-open `[start, end)` throughout, matching `TranscriptChapters` and `TranscriptPlayback`.
public enum SpeakerOverlay {
    /// A cluster must cover at least this fraction of the segment's duration.
    public static let minimumCoverage = 0.80
    /// …and must beat the runner-up by at least this many percentage points.
    public static let minimumMargin = 0.20

    /// Assigns a label to each segment, in segment order. Never fills a visual gap by choosing the
    /// most common speaker: an ambiguous interval reports its ambiguity.
    public static func rows(
        segments: [TranscriptSegment],
        turns: [SpeakerTurn],
        recordingDuration: TimeInterval?
    ) -> [SpeakerOverlayRow] {
        guard !segments.isEmpty else { return [] }
        guard !turns.isEmpty else {
            return segments.indices.map { SpeakerOverlayRow(segmentIndex: $0, label: .unlabeled) }
        }

        var rows: [SpeakerOverlayRow] = []
        rows.reserveCapacity(segments.count)
        // Turns are validated sorted by start, so a single advancing cursor is enough: segments are
        // also time-ordered, so the walk never rescans from the beginning. A nested scan here would
        // be O(segments x turns) and would regress long transcripts the way the playback tick once did.
        var cursor = 0

        for index in segments.indices {
            guard let bounds = self.bounds(of: segments, at: index, recordingDuration: recordingDuration) else {
                rows.append(SpeakerOverlayRow(segmentIndex: index, label: .unlabeled))
                continue
            }
            // Retreat is impossible (segments advance), but a turn may span several segments, so the
            // cursor only moves past turns that end before this segment begins.
            while cursor < turns.count, turns[cursor].endSeconds <= bounds.start {
                cursor += 1
            }

            var coverageByCluster: [Int: TimeInterval] = [:]
            var overlapSeconds: TimeInterval = 0
            var uncertainSeconds: TimeInterval = 0
            var scan = cursor
            while scan < turns.count, turns[scan].startSeconds < bounds.end {
                let turn = turns[scan]
                let intersection = min(turn.endSeconds, bounds.end) - max(turn.startSeconds, bounds.start)
                if intersection > 0 {
                    switch turn.kind {
                    case .speech:
                        coverageByCluster[turn.clusterID, default: 0] += intersection
                    case .overlap:
                        overlapSeconds += intersection
                    case .uncertain:
                        uncertainSeconds += intersection
                    }
                }
                scan += 1
            }

            rows.append(SpeakerOverlayRow(
                segmentIndex: index,
                label: label(
                    coverageByCluster: coverageByCluster,
                    overlapSeconds: overlapSeconds,
                    uncertainSeconds: uncertainSeconds,
                    segmentDuration: bounds.end - bounds.start
                )
            ))
        }
        return rows
    }

    /// The distinct clusters actually shown, in first-appearance order — the legend's row order, so
    /// it matches the reading order of the transcript rather than a numeric sort.
    public static func clusterIDs(in rows: [SpeakerOverlayRow]) -> [Int] {
        var seen: Set<Int> = []
        var ordered: [Int] = []
        for row in rows {
            guard case let .speaker(clusterID) = row.label, !seen.contains(clusterID) else { continue }
            seen.insert(clusterID)
            ordered.append(clusterID)
        }
        return ordered
    }

    /// The PRD's rule, in one place: an overlap anywhere in the segment vetoes a name; otherwise a
    /// cluster must clear both the coverage floor and the margin over the runner-up.
    private static func label(
        coverageByCluster: [Int: TimeInterval],
        overlapSeconds: TimeInterval,
        uncertainSeconds: TimeInterval,
        segmentDuration: TimeInterval
    ) -> SpeakerOverlayLabel {
        guard segmentDuration > 0 else { return .unlabeled }
        if overlapSeconds > 0 { return .overlapping }
        guard !coverageByCluster.isEmpty else {
            return uncertainSeconds > 0 ? .uncertain : .unlabeled
        }
        // Ties break toward the lower cluster id so the result is deterministic across runs.
        let ranked = coverageByCluster
            .sorted { ($0.value, $1.key) > ($1.value, $0.key) }
        let best = ranked[0]
        let bestShare = best.value / segmentDuration
        let runnerUpShare = ranked.count > 1 ? ranked[1].value / segmentDuration : 0
        guard bestShare >= minimumCoverage, bestShare - runnerUpShare >= minimumMargin else {
            return .uncertain
        }
        return .speaker(clusterID: best.key)
    }

    /// A segment's effective time range, with the same three-level fallback `TranscriptPlayback`
    /// uses: an explicit end, else the next segment's start, else the recording duration.
    private static func bounds(
        of segments: [TranscriptSegment],
        at index: Int,
        recordingDuration: TimeInterval?
    ) -> (start: TimeInterval, end: TimeInterval)? {
        guard let start = segments[index].start, start.isFinite else { return nil }
        let end = segments[index].end
            ?? segments[(index + 1)...].lazy.compactMap(\.start).first
            ?? recordingDuration
        guard let end, end.isFinite, end > start else { return nil }
        return (start, end)
    }
}
```

- [ ] **Step 4: Run the tests and verify they pass**

Expected: PASS, 12 tests.

- [ ] **Step 5: Commit**

```bash
git add Sources/WhisperCore/SpeakerOverlay.swift Tests/WhisperCoreTests/SpeakerOverlayTests.swift
git commit -m "feat(diarization): reconcile turns into a conservative display overlay (F218)"
```

---

## Task 5: The `diarization.json` artifact codec

**Files:**
- Create: `Sources/WhisperCore/DiarizationArtifact.swift`
- Test: `Tests/WhisperCoreTests/DiarizationArtifactTests.swift`

**Interfaces:**
- Consumes: `SpeakerTurn`, `SpeakerTurns.validate` (Task 2)
- Produces: `DiarizationArtifactV1`, `DiarizationProducer`, `DiarizationRecordingReference`, `DiarizationArtifactError`, `DiarizationArtifactCodec.encode(_:)`, `DiarizationArtifactCodec.decode(_:)`

Note: `aliases` is `[String: String]` keyed by the cluster id rendered in decimal. `[Int: String]` would encode as a flat JSON **array**, which is unreadable and breaks hand inspection of the sidecar.

- [ ] **Step 1: Write the failing tests**

```swift
import Foundation
import Testing
@testable import WhisperCore

// F218 — the sidecar is a new persistence contract holding user-typed aliases. It decodes strictly,
// refuses a newer schema rather than truncating it, and never silently repairs a malformed result.

private func artifact(
    turns: [SpeakerTurn] = [SpeakerTurn(startSeconds: 0, endSeconds: 5, clusterID: 0, kind: .speech)],
    aliases: [String: String] = [:]
) -> DiarizationArtifactV1 {
    DiarizationArtifactV1(
        meetingID: UUID(uuidString: "11111111-2222-3333-4444-555555555555")!,
        recording: DiarizationRecordingReference(
            relativePath: "Recordings/x/meeting.wav",
            sha256: "abc123",
            durationSeconds: 10
        ),
        transcriptTimingFingerprint: "ffffffffffffffff",
        producer: DiarizationProducer(
            runtimeID: "sherpa-onnx",
            runtimeVersion: "1.13.8",
            segmentationModelSHA256: "seg",
            embeddingModelSHA256: "emb",
            clusterThreshold: 0.3
        ),
        createdAt: Date(timeIntervalSince1970: 1_700_000_000),
        turns: turns,
        aliases: aliases
    )
}

@Test("An artifact round-trips through the codec unchanged")
func artifactRoundTrips() throws {
    let original = artifact(aliases: ["0": "Me"])
    let decoded = try DiarizationArtifactCodec.decode(DiarizationArtifactCodec.encode(original))
    #expect(decoded == original)
}

@Test("The encoded form is stable, sorted JSON with ISO-8601 dates")
func artifactEncodesStably() throws {
    let data = try DiarizationArtifactCodec.encode(artifact())
    let text = String(decoding: data, as: UTF8.self)
    #expect(text.contains("\"schemaVersion\" : 1"))
    #expect(text.contains("2023-11-14T"))
    // Sorted keys mean a byte-identical re-encode of unchanged content — no spurious rewrites.
    let again = try DiarizationArtifactCodec.encode(artifact())
    #expect(again == data)
}

@Test("A newer schema version is refused, not truncated")
func artifactRefusesNewerSchema() throws {
    var object = try #require(
        try JSONSerialization.jsonObject(with: DiarizationArtifactCodec.encode(artifact())) as? [String: Any]
    )
    object["schemaVersion"] = 2
    let data = try JSONSerialization.data(withJSONObject: object)
    #expect(throws: DiarizationArtifactError.newerSchema(2)) {
        try DiarizationArtifactCodec.decode(data)
    }
}

@Test("Corrupt bytes decode as unreadable")
func artifactRefusesCorruptBytes() {
    #expect(throws: DiarizationArtifactError.unreadable) {
        try DiarizationArtifactCodec.decode(Data("not json at all".utf8))
    }
}

@Test("A malformed turn fails the whole decode rather than being dropped")
func artifactValidatesTurnsOnDecode() throws {
    let bad = artifact(turns: [SpeakerTurn(startSeconds: 5, endSeconds: 1, clusterID: 0, kind: .speech)])
    // Encoding does not validate; decoding must, because the file may have been written by anything.
    let data = try JSONEncoder.diarization.encode(bad)
    var thrown: Error?
    do { _ = try DiarizationArtifactCodec.decode(data) } catch { thrown = error }
    #expect(thrown as? DiarizationArtifactError == .malformed("reversedInterval"))
}

@Test("A turn past the recorded duration fails the decode")
func artifactValidatesTurnsAgainstItsOwnDuration() throws {
    let bad = artifact(turns: [SpeakerTurn(startSeconds: 0, endSeconds: 99, clusterID: 0, kind: .speech)])
    let data = try JSONEncoder.diarization.encode(bad)
    #expect(throws: DiarizationArtifactError.malformed("exceedsDuration")) {
        try DiarizationArtifactCodec.decode(data)
    }
}

@Test("An alias key that is not a cluster number is refused")
func artifactRefusesNonNumericAliasKeys() throws {
    let bad = artifact(aliases: ["not-a-number": "Me"])
    let data = try JSONEncoder.diarization.encode(bad)
    #expect(throws: DiarizationArtifactError.malformed("aliasKey")) {
        try DiarizationArtifactCodec.decode(data)
    }
}

@Test("An over-long alias is refused so the sidecar cannot become a text dump")
func artifactBoundsAliasLength() throws {
    let bad = artifact(aliases: ["0": String(repeating: "a", count: DiarizationArtifactV1.maximumAliasLength + 1)])
    let data = try JSONEncoder.diarization.encode(bad)
    #expect(throws: DiarizationArtifactError.malformed("aliasLength")) {
        try DiarizationArtifactCodec.decode(data)
    }
}

@Test("The artifact carries no embedding, audio, or transcript text")
func artifactCarriesNoVoiceData() throws {
    let text = String(decoding: try DiarizationArtifactCodec.encode(artifact()), as: UTF8.self)
    for forbidden in ["embedding", "voiceprint", "waveform", "transcript", "text"] {
        #expect(!text.lowercased().contains(forbidden), "artifact leaked a \(forbidden) field")
    }
}
```

- [ ] **Step 2: Run the tests and verify they fail**

`--filter "artifact"`. Expected: FAIL — `cannot find 'DiarizationArtifactV1' in scope`.

- [ ] **Step 3: Write the implementation**

```swift
import Foundation

/// Which runtime and models produced a result. Recorded so a rerun after a model change is
/// recognizable, and so the scorecard can attribute a number to an exact stack (F218).
public struct DiarizationProducer: Codable, Sendable, Equatable {
    public let runtimeID: String
    public let runtimeVersion: String
    public let segmentationModelSHA256: String
    public let embeddingModelSHA256: String
    public let clusterThreshold: Double

    public init(runtimeID: String, runtimeVersion: String, segmentationModelSHA256: String,
                embeddingModelSHA256: String, clusterThreshold: Double) {
        self.runtimeID = runtimeID
        self.runtimeVersion = runtimeVersion
        self.segmentationModelSHA256 = segmentationModelSHA256
        self.embeddingModelSHA256 = embeddingModelSHA256
        self.clusterThreshold = clusterThreshold
    }
}

/// Identifies the audio a result belongs to. The hash is what makes a result *stale* rather than
/// wrong when the recording changes.
public struct DiarizationRecordingReference: Codable, Sendable, Equatable {
    public let relativePath: String
    public let sha256: String
    public let durationSeconds: TimeInterval

    public init(relativePath: String, sha256: String, durationSeconds: TimeInterval) {
        self.relativePath = relativePath
        self.sha256 = sha256
        self.durationSeconds = durationSeconds
    }
}

/// The versioned per-recording sidecar written to `Recordings/<meeting-uuid>/diarization.json`.
///
/// It deliberately holds no embedding, no voiceprint, no audio, no copied transcript text, and no
/// global cluster id — only anonymous intervals, the provenance needed to detect staleness, and the
/// aliases a person typed for this one meeting (F218).
public struct DiarizationArtifactV1: Codable, Sendable, Equatable {
    public static let currentSchemaVersion = 1
    public static let maximumAliasLength = 64

    public let schemaVersion: Int
    public let meetingID: UUID
    public let recording: DiarizationRecordingReference
    public let transcriptTimingFingerprint: String
    public let producer: DiarizationProducer
    public let createdAt: Date
    public let turns: [SpeakerTurn]
    /// Cluster id rendered in decimal → the alias a person typed. A `[Int: String]` would encode as
    /// a flat JSON array, which is unreadable in a file a person may inspect.
    public var aliases: [String: String]

    public init(
        schemaVersion: Int = DiarizationArtifactV1.currentSchemaVersion,
        meetingID: UUID,
        recording: DiarizationRecordingReference,
        transcriptTimingFingerprint: String,
        producer: DiarizationProducer,
        createdAt: Date,
        turns: [SpeakerTurn],
        aliases: [String: String]
    ) {
        self.schemaVersion = schemaVersion
        self.meetingID = meetingID
        self.recording = recording
        self.transcriptTimingFingerprint = transcriptTimingFingerprint
        self.producer = producer
        self.createdAt = createdAt
        self.turns = turns
        self.aliases = aliases
    }
}

public enum DiarizationArtifactError: Error, Sendable, Equatable {
    /// The bytes are not decodable as this artifact at all.
    case unreadable
    /// Written by a newer build. Preserve it; never rewrite it.
    case newerSchema(Int)
    /// Decodable but not trustworthy. The payload names the failed rule.
    case malformed(String)
}

extension JSONEncoder {
    /// Stable output so an unchanged artifact re-encodes byte-identically and never causes a
    /// spurious rewrite.
    public static var diarization: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }
}

extension JSONDecoder {
    public static var diarization: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}

/// Strict read/write for the sidecar. Decoding validates: a file we cannot fully trust produces an
/// error the caller turns into "Speaker labels unavailable; your transcript is safe", never a
/// partially-applied result.
public enum DiarizationArtifactCodec {
    public static func encode(_ artifact: DiarizationArtifactV1) throws -> Data {
        try JSONEncoder.diarization.encode(artifact)
    }

    public static func decode(_ data: Data) throws -> DiarizationArtifactV1 {
        // The version is read before the whole value, so a newer schema is reported as such rather
        // than as corruption — the two get very different handling on disk.
        if let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let version = object["schemaVersion"] as? Int,
           version > DiarizationArtifactV1.currentSchemaVersion {
            throw DiarizationArtifactError.newerSchema(version)
        }
        guard let artifact = try? JSONDecoder.diarization.decode(DiarizationArtifactV1.self, from: data) else {
            throw DiarizationArtifactError.unreadable
        }
        guard artifact.schemaVersion == DiarizationArtifactV1.currentSchemaVersion else {
            throw DiarizationArtifactError.malformed("schemaVersion")
        }
        guard artifact.recording.durationSeconds.isFinite, artifact.recording.durationSeconds >= 0 else {
            throw DiarizationArtifactError.malformed("duration")
        }
        do {
            _ = try SpeakerTurns.validate(artifact.turns, durationSeconds: artifact.recording.durationSeconds)
        } catch let error as SpeakerTurnValidationError {
            throw DiarizationArtifactError.malformed(String(describing: error))
        }
        for (key, alias) in artifact.aliases {
            guard let clusterID = Int(key), clusterID >= 0 else {
                throw DiarizationArtifactError.malformed("aliasKey")
            }
            guard alias.count <= DiarizationArtifactV1.maximumAliasLength else {
                throw DiarizationArtifactError.malformed("aliasLength")
            }
        }
        return artifact
    }
}
```

- [ ] **Step 4: Run the tests and verify they pass**

Expected: PASS, 9 tests. `SpeakerTurnValidationError` cases are lowerCamelCase, so `String(describing: .reversedInterval)` is `"reversedInterval"` — matching the assertions.

- [ ] **Step 5: Commit**

```bash
git add Sources/WhisperCore/DiarizationArtifact.swift Tests/WhisperCoreTests/DiarizationArtifactTests.swift
git commit -m "feat(diarization): add the versioned diarization.json envelope and strict codec (F218)"
```

---

## Task 6: The runtime output parser

Pure, table-driven parsing of the binary's grammar. Every rule here was observed in a real run.

**Files:**
- Create: `Sources/WhisperCore/DiarizationOutputParser.swift`
- Test: `Tests/WhisperCoreTests/DiarizationOutputParserTests.swift`

**Interfaces:**
- Consumes: `SpeakerTurn`, `SpeakerTurnKind` (Task 2)
- Produces: `RawDiarizationTurn`, `DiarizationOutputParser.turn(from:)`, `.progress(from:)`, `.densify(_:uncertainBelowConfidence:)`, `.classify(errorOutput:exitStatus:)`, `LocalDiarizationError`

> **Confidence has three forms, not two.** A float, the literal `n/a` (emitted when only one cluster
> formed — measured on 5 of 592 corpus turns, and on 100% of the turns in both single-cluster
> fixtures), and absent entirely when `--clustering.compute-confidence` is off. All three must parse
> to a turn; only the float form is ever compared against a threshold.

- [ ] **Step 1: Write the failing tests**

```swift
import Foundation
import Testing
@testable import WhisperCore

// F219 — the runtime speaks a line grammar, and every rule below was observed in a real run:
// non-dense speaker ids, a -2.0 confidence sentinel, a config preamble before `Started`, and four
// distinct failure markers that all exit 255.

@Test("A segment line parses into a raw turn")
func parserReadsASegmentLine() throws {
    let turn = try #require(DiarizationOutputParser.turn(from: "0.031 -- 8.485 speaker_00 confidence=0.707"))
    #expect(turn.startSeconds == 0.031)
    #expect(turn.endSeconds == 8.485)
    #expect(turn.rawSpeaker == 0)
    #expect(turn.confidence == 0.707)
}

@Test("A segment line without confidence parses with a nil confidence")
func parserReadsALineWithoutConfidence() throws {
    let turn = try #require(DiarizationOutputParser.turn(from: "8.975 -- 18.695 speaker_02"))
    #expect(turn.rawSpeaker == 2)
    #expect(turn.confidence == nil)
}

@Test("A single-cluster run emits confidence=n/a, and the turn still parses")
func parserReadsUnavailableConfidence() throws {
    // Observed verbatim on the F217 corpus: whenever exactly one cluster forms, the runtime prints
    // the literal string `n/a` rather than a number or the -2.0 sentinel. A pattern that accepts
    // only digits drops the entire line, so a monologue would diarize to nothing at all.
    let turn = try #require(DiarizationOutputParser.turn(from: "0.470 -- 17.159 speaker_00 confidence=n/a"))
    #expect(turn.startSeconds == 0.470)
    #expect(turn.rawSpeaker == 0)
    #expect(turn.confidence == nil)
}

@Test("Preamble and progress lines are not turns")
func parserIgnoresNonSegmentLines() {
    #expect(DiarizationOutputParser.turn(from: "Started") == nil)
    #expect(DiarizationOutputParser.turn(from: "OfflineSpeakerDiarizationConfig(segmentation=...)") == nil)
    #expect(DiarizationOutputParser.turn(from: "") == nil)
    #expect(DiarizationOutputParser.turn(from: "progress 50.00%") == nil)
}

@Test("Progress lines parse to a 0...1 fraction")
func parserReadsProgress() {
    #expect(DiarizationOutputParser.progress(from: "progress 1.09%") == 0.0109)
    #expect(DiarizationOutputParser.progress(from: "progress 100.00%") == 1.0)
    #expect(DiarizationOutputParser.progress(from: "Duration : 56.190 s") == nil)
}

@Test("Sparse speaker ids are remapped densely in first-appearance order")
func parserDensifiesSpeakerIDs() {
    // Real output for a two-speaker file: speaker_00 and speaker_02, with no speaker_01.
    let raw = [
        RawDiarizationTurn(startSeconds: 0, endSeconds: 8, rawSpeaker: 0, confidence: 0.7),
        RawDiarizationTurn(startSeconds: 8, endSeconds: 18, rawSpeaker: 2, confidence: 0.6),
        RawDiarizationTurn(startSeconds: 19, endSeconds: 27, rawSpeaker: 0, confidence: 0.6)
    ]
    let turns = DiarizationOutputParser.densify(raw, uncertainBelowConfidence: 0)
    #expect(turns.map(\.clusterID) == [0, 1, 0])
    #expect(turns.allSatisfy { $0.kind == .speech })
}

@Test("The -2.0 confidence sentinel means unavailable, not a low score")
func parserTreatsSentinelConfidenceAsUnavailable() {
    let raw = [RawDiarizationTurn(startSeconds: 0, endSeconds: 8, rawSpeaker: 0, confidence: -2.0)]
    // A sentinel must not be compared against the threshold as if it were a real score.
    let turns = DiarizationOutputParser.densify(raw, uncertainBelowConfidence: 0.5)
    #expect(turns[0].kind == .speech)
}

@Test("A genuinely low confidence becomes an uncertain turn rather than a confident label")
func parserAbstainsBelowTheConfidenceFloor() {
    let raw = [
        RawDiarizationTurn(startSeconds: 0, endSeconds: 8, rawSpeaker: 0, confidence: 0.2),
        RawDiarizationTurn(startSeconds: 8, endSeconds: 16, rawSpeaker: 1, confidence: 0.9)
    ]
    let turns = DiarizationOutputParser.densify(raw, uncertainBelowConfidence: 0.5)
    #expect(turns[0].kind == .uncertain)
    #expect(turns[1].kind == .speech)
}

@Test("Each runtime failure marker maps to its own error")
func parserClassifiesFailures() {
    #expect(DiarizationOutputParser.classify(errorOutput: "Errors in config!", exitStatus: 255)
        == .runtimeDamaged("Errors in config!"))
    #expect(DiarizationOutputParser.classify(errorOutput: "Failed to read /tmp/x.wav", exitStatus: 255)
        == .audioUnreadable("Failed to read /tmp/x.wav"))
    #expect(DiarizationOutputParser.classify(errorOutput: "Expect sample rate 16000. Given: 44100", exitStatus: 255)
        == .sampleRateMismatch("Expect sample rate 16000. Given: 44100"))
    #expect(DiarizationOutputParser.classify(errorOutput: "something else", exitStatus: 3)
        == .processFailed("something else"))
}
```

- [ ] **Step 2: Run the tests and verify they fail**

`--filter "parser"`. Expected: FAIL — `cannot find 'DiarizationOutputParser' in scope`.

- [ ] **Step 3: Write the implementation**

```swift
import Foundation

/// One line of the runtime's stdout, before remapping. `rawSpeaker` is the runtime's own cluster
/// number, which is **not dense** — a two-speaker file really does emit `speaker_00`/`speaker_02`.
public struct RawDiarizationTurn: Sendable, Equatable {
    public let startSeconds: TimeInterval
    public let endSeconds: TimeInterval
    public let rawSpeaker: Int
    public let confidence: Double?

    public init(startSeconds: TimeInterval, endSeconds: TimeInterval, rawSpeaker: Int, confidence: Double?) {
        self.startSeconds = startSeconds
        self.endSeconds = endSeconds
        self.rawSpeaker = rawSpeaker
        self.confidence = confidence
    }
}

public enum LocalDiarizationError: LocalizedError, Sendable, Equatable {
    case runtimeNotInstalled
    case runtimeDamaged(String)
    case audioUnreadable(String)
    case sampleRateMismatch(String)
    case processFailed(String)

    public var errorDescription: String? {
        switch self {
        case .runtimeNotInstalled:
            "The speaker-analysis model is not installed. Install it in Settings to analyze speaker turns."
        case .runtimeDamaged:
            "The speaker-analysis model files are missing or damaged. Reinstall it in Settings; your transcript is unchanged."
        case .audioUnreadable:
            "This meeting's recording could not be read for analysis. Your transcript is unchanged."
        case .sampleRateMismatch:
            "The audio prepared for analysis was in the wrong format. Your transcript is unchanged."
        case let .processFailed(detail):
            "Speaker analysis did not finish. Your transcript is unchanged. \(detail)"
        }
    }
}

/// Pure parsing of the diarization runtime's line grammar (F219). Kept separate from the process
/// plumbing so every rule below is testable without a model, audio, or a subprocess.
public enum DiarizationOutputParser {
    /// `0.031 -- 8.485 speaker_00 confidence=0.707`, with confidence present only when the runtime
    /// was asked for it.
    private static let segmentPattern = try! NSRegularExpression(
        pattern: #"^\s*([0-9]+\.[0-9]+)\s*--\s*([0-9]+\.[0-9]+)\s+speaker_([0-9]+)(?:\s+confidence=(n/a|-?[0-9.]+))?\s*$"#
    )
    private static let progressPattern = try! NSRegularExpression(
        pattern: #"^\s*progress\s+([0-9]+\.[0-9]+)%\s*$"#
    )

    /// The runtime reports this when only one cluster formed, or when no overlapping embedding
    /// interval existed. It is "unavailable", not a low score, and must never be thresholded.
    public static let unavailableConfidence: Double = -2.0

    public static func turn(from line: String) -> RawDiarizationTurn? {
        let range = NSRange(line.startIndex..<line.endIndex, in: line)
        guard let match = segmentPattern.firstMatch(in: line, range: range) else { return nil }
        func group(_ index: Int) -> String? {
            guard let range = Range(match.range(at: index), in: line) else { return nil }
            return String(line[range])
        }
        guard let start = group(1).flatMap(Double.init),
              let end = group(2).flatMap(Double.init),
              let speaker = group(3).flatMap(Int.init) else { return nil }
        // `confidence=n/a` is emitted verbatim whenever only one cluster formed. It is not a
        // number and it is not a score — it means "unavailable". Parsing it as a failed Double is
        // correct (nil), but the PATTERN must accept it, or the whole line fails to match and every
        // turn of a single-speaker recording is silently discarded. Measured on the F217 corpus:
        // `mono_1spk` and `zh_2spk_alt` emit it for 100% of their turns.
        return RawDiarizationTurn(
            startSeconds: start,
            endSeconds: end,
            rawSpeaker: speaker,
            confidence: group(4).flatMap(Double.init)
        )
    }

    public static func progress(from line: String) -> Double? {
        let range = NSRange(line.startIndex..<line.endIndex, in: line)
        guard let match = progressPattern.firstMatch(in: line, range: range),
              let percentRange = Range(match.range(at: 1), in: line),
              let percent = Double(line[percentRange]) else { return nil }
        return min(1, max(0, percent / 100))
    }

    /// Remaps the runtime's sparse cluster numbers onto dense `0..<n` in first-appearance order, so
    /// "Speaker 1" is the first voice heard rather than an arbitrary internal index, and marks a
    /// low-confidence turn uncertain so the overlay abstains instead of showing a confident guess.
    public static func densify(
        _ raw: [RawDiarizationTurn],
        uncertainBelowConfidence threshold: Double
    ) -> [SpeakerTurn] {
        var mapping: [Int: Int] = [:]
        var next = 0
        return raw.map { turn in
            let clusterID: Int
            if let existing = mapping[turn.rawSpeaker] {
                clusterID = existing
            } else {
                clusterID = next
                mapping[turn.rawSpeaker] = next
                next += 1
            }
            let isUncertain: Bool
            if let confidence = turn.confidence, confidence != unavailableConfidence {
                isUncertain = confidence < threshold
            } else {
                isUncertain = false
            }
            return SpeakerTurn(
                startSeconds: turn.startSeconds,
                endSeconds: turn.endSeconds,
                clusterID: clusterID,
                kind: isUncertain ? .uncertain : .speech
            )
        }
    }

    /// Maps the runtime's failure markers onto distinct errors. All four config/IO failures exit
    /// 255, so the marker text is the only discriminator.
    public static func classify(errorOutput: String, exitStatus: Int32) -> LocalDiarizationError {
        if errorOutput.contains("Expect sample rate") { return .sampleRateMismatch(errorOutput) }
        if errorOutput.contains("Failed to read") { return .audioUnreadable(errorOutput) }
        if errorOutput.contains("Errors in config!") { return .runtimeDamaged(errorOutput) }
        return .processFailed(errorOutput)
    }
}
```

- [ ] **Step 4: Run the tests and verify they pass**

Expected: PASS, 8 tests.

- [ ] **Step 5: Commit**

```bash
git add Sources/WhisperCore/DiarizationOutputParser.swift Tests/WhisperCoreTests/DiarizationOutputParserTests.swift
git commit -m "feat(diarization): parse the runtime's turn, progress, and failure grammar (F219)"
```

---

## Task 7: The subprocess client and runtime paths

**Files:**
- Create: `Sources/WhisperCore/LocalDiarizationClient.swift`
- Test: `Tests/WhisperCoreTests/LocalDiarizationClientTests.swift`

**Interfaces:**
- Consumes: `DiarizationOutputParser`, `RawDiarizationTurn`, `LocalDiarizationError` (Task 6); `SpeakerTurn` (Task 2)
- Produces: `DiarizationRuntime` (paths, `isInstalled`, pinned config), `SpeakerDiarizationResult`, `LocalDiarizationClient.diarize(audioURL:durationSeconds:progress:)`

Follow `LocalWhisperClient`'s process shape exactly: one shared pipe for stdout+stderr, a `readabilityHandler` feeding an `AsyncStream`, `withTaskCancellationHandler`, and an **armed exit stream** — never `process.waitUntilExit()` on a cooperative thread.

- [ ] **Step 1: Write the failing tests**

The client is tested against a fake executable, exactly as `QwenASRClientTests` tests the Qwen client against a fake `python`.

```swift
import Foundation
import Testing
@testable import WhisperCore

// F219 — the seam is the executable path, so the whole adapter is testable with a shell script
// that replays a recorded transcript: no models, no audio, no network.

@MainActor
private func makeFakeRuntime(
    stdout: String,
    stderr: String = "",
    exitStatus: Int = 0
) throws -> (directory: URL, client: LocalDiarizationClient) {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("DiarizationClient-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let executable = directory.appendingPathComponent("fake-diarizer")
    let script = """
    #!/bin/zsh
    cat <<'STDOUT_EOF'
    \(stdout)
    STDOUT_EOF
    print -u2 -- '\(stderr)'
    exit \(exitStatus)
    """
    try script.write(to: executable, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
    let segmentation = directory.appendingPathComponent("segmentation.onnx")
    let embedding = directory.appendingPathComponent("embedding.onnx")
    try Data("seg".utf8).write(to: segmentation)
    try Data("emb".utf8).write(to: embedding)
    return (directory, LocalDiarizationClient(
        executableURL: executable,
        segmentationModelURL: segmentation,
        embeddingModelURL: embedding
    ))
}

@MainActor
@Test("A successful run yields validated, densely numbered turns")
func clientParsesASuccessfulRun() async throws {
    let (directory, client) = try makeFakeRuntime(stdout: """
    OfflineSpeakerDiarizationConfig(segmentation=...)
    Started
    0.031 -- 8.485 speaker_00 confidence=0.707
    8.975 -- 18.695 speaker_02 confidence=0.641
    """)
    defer { try? FileManager.default.removeItem(at: directory) }

    let result = try await client.diarize(
        audioURL: directory.appendingPathComponent("audio.wav"),
        durationSeconds: 20,
        progress: { _ in }
    )
    #expect(result.turns.map(\.clusterID) == [0, 1])
    #expect(result.speakerCount == 2)
    #expect(result.turns[0].startSeconds == 0.031)
}

@MainActor
@Test("Lines before `Started` are discarded so the config preamble never reaches a turn")
func clientDiscardsThePreamble() async throws {
    // The preamble embeds model paths; treating it as data would both break parsing and log paths.
    let (directory, client) = try makeFakeRuntime(stdout: """
    OfflineSpeakerDiarizationConfig(model="/secret/path/model.onnx")
    0.000 -- 1.000 speaker_09
    Started
    2.000 -- 3.000 speaker_00
    """)
    defer { try? FileManager.default.removeItem(at: directory) }

    let result = try await client.diarize(
        audioURL: directory.appendingPathComponent("audio.wav"),
        durationSeconds: 10,
        progress: { _ in }
    )
    #expect(result.turns.count == 1)
    #expect(result.turns[0].startSeconds == 2.0)
}

@MainActor
@Test("Zero turns with a clean exit is a legitimate empty result, not a failure")
func clientTreatsSilenceAsAnEmptyResult() async throws {
    let (directory, client) = try makeFakeRuntime(stdout: "Started")
    defer { try? FileManager.default.removeItem(at: directory) }

    let result = try await client.diarize(
        audioURL: directory.appendingPathComponent("audio.wav"),
        durationSeconds: 1,
        progress: { _ in }
    )
    #expect(result.turns.isEmpty)
    #expect(result.speakerCount == 0)
}

@MainActor
@Test("Progress lines on stderr reach the progress callback")
func clientReportsProgress() async throws {
    let (directory, client) = try makeFakeRuntime(
        stdout: "Started\n1.000 -- 2.000 speaker_00",
        stderr: "progress 50.00%"
    )
    defer { try? FileManager.default.removeItem(at: directory) }

    let box = ProgressBox()
    _ = try await client.diarize(
        audioURL: directory.appendingPathComponent("audio.wav"),
        durationSeconds: 10,
        progress: { fraction in box.values.append(fraction) }
    )
    #expect(box.values.contains(0.5))
}

@MainActor
@Test("A config failure maps to the damaged-runtime error")
func clientMapsConfigFailure() async throws {
    let (directory, client) = try makeFakeRuntime(stdout: "", stderr: "Errors in config!", exitStatus: 255)
    defer { try? FileManager.default.removeItem(at: directory) }

    var thrown: Error?
    do {
        _ = try await client.diarize(
            audioURL: directory.appendingPathComponent("audio.wav"),
            durationSeconds: 10,
            progress: { _ in }
        )
    } catch { thrown = error }
    guard case .runtimeDamaged = thrown as? LocalDiarizationError else {
        Issue.record("expected runtimeDamaged, got \(String(describing: thrown))")
        return
    }
}

@MainActor
@Test("A turn past the recording duration fails the whole run rather than being shown")
func clientValidatesAgainstDuration() async throws {
    let (directory, client) = try makeFakeRuntime(stdout: """
    Started
    0.000 -- 999.000 speaker_00
    """)
    defer { try? FileManager.default.removeItem(at: directory) }

    var thrown: Error?
    do {
        _ = try await client.diarize(
            audioURL: directory.appendingPathComponent("audio.wav"),
            durationSeconds: 10,
            progress: { _ in }
        )
    } catch { thrown = error }
    #expect(thrown != nil)
}

private final class ProgressBox: @unchecked Sendable {
    var values: [Double] = []
}

@Test("The runtime reports itself uninstalled when any required file is missing")
func runtimeInstallationPredicateRequiresEveryFile() throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("DiarizationRuntime-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    #expect(DiarizationRuntime.isInstalled(applicationSupport: root) == false)

    let directory = DiarizationRuntime.managedDirectory(applicationSupport: root)
    try FileManager.default.createDirectory(
        at: directory.appendingPathComponent("models/segmentation"), withIntermediateDirectories: true)
    try FileManager.default.createDirectory(
        at: directory.appendingPathComponent("models/embedding"), withIntermediateDirectories: true)
    try FileManager.default.createDirectory(
        at: directory.appendingPathComponent("bin"), withIntermediateDirectories: true)
    try Data("x".utf8).write(to: DiarizationRuntime.segmentationModel(applicationSupport: root))
    try Data("x".utf8).write(to: DiarizationRuntime.embeddingModel(applicationSupport: root))
    // Still missing the executable.
    #expect(DiarizationRuntime.isInstalled(applicationSupport: root) == false)

    let executable = DiarizationRuntime.executable(applicationSupport: root)
    try Data("x".utf8).write(to: executable)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
    #expect(DiarizationRuntime.isInstalled(applicationSupport: root) == true)
}
```

- [ ] **Step 2: Run the tests and verify they fail**

`--filter "client|runtimeInstallation"`. Expected: FAIL — `cannot find 'LocalDiarizationClient' in scope`.

- [ ] **Step 3: Write the implementation**

Model the process handling on `Sources/WhisperCore/LocalWhisperClient.swift:226-345` — read it before writing this. Required elements:

- `DiarizationRuntime` with `managedDirectory(applicationSupport:)` → `<AppSupport>/WhisperMeet/Runtime/Diarization`, `executable` → `bin/sherpa-onnx-offline-speaker-diarization`, `segmentationModel` → `models/segmentation/model.onnx`, `embeddingModel` → `models/embedding/campplus_zh_en.onnx`, plus `isInstalled(applicationSupport:)` requiring an **executable** binary and both model files, and the pinned constants `clusterThreshold = 0.3`, `numThreads = 4`, and `uncertainBelowConfidence = 0.0`.

> **Keep the confidence floor at `0.0`; the number was not earned.** On the F216 fixtures a floor of
> 0.50 does separate wholly-misattributed turns from correct ones *per turn*. But scored on what a
> reader actually sees — rows surviving `SpeakerOverlay`'s 80%/20-point rule — the overlay already
> abstains on exactly those rows: 100% displayed precision at 93.3% coverage without the floor,
> versus 100% at 86.7% with it. It costs coverage and buys no precision.
- `SpeakerDiarizationResult { turns: [SpeakerTurn], speakerCount: Int, audioSeconds: TimeInterval }`.
- `LocalDiarizationClient.diarize(audioURL:durationSeconds:progress:)`:
  - Arguments exactly: `--print-args=false`, `--clustering.cluster-threshold=0.3`, `--clustering.compute-confidence=true`, `--segmentation.num-threads=4`, `--embedding.num-threads=4`, `--segmentation.pyannote-model=<path>`, `--embedding.model=<path>`, `<audio path>`.
  - Environment: strip `HTTP_PROXY`/`HTTPS_PROXY`/`ALL_PROXY` and their lowercase forms.
  - A single shared pipe for stdout+stderr, drained through an `AsyncStream<Data>` from a `readabilityHandler`, split on `\n` and `\r`.
  - **Discard every line until the literal `Started`**, then parse turns; parse `progress` lines at any time.
  - Bound the retained diagnostic log at 100 KB, as `LocalWhisperClient` does.
  - `withTaskCancellationHandler { … } onCancel: { cancellation.cancel() }` and an armed exit stream created **before** `run()`.
  - On non-zero exit, `throw DiarizationOutputParser.classify(errorOutput:exitStatus:)`.
  - On success, `SpeakerTurns.validate(_:durationSeconds:)` then compute `speakerCount` as the number of distinct `clusterID`s.

- [ ] **Step 4: Run the tests and verify they pass**

Expected: PASS, 7 tests.

- [ ] **Step 5: Commit**

```bash
git add Sources/WhisperCore/LocalDiarizationClient.swift Tests/WhisperCoreTests/LocalDiarizationClientTests.swift
git commit -m "feat(diarization): add the cancellable local diarization subprocess client (F219)"
```

---

## Task 8: The sidecar store

**Files:**
- Create: `Sources/WhisperMeet/DiarizationArtifactStore.swift`
- Test: `Tests/WhisperMeetTests/DiarizationArtifactStoreTests.swift`

**Interfaces:**
- Consumes: `DiarizationArtifactV1`, `DiarizationArtifactCodec`, `DiarizationArtifactError` (Task 5)
- Produces: `DiarizationArtifactStore` with `load(meetingID:in:)`, `save(_:in:)`, `clear(meetingID:in:)`, `fileURL(meetingID:in:)`, `RecordingFingerprint.sha256(of:)`, `DiarizationLoadOutcome`

- [ ] **Step 1: Write the failing tests**

```swift
import Foundation
import Testing
@testable import WhisperCore
@testable import WhisperMeet

// F218 — this sidecar holds user-typed aliases, so unlike notes.md it is NOT best-effort. Corrupt
// bytes are quarantined before anything overwrites them, a newer schema is left alone, a changed
// recording makes the result stale, and a read-only library refuses every mutation.

private func makeRecording() throws -> (root: URL, meetingID: UUID, directory: URL) {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("DiarizationStore-\(UUID().uuidString)", isDirectory: true)
    let meetingID = UUID()
    let directory = root.appendingPathComponent("Recordings/\(meetingID.uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    try Data("audio".utf8).write(to: directory.appendingPathComponent("meeting.wav"))
    return (root, meetingID, directory)
}

private func makeArtifact(meetingID: UUID, recordingHash: String = "hash-1") -> DiarizationArtifactV1 {
    DiarizationArtifactV1(
        meetingID: meetingID,
        recording: DiarizationRecordingReference(
            relativePath: "Recordings/\(meetingID.uuidString)/meeting.wav",
            sha256: recordingHash,
            durationSeconds: 10
        ),
        transcriptTimingFingerprint: "abc",
        producer: DiarizationProducer(
            runtimeID: "sherpa-onnx", runtimeVersion: "1.13.8",
            segmentationModelSHA256: "seg", embeddingModelSHA256: "emb", clusterThreshold: 0.3
        ),
        createdAt: Date(timeIntervalSince1970: 1_700_000_000),
        turns: [SpeakerTurn(startSeconds: 0, endSeconds: 5, clusterID: 0, kind: .speech)],
        aliases: [:]
    )
}

@Test("A saved artifact loads back identically")
func storeRoundTripsAnArtifact() throws {
    let (root, meetingID, _) = try makeRecording()
    defer { try? FileManager.default.removeItem(at: root) }
    let artifact = makeArtifact(meetingID: meetingID)

    try DiarizationArtifactStore.save(artifact, in: root)
    let outcome = DiarizationArtifactStore.load(meetingID: meetingID, in: root)

    guard case let .ready(loaded) = outcome else {
        Issue.record("expected .ready, got \(outcome)")
        return
    }
    #expect(loaded == artifact)
}

@Test("Loading when no sidecar exists reports absent, not an error")
func storeReportsAbsence() throws {
    let (root, meetingID, _) = try makeRecording()
    defer { try? FileManager.default.removeItem(at: root) }
    #expect(DiarizationArtifactStore.load(meetingID: meetingID, in: root) == .absent)
}

@Test("Corrupt bytes are quarantined and the original is left in place")
func storeQuarantinesCorruptBytes() throws {
    let (root, meetingID, directory) = try makeRecording()
    defer { try? FileManager.default.removeItem(at: root) }
    let sidecar = directory.appendingPathComponent("diarization.json")
    let corrupt = Data("{ this is not json".utf8)
    try corrupt.write(to: sidecar)

    let outcome = DiarizationArtifactStore.load(meetingID: meetingID, in: root)

    guard case .unavailable = outcome else {
        Issue.record("expected .unavailable, got \(outcome)")
        return
    }
    // Preserved, not destroyed — the bytes may be the only copy of a user's aliases.
    #expect(try Data(contentsOf: sidecar) == corrupt)
    let siblings = try FileManager.default.contentsOfDirectory(atPath: directory.path)
    #expect(siblings.contains { $0.hasPrefix("diarization.unreadable-") })
}

@Test("A newer schema is preserved and never overwritten by a save")
func storeRefusesToClobberANewerSchema() throws {
    let (root, meetingID, directory) = try makeRecording()
    defer { try? FileManager.default.removeItem(at: root) }
    let sidecar = directory.appendingPathComponent("diarization.json")
    let future = Data(#"{"schemaVersion":99,"somethingNew":true}"#.utf8)
    try future.write(to: sidecar)

    let outcome = DiarizationArtifactStore.load(meetingID: meetingID, in: root)
    guard case .unavailable = outcome else {
        Issue.record("expected .unavailable, got \(outcome)")
        return
    }
    #expect(try Data(contentsOf: sidecar) == future)
}

@Test("A changed recording hash makes a loaded result stale rather than wrong")
func storeDetectsStaleAudio() throws {
    let (root, meetingID, _) = try makeRecording()
    defer { try? FileManager.default.removeItem(at: root) }
    try DiarizationArtifactStore.save(makeArtifact(meetingID: meetingID, recordingHash: "old"), in: root)

    let outcome = DiarizationArtifactStore.load(meetingID: meetingID, in: root, currentRecordingSHA256: "new")

    guard case .stale = outcome else {
        Issue.record("expected .stale, got \(outcome)")
        return
    }
}

@Test("Clearing removes only the sidecar and leaves the recording untouched")
func storeClearRemovesOnlyTheSidecar() throws {
    let (root, meetingID, directory) = try makeRecording()
    defer { try? FileManager.default.removeItem(at: root) }
    let wav = directory.appendingPathComponent("meeting.wav")
    let before = try Data(contentsOf: wav)
    try DiarizationArtifactStore.save(makeArtifact(meetingID: meetingID), in: root)

    try DiarizationArtifactStore.clear(meetingID: meetingID, in: root)

    #expect(!FileManager.default.fileExists(atPath: directory.appendingPathComponent("diarization.json").path))
    #expect(try Data(contentsOf: wav) == before)
}

@Test("A save never touches the audio, and a failed save leaves the previous artifact intact")
func storeSaveIsAtomicAndNonDestructive() throws {
    let (root, meetingID, directory) = try makeRecording()
    defer { try? FileManager.default.removeItem(at: root) }
    let wav = directory.appendingPathComponent("meeting.wav")
    let audioBefore = try Data(contentsOf: wav)
    try DiarizationArtifactStore.save(makeArtifact(meetingID: meetingID, recordingHash: "first"), in: root)
    let firstBytes = try Data(contentsOf: directory.appendingPathComponent("diarization.json"))

    try DiarizationArtifactStore.save(makeArtifact(meetingID: meetingID, recordingHash: "second"), in: root)

    let secondBytes = try Data(contentsOf: directory.appendingPathComponent("diarization.json"))
    #expect(secondBytes != firstBytes)
    #expect(try Data(contentsOf: wav) == audioBefore)
    // No temp file is left behind.
    let siblings = try FileManager.default.contentsOfDirectory(atPath: directory.path)
    #expect(!siblings.contains { $0.hasSuffix(".tmp") })
}

@Test("Saving into a missing recording directory fails rather than creating one")
func storeNeverCreatesARecordingFolder() throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("DiarizationStore-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let meetingID = UUID()

    #expect(throws: (any Error).self) {
        try DiarizationArtifactStore.save(makeArtifact(meetingID: meetingID), in: root)
    }
    #expect(!FileManager.default.fileExists(
        atPath: root.appendingPathComponent("Recordings/\(meetingID.uuidString)").path))
}

@Test("The recording fingerprint streams rather than loading the whole file")
func recordingFingerprintStreamsLargeFiles() throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("DiarizationHash-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let file = root.appendingPathComponent("big.bin")
    // Several chunks' worth, so the chunk boundary logic is actually exercised.
    try Data(repeating: 0xAB, count: 5_000_000).write(to: file)

    let digest = try RecordingFingerprint.sha256(of: file)

    #expect(digest.count == 64)
    #expect(digest == (try RecordingFingerprint.sha256(of: file)))
}
```

- [ ] **Step 2: Run the tests and verify they fail**

`--filter "store|recordingFingerprint"`. Expected: FAIL — `cannot find 'DiarizationArtifactStore' in scope`.

- [ ] **Step 3: Write the implementation**

Key requirements:

```swift
import CryptoKit
import Foundation
import WhisperCore

/// What a sidecar read produced. Distinguishing these is the whole point: "absent" offers analysis,
/// "stale" hides labels but keeps the file, and "unavailable" says the transcript is safe (F218).
public enum DiarizationLoadOutcome: Sendable, Equatable {
    case absent
    case ready(DiarizationArtifactV1)
    case stale
    case unavailable
}
```

- `fileURL(meetingID:in:)` → `<root>/Recordings/<uuid>/diarization.json`.
- `load` reads the bytes; on `DiarizationArtifactError.unreadable` or `.malformed`, calls `StoreQuarantine.preserve(fileAt:using:)` (copy, never move) and returns `.unavailable`; on `.newerSchema`, returns `.unavailable` **without** quarantining or rewriting; on success compares `currentRecordingSHA256` when supplied and returns `.stale` on mismatch.
- `save` requires the recording directory to already exist (never create one — `InterruptedRecordingRecovery.removeIfEmpty` only removes a *completely empty* folder, so a sidecar written into an in-progress folder would strand it); writes with `Data.write(options: .atomic)`.
- `RecordingFingerprint.sha256(of:)` uses `FileHandle` + `SHA256()` incrementally in 1 MiB chunks — never `Data(contentsOf:)`, which would try to load a multi-GB WAV into memory.
- Degraded-library refusal lives in `AppModel` (Task 9), which owns the `MeetingStore`; this type stays a pure file helper so it is testable without a store.

- [ ] **Step 4: Run the tests and verify they pass**

Expected: PASS, 9 tests.

- [ ] **Step 5: Commit**

```bash
git add Sources/WhisperMeet/DiarizationArtifactStore.swift Tests/WhisperMeetTests/DiarizationArtifactStoreTests.swift
git commit -m "feat(diarization): add the durable, quarantining diarization.json sidecar store (F218)"
```

---

## Task 9: AppModel seam, guards, and cancellation

**Files:**
- Modify: `Sources/WhisperMeet/AppModel.swift`
- Test: `Tests/WhisperMeetTests/DiarizationWiringTests.swift`, `Tests/WhisperMeetTests/DiarizationGuardTests.swift`

**Interfaces:**
- Consumes: everything from Tasks 2–8
- Produces: `SpeakerDiarizationRequest`, `AppModel.runSpeakerDiarization`, `.requestSpeakerDiarization(for:)`, `.cancelSpeakerDiarization()`, `.clearSpeakerDiarization(for:)`, `.renameSpeaker(clusterID:to:in:)`, `.speakerOverlay(for:)`, `.diarizationRunningID`, `.diarizationProgress`, `SpeakerOverlayPresentation`

- [ ] **Step 1: Write the failing tests**

Follow `CorrectionWiringTests.swift` exactly for the model fixture. Cover:

1. `requestSpeakerDiarization` threads the audio URL and duration through the seam and writes a sidecar whose overlay reaches `speakerOverlay(for:)`.
2. The seam is **not** called while `hasActiveTranscription`, while `isRunningAuxiliaryEngine`, while dictation is active, while an installer runs, or when `store.isDegraded` — five separate tests, each asserting a seam-call counter stayed at zero and `model.alertMessage` explains why.
3. Cancellation: `cancelSpeakerDiarization()` during a run leaves the transcript, the segments, and the audio bytes unchanged and writes **no** sidecar.
4. A failing seam leaves the transcript unchanged, sets `alertMessage`, and writes no sidecar.
5. `renameSpeaker` changes only the alias in the sidecar; the turns, the audio, and `transcriptText` are byte-identical afterwards.
6. `clearSpeakerDiarization` deletes the sidecar and leaves audio and transcript untouched.
7. A rerun replaces the artifact and **drops the previous aliases** (cluster ids permute across runs, so carrying an alias over would silently mislabel).
8. `speakerOverlay(for:)` returns `nil` when the transcript timing fingerprint no longer matches.

Use the byte-comparison immutability idiom from `SegmentRerunWiringTests.swift:51-52,67-69`:

```swift
let wavBefore = try Data(contentsOf: wavURL)
// … run …
#expect(try Data(contentsOf: wavURL) == wavBefore)
```

- [ ] **Step 2: Run the tests and verify they fail**

`--filter "diarization"`. Expected: FAIL — `value of type 'AppModel' has no member 'requestSpeakerDiarization'`.

- [ ] **Step 3: Write the implementation**

```swift
/// What the diarization seam needs. Deliberately not the MeetingRecord: the runtime gets a path and
/// a duration, never the transcript, the title, or anything else about the meeting.
struct SpeakerDiarizationRequest: Sendable {
    let meetingID: UUID
    let audioURL: URL
    let durationSeconds: TimeInterval
}
```

On `AppModel`:

- `var runSpeakerDiarization: @Sendable (SpeakerDiarizationRequest, @Sendable @escaping (Double) async -> Void) async throws -> SpeakerDiarizationResult`, defaulting to a closure that prepares a 16 kHz mono temp WAV with `AudioTranscoder.needsTranscoding` / `transcodeToWAV` into a per-run temp **directory** removed by `defer`, then calls `LocalDiarizationClient`.
- `@Published private(set) var diarizationRunningID: UUID?` and `@Published private(set) var diarizationProgress: Double?` — scoped per meeting, following `secondOpinionRunningID` (F156) and `proposingCorrectionsID` (F173), so another meeting's view never shows this run as its own.
- `private var diarizationTask: Task<Void, Never>?`.
- `requestSpeakerDiarization(for:)` guards in this order, each with its own `alertMessage`: `diarizationRunningID == nil` → `!hasActiveTranscription` → `!isRunningAuxiliaryEngine` → `!isDictationActive()` → `!isInstallingRecognitionRuntime && !isInstallingDiarizationRuntime` → `libraryAcceptsChanges("Speaker analysis")` → `isDiarizationInstalled` → the meeting is completed, native, and has usable timings.
- Claim `isRunningAuxiliaryEngine = true` alongside `diarizationRunningID`, so transcription and second opinion refuse to start — and clear both in the task epilogue.
- On success: compute the recording SHA-256 and the timing fingerprint, build the artifact, `DiarizationArtifactStore.save`. Only a complete valid result is persisted.
- `catch is CancellationError` → clear state, write nothing, no alert.
- `speakerOverlay(for:)` returns a `SpeakerOverlayPresentation { rows, clusterIDs, aliases, isStale, isSingleCluster }`, recomputed from current segments, and caches by `(meetingID, timingFingerprint)` so the 4 Hz playback tick never recomputes it (the F160 lesson).
- **Single-cluster suppression.** When `SpeakerOverlay.clusterIDs(in:)` yields fewer than two clusters, set `isSingleCluster` and return every row as `.unlabeled`. Rename must be unavailable in that state — there is nothing safe to name. Test it: a result whose turns all carry one cluster produces no labelled rows and `isSingleCluster == true`.

- [ ] **Step 4: Run the tests and verify they pass**

Expected: PASS, ~12 tests.

- [ ] **Step 5: Commit**

```bash
git add Sources/WhisperMeet/AppModel.swift Tests/WhisperMeetTests/DiarizationWiringTests.swift Tests/WhisperMeetTests/DiarizationGuardTests.swift
git commit -m "feat(diarization): guard and wire speaker analysis through an injected AppModel seam (F219)"
```

---

## Task 10: The installer script and notices

**Files:**
- Create: `Scripts/setup-speaker-diarization.sh`, `Resources/THIRD-PARTY-NOTICES.txt`
- Modify: `Scripts/build-app.sh`
- Test: `Tests/WhisperCoreTests/DiarizationInstallerScriptShapeTests.swift`

Build it from the `Scripts/setup-qwen-asr.sh` skeleton and the installer contract in `docs/DIARIZATION_RUNTIME_DECISION.md` §6. The download half stays untested by design, so every ordering and rollback invariant must be expressible without a network — exactly the two-way contract `LinkImportScriptShapeTests` and `QwenInstallerRecoveryTests` already establish.

- [ ] **Step 1: Write the failing tests**

Shape assertions against the script text (byte-offset ordering), plus a real execution of the `DIARIZATION_INSTALL_RECOVERY_ONLY=1` branch over a temp directory seeded with fake runtimes, asserting the backup is promoted, incomplete orphans are purged, and the lock file is gone. Also assert `build-app.sh` copies both the script and the notices file, and that the pinned hashes in the script match the constants in `DIARIZATION_RUNTIME_DECISION.md`.

- [ ] **Step 2: Run and verify they fail**

- [ ] **Step 3: Write the script**

Required ordering: recovery guard → platform gate → notices-present gate → lock → reclaim → (recovery exits here) → disk check → download → sha256 gate → extract → per-file sha256 gate → prune → GPL symbol gate (`nm -a … | grep -qE '_espeak[A-Za-z_]*'` — a plain `grep -i espeak` false-positives on "spe**aker**") → offline symbol gate → notices copy → MANIFEST → silence smoke test → atomic activation with rollback.

- [ ] **Step 4: Run the tests and verify they pass**

- [ ] **Step 5: Commit**

```bash
git add Scripts/setup-speaker-diarization.sh Resources/THIRD-PARTY-NOTICES.txt Scripts/build-app.sh Tests/WhisperCoreTests/DiarizationInstallerScriptShapeTests.swift
git commit -m "feat(diarization): add the pinned, verifying speaker-model installer (F219)"
```

---

## Task 11: Install wiring and startup reclaim

**Files:**
- Modify: `Sources/WhisperMeet/AppModel.swift`
- Test: `Tests/WhisperMeetTests/DiarizationInstallWiringTests.swift`

Mirror `installQwenASR` exactly: compound busy guard, arch gate, `Bundle.main.url(forResource:withExtension:)` resolution with the `developmentScriptURL` fallback, optimistic flag, detached runner writing to `diarization-install.log`, then **verify by re-probing the filesystem** (`refreshRuntime()` → `isDiarizationInstalled`), never by exit status alone. Add `reclaimInterruptedDiarizationInstall()` behind an injectable seam, called from `performStartupRecovery()` before `refreshRuntime()`.

- [ ] Step 1: failing tests (seam counter proves the reclaim runs only when orphan artifacts exist; install refuses while busy)
- [ ] Step 2: run, verify red
- [ ] Step 3: implement
- [ ] Step 4: run, verify green
- [ ] Step 5: `git commit -m "feat(diarization): install, verify, and self-heal the speaker runtime (F219)"`

---

## Task 12: Labeled export, and proof the defaults stay clean

**Files:**
- Modify: `Sources/WhisperCore/TranscriptExporter.swift`
- Test: `Tests/WhisperCoreTests/DiarizationExportTests.swift`

**Interfaces:**
- Produces: `TranscriptExportFormat.labeledText`, `.labeledMarkdown`, `TranscriptExportFormat.standardFormats`, `TranscriptExportRequest.speakerLabels`

- [ ] **Step 1: Write the failing tests**

The load-bearing test is the isolation one:

```swift
@Test("Every standard export format stays label-free even when the request carries labels")
func standardExportsNeverCarrySpeakerLabels() {
    let segments = [
        TranscriptSegment(speaker: nil, start: 0, end: 5, text: "first line"),
        TranscriptSegment(speaker: nil, start: 5, end: 10, text: "second line")
    ]
    let request = TranscriptExportRequest(
        title: "M", languageCode: "en", durationSeconds: 10,
        transcriptText: TranscriptFormatter.timestamped(segments),
        segments: segments, markers: [],
        speakerLabels: [0: "Nadia", 1: "Speaker 2"]
    )
    for format in TranscriptExportFormat.standardFormats {
        let rendered = TranscriptExporter.render(format, request)
        #expect(!rendered.contains("Nadia"), "\(format) leaked an alias")
        #expect(!rendered.contains("Speaker 2"), "\(format) leaked a cluster label")
    }
}

@Test("The standard format list excludes the labeled formats")
func labeledFormatsAreNotOfferedAsOrdinaryExports() {
    #expect(!TranscriptExportFormat.standardFormats.contains(.labeledText))
    #expect(!TranscriptExportFormat.standardFormats.contains(.labeledMarkdown))
    #expect(TranscriptExportFormat.standardFormats.count == 9)
}

@Test("A labeled export marks an alias as user-assigned rather than recognized")
func labeledExportMarksAliasesAsUserAssigned() {
    // … render .labeledMarkdown and assert the header explains the labels are inferred, anonymous,
    // and that any name was typed by the reader — never "recognized" or "identified".
}
```

Plus: labels only appear for segments the overlay actually labeled; uncertain and overlapping segments render their own words; an unlabeled segment renders with no prefix at all.

- [ ] **Step 2: Run and verify they fail**
- [ ] **Step 3: Implement**

Add `speakerLabels: [Int: String]?` to `TranscriptExportRequest` (defaulted `nil`, so no call site breaks) and a separate `[SpeakerOverlayRow]` carried alongside. Add the two cases and a `static let standardFormats: [TranscriptExportFormat]` listing exactly the nine existing ones. Change `ContentView`'s export menu `ForEach` from `allCases` to `standardFormats` in Task 13.

- [ ] **Step 4: Run and verify they pass**
- [ ] **Step 5:** `git commit -m "feat(diarization): add labeled export formats and prove the defaults stay unlabeled (F220)"`

---

## Task 13: Entry point, disclosure, and the install row

**Files:**
- Modify: `Sources/WhisperMeet/ContentView.swift`

- [ ] **Step 1: Add the Improve-menu entry**

In `improveMenu` (ContentView.swift:2825-2913), after the `Second Opinion` item, add a `Divider()` and:

```swift
Button {
    confirmDiarization = true
} label: {
    Label("Analyze Speaker Turns…", systemImage: "person.wave.2")
}
.disabled(
    model.diarizationRunningID != nil
        || model.isRunningAuxiliaryEngine
        || model.hasActiveTranscription
        || !meeting.hasUsableTimings
)
```

Extend the trailing footnote block with the matching plain-language reasons: no usable timestamps, analysis already running, model not installed.

- [ ] **Step 2: Add the first-run disclosure**

An `.alert` in the `TranscriptDetailView` modifier chain, next to the existing `confirmSummarize` one — but stating the opposite boundary:

```swift
.alert("Analyze speaker turns?", isPresented: $confirmDiarization) {
    Button("Cancel", role: .cancel) {}
    Button("Analyze") { model.requestSpeakerDiarization(for: meetingID) }
} message: {
    Text("WhisperMeet will label parts of this transcript with anonymous labels such as “Speaker 1”, using a model on this Mac. It does not identify people, and analysis can be wrong — especially when voices overlap. Your recording and transcript are not changed.")
}
```

- [ ] **Step 3: Add the Settings install row**

Beside the Qwen row (ContentView.swift:1297-1344), same shape: architecture gate, `Install`/`Repair or Update` button, the same compound `.disabled`, an indeterminate `ProgressView("Installing about 60 MB…")`, and disclosure copy naming the publisher, the size, the storage location, and that **only model files are downloaded — never meeting content**.

- [ ] **Step 4: Switch the export menu to the standard list**

Change `ForEach(TranscriptExportFormat.allCases, id: \.self)` to `ForEach(TranscriptExportFormat.standardFormats, id: \.self)`, and add a separate `Button("Transcript with Speaker Labels (.md)")` below a `Divider()`, shown only when an overlay exists.

- [ ] **Step 5: Build and commit**

```bash
swift build --disable-sandbox -c release -Xswiftc -warnings-as-errors
git add Sources/WhisperMeet/ContentView.swift
git commit -m "feat(diarization): add the analyze entry point, disclosure, and install row (F220)"
```

---

## Task 14: The review surface

**Files:**
- Modify: `Sources/WhisperMeet/ContentView.swift`, `Sources/WhisperCore/AccessibilityPhrase.swift`
- Test: `Tests/WhisperCoreTests/AccessibilityPhraseTests.swift` (extend)

- [ ] **Step 1: Add the VoiceOver phrase**

In `AccessibilityPhrase.swift`, which already carries the rule "never implies identified speakers (F71)":

```swift
/// Reads an anonymous cluster label. Always says "inferred" — the label is a guess about voices,
/// never a claim about a person (F220).
public static func speakerLabel(_ label: String, offset: TimeInterval, text: String) -> String {
    "\(label), inferred, \(TranscriptFormatter.timestamp(offset)), \(text)"
}
```

Test it says "inferred" and never "recognized"/"identified".

- [ ] **Step 2: Render the label in the transcript row**

In `segmentRow` (ContentView.swift:4036-4094), between the timestamp column and the text, add a fixed-width label column shown only when an overlay exists — matching `metadataChip`'s quiet register (`.font(.callout)`, `.foregroundStyle(.secondary)`, `.padding(.horizontal, 9)/.padding(.vertical, 3)`, `.background(.quaternary.opacity(0.5), in: Capsule())`). Text, never colour alone. Precompute `labelsByIndex: [Int: String]` in `init`/`.task`, never in the row body — the F160 rule.

- [ ] **Step 3: Add the legend**

Above the transcript scroll view, matching `qualityReviewBanner`'s shape (`HStack(spacing: 8)`, `.padding(10)`, `.bannerSurface(.blue)`): the cluster list in first-appearance order, a "labels are inferred, not identified" sentence, and `Rename…` / `Clear` / `Analyze Again` buttons.

- [ ] **Step 4: Rename, clear, rerun**

Rename is an inline-`TextField` alert, matching the marker-rename pattern at ContentView.swift:3916-3930, with the field labeled **"Your label"** — never "name" or "who". Clear uses a `.confirmationDialog` with a `role: .destructive` verb and a `Keep labels` cancel. Rerun states plainly that new labels are created and existing ones are replaced.

- [ ] **Step 5: The states**

Render each PRD state distinctly: analyzing (progress + Cancel), stale (labels hidden + explanation), unavailable (plain reason + the transcript is safe), no turns found, model missing, and **only one voice distinguished**.

The single-voice state is not an error and must not read like one. Wording along the lines of: *"Only one voice could be told apart in this recording, so no speaker labels are shown. This happens with a single speaker, and also when two people's voices sound alike."* Offer Analyze Again and Clear; do not offer Rename.

- [ ] **Step 5b: Say what the limitation actually is**

The legend and the first-run disclosure must both state that voices which sound similar may be merged into one label — this is the runtime's measured weakness, not a hypothetical. Do not bury it in documentation only. A person who is told this up front reads a wrong label as a known limitation; a person who is not reads it as a fact about who spoke.

- [ ] **Step 6: Build and commit**

```bash
swift build --disable-sandbox -c release -Xswiftc -warnings-as-errors
git add Sources/WhisperMeet/ContentView.swift Sources/WhisperCore/AccessibilityPhrase.swift Tests/WhisperCoreTests/AccessibilityPhraseTests.swift
git commit -m "feat(diarization): add the anonymous-label review surface and accessibility phrasing (F220)"
```

---

## Task 15: The synthetic corpus generator

**Files:**
- Create: `Scripts/bench/diarization/generate_corpus.py`, `Scripts/bench/diarization/manifest.json`
- Test: `Scripts/tests/test_generate_corpus.py`
- Modify: `.gitignore` (generated WAVs), `Scripts/quality-check.sh` (run the new test)

Manifest-driven. Each fixture records generator version, voices, exact WAV sha256, reference turns, overlap intervals, sample rate, and mix offsets. WAVs are generated locally and **gitignored**; only the manifest and hashes are committed, so nothing is redistributed.

Required strata: English, Mandarin, code-switching; 1/2/3/4+ voices; alternating, rapid, long turns; silence; music/no-speech; noise; controlled overlap; two-track mixes with presentation offsets; a deterministic 30-minute sentinel; and the failure fixtures (no timestamps, corrupt sidecar, missing audio).

Ground truth is concatenation arithmetic, not estimation: build each part with `say -o`, read its exact duration with `afinfo`, energy-trim, then concatenate with a known silence gap.

- [ ] Steps 1-5 as usual; commit `"feat(diarization): add the manifest-driven synthetic diarization corpus (F217)"`

---

## Task 16: The DER/JER scorer

**Files:**
- Create: `Scripts/bench/diarization/score_diarization.py`
- Test: `Scripts/tests/test_score_diarization.py`
- Modify: `Scripts/quality-check.sh`

Implement per `docs/DIARIZATION_RUNTIME_DECISION.md` and the pyannote.metrics definitions: elementary-segment timeline at every boundary, speaker-weighted `Σ d·N_ref` denominator, global Hungarian mapping with zero-co-occurrence pairs dropped, full-width collar, micro-averaging, and both scoring conventions reported (no-collar/overlap-scored **and** 0.25 s collar/overlap-excluded).

**The scorer must be validated against pyannote's golden vector before it is trusted:** `total=31 correct=22 miss=2 fa=7 conf=7 DER=16/31`. A hand-written DER is silently wrong in a dozen ways; this test is what makes the number mean anything.

Also report displayed-label precision and coverage *after* `SpeakerOverlay`'s reconciliation, plus the percentage intentionally abstained — the numbers that describe what a person actually sees.

- [ ] Steps 1-5; commit `"feat(diarization): add a golden-vector-validated DER/JER scorer (F217)"`

---

## Task 17: Run the gate

**Files:**
- Create: `docs/DIARIZATION_SCORECARD.md`
- Modify: `Sources/WhisperCore/LocalDiarizationClient.swift` (the derived confidence floor), `docs/CHANGELOG.md`, `docs/TICKETS.md` → `docs/TICKET_LOG.md`

- [ ] **Step 1: Generate the corpus and run the scorecard**

Record per-stratum DER/JER, components, speaker-count error, boundary precision/recall, displayed-label precision/coverage/abstention, cold and warm RTF, wall time, peak RSS, and three-run determinism.

- [ ] **Step 2: Derive the confidence floor from data, not intuition**

Measure the runtime's per-turn `confidence` on the same-gender fixtures where it absorbs a speaker, and on the clean fixtures. Choose `DiarizationRuntime.uncertainBelowConfidence` as the value that abstains on the absorbed turns while keeping the clean ones labeled; record the before/after table. If no value separates them, set it to `0` and say plainly in the scorecard that confidence does not predict this failure.

- [ ] **Step 3: Run the full gate**

```bash
git add -A && ./Scripts/quality-check.sh
```

All five steps must pass. Confirm the Swift test count went **up**, not down.

- [ ] **Step 4: Record the evidence and close the tickets**

Write `docs/DIARIZATION_SCORECARD.md` with the real numbers, a CHANGELOG entry in the existing voice, and append F216–F221 closures to `docs/TICKET_LOG.md` with real command output — the failing-before and passing-after lines, the build, and the real-model run. Any gate that cannot be met from here (manual VoiceOver, keyboard, Dynamic Type, and the blinded value study in the installed app) closes `partial` and is named explicitly, not quietly omitted.

- [ ] **Step 5: Commit**

```bash
git add -A
git commit -m "docs(diarization): record the speaker-analysis scorecard and beta evidence (F221)"
```

---

## Self-review

**Spec coverage.** PRD §Goals 1-6 → Tasks 9, 14, 4, 14, 12, 16-17. §Non-goals → enforced by the Global Constraints and asserted in Tasks 9 and 12. §States table → Task 14 Step 5. §Hard privacy rules 1-7 → Tasks 5 (no voice data in the artifact), 7 (no network), 9 (temp dir removed by `defer`), 12 (no label leak), and the Task 1 policy text. §Artifact envelope → Task 5. §Reconciliation policy 1-5 → Task 4. §AppModel seam → Task 9. §Evidence plan → Tasks 15-17. §Delivery phases 0-4 → Tasks 1, 2-8, 9-11, 12-14, 15-17.

**Known gap, carried deliberately:** the PRD's §Evidence-plan "Python Community-1 lab control" is not built. The quality gate's "within three absolute DER points of that control" therefore has no control to compare against. Task 17 must state this plainly in the scorecard rather than quietly scoring against nothing.

**Type consistency.** `SpeakerTurnKind` is `.speech`/`.overlap`/`.uncertain` in Tasks 2 and 4 — but **Task 6 never constructs `.overlap`**, and an earlier draft of this line claimed it did. `DiarizationOutputParser.densify` is the only production constructor of a `SpeakerTurn`, and the selected runtime emits one speaker per line with no simultaneity marker, so densify has nothing to copy and produces `.speech`/`.uncertain` only. The consequence is that Task 4's overlap veto (PRD reconciliation rule: "an overlap anywhere in the segment vetoes a name") is implemented and tested but **unreachable in production** — genuine simultaneous speech arrives as two intersecting `.speech` turns, passes through unmarked, and the overlay may name one of them. Deriving `.overlap` from intersecting raw turns is interval splitting with its own failure modes; it is deferred to **F223** rather than improvised, and `overlayVetoIsUnreachableFromRuntimeOutput` pins the gap so the veto cannot read as live. `SpeakerOverlayLabel` is `.speaker(clusterID:)`/`.overlapping`/`.uncertain`/`.unlabeled` — `.unlabeled` rather than `.none`, which would collide with `Optional.none`. `aliases` is `[String: String]` in the artifact (JSON keys must be strings) but `[Int: String]` in `TranscriptExportRequest.speakerLabels`, where it never touches JSON; Task 9 converts between them. `DiarizationArtifactCodec.decode` takes only `Data` — an earlier draft threaded an `expectedDuration`, but the artifact carries its own duration, so the parameter was removed.
