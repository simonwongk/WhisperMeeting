#!/usr/bin/env python3
"""F293 — a bench engine that runs the *meeting* transcription script.

`benchmark.py`'s Qwen row drives `qwen_server.py`, the dictation daemon. Meetings run
`Scripts/qwen_transcribe.py`, which chunks and batches differently — so every Qwen number the bench
has ever produced describes a path no meeting takes, and a regression in the meeting path could not
show up while the bench improved. This engine is the other half of F241.

Standard library only, and deliberately its own module: `benchmark.py` imports whisper,
mlx_whisper, jiwer and opencc at module scope, none of which exist in the system python3 that
`Scripts/quality-check.sh` uses, so anything defined there cannot be covered by a gated test.
Extracting the engine is what makes it testable at all.

The engine contract is `benchmark.py`'s: a callable `(path, lang) -> (text, detected_language)`.
"""

import json
import os
import subprocess


def meeting_engine_language(lang: str) -> str:
    """What to tell the helper, matching the daemon row's convention so the two rows differ by
    *path* and not by instruction.

    `QwenServer.transcribe` maps `en` to English and everything else to Chinese. Everything else
    here means `auto` instead: on a code-switched clip, naming a language is a guess, and F271
    measured Whisper dropping over half a mixed clip after committing to one. `QWEN_BENCH_LANGUAGE`
    overrides, as it does for the daemon row.
    """
    override = os.environ.get("QWEN_BENCH_LANGUAGE")
    if override:
        return override
    return {"en": "English", "zh": "Chinese"}.get(lang, "auto")


def meeting_engine_command(python, script, model, aligner, audio, output, language):
    """The argv `QwenASRClient` builds, with the bench's paths.

    All four of --model, --aligner, --audio and --output are `required=True` in
    `qwen_transcribe.py`, so a missing one is an argparse exit — discovered, without a test, only
    part way through a long run.
    """
    return [
        python, script,
        "--model", model,
        "--aligner", aligner,
        "--audio", audio,
        "--output", output,
        "--language", language,
    ]


def read_meeting_payload(path, diagnostic=""):
    """The transcript and the detected language from the helper's `--output` file.

    `language: null` reads as `auto`, never as a language: the helper writes null when it cannot
    tell, and printing that as a detection would put a wrong label in the results table. An empty
    transcript is returned as empty and scores as a total miss, which is the honest result —
    skipping it would quietly raise the engine's average.
    """
    if not os.path.exists(path):
        raise RuntimeError(
            "qwen_transcribe.py wrote no output. Its diagnostics go to stderr and its result to "
            f"--output, so the reason is here or nowhere: {diagnostic.strip()[-600:]}"
        )
    with open(path, encoding="utf-8") as handle:
        payload = json.load(handle)
    return (payload.get("text") or "").strip(), payload.get("language") or "auto"


def make_qwen_meeting(python, script, model, aligner, work_dir, timeout=1800):
    """An engine callable for `benchmark.py`'s engine list.

    One process per clip, which is what the app does for a meeting — the daemon is the dictation
    path's optimisation and reusing it here would measure the thing this engine exists to avoid.
    So the model load is inside every timing; the row is labelled to say so.
    """
    os.makedirs(work_dir, exist_ok=True)

    def run(path, lang):
        output = os.path.join(work_dir, "meeting-out.json")
        if os.path.exists(output):
            os.remove(output)
        completed = subprocess.run(
            meeting_engine_command(
                python, script, model, aligner, path, output, meeting_engine_language(lang)
            ),
            capture_output=True, text=True, timeout=timeout,
        )
        return read_meeting_payload(
            output, diagnostic=(completed.stderr or completed.stdout or "")
        )

    return run
