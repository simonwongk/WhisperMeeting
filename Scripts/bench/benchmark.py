#!/usr/bin/env python3
"""Phase-0 dictation-engine benchmark (M3 Pro).

Compares, on the SAME clips, warm release->text latency + accuracy for:
  - openai/whisper `turbo` (PyTorch, CPU/fp32) — current production baseline
  - mlx-whisper `turbo` fp16 — the candidate fast dictation engine
  - mlx-whisper `turbo` q8   — best-effort (skipped gracefully if convert unavailable)

Accuracy: EN -> WER; 中文 & code-switch -> CER after 繁->簡 (OpenCC) + punctuation/space
stripping, so we don't wrongly penalize traditional/simplified or punctuation differences.

Relative deltas are valid on synthetic TTS clips. Drop real-mic clips (same ids) into
clips/ and re-run for absolute numbers; code-switch especially wants real recordings.

Usage: python benchmark.py [clips_dir]
"""
import json
import os
import re
import subprocess
import sys
import time
from pathlib import Path

import whisper
import mlx_whisper
import jiwer
from opencc import OpenCC

T2S = OpenCC("t2s")
BENCH = Path(__file__).resolve().parent
CLIPS = Path(sys.argv[1]) if len(sys.argv) > 1 else BENCH / "clips"
MODELDIR = os.path.expanduser("~/Library/Application Support/WhisperMeet/Models")
MLX_FP16 = "mlx-community/whisper-large-v3-turbo"

_PUNCT = re.compile(r"[\s，。？！、,.\?!；;：:\"'“”‘’（）()\[\]{}…—\-_/]+")


def norm_latin(s: str) -> str:
    return _PUNCT.sub(" ", s.lower()).strip()


def norm_cjk(s: str) -> str:
    return _PUNCT.sub("", T2S.convert(s))


def score(ref: str, hyp: str, lang: str):
    if lang == "en":
        return "WER", jiwer.wer(norm_latin(ref), norm_latin(hyp))
    r, h = norm_cjk(ref), norm_cjk(hyp)
    if not r:
        return "CER", float("nan")
    return "CER", jiwer.cer(r, h)


def main() -> int:
    refs = json.loads((CLIPS / "references.json").read_text())
    clips = sorted(refs.keys())

    pt = whisper.load_model("turbo", download_root=MODELDIR)

    def run_pt(path):
        r = pt.transcribe(path, task="transcribe", fp16=False, verbose=False)
        return r["text"].strip(), r.get("language")

    def make_mlx(repo):
        def run(path):
            r = mlx_whisper.transcribe(
                path, path_or_hf_repo=repo, task="transcribe", verbose=False
            )
            return r["text"].strip(), r.get("language")
        return run

    engines = [
        ("pytorch-turbo (fp32/CPU baseline)", run_pt),
        ("mlx-turbo-fp16", make_mlx(MLX_FP16)),
    ]

    # Best-effort q8 (local quantize; never q4 per hardware rules). Skips cleanly if unavailable.
    try:
        q8dir = Path(MODELDIR) / "mlx-turbo-q8"
        if not q8dir.exists():
            subprocess.run(
                [sys.executable, "-m", "mlx_whisper.convert",
                 "--torch-name-or-path", "large-v3-turbo",
                 "--mlx-path", str(q8dir), "-q", "--q-bits", "8", "--q-group-size", "64"],
                check=True, timeout=1200,
            )
        engines.append(("mlx-turbo-q8", make_mlx(str(q8dir))))
    except Exception as e:  # noqa: BLE001
        print(f"[q8 skipped: {e!r}] — fp16 is the recommended config on 18 GB anyway.\n")

    # Warm each engine (first call loads the model; timing discarded).
    for name, fn in engines:
        try:
            fn(str(CLIPS / f"{clips[0]}.wav"))
        except Exception as e:  # noqa: BLE001
            print(f"[warmup {name} failed: {e!r}]")

    results = {}
    for name, fn in engines:
        rows = []
        for cid in clips:
            path = str(CLIPS / f"{cid}.wav")
            lang, ref = refs[cid]["lang"], refs[cid]["text"]
            t0 = time.perf_counter()
            try:
                hyp, det = fn(path)
                dt = round(time.perf_counter() - t0, 3)
                metric, val = score(ref, hyp, lang)
                val = round(val, 3)
            except Exception as e:  # noqa: BLE001
                dt, hyp, det, metric, val = -1.0, f"ERROR: {e!r}", "?", "?", float("nan")
            rows.append(dict(clip=cid, lang=lang, sec=dt, det=det, metric=metric, val=val, hyp=hyp))
        results[name] = rows

    def avg(rows, pred):
        xs = [r["val"] for r in rows if pred(r) and r["val"] == r["val"]]
        return sum(xs) / len(xs) if xs else float("nan")

    def avgsec(rows):
        xs = [r["sec"] for r in rows if r["sec"] >= 0]
        return sum(xs) / len(xs) if xs else float("nan")

    L = ["# Phase 0 — dictation engine benchmark (M3 Pro, 18 GB; synthetic clips)\n",
         "Warm release→text latency (model resident) + accuracy. Lower is better everywhere.",
         "CER normalized 繁→簡 (OpenCC) with punctuation/spaces stripped.\n",
         "## Summary\n",
         "| engine | avg sec | EN WER | 中文 CER | code-switch CER |",
         "|---|---|---|---|---|"]
    for name, _ in engines:
        rows = results[name]
        L.append(f"| {name} | {avgsec(rows):.2f} | "
                 f"{avg(rows, lambda r: r['lang']=='en'):.3f} | "
                 f"{avg(rows, lambda r: r['lang']=='zh'):.3f} | "
                 f"{avg(rows, lambda r: r['lang']=='cs'):.3f} |")
    for name, _ in engines:
        L.append(f"\n## {name} — per clip\n")
        L.append("| clip | lang | sec | detected | metric | value | transcript |")
        L.append("|---|---|---|---|---|---|---|")
        for r in results[name]:
            L.append(f"| {r['clip']} | {r['lang']} | {r['sec']} | {r['det']} | "
                     f"{r['metric']} | {r['val']} | {r['hyp']} |")
    md = "\n".join(L)
    (BENCH / "results.md").write_text(md)
    (BENCH / "results.json").write_text(json.dumps(results, ensure_ascii=False, indent=2))
    print(md)
    return 0


if __name__ == "__main__":
    sys.exit(main())
