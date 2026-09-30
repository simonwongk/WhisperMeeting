# Code-switch per-word results: Qwen3-ASR, dictation path vs meeting path (F628)

This file is written by hand from `dictation-ab.py --words` output. It is not generated like
`results.md`, which `benchmark.py` rewrites from scratch on every run. Re-run the commands below
to reproduce it.

- **Measured:** 2026-09-30, Apple M3 Pro, 18 GB.
- **Model:** the installed runtime, `mlx-audio=0.3.1`,
  `mlx-community/Qwen3-ASR-1.7B-8bit@a8379a2e`, aligner
  `mlx-community/Qwen3-ForcedAligner-0.6B-8bit@0e1a68e9`.
- **Meeting path:** the installed `qwen_transcribe.py`, byte-identical to this commit's
  `Scripts/qwen_transcribe.py`. One process per clip, with the argv `QwenASRClient` builds.
- **Dictation path:** the installed `qwen_dictate_server.py`, kept warm.
- **Clips:** the synthetic F589 clips from `generate_clips.sh`, voices Samantha (en) and
  Tingting (zh). In encs1–6 the Mandarin words are spliced in, each spoken by the Mandarin voice.
  In cs1–3 one Mandarin voice reads the mixed text.

```bash
Scripts/bench/dictation-ab.py --engine qwen3-asr-1.7b-8bit --clips encs,cs --words [--language English]
Scripts/bench/dictation-ab.py --engine qwen-meeting        --clips encs,cs --words [--language English]
```

## Result: the meeting path shares it, and so does every other result on these clips

Under each setting, the two paths returned **byte-identical transcripts on all 9 clips** (9/9
Automatic, 9/9 English). The meeting path writes 王老师 as "Wang老师" exactly as dictation does.
The two dictation columns also match F589's Qwen columns (2026-09-26) verdict for verdict.

| clip | word | Automatic: dictation | Automatic: meeting | English: dictation | English: meeting |
|---|---|---|---|---|---|
| encs1 | 会议纪要 | kept | kept | DROPPED ("meeting minutes") | DROPPED ("meeting minutes") |
| encs1 | 周五 | kept | kept | DROPPED ("Friday") | DROPPED ("Friday") |
| encs2 | 客户 | kept | kept | DROPPED ("customer") | DROPPED ("customer") |
| encs2 | 报价 | kept | kept | kept | kept |
| encs3 | 会议室 | kept | kept | kept | kept |
| encs3 | 培训 | kept | kept | kept | kept |
| encs4 | 王老师 | DROPPED ("Wang老师") | DROPPED ("Wang老师") | DROPPED ("Wang老师") | DROPPED ("Wang老师") |
| encs4 | 作业 | kept | kept | kept | kept |
| encs5 | 预算 | kept | kept | DROPPED (absent) | DROPPED (absent) |
| encs6 | 翻译 | kept | kept | kept | kept |
| cs1 | deadline | kept | kept | kept | kept |
| cs2 | schedule | kept | kept | kept | kept |
| cs2 | meeting | kept | kept | kept | kept |
| cs3 | bug | kept | kept | kept (as "fixed") | kept (as "fixed") |
| cs3 | fix | kept | kept | kept | kept |
| cs3 | merge | kept | kept | kept | kept |

The parenthesised text is what the hypothesis has in that word's place, read by hand from the raw
transcript. `word_diff` only reports kept or dropped. In cs3 under English, "fix" is counted kept
because "fix" is a substring of "fixed".

Two other results, both identical across the two paths:

- **encs5 under Automatic** reads "R. 预算 for Q4…": the English word "Our" becomes "R.". 预算 itself
  is kept.
- **English pinned, embedded Mandarin is translated rather than transcribed.** 会议纪要 becomes
  "meeting minutes", 周五 becomes "Friday" and 客户 becomes "customer", and 预算 is dropped along
  with "Our" ("For Q4 is still under review."). With Wang老师, 5 of the 10 embedded words are not
  in the transcript as spoken, against 1 of 10 under Automatic. F589 recorded this for dictation;
  a meeting with its language set to English does the same.

## Control: the name without English context

The same Mandarin voice spoke 王老师 alone, and again inside a Mandarin sentence. Both went through
the meeting path.

| clip | Automatic | Chinese | English |
|---|---|---|---|
| 王老师 (alone) | 王老师。 | 王老师。 | 王老师。 |
| 我去问一下王老师作业的事。 | 我去问一下王老师作业的事。 | 我去问一下王老师作业的事。 | 我去问一下王老师作业的事。 |

Even with English pinned, the name comes back intact when no English surrounds it. So "Wang老师"
comes from the model decoding a Chinese surname inside an English sentence. It is not a property
of either decode path, and not of the language setting. F589 recorded the same rendering from
Whisper Turbo, a different model.

## What these clips cannot show

Every clip is 2.2–4.1 s long, so it fits in one chunk on both paths (30 s for dictation, 60 s for
meetings). They cannot tell apart the paths' chunking and cross-chunk batching, the same caveat
as `results.md`. "Shared" means shared on a short utterance. How a name behaves inside a long
recording, with a minute of context around it, was not measured here.
