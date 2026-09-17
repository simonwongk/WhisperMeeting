# 👥 Speaker diarization — product requirements and delivery plan

## Decision at a glance

This document proposes an **optional, post-meeting, entirely local speaker-turn analysis** for WhisperMeet. It is a decision-ready plan, not an implementation authorization and not a change to the current product policy.

The proposed first release labels portions of a completed transcript with anonymous, per-meeting clusters such as **Speaker 1** and **Speaker 2**. A person may rename a cluster for that one meeting, but WhisperMeet never infers, enrolls, verifies, or remembers a person's real identity. It never matches voices across meetings, sends speaker data to Claude, or offers a cloud fallback.

The technical recommendation is to evaluate an offline Core ML implementation of a Community-1-style pipeline through FluidAudio first, with sherpa-onnx as the native fallback and the official Python Community-1 pipeline as a research control. No candidate is selected for shipping until it clears the legal, privacy, offline, quality, performance, recovery, and accessibility gates in this PRD.

> **Superseded twice on 2026-09-13, and the PRD's original instinct was right (F216).** First, under a no-third-party-dependency constraint, a pinned native `sherpa-onnx` binary was selected over FluidAudio. That runtime then failed real-meeting validation — 33 to 179 speaker clusters on a single 35-minute meeting, at no setting. The product owner lifted the dependency constraint, FluidAudio's offline VBx path was measured on the same audio (4 clusters, 615 MB, 352x real time, bit-deterministic), and **FluidAudio is the adopted runtime**. The PRD named it first choice for precisely the reason it won: VBx models within-speaker variability across a long recording, which simple agglomerative clustering cannot. The reasoning, per-artifact licences, pinned hashes, and offline evidence are in [`DIARIZATION_RUNTIME_DECISION.md`](DIARIZATION_RUNTIME_DECISION.md). One further correction: the `pip` distribution of sherpa-onnx statically links espeak-ng (GPL-3.0) and must not be shipped.

**Current-policy status.** **Approved 2026-09-13.** The amendment in [Required decision](#required-decision-before-implementation) was accepted and `AGENTS.md`, `docs/PRODUCT_SPEC.md`, `docs/ROADMAP.md`, `docs/CHANGELOG.md` and the end-user `README.md` were changed together in the F216 commit. Two boundaries were deliberately *not* relaxed: ASR segments are still never presented as identified speakers, and imported third-party captions still have speaker labels stripped before a segment is constructed.

## Problem statement

WhisperMeet makes meeting recordings searchable and readable, but a person reading a long transcript cannot reliably answer “who said this?” The app retains separate microphone and system-audio tracks as useful capture provenance for a future local analysis feature, yet those tracks must not be treated as people:

- A system track can contain several remote participants.
- Headphones, speakerphone echo, and microphone bleed can put the same voice on both tracks.
- A local microphone can contain more than one nearby speaker.
- Imported audio usually has no WhisperMeet source tracks at all.

Treating a channel as a person would manufacture an identity claim rather than analyze speech. Likewise, using ordinary ASR timestamps as speaker labels would create a confident-looking but unsupported result.

The feature therefore has a narrow purpose: make a *completed*, timed transcript easier to navigate with cautious, anonymous voice-turn attribution. It must preserve the recording as the source of truth and preserve the original ASR text and timestamps even if analysis is wrong, cancelled, unsupported, or unavailable.

## Goals, non-goals, and vocabulary

### Goals

1. Let a person explicitly ask WhisperMeet to analyze speaker turns for one eligible completed meeting, wholly on that Mac.
2. Display useful anonymous labels where the model has a sufficiently unambiguous time overlap with an ASR segment.
3. Make uncertainty, overlap, no-speech, missing timestamps, and failure visible rather than inventing a single speaker.
4. Let a person give a cluster a local, per-meeting alias such as “Me” or “Project lead.”
5. Keep canonical audio, source tracks, ASR text, ASR timestamps, ordinary exports, search, notes, and both local and Claude summaries unchanged by default.
6. Prove the result with a repeatable, licensed synthetic benchmark and real-installed-model validation before release.

### Non-goals for the first release

- Identifying a person, verifying a claimed person, face/voice matching, enrollment, or a persistent voiceprint.
- Sharing an alias, embedding, diarization turn, audio, or transcript with a network service.
- Real-time diarization while a meeting is recording or dictation is active.
- Replacing Whisper or Qwen ASR, changing language detection, translating text, or changing the canonical transcript.
- A library-wide “analyze everything” action.
- Treating microphone/system tracks as “me” and “everyone else.”
- Automatic speaker labels in default copy, notes, search, exports, diagnostics, or summaries.
- Detailed manual turn editing in the initial shipping slice. A person can rename a cluster, clear labels, or rerun analysis; split/merge/reassign editing is a separately evaluated future feature.

### Terms used consistently

| Term | Meaning | It does **not** mean |
|---|---|---|
| **Diarization** | Estimating which anonymous voice cluster spoke at a time. | Identifying a human being. |
| **Cluster** | A model-local ID such as <code>spk-01</code>, scoped to one result. | A durable person profile. |
| **Alias** | Text typed by the person for one cluster in one meeting. | A verified, inferred, or cross-meeting name. |
| **Turn** | A time interval emitted by the diarizer. | An ASR sentence or immutable transcript segment. |
| **Overlay** | A display-only reconciliation of turns with transcript segments. | A mutation of TranscriptSegment or transcriptText. |
| **Overlap** | More than one voice may be active in an interval. | Permission to choose a dominant speaker silently. |

## Product context and verified codebase facts

The app has the right *recording* foundation, but not a ready-made diarization feature.

| Existing seam | Verified behavior | Consequence |
|---|---|---|
| Capture | AudioCaptureEngine writes separate Float32 microphone/system tracks, aligns them by presentation time, mixes a canonical meeting.wav, and saves source-tracks.json. [AudioCaptureEngine.swift](../Sources/WhisperMeet/AudioCaptureEngine.swift:430) | Analyze the canonical mixed recording first. Retained tracks are benchmark inputs and provenance only, never identity shortcuts. |
| Transcript model | TranscriptSegment has optional speaker, but its identity includes that field and current producers write nil. [TranscriptModels.swift](../Sources/WhisperCore/TranscriptModels.swift:162) | Do not write diarization labels into canonical segments; a segment rerun could erase or stale them. |
| Existing display/export | Read mode and TranscriptFormatter render timestamp/text, while ordinary exporters omit speaker data. [ContentView.swift](../Sources/WhisperMeet/ContentView.swift:4037) [TranscriptExporter.swift](../Sources/WhisperMeet/TranscriptExporter.swift:232) | Preserve this safe default. Any labeled export is a separate, affirmative action. |
| ASR engines | Whisper emits timestamped segments; Qwen alignment can fail while preserving complete text. [LocalWhisperClient.swift](../Sources/WhisperCore/LocalWhisperClient.swift:172) [AppModel.swift](../Sources/WhisperMeet/AppModel.swift:1901) | Analysis needs usable timings. If absent, keep text and show unavailable—never manufacture alignment. |
| Summary boundary | Claude summarization receives canonical meeting.transcriptText. [AppModel.swift](../Sources/WhisperMeet/AppModel.swift:1697) | Aliases and labels must stay outside this path. |
| Persistence | meetings.json is a shared wire format; the project requires append-only fields, bidirectional compatibility, and quarantine on unreadable data. [Library-index postmortem](./LIBRARY_INDEX_WIPE_POSTMORTEM_2026-08-14.md:20) | A versioned derived sidecar is safer than a rich diarization graph in MeetingRecord. |
| Lifecycle guard | AppModel already serializes transcription and protects degraded-library states. [AppModel.swift](../Sources/WhisperMeet/AppModel.swift:485) | A diarization job needs its own guard and yields to recording, transcription, dictation, installation, and degraded storage. |

## Research and candidate decision

### What the research establishes

The official Community-1 model operates on 16 kHz mono audio, supports fully local use after staging, and supplies an exclusive diarization output intended to reconcile diarization with ASR timestamps. Its benchmark results vary substantially by corpus—from 8.9% DER on REPERE to 44.6% on AVA-AVD—so a vendor number is not a product-quality promise for WhisperMeet meetings. The original artifact also requires accepting access conditions and providing a Hugging Face token for download. [pyannote Community-1 model card](https://huggingface.co/pyannote/speaker-diarization-community-1)

FluidAudio is the leading **candidate**, not a dependency commitment. Its offline Swift/Core ML pipeline uses Community-1-style segmentation, WeSpeaker embeddings, and VBx clustering; its file API is designed for memory-mapped processing. Its model card declares 16 kHz mono input, timestamped anonymous IDs, Apple Neural Engine optimization, CC-BY-4.0 model terms, while the SDK is Apache-2.0. It documents staged local-model loading that avoids a runtime downloader. [FluidAudio offline API](https://github.com/FluidInference/FluidAudio) [FluidAudio model card](https://huggingface.co/FluidInference/speaker-diarization-coreml) [FluidAudio offline staging](https://github.com/FluidInference/FluidAudio/blob/main/Documentation/Diarization/GettingStarted.md)

That does not eliminate risk. Its public issue tracker documents a case where automatic clustering and an explicitly known speaker count produced materially different partitions on the same audio. WhisperMeet should neither expose a “known people” shortcut nor trust a third-party default without a fixed regression corpus. [FluidAudio issue #801](https://github.com/FluidInference/FluidAudio/issues/801)

sherpa-onnx is the strongest fallback: it has a documented local diarization API and an official Swift example, with a segmentation + embedding + clustering architecture. Its model guide demonstrates 16 kHz mono input. The runtime’s Apache-2.0 license alone, however, is not a model redistribution grant; every converted segmentation and embedding artifact needs separate evidence. [sherpa-onnx API](https://k2-fsa.github.io/sherpa/onnx/c-api/html/speaker_diarization.html) [Swift example](https://github.com/k2-fsa/sherpa-onnx/blob/master/swift-api-examples/speaker-diarization.swift) [model guide](https://k2-fsa.github.io/sherpa/onnx/speaker-diarization/models.html)

Qwen is not a diarizer. Qwen3-ASR’s official scope is ASR, language identification, timestamps, and forced alignment; WhisperMeet’s pinned helper returns text and ASR timing, not speaker turns. A diarizer must run after ASR over local audio, then reconcile its result without changing ASR content. [Qwen3-ASR](https://github.com/QwenLM/Qwen3-ASR)

Cloud diarization is rejected. The higher-quality hosted precision-2 path explicitly runs on pyannote’s servers, which conflicts with WhisperMeet’s local-only recording/transcription boundary. [pyannote Community-1 model card](https://huggingface.co/pyannote/speaker-diarization-community-1)

### Candidate matrix

| Candidate | Why evaluate it | Why it is not automatically approved | Role |
|---|---|---|---|
| **FluidAudio offline Core ML** | Native Swift package, Apple-platform focus, staged models, post-meeting/offline pipeline, published benchmark harness. | Third-party API/model conversion and clustering behavior need an exact pin, security review, legal notices, and WhisperMeet-specific English/Mandarin/overlap validation. | **First technical spike.** Preferred only if every gate passes. |
| **sherpa-onnx offline pipeline** | Native C/C++/Swift route, transparent modular components, documented local API and Swift example. | More integration/packaging work; quality and model licensing must be established on supported Macs. | **Fallback spike** if FluidAudio fails a gate or cannot be shipped responsibly. |
| **Official Python Community-1** | Direct official reference, exclusive output, published benchmark table. | Token-gated artifact, Python/PyTorch runtime, no official Apple Neural Engine deployment path; poor frictionless installer UX. | **Lab control only.** Use isolated developer environments and synthetic/licensed test audio. |
| **Qwen/MLX helper reuse** | Some users already have Qwen installed. | It is ASR/alignment, not a diarization contract; changing its pinned venv risks ASR drift. | **Rejected.** |
| **Hosted diarization** | May improve benchmark scores. | Sends voice-derived data off-device. | **Rejected.** |

### Selection rule

F216 may select a runtime only after a fixed source revision and exact artifact hashes show all of the following:

1. The runtime, each model artifact, conversion, and bundled notice have documented redistribution-compatible terms and attribution.
2. The installer downloads only declared model data after an explicit user action; it never downloads executable code at runtime.
3. A normal analysis run makes no network request after installation, even when a model is missing or malformed.
4. It produces bounded, validated turns on English, Mandarin, code-switching, two-track, long-form, noise, and overlap fixtures.
5. It is cancellable, resource-bounded, repeatable over three identical runs, and stable in an installed app on supported Macs.
6. It passes every preservation, degraded-library, corruption, and label-leak test below.

If no candidate clears every gate, the correct result is **do not ship diarization**.

## Proposed user experience

### Eligibility and entry point

Only an eligible completed native WhisperMeet recording with a readable canonical WAV and usable timestamped transcript exposes **Analyze speaker turns…** in the existing transcript Improve menu. The first release excludes imports and URL audio until they pass their own source-quality and recovery gate.

Before a first run, a compact sheet says:

> Analyze voice turns locally on this Mac. WhisperMeet will create anonymous labels such as “Speaker 1”; it does not identify people. Analysis can be wrong, especially with overlapping speech. Your recording and transcript will not be changed.

If the model is absent, the sheet separately offers **Install local speaker model** and states the precise size, publisher/version, attribution link, storage location, and that only model files—not meeting content—are downloaded. Nothing runs until the person confirms installation or selects a previously installed verified model.

### States

| State | What the person sees | Required behavior |
|---|---|---|
| Not analyzed | Analyze speaker turns plus local-only explanation. | No model load or network activity. |
| Model unavailable | Exact missing/unsupported/corrupt reason and explicit install/repair option. | Never silently invoke a downloader. |
| Preparing | Verified model/version and cancellable setup progress. | Cannot race recording, transcription, dictation, or another installer. |
| Analyzing locally | Progress plus Cancel. | Read-only analysis; no partial result becomes visible. |
| Ready to review | Anonymous labels, a legend, and per-meeting Rename / Clear / Rerun. | Labels are text, not color alone. |
| Needs review | Unassigned, Overlapping voices, or Uncertain. | Do not collapse ambiguity into one named speaker. |
| Unavailable | Plain reason: no timings, too little speech, silence/music, incomplete recording, or unsupported input. | Preserve transcript and offer a safe retry/clear path. |
| Failed or cancelled | Original transcript remains immediately usable; Retry is available. | Remove temporary material; do not save a partial artifact. |
| Stale | Labels belong to different audio/model result and are hidden. | Preserve or quarantine the artifact; never apply it to changed audio. |

### Display, aliases, and output

The transcript remains a timestamped text document. A row may receive a neutral text label, for example **Speaker 1 · inferred**. A person can rename the cluster to a per-meeting alias. The interface calls it “Your label,” never “recognized” or “verified.” Rerun creates fresh anonymous clusters and does not silently transfer aliases.

An ASR sentence may span multiple diarization turns. The UI never rewrites or splits a sentence just to make a label fit. Instead it uses the conservative reconciliation rule below and shows no single label when the interval is materially ambiguous or overlapping.

The following remain **unlabeled** in v1: ordinary Copy, plain text/SRT/VTT/HTML/JSON/Markdown exports, search, notes.md, diagnostics, local summaries, and the opt-in Claude summary request. Only a separately named **Export with speaker labels…** action can include an anonymous label or a clearly marked user-assigned alias.

VoiceOver reads a concise value such as “Speaker 2, inferred, 12 minutes 04 seconds, [segment text].” Every control has a keyboard path; color is supplementary; aliases and uncertainty remain legible at large Dynamic Type sizes. This needs manual VoiceOver and Voice Control validation, consistent with [Apple accessibility fundamentals](https://developer.apple.com/documentation/swiftui/accessibility-fundamentals).

## Data, privacy, and persistence design

### Hard privacy rules

1. Analysis runs on-device after model installation. There is no cloud fallback.
2. Cluster IDs are unique to one artifact and never used to look up a voice across meetings.
3. Aliases are local to the meeting and stored only in its derived artifact.
4. Embeddings, logits, temporary resampled audio, and model scratch output are removed on success, failure, and cancellation. They are not voice profiles.
5. Audio, source tracks, transcript text, timestamps, and the existing meeting index are not modified by analysis, aliasing, clearing, failure, or cancellation.
6. No automatic label appears in a Claude request. A labeled-cloud workflow would be a separate policy proposal with fresh consent.
7. The feature makes no claim about gender, role, sentiment, demographic trait, or real-world identity.

### Authoritative sidecar, not MeetingRecord

Store the result in a versioned per-recording sidecar:

~~~text
Recordings/<meeting-uuid>/diarization.json
~~~

It belongs beside meeting.wav, source-tracks.json, and notes.md, so the existing whole-recording delete removes it with the source material. It avoids adding an evolving speaker graph to the cross-build meetings.json wire format and avoids leaking labels into canonical transcript code.

notes.md is not a suitable implementation model: it is intentionally regenerable and silently best-effort. This artifact contains user aliases and must have strict decoding, atomic writes, an accessible backup/quarantine path, and fail-closed rendering.

### DiarizationArtifactV1 envelope

~~~text
schemaVersion: 1
meetingID: UUID
recording: { relativePath, sha256, durationSeconds, canonicalFormat }
transcriptTimingFingerprint: sha256
producer: { runtimeID, runtimeVersion, modelID, modelAssetHashes, configurationID }
createdAt: ISO-8601
turns: [ { startSeconds, endSeconds, clusterID, kind } ]
aliases: { clusterID: userTypedAlias }
~~~

kind distinguishes normal anonymous turns from overlap and explicitly unassigned/uncertain intervals. The artifact contains no embedding, voiceprint, raw audio, copied transcript, known identity, confidence theater, or global cluster ID.

Rules for reading and writing it:

- Validate finite, non-negative, ordered intervals and a bounded duration before displaying a result.
- Validate the recording SHA-256 before applying the artifact. A mismatch produces **Stale** and hides labels.
- Write a fresh temporary file and atomically replace only after a complete valid result exists.
- If decoding fails, the schema is newer, or validation fails, preserve bytes by quarantine before retry and show “Speaker labels unavailable; your transcript is safe.” Never overwrite unknown content.
- When the library is degraded/read-only, prohibit all diarization artifact writes and clear/repair mutations.
- Recompute display overlay from current timed segments. A changed transcript-timing fingerprint invalidates only a cached mapping; it never rewrites turns or transcript. If current timing cannot be reconciled, display unavailable.

This is a new persistence contract, so its reader/writer needs bidirectional fixtures and quarantine tests even though it is outside meetings.json.

## Technical architecture

~~~mermaid
flowchart LR
    A[Completed meeting.wav] --> B[Local 16 kHz mono temp input]
    B --> C[App-target diarization adapter]
    C --> D[Validated anonymous turns]
    D --> E[diarization.json sidecar]
    D --> F[Pure reconciler]
    G[Timed transcript segments] --> F
    F --> H[Display-only label overlay]
    H --> I[Transcript read view]
    E -. never feeds .-> J[Canonical transcript / notes / normal exports / Claude]
~~~

| Layer | Responsibility | Must not do |
|---|---|---|
| WhisperCore | Sendable value types, result validation, interval algebra, display reconciliation, artifact codec/fingerprint primitives. | Import Core ML, AppKit, SwiftUI, or a third-party runtime. |
| WhisperMeet app target | Runtime availability, confirmed installer, temporary audio preparation, job lifecycle, sidecar I/O/quarantine, AppModel state, SwiftUI. | Make a model result canonical transcript content. |
| Candidate adapter | Fixed-version FluidAudio or sherpa invocation; bounded progress/cancel; normalized raw turns. | Persist embeddings or contact the network after install. |

The app target, not WhisperCore, owns an eventual Core ML/third-party dependency. This keeps the Foundation-only core purity rule intact. The adapter runs off the main actor in a detached job and is protected by an AppModel guard so there is at most one resource-heavy ML task across transcription, diarization, dictation, and installation.

### Reconciliation policy

Raw diarization turns and ASR segments are different temporal shapes. The first release does not populate TranscriptSegment.speaker. DiarizationReconciler creates a presentation overlay only:

1. Reject malformed, out-of-range, unknown, or impossible raw intervals before storage.
2. For each timed ASR segment, calculate coverage from each cluster and from overlap.
3. Show one inferred cluster only when it covers at least **80%** of the segment, exceeds the next cluster by at least **20 percentage points**, and does not intersect a reported overlap. These are conservative initial benchmark parameters, not user-adjustable “confidence” controls.
4. Otherwise show no speaker, **Unassigned**, or **Overlapping voices**. Never select the most common speaker merely to fill a visual gap.
5. Preserve the original time and text even when no label is displayed.

A benchmark may revise this fixed policy only with a documented before/after comparison on a held-out corpus; it may not tune settings against a release test set.

### AppModel seam and reachability

Follow the repository’s F47-style injected seam rather than testing only the pure core:

~~~swift
var runSpeakerDiarization: @Sendable (SpeakerDiarizationRequest) async throws
  -> SpeakerDiarizationResult

func requestSpeakerDiarization(for meetingID: UUID)
~~~

The default closure invokes the selected local adapter. A headless WhisperMeetTests case creates a temp MeetingStore, writes a synthetic native-recording fixture and timed transcript, replaces the closure, calls requestSpeakerDiarization, and asserts that a valid sidecar-derived overlay returns through the app-level path.

~~~text
TranscriptDetailView “Analyze speaker turns…”
  → AppModel.requestSpeakerDiarization(for:)
  → runSpeakerDiarization seam / local adapter
  → DiarizationArtifactStore
  → PlayableTranscriptView row overlay
~~~

Do not add a new persisted MeetingStatus value; older builds currently decode unknown values as a recorded meeting. Model/job state belongs in transient AppModel state and the versioned sidecar, not in a schema change that can affect unrelated library operations.

## User stories and acceptance criteria

| User story | Acceptance criteria |
|---|---|
| Analyze a completed meeting | The action is absent while recording/transcribing/dictating, requires explicit initiation, discloses local anonymous analysis, and never starts a library-wide batch job. |
| Read a more navigable transcript | Labels start as Speaker n; aliases are visibly user-assigned; no UI says “recognized” or implies a person/channel mapping. |
| Know when the result is weak | Overlap, ambiguity, silence/music, short audio, missing timing, corruption, cancellation, and model failures have specific non-destructive states. |
| Give a useful local name | Alias changes only the sidecar for one meeting, never an embedding/profile, cloud request, default export, or a different meeting. |
| Clear or rerun | Clear deletes only the derived artifact; rerun creates a fresh result; neither action changes source bytes or ASR data. |
| Export safely | Existing copy/export/note/summary behavior is unchanged/unlabeled; affirmative labeled export is separate. |
| Use assistive technology | VoiceOver, keyboard navigation, Dynamic Type, and focus order are manually verified in the installed app. |
| Protect a damaged library | Degraded mode disables diarization mutation; malformed/newer sidecars are preserved/quarantined; audio/transcript remain readable. |

## Evidence plan and release gates

### Corpus and scoring

Create Scripts/bench/diarization/ with a manifest-driven synthetic multi-speaker corpus. It uses only generated or explicitly licensed sources—never a user meeting, index, transcript, or recording. Each fixture records its generator version, voice/source license, exact WAV hash, reference turns, overlap intervals, sample rate, channel map, and mix offsets.

Required strata:

- English, Mandarin, and code-switching speech.
- One, two, three, and four-plus voices.
- Alternating turns, rapid changes, long turns, silence, music/no-speech, noise, and controlled overlap.
- Microphone/system-style two-track mixes with intentional presentation-time offsets and bleed.
- Clean mono versus source-track ablation for research only—never channel-as-person.
- A deterministic 30–60 minute sentinel for long-form memory, cancellation, and cluster stability.
- No-timestamp, corrupt-sidecar, missing-audio, and degraded-store failure fixtures.

Use [pyannote.metrics](https://pyannote.github.io/pyannote-metrics/) definitions to score DER and components. Every score records collar and overlap policy; the suite reports both no-collar/overlap-scored and conventional collar/overlap-excluded results rather than comparing incompatible headline numbers.

For every candidate and stratum, record:

- DER/JER, miss/false-alarm/confusion components, speaker-count error, boundary precision/recall, overlap behavior, and anonymous-label-permutation-invariant attribution.
- **Displayed-label precision and coverage** after WhisperMeet’s conservative reconciliation, plus the percent intentionally abstained as uncertain.
- Cold/warm real-time factor, wall time, peak unified memory, disk footprint, CPU/GPU/ANE choice, cancellation latency, and three-run determinism.
- Runtime/package/model revisions and SHA-256 hashes, Mac hardware/OS, environment, and network-denied evidence.
- Hashes of audio and canonical transcript before/after success, failure, and cancellation.

### Go/no-go gates

Numbers are predeclared after the baseline is built and before candidate tuning. Do not invent a universal threshold from a vendor corpus or average away a failing language/capture mode.

1. **Safety gate: hard 100%.** Every preservation, offline-after-install, no-label-leak, degraded-library, corrupt/newer-sidecar, cancellation, and temporary-file-cleanup test passes.
2. **Quality gate.** Candidate meets the pre-registered target composite and no required stratum regresses by more than five absolute DER points from the Python control. The initial target is within three absolute DER points of that control on the composite; F217 may revise that rule only before the held-out output is seen.
3. **Value gate.** Blinded internal reviewers complete predefined “who said this?” navigation tasks faster or more accurately than with an unlabeled transcript, without reporting that review burden outweighs the value.
4. **System gate.** On the lowest supported Apple Silicon configuration, p95 real-time factor is at most 0.25, no memory-pressure termination occurs on the long-form sentinel, and output is stable across three runs. Profile actual backend execution; an available Core ML provider is not proof of ANE execution.
5. **Trust gate.** Manual review validates overlap/ambiguity language, aliases, default export isolation, and VoiceOver/keyboard/Dynamic Type behavior in the installed app.

A failed gate is a **no-ship** outcome, not a weaker best-effort label.

## Testing decisions

| Area | Failing-before / passing-after evidence |
|---|---|
| Pure validation | Reject NaN, negative, reversed, out-of-duration, duplicate/unknown-kind, and impossible overlap inputs; accept canonical fixture. |
| Reconciliation | Deterministic fixtures prove unambiguous labels, multi-turn segments, threshold edges, overlap, uncertainty, and no-timestamp behavior. |
| Sidecar durability | Atomic write, backup/quarantine, stale audio fingerprint, future schema, corrupt bytes, deletion behavior, and no overwrite on read failure. |
| AppModel reachability | Injected runSpeakerDiarization test proves guards, result path, cancellation, failure, and overlay state through a temp MeetingStore. |
| Lifecycle safety | Analysis refuses before runtime launch during recording, active transcription, dictation, model installation, or degraded storage. |
| Immutability | SHA-256/audio bytes, source tracks, transcript text, timed segments, and ordinary sidecars are unchanged after success/failure/cancel. |
| Output isolation | Existing exporters, notes.md, Copy, local summary, and Claude request fixture stay label-free; only explicit labeled export includes overlay data. |
| Runtime/install | Exact manifest/hash, staged offline load, no-network-after-install, corrupted artifact, low-space, cancellation, and architecture tests. |
| Human QA | Synthetic real-model run, installed app, long form, accessibility, clear/rerun, error/retry, and no-cloud observation are recorded in the ticket log. |

The app target has no SwiftUI view-render harness. That is a permanent harness limitation, not deferred work: after the AppModel seam has red-green coverage, record manual UI steps in the closing log as “Not planned: no view-render harness exists.”

## Delivery plan

| Phase | Outcome |
|---|---|
| 0 — approval and research | Approve constrained scope; freeze policy language; run candidate/legal/benchmark spike. No production runtime, persistence, or UI lands merely because an experiment runs. |
| 1 — safe foundation | Build pure result/overlay types and durable sidecar with red-green tests before attaching a model. |
| 2 — local orchestration | Add one guarded local runtime, explicit installer, AppModel seam, cancellation, and headless reachability tests. Support native recordings first. |
| 3 — review and output | Add thin SwiftUI control, anonymous labels, aliases, clear/rerun, accessibility, and labeled export. Prove defaults remain unlabeled. |
| 4 — beta gate | Run installed-model validation only on synthetic/licensed clips; complete long-form/accessibility matrix; publish scorecard; remain explicit opt-in beta until evidence supports it. |

### Proposed independently claimable tickets

| Ticket | Scope | Depends on | Done when |
|---|---|---|---|
| F216 | Approve/record constrained policy; evaluate FluidAudio, sherpa-onnx, and Python control at fixed revisions; produce license/offline/package decision. | This PRD | A documented selection or no-ship result has exact artifacts, hashes, model notices, and source evidence. |
| F217 | Build synthetic/licensed corpus, scorer, manifest, and frozen scorecard protocol. | F216 candidate requirements | Fixtures have ground truth/hashes; scorer reports per-stratum DER/JER/display metrics; no user data is read. |
| F218 | Add pure validation/reconciliation and diarization.json durability/quarantine contract. | F217 schema decisions | Red-green core and sidecar tests prove failure and immutability paths. |
| F219 | Add selected local runtime installer, AppModel guard/seam/cancel/retry, and headless reachability test. | F216, F218 | A model result reaches the app overlay through the named user path without racing other ML work. |
| F220 | Add review UI, aliases, clear/rerun, explicit labeled export, and accessibility behavior. | F219 | Default outputs remain unchanged; UI is manually verified in installed app. |
| F221 | Run release benchmark, long-form, installed-model, privacy, and beta evidence gate. | F217–F220 | All go/no-go evidence is recorded; feature launches only on a pass. |

## Required decision before implementation

The following is the precise policy amendment proposed for review. It preserves the intent of the current local-only and source-of-truth rules while allowing a tightly bounded feature:

> WhisperMeet may offer an explicit, post-meeting, entirely local speaker-turn analysis for a completed recording. It may assign anonymous, per-meeting voice-cluster labels and let the user rename those labels for that meeting. It must not infer, enroll, or verify a real person's identity; match voices across meetings; infer role, gender, demographic attributes, or sentiment; or send audio, embeddings, speaker turns, or user-entered aliases to a service.
>
> The recording and original transcript remain unchanged. Failed, cancelled, ambiguous, overlapping, unsupported, or timing-unavailable analysis preserves them and explains the limitation plainly. Voice embeddings and model scratch output are temporary; no voice profile is persisted. Default transcript views, notes sidecars, ordinary exports, search, and both local and Claude summaries exclude speaker labels. A person must explicitly request any labeled export.

If approved, amend AGENTS.md, docs/PRODUCT_SPEC.md, docs/ROADMAP.md, and the end-user README.md in one reviewed change. Until then, the existing “no diarization” language remains binding.

## Risks and explicit open decisions

| Risk or decision | Plan response |
|---|---|
| Model licensing/conversion provenance is incomplete. | Do not bundle/download it until F216 records every artifact’s terms, notice, pin, and hash. |
| A native candidate works on a demo but fails long multi-speaker meetings. | Require per-stratum scorecards, long-form sentinel, and no-ship outcome on a failed gate. |
| A model sees channel bleed as a second person. | Analyze the mix first; retain channel ablation only in benchmark; never map a channel to a person. |
| IDs permute across reruns. | Aliases are per artifact; clear aliases on rerun; compare labels permutation-invariant in scoring. |
| Labels are persuasive but wrong. | Conservative overlay, visible uncertainty/overlap, no identity language, and no default label leakage. |
| Sidecar corruption harms a meeting. | Sidecar only, atomic writes, backup/quarantine, read-only degraded behavior, and audio/transcript immutability tests. |
| Model download expands privacy boundary. | Explicit model-only install, pinned data artifact, no executable download, and network-denied test. |
| Accessibility/UI density turns a helpful feature into noise. | Text-first labels, keyboard/VoiceOver/Dynamic Type passes, and a value study against current transcript. |
| Participant-consent or jurisdictional concerns remain. | Local-only design is risk reduction, not legal advice; obtain product/legal review before rollout. |

## Sources consulted

Primary sources were checked on 2026-09-12. Version pins, artifact hashes, and licenses must be rechecked immediately before implementation.

- [pyannote Community-1 model card](https://huggingface.co/pyannote/speaker-diarization-community-1) — 16 kHz mono, offline setup, exclusive output, access conditions, benchmark methodology/results, and hosted-service boundary.
- [FluidAudio repository](https://github.com/FluidInference/FluidAudio) — native Swift offline pipeline and staged model-load design.
- [FluidAudio Core ML model card](https://huggingface.co/FluidInference/speaker-diarization-coreml) — input/output, Core ML/ANE claim, model license, and source-model provenance.
- [FluidAudio benchmarks](https://github.com/FluidInference/FluidAudio/blob/main/Documentation/Benchmarks.md) and [issue #801](https://github.com/FluidInference/FluidAudio/issues/801) — performance context and clustering-regression warning.
- [sherpa-onnx API](https://k2-fsa.github.io/sherpa/onnx/c-api/html/speaker_diarization.html), [Swift example](https://github.com/k2-fsa/sherpa-onnx/blob/master/swift-api-examples/speaker-diarization.swift), and [model guide](https://k2-fsa.github.io/sherpa/onnx/speaker-diarization/models.html) — native fallback architecture and artifact caveats.
- [Qwen3-ASR](https://github.com/QwenLM/Qwen3-ASR) — Qwen scope remains ASR/alignment, not an approved diarization contract.
- [pyannote.metrics](https://pyannote.github.io/pyannote-metrics/) — reproducible diarization scoring.
- [MacWhisper speaker-recognition workflow](https://docs.macwhisper.com/article/32-automatic-speaker-recognition-in-macwhisper) — anonymous labels followed by user rename are an understandable desktop UX; design evidence only.
- [Apple accessibility fundamentals](https://developer.apple.com/documentation/swiftui/accessibility-fundamentals) — manual assistive-technology validation.
