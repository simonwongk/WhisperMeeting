# Local ASR benchmark (M3 Pro, 18 GB; synthetic clips)

Warm release→text latency (model resident) + accuracy. Lower is better everywhere.
CER normalized 繁→簡 (OpenCC) with punctuation/spaces stripped.

## Summary

| engine | avg sec | EN WER | 中文 CER | code-switch CER |
|---|---|---|---|---|
| pytorch-turbo (fp32/CPU baseline) | 6.75 | 0.023 | 0.049 | 0.000 |
| mlx-turbo-fp16 | 1.60 | 0.023 | 0.049 | 0.000 |
| sensevoice-small-q8 | 0.19 | 0.023 | 0.026 | 0.018 |
| qwen3-asr-1.7b-8bit | 0.38 | 0.000 | 0.000 | 0.000 |
| qwen3-asr-1.7b-8bit-auto | 0.38 | 0.000 | 0.000 | 0.000 |

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