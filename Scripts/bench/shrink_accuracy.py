#!/usr/bin/env python3
"""F795 — does Shrink's AAC cost transcription accuracy? Measured, not assumed.

For each synthetic clip in Scripts/bench/clips (generate them with generate_clips.sh; they are
gitignored), this:
  1. upsamples it to 48 kHz 16-bit mono WAV, the format a capture's meeting.wav has;
  2. shrinks it with Shrink's exact two-step recipe (AudioCompressor.compressSpeech): a mixed
     16 kHz mono WAV, then `afconvert -f m4af -d aac -b <bitrate>`;
  3. transcribes both with the installed Whisper CLI, in one run so the model loads once, with the
     app's default settings (model `large`, auto-detected language);
  4. scores both against references.json: WER for English, CER (after 繁->簡 and punctuation
     stripping) for Mandarin and code-switched clips.

Prints one row per clip and exits 1 if any clip's error rate rises by more than one percentage
point — the acceptance line in docs/MEETING_STORAGE_DESIGN.md, part 4.

Run with the app's Whisper environment, which has whisper, jiwer and opencc:
  "$HOME/Library/Application Support/WhisperMeet/Runtime/venv/bin/python" \
      Scripts/bench/shrink_accuracy.py [--bitrate 32000] [--clips DIR]
"""
import argparse
import json
import os
import re
import subprocess
import sys
import tempfile
from pathlib import Path

import jiwer
from opencc import OpenCC

SUPPORT = Path.home() / "Library/Application Support/WhisperMeet"
T2S = OpenCC("t2s")
# The same normalisation as benchmark.py's score(); copied, because importing benchmark.py pulls in
# mlx_whisper, which this environment does not have.
_PUNCT = re.compile(r"[\s，。？！、,.\?!；;：:\"'“”‘’（）()\[\]{}…—\-_/]+")


def score(ref: str, hyp: str, lang: str) -> float:
    if lang == "en":
        return jiwer.wer(_PUNCT.sub(" ", ref.lower()).strip(), _PUNCT.sub(" ", hyp.lower()).strip())
    r, h = _PUNCT.sub("", T2S.convert(ref)), _PUNCT.sub("", T2S.convert(hyp))
    return float("nan") if not r else jiwer.cer(r, h)


def afconvert(*args: str) -> None:
    subprocess.run(["/usr/bin/afconvert", *args], check=True, capture_output=True)


def main() -> int:
    here = Path(__file__).resolve().parent
    parser = argparse.ArgumentParser()
    parser.add_argument("--bitrate", type=int, default=32_000)
    parser.add_argument("--clips", type=Path, default=here / "clips")
    parser.add_argument("--whisper", default=str(SUPPORT / "Runtime/venv/bin/whisper"))
    args = parser.parse_args()

    references = json.loads((args.clips / "references.json").read_text())
    clips = sorted(p for p in args.clips.glob("*.wav") if p.stem in references)
    if not clips:
        print(f"no clips in {args.clips}; run Scripts/bench/generate_clips.sh first", file=sys.stderr)
        return 2

    with tempfile.TemporaryDirectory(prefix="shrink-accuracy-") as tmp:
        work = Path(tmp)
        inputs = []
        for clip in clips:
            original = work / f"{clip.stem}-original.wav"
            afconvert("-f", "WAVE", "-d", "LEI16@48000", str(clip), str(original))
            mixed = work / f".{clip.stem}-work.wav"
            afconvert("-f", "WAVE", "-d", "LEI16@16000", "-c", "1", "--mix", str(original), str(mixed))
            shrunk = work / f"{clip.stem}-shrunk.m4a"
            afconvert("-f", "m4af", "-d", "aac", "-b", str(args.bitrate), str(mixed), str(shrunk))
            mixed.unlink()
            inputs += [original, shrunk]
        out = work / "out"
        out.mkdir()
        subprocess.run(
            [args.whisper, *map(str, inputs), "--model", "large", "--model_dir", str(SUPPORT / "Models"),
             "--task", "transcribe", "--output_format", "json", "--output_dir", str(out),
             "--verbose", "False"],
            check=True,
        )

        print(f"bitrate {args.bitrate} b/s\n")
        print(f"{'clip':<6}{'metric':<7}{'original':>10}{'shrunk':>10}{'delta pp':>10}  shrunk text")
        worst = 0.0
        for clip in clips:
            ref = references[clip.stem]
            texts = {kind: json.loads((out / f"{clip.stem}-{kind}.json").read_text())["text"].strip()
                     for kind in ("original", "shrunk")}
            before, after = (score(ref["text"], texts[k], ref["lang"]) for k in ("original", "shrunk"))
            delta = (after - before) * 100
            worst = max(worst, delta)
            metric = "WER" if ref["lang"] == "en" else "CER"
            print(f"{clip.stem:<6}{metric:<7}{before:>10.3f}{after:>10.3f}{delta:>+10.1f}  {texts['shrunk']}")
        verdict = "PASS" if worst <= 1.0 else "FAIL"
        print(f"\nworst rise {worst:+.1f} pp -> {verdict} (acceptance: no clip rises by more than 1.0 pp)")
        return 0 if verdict == "PASS" else 1


if __name__ == "__main__":
    sys.exit(main())
