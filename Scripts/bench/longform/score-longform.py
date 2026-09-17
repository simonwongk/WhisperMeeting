#!/usr/bin/env python3
"""Score a long-form transcription against the fixture's ground truth (F241).

Run: python3 Scripts/bench/longform/score-longform.py <transcript.json> [build_dir]

Reuses `benchmark.py`'s `norm_latin` / `norm_cjk` / `score`, as F241 specifies, so a long-form
number is comparable with the short-clip rows rather than being a second scoring convention. The
fixture is code-switched by construction — it concatenates en, zh and cs clips — so it is scored
both ways and both are reported: WER on the Latin-normalised text and CER on the 繁→簡-normalised
text. Neither alone describes it, and picking one would flatter whichever engine suits that metric.
"""

import importlib.util
import json
import pathlib
import sys

BENCH = pathlib.Path(__file__).resolve().parents[1]
_spec = importlib.util.spec_from_file_location("benchmark", BENCH / "benchmark.py")
benchmark = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(benchmark)


def transcript_text(path):
    """The text of a `qwen_transcribe.py` output, whatever shape it takes.

    Tolerant on purpose: the helper's payload has changed twice this month (F263's per-sentence
    timings, F273's provenance), and a scorer that only reads one shape would silently score an
    empty string as a total failure rather than saying it could not find the text.
    """
    payload = json.loads(pathlib.Path(path).read_text(encoding="utf-8"))
    if isinstance(payload, dict):
        for key in ("text", "transcript", "transcriptText"):
            if isinstance(payload.get(key), str) and payload[key].strip():
                return payload[key]
        for key in ("segments", "sentences"):
            items = payload.get(key)
            if isinstance(items, list) and items:
                joined = " ".join(
                    str(item.get("text", "")) for item in items if isinstance(item, dict)
                ).strip()
                if joined:
                    return joined
    raise SystemExit(f"{path}: could not find transcript text in {sorted(payload)!r}")


def main(argv):
    if len(argv) < 2:
        raise SystemExit(__doc__.strip().splitlines()[2])
    build = pathlib.Path(argv[2]) if len(argv) > 2 else BENCH / "longform" / "build"
    meta = json.loads((build / "longform.json").read_text(encoding="utf-8"))
    reference = (build / meta["reference"]).read_text(encoding="utf-8").strip()
    hypothesis = transcript_text(argv[1])

    _, wer = benchmark.score(reference, hypothesis, "en")
    _, cer = benchmark.score(reference, hypothesis, "zh")

    print(f"fixture: {meta['seconds']}s, {meta['passes']} passes, "
          f"{meta['chunksAt60s']} chunks at 60 s")
    print(f"reference: {len(reference)} chars   hypothesis: {len(hypothesis)} chars")
    print(f"WER (Latin-normalised): {wer:.4f}")
    print(f"CER (繁→簡 normalised): {cer:.4f}")
    # A length ratio far from 1 is the signal that something structural went wrong — a truncated
    # tail chunk, or a degenerate repetition loop (F260) inflating the output. Either would make the
    # error rates above describe the wrong failure.
    ratio = len(hypothesis) / max(1, len(reference))
    print(f"length ratio: {ratio:.3f}"
          + ("   <- structural: check the tail chunk and F260's cycle guard" if not 0.7 < ratio < 1.4 else ""))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
