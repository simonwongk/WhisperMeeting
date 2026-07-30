# ASR evaluation and integration log — 2026-07-29

This log records the complete model-selection work for the Qwen3-ASR opt-in trial. Experimental
audio was limited to the repository's synthetic clips under `Scripts/bench/clips`; no user
recording, meeting index, or transcript was read or changed.

## Sources checked

- OpenAI Whisper's live repository documentation was checked before evaluating the existing local
  baseline.
- Qwen3-ASR's official repository and model documentation were checked for languages, automatic
  language detection, long-audio behavior, license, and forced-alignment limits.
- SenseVoice's official repository, macOS-arm64 release, GGUF model pages, and license clarification
  were checked before its isolated test.
- Exact candidate download sizes and source links are recorded in
  [`ASR_MODEL_ALTERNATIVES.md`](ASR_MODEL_ALTERNATIVES.md).

## Isolated downloads

All candidates were first downloaded under `/private/tmp/whispermeet-asr-bench-20260729`.

### Qwen

- Runtime: `mlx-audio==0.3.1`, installed in an isolated virtual environment.
- ASR: `mlx-community/Qwen3-ASR-1.7B-8bit`
  - revision `a8379a2e2f9e313c9292cdf1af4055ab56d50d55`
  - `model.safetensors` SHA-256
    `bf304b009cc7eca79283056f787b44c952d24ac22cec787b39732bba3c23c13c`
- Aligner: `mlx-community/Qwen3-ForcedAligner-0.6B-8bit`
  - revision `0e1a68e91d815300c7c9754b2a7639378b23db15`
  - `model.safetensors` SHA-256
    `be19ef8ac4326d032e7673342930b14c2df30bd68c1632493b0f563e30829f91`
- Measured download: 2.46 GB ASR + 1.28 GB aligner. The complete installed runtime, including
  Python packages, is 4.2 GB on this Mac.

### SenseVoice

- Official macOS arm64 runtime: v0.1.9, 7 MB.
  - archive SHA-256
    `2d5786784ad09d8f4def1d942f678728638fe601d00acf0dad7cf094a9328363`
- SenseVoiceSmall q8: 254,208,320 bytes.
  - SHA-256
    `4ae45c94422de949b387e2e0fb10d7e14e4c42c69db30c3444ecc7d4b844b7c5`
- FSMN VAD: 1,720,512 bytes.
  - SHA-256
    `1270f2559c495f4e7b6e739541151027d360761a3fda43fc147034f5719f5479`
- SenseVoice was benchmarked but not installed into the app's managed runtime.

The Mac had 226 GiB available before these downloads.

## Benchmark

The benchmark was extended to run named engines separately and append results. Qwen uses one
persistent local process so the reported value is warm release-to-text latency. Each engine was
run in its own process after an initial combined run incorrectly made Qwen appear to take 12.3
seconds because several large models were simultaneously resident in 18 GB unified memory. That
contention result was discarded, the procedure was corrected, and the corrected outputs were saved
to `Scripts/bench/results.json` and `Scripts/bench/results.md`.

| engine | average seconds | English WER | Mandarin CER | code-switch CER |
|---|---:|---:|---:|---:|
| PyTorch Whisper turbo, CPU/fp32 baseline | 6.75 | 0.023 | 0.049 | 0.000 |
| MLX Whisper turbo fp16 | 1.60 | 0.023 | 0.049 | 0.000 |
| SenseVoiceSmall q8 | **0.19** | 0.023 | 0.026 | 0.018 |
| Qwen3-ASR 1.7B 8-bit, explicit language | 0.38 | **0.000** | **0.000** | **0.000** |
| Qwen3-ASR 1.7B 8-bit, automatic language | 0.38 | **0.000** | **0.000** | **0.000** |

Qwen was selected because the request required both speed and accuracy. SenseVoice was the fastest,
but Qwen was still much faster than both Whisper paths and was the only candidate with zero measured
error in every synthetic category. This benchmark does not include accents, noise, long meetings,
overlapping speech, peak memory, or business vocabulary, so Whisper remains the default.

## Production-path checks

- The new helper transcribed `en1.wav` as:
  `Can you send me the quarterly report by Friday afternoon?`
  It returned language `en` and 10 aligned words.
- A first mixed-language command referenced nonexistent `mix1.wav` and failed with
  `FileNotFoundError`. The actual benchmark clip name was found and the command was corrected.
- The helper transcribed `cs1.wav` as:
  `我们的 deadline 是这个星期五。`
  It returned language `zh`, preserved the English word `deadline`, and returned 10 aligned items.
- The permanent managed installation was then run through the same English smoke test and produced
  the same text, language, and aligned-item count.

## App and safety changes

- Added a meeting transcription engine preference while preserving the existing `large` and
  `turbo` preference values. This is not a transcript or recording format change.
- Added “Qwen3-ASR 1.7B — fast + accurate” to Settings. Whisper Large remains selected for existing
  and new users unless they opt in.
- Added an app-bundled installer that requires 6 GB free, installs into a sibling staging directory,
  pins the runtime and model revisions, verifies both multi-gigabyte model hashes, validates the
  helper, and only then performs a rollback-safe runtime swap. Its exit/signal trap restores the
  prior runtime if activation does not complete, and a later run recovers an orphaned backup left
  by a force-quit or power loss.
- Installer recovery is serialized with a stale-PID-aware lock. Before checking free space, a new
  run removes abandoned staging directories and obsolete backups only after confirming a complete
  canonical runtime (or restoring a complete backup), preventing multi-gigabyte orphans from
  consuming recording storage.
- Installation is refused while a recording, preflight capture, or transcription is active.
- Qwen runs with Hugging Face and Transformers offline modes forced after installation.
- Transcription output is first written to an isolated temporary directory and atomically finalized
  by the helper. The meeting is updated only after a complete, readable result arrives.
- Forced alignment is bounded to 240-second chunks, below Qwen's documented five-minute limit.
- If aligned words do not map exactly back to Qwen's punctuated text, the app stores the complete
  text without derived segments instead of dropping or rewriting words.
- If the forced aligner itself fails after ASR succeeds, the helper emits the complete recognized
  text with no derived segments and records a private local diagnostic instead of discarding text.
- Engine and language are snapshotted when a transcription is queued, so later Settings changes
  cannot alter a waiting job.
- Qwen is hidden from model choices on Intel Macs, where its MLX runtime cannot run.
- Cancellation terminates the helper and leaves the recording unchanged.
- Qwen currently does not accept the app's Business Vocabulary prompt; Settings discloses this.

## Persistent installation

The approved runtime was installed at:

`~/Library/Application Support/WhisperMeet/Runtime/Qwen3ASR`

The installer produced a `MANIFEST` containing the pinned versions, revisions, and hashes above.
Both installed model hashes were recalculated successfully, the Python executable is present and
executable, and the installed directory measured 4.2 GB.

## Verification history

- Test-first failures were observed before the new engine enum, alignment assembler, and Qwen client
  existed.
- Focused engine/alignment/client suite: 8 tests passed.
- Focused client suite after enforcing offline operation: 4 tests passed.
- Focused Qwen safety suite after review: 7 tests passed, plus the queued-selection snapshot test.
- Complete suite: 169 tests passed.
- Shell syntax, Python compilation, and `git diff --check` passed.
- Warnings-as-errors release build passed.
- The packaged app contains the Qwen installer/helper and passed
  `codesign --verify --deep --strict`.
- Two independent final re-reviews (repository standards and requested behavior) reported no
  remaining actionable findings.
