# F216 — Decision record: local speaker-diarization runtime

**Runtime: FluidAudio 0.15.7**, pinned `exact:` with `traits: []`, imported only from
`Sources/WhisperMeet/`, running the pyannote `speaker-diarization-community-1` Core ML conversion
in-process. No Python, no subprocess, no network after install.

**Status:** Runtime selected — **not** a ship approval. PRD go/no-go gate 2 (quality) is still open
and, as written, cannot be evaluated at all (§5.4). **Decided:** 2026-09-13. **Verified on:** this
Mac, Apple Silicon arm64, macOS 26.6.2 (build 25G83). **Evidence:** every hash in §1 was recomputed
independently with `shasum -a 256` after the investigation; the measurements in §5 came from a
throwaway SwiftPM harness built outside this repository against the pinned package.

**This record was decided twice in one day, and the second decision is the one that ships.** A
product-owner rule of *no new SwiftPM third-party dependency* first selected a pinned sherpa-onnx
native binary. That runtime then failed real-meeting validation — 179 speaker clusters on a
35-minute meeting with a handful of participants, and no setting fixed it. The product owner lifted
the constraint, which was trigger 2 on that record's own list of what would reopen it; FluidAudio,
the runtime the PRD had recommended spiking first, was measured on the identical audio and adopted.

**How to read this.** §1–§8 describe the runtime that ships. §9 keeps the sherpa-onnx route in full,
clearly marked as superseded, because two things in it are still binding: the GPL/espeak finding
that bars the `pip` distribution for good, and the real-meeting failure that is the evidence
justifying this swap. A decision record that deletes the case it argued cannot be audited.

---

## 1. Decision

**Adopt FluidAudio 0.15.7 as the local speaker-diarization runtime.** It is an Apache-2.0 SwiftPM
package that runs the pyannote community-1 recipe — powerset segmentation, WeSpeaker embeddings,
PLDA scoring, VBx clustering and `constrained_argmax` per-chunk assignment — as compiled Core ML
bundles, inside this app's own process, on the Apple Neural Engine.

Why it was chosen, on measurement rather than reputation:

1. **It works on the audio the previous runtime failed on.** 4 clusters on the real 35-minute
   meeting at the pinned threshold, against sherpa-onnx's 179 on the identical file (§5.2). VBx
   exists to model within-speaker variability across a long recording, which is exactly the failure
   that killed the plain agglomerative route.
2. **It costs a fifth of the memory and runs thirteen times faster.** 615.5 MiB peak RSS and RTF
   0.0028 against 3 201 MiB and RTF 0.037 on the same file (§5.3).
3. **It is bit-deterministic** across repeated runs on real audio (§5.3) — PRD system gate 4's
   three-run stability requirement, met on a meeting rather than on a fixture.
4. **The staged payload is a third of the size and contains nothing executable**: 21.6 MB of Core ML
   bundles instead of 61 MB of native binary, ONNX Runtime and ONNX models.

What it costs, recorded because it is the other half of the trade:

- **The first third-party SwiftPM dependency in this project's history**, and it pulls a 111 MB Rust
  xcframework through `swift package resolve` even when the trait that unlinks it is set (§3.1).
- **A delete-on-failure path inside a dependency** (§3.3) — the exact shape of the 2026-08-14
  library-index wipe, now avoided by never calling the API that contains it.
- **Weaker licence provenance than the route it replaces.** The model licence is asserted in README
  front-matter and in the artifacts' own metadata, not in a LICENSE file (§2).
- **Peak memory now lives inside the app's process**, not in a child the OS reclaims unconditionally.
- **An offline guarantee that is a flag and a call-path discipline, not the absence of network code**
  (§4).

### Pins

What follows is exactly what `Scripts/setup-speaker-diarization.sh` installs. (The superseded
sherpa-onnx artifacts and their hashes are in §9.6.)

Every file below was downloaded twice, independently, and hashed with `shasum -a 256`; the two runs
agreed byte for byte. The four `.mlmodelc` entries are **directories**, not files, which is why each
is pinned leaf by leaf: `mkdir -p` runs before the first byte of a download, so a per-directory check
reports "present" for an install that fetched nothing.

| Role | Artifact | Bytes | SHA-256 |
|---|---|---:|---|
| Segmentation (pyannote powerset, 10 s) | `Segmentation.mlmodelc/analytics/coremldata.bin` | 243 | `64265f8e7ad41a5f68d630c15288c2499cca5892ad49e20096819cdeac004cdb` |
| └ | `Segmentation.mlmodelc/coremldata.bin` | 812 | `ea51481b8bd3e496ad3cf16f066ddaa37f20e8772eaac76b3393c28de20e06bc` |
| └ | `Segmentation.mlmodelc/metadata.json` | 3,410 | `88dbf0b07208fe142e1729c2b4c974ad3599fcb2ae5d5f18fce782b225384124` |
| └ | `Segmentation.mlmodelc/model.mil` | 43,063 | `d37e4ce30b406a6b34f765f769b9baed3178cc0c2b2e299c641daa43a052dd3f` |
| └ | `Segmentation.mlmodelc/weights/weight.bin` | 5,959,360 | `c3189a64946c75bc24fcb98afe89ad78c52bdbadfdf65e857fb1b81e2cc9fbb2` |
| Filterbank frontend | `FBank.mlmodelc/analytics/coremldata.bin` | 243 | `0e8bd3a8b82ac123580989f490e4d9245127c535857630b543311268accc3f0a` |
| └ | `FBank.mlmodelc/coremldata.bin` | 853 | `57ac436bb0671cbb5527a339134d695f752eb77f7a18966b93c6835335595759` |
| └ | `FBank.mlmodelc/metadata.json` | 3,409 | `2623785f5d186893b82d01e84aa33a7704ef763c3309e02055f22dc9d871ce9a` |
| └ | `FBank.mlmodelc/model.mil` | 15,667 | `27aaeb21569e81bdbe2eef87789f50a37cfea800039bd134448a9417de2f30ed` |
| └ | `FBank.mlmodelc/weights/weight.bin` | 1,776,896 | `9e83fdd3ea78064b078069e4d9141603c61c47a27fd19e7e3142ff7476f8db36` |
| Speaker embedding (WeSpeaker ResNet34) | `Embedding.mlmodelc/analytics/coremldata.bin` | 243 | `8d6706436639b53830b4dbe8aaf9c9a843f7f582d63e16f3cb8bb7c6ccd58682` |
| └ | `Embedding.mlmodelc/coremldata.bin` | 704 | `4a705bac27d151d9642f37609296042a15602a42253039e0921dc9e75da7e004` |
| └ | `Embedding.mlmodelc/metadata.json` | 2,818 | `1854371eb6b438fb8aeac96afb45c999af7902581c06afdfcd7ff3cb1ce66be5` |
| └ | `Embedding.mlmodelc/model.mil` | 78,432 | `22fa958aef72a561c21f874a07cbdcd30fdf40ee961c0bc2fb67c119273b46d3` |
| └ | `Embedding.mlmodelc/weights/weight.bin` | 13,412,288 | `99356b2985b8d43880a657024d941d450b38820451ccff903f76ed4e52d1868b` |
| PLDA rho (VBx clustering) | `PldaRho.mlmodelc/analytics/coremldata.bin` | 243 | `8940ea6044dbcbefa22da8cc41e0b485e1fb5ed89aecaf37c6e0c483a97ddcd7` |
| └ | `PldaRho.mlmodelc/coremldata.bin` | 763 | `4d9741477f721c79b09fcdfe455110c4b7d4272e2de3496bf1729d966d3ee418` |
| └ | `PldaRho.mlmodelc/metadata.json` | 2,749 | `b314cf25a93e46b4076883a6f5a2f8848b73c3851bd9d36074d067f35a1c7945` |
| └ | `PldaRho.mlmodelc/model.mil` | 7,613 | `83aee2e5310d19b5f202aea97d07a0e12102556d1b32ef3ed08b36f7f9725041` |
| └ | `PldaRho.mlmodelc/weights/weight.bin` | 200,192 | `80f7d229202636d372428c90596f11a91545f07da77259f07153aaf225914a36` |
| PLDA parameters | `plda-parameters.json` | 89,416 | `38ee28d4269c076cef254ee760bbd811f0738a92e0f01f9699ad372828c5de8f` |

**Download total: 21,599,417 B (20.6 MiB). On disk after install: the same — there is nothing to
extract and nothing to prune.**

URLs — every file at `https://huggingface.co/FluidInference/speaker-diarization-coreml/resolve/main/<artifact>`,
fetched anonymously. No token, no account, no click-through, no `.netrc`.

Notes on the pins:
- **The staged directory must be named `speaker-diarization`, not `speaker-diarization-coreml`.**
  FluidAudio resolves `<models parent>/<Repo.diarizer.folderName>` and `folderName` strips the
  `-coreml` suffix from the Hugging Face slug. Staging under the repo name fails with
  `DownloadError.modelMissing(repo: "speaker-diarization", …)` — an error naming the *folder* it
  looked in rather than the repo it wanted, so it misdirects. Verified by execution.
- The repository also holds `wespeaker*.mlmodelc`, `pyannote_segmentation.mlmodelc`, `PLDA.mlmodelc`,
  an `mlpackages/` tree and `plots/`. **None of those are downloaded.** They belong to the legacy
  streaming `DiarizerManager`, not to `ModelNames.OfflineDiarizer.requiredModels`, and the installer's
  completeness check refuses a staged tree that contains anything outside the 21 files above.
- Apple Silicon only, matching the existing Qwen3-ASR constraint. The bundles are Core ML compiled
  units; whether they load is a property of this machine, which is what the install-time smoke test
  exists to establish before anything is activated.

### Configuration pin (this is part of the decision, not tuning)

```swift
clustering.threshold = 0.6              // FluidAudio's community preset — see below
segmentation = .community               // the configuration FluidAudio's own DER numbers used
embedding    = .community
vbx          = .community
postProcessing = .community
// never clustering.numSpeakers / minSpeakers / maxSpeakers — left nil
// never prepareModels() — see §3.3
```

> **The threshold did not carry across, and could not.** sherpa-onnx's
> `--clustering.cluster-threshold=0.40` was re-derived on the F217 corpus as a **cosine distance**.
> FluidAudio's threshold is a **Euclidean distance in PLDA space** (its v0.15.6 semantics fix); the
> two are not comparable and map as `euclidean = sqrt(2 − 2·cosine)`, so reusing 0.40 would not be
> conservative, it would be a far more aggressive setting that over-splits every meeting. 0.6 is the
> value upstream calibrated on pyannote community-1 and is the only defensible starting point.
> **It is not calibrated for this product.** Re-deriving it on annotated audio is F225; FluidAudio's
> `prepare`/`cluster` split makes that cheap, because a threshold sweep re-clusters in ~0.25 s
> without re-running the models.

### What this decision is not

This selects a runtime that satisfies the licence, offline, packaging, memory and performance
constraints, and that produces a plausible speaker count on the one real meeting anyone has ever run
it against. It does **not** clear PRD go/no-go gate 2 (quality), and it is not evidence that a label
shown to a user would be correct.

**Neither runtime has been measured against ground truth on real audio, because none exists.**
Cluster counts, resource use and determinism are all there is. A plausible speaker count is a sanity
check, not a quality gate. The PRD's quality gate names a Python Community-1 control that was never
built, so it has no comparator and cannot be evaluated as written. §5.4 states this at length, and
`DIARIZATION_SCORECARD.md` is the standing record of it.

---

## 2. Licence and attribution ledger

### FluidAudio + pyannote community-1 (Core ML)

`Resources/THIRD-PARTY-NOTICES.txt` is authored from this table and is copied into the runtime
directory by the installer, which refuses to activate without it.

| Artifact | Upstream project | Licence | Redistribution OK? | Attribution the app must show | Source |
|---|---|---|---|---|---|
| FluidAudio 0.15.7 (compiled into WhisperMeet) | FluidInference/FluidAudio | Apache-2.0 | **Yes** | Full Apache-2.0 text; "FluidAudio, © Fluid Inference". No upstream `NOTICE` file exists, so §4(d) is inert; §4(a)/(b)/(c) apply | https://github.com/FluidInference/FluidAudio/blob/main/LICENSE |
| The 21 staged Core ML files (§1 Pins) | pyannote `speaker-diarization-community-1`, converted by Fluid Inference | **CC-BY-4.0** | **Yes** | Attribution to pyannote.audio / Hervé Bredin **and** to the converter, a link to the licence, **and a statement that changes were made** (the Core ML conversion is the change). Authored by us — see below | https://huggingface.co/FluidInference/speaker-diarization-coreml |
| WeSpeaker ResNet34 (the embedding network realised by `Embedding.mlmodelc`) | wenet-e2e/wespeaker | Apache-2.0 | **Yes** — no WeSpeaker code or checkpoint is shipped; the architecture arrives only through the community-1 weights | Apache-2.0 text; credit the project | https://github.com/wenet-e2e/wespeaker |
| VBx (reimplemented in Swift inside FluidAudio) | BUTSpeechFIT/VBx | Apache-2.0 | **Yes** | Apache-2.0 text; `Copyright 2021-2024 BUT Speech@FIT`. FluidAudio bundles this notice in `ThirdPartyLicenses/vbx-LICENSE.md` and it must travel with the app | FluidAudio `ThirdPartyLicenses/vbx-LICENSE.md` |
| fastcluster (reimplemented in Swift inside FluidAudio) | fastcluster | BSD-2-Clause | **Yes**, with the binary-form condition | **Reproduce `© 2011 Daniel Müllner`, `changes from 1.1.24 on: © Google Inc.`, both conditions and the all-caps disclaimer.** FluidAudio bundles it in `ThirdPartyLicenses/fastcluster-LICENSE.md` | FluidAudio `ThirdPartyLicenses/fastcluster-LICENSE.md` |
| NemoTextProcessing (prebuilt Rust xcframework) | FluidInference/text-processing-rs | Apache-2.0 | **Not shipped** | — `traits: []` removes the linkage, so neither it nor its NVIDIA NeMo licence chain travels with the app. It is still *downloaded* at `swift package resolve` time; traits control linkage, not fetching | FluidAudio `ThirdPartyLicenses/NemoTextProcessing-LICENSE.md` |

**Neither repository ships a licence file.** The upstream model card declares `license: cc-by-4.0`
and is `gated: auto`; the converted repo declares `license: cc-by-4.0` in README front-matter with
`base_model: pyannote/speaker-diarization-community-1`, `base_model_relation: finetune`, and raw
`LICENSE` returns **HTTP 404**. The evidence that survives a README edit is inside the artifacts: all
four `metadata.json` files and `plda-parameters.json` carry `"license": "CC-BY-4.0"`,
`"author": "Fluid Inference"` and `"version": "pyannote-speaker-diarization-community-1"`, and those
files are SHA-256 pinned. `THIRD-PARTY-NOTICES.txt` is therefore authored by us from that evidence.

**On re-hosting an ungated conversion of a gated upstream.** F216's gate requires this reasoning to be
explicit rather than assumed: CC-BY-4.0 permits it. Gating is a distribution choice made by the
upstream host, not a term of the licence, and CC-BY-4.0 §2(a)(1) grants the right to reproduce and
share the material, §2(a)(5)(A) forbids the licensor from imposing additional restrictions, and
§4 contains no anti-circumvention term reaching a form the licensor themselves published. The
obligations that *do* bind are attribution, the licence link, and the indication of modification —
all three discharged in `THIRD-PARTY-NOTICES.txt`.

**What CC-BY-4.0 costs us that MIT did not.** It is not share-alike, so nothing about WhisperMeet's
own licensing changes. It does require the notice to survive in the shipped product, which is why the
installer treats a missing `THIRD-PARTY-NOTICES.txt` as a refusal rather than a warning, and why the
notice is copied into the runtime directory as well as the app bundle.

### Explicitly foreclosed (do not revisit without new evidence)

The ledger for the superseded sherpa-onnx route — including which of its components were verified
present in the shipped binary by symbol inspection — is §9.2. The first entry below is the finding
that route produced, and it outlives it.

- **`pip install sherpa-onnx` and the SPM xcframework** — both statically link GPL-3.0 espeak-ng.
  Reproduced on the wheel installed here (50 unique espeak symbols in the Python extension module).
- **`sherpa-onnx-reverb-diarization-v1` / `-v2`** — Rev Model Non-Production License §3.2 bans
  supplying the model, derivatives, **and its outputs** in the course of commercial activity, paid
  or free. Legally foreclosed for a commercial desktop product regardless of the embedder paired
  with it.
- **WeSpeaker weights** — VoxCeleb-derived → CC-BY-4.0 with "for research purposes" framing;
  CN-Celeb-derived → **CC-BY-SA-4.0**, a share-alike trap on a shipped model.
- **`nemo_en_titanet_small`, `nemo_en_speakerverification_speakernet`** — licence UNESTABLISHED (NGC
  points at the toolkit's Apache-2.0 while NVIDIA publishes equivalent weights as CC-BY-4.0
  elsewhere). Not "probably Apache".
- **Every `.wav` in both model releases** — no licence statement anywhere. Never ship them; never
  use them as a bundled smoke-test fixture.

---

## 3. Verified landmines

Every item here was hit during the evaluation or the adoption, and every one of them fails quietly
rather than loudly. They are collected in one section because each is invisible from the code that
would suffer for it.

### 3.1 `traits:` needs swift-tools-version 6.2, and it does not prevent the download

FluidAudio's manifest links `NemoTextProcessing`, a prebuilt Rust xcframework, unless the dependency
declaration opts out with `traits: []`. Two corrections to what was assumed before it was tried:

- **`traits:` does not exist at swift-tools-version 6.0.** Verbatim:
  `error: 'package(url:exact:traits:)' is unavailable`. WhisperMeet's `Package.swift` moved from 6.0
  to **6.2** to reach that argument and for no other reason; `.macOS(.v15)` and
  `swiftLanguageModes: [.v5]` are unchanged, the suite count did not move, and the rationale is in
  the manifest's own header comment.
- **`traits: []` removes linkage, not fetching.** The 111 MB artifact still lands in
  `.build/artifacts` at `swift package resolve` time, trait or no trait. What the opt-out buys is a
  binary of 8.5 MB instead of 16.9 MB, with zero `nemo`/`rustfst` strings — unlinked code is not
  shipped code, so neither it nor NVIDIA NeMo's licence chain travels with the app. What it does not
  buy is an offline resolve, and a feature whose headline promise is that it never touches the
  network now has a build step that does (§4).

### 3.2 The staged folder must be named `speaker-diarization`, not the Hugging Face slug

FluidAudio resolves `<models parent>/<Repo.diarizer.folderName>`, and `folderName` strips the
`-coreml` suffix from the slug `FluidInference/speaker-diarization-coreml`. Staging into a directory
named after the repository fails with `DownloadError.modelMissing(repo: "speaker-diarization", …)` —
an error that names the *folder* it looked in rather than the repo it wanted, so it sends you to
check the wrong thing. Verified by execution. The name is pinned in the installer
(`model_directory_name`), in `FluidAudioDiarizationRuntime.modelsDirectory`, and in a test.

### 3.3 `prepareModels()` deletes the staged models on any load failure — never call it

`OfflineDiarizerManager.prepareModels()` catches *any* error from `OfflineDiarizerModels.load` and
calls `purgeDiarizerRepo(at:)`, which is a `FileManager.removeItem` on the whole
`<parent>/speaker-diarization` directory, before attempting to re-download
(`OfflineDiarizerManager.swift:65`, `:100`, `:547` in the pinned checkout). One truncated file or one
Core ML execution-plan failure therefore deletes a pre-staged model set — on a machine that may have
no network to re-fetch it. That is the shape of this project's own 2026-08-14 library-index wipe, in
somebody else's code.

The app calls `OfflineDiarizerModels.load(from:configuration:)`, which only reads, and sets
`ModelHub.offlineMode = true` before any loader is touched. A test damages a staged tree, runs the
real loader, and asserts every file survives.

### 3.4 `process()` reaches `prepareModels()` for you if the manager holds no models

Avoiding the call by name is not enough: `OfflineDiarizerManager.prepare` — which `process` runs —
calls `prepareModels()` itself whenever `models == nil` (`OfflineDiarizerManager.swift:208`). So
`manager.initialize(models:)` after a successful `load` is not bookkeeping; omitting it hands the
purge path back through the front door. This is the landmine underneath the landmine, and it is the
reason §3.3's rule is expressed as two lines of code rather than one.

### 3.5 The threshold did not carry across, and could not

sherpa-onnx's 0.40 was a **cosine distance**; FluidAudio's threshold is a **Euclidean distance in
PLDA space** (its v0.15.6 semantics fix). They map as `euclidean = sqrt(2 − 2·cosine)`, so carrying
0.40 over would not have been conservative — it would have been a far more aggressive setting that
over-splits every meeting. The old constant was deleted rather than converted. See §1's Configuration
pin.

### 3.6 Cancellation propagation is days old upstream, so the adapter does not rely on it

FluidAudio only gained cancellation propagation into its segmentation and embedding loops on
2026-09-03 (PR #886), ten days before this adoption. The adapter checks `Task.checkCancellation()`
before the run **and again after it returns**, so a runtime that ignores a cancel still ends the job
as a `CancellationError` and no sidecar is written for a run the user stopped. Both paths are tested
(a runner that honours cancellation, and one that ignores it).

### 3.7 Silence throws; it is not an empty result

One second of digital silence raises `OfflineDiarizationError.noSpeechDetected` where sherpa-onnx
printed zero segment lines and exited 0. Surfaced raw, that becomes "analysis failed" for a meeting
recorded with the microphone muted — a user told their recording is broken when it is merely quiet.
The adapter maps that one case to an empty result; every layer above already handles zero turns.
Verified by execution, and it is also why the installer's smoke test asserts *zero turns* rather
than success.

---

## 4. Offline evidence

The requirement is *zero network calls after install*, and the shape of the proof changed with the
runtime. Stated plainly: **the offline guarantee is structurally weaker than the one the superseded
route had.**

sherpa-onnx ran in a child process that contained no network code at all — zero socket, URL or TLS
symbols, no networking framework linked, byte-identical output under a kernel-enforced
`(deny network*)` sandbox (§9.4). Offline was the *absence of a capability*, checkable by symbol
inspection in CI. FluidAudio runs inside WhisperMeet, a process that already links `URLSession` for
opt-in Claude summaries, so no symbol check can say anything about it. Offline is now a property of
the call paths this app takes, and it rests on four things:

1. **`ModelHub.offlineMode = true`, set exactly once before any loader is touched** — a `static let`
   whose initialiser runs on first use inside the runtime stage. In offline mode a failed load is
   rethrown untouched; with the flag off, the failure path is "delete the cache and re-download".
2. **`prepareModels()` is never called** (§3.3, §3.4). It is the only entry point that downloads, so
   not calling it keeps both the downloader and the purge out of reach.
3. **The installer does all fetching**, from pinned `https://huggingface.co/…` URLs, hashed in the
   same loop that fetches them, before anything is activated (§6). At analysis time every file is
   already on disk, and `isInstalled` refuses the run before a loader is touched if it is not.
4. **Nothing else in the analysis path can reach the network.** The adapter takes a file URL and a
   duration and returns turns. No URL, no token, no cache directory, no `from_pretrained`.

What is genuinely *not* offline any more is the **build**: `swift package resolve` fetches FluidAudio
and the 111 MB `NemoTextProcessing` artifact (§3.1). No part of that ships, so it is a
developer-machine cost rather than a user-machine one — but it is a real change from a manifest that
had no `dependencies:` at all, and it should not be described as anything else.

**The gap, recorded rather than implied away.** There is no kernel-sandbox control run for the
in-process path, because the process under test is the whole app and the app legitimately uses the
network elsewhere. What would close it is a network-deny sandbox around a `--diarization-smoke-test`
launch — an entry point that already exists (§6), runs before `App.main()`, and touches no other
subsystem. Not done; it belongs to F221's evidence pass, and it is listed in §8.

---

## 5. Measured behaviour

One machine, one meeting, two tracks. Everything below came from a throwaway SwiftPM harness built
against the pinned FluidAudio 0.15.7 and the staged Core ML bundles, outside this repository.
**Read §5.4 alongside it: none of this is an accuracy measurement.**

### 5.1 The subject

The same real 35-minute Mandarin video call the superseded runtime failed on, run at the user's
explicit instruction on one meeting from their own library — a deliberate, user-authorised exception
to the AGENTS.md rule against testing on user recordings. Read-only: segment *timings* only, no
transcript text read or retained, working copies written outside the library, and afterwards the
recording verified SHA-256 byte-identical with `meetings.json` untouched. Two tracks were analysed
separately: the mixed meeting (`real_meeting_16k.wav`, 2 116.5 s) and the microphone capture
(`mic_16k.wav`, 2 116.4 s).

### 5.2 Clusters, at the pin and across the threshold

At the pinned threshold 0.6 — FluidAudio's community default, which we did not change — the mixed
meeting returns **4 clusters**, 202 turns, 933.6 s of speech.

| threshold | clusters, mixed meeting | clusters, microphone track |
|---:|---:|---:|
| 0.3 | 5 | 6 |
| 0.4 | 5 | 6 |
| 0.5 | 4 | 6 |
| **0.6** *(the pin)* | **4** | **5** |
| 0.7 | 4 | 6 |
| 0.8 | 2 | 3 |
| 0.9 | 2 | 2 |
| 1.0 | 2 | 2 |
| 1.2 | 1 | 1 |
| 1.4 | 1 | 1 |

sherpa-onnx on the identical files produced **179 clusters** at its own pinned threshold, and nothing
in its range produced a plausible count at all: 33 was the floor on the mixed meeting, at the most
aggressive merge setting available, and the only run that reached 12 did so with
`min-duration-on=3.0`, which discards every utterance shorter than three seconds — most of
conversational speech. The full sweep is in `DIARIZATION_SCORECARD.md` §4.

Two properties of the FluidAudio column matter more than the headline number, because they are what
distinguishes a working clustering stage from a broken one. The count is **stable across a wide
band** — 4 from 0.5 through 0.7 — rather than sliding with the knob; and as the threshold widens it
degrades **towards merging** (2, then 1) rather than fragmenting without limit as it narrows. The
microphone track sits at 5 rather than 1, which is the *correct* behaviour for a track that carries
the whole call through speaker bleed (`DIARIZATION_SCORECARD.md` §4 measures the bleed directly).

### 5.3 Cost, determinism, and the sweep

| Measurement, 2 116.5 s of real audio | FluidAudio 0.15.7 | sherpa-onnx 1.13.8 |
|---|---:|---:|
| Wall clock | **5.92–6.03 s** | 78.5 s |
| RTF (wall ÷ audio) | **0.0028** | 0.037 |
| Real-time multiple | **≈352×** | ≈27× |
| Peak RSS | **645 447 680 B (615.5 MiB)** | 3 356 409 856 B (3 201 MiB) |

`/usr/bin/time -l` over the whole process, including Core ML compile and load (0.07–0.09 s warm) and
the audio read. Two runs on the meeting file measured RTF 0.00280 and 0.00285; the second run's peak
RSS was 625 197 056 B (596.2 MiB). PRD system gate 4 asks for p95 RTF ≤ 0.25: this is two orders of
magnitude inside it on this machine, and the memory figure is 5.2× smaller than the runtime it
replaces.

**Determinism: bit-identical, not merely equivalent.** Three consecutive runs on the microphone
track produced byte-identical turn dumps — `shasum -a 256` returned
`9d37db23234ae17e013a08fe0942a817d97d3960520a50578d970f0697c225d0` for all three, and for two
further runs earlier in the same evaluation, one of them with a cold Core ML compile. Two runs on the
meeting file agreed the same way
(`f2bf55cde06d87c403844e650a4e3dd615a36866ee445a5db9dfceec81d2b09a`).

**The `prepare`/`cluster` split is real, and it changes what calibration costs.** Segmentation and
embedding took 5.77 s for this meeting (1 059 chunks, 711 embeddings); every subsequent threshold in
the sweep above re-clustered in **0.19–0.25 s** without re-running a model. A full threshold sweep is
therefore seconds rather than hours, which is what makes F225 cheap the moment annotated audio
exists.

**One structural fact about the output:** across all 202 turns at the pin, **no two intervals
intersect**. The runtime reports one speaker at a time in this configuration, so the PRD's overlap
veto stays unreachable in production — F223, and §8.

### 5.4 What none of this measures

**Neither runtime has been measured against ground truth on real audio, because no ground truth
exists.** This meeting has no reference turns. Nothing above says whether a single label would have
been *right* — only how many clusters were invented, what they cost, and whether the answer is
stable.

**A plausible speaker count is a sanity check, not a quality gate.** Four clusters for a meeting with
a handful of participants is consistent with a system that works and equally consistent with one that
merged two quiet speakers and split a loud one. The synthetic TTS corpus cannot close the gap: it was
falsified as a calibration instrument, and the obvious repair — per-utterance gain and spectral tilt
to widen within-speaker spread — was tried and changed nothing (`DIARIZATION_SCORECARD.md` §4).

**The PRD's quality gate cannot be evaluated as written.** It reads "within three absolute DER points
of the Python Community-1 control"; that control was never built. The gate has no comparator, so it
is not passed, not failed, but unevaluable — and recording that is the only honest disposition.
Everything else here is n = 1 as well: one meeting, one language, one capture setup, one machine.

---

## 6. Installer contract — `Scripts/setup-speaker-diarization.sh`

Same skeleton as `Scripts/setup-qwen-asr.sh` and as the sherpa-era script this replaces: cross-process
lock, orphan reclaim, staged install, verify-before-swap, atomic activation with rollback. What
changed is everything below the skeleton — no Python, no venv, no tarballs to extract, no native
binary, and 21.6 MB of Core ML bundles instead of 51 MB of downloads.

**Target:** `~/Library/Application Support/WhisperMeet/Runtime/Diarization` (overridable as `$1`).
Models land at `<target>/models/speaker-diarization/…` — the extra `models` level exists because
FluidAudio is handed a models *parent* directory and appends the folder name itself.

**Names (unchanged):** staging `.Diarization-install-$$`, backup `.Diarization-backup-$$`, lock
`.Diarization-install.lock` acquired with `/usr/bin/shlock -p $$ -f`, flags `activation_complete=0`
and `lock_acquired=0`.

**Pinned constants at the top of the script:** the repo slug, the base URL, `model_directory_name`
(with the comment saying why it is not the slug), and `model_manifest` — 21 `"<relative path> <sha256>"`
entries, verbatim from §1.

**Preflight:**
1. `RECOVERY_ONLY` guard first. `DIARIZATION_INSTALL_RECOVERY_ONLY=1` skips the platform check, the
   notices check, the smoke-test-command check and all downloads, and exits 0 immediately after the
   reclaim block, so a build missing a bundled file can still reclaim an orphaned runtime at launch
   (F33).
2. Outside recovery mode: require `Darwin` + `arm64`.
3. Outside recovery mode: require the bundled `THIRD-PARTY-NOTICES.txt` next to the script. The
   runtime is not shippable without it, and CC-BY-4.0 makes that a licence obligation rather than a
   nicety.
4. Outside recovery mode: require an executable `smoke_test_command`. Checked **before** the
   download, because discovering after 21.6 MB that nothing can verify the payload is a worse way to
   say the same no.
5. `mkdir -p "$runtime_parent"`.

**Completeness predicate**, used by the reclaim logic and by the final check before activation:

```sh
runtime_is_complete() {
  candidate="$1"
  [[ -f "$candidate/THIRD-PARTY-NOTICES.txt" && -f "$candidate/MANIFEST" ]] || return 1
  for manifest_entry in "${model_manifest[@]}"; do
    [[ -f "$candidate/models/$model_directory_name/${manifest_entry%% *}" ]] || return 1
  done
  return 0
}
```

It requires **exactly** what `FluidAudioDiarizationRuntime.requiredModelFiles` requires, and
`diarizationInstallerManifestMatchesTheSwiftRequiredFiles` compares the two lists mechanically. A
subset on either side is how a tree the installer would refuse gets reported to the app as healthy —
a defect this project has already shipped once, which is why the check is a test and not a convention.

**Trap and lock:** `trap cleanup_and_restore EXIT` restoring `backup → target` when
`activation_complete -eq 0 && ! -e target && -e backup`, removing the staging directory, and releasing
the lock; `trap 'exit 130' HUP INT TERM`. Unchanged.

**Reclaim (under the lock, before any download):** promote a *complete* orphaned
`.Diarization-backup-*` if the canonical path is missing; delete incomplete backups; delete every
`.Diarization-install-*`. Then, if `RECOVERY_ONLY`, `exit 0`.

**Disk check:** ≥ 128 MiB free on `$runtime_parent` — the sherpa era's 512 MiB reduced to match a
payload that shrank by two thirds. Refusing a user with 300 MB free would be a refusal for a reason
that no longer exists.

**Download and hash in one loop.** `curl -fsSL --proto '=https' --tlsv1.2`, no credentials, no
`.netrc`, no token environment variable read — the repository is ungated.

```sh
for entry in "${model_manifest[@]}"; do
  relative_path="${entry%% *}"
  expected_sha256="${entry##* }"
  destination="$staged_models/$relative_path"
  mkdir -p "${destination:h}"
  download "$model_base_url/$relative_path" "$destination"
  verify_sha256 "$destination" "$expected_sha256" "$relative_path"
done
```

One list, not two. The sherpa script had three downloads and five separate payload checks, and
keeping those two lists in agreement was manual; here the iteration that fetches a file is the
iteration that hashes it, so "downloaded but never verified" is not a state the script can be edited
into.

**Manifest-completeness gate — the replacement for the espeak and socket symbol gates.** Those read a
native executable's symbol table to prove no GPL-3.0 espeak-ng was linked and no socket could be
opened. A `.mlmodelc` bundle is data: it exports no symbols, links nothing, and cannot open a socket,
so both gates are not merely unnecessary but meaningless — they would be auditing something the
installer no longer installs. What survives is the question they really asked, *is the payload exactly
what we pinned?*, and it is asked directly:

```sh
staged_models_match_manifest() {
  candidate="$1"
  [[ -d "$candidate" ]] || return 1
  if [[ -n "$(find "$candidate" ! -type d ! -type f -print -quit 2>/dev/null)" ]]; then
    return 1
  fi
  staged_files="$(cd "$candidate" && find . -type f -print | sed 's|^\./||' | sort)"
  pinned_files="$(print -l -- "${model_manifest[@]%% *}" | sort)"
  [[ "$staged_files" == "$pinned_files" ]]
}
```

Set equality, not a count: an **extra** file is an unpinned, unhashed payload, and the `! -type d
! -type f` probe refuses symlinks, which are a path out of the staged tree and into anything on the
machine.

**Notices and MANIFEST:** `cp` the bundled `THIRD-PARTY-NOTICES.txt` into the staging root,
`chmod 644`. The MANIFEST records `model_repo`, `model_directory`, `runtime_id`, `runtime_version`,
`cluster_threshold`, and one `sha256 <hash> <path>` line per pinned file, so an installed tree
describes its own provenance.

**Smoke test before activation.** The sherpa script ran the pinned CLI over a generated silent WAV,
because `--help` exits 0 and proves nothing about inference. The same argument applies with more
force here and the same test is kept — but nothing on a stock Mac can load a Core ML bundle from a
shell, and the diarizer is no longer a separate binary. So the installer calls **this app** back:

```sh
"$smoke_test_command" --diarization-smoke-test "$staging_directory/models"
```

`smoke_test_command` is `Contents/MacOS/WhisperMeet`, one directory over from the
`Contents/Resources` the script itself lives in, with a `.build/{release,debug}/WhisperMeet` fallback
for a source checkout — the same sibling-resolution shape the notices file uses.
`DiarizationInstallSmokeTest` runs before `App.main()`, so no window, `NSApplication` or permission
prompt is created; it generates one second of 16 kHz mono silence in a temporary directory, loads all
four bundles through `OfflineDiarizerModels.load` — **never `prepareModels()`** — runs the pipeline,
and exits non-zero unless the run produced zero speaker turns.

Two honest limits, recorded rather than implied away:
- **Silence does not exercise clustering.** There is nothing to cluster. What it does exercise is the
  expensive and machine-specific half: compiling and loading all four Core ML bundles and reading the
  PLDA parameters, which is the failure this gate exists to catch.
- **Silence is not "zero segments" to FluidAudio.** It throws
  `OfflineDiarizationError.noSpeechDetected`. The adapter maps that to an empty result, because "no
  speech in this recording" is a result and not a failure — surfaced raw it would tell a user whose
  microphone was muted for an hour that their analysis had crashed. Verified by execution.

Silence is also deliberately *generated*, never taken from a model release: every `.wav` in the
releases this project has surveyed carries no licence statement at all.

**Atomic activation with rollback** — byte for byte the Qwen pattern, unchanged from the sherpa
script: `target → backup`, `staging → target`, restore the backup if the swap fails,
`activation_complete=1`, remove the backup, release the lock, clear the trap.

**Final on-disk layout (20.6 MiB):**

```
~/Library/Application Support/WhisperMeet/Runtime/Diarization/
  models/speaker-diarization/Segmentation.mlmodelc/   5,  6,006,888 B
  models/speaker-diarization/FBank.mlmodelc/          5,  1,797,068 B
  models/speaker-diarization/Embedding.mlmodelc/      5, 13,494,485 B
  models/speaker-diarization/PldaRho.mlmodelc/        5,    211,560 B
  models/speaker-diarization/plda-parameters.json           89,416 B
  THIRD-PARTY-NOTICES.txt
  MANIFEST
```

---

## 7. Adapter contract — `FluidAudioDiarizationClient`

One file, `Sources/WhisperMeet/FluidAudioDiarizationClient.swift`, and it is the only place in the
app that says `import FluidAudio`. `WhisperCore` stays Foundation-only (the AGENTS.md purity rule),
which is the whole reason the runtime lives in the app target.

**The seam.** `diarize(audioURL:durationSeconds:progress:) async throws -> SpeakerDiarizationResult`
— the same contract the retired subprocess client satisfied, which is why
`AppModel.runSpeakerDiarization`, its guards, its cancellation, the sidecar and every
label-isolation guarantee above the seam were untouched by the swap. The runtime stage is injectable,
so remapping, validation and cancellation are testable without 21.6 MB of bundles or any audio.

**Configuration** is §1's Configuration pin, assembled in one place. `numSpeakers`, `minSpeakers` and
`maxSpeakers` stay nil: fixing a count would make a monologue grow a second voice.

**Loading order**, and it is load-bearing: `ModelHub.offlineMode = true`, then `isInstalled` (leaf
files, never directories — see §1's note on `mkdir -p`), then
`OfflineDiarizerModels.load(from:configuration:)`, then `manager.initialize(models:)`. Never
`prepareModels()`, by either of the two routes that reach it (§3.3, §3.4).

**Cluster ids.** FluidAudio emits `"S1"`, `"S2"`, … in its own internal order. `SpeakerTurns.densify`
— in `WhisperCore`, generic over the runtime's id type — remaps them to dense `0..<n` in
first-appearance order, keyed on the string **verbatim** rather than parsed. Parsing the digits back
out is the thing worth avoiding: the day an id stops being "S" plus digits, every parse returns the
same fallback, every turn collapses onto one cluster, and two voices are displayed as one
confidently-labelled speaker — the single error `SpeakerOverlay` cannot detect, because it sees one
cluster with no competitor and no overlap. Sorting happens in the adapter rather than in `densify`,
because ordering is the runtime's property and FluidAudio promises none.

**Confidence is `nil`.** FluidAudio reports a per-segment `qualityScore`, but it is not a per-turn
clustering confidence and no threshold for it has been earned on any corpus, so no score is recorded
rather than a misleading one. `uncertainBelowConfidence` ships at 0.0. F225 may revise this only with
a documented before/after table.

**Embeddings never cross the seam.** The adapter's own `Segment` carries three fields; FluidAudio's
`TimedSpeakerSegment` carries a 256-float embedding, which the PRD's anonymity rule forbids
retaining.

**Cancellation** is checked before the run and again after it returns (§3.6), so a cancelled job
always reaches `performSpeakerDiarization` as a `CancellationError` and never writes a sidecar.

**Errors** map onto what the app can already explain: `noSpeechDetected` → an empty result (§3.7); a
load failure → `runtimeDamaged` ("reinstall it in Settings"), since the files were present a moment
earlier; a Cocoa, OSStatus or AVFoundation error during analysis → `audioUnreadable`, because the
only file the stage touches is the prepared audio; anything else → `processFailed`. A
`CancellationError` is never remapped into any of them.

**Sidecar provenance.** `DiarizationProducer` records `runtimeID = "fluidaudio-offline-diarizer"`,
`runtimeVersion = "0.15.7"`, `clusterThreshold = 0.6`, and the SHA-256 of the two `weights/weight.bin`
files that *are* the models rather than their packaging — `Segmentation.mlmodelc` (`c3189a64…`) and
`Embedding.mlmodelc` (`99356b29…`), both pinned in §1. A result produced by the superseded runtime is
therefore still identifiable in an old sidecar, with no schema bump, which is what those fields were
put there for.

---

## 8. Residual risks

Ordered by how likely each is to overturn this decision. The sherpa-era risk list went with the
runtime it described; what survived it is here.

1. **Quality is unmeasured, and there is nothing to measure it against.** No ground truth, no
   control, n = 1 (§5.4). Everything known about this runtime's accuracy on WhisperMeet audio is that
   it produces a *plausible* cluster count on one meeting. **Falsifier:** annotated real audio, which
   is F221's evidence pass. Until it exists, any label shown to a user is an assertion nobody has
   checked.
2. **The threshold is upstream's, not ours.** 0.6 is what FluidAudio calibrated on pyannote
   community-1. The sweep in §5.2 shows the count is stable from 0.5 to 0.7, which is reassuring
   about robustness and says nothing about correctness. F225 re-derives it on annotated audio, made
   cheap by the `prepare`/`cluster` split.
3. **Peak memory now lives in the app's process.** 615.5 MiB at 35 minutes is a fifth of what the
   child process used, but the OS no longer reclaims it unconditionally when analysis ends or
   crashes, and nothing here measured a 90-minute meeting — several in the user's own library are
   longer. A duration ceiling remains a design requirement, not a follow-up.
4. **The lowest supported Apple Silicon configuration was not tested.** PRD gate 4 names it
   explicitly; everything here ran on one machine. With RTF 0.0028 against a 0.25 gate the risk is
   memory on an 8 GB M1, not speed.
5. **A dependency that can delete our models is one call away.** §3.3 and §3.4 are guarded in code
   and pinned by a test that damages a staged tree and asserts every file survives — but the guard is
   "do not call that function", and an upstream change can move where that function is reached from.
   Re-read `OfflineDiarizerManager` on every version bump. This is why the pin is `exact:`.
6. **Upstream is converging, not converged.** Four clustering-correctness fixes landed in the five
   weeks before adoption (#802 in v0.15.6; #891 and cancellation propagation #886 in v0.15.7). Treat
   any bump as a behaviour change until proven otherwise, with §5 as the baseline to compare against.
7. **The offline guarantee can no longer be proved by symbol inspection** (§4), and the sandbox
   control that would partly replace it has not been run.
8. **The attribution ledger is an engineering read, not a legal one.** The CC-BY-4.0 claim lives in
   README front-matter and inside the artifacts' own metadata, not in a LICENSE file, and the
   reasoning in §2 about re-hosting an ungated conversion of a gated upstream is well-supported but
   is still a reading. A human should sign off on `THIRD-PARTY-NOTICES.txt` before any build ships.
9. **The PRD's overlap veto is still unreachable** — now verified against real output rather than
   inferred: none of the 202 turns intersect, so `densify` never constructs an `.overlap` and the veto
   fires only for turns built by hand in fixtures. Real simultaneous speech arrives unmarked and may
   be named confidently. F223.
10. **Only Apple Silicon is covered.** The bundles were staged, hashed and loaded on this machine
    only; Intel is out of scope and was never fetched for.
11. **`swift package resolve` now needs the network** (§3.1), and the 111 MB artifact it fetches is
    checksum-pinned but third-party hosted. A clean checkout is no longer a hermetic build.
12. **PRD text remains partly stale.** `docs/SPEAKER_DIARIZATION_PRD.md` carries a correction header
    rather than a rewrite, and its policy amendment is still unapproved — **no implementation ticket
    may close as shipped until that is signed off**, regardless of this runtime selection.

---

## 9. Superseded — the sherpa-onnx route (selected and replaced on 2026-09-13)

Kept in full, and kept clearly marked. Three things in it are still binding:

- **The GPL/espeak finding (§9.1) is still true and still bars the `pip` distribution of
  sherpa-onnx, permanently.** The Python extension module statically links espeak-ng
  (GPL-3.0-or-later) itself; swapping in clean dylibs fixes nothing.
- **The real-meeting failure (`DIARIZATION_SCORECARD.md` §4, summarised in §9.5) is the evidence
  that justified this swap.** Without it, "FluidAudio is better" would be a preference.
- **The reasoning that foreclosed each rejected alternative** (§2's foreclosed list, drawn from this
  work) does not depend on which runtime won.

Nothing in §9 describes code that ships. The subprocess client, its stdout grammar parser and their
23 tests were deleted outright when the swap landed; `SpeakerTurns.densify` is the one piece that was
kept, moved to `WhisperCore`, and made generic over the runtime's id type.

### 9.1 The selection argument

**Selected: sherpa-onnx 1.13.8, shipped as the prebuilt `-no-tts-` native CLI
`sherpa-onnx-offline-speaker-diarization`, invoked as a subprocess. No Python, no pip, no SwiftPM
dependency.**

This reverses the assumption that carried through the research phase. The research leg measured the
stack through `pip install sherpa-onnx==1.13.8`. **The pip route is rejected on licence grounds, and
the rejection is stronger than previously documented**, because the prior evidence only checked
`libsherpa-onnx-c-api.dylib`. Measured today against the wheel actually installed in the evidence
venv:

```
$ nm -a venv/lib/python3.11/site-packages/sherpa_onnx/lib/_sherpa_onnx.cpython-311-darwin.so \
    | grep -oE '_espeak[A-Za-z_0-9]*' | sort -u | wc -l
      50
$ strings -a _sherpa_onnx.cpython-311-darwin.so | grep -c 'TTS is not enabled'
0
$ otool -L _sherpa_onnx.cpython-311-darwin.so
  /usr/lib/libSystem.B.dylib, @rpath/libonnxruntime.dylib, /usr/lib/libc++.1.dylib
```

The Python extension module **statically links espeak-ng (GPL-3.0-or-later) itself**, and it does
*not* link `libsherpa-onnx-c-api.dylib`. So swapping the clean `-no-tts-` dylibs into a pip install
fixes nothing, and the `-no-tts-lib` tarball contains no Python module at all (verified: it holds
exactly `lib/{libonnxruntime,libsherpa-onnx-c-api,libsherpa-onnx-cxx-api}.dylib`). There is no
licence-clean Python route short of building the wheel from source with
`-DSHERPA_ONNX_ENABLE_TTS=OFF`.

The resolution, verified today: the release also publishes a **full** `-no-tts` distribution (no
`-lib` suffix) containing `bin/` executables, among them `sherpa-onnx-offline-speaker-diarization`.
It is clean, it reproduces the Python results exactly, and it needs two files on disk.

### 9.2 Licence ledger — sherpa-onnx

Everything marked "verified present" was confirmed by symbol table or string inspection of the
binary we actually shipped (`bin/sherpa-onnx-offline-speaker-diarization`, `lib/libonnxruntime.dylib`).

| Artifact | Upstream project | Licence | Redistribution OK? | Attribution the app must show | Source URL |
|---|---|---|---|---|---|
| `sherpa-onnx-offline-speaker-diarization` (statically links the sherpa-onnx core) | k2-fsa/sherpa-onnx | Apache-2.0 | **Yes.** No upstream `NOTICE` file exists (raw `NOTICE` → HTTP 404), so §4(d) is inert; §4(a)/(b)/(c) apply | Full Apache-2.0 text; "sherpa-onnx, © the k2-fsa authors"; a modification statement **only if** we ever rebuild from patched source | https://github.com/k2-fsa/sherpa-onnx/blob/master/LICENSE |
| `libonnxruntime.dylib` 1.28.2 | microsoft/onnxruntime | MIT | **Yes** | Full MIT text + `Copyright (c) Microsoft Corporation`. Ship `ThirdPartyNotices.txt` too (conservative, customary). **The tarball ships no licence file — we must source this ourselves** | https://github.com/microsoft/onnxruntime/blob/main/LICENSE |
| kaldi-native-fbank (**verified present**: 33 `knf::` symbols incl. `knf::MelBanks::InitKaldiMelBanks`) | csukuangfj/kaldi-native-fbank | Apache-2.0 | **Yes** | Apache-2.0 text; retain notices | https://github.com/csukuangfj/kaldi-native-fbank/blob/master/LICENSE |
| kaldi-decoder (**verified present**: `kaldi_decoder::` symbols + build path `_deps/kaldi_decoder-src`) | csukuangfj/kaldi-decoder | Apache-2.0 | **Yes** | Apache-2.0 text; retain notices | https://github.com/csukuangfj/kaldi-decoder/blob/master/LICENSE |
| hclust-cpp — **the diarization clustering step** (**verified present**: `fastclustercpp::` symbols, `fastclustercpp::node`, `fastclustercpp::nan_error`) | csukuangfj/hclust-cpp | BSD-2-Clause (GitHub reports `NOASSERTION`; the text is 2-clause BSD) | **Yes**, with the binary-form condition | **Reproduce `Copyright (c) 2011 Daniel Müllner`, `Copyright (c) 2018 Christoph Dalitz`, both conditions, and the all-caps warranty disclaimer.** Easiest to miss because SPDX detection fails on it | https://github.com/csukuangfj/hclust-cpp/blob/master/LICENSE |
| `sherpa-onnx-pyannote-segmentation-3-0/model.onnx` | pyannote/segmentation-3.0, converted by k2-fsa | MIT | **Yes.** The HF gate is a mailing-list form on *HF's copy*, not a term of the MIT grant; the k2-fsa conversion pulled from the ungated `csukuangfj/pyannote-models` mirror, and the GitHub asset serves anonymously | Full MIT text + **`Copyright (c) 2022 CNRS`** (the line in the artifact we download; the HF mirror says 2023 — reproduce both). Credit pyannote.audio / Hervé Bredin (good practice). **Keep the tarball's own `LICENSE` file next to `model.onnx`** | https://github.com/k2-fsa/sherpa-onnx/releases/tag/speaker-segmentation-models |
| `3dspeaker_speech_campplus_sv_zh_en_16k-common_advanced.onnx` | 3D-Speaker (ModelScope / Alibaba `iic`) | Apache-2.0, declared **per model by the publisher** on ModelScope | **Yes** | Apache-2.0 text; attribute "3D-Speaker (ModelScope / Alibaba `iic`)"; cite `https://www.modelscope.cn/models/iic/speech_campplus_sv_zh_en_16k-common_advanced/summary` — which is embedded in the ONNX `metadata_props`, so **do not strip metadata** | https://github.com/modelscope/3D-Speaker/blob/main/LICENSE |
| espeak-ng | espeak-ng | GPL-3.0-or-later | **Must be absent** | — | https://github.com/espeak-ng/espeak-ng/blob/master/COPYING |
| nlohmann/json | nlohmann/json | MIT | n/a | **Not detected** in the shipped binary (0 strings, 0 symbols). No notice required unless a future rebuild pulls it in | — |

**Verified absent from everything we ship** (`bin/sherpa-onnx-offline-speaker-diarization`, all
three `lib/*.dylib`, and the other 28 binaries in the tarball): `espeak` symbol count **0**,
`espeak-ng-data` strings **0**, piper/phonemize strings **0**. `libsherpa-onnx-c-api.dylib`
additionally carries the `"TTS is not enabled"` stub marker (×1), the positive proof that this is a
no-TTS build.

**The `-no-tts` tarball ships no LICENSE file** (contents are exactly `bin/`, `include/`, `lib/`).
Every notice above has to be authored by us and bundled — `THIRD-PARTY-NOTICES.txt` in the app
bundle, surfaced in About → Legal, and copied into the runtime directory by the installer.

### 9.3 Why FluidAudio was not chosen the first time

The dispositive reason below — the no-SPM-dependency constraint — was lifted, and the record was
reopened the same day. Everything else in this section still reads true, and the landmines it names
are exactly the ones §3 now guards against. It is worth reading as written: it argued against the
runtime that was ultimately adopted, and its objections were not wrong, they were outweighed.

FluidAudio is the better diarizer. That is not in dispute and it should be recorded plainly, because
the decision is a trade, not a verdict on quality.

**Where FluidAudio is genuinely better:**

1. **Accuracy, by a wide margin.** It ports the full pyannote community-1 recipe: powerset
   segmentation + VBx + PLDA + **`constrained_argmax`** (Hungarian matching per segmentation chunk,
   so two speakers sharing a chunk cannot collapse onto one centroid). sherpa-onnx has agglomerative
   clustering and nothing else. FluidAudio's own PR #802 is a written demonstration that the missing
   piece is *precisely* what prevents silent speaker absorption — and silent absorption is exactly
   the failure we measured on our same-gender English clip (§9.5).
2. **Speed and battery.** RTFx 122–323 via the Apple Neural Engine versus our measured RTF ≈0.062
   (RTFx ≈16). A 90-minute meeting would be ~30 s instead of ~5.6 min.
3. **Published, CI-reproduced benchmarks** (VoxConverse 13.89–15.07 % avg DER; AMI SDM 10.6 %)
   versus nothing published for sherpa-onnx's diarization pipeline.
4. **No Python, no venv drift** — though our choice now shares that property.
5. **`prepare` / `cluster` split** gives a free, fast rerun-with-different-N; we have to re-run
   everything.
6. **Real `ThirdPartyLicenses/` hygiene**, better than most.
7. **21.6 MB of staged models**, an easier consent sheet than our 51 MB download.
8. Its one documented landmine (the macOS 14 BNNS crash, 1200/1200 reproduction) is outside
   WhisperMeet's `.macOS(.v15)` floor.

**Why it was still not chosen:**

- **The constraint is dispositive.** The product owner's rule is *no new SwiftPM third-party
  dependency*. WhisperMeet's `Package.swift` has no `dependencies:` at all today. FluidAudio would
  be the first, and it does not come alone: on toolchains below Swift 6.2 the `Package.swift`
  manifest always links a **remote checksum-pinned Rust xcframework** (`NemoTextProcessing`, fetched
  over the network at `swift package resolve` time) plus a C++ target. `traits: []` removes it —
  **only** on tools ≥ 6.2, so the manifest behaves differently per toolchain. Given that
  `swift test` in this repo already needs a bespoke framework/rpath invocation (F166), a
  toolchain-conditional manifest is a real operational tax, and `swift package resolve` itself
  wanting the network is at odds with a feature whose headline promise is that it never touches the
  network.
- **Its offline guarantee is a flag, ours is an absence.** `ModelHub.offlineMode` is real,
  documented and tested — but the *default* entry point `prepareModels()` calls `purgeDiarizerRepo`
  (a `FileManager.removeItem` on the whole repo directory) on **any** thrown load error, and that
  purge is **not** guarded by `offlineMode`. One corrupt byte or one execution-plan failure deletes
  a pre-staged model set on a machine that cannot re-download. Avoiding it means bypassing the
  documented API, and the published offline-staging doc names the **wrong five files** for this
  pipeline (it documents the legacy online `DiarizerManager`, not
  `ModelNames.OfflineDiarizer.requiredModels`). Given this codebase's own history — the
  library-index wipe postmortem — a delete-on-failure path in a dependency is the exact shape of
  risk we have been burned by.
- **Licence provenance is weaker, not stronger.** Its models are CC-BY-4.0 **asserted only in HF
  card front-matter with no LICENSE file in the repo**, and they are a re-host of a *gated* upstream
  (`pyannote/speaker-diarization-community-1`, `gated: auto`, anonymous config fetch → 401). Our
  segmentation model is MIT **with the licence file physically inside the artifact**, and our
  embedder is Apache-2.0 declared per model by its publisher. FluidAudio's own PR #802 discloses
  that its clustering defaults are *inferred from source semantics* because it cannot read the gated
  config.
- **Blast radius.** FluidAudio's peak memory lives inside the WhisperMeet process, and it writes
  ~230 MB/hour of temp audio to the system temp dir, leaked on crash. Ours lives in a child process
  the OS reclaims unconditionally.
- **Its quality numbers are currently unquotable anyway.** The AMI table is explicitly stale
  ("should be re-benchmarked on this branch"), and four clustering-correctness fixes landed in the
  five weeks before this decision (#802 in v0.15.6; #891 and cancellation-propagation #886 in
  v0.15.7, merged nine and ten days ago). We would have had to generate our own numbers regardless —
  which is F217's job either way.

**What would make us revisit.** Any one of these, and this record should be reopened:

1. F217's real-corpus scorecard shows sherpa-onnx failing PRD gate 2 (more than three absolute DER
   points from the Python control on the composite, or a stratum regression over five points) — the
   same-gender stratum is the likely trigger.
2. The product owner lifts or narrows the no-SPM-dependency constraint.
3. FluidAudio publishes a post-#801/#891 AMI table *and* `prepareModels()` stops purging on
   non-download failures *and* the staging documentation is corrected.
4. Upstream sherpa-onnx adds constrained per-chunk assignment (this would resolve it in our favour
   instead).

An adapter protocol (`func diarize(url:progress:) async throws -> [Turn]`) makes either engine a
one-file swap, so the cost of being wrong here is bounded — that is what makes choosing the more
contained, more licence-clean option the right default.

### 9.4 Offline evidence — sherpa-onnx

This is the proof shape that does **not** transfer to an in-process runtime, and §4 explains what
replaced it. It is kept because it is the reasoning that would have to be redone if this project ever
ships a native inference binary again.

The requirement is *zero network calls after install*. Four independent proofs, all executed on the
artifacts being shipped.

**(a) No network symbols.**

```
$ nm -u bin/sherpa-onnx-offline-speaker-diarization \
    | grep -cE '_connect$|_socket$|_getaddrinfo|_send$|_sendto|_recv|curl_|SSL_|CFURL|NSURL|_bind$|_listen$'
0
$ nm -u lib/libsherpa-onnx-c-api.dylib | grep -cE '…'      → 0
$ nm -u lib/libonnxruntime.dylib      | grep -cE '…'      → 1
$ nm -u lib/libonnxruntime.dylib | grep -E '…'
_OBJC_CLASS_$_NSURL          # CoreML model-file path handling, not a URL loader
```

Control that the check discriminates: the tarball's `sherpa-onnx-offline-websocket-server` returns
**4** for `_socket$|_bind$|_listen$|_accept$|_connect$`; our diarization binary returns **0**. (That
server is one of the 28 binaries the installer deletes.)

**(b) No network framework linked.**

```
$ otool -L bin/sherpa-onnx-offline-speaker-diarization
  /usr/lib/libSystem.B.dylib
  @rpath/libonnxruntime.dylib
  /usr/lib/libc++.1.dylib
```

No `libcurl`, no `CFNetwork`, no `Security`, no `Network.framework`. Without a TLS or URL-loading
framework there is no path to an HTTPS fetch.

**(c) Kernel-enforced sandbox run.** Profile `no-network.sb`:

```
(version 1)
(allow default)
(deny network*)
```

Control proving the sandbox bites: `sandbox-exec -f no-network.sb curl -m 8 https://github.com` →
`curl: (6) Could not resolve host: github.com`, exit 6.

Under that same sandbox, with every proxy variable `env -u`'d, the diarization run returned `EXIT=0`
and turns **identical** to the unsandboxed run:

```
0.031 -- 8.485 speaker_00
8.975 -- 18.695 speaker_02
19.268 -- 27.824 speaker_00
28.263 -- 38.017 speaker_02
38.523 -- 46.606 speaker_00
47.129 -- 56.090 speaker_02
```

(The only textual difference from the unsandboxed capture is the absence of `confidence=` fields,
because I omitted `--clustering.compute-confidence` on that invocation. Boundaries and speaker
assignment are byte-identical.)

**(d) Models can only enter as file paths.** The two `--*-model=` flags are the sole model input. A
missing file is rejected before any work: `--segmentation.pyannote-model=/nope.onnx` →
`Errors in config!`, exit **255**. There is no `from_pretrained`, no cache directory, no download
subcommand — and, unlike the Python route, no interpreter that could import one.

**Structural conclusion:** offline here is the *absence* of network code in the child process,
enforceable by symbol inspection in CI and by sandbox policy at run time. It is not a boolean that
every code path must remember to respect.

### 9.5 Measured behaviour — the synthetic TTS corpus

**These numbers are not wrong; they were answering the wrong question.** The micro-averaged 5.05 %
DER below is a measurement of text-to-speech, not of meetings: two utterances from one macOS voice
differ by almost nothing, so a threshold tuned just above that spread sits far below a real speaker's,
and agglomerative clustering then never merges. The same runtime that scored 5.05 % here produced 179
clusters on a real 35-minute meeting. `DIARIZATION_SCORECARD.md` §4 carries the falsification in
full, including the augmentation hypothesis that was tested and failed.

The corpus itself remains sound for what it is now used for — parsing, validation, abstention,
preservation, cancellation, determinism, label isolation — and must never again be used to calibrate
a clustering parameter.

All numbers below are from the **shipping native binary** (not the Python evidence run), on this
Mac, at `--clustering.cluster-threshold=0.3`,
`--segmentation.num-threads=4 --embedding.num-threads=4`, `model.onnx` (fp32).

#### Corpus

Five synthetic clips built with `say` → `afconvert -f WAVE -d LEI16@16000 -c 1`, each part
energy-trimmed and concatenated with an exact 0.500 s digital-silence gap, so ground truth is
concatenation arithmetic rather than an estimate. Six `ABABAB` turns per clip. Scored with a
from-scratch md-eval/pyannote-compatible scorer that passes the pyannote golden vector exactly
(`total=31 correct=22 miss=2 fa=7 conf=7 DER=16/31`), uses the speaker-weighted `Σ d·N_ref`
denominator, a global Hungarian mapping with zero-co-occurrence pairs dropped, pyannote's full-width
collar convention, and micro-averaging.

#### Accuracy

| Clip | Voices | Turns found | Speakers | DER (collar 0, overlap kept) | DER (NIST collar 0.25 s, overlap skipped) |
|---|---|---:|---:|---:|---:|
| `en` | Samantha en_US F / Daniel en_GB M | 6 | 2 | **0.96 %** | 0.00 % |
| `zh` | Tingting zh_CN F / Meijia zh_TW F | 6 | 2 | **7.55 %** | 0.60 % |
| `zhmf` | Tingting F / Rocko M | 6 | 2 | **1.65 %** | 0.00 % |
| `zhgp` | Tingting F / Grandpa M | 6 | 2 | **1.73 %** | 0.00 % |
| `enff` | Samantha en_US F / Karen en_AU F | 8 | 2 | **14.23 %** | 10.63 % |
| **Micro-average** | 302.72 s of reference speaker-time | | | **5.05 %** | **1.97 %** |

The native binary reproduces the Python evidence run's micro-averages **to the digit** (5.05 % /
1.97 %) and its per-turn boundaries exactly. English and Mandarin are handled equally well when the
two voices differ in timbre; the single bilingual embedder covers both, as intended.

English boundary accuracy, all 12 boundaries, worst error **0.105 s**. Mandarin `zh` worst error
**1.067 s**; `zhmf` 0.216 s; `zhgp` 0.317 s.

#### The one bad result, stated plainly

`enff` (two female English voices) is the ceiling, and the failure mode is the damaging one —
**silent speaker absorption**, not an "uncertain" state:

```
0.031 --  8.452 speaker_00     ← correct (A)
9.025 --  9.970 speaker_00     ← wrong: this is B
9.970 -- 16.028 speaker_01     ← correct (B)
16.028 -- 28.583 speaker_00    ← ~7 s of B absorbed into A
```

No knob fixes it. Cosine distance between CAM++ embeddings of the two speakers is ≈0.29 (same-gender
pairs, both `enff` and `zh`) versus 0.72–0.84 for cross-gender pairs; within-speaker similarity is
≥0.9196 everywhere, so the embedder separates every pair with margin ≥ +0.21 — the clustering stage,
not the embedder, is the limit. sherpa-onnx has no constrained per-chunk assignment and no VBx
refinement to prevent it.

#### Two findings that are configuration decisions, both re-verified on the native binary

**`--clustering.num-clusters` is not a usable "I know there are N speakers" control.** It is not a
floor, not a cap, and not monotonic:

```
zh --clustering.num-clusters=2 -> segments=1  distinct_speakers=1
zh --clustering.num-clusters=3 -> segments=1  distinct_speakers=1
zh --clustering.num-clusters=4 -> segments=1  distinct_speakers=1
zh --clustering.num-clusters=5 -> segments=6  distinct_speakers=2   ← correct answer, wrong question
```

Asking for 2 speakers on a 2-speaker file returns 1. Do not build UI on it.

**The default `threshold=0.5` collapses same-gender pairs to a single speaker.** With no flags at
all, `zh` returns one turn spanning the whole file: `0.031 -- 69.910 speaker_00` — DER 52.72 %.
Micro-averaged across the corpus, threshold 0.5 costs about 10 DER points versus 0.3 (15.11 % vs
5.05 %, measured on the Python leg across the same clips). Below 0.25 it over-splits the easy clips.

**`model.int8.onnx` is not a free win and must not ship.** Micro-averaged DER (collar 0): int8 30.46
% / 16.41 % / 20.30 % / 15.81 % at thresholds 0.2 / 0.3 / 0.4 / 0.5, versus fp32's 5.05 % at 0.3 —
and no single threshold works across clips for int8. The 4.5 MB saving costs correctness.

#### Performance (`/usr/bin/time -l`, includes process start and model load)

| Audio | Wall (real) | RTF | Max RSS | Peak footprint |
|---|---:|---:|---:|---:|
| 56.19 s (`en`) | 3.13 s | 0.0557 | 186,007,552 B (177.4 MiB) | 170,705,496 B |
| 69.89 s (`zh`) | 3.88 s | 0.0555 | 200,851,456 B (191.5 MiB) | 185,582,216 B |
| 899.04 s (15 min) | 55.30 s | 0.0615 | 493,584,384 B (470.7 MiB) | 478,446,408 B |
| 1798.08 s (30 min) | 111.11 s | 0.0618 | 766,984,192 B (731.4 MiB) | 684,262,432 B |

Linear fit over 56 s → 1798 s: **333.5 kB per second of audio = 0.318 MiB/s ≈ 19.1 MiB/min ≈ 1.12
GiB/hour**, on a **159.5 MiB** intercept.

Projections (arithmetic, not measured): **1-hour meeting ≈ 1.27 GiB RSS, ≈3.7 min wall. 3-hour
meeting ≈ 3.5 GiB RSS, ≈11.2 min wall.**

The native binary is slightly leaner than the Python route measured earlier (731.4 MiB vs 819.6 MiB
at 30 minutes; 177.4 MiB vs 189.2 MiB at 56 s) — the interpreter and the float-list copy are gone.

**PRD system gate 4 (p95 RTF ≤ 0.25):** passes with ~4× headroom on this machine. The gate's actual
wording is "on the lowest supported Apple Silicon configuration", which was **not** tested — see §8.

Thread scaling (measured on the Python leg, same models, same machine): 1 → RTF 0.141, 2 → 0.081,
**4 → 0.053**, 6 → 0.054, 8 → 0.059 (regresses). `num-threads=4` on both sub-configs.

Segmentation runs first with no progress; on `en` it took 1.030 s of a 3.688 s total, so roughly
**28 % of wall elapses before the first progress tick**.

### 9.6 Installer contract and pins — sherpa-onnx

Kept because the tarball prune, the espeak gate and the socket gate are the reasoning that would have
to be redone if this project ever ships a native inference binary again. The pinned hashes below are
the record of the route that was built and then replaced; §1 is what the installer fetches today.

Same skeleton as `Scripts/setup-qwen-asr.sh`, with the pip/venv stage replaced by tarball extraction
and an aggressive prune. No Homebrew, no Python, no `pip`.

**Target:** `~/Library/Application Support/WhisperMeet/Runtime/Diarization` (overridable as `$1`).

**Names (mirroring the Qwen installer):**
- staging `"$runtime_parent/.Diarization-install-$$"`
- backup `"$runtime_parent/.Diarization-backup-$$"`
- lock `"$runtime_parent/.Diarization-install.lock"`, acquired with
  `/usr/bin/shlock -p $$ -f "$lock_file"`
- flags `activation_complete=0`, `lock_acquired=0`

**Pinned constants at the top of the script** — every sherpa-era pin, verbatim (this record no
longer carries that table; the MANIFEST below preserves the hashes), including the misspelled
`speaker-recongition-models` path segment with a comment saying it is upstream's typo and not to
be "fixed".

**Preflight:**
1. `RECOVERY_ONLY` guard first. `DIARIZATION_INSTALL_RECOVERY_ONLY=1` skips the platform check, the
   notices-file check, all downloads, and exits 0 immediately after the reclaim block — exactly as
   `QWEN_INSTALL_RECOVERY_ONLY` does, so a build missing a bundled file can still reclaim an
   orphaned runtime at launch (F33).
2. Outside recovery mode: require `Darwin` + `arm64`, else exit 1 with "Speaker analysis requires an
   Apple-silicon Mac."
3. Outside recovery mode: require the bundled `THIRD-PARTY-NOTICES.txt` next to the script (the
   analogue of the Qwen helper-source check). The runtime is not shippable without it.
4. `mkdir -p "$runtime_parent"`.

**Completeness predicate** (used by both the reclaim logic and the final check):

```sh
runtime_is_complete() {
  candidate="$1"
  [[ -x "$candidate/bin/sherpa-onnx-offline-speaker-diarization"
    && -f "$candidate/lib/libonnxruntime.dylib"
    && -f "$candidate/models/segmentation/model.onnx"
    && -f "$candidate/models/segmentation/LICENSE"
    && -f "$candidate/models/embedding/campplus_zh_en.onnx"
    && -f "$candidate/THIRD-PARTY-NOTICES.txt"
    && -f "$candidate/MANIFEST" ]]
}
```

**Trap and lock:** `trap cleanup_and_restore EXIT` restoring `backup → target` when
`activation_complete -eq 0 && ! -e target && -e backup`, removing the staging directory, and
releasing the lock; `trap 'exit 130' HUP INT TERM`. Identical semantics to the Qwen script.

**Reclaim (under the lock, before any download):** if the canonical path is missing, promote a
*complete* orphaned `.Diarization-backup-*`; delete incomplete backups; delete every
`.Diarization-install-*`. Then, if `RECOVERY_ONLY`, `exit 0`.

**Disk check:** require ≥ 512 MiB free on `$runtime_parent` (51 MiB of downloads, ~62 MiB of full
extraction, ~61 MiB of final layout, plus slack), else exit 1.

**Download into staging** — `curl -fsSL --proto '=https' --tlsv1.2`, three artifacts, no
credentials, no `.netrc`, no token env var read.

**SHA-256 gate before anything is extracted, and again before the swap.** Each of the three
downloaded files is checked with `shasum -a 256` against its pinned constant; a mismatch prints
"Speaker-analysis model verification failed; the existing runtime was not changed." and exits 1 —
the trap restores the previous runtime untouched. After extraction, the four kept payload files
(`bin/…-diarization`, `lib/libonnxruntime.dylib`, `models/segmentation/model.onnx`,
`models/embedding/campplus_zh_en.onnx`) are hashed again against their pinned constants. An archive
that hashes correctly but unpacks wrong never activates.

**Prune — this is a licence and attack-surface requirement, not tidiness.** From the runtime tarball
keep exactly two files:

```
bin/sherpa-onnx-offline-speaker-diarization
lib/libonnxruntime.dylib
```

Delete the other 28 binaries, both `libsherpa-onnx-*.dylib`, and `include/`. **The deleted set
includes `sherpa-onnx-offline-websocket-server` and `sherpa-onnx-online-websocket-server`, which do
contain socket symbols.** Verified: the two-file layout runs correctly and unchanged
(`@loader_path/../lib` rpath resolves), total 28 MB.

From the segmentation tarball keep `model.onnx`, `LICENSE`, `README.md`; delete `model.int8.onnx`
(so it cannot be selected by accident) and the bundled `.py`/`.sh` scripts.

**GPL gate, run in the installer and again in CI** (a naive `grep -i espeak` false-positives on
"spe**aker**", so match the symbol form):

```sh
if nm -a "$staging_directory/bin/sherpa-onnx-offline-speaker-diarization" | grep -qE '_espeak[A-Za-z_]*'; then
  print -u2 "Speaker-analysis runtime failed its licence check; nothing was changed."
  exit 1
fi
if nm -u "$staging_directory/bin/sherpa-onnx-offline-speaker-diarization" \
     | grep -qE '_socket$|_bind$|_listen$|_connect$'; then
  print -u2 "Speaker-analysis runtime failed its offline check; nothing was changed."
  exit 1
fi
```

**Notices:** `cp` the bundled `THIRD-PARTY-NOTICES.txt` into the staging root, `chmod 644`. The
segmentation `LICENSE` stays next to `model.onnx` and is never stripped.

**MANIFEST** (same shape as Qwen's), written into staging:

```
sherpa_onnx_version=1.13.8
sherpa_onnx_git_sha1=11afbd00
runtime_asset=sherpa-onnx-v1.13.8-osx-arm64-shared-no-tts.tar.bz2
runtime_asset_sha256=91b96512c4fa1960f8a9ed5360a6c8dda53a4b5015d0590244f14086a234557a
diarization_binary_sha256=e1170a93308867d8e343ac22a00b46b1d8e786c763c32a17caff07cf934ff66f
onnxruntime_dylib_sha256=3567d114f7299d559993e536d605a6f46d7bc9d2542004accc80ee9bf5457f0b
segmentation_asset_sha256=24615ee884c897d9d2ba09bb4d30da6bb1b15e685065962db5b02e76e4996488
segmentation_model_sha256=220ad67ca923bef2fa91f2390c786097bf305bceb5e261d4af67b38e938e1079
embedding_model_sha256=aa3cfc16963a10586a9393f5035d6d6b57e98d358b347f80c2a30bf4f00ceba2
cluster_threshold=0.3
num_threads=4
```

**Smoke test before activation**, replacing Qwen's `--help` checks. `--help` exits 0 and proves
nothing about inference, so instead generate a 1-second 16 kHz mono silence WAV *in staging*
(`printf`/`dd` into a WAV header — never one of the upstream test `.wav` files, whose licence is
UNESTABLISHED) and run the real pipeline against it. Verified behaviour: **exit 0**, zero segment
lines on stdout, `progress 100.00%` and `Duration : 1.000 s` on stderr. Require exit 0 and zero
segment lines; delete the WAV.

**Atomic activation with rollback** — byte-for-byte the Qwen pattern:

```sh
if [[ -e "$target_directory" ]]; then mv "$target_directory" "$backup_directory"; fi
if ! mv "$staging_directory" "$target_directory"; then
  if [[ -e "$backup_directory" ]]; then mv "$backup_directory" "$target_directory"; fi
  print -u2 "The new speaker-analysis runtime could not be activated; the previous runtime was restored."
  exit 1
fi
activation_complete=1
[[ -e "$backup_directory" ]] && rm -rf "$backup_directory"
rm -f "$lock_file"; lock_acquired=0
trap - EXIT HUP INT TERM
print "Speaker analysis is ready at $target_directory"
```

**Final on-disk layout (60.5 MiB):**

```
~/Library/Application Support/WhisperMeet/Runtime/Diarization/
  bin/sherpa-onnx-offline-speaker-diarization        405,440 B
  lib/libonnxruntime.dylib                        28,775,120 B
  models/segmentation/model.onnx                   5,992,913 B
  models/segmentation/LICENSE                          1,061 B   (MIT, © 2022 CNRS — never strip)
  models/segmentation/README.md                          115 B   (provenance)
  models/embedding/campplus_zh_en.onnx            28,281,164 B
  THIRD-PARTY-NOTICES.txt
  MANIFEST
```

### 9.7 Helper contract — the sherpa-onnx subprocess grammar

> **Historical.** There is no subprocess any more: FluidAudio runs in-process, so the argv/stdout
> grammar below describes nothing that ships. What replaced it is `FluidAudioDiarizationClient`,
> whose contract is the same `SpeakerDiarizationResult` this grammar was parsed into — which is why
> nothing above the adapter seam changed. The sidecar JSON in this section is still the shape
> written today — only the engine fields differ, and §7 records what they now hold.
>
> **Retired in code 2026-09-13 (F216/F219).** The grammar below is now documentation only.
> `Sources/WhisperCore/LocalDiarizationClient.swift` (the subprocess adapter, its line reader and
> its bounded diagnostic log), `Sources/WhisperCore/DiarizationOutputParser.swift` (the segment and
> progress regexes, the `confidence=n/a` and `-2.0` sentinels, and `classify`'s four exit-255
> failure markers) and their 23 tests were deleted: maintaining a parser for a runtime nothing
> invokes is a standing invitation to trust it again. Kept, and moved:
>
> - `SpeakerTurns.densify` → `Sources/WhisperCore/SpeakerTurn.swift`. The first-appearance remap is
>   not a property of any runtime — every diarizer allocates cluster ids that are private to its own
>   clustering pass, and "Speaker 1" has to mean the first voice heard. It is now generic over the
>   runtime's own id type (sherpa's sparse `Int`, FluidAudio's `String`) and
>   `FluidAudioDiarizationClient.densify` delegates to it, so there is one implementation of the
>   rule rather than two.
> - `DiarizationRuntime`, `SpeakerDiarizationResult`, `LocalDiarizationError` →
>   `Sources/WhisperCore/DiarizationRuntime.swift`. `DiarizationRuntime` kept only
>   `managedDirectory` and `uncertainBelowConfidence`; its sherpa-era `clusterThreshold` (0.40,
>   a cosine distance) and `numThreads` (a `--segmentation.num-threads` value) went with the flags
>   that consumed them.

**There is no Python helper.** The decision removes the interpreter, so `Scripts/` gains no new
`.py` file and the `Runtime/Diarization` tree contains no venv. The "helper" is the pinned binary,
and the Swift adapter speaks to it over argv / stdout / stderr / exit status. Every line of the
grammar below was observed in the runs recorded in §9.4–§9.5.

#### Invocation

```
<Runtime>/bin/sherpa-onnx-offline-speaker-diarization
  --print-args=false
  --clustering.cluster-threshold=0.3
  --clustering.compute-confidence=true
  --segmentation.num-threads=4
  --embedding.num-threads=4
  --segmentation.pyannote-model=<Runtime>/models/segmentation/model.onnx
  --embedding.model=<Runtime>/models/embedding/campplus_zh_en.onnx
  <absolute path to 16 kHz mono 16-bit PCM WAV>
```

- `--print-args=false` is **required**: with the default `true` the binary echoes full argv —
  including the recording path — and that would land in logs. It does **not** silence everything: a
  one-line `OfflineSpeakerDiarizationConfig(...)` dump, carrying the two model paths, still precedes
  `Started` on stdout. Both facts are handled by the same adapter rule below — discard every line
  until `Started` — but the flag alone is not sufficient, and the preamble must never be logged
  verbatim.
- `--clustering.num-clusters` is **forbidden** (§9.5).
- Environment: clear `HTTP_PROXY`/`HTTPS_PROXY`/`ALL_PROXY` and their lowercase forms. Nothing reads
  them, but a hostile proxy env should not even be visible. Run under the network-deny sandbox
  profile where the app's own sandboxing allows it.
- `stdin` is unused; close it.

#### stdout grammar (verified)

```
line 1     OfflineSpeakerDiarizationConfig(...)      ← one long config dump; CONTAINS THE WAV PATH
line 2     Started
line 3..N  <start> -- <end> speaker_<NN> confidence=<0.NNN>
```

Segment line, exact form: `0.031 -- 8.485 speaker_00 confidence=0.707`. Regex:
`^\s*([0-9]+\.[0-9]+)\s*--\s*([0-9]+\.[0-9]+)\s+speaker_([0-9]+)(?:\s+confidence=(n/a|-?[0-9.]+))?\s*$`.
(The `n/a` alternative is load-bearing — see the confidence note below.)

Adapter rules:
- **Discard everything until the literal line `Started`.** Never log line 1 verbatim — it embeds the
  recording path.
- Times are **seconds**, already sorted by start time.
- **Speaker ids are not dense.** Real output from `en`:
  `speaker_00, speaker_02, speaker_00, speaker_02, …`. Remap to `0..N-1` in first-appearance order
  before anything reaches the UI or the sidecar.
- `confidence` has **three** forms, not two: a float in `[-1, 1]`; the literal string **`n/a`**; or
  absent (when `--clustering.compute-confidence` is off). **Corrected 2026-09-13 after the F217
  corpus run:** `n/a` is what the runtime actually prints when only one cluster formed — `mono_1spk`
  and `zh_2spk_alt` emitted it for 100% of their turns. A pattern accepting only digits fails the
  whole line and silently discards every turn of a single-speaker recording. Both `n/a` and the
  `-2.0` sentinel (only one cluster formed, or no overlapping embedding interval)
  and must be surfaced as "unavailable", not as a low score. Valid range is `[-1, 1]`.
- Zero segment lines with exit 0 is a **legitimate** result (silence, or audio too short) and must
  render as "no speaker turns found", not as an error.

#### stderr grammar (verified)

```
progress 1.09%
progress 2.17%
...
progress 100.00%
Duration : 56.190 s
Elapsed seconds: 2.989 s
Real time factor (RTF): 2.989 / 56.190 = 0.053
```

- 92 progress lines for a 56.19 s clip — roughly one per second of audio, but the count is only
  knowable after segmentation finishes, so do not derive a total from duration.
- **Progress covers only the embedding phase.** ~28 % of wall time elapses before the first tick
  (segmentation 1.030 s of 3.688 s on `en`). The UI must show an indeterminate phase until the first
  `progress` line, then map `progress` onto the remaining portion. An honest ETA can be seeded from
  the measured RTF (0.055–0.062, stable from 56 s to 30 min) and refined once ticks start.
- Parse with a strict regex; treat any unmatched stderr line as diagnostic text, log it at debug
  level only, and never surface it raw to the user.

#### JSON the adapter produces (the sidecar payload, not the binary's output)

```json
{
  "schema": "diarization.turns.v1",
  "engine": "sherpa-onnx",
  "engine_version": "1.13.8",
  "engine_git_sha1": "11afbd00",
  "segmentation_model_sha256": "220ad67ca923bef2fa91f2390c786097bf305bceb5e261d4af67b38e938e1079",
  "embedding_model_sha256": "aa3cfc16963a10586a9393f5035d6d6b57e98d358b347f80c2a30bf4f00ceba2",
  "cluster_threshold": 0.3,
  "audio_seconds": 56.19,
  "wall_seconds": 3.13,
  "speaker_count": 2,
  "turns": [
    {"start": 0.031, "end": 8.485, "speaker": 0, "confidence": 0.707},
    {"start": 8.975, "end": 18.695, "speaker": 1, "confidence": 0.641}
  ]
}
```

`speaker` is the **dense remapped** index. `raw_speaker` is deliberately not persisted. No
embeddings, no file paths, no voice profile — consistent with the PRD's hard privacy rules.

#### Error behaviour (all verified)

| Condition | Exit | Distinguishing stderr/stdout marker | Adapter action |
|---|---:|---|---|
| Missing or unreadable model file | **255** | `Errors in config!` | Runtime is damaged → trigger the installer's reclaim/reinstall path; preserve the transcript |
| WAV missing or unreadable | **255** | `Failed to read <path>` | Source-audio error; explain plainly |
| Wrong sample rate | **255** | `Expect sample rate 16000. Given: 44100` | Adapter bug — it must resample to 16 kHz mono before spawning. (Note this is *better* than the Python API, which silently produced garbage timestamps) |
| 1 s of silence | 0 | no segment lines; `Duration : 1.000 s` | "No speaker turns found" |
| Success | 0 | `Started` + ≥1 segment line | Parse |
| Cancelled by user | signal | — | See below |

**Cancellation is process termination.** There is no in-band cancel: `SIGTERM` the child, then
`SIGKILL` after a grace period, and discard partial stdout. The OS reclaims the child's entire (up
to multi-GiB) footprint. Treat a signalled exit as "cancelled", never as a failure.

**Memory budget is an adapter responsibility.** ~1.12 GiB per hour of audio plus a 159.5 MiB
baseline, in the child. The adapter must refuse or warn above a configured duration ceiling rather
than let a 3-hour import reach ~3.5 GiB unannounced.

**Testability:** the seam is the executable path. Point it at a shell script that emits a canned
stdout/stderr transcript and an exit code, and the entire adapter — including the non-dense-id
remap, the sentinel-confidence path, the zero-turn path, and each of the four error markers — is
unit-testable with no models, no audio, and no network. This matches how the existing
Qwen/Whisper/Summarizer helpers are already tested.

**If real in-process control is ever needed** (finer progress, in-band cancel, no text parsing), the
`-no-tts` tarball also ships `include/sherpa-onnx/c-api/{c-api.h,cxx-api.h}` and
`lib/libsherpa-onnx-c-api.dylib`, both verified espeak-free, so a small compiled helper is available
without changing any licence conclusion. That is not needed for the first release.
