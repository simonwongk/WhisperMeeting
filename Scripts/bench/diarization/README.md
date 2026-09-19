# Diarization benchmark (F217)

A manifest-driven synthetic corpus and a diarization scorer. Stdlib Python 3.9 only — the rest of
`Scripts/` has no third-party dependency and this adds none.

## What this corpus is for, and what it is not for

**It is for correctness.** Does the pipeline parse the runtime's output, validate intervals, abstain
where it should, preserve the recording, cancel cleanly, produce identical output across runs, and
keep labels out of every default output path? The corpus answers all of that, with exact ground truth.

**It is not for calibration.** Measured on 2026-09-13: a clustering threshold derived from this
corpus (0.40, at a apparent 90.8 % displayed-label precision) produced **179 speaker clusters** on a
real 35-minute meeting, and **13 clusters on two minutes of one person speaking**. Every utterance
from one macOS voice is acoustically near-identical, so within-speaker embedding spread is far
narrower than a real person's, and a threshold fitted here sits far below the real one.

Augmenting the audio does not fix this. Per-utterance gain (−7…+3 dB) and spectral tilt were tried;
the fixture still resolved correctly to 2 clusters, unchanged. Do not re-attempt that without new
evidence.

**Never derive a clustering parameter from this corpus.** See `docs/DIARIZATION_SCORECARD.md`.

## Layout

- `manifest.json` — 18 fixture definitions: id, stratum, seed, voices, utterance script, timing,
  noise/overlap/offset parameters. Committed.
- `generate_corpus.py` — synthesises the audio. Generated `.wav` and `.truth.json` are gitignored;
  only the manifest and `manifest.lock.json` hashes are committed, so nothing is redistributed.
- `score_diarization.py` — DER/JER with NIST `md-eval` accounting and pyannote.metrics conventions.
- `runtime-probe/` — a separate Swift package (built on demand, never part of the app): `probe`
  runs the shipped runtime and Sortformer on one file (F232); `sweep` computes embeddings once per
  file and re-clusters at each threshold (F225).
- `sweep_score.py` — scores a `sweep` output directory against RTTM ground truth, per threshold.
- `ami_prepare.py` — turns word-aligned AMI annotations into the 16 kHz mono WAV and per-meeting
  RTTM that `sweep` and `sweep_score.py` require, and **records the two decisions that move the
  numbers**: how words become reference turns, and what gap closes one (F340).
- `bucket_table.py` — the F317 table: what a displayed label is worth by reference-turn length and
  whether anyone else is talking, with the sub-second gate as a parameter so the before-and-after
  come from one run (F340).
- `row_lengths.py` — how long a library's transcript rows actually are, which is what says how many
  rows the sub-second rule touches. Reads timings only, never transcript text (F340).
- `score_corpus.py` — runs the scorer over a directory of runtime output and prints the per-stratum
  table, including displayed-label precision after the product's own overlay rule.

## Ground truth is arithmetic, not annotation

Each utterance is synthesised separately with `say -o`, measured exactly with `afinfo`,
energy-trimmed, and placed at a chosen offset. Turn boundaries are therefore exact by construction
rather than estimated from the mix. Overlap fixtures mix at sample level and record the union of
overlapping intervals. Regeneration from a wiped cache is byte-identical.

## Usage

```bash
python3 generate_corpus.py --out out          # generate everything
python3 generate_corpus.py --only en_2spk_alt --out out
python3 generate_corpus.py --verify --out out # recompute hashes, non-zero exit on drift
python3 generate_corpus.py --list

python3 score_diarization.py --self-test      # ALWAYS run this before trusting a number
python3 score_corpus.py <hypothesis_dir>
```

### Re-deriving the AMI tables (F225, F317 — see `docs/DIARIZATION_SCORECARD.md`)

One step needs a third-party library and is therefore outside the committed tools, so that
everything deciding a *number* stays inside them:

```bash
# 1. Shards -> one JSON object per meeting: {"id", "words": [[start, end, speaker], …], "audio"}.
#    `datasets` is not a dependency of this repo; install it in a scratch venv.
python3 -c 'from datasets import load_dataset; import json
ds = load_dataset("diarizers-community/ami", "ihm", split="train")
print("\n".join(json.dumps(r) for r in ds))' > ami.jsonl      # revision pinned in the scorecard

# 2. Reference turns + 16 kHz mono WAV. `--gap` is the decision that moves every bucket.
python3 ami_prepare.py --manifest ami.jsonl --out ami --gap 0.5

# 3. Sweep the clustering threshold (Swift; see runtime-probe/README).
swift run -c release sweep <models parent> sweep-out 0.30,0.40,0.50,0.55,0.60,0.65,0.70,0.80,0.90,1.00 ami/wav/*.wav

# 4. The DER table.
python3 sweep_score.py sweep-out ami/rttm

# 5. The row-length table, before and after the sub-second rule.
python3 bucket_table.py --rttm ami/rttm --hypotheses sweep-out/0.60 --gate 0
python3 bucket_table.py --rttm ami/rttm --hypotheses sweep-out/0.60 --gate 1.0

# 6. How many rows the rule touches in a real library (timings only, never text).
python3 row_lengths.py --library "~/Library/Application Support/WhisperMeet"
```

Every one of those tools has a `--self-test` that runs offline, and
`Scripts/tests/test_diarization_producers.py` runs all three in the quality gate.

## The scorer's conventions, stated because both have a widely-used opposite

- `collar` is a **full width** centred on each reference boundary (pyannote's convention), so the
  conventional NIST 250 ms half-collar is `--collar 0.5`. md-eval's `-c` is a half-width.
- The optimal speaker mapping is computed **after** collars and overlap exclusion (pyannote's
  convention, not md-eval's).
- The DER denominator is speaker-weighted reference time, `sum(d * n_ref)` — ten seconds of two
  concurrent speakers contributes twenty. DER is therefore unbounded above and is never clamped.

`--self-test` checks the implementation against pyannote.metrics' published golden vectors, including
the exact component breakdown `total=31 correct=22 miss=2 fa=7 conf=7 DER=16/31`. A hand-written DER
is silently wrong in a dozen ways; run it before quoting any figure this produces.

## Reading the output

`score_corpus.py` reports DER, but the number to read first is **displayed-label precision**: of the
transcript rows that actually received a label after the conservative overlay rule, how many were
right. DER counts time and is dominated by whoever spoke most; precision counts what a reader sees.
Coverage matters alongside it — precision at 5 % coverage is worthless.
