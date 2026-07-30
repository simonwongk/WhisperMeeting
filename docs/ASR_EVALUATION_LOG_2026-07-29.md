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

## Quick Dictation integration — 2026-07-30

The follow-up request was to make the model selectable for Quick Dictation while reusing its audio
capture. OpenAI Whisper's live repository documentation and Qwen3-ASR's official repository were
rechecked before changing either adapter. They confirm a common high-level contract (audio in, text
out), but not an interchangeable function call: the runtimes, arguments, warm-model processes,
optional prompt support, and error behavior differ.

### Implementation log

- Preserved `MicDictationRecorder` and its existing ephemeral WAV. The file still follows the same
  cleanup, text delivery, clipboard fallback, and history code regardless of model.
- Added an independent dictation preference with two choices: Whisper Turbo (unchanged default) and
  Qwen3-ASR 1.7B (opt-in). Meeting selection is not coupled to it.
- Added one tested selection boundary that swaps only the `DictationEngine`. It permanently retires
  and drains the previous resident process before installing or warming the replacement. Selection
  is refused while capture, transcription, delivery, model retirement, or a self-test is active.
- Added `qwen_dictate_server.py`, using the existing newline-delimited dictation request/response
  protocol. It receives the same WAV path, maps automatic language to Qwen's `auto`, keeps the ASR
  model resident, forces the pinned installed snapshot offline, and compiles one silent inference
  before emitting `{"ready":true}` so the first real dictation does not pay benchmark-excluded
  first-inference compilation.
- Excluded the forced aligner from dictation. It is necessary for meeting timestamps but would add
  memory and startup cost without changing the dictated text.
- Made vocabulary support an explicit capability. Whisper continues receiving the existing
  `initial_prompt`; Qwen never receives it because the current local Qwen API has no corresponding
  parameter. Settings disables and explains the vocabulary toggle for Qwen.
- Added selected-model diagnostics, a model-specific repair action, self-test text, bundle packaging,
  fresh-install copying, and self-healing copying for runtimes installed before this helper existed.
- Added local logs for model changes, warm-up model, per-engine transcription duration, helper
  synchronization, failures, and the pre-existing delivery/capture outcomes.

### Test-first and real-runtime evidence

- The first focused Swift run initially failed before implementation because the model enum and
  selectable engine did not exist. That attempt also exposed the managed environment's unwritable
  default Clang cache; rerunning with the repository's temporary cache convention produced the
  intended red tests.
- New regression coverage proves that Qwen is opt-in, vocabulary capability is honest, replacing a
  model shuts down the old engine, the Qwen adapter receives the unchanged WAV path, automatic
  language becomes `auto`, Whisper-only vocabulary is not forwarded, and the warm Qwen process uses
  the local model argument and shared wire protocol.
- Focused dictation/Qwen result: **10 tests passed**.
- A first real-model smoke attempt inside the managed sandbox failed with
  `No Metal device available`, as expected for a GPU-restricted process. It was rerun outside that
  restriction with the approved installed runtime.
- The production helper loaded
  `~/Library/Application Support/WhisperMeet/Runtime/Qwen3ASR/model` and transcribed the repository
  clip `Scripts/bench/clips/en1.wav` as:
  `Can you send me the quarterly report by Friday afternoon?`
  The response contained `language: English` and no error. No user recording or transcript was read
  or changed. After the silent prewarm, the complete response arrived inside the first one-second
  output polling window.
- Python compilation, zsh syntax checks, and `git diff --check` passed with no output.
- Complete Swift suite: **176 tests passed**.
- Warnings-as-errors release build: `Build complete!`.
- Packaged application: `.build/WhisperMeet.app`; the bundle contains the 2.3 KB production Qwen
  dictation helper and `codesign --verify --deep --strict` passed.
- The guarded updater installed the verified app at `/Applications/WhisperMeet.app`; strict
  signature verification also passed on the installed copy.

The speed/accuracy choice remains based on the corrected benchmark above: Qwen averaged 0.38 seconds
warm and was the only candidate with zero measured English, Mandarin, and code-switch error on the
small synthetic corpus. This integration does not claim that synthetic accuracy generalizes to
accents, background noise, or every real microphone.

The exact verification excerpts, failed attempts, review findings, and their corrections are in
[`DICTATION_MODEL_SELECTION_LOG_2026-07-30.md`](DICTATION_MODEL_SELECTION_LOG_2026-07-30.md).

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
