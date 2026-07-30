# Local ASR model alternatives

Research date: 2026-07-29

## Decision

**Selected for an opt-in app trial: Qwen3-ASR-1.7B MLX 8-bit plus the Qwen3 ForcedAligner
0.6B MLX 8-bit. Whisper Large remains the default.** On the existing 10-clip synthetic
English/Mandarin/code-switch benchmark, automatic-language Qwen averaged 0.38 seconds and scored
0.000 English WER, 0.000 Mandarin CER, and 0.000 code-switch CER. SenseVoiceSmall was faster at
0.19 seconds, but regressed code-switch CER to 0.018 by recognizing “bug” as “bg”. The measured
results are in [`../Scripts/bench/results.md`](../Scripts/bench/results.md).

This proves the short local path, not long-meeting superiority. Qwen is therefore available as an
explicit model choice, but is not the default and is clearly labeled as needing validation on real,
long meetings. The app keeps every recording unchanged if Qwen is missing, cancelled, or fails.
Its complete transcript text remains authoritative if timestamp alignment cannot be mapped safely.

The production helper was also exercised directly with the Qwen aligner on synthetic English and
English/Mandarin code-switch clips. It returned the expected text plus 10 aligned items for each
clip. Since the official aligner supports inputs only up to five minutes, the helper bounds every
alignment request to four minutes.

The user approved the dependency and model installation. The managed runtime occupies 4.2 GB on
disk, including its isolated Python environment. Installed model hashes and revisions are recorded
in [`ASR_EVALUATION_LOG_2026-07-29.md`](ASR_EVALUATION_LOG_2026-07-29.md).

## Requirements that candidates must preserve

- Fully local/offline transcription after the model is downloaded.
- English, Mandarin, and realistic English/Mandarin code-switching.
- Original-language transcription, never automatic translation.
- Long-form meeting reliability with no dropped or duplicated boundaries.
- Usable segment timestamps for playback, export, markers, and quality review.
- Automatic language detection plus explicit English and Chinese modes.
- Business-vocabulary or context guidance, or measured evidence that its absence is acceptable.
- A license suitable for redistribution in a desktop app.
- The recording remains untouched on every model/runtime failure.

## Ranked candidates

| Rank | Candidate | Why it merits a test | Main risk |
|---|---|---|---|
| 0 | MLX Whisper large-v3 control | Same Whisper family and output expectations; isolates Apple-Silicon runtime speed from model choice. The existing MLX turbo benchmark was about 3.35× faster on short synthetic clips with the same measured accuracy. | Meeting-path timestamps, progress, cancellation, and long-audio behavior still need measurement. This is a runtime change, not an accuracy upgrade. |
| 1 | Qwen3-ASR-1.7B + Qwen3 ForcedAligner 0.6B | Apache-2.0 weights; English, Chinese, code-switching, automatic language ID, long audio, and timestamps. Qwen's published evaluation reports lower error than Whisper large-v3 on several English and Chinese sets, including a large improvement on its WenetSpeech meeting comparison. MLX-Audio and its Swift SDK provide Apple-Silicon paths. | The strongest published numbers are producer-reported and mostly GPU/vLLM measurements. Timestamps require a second model, and the MLX integration is a separate community runtime that must be validated on long meetings. |
| 2 | SenseVoiceSmall | 234M parameters; Mandarin, Cantonese, English, Japanese, and Korean; non-autoregressive. Its maintainers report Chinese advantages and over 15× Whisper-Large inference speed in their benchmark. The official repository now publishes a self-contained macOS-arm64/GGUF runtime with VAD, and current FunASR restores VAD segment timestamps. | English meeting accuracy and mixed-language behavior need local proof. Segment timing is VAD-derived and may be coarser than Whisper. Weights use the FunASR Model License rather than a standard OSS license; commercial use is permitted with attribution according to the maintainers. |
| 3 | Qwen3-ASR-0.6B + aligner | Same language/timestamp story as the 1.7B model with a much smaller Apache-2.0 checkpoint; the upstream model file is about 1.88 GB before MLX quantization. A plausible fast tier if 1.7B is accurate but too slow or memory-heavy. | Qwen's published English results are mixed versus Whisper large-v3, and adding the aligner reduces its footprint advantage. |
| Deferred | Moonshine family | The 245M-parameter Streaming Medium model is a strong English speed comparison: its maintainers report 6.65% average WER, low latency, and a sub-1 GB runtime-memory target. Separate small Mandarin checkpoints exist. | The current Streaming Medium checkpoint is English-only, while the separate Mandarin checkpoints do not provide one model for English/Mandarin code-switching. It cannot replace the app's multilingual path as currently released. |
| Deferred | Microsoft VibeVoice-ASR | MIT, 50+ languages, hotwords, timestamps, and up to 60-minute single-pass meeting transcription. An MLX conversion exists. | At 9B parameters it is a poor fit for the current 18 GB target Mac, and its diarization-first output conflicts with the product's no-speaker-identification boundary unless stripped and independently validated. |

All performance claims above are reasons to benchmark, not claims about WhisperMeet. Hardware,
audio, chunking, normalization, and decoding settings differ across the publishers' evaluations.

## Current download sizes

These are repository download sizes as of 2026-07-29, not peak unified-memory measurements. The
Qwen totals include the separate aligner needed for timestamps. Runtime memory can be higher than
the weight files and must be measured on the target 18 GB Mac.

| Candidate configuration | Parameters | Download |
|---|---:|---:|
| MLX Whisper large-v3 control | 1.55B | 3.08 GB |
| Qwen3-ASR-1.7B MLX 8-bit + ForcedAligner MLX 8-bit | 1.7B + 0.6B | 2.46 GB + 1.28 GB = **3.74 GB** |
| SenseVoiceSmall q8 + FSMN VAD | 234M + VAD | 254 MB + 1.72 MB = **about 256 MB** |
| Qwen3-ASR-0.6B MLX 8-bit + ForcedAligner MLX 8-bit | 0.6B + 0.6B | 1.01 GB + 1.28 GB = **2.29 GB** |
| Moonshine Streaming Medium, current full-precision checkpoint | 245M | 1.07 GB |
| VibeVoice-ASR MLX 4-bit | 9B nominal | 5.71 GB |

For reference, the original VibeVoice-ASR checkpoint is 17.3 GB. The official, unquantized Qwen
downloads are about 4.70 GB for ASR 1.7B, 1.88 GB for ASR 0.6B, and 1.84 GB for the aligner.

## Candidates not suitable for the current product

| Candidate | Reason not to prioritize |
|---|---|
| Distil-Whisper large-v3 | Compelling English speedup, but the released model is English-only and therefore cannot replace the app's Mandarin path. |
| NVIDIA Parakeet TDT 0.6B v3 | Fast, timestamped, and permissively licensed, but its 25 supported languages are European and do not include Mandarin. |
| Mistral Voxtral Mini 3B | Apache-2.0 and capable long-form ASR, but the published eight-language set excludes Mandarin and its transcription window is limited to 30 minutes. |
| faster-whisper / whisper.cpp | Useful runtime comparisons, not different recognition models. They may improve speed or packaging but cannot establish that another model is more accurate. |

## Proposed benchmark

Use a separate benchmark environment and never point experimental code at the user's meeting
index or recording folders. Read copies of audio; write all outputs under `Scripts/bench/`.

### Test order

1. OpenAI Whisper large and turbo through the current production path.
2. MLX Whisper large-v3 as the same-model runtime control.
3. Qwen3-ASR-1.7B 8-bit plus the 0.6B forced aligner.
4. SenseVoiceSmall q8 through its macOS-arm64 runtime.
5. Qwen3-ASR-0.6B 8-bit plus the aligner.

Moonshine may be measured separately as an English-only research comparison, but it does not enter
the multilingual replacement gate.

### Corpus

- At least three manually corrected, user-approved recordings per category:
  - English meeting.
  - Mandarin meeting.
  - English/Mandarin code-switching.
  - Far-field/noisy meeting.
- Include 30–60 minute files so boundary handling is exercised.
- Include business names and technical terms from the existing vocabulary workflow.
- Include silence, overlapping speech, and music/noise sections to measure hallucinations.
- Benchmark the same copied mixed WAV for every engine. Source-track experiments are a separate
  question and must not be mixed into the model comparison.

### Measurements

- English WER.
- Mandarin CER after recording both raw and normalized Simplified/Traditional scores.
- Code-switch CER plus exact preservation of English technical terms.
- Business-vocabulary recall.
- Hallucinated non-empty text during labeled silence.
- Missing/duplicated text at chunk boundaries.
- Timestamp coverage and median/p95 alignment error on a hand-aligned subset.
- Real-time factor, total wall time, cold-start time, peak memory, and model size.
- Determinism across three identical runs.
- Cancellation behavior and whether partial outputs remain isolated from production data.

### Advancement gate

A candidate advances only if it:

- passes every privacy, language, timestamp, long-audio, licensing, and recording-safety gate;
- improves WER/CER in both English and Mandarin without regressing business-term recall, **or**
  is at least 2× faster with no material accuracy regression;
- stays within the target Mac's memory budget; and
- produces stable output on all long recordings across three runs.

The synthetic gate selected Qwen for an opt-in trial after explicit dependency approval. Promotion
to the default still requires the real-meeting, long-audio, memory, and timestamp measurements
above.

## Primary sources

- [OpenAI Whisper repository and current model/CLI documentation](https://github.com/openai/whisper)
- [Qwen3-ASR official repository, license, languages, evaluations, and forced aligner](https://github.com/QwenLM/Qwen3-ASR)
- [Qwen3-ASR 0.6B official model card](https://huggingface.co/Qwen/Qwen3-ASR-0.6B)
- [Qwen3-ASR 1.7B MLX 8-bit files](https://huggingface.co/mlx-community/Qwen3-ASR-1.7B-8bit/tree/main)
- [Qwen3-ASR 0.6B MLX 8-bit files](https://huggingface.co/mlx-community/Qwen3-ASR-0.6B-8bit/tree/main)
- [Qwen3 ForcedAligner 0.6B MLX 8-bit files](https://huggingface.co/mlx-community/Qwen3-ForcedAligner-0.6B-8bit/tree/main)
- [MLX-Audio Apple-Silicon runtime and Qwen3-ASR support](https://github.com/Blaizzy/mlx-audio)
- [MLX-Audio Swift SDK](https://github.com/Blaizzy/mlx-audio-swift)
- [SenseVoice official repository and benchmarks](https://github.com/QwenAudio/SenseVoice)
- [SenseVoice official macOS-arm64/GGUF releases](https://github.com/QwenAudio/SenseVoice/releases)
- [SenseVoiceSmall model card](https://huggingface.co/FunAudioLLM/SenseVoiceSmall)
- [SenseVoiceSmall official GGUF files](https://huggingface.co/FunAudioLLM/SenseVoiceSmall-GGUF/tree/main)
- [FSMN VAD official GGUF files](https://huggingface.co/FunAudioLLM/fsmn-vad-GGUF/tree/main)
- [SenseVoice commercial-use clarification from its maintainers](https://github.com/FunAudioLLM/SenseVoice/issues/286)
- [Moonshine official repository, macOS support, benchmarks, and licensing](https://github.com/moonshine-ai/moonshine)
- [Moonshine Streaming Medium model card and files](https://huggingface.co/UsefulSensors/moonshine-streaming-medium)
- [MLX Whisper large-v3 files](https://huggingface.co/mlx-community/whisper-large-v3-mlx/tree/main)
- [Microsoft VibeVoice-ASR model card](https://huggingface.co/microsoft/VibeVoice-ASR)
- [VibeVoice-ASR MLX 4-bit files](https://huggingface.co/mlx-community/VibeVoice-ASR-4bit)
- [Distil-Whisper large-v3 model card](https://huggingface.co/distil-whisper/distil-large-v3)
- [NVIDIA Parakeet TDT 0.6B v3 model card](https://huggingface.co/nvidia/parakeet-tdt-0.6b-v3)
- [Mistral Voxtral Mini 3B model card](https://huggingface.co/mistralai/Voxtral-Mini-3B-2507)
