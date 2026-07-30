#!/usr/bin/env python3
"""Compare the two Quick Dictation engines through their PRODUCTION helpers.

This is deliberately different from `benchmark.py`, which loads candidate models with its own
loaders to compare engine families. This script spawns the *shipped* helper subprocesses with the
exact argv `WarmWhisperDictationEngine` / `WarmQwenDictationEngine` use, and speaks the same
newline-delimited JSON wire protocol (`{"wavPath": …, "language": …, "initialPrompt": …}`). So it
exercises the real integration boundary, and would have caught F24 — the helper writing
`Detected language: X` onto its own JSON stdout — which a model-level benchmark cannot see.

Usage:
    Scripts/bench/dictation-ab.py                 # both engines, markdown table on stdout
    Scripts/bench/dictation-ab.py --json out.json # also dump per-clip detail
    Scripts/bench/dictation-ab.py --engine turbo  # one engine only

Requires the runtimes to be installed (Settings → Install…), and the clips to exist:
`Scripts/bench/clips/*.wav` are gitignored, so run `Scripts/bench/generate_clips.sh` first.
Reads only the bench clips — never a user recording, meeting index, or transcript.
"""
import argparse
import json
import os
import subprocess
import sys
import time
import unicodedata

BENCH = os.path.dirname(os.path.abspath(__file__))
CLIPS = os.path.join(BENCH, "clips")
SUPPORT = os.path.expanduser("~/Library/Application Support/WhisperMeet")

ENGINES = {
    # Mirrors DictationController.makeEngine(for:) — keep in sync if that changes.
    "qwen3-asr-1.7b-8bit": {
        "label": "Qwen3-ASR 1.7B",
        "python": f"{SUPPORT}/Runtime/Qwen3ASR/venv/bin/python",
        "script": f"{SUPPORT}/Runtime/Qwen3ASR/qwen_dictate_server.py",
        "args": ["--model", f"{SUPPORT}/Runtime/Qwen3ASR/model"],
        # WarmWhisperDictationEngine sets these for the Qwen runtime.
        "env": {"HF_HUB_OFFLINE": "1", "TRANSFORMERS_OFFLINE": "1"},
    },
    "turbo": {
        "label": "Whisper Turbo",
        "python": f"{SUPPORT}/Runtime/venv/bin/python",
        "script": f"{SUPPORT}/Runtime/whisper_dictate_server.py",
        "args": ["--mlx-repo", "mlx-community/whisper-large-v3-turbo",
                 "--model-dir", f"{SUPPORT}/Models"],
        "env": {},
    },
}


def normalize(text):
    text = unicodedata.normalize("NFKC", text).lower()
    return "".join(c for c in text if c.isalnum() or c.isspace()).split()


def error_rate(reference, hypothesis, by_char):
    """WER for English, CER for Mandarin and code-switch. Levenshtein over the chosen unit."""
    if by_char:
        r, h = list("".join(normalize(reference))), list("".join(normalize(hypothesis)))
    else:
        r, h = normalize(reference), normalize(hypothesis)
    if not r:
        return 0.0
    previous = list(range(len(h) + 1))
    for i, rc in enumerate(r, 1):
        current = [i]
        for j, hc in enumerate(h, 1):
            current.append(min(previous[j] + 1, current[j - 1] + 1,
                               previous[j - 1] + (rc != hc)))
        previous = current
    return previous[len(h)] / len(r)


def run_engine(key, spec, references, verbose):
    environment = dict(os.environ)
    environment.update({"PYTHONUNBUFFERED": "1", "HF_HUB_DISABLE_PROGRESS_BARS": "1"})
    environment.update(spec["env"])
    environment["PATH"] = "/opt/homebrew/bin:/usr/local/bin:" + environment.get("PATH", "")

    started = time.monotonic()
    process = subprocess.Popen(
        [spec["python"], spec["script"], *spec["args"]],
        stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
        env=environment, text=True,
    )
    # The helper must answer the handshake with a JSON object. A bare line here is the F24 defect.
    ready = process.stdout.readline()
    cold_seconds = time.monotonic() - started
    if '"ready"' not in ready:
        process.kill()
        detail = (ready or "<no output>").strip() + "\n" + process.stderr.read()[-800:]
        hint = ""
        if ready.strip() and not ready.lstrip().startswith("{"):
            # This is the F24 signature: chatter on the JSON wire. Most likely the INSTALLED
            # helper predates the fix, because the app only syncs the selected engine's helper
            # from its bundle (F25). Selecting that engine in Settings re-syncs it.
            hint = ("\nThe helper wrote a non-JSON line on its protocol stream. The installed copy "
                    f"at\n  {spec['script']}\nmay predate a shipped fix — the app syncs only the "
                    "SELECTED engine's helper (see F25).\nSelect this engine in Settings, or copy "
                    "the bundled helper over it, then re-run.")
        raise SystemExit(f"{key}: helper never reported ready.\n{detail}{hint}")

    rows = []
    for clip_id, reference in sorted(references.items()):
        wav = os.path.join(CLIPS, f"{clip_id}.wav")
        if not os.path.exists(wav):
            raise SystemExit(f"missing {wav} — run Scripts/bench/generate_clips.sh first")
        # language: null is the app's "Detect automatically" default.
        request = {"wavPath": wav, "language": None, "initialPrompt": None}
        clip_started = time.monotonic()
        process.stdin.write(json.dumps(request) + "\n")
        process.stdin.flush()
        response = json.loads(process.stdout.readline())
        elapsed = time.monotonic() - clip_started
        text = response.get("text") or ""
        rate = error_rate(reference["text"], text, reference["lang"] in ("zh", "cs"))
        rows.append({"clip": clip_id, "lang": reference["lang"], "seconds": round(elapsed, 3),
                     "text": text, "reference": reference["text"],
                     "error_rate": round(rate, 4), "helper_error": response.get("error")})
        if verbose:
            print(f"  {key:22} {clip_id}  {elapsed:6.2f}s  err={rate:.3f}  {text!r}", flush=True)

    process.stdin.close()
    process.wait(timeout=30)
    return {"engine": key, "label": spec["label"],
            "cold_seconds": round(cold_seconds, 2), "clips": rows}


def table(results):
    languages = ("en", "zh", "cs")
    out = ["| engine | cold start | warm per clip | en | zh | code-switch |",
           "|---|---|---|---|---|---|"]
    for result in results:
        clips = result["clips"]
        warm = sum(c["seconds"] for c in clips) / len(clips)
        cells = []
        for lang in languages:
            subset = [c["error_rate"] for c in clips if c["lang"] == lang]
            cells.append(f"{sum(subset) / len(subset):.3f}" if subset else "—")
        out.append(f"| {result['label']} | {result['cold_seconds']:.1f} s | "
                   f"{warm:.2f} s | " + " | ".join(cells) + " |")
    return "\n".join(out)


def main():
    parser = argparse.ArgumentParser(description=__doc__,
                                     formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--engine", choices=sorted(ENGINES), action="append",
                        help="restrict to one engine (repeatable); default is both")
    parser.add_argument("--json", metavar="PATH", help="write per-clip detail as JSON")
    parser.add_argument("--quiet", action="store_true", help="table only")
    arguments = parser.parse_args()

    with open(os.path.join(CLIPS, "references.json"), encoding="utf-8") as handle:
        references = json.load(handle)

    results = []
    for key in (arguments.engine or sorted(ENGINES)):
        spec = ENGINES[key]
        if not (os.path.exists(spec["python"]) and os.path.exists(spec["script"])):
            print(f"skip {key}: runtime not installed", file=sys.stderr)
            continue
        if not arguments.quiet:
            print(f"== {key} ==", flush=True)
        results.append(run_engine(key, spec, references, not arguments.quiet))

    if not results:
        raise SystemExit("no engine runtime installed — nothing to compare")

    print()
    print(table(results))
    print("\nLatency varies run to run and with thermal state; error rates are deterministic "
          "for a given clip set.")
    if arguments.json:
        with open(arguments.json, "w", encoding="utf-8") as handle:
            json.dump(results, handle, ensure_ascii=False, indent=2)
        print(f"wrote {arguments.json}")


if __name__ == "__main__":
    sys.exit(main())
