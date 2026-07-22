# Phase 0 — dictation engine benchmark (M3 Pro, 18 GB; synthetic clips)

Warm release→text latency (model resident) + accuracy. Lower is better everywhere.
CER normalized 繁→簡 (OpenCC) with punctuation/spaces stripped.

## Summary

| engine | avg sec | EN WER | 中文 CER | code-switch CER |
|---|---|---|---|---|
| pytorch-turbo (fp32/CPU baseline) | 4.76 | 0.023 | 0.049 | 0.000 |
| mlx-turbo-fp16 | 1.42 | 0.023 | 0.049 | 0.000 |

## pytorch-turbo (fp32/CPU baseline) — per clip

| clip | lang | sec | detected | metric | value | transcript |
|---|---|---|---|---|---|---|
| cs1 | cs | 5.477 | zh | CER | 0.0 | 我们的deadline是这个星期五 |
| cs2 | cs | 4.612 | zh | CER | 0.0 | 帮我schedule一个meeting明天下午。 |
| cs3 | cs | 4.594 | zh | CER | 0.0 | 这个bug已经fix了,可以merge了。 |
| en1 | en | 4.653 | en | WER | 0.0 | Can you send me the quarterly report by Friday afternoon? |
| en2 | en | 4.634 | en | WER | 0.091 | Let's schedule the design review for next Tuesday at 10. |
| en3 | en | 4.606 | en | WER | 0.0 | the build is failing on the release step, please take a look |
| en4 | en | 4.648 | en | WER | 0.0 | Remind me to follow up with the vendor about the invoice. |
| zh1 | zh | 4.662 | zh | CER | 0.071 | 帮我把今天的会议记要发给团队。 |
| zh2 | zh | 4.691 | zh | CER | 0.0 | 这个季度的销售数据看起来很不错。 |
| zh3 | zh | 5.025 | zh | CER | 0.077 | 请提醒我下午3点跟客户开会。 |

## mlx-turbo-fp16 — per clip

| clip | lang | sec | detected | metric | value | transcript |
|---|---|---|---|---|---|---|
| cs1 | cs | 1.51 | zh | CER | 0.0 | 我们的deadline是这个星期五 |
| cs2 | cs | 1.43 | zh | CER | 0.0 | 帮我schedule一个meeting明天下午。 |
| cs3 | cs | 1.39 | zh | CER | 0.0 | 这个bug已经fix了,可以merge了。 |
| en1 | en | 1.403 | en | WER | 0.0 | Can you send me the quarterly report by Friday afternoon? |
| en2 | en | 1.388 | en | WER | 0.091 | Let's schedule the design review for next Tuesday at 10. |
| en3 | en | 1.388 | en | WER | 0.0 | the build is failing on the release step, please take a look |
| en4 | en | 1.393 | en | WER | 0.0 | Remind me to follow up with the vendor about the invoice. |
| zh1 | zh | 1.415 | zh | CER | 0.071 | 帮我把今天的会议记要发给团队。 |
| zh2 | zh | 1.435 | zh | CER | 0.0 | 这个季度的销售数据看起来很不错。 |
| zh3 | zh | 1.409 | zh | CER | 0.077 | 请提醒我下午3点跟客户开会。 |