#!/usr/bin/env python3
"""Local ASR benchmark (M3 Pro).

Compares, on the SAME clips, warm release->text latency + accuracy for:
  - openai/whisper `turbo` (PyTorch, CPU/fp32) — current production baseline
  - mlx-whisper `turbo` fp16 — the candidate fast dictation engine
  - mlx-whisper `turbo` q8   — best-effort (skipped gracefully if convert unavailable)
  - SenseVoiceSmall q8 + FSMN-VAD — when SENSEVOICE_* paths are set
  - Qwen3-ASR-1.7B MLX 8-bit — when QWEN_PYTHON and QWEN_MODEL are set

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
from contextlib import ExitStack
from pathlib import Path

import whisper
import mlx_whisper
import jiwer
from opencc import OpenCC

# F293 — the meeting-path engine lives in its own stdlib-only module so it can be covered by a gated
# test; everything in this file is unreachable from `Scripts/quality-check.sh`, whose python3 has
# none of the four imports above.
import importlib.util as _importlib_util

_engine_spec = _importlib_util.spec_from_file_location(
    "qwen_meeting_engine", Path(__file__).resolve().parent / "qwen_meeting_engine.py"
)
qwen_meeting_engine = _importlib_util.module_from_spec(_engine_spec)
_engine_spec.loader.exec_module(qwen_meeting_engine)

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


class QwenServer:
    def __init__(self, python: str, model: str):
        self.process = subprocess.Popen(
            [python, str(BENCH / "qwen_server.py"), model],
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            bufsize=1,
        )
        ready = self._read_response(timeout_seconds=120)
        if ready.get("ready") is not True:
            raise RuntimeError(f"Qwen helper did not become ready: {ready}")

    def close(self) -> None:
        if self.process.stdin:
            self.process.stdin.close()
        try:
            self.process.wait(timeout=5)
        except subprocess.TimeoutExpired:
            self.process.terminate()
            self.process.wait(timeout=5)

    def transcribe(self, path: str, lang: str):
        language = os.environ.get("QWEN_BENCH_LANGUAGE")
        if not language:
            language = "English" if lang == "en" else "Chinese"
        assert self.process.stdin
        self.process.stdin.write(json.dumps({"audio": path, "language": language}) + "\n")
        self.process.stdin.flush()
        response = self._read_response(timeout_seconds=600)
        if "error" in response:
            raise RuntimeError(response["error"])
        detected = {
            "English": "en",
            "Chinese": "zh",
        }.get(language, "auto")
        return response["text"], detected

    def _read_response(self, timeout_seconds: float) -> dict:
        assert self.process.stdout
        started = time.monotonic()
        while time.monotonic() - started < timeout_seconds:
            line = self.process.stdout.readline()
            if not line:
                diagnostic = ""
                if self.process.stderr:
                    diagnostic = self.process.stderr.read().strip()
                raise RuntimeError(
                    f"Qwen helper exited with {self.process.poll()}: {diagnostic}"
                )
            try:
                return json.loads(line)
            except json.JSONDecodeError:
                continue
        raise TimeoutError("Qwen helper response timed out")


def make_sensevoice(binary: str, model: str, vad: str):
    def run(path: str, _lang: str):
        completed = subprocess.run(
            [binary, "-m", model, "--vad", vad, "-a", path],
            check=True,
            capture_output=True,
            text=True,
            timeout=600,
        )
        text = "\n".join(
            line for line in completed.stdout.splitlines()
            if line.strip() and not line.startswith("[sensevoice]")
        ).strip()
        return text, "auto"

    return run


def main() -> int:
    refs = json.loads((CLIPS / "references.json").read_text())
    clips = sorted(refs.keys())
    requested = {
        item.strip()
        for item in os.environ.get(
            # `qwen-meeting` is opt-in: one model load per clip makes it far slower than the
            # daemon row, and it needs QWEN_ALIGNER and QWEN_TRANSCRIBE as well (F293).
            "BENCH_ENGINES", "pytorch,mlx,sensevoice,qwen"
        ).split(",")
        if item.strip()
    }

    def make_mlx(repo):
        def run(path, _lang):
            r = mlx_whisper.transcribe(
                path, path_or_hf_repo=repo, task="transcribe", verbose=False
            )
            return r["text"].strip(), r.get("language")
        return run

    with ExitStack() as resources:
        engines = []
        if "pytorch" in requested:
            pt = whisper.load_model("turbo", download_root=MODELDIR)

            def run_pt(path, _lang):
                r = pt.transcribe(path, task="transcribe", fp16=False, verbose=False)
                return r["text"].strip(), r.get("language")

            engines.append(("pytorch-turbo (fp32/CPU baseline)", run_pt))
        if "mlx" in requested:
            engines.append(("mlx-turbo-fp16", make_mlx(MLX_FP16)))

        # Best-effort q8 (local quantize; never q4 per hardware rules). Skips cleanly if unavailable.
        if "mlx-q8" in requested and os.environ.get("SKIP_MLX_Q8") != "1":
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

        sense_paths = (
            os.environ.get("SENSEVOICE_BIN"),
            os.environ.get("SENSEVOICE_MODEL"),
            os.environ.get("SENSEVOICE_VAD"),
        )
        if "sensevoice" in requested and all(sense_paths):
            engines.append(("sensevoice-small-q8", make_sensevoice(*sense_paths)))

        qwen_python = os.environ.get("QWEN_PYTHON")
        qwen_model = os.environ.get("QWEN_MODEL")
        if "qwen" in requested and qwen_python and qwen_model:
            try:
                qwen = QwenServer(qwen_python, qwen_model)
                resources.callback(qwen.close)
                suffix = "-auto" if os.environ.get("QWEN_BENCH_LANGUAGE") == "auto" else ""
                engines.append((f"qwen3-asr-1.7b-8bit{suffix}", qwen.transcribe))
            except Exception as e:  # noqa: BLE001
                print(f"[Qwen skipped: {e!r}]\n")

        # F293 — the same weights through the script a MEETING actually runs. The row above drives
        # `qwen_server.py`, the dictation daemon; `qwen_transcribe.py` chunks and batches
        # differently, so until this row existed every Qwen number here described a path no meeting
        # takes. One process per clip, as the app does, so the model load is inside the timing — the
        # label says `cold` for that reason, and its seconds are not comparable with the daemon's.
        qwen_aligner = os.environ.get("QWEN_ALIGNER")
        qwen_script = os.environ.get("QWEN_TRANSCRIBE")
        if ("qwen-meeting" in requested and qwen_python and qwen_model
                and qwen_aligner and qwen_script):
            engines.append((
                "qwen3-asr-1.7b-8bit-meeting-cold",
                qwen_meeting_engine.make_qwen_meeting(
                    qwen_python, qwen_script, qwen_model, qwen_aligner,
                    work_dir=str(BENCH / "work"),
                ),
            ))

        # Warm each engine (first call loads the model; timing discarded).
        for name, fn in engines:
            try:
                first = clips[0]
                fn(str(CLIPS / f"{first}.wav"), refs[first]["lang"])
            except Exception as e:  # noqa: BLE001
                print(f"[warmup {name} failed: {e!r}]")

        result_path = BENCH / "results.json"
        results = {}
        if os.environ.get("BENCH_APPEND") == "1" and result_path.exists():
            results = json.loads(result_path.read_text())
        for name, fn in engines:
            rows = []
            for cid in clips:
                path = str(CLIPS / f"{cid}.wav")
                lang, ref = refs[cid]["lang"], refs[cid]["text"]
                t0 = time.perf_counter()
                try:
                    hyp, det = fn(path, lang)
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

        # The scope caveat is EMITTED here, not hand-written into results.md.
        #
        # It used to live in the file, and this function rewrites results.md from scratch on every
        # run — so the first run after it was written silently deleted it, and the deletion was
        # about to be committed as part of F293. Prose that explains a table has to be produced by
        # whatever produces the table, or it survives exactly until someone runs the benchmark.
        scope = [
            "## Scope — this is a DICTATION benchmark, not a meeting benchmark\n",
            "Read before quoting any number here. All ten clips are short (about 2–3 s), which is "
            "the Quick\nDictation shape. For meetings these numbers are invalid, and for a "
            "different reason per engine:\n",
            "- **Every row is warm, except the `-meeting-cold` row.** The warm-up call's timing is "
            "discarded, so\n  no other row includes model load. A real meeting pays that load once "
            "(measured elsewhere at\n  2–11 s). The meeting row spawns a process per clip and so "
            "*does* include it — which is why its\n  seconds are not comparable with the others, "
            "and why `cold` is in its name.",
            "- **Whisper rows** (`pytorch-turbo`, `mlx-turbo-*`): Whisper pads every input to a 30 s "
            "mel window,\n  so a 3 s clip pays one full encoder pass and roughly ten tokens of "
            "decode. Long-form audio pays\n  that same encoder per window but far more decode per "
            "window. These rows are therefore\n  encoder-dominated and **understate decode cost** "
            "— exactly where a CPU fp32 path is worst. Do\n  not extrapolate a realtime factor for "
            "a meeting from them.",
            "- **`qwen3-asr-1.7b-8bit`**: the resident dictation daemon (`bench/qwen_server.py`), "
            "not the script a\n  meeting runs. A 3 s clip never fills a 60 s chunk, so the 60 s × 4 "
            "batching and its padding are\n  never exercised here, and the row is warm.",
            "- **`qwen3-asr-1.7b-8bit-meeting-cold`** (F293): the same weights through "
            "`Scripts/qwen_transcribe.py`,\n  the script a meeting actually runs — added because "
            "until it existed every Qwen number in this\n  file described a path no meeting takes. "
            "On these clips it is byte-identical to the daemon row,\n  which says the clips cannot "
            "discriminate the two paths rather than that the paths agree in\n  general: 2–3 s is "
            "still one chunk. What it did surface is a wrong language label on the\n  "
            "code-switched clips (**F296**).",
            "\nThere is still no long-form ASR measurement in this table. Until one exists, treat a "
            "meeting-speed\nclaim sourced from it as unsupported — see **F241** for the long-form "
            "fixture and its scorer.\n",
        ]
        L = ["# Local ASR benchmark (M3 Pro, 18 GB; synthetic clips)\n",
             "Warm release→text latency (model resident) + accuracy. Lower is better everywhere.",
             "CER normalized 繁→簡 (OpenCC) with punctuation/spaces stripped.\n",
             *scope,
             "## Summary\n",
             "| engine | avg sec | EN WER | 中文 CER | code-switch CER |",
             "|---|---|---|---|---|"]
        for name in results:
            rows = results[name]
            L.append(f"| {name} | {avgsec(rows):.2f} | "
                     f"{avg(rows, lambda r: r['lang']=='en'):.3f} | "
                     f"{avg(rows, lambda r: r['lang']=='zh'):.3f} | "
                     f"{avg(rows, lambda r: r['lang']=='cs'):.3f} |")
        for name in results:
            L.append(f"\n## {name} — per clip\n")
            L.append("| clip | lang | sec | detected | metric | value | transcript |")
            L.append("|---|---|---|---|---|---|---|")
            for r in results[name]:
                L.append(f"| {r['clip']} | {r['lang']} | {r['sec']} | {r['det']} | "
                         f"{r['metric']} | {r['val']} | {r['hyp']} |")
        md = "\n".join(L)
        (BENCH / "results.md").write_text(md)
        result_path.write_text(json.dumps(results, ensure_ascii=False, indent=2))
        print(md)
        return 0


if __name__ == "__main__":
    sys.exit(main())
