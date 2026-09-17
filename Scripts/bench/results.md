# Local ASR benchmark (M3 Pro, 18 GB; synthetic clips)

Warm release→text latency (model resident) + accuracy. Lower is better everywhere.
CER normalized 繁→簡 (OpenCC) with punctuation/spaces stripped.

## Scope — this is a DICTATION benchmark, not a meeting benchmark

Read before quoting any number here. All ten clips are short (about 2–3 s), which is the Quick
Dictation shape. For meetings these numbers are invalid, and for a different reason per engine:

- **Every row is warm, except the `-meeting-cold` row.** The warm-up call's timing is discarded, so
  no other row includes model load. A real meeting pays that load once (measured elsewhere at
  2–11 s). The meeting row spawns a process per clip and so *does* include it — which is why its
  seconds are not comparable with the others, and why `cold` is in its name.
- **Whisper rows** (`pytorch-turbo`, `mlx-turbo-*`): Whisper pads every input to a 30 s mel window,
  so a 3 s clip pays one full encoder pass and roughly ten tokens of decode. Long-form audio pays
  that same encoder per window but far more decode per window. These rows are therefore
  encoder-dominated and **understate decode cost** — exactly where a CPU fp32 path is worst. Do
  not extrapolate a realtime factor for a meeting from them.
- **`qwen3-asr-1.7b-8bit`**: the resident dictation daemon (`bench/qwen_server.py`), not the script a
  meeting runs. A 3 s clip never fills a 60 s chunk, so the 60 s × 4 batching and its padding are
  never exercised here, and the row is warm.
- **`qwen3-asr-1.7b-8bit-meeting-cold`** (F293): the same weights through `Scripts/qwen_transcribe.py`,
  the script a meeting actually runs — added because until it existed every Qwen number in this
  file described a path no meeting takes. On these clips it is byte-identical to the daemon row,
  which says the clips cannot discriminate the two paths rather than that the paths agree in
  general: 2–3 s is still one chunk. What it did surface is a wrong language label on the
  code-switched clips (**F296**).

There is still no long-form ASR measurement in this table. Until one exists, treat a meeting-speed
claim sourced from it as unsupported — see **F241** for the long-form fixture and its scorer.

## Summary

| engine | avg sec | EN WER | 中文 CER | code-switch CER |
|---|---|---|---|---|
| pytorch-turbo (fp32/CPU baseline) | 6.75 | 0.023 | 0.049 | 0.000 |
| mlx-turbo-fp16 | 1.60 | 0.023 | 0.049 | 0.000 |
| sensevoice-small-q8 | 0.19 | 0.023 | 0.026 | 0.018 |
| qwen3-asr-1.7b-8bit | 0.38 | 0.000 | 0.000 | 0.000 |
| qwen3-asr-1.7b-8bit-auto | 0.38 | 0.000 | 0.000 | 0.000 |
| qwen3-asr-1.7b-8bit-meeting-cold | 1.94 | 0.000 | 0.000 | 0.000 |

## pytorch-turbo (fp32/CPU baseline) — per clip

| clip | lang | sec | detected | metric | value | transcript |
|---|---|---|---|---|---|---|
| cs1 | cs | 5.626 | zh | CER | 0.0 | 我们的deadline是这个星期五 |
| cs2 | cs | 5.623 | zh | CER | 0.0 | 帮我schedule一个meeting明天下午。 |
| cs3 | cs | 6.556 | zh | CER | 0.0 | 这个bug已经fix了,可以merge了。 |
| en1 | en | 6.737 | en | WER | 0.0 | Can you send me the quarterly report by Friday afternoon? |
| en2 | en | 5.82 | en | WER | 0.091 | Let's schedule the design review for next Tuesday at 10. |
| en3 | en | 5.936 | en | WER | 0.0 | the build is failing on the release step, please take a look |
| en4 | en | 7.094 | en | WER | 0.0 | Remind me to follow up with the vendor about the invoice. |
| zh1 | zh | 10.962 | zh | CER | 0.071 | 帮我把今天的会议记要发给团队。 |
| zh2 | zh | 6.762 | zh | CER | 0.0 | 这个季度的销售数据看起来很不错。 |
| zh3 | zh | 6.368 | zh | CER | 0.077 | 请提醒我下午3点跟客户开会。 |

## mlx-turbo-fp16 — per clip

| clip | lang | sec | detected | metric | value | transcript |
|---|---|---|---|---|---|---|
| cs1 | cs | 1.666 | zh | CER | 0.0 | 我们的deadline是这个星期五 |
| cs2 | cs | 1.545 | zh | CER | 0.0 | 帮我schedule一个meeting明天下午。 |
| cs3 | cs | 1.545 | zh | CER | 0.0 | 这个bug已经fix了,可以merge了。 |
| en1 | en | 1.531 | en | WER | 0.0 | Can you send me the quarterly report by Friday afternoon? |
| en2 | en | 1.552 | en | WER | 0.091 | Let's schedule the design review for next Tuesday at 10. |
| en3 | en | 1.63 | en | WER | 0.0 | the build is failing on the release step, please take a look |
| en4 | en | 1.73 | en | WER | 0.0 | Remind me to follow up with the vendor about the invoice. |
| zh1 | zh | 1.593 | zh | CER | 0.071 | 帮我把今天的会议记要发给团队。 |
| zh2 | zh | 1.66 | zh | CER | 0.0 | 这个季度的销售数据看起来很不错。 |
| zh3 | zh | 1.588 | zh | CER | 0.077 | 请提醒我下午3点跟客户开会。 |

## sensevoice-small-q8 — per clip

| clip | lang | sec | detected | metric | value | transcript |
|---|---|---|---|---|---|---|
| cs1 | cs | 0.144 | auto | CER | 0.0 | 我们的deadline是这个星期五。 |
| cs2 | cs | 0.166 | auto | CER | 0.0 | 帮我schedule一个meeting，明天下午。 |
| cs3 | cs | 0.21 | auto | CER | 0.053 | 这个bg已经fix了，可以 merge了。 |
| en1 | en | 0.208 | auto | WER | 0.0 | Can you send me the quarterly report by Friday afternoon. |
| en2 | en | 0.22 | auto | WER | 0.091 | Let's schedule the design review for next Tuesday at 10. |
| en3 | en | 0.205 | auto | WER | 0.0 | The build is failing on the release step, please take a look. |
| en4 | en | 0.209 | auto | WER | 0.0 | Remind me to follow up with the vendor about the invoice. |
| zh1 | zh | 0.186 | auto | CER | 0.0 | 帮我把今天的会议纪要发给团队。 |
| zh2 | zh | 0.196 | auto | CER | 0.0 | 这个季度的销售数据看起来很不错。 |
| zh3 | zh | 0.195 | auto | CER | 0.077 | 请提醒我下午3点跟客户开会。 |

## qwen3-asr-1.7b-8bit — per clip

| clip | lang | sec | detected | metric | value | transcript |
|---|---|---|---|---|---|---|
| cs1 | cs | 0.339 | zh | CER | 0.0 | 我们的 deadline 是这个星期五。 |
| cs2 | cs | 0.345 | zh | CER | 0.0 | 帮我 schedule 一个 meeting，明天下午。 |
| cs3 | cs | 0.435 | zh | CER | 0.0 | 这个 bug 已经 fix 了，可以 merge 了。 |
| en1 | en | 0.386 | en | WER | 0.0 | Can you send me the quarterly report by Friday afternoon? |
| en2 | en | 0.41 | en | WER | 0.0 | Let's schedule the design review for next Tuesday at ten. |
| en3 | en | 0.442 | en | WER | 0.0 | The build is failing on the release step. Please take a look. |
| en4 | en | 0.422 | en | WER | 0.0 | Remind me to follow up with the vendor about the invoice. |
| zh1 | zh | 0.38 | zh | CER | 0.0 | 帮我把今天的会议纪要发给团队。 |
| zh2 | zh | 0.338 | zh | CER | 0.0 | 这个季度的销售数据看起来很不错。 |
| zh3 | zh | 0.347 | zh | CER | 0.0 | 请提醒我下午三点跟客户开会。 |

## qwen3-asr-1.7b-8bit-auto — per clip

| clip | lang | sec | detected | metric | value | transcript |
|---|---|---|---|---|---|---|
| cs1 | cs | 0.293 | auto | CER | 0.0 | 我们的 deadline 是这个星期五。 |
| cs2 | cs | 0.343 | auto | CER | 0.0 | 帮我 schedule 一个 meeting，明天下午。 |
| cs3 | cs | 0.442 | auto | CER | 0.0 | 这个 bug 已经 fix 了，可以 merge 了。 |
| en1 | en | 0.391 | auto | WER | 0.0 | Can you send me the quarterly report by Friday afternoon? |
| en2 | en | 0.403 | auto | WER | 0.0 | Let's schedule the design review for next Tuesday at ten. |
| en3 | en | 0.437 | auto | WER | 0.0 | The build is failing on the release step. Please take a look. |
| en4 | en | 0.423 | auto | WER | 0.0 | Remind me to follow up with the vendor about the invoice. |
| zh1 | zh | 0.355 | auto | CER | 0.0 | 帮我把今天的会议纪要发给团队。 |
| zh2 | zh | 0.323 | auto | CER | 0.0 | 这个季度的销售数据看起来很不错。 |
| zh3 | zh | 0.345 | auto | CER | 0.0 | 请提醒我下午三点跟客户开会。 |

## qwen3-asr-1.7b-8bit-meeting-cold — per clip

| clip | lang | sec | detected | metric | value | transcript |
|---|---|---|---|---|---|---|
| cs1 | cs | 2.25 | en | CER | 0.0 | 我们的 deadline 是这个星期五。 |
| cs2 | cs | 2.187 | en | CER | 0.0 | 帮我 schedule 一个 meeting，明天下午。 |
| cs3 | cs | 1.934 | en | CER | 0.0 | 这个 bug 已经 fix 了，可以 merge 了。 |
| en1 | en | 1.891 | en | WER | 0.0 | Can you send me the quarterly report by Friday afternoon? |
| en2 | en | 1.828 | en | WER | 0.0 | Let's schedule the design review for next Tuesday at ten. |
| en3 | en | 1.888 | en | WER | 0.0 | The build is failing on the release step. Please take a look. |
| en4 | en | 1.887 | en | WER | 0.0 | Remind me to follow up with the vendor about the invoice. |
| zh1 | zh | 1.849 | zh | CER | 0.0 | 帮我把今天的会议纪要发给团队。 |
| zh2 | zh | 1.799 | zh | CER | 0.0 | 这个季度的销售数据看起来很不错。 |
| zh3 | zh | 1.853 | zh | CER | 0.0 | 请提醒我下午三点跟客户开会。 |