# F216 — Decision record: local speaker-diarization runtime

**Status:** Runtime selected (not a ship approval — the PRD quality gate remains open and is
F217/F221's job). **Decided:** 2026-09-13. **Verified on:** this Mac, Apple Silicon arm64, macOS
26.6.2 (build 25G83). **Supersedes:** the PRD's "spike FluidAudio first" recommendation
(`docs/SPEAKER_DIARIZATION_PRD.md` §Selection rule / candidate matrix), which predates the product
owner's no-new-SwiftPM-dependency constraint. **Evidence:** produced in a throwaway directory
outside the repository; no user meeting, recording, index, or transcript was read. Every hash below
was recomputed independently after the investigation (`shasum -a 256`), and the espeak/socket symbol
checks and a live two-speaker run were reproduced before this record was committed. Nothing here is
reproduced from memory — regenerate it by following §6 and §7 against the pinned URLs.

---

## 1. Decision

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

### Pins

| Role | Artifact | Bytes | SHA-256 |
|---|---|---:|---|
| Runtime tarball | `sherpa-onnx-v1.13.8-osx-arm64-shared-no-tts.tar.bz2` | 18,252,168 | `91b96512c4fa1960f8a9ed5360a6c8dda53a4b5015d0590244f14086a234557a` |
| └ kept: diarization CLI | `bin/sherpa-onnx-offline-speaker-diarization` | 405,440 | `e1170a93308867d8e343ac22a00b46b1d8e786c763c32a17caff07cf934ff66f` |
| └ kept: ONNX Runtime | `lib/libonnxruntime.dylib` | 28,775,120 | `3567d114f7299d559993e536d605a6f46d7bc9d2542004accc80ee9bf5457f0b` |
| Segmentation tarball | `sherpa-onnx-pyannote-segmentation-3-0.tar.bz2` | 6,958,444 | `24615ee884c897d9d2ba09bb4d30da6bb1b15e685065962db5b02e76e4996488` |
| └ kept: model | `model.onnx` | 5,992,913 | `220ad67ca923bef2fa91f2390c786097bf305bceb5e261d4af67b38e938e1079` |
| └ kept: licence | `LICENSE` (MIT, © 2022 CNRS) | 1,061 | `14d7016ad68e7394d6e6b78d96cc2ae431c905287b89674cfdf021e79e62b8ba` |
| └ kept: provenance | `README.md` | 115 | `0380ed76a50efcc421dc62f251ed06e8349688466beac3177bee6e00dc336bfc` |
| Embedding model | `3dspeaker_speech_campplus_sv_zh_en_16k-common_advanced.onnx` | 28,281,164 | `aa3cfc16963a10586a9393f5035d6d6b57e98d358b347f80c2a30bf4f00ceba2` |

URLs (all fetched anonymously — no token, no account, no click-through):

```
https://github.com/k2-fsa/sherpa-onnx/releases/download/v1.13.8/sherpa-onnx-v1.13.8-osx-arm64-shared-no-tts.tar.bz2
https://github.com/k2-fsa/sherpa-onnx/releases/download/speaker-segmentation-models/sherpa-onnx-pyannote-segmentation-3-0.tar.bz2
https://github.com/k2-fsa/sherpa-onnx/releases/download/speaker-recongition-models/3dspeaker_speech_campplus_sv_zh_en_16k-common_advanced.onnx
```

Notes on the pins:
- **`speaker-recongition-models` is a real upstream typo** and must be hard-coded.
  `speaker-recognition-models` returns HTTP 404.
- The embedding hash matches the release's own `checksum.txt` verbatim. The segmentation release
  publishes no checksums; those three hashes are ours, computed from the artifact we downloaded.
- Version self-report from the shipped binary:
  `sherpa-onnx version : 1.13.8 / Git SHA1: 11afbd00 / Git date: Thu Sep 10 13:52:45 2026 / onnxruntime version : 1.28.2`.
- **Download total: 53,491,776 B (51.0 MiB). On disk after pruning: 63,455,813 B (60.5 MiB).**
- Apple Silicon only, matching the existing Qwen3-ASR constraint. A
  `-osx-universal2-shared-no-tts.tar.bz2` and an `-osx-x64-` variant exist on the same release but
  were **not** downloaded or verified; do not pin them without repeating this work.

### Configuration pin (this is part of the decision, not tuning)

```
--clustering.cluster-threshold=0.40     # re-derived on the F217 corpus; see the note below
--segmentation.num-threads=4 --embedding.num-threads=4
--clustering.compute-confidence=true
--print-args=false
# never --clustering.num-clusters
# never model.int8.onnx
```

> **Threshold re-pinned 0.30 → 0.40 on 2026-09-13 (F217).** The 0.30 above was calibrated on five
> two-speaker clips, which is the wrong sample for the cases that actually fail. Swept over seven
> thresholds × 18 corpus fixtures and scored as the product behaves (conservative overlay plus
> single-cluster suppression): 0.3–0.6 is a flat plateau, 0.7 falls off a cliff, and **0.40 gives the
> best displayed-label precision, 90.8 % at 68.8 % coverage**. The axis is asymmetric, which is why
> this is not simply "tune for DER": too low over-splits, and the overlay abstains on the rows that
> become ambiguous; too high merges two speakers into one cluster, which no guard in the product can
> detect. Erring low costs coverage, erring high costs correctness. Full reasoning in
> `DIARIZATION_SCORECARD.md`.

### What this decision is not

This selects a runtime that satisfies the licence, offline, packaging, and performance constraints.
It does **not** clear PRD go/no-go gate 2 (quality). The only accuracy evidence is five synthetic
TTS clips, and one of them — same-gender English — fails at 14.23 % DER with silent speaker
absorption. See §8.

---

## 2. Licence and attribution ledger

Everything marked "verified present" was confirmed by symbol table or string inspection of the
binary we actually ship (`bin/sherpa-onnx-offline-speaker-diarization`, `lib/libonnxruntime.dylib`).

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

### Explicitly foreclosed (do not revisit without new evidence)

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

## 3. Why not FluidAudio

FluidAudio is the better diarizer. That is not in dispute and it should be recorded plainly, because
the decision is a trade, not a verdict on quality.

**Where FluidAudio is genuinely better:**

1. **Accuracy, by a wide margin.** It ports the full pyannote community-1 recipe: powerset
   segmentation + VBx + PLDA + **`constrained_argmax`** (Hungarian matching per segmentation chunk,
   so two speakers sharing a chunk cannot collapse onto one centroid). sherpa-onnx has agglomerative
   clustering and nothing else. FluidAudio's own PR #802 is a written demonstration that the missing
   piece is *precisely* what prevents silent speaker absorption — and silent absorption is exactly
   the failure we measured on our same-gender English clip (§5).
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

---

## 4. Offline evidence

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

---

## 5. Measured behaviour

All numbers below are from the **shipping native binary** (not the Python evidence run), on this
Mac, at `--clustering.cluster-threshold=0.3`,
`--segmentation.num-threads=4 --embedding.num-threads=4`, `model.onnx` (fp32).

### Corpus

Five synthetic clips built with `say` → `afconvert -f WAVE -d LEI16@16000 -c 1`, each part
energy-trimmed and concatenated with an exact 0.500 s digital-silence gap, so ground truth is
concatenation arithmetic rather than an estimate. Six `ABABAB` turns per clip. Scored with a
from-scratch md-eval/pyannote-compatible scorer that passes the pyannote golden vector exactly
(`total=31 correct=22 miss=2 fa=7 conf=7 DER=16/31`), uses the speaker-weighted `Σ d·N_ref`
denominator, a global Hungarian mapping with zero-co-occurrence pairs dropped, pyannote's full-width
collar convention, and micro-averaging.

### Accuracy

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

### The one bad result, stated plainly

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

### Two findings that are configuration decisions, both re-verified on the native binary

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

### Performance (`/usr/bin/time -l`, includes process start and model load)

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

---

## 6. Installer contract — `Scripts/setup-speaker-diarization.sh`

Same skeleton as `Scripts/setup-qwen-asr.sh`, with the pip/venv stage replaced by tarball extraction
and an aggressive prune. No Homebrew, no Python, no `pip`.

**Target:** `~/Library/Application Support/WhisperMeet/Runtime/Diarization` (overridable as `$1`).

**Names (mirroring the Qwen installer):**
- staging `"$runtime_parent/.Diarization-install-$$"`
- backup `"$runtime_parent/.Diarization-backup-$$"`
- lock `"$runtime_parent/.Diarization-install.lock"`, acquired with
  `/usr/bin/shlock -p $$ -f "$lock_file"`
- flags `activation_complete=0`, `lock_acquired=0`

**Pinned constants at the top of the script** — every value from §1, verbatim, including the
misspelled `speaker-recongition-models` path segment with a comment saying it is upstream's typo and
not to be "fixed".

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

---

## 7. Helper contract

**There is no Python helper.** The decision removes the interpreter, so `Scripts/` gains no new
`.py` file and the `Runtime/Diarization` tree contains no venv. The "helper" is the pinned binary,
and the Swift adapter speaks to it over argv / stdout / stderr / exit status. Every line of the
grammar below was observed in the runs recorded in §4–§5.

### Invocation

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
- `--clustering.num-clusters` is **forbidden** (§5).
- Environment: clear `HTTP_PROXY`/`HTTPS_PROXY`/`ALL_PROXY` and their lowercase forms. Nothing reads
  them, but a hostile proxy env should not even be visible. Run under the network-deny sandbox
  profile where the app's own sandboxing allows it.
- `stdin` is unused; close it.

### stdout grammar (verified)

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

### stderr grammar (verified)

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

### JSON the adapter produces (the sidecar payload, not the binary's output)

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

### Error behaviour (all verified)

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

---

## 8. Residual risks

Ordered by how likely each is to overturn this decision.

1. **Quality on real meeting audio is unmeasured, and the corpus is a floor, not a prediction.**
   Five synthetic TTS clips, six turns each, ~1 minute apiece, 302.72 s of speaker-time total,
   **zero overlap, zero crosstalk, no reverb, no room noise, clean single channel**. Real meetings
   have every one of those. The 5.05 % micro-average proves the stack is wired correctly and the
   models load and run; it says nothing about AMI-like conditions, where published pyannote-family
   numbers sit around 10–15 % DER and sherpa-onnx's simpler clustering should be expected to do
   worse. **Falsifier:** F217's real-corpus scorecard. If sherpa-onnx lands more than three absolute
   DER points from the Python control on the composite, or regresses any stratum by more than five
   points, PRD gate 2 fails and this decision is void.
2. **Same-gender speakers produce silent absorption at ~14 % DER and no knob fixes it.** This is the
   failure mode most damaging to a diarization UI — a confident, plausible, wrong label rather than
   an "uncertain" state. It is a direct consequence of sherpa-onnx having no constrained per-chunk
   assignment. If the PRD's quality gate is tighter than this on real audio, **the FluidAudio
   comparison leg becomes load-bearing again** and the no-SPM constraint has to be revisited or the
   feature does not ship.
3. **`threshold=0.3` is calibrated to five synthetic clips on one embedder.** It is not a principled
   value; it is the best of the values tried. It is also embedder-specific: the earlier research
   derived ≈0.9 for the ERes2Net embedder on the same pipeline. F217 must re-derive it on the real
   corpus, and the value must move into a versioned constant that the sidecar records (which is why
   `cluster_threshold` is in both `MANIFEST` and the JSON).
4. **The lowest supported Apple Silicon configuration was not tested.** PRD gate 4 names it
   explicitly. Everything here ran on one machine (macOS 26.6.2, Apple Silicon). On an 8 GB M1, a
   3-hour recording's projected ~3.5 GiB child would be a real memory-pressure risk, and the RTF
   headroom (0.062 against a 0.25 gate) is unverified on the slower part. **Falsifier:** a long-form
   sentinel run on the floor configuration.
5. **The memory projections beyond 30 minutes are arithmetic, not measurement.** The linear fit is
   clean across 56 s → 1798 s (0.318 MiB/s), but 1-hour and 3-hour figures are extrapolations. There
   is no streaming path in sherpa-onnx and no chunking that preserves global clustering, so a hard
   duration ceiling is a design requirement, not a follow-up.
6. **Only the arm64 artifact is verified.** The universal2 and x64 `-no-tts` assets exist on the
   same release but were not downloaded, hashed, or symbol-checked. Shipping Intel support requires
   repeating §1, §2 and §4 for that asset.
7. **Upstream release assets are mutable in principle.** GitHub release assets can be replaced. The
   SHA-256 gate turns that into a loud install failure rather than a silent substitution, which is
   the correct behaviour — but it means an upstream change breaks installs until we re-pin. The
   segmentation release publishes no upstream checksums at all, so three of our eight hashes have no
   second source.
8. **The attribution ledger is an engineering read, not a legal one.** Specifically: the pyannote
   MIT copyright-year discrepancy (© 2022 CNRS in the artifact, © 2023 CNRS on the HF mirror); the
   fact that the HF gate on `pyannote/segmentation-3.0` is a mailing-list form whose own text says
   the model "uses MIT license and will always remain open-source" — a reading that is
   well-supported but is still a reading; and hclust-cpp's BSD-2-Clause text under a GitHub
   `NOASSERTION` label. A human should sign off on `THIRD-PARTY-NOTICES.txt` before any build ships.
9. **Determinism across runs is only weakly established.** Boundaries were byte-identical between
   the sandboxed and unsandboxed `en` runs and between the native and Python paths, but no formal
   three-run stability test was performed. PRD gate 4 requires output stable across three runs; that
   is a cheap test F217 should add.
10. **PRD text is now stale.** `docs/SPEAKER_DIARIZATION_PRD.md` still names FluidAudio as the first
    spike and cites the wrong offline-staging document as evidence. It must be amended alongside
    this record, and the policy amendment in its "Required decision before implementation" section
    is still unapproved — **no implementation ticket may close as shipped until that is signed
    off**, regardless of this runtime selection.
11. **The runtime reports no overlap at all, so the PRD's overlap veto is dead in production.**
    sherpa-onnx emits one speaker per line and never marks simultaneity, so
    `DiarizationOutputParser.densify` — the only production constructor of a `SpeakerTurn` — can
    produce `.speech` and `.uncertain` but never `.overlap`. Task 4's veto ("an overlap anywhere in
    the segment vetoes a name") is implemented and tested, and fires only for turns built by hand in
    test fixtures. Real simultaneous speech therefore arrives as two intersecting `.speech`
    intervals, passes through unmarked, and the overlay may name one of the two voices confidently.
    This compounds risk 2 rather than mitigating it: crosstalk is absent from the corpus, so nothing
    measured here exercises the case. **Falsifier / fix:** F223, which derives `.overlap` by
    splitting intersecting raw turns. Until it lands, `overlayVetoIsUnreachableFromRuntimeOutput`
    pins the gap, and any claim that the veto protects a real meeting is false.
