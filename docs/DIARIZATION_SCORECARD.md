# Speaker analysis — measured behaviour and release decision

**Tickets:** F216 (runtime selection), F217 (corpus and scorer), F221 (evidence and go/no-go).
**Measured:** 2026-09-13, Apple silicon, macOS 26.6.2 (build 25G83).
**Runtimes measured:** sherpa-onnx 1.13.8 native `-no-tts` binary (pyannote segmentation 3.0,
3D-Speaker CAM++ zh_en) — **rejected**. FluidAudio 0.15.7 offline diarizer (the pyannote
`speaker-diarization-community-1` Core ML conversion) — **adopted**. Pins, licences and the full
reasoning are in [`DIARIZATION_RUNTIME_DECISION.md`](DIARIZATION_RUNTIME_DECISION.md).

> **Decision: adopt FluidAudio. That is a runtime choice, not a quality result.**
>
> sherpa-onnx does not work on real meeting audio and no configuration fixes it: on a real 35-minute
> meeting with a handful of participants it produced between 33 and 179 speaker clusters (§4). On the
> identical file FluidAudio produces **4 clusters** at its default threshold, for a fifth of the
> memory and thirteen times the speed, bit-identically across runs (§5). The synthetic corpus had
> said 90.8 % displayed-label precision for sherpa-onnx; that number describes text-to-speech, not
> meetings, which is why §2 must never again be used to calibrate anything.
>
> **Neither runtime has been measured against ground truth on real audio, because none exists** (§6).
> Cluster counts, resource use and determinism are all there is. A plausible speaker count is a
> sanity check, not a quality gate.

## 1. How to read this

Three numbers matter, in this order:

1. **Displayed-label precision** — of the transcript rows that receive a label, how many are right.
   This is what a reader experiences. A feature whose posture is *abstain rather than guess* lives or
   dies here.
2. **Coverage** — how often it is willing to say anything. Precision at 5 % coverage is worthless.
3. **DER** — the literature-comparable figure. Useful for comparing systems, poor at describing what
   a person sees, and dominated by whoever spoke most.

Every DER and precision figure below is scored with
`Scripts/bench/diarization/score_diarization.py`, validated against pyannote.metrics' published
golden vectors before producing any number here (`--self-test`: 13/13, including the exact component
breakdown `total=31 correct=22 miss=2 fa=7 conf=7 DER=16/31`).

**All three numbers exist only for the synthetic corpus (§2).** The real-meeting sections (§4, §5)
report cluster counts and resource use, because scoring needs a reference and there is none — §6.

## 2. The synthetic corpus — sherpa-onnx

*These are sherpa-onnx numbers, and they are kept because §4 only means something next to them. They
were measured before the real-meeting run falsified this corpus as a calibration instrument.*

Eighteen fixtures, `Scripts/bench/diarization/manifest.json`, generated from macOS system voices.
Ground truth is concatenation arithmetic — each utterance synthesised separately, measured with
`afinfo`, energy-trimmed, placed at a known offset — so boundaries are exact, not annotated.
Regeneration is byte-identical from a wiped cache. Generated audio is gitignored; the manifest and
per-fixture hashes are committed.

Scored as the product behaves (conservative overlay **plus** single-cluster suppression):

| threshold | micro DER | displayed precision | coverage |
|---:|---:|---:|---:|
| 0.30 | 20.58 % | 89.0 % | 67.2 % |
| **0.40** | **20.05 %** | **90.8 %** | **68.8 %** |
| 0.50 | 19.73 % | 89.6 % | 71.4 % |
| 0.60 | 19.86 % | 88.9 % | 71.4 % |
| 0.70 | 38.77 % | — | — |
| 0.80 | 39.24 % | — | — |

Per stratum at 0.40:

| stratum | DER | speakers ref→hyp | displayed precision |
|---|---:|---|---:|
| 2-speaker, different voices | 2.5 % | 2→2 | 100 % |
| 1 speaker (monologue) | 0.4 % | 1→1 | suppressed |
| rapid turns (<2 s) | 9.1 % | 2→2 | 100 % |
| controlled overlap | 2.5 % | 2→2 | 100 % |
| noise (SNR 3 dB / 10 dB) | 4.9 % / 4.7 % | 2→2 | 100 % |
| long-form 30 min | 19.9 % | 3→4 | 100 % |
| music / no speech | n/a | 0→0 | 0 s false alarm |
| **2 same-gender voices (en)** | **57.2 %** | **2→1** | suppressed |
| **2 same-gender voices (zh)** | **51.5 %** | **2→1** | suppressed |
| 3 speakers | 32.2 % | 3→2 | 66.7 % |
| code-switching en/zh | 55.9 % | 2→1 | suppressed |

Controls were added specifically to separate speaker *count* from voice *similarity*:
`en_2spk_samegender` is the two-speaker fixture with the male voice swapped for a second female
voice, same script; `en_3spk_distinct` is the three-speaker fixture with dissimilar voices. Count is
not the driver — similarity is.

**Determinism:** identical output across three runs on four fixtures including the 30-minute
sentinel.

## 3. Two mechanisms that convert model error into abstention

Measured, not assumed:

1. **The conservative overlay rule** (≥ 80 % coverage, ≥ 20-point margin, no intersecting overlap).
   On the F216 fixtures this alone gave 100 % displayed precision at 93.3 % coverage.
2. **Single-cluster suppression.** When analysis distinguishes exactly one voice, no labels are shown
   at all. Without it, a failed two-speaker separation labels every row "Speaker 1" — and renaming
   that cluster to a person's name then attributes the other person's words to them.

A per-turn confidence floor was evaluated and **rejected**: it duplicates what the overlay already
does and costs 6.6 points of coverage for no precision gain. `uncertainBelowConfidence` ships at 0.0.
(A second, independent reason now: FluidAudio reports no per-turn clustering confidence at all — its
`qualityScore` is not one — so the adapter records no score rather than a misleading one, and there
is nothing for a floor to threshold.)

Neither mechanism detects an error *within* a turn — a span that is mostly speaker A quietly
containing several seconds of speaker B looks perfect to the overlay.

## 4. Real meeting validation — sherpa-onnx, and why §2 does not survive it

Run at the user's explicit instruction on one meeting from their own library. `AGENTS.md` normally
forbids reading a user recording for testing; this was a deliberate, user-authorised exception.
Read-only: segment *timings* only, no transcript text read or retained, working copy written outside
the library. Verified afterwards — recording SHA-256 byte-identical, `meetings.json` untouched, no
new file in the recording folder.

**Subject:** 35.3 min, Mandarin, video call, 278 timed transcript rows, `meeting-recovered.wav`.

### Full mixed meeting

| threshold | clusters | peak RSS |
|---:|---:|---:|
| 0.40 *(the §2 pin)* | **179** | 3 201 MB |
| 0.50 | 148 | 2 516 MB |
| 0.60 | 115 | 1 905 MB |
| 0.70 | 91 | 1 389 MB |
| 0.80 | 64 | 1 042 MB |
| 0.90 | 49 | 786 MB |
| 0.95 | 33 | 694 MB |

### The microphone track

Run separately to test whether codec-compressed remote audio was the cause. **Correction:** this track
was initially described as single-speaker. It is not. Measured envelope analysis shows only **10 s** of
mic-only activity across the whole meeting, **720 s** with both tracks active, and the mic sitting just
**10.5 dB** below its own speech level while the remote side alone is talking — open speakers, not
headphones. The microphone hears the entire call, so this track contains several voices and no claim
of the form "N clusters for one person" can be made from it. This meeting contains no clean
single-speaker sample.

What the track does still establish is that the fragmentation is not *caused* by the mixed/compressed
system feed, since it reproduces on the microphone capture as well:

| setting | clusters on the mic track (several voices via bleed) |
|---|---:|
| threshold 0.40 | 121 |
| threshold 0.70 | 52 |
| threshold 0.80 | 35 |
| threshold 0.90 | 23 |
| threshold 0.99 *(maximum)* | 17 |
| threshold 0.95 + `min-duration-on=3.0`, `min-duration-off=2.0` | **12** |

No configuration brings the count near a plausible participant number. The last row is independently
unusable: `min-duration-on=3.0` discards every utterance shorter than three seconds,
which is most conversational speech. `--clustering.num-clusters` does not help and is documented
non-functional (asking for 2 on a 2-speaker file returns 1).

Because the fragmentation reproduces on the *microphone* track, it is **not** caused by
codec-compressed remote audio.

Nor is it a long-recording effect. A **two-minute** excerpt (600–720 s) fragments comparably —
13 clusters at threshold 0.40, 8 at 0.70, 5 at 0.90, 4 at 0.99. **Correction:** that excerpt was
initially described as one person speaking. Envelope analysis shows the remote side active for 81 of
its 120 seconds and the local microphone for only 19, so it is a multi-voice sample and the figures
above are not "clusters for one voice". They do still show that the fragmentation needs no long
recording.

### Why the synthetic corpus pointed the wrong way

Within-speaker embedding spread. Two utterances by one real person minutes apart differ by distance
from the microphone, energy, emotion and channel state. Two utterances from one macOS voice differ by
almost nothing. A threshold tuned just above the synthetic within-speaker spread sits far *below* the
real one, and agglomerative clustering then never merges. Real audio at 0.40 behaves as synthetic
audio did at 0.10.

**Consequence for the corpus's role:** it remains sound for *correctness* — parsing, validation,
abstention, preservation, cancellation, determinism, label isolation — and must never again be used
to calibrate a clustering parameter.

**Can the corpus be made predictive? Tried, and no — not easily.** The obvious fix is to widen
within-speaker spread synthetically. This was tested: each utterance of the clean two-speaker fixture
was given an independent gain (−7…+3 dB) and a per-utterance spectral tilt, simulating a speaker
moving relative to the microphone. The result was **2 clusters at both threshold 0.40 and 0.80 —
unchanged, and still correct**. The CAM++ embedder is robust to level and mild spectral shaping, so
that class of augmentation does not reproduce the failure.

Whatever distinguishes real speech here is harder to synthesise — genuine pitch and vocal-effort
variation, speaking-rate change, room acoustics, microphone response. It may not be reachable with
TTS plus signal processing at all. **Do not assume a cheap augmentation will close this gap; the
reliable path to a calibration number is real recorded audio.** Recorded as a negative result so the
idea is not re-attempted from scratch.

### Memory

Peak RSS tracks cluster count, so a correct threshold would reduce it — but the F216 projection of
~1.12 GiB/hour came from synthetic audio and was 5× low at this length. At the observed rate, several
meetings in the user's own library (93.6, 81.7, 74.5 min) would need 7–8.5 GB. On an 8 GB Mac that is
a memory-pressure termination, not a slow run.

### What this does not establish

No DER and no precision on real audio: a real meeting has no reference turns, so nothing here says
whether a label would have been *right* — only how many clusters were invented and what it cost.
n = 1: one meeting, one language, one capture setup, one machine. That is enough to fail a gate and
not enough to pass one. §6 states the same limit for the runtime that replaced this one.

## 5. FluidAudio on the same two files

Measured with a throwaway SwiftPM harness built against the pinned FluidAudio 0.15.7 and the staged
Core ML bundles, outside the repository. Same audio, same machine, same day, and the same read-only
handling as §4: segment timings only, working copies outside the library, recording verified
SHA-256 byte-identical afterwards and `meetings.json` untouched.

### Clusters

At the **default threshold 0.6** — FluidAudio's own community preset, and the value the app pins
unchanged — the mixed meeting returns **4 clusters**, 202 turns, 933.6 s of speech.

| threshold | clusters, mixed meeting | clusters, microphone track |
|---:|---:|---:|
| 0.3 | 5 | 6 |
| 0.4 | 5 | 6 |
| 0.5 | 4 | 6 |
| **0.6** *(the default, and the pin)* | **4** | **5** |
| 0.7 | 4 | 6 |
| 0.8 | 2 | 3 |
| 0.9 | 2 | 2 |
| 1.0 | 2 | 2 |
| 1.2 | 1 | 1 |
| 1.4 | 1 | 1 |

sherpa-onnx at its own pin, on the identical files: **179** and **121**.

Two properties matter more than the headline number, because they are the difference between a
working clustering stage and a broken one. The count is **stable across a wide band** — 4 from 0.5
through 0.7 — instead of tracking the knob the way §4's table does; and as the threshold widens it
degrades by **merging** (2, then 1) rather than fragmenting without limit as it narrows. The
microphone track sitting at 5 rather than 1 is *correct*, for the reason §4 records: that track hears
the whole call.

### Cost and determinism

| 2 116.5 s of real audio | FluidAudio 0.15.7 | sherpa-onnx 1.13.8 |
|---|---:|---:|
| Wall clock | **5.92–6.03 s** | 78.5 s |
| RTF (wall ÷ audio) | **0.0028** | 0.037 |
| Real-time multiple | **≈352×** | ≈27× |
| Peak RSS | **645 447 680 B (615.5 MiB)** | 3 356 409 856 B (3 201 MiB) |

`/usr/bin/time -l` over the whole process, including Core ML compile and load (0.07–0.09 s warm) and
the audio read. The repeat run measured RTF 0.00285 and 625 197 056 B (596.2 MiB) peak RSS.

**Memory scales with duration, and it is the number worth watching.** Peak RSS is not flat — the
whole file is held and clustered at once, so a longer meeting costs more:

| audio duration | wall clock | peak RSS |
|---:|---:|---:|
| 35.3 min (the real meeting) | 5.9 s | 615 MiB |
| 180.0 min (`ui-long-cancel.wav`) | 59.2 s | **1 538 MiB** |

Roughly 8.5 MiB per minute of audio. Three hours — longer than any meeting this app has recorded —
stays inside 1.5 GB, so no duration cap is needed on the machines this ships to. Measured with
`Scripts/bench/diarization/make-ui-fixtures.sh audio`, which builds that three-hour fixture; it exists
because a 46-minute meeting analyses in ~15 s, too fast to exercise the Cancel button (F230).

**Determinism is bit-identical, not merely equivalent.** Three consecutive runs on the microphone
track produced byte-identical turn dumps — `shasum -a 256` returned
`9d37db23234ae17e013a08fe0942a817d97d3960520a50578d970f0697c225d0` for all three, and for two further
runs earlier in the same evaluation, one of them with a cold Core ML compile. Two runs on the meeting file
agreed the same way (`f2bf55cde06d87c403844e650a4e3dd615a36866ee445a5db9dfceec81d2b09a`).

**Calibration is cheap on this runtime.** Segmentation and embedding took 5.77 s for this meeting
(1 059 chunks, 711 embeddings); every later threshold in the sweep above re-clustered in
**0.19–0.25 s** without re-running a model. A sweep point cost 78 s on sherpa-onnx and costs 0.2 s
here, which is what makes re-deriving the threshold (F225) worth doing properly the moment annotated
audio exists.

**No intersecting turns.** Across all 202 turns at the default threshold, no two intervals overlap,
so the PRD's overlap veto remains unreachable in production — F223.

### What changed the answer

Not the threshold, and not the audio. sherpa-onnx clusters embeddings agglomeratively and has nothing
that models how one person's voice moves across 35 minutes. FluidAudio runs VBx over PLDA scores with
constrained per-chunk assignment, which is precisely a model of that variability. §4's falsification
predicted this: the failure was within-speaker spread, so the fix had to be a method that expects it
rather than a threshold that tolerates it.

## 6. What neither runtime has measured

**Neither runtime has been measured against ground truth on real audio, because none exists.** This
meeting has no reference turns. Cluster counts, resource use and determinism are all there is, and
nothing in §4 or §5 says whether a single displayed label would have been *right*.

**A plausible speaker count is a sanity check, not a quality gate.** Four clusters for a meeting with
a handful of participants is consistent with a system that works and equally consistent with one that
merged two quiet speakers and split a loud one. Evidence of this kind is enough to **fail** a gate —
179 clusters is unambiguous — and never enough to pass one.

**The synthetic corpus cannot stand in for the missing reference.** §2's figures are text-to-speech
measurements; §4 falsified them as predictors of real behaviour, and the obvious repair — widening
within-speaker spread with gain and spectral-tilt augmentation — was tried and changed nothing at all.

**The PRD's quality gate cannot be evaluated as written.** It reads "within three absolute DER points
of the Python Community-1 control". **That control was never built**, so the gate has no comparator:
it is not passed, it is not failed, it is unevaluable. Recorded here rather than scored against
nothing.

**n = 1 in every other dimension too:** one meeting, one language, one capture setup, one machine.

## 7. Gates

| Gate | Result |
|---|---|
Assessed for the adopted runtime, with the rejected one alongside where the comparison is the point.

| Gate | Result |
|---|---|
| **Safety** — preservation, offline-after-install, no label leak, degraded library, corrupt/newer sidecar, cancellation, temp cleanup | Met in the test suite, on both runtimes; the recording was verified byte-identical after every real run. |
| **Quality** — per-stratum DER against a pre-registered target | **Cannot be evaluated as written** (§6): the Python Community-1 comparator the PRD names was never built. What *is* known: sherpa-onnx fails any reading of it (33–179 clusters where 1–6 are correct); FluidAudio produces a plausible count on one meeting, which is not a pass. |
| **Value** — blinded navigation study | **Not run.** Requires human participants. |
| **System** — p95 RTF ≤ 0.25, no memory-pressure termination on the long-form sentinel at the lowest supported configuration, three-run determinism | **RTF met** with two orders of magnitude of headroom (0.0028). **Determinism met**, bit-identically across three runs on real audio. **Memory** is 615.5 MiB at 35 min — a fifth of sherpa-onnx's 3 201 MiB — but **untested beyond 35 minutes and untested on the floor configuration**, which the gate names explicitly. |
| **Trust** — VoiceOver, keyboard, Dynamic Type, wording in the installed app | **Not run.** Requires manual validation. |

## 8. Decision

**Adopt FluidAudio as the runtime. Do not ship speaker labels yet.** Those are two decisions and only
the first is settled.

sherpa-onnx is rejected on evidence (§4). FluidAudio is adopted on evidence that it is *usable* —
plausible, stable across a wide threshold band, cheap, and bit-deterministic (§5) — not on evidence
that it is *correct*, which nobody has (§6). The PRD's own rule still governs the second decision:
*"If no candidate clears every gate, the correct result is do not ship diarization."* The quality
gate is not cleared. It is unevaluable, which is not the same thing as cleared, and the difference
must not be quietly collapsed in favour of shipping.

What stands regardless of runtime, because all of it sits behind the diarization adapter and the
`AppModel.runSpeakerDiarization` seam:

- the pure core — turn validation, the conservative overlay reconciler, the timing fingerprint
- the versioned `diarization.json` sidecar with atomic writes, quarantine and staleness detection
- the guarded, cancellable AppModel job
- label isolation from every default output path
- the corpus, the validated scorer, and the whole test suite

That is no longer a claim: swapping sherpa-onnx for FluidAudio changed one adapter file and one
installer, and nothing above the seam moved.

**Next, in order:**

1. **Annotated real audio (F221).** Until it exists, every figure in this document is a sanity check
   and the quality gate stays unevaluable.
2. **Re-derive the clustering threshold on it (F225).** 0.6 is upstream's value, not ours, and a
   sweep point now costs 0.2 s.
3. **Overlap detection is not available from this runtime at all (F223 closed invalid; F232).**
   Measured directly rather than inferred from a meeting that may simply have had no overlap: a
   fixture with 8.1 s of *certain* simultaneous speech
   (`Scripts/bench/diarization/make-ui-fixtures.sh audio` → `probe-overlap.wav`; speaker A alone
   0.0–6.0 s, **both talking 6.0–14.1 s**, speaker B alone 14.1–20.9 s) returns:

   ```text
   PROBE audio=20.9s turns=3 speakers=2
   PROBE turn c0  0.00-14.06 speech
   PROBE turn c1 14.48-18.25 speech
   PROBE turn c1 18.59-20.90 speech
   PROBE intersections=0
   ```

   Both speakers are found, so this is not a clustering failure. The entire overlap window is
   attributed to c0 as ordinary confident speech, and **no two turns intersect** — the pyannote
   community-1 pipeline resolves simultaneity to a single winner before `OfflineDiarizerManager`
   returns. F223's proposed fix (split intersecting raw turns in `densify`) therefore cannot fire:
   there is nothing to split, and implementing it would add live-looking dead code one layer below
   the dead veto it was meant to feed.

   This also makes the risk concrete rather than theoretical: 6.0–14.1 s would be labelled
   "Speaker 1" with full confidence while two people are talking. That is the persuasive wrong
   label `SpeakerOverlay` exists to prevent, and neither the coverage rule nor the margin rule nor
   single-cluster suppression can see it.

   FluidAudio ships a second architecture, **Sortformer** (`OfflineSortformerDiarizer`,
   `DiarizerTimeline`). It was run on the same fixture rather than assumed from its types:

   ```text
   SORT speaker 0   0.00-14.16
   SORT speaker 1   5.92-20.96
   SORT INTERSECT s0 & s1 over 5.92-14.16
   SORT spans=2 intersections=1
   ```

   Against a ground truth of both speakers talking 6.0–14.1 s, it places the overlap at
   **5.92–14.16 s** — within about 0.1 s at both boundaries. Overlap detection on this runtime is
   real, not theoretical.

   It is not a free swap, and the trade is sharp:

   | | pyannote community-1 *(current)* | Sortformer v2.1 fp16 |
   |---|---|---|
   | Simultaneous speech | not reported at all | detected, ±0.1 s on this fixture |
   | Maximum speakers | unbounded (clustering) | **4, fixed** — `numSpeakers` is a `let`, the model's output width |
   | Model download | **21 MB** | **242 MB** |
   | First compile | 0.10 s | 10.3 s |
   | Measured on real meetings | yes, §4–5 | **no** — one 21 s synthetic fixture |

   The speaker cap is the hard part. The one real meeting measured produced exactly **4** clusters,
   which is the cap, so a fifth participant would have nowhere to go. Trading an unbounded speaker
   count for overlap detection is a product decision about which error is worse, and it is F232's,
   not a change to make silently. Nothing here was adopted: the probe downloaded into a scratch
   directory and the installed runtime is untouched.
   **Measured on real meetings, 2026-09-18 (F232 — decided: stay on pyannote community-1).**
   `Scripts/bench/diarization/runtime-probe` runs both runtimes on the same file and prints counts
   and timings only. Two real recordings from the library, 35.3 and 36.3 minutes:

   | | meeting A (35.3 min) | meeting B (36.3 min) |
   |---|---|---|
   | pyannote: clusters / turns / wall | 4 / 203 / 6 s | 4 / 336 / 7 s |
   | Sortformer: slots used / turns / wall | 4 / 437 / 17 s | 4 / 734 / 17 s |
   | Simultaneous speech Sortformer reports | 25.5 s (1.2 % of the file) | 41.0 s (1.9 %) |
   | Overlap intervals: <0.5 s / 0.5–2 s / ≥2 s | 48 / 15 / **0** (longest 1.8 s) | 67 / 28 / **0** (longest 1.6 s) |
   | Best one-to-one agreement on who is speaking, frames where both name one speaker | **39.1 %** | **56.6 %** |
   | Speech only pyannote hears / only Sortformer hears | 211 s / 74 s | 399 s / 113 s |

   The synthetic fixture's 8-second overlap does not occur in these meetings: no interval reaches
   2 s, and about three quarters are under half a second — backchannels, not two people talking
   over a sentence. A veto fed by them would withhold a name for a whole segment because of an
   "mm-hm". Meanwhile the two runtimes disagree about *who* is speaking on roughly half the frames,
   and Sortformer fills all four of its slots on both files, so neither its identities nor its cap
   are safe to adopt on 35-minute audio — with no ground truth, the disagreement does not say which
   is right, only that swapping is not a like-for-like change. Using Sortformer as an overlap
   detector beside pyannote would cost 242 MB and ~2.5× the analysis time to suppress ≤1.8 s events.
   The shipped disclosure ("when two people talk at the same time only one of them is labelled")
   stays the answer. Revisit if FluidAudio ships an overlap-aware clustering diarizer, or a real
   meeting shows sustained overlap.
4. **Floor-configuration and long-recording runs.** 615.5 MiB at 35 minutes is comfortable; nothing
   here measured 90 minutes or an 8 GB machine, and the system gate names both.
