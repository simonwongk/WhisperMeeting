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
