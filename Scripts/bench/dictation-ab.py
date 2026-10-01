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
    Scripts/bench/dictation-ab.py --engine qwen-meeting --clips encs,cs --words
                                                  # the MEETING path on the same clips (F628)

`qwen-meeting` is not a dictation engine and is not run by default: it is a control row that runs
the same Qwen weights through `qwen_transcribe.py`, the script a meeting runs, one process per clip
with the argv `QwenASRClient` builds — so a per-word result can be told apart as the model's or the
dictation path's.

Requires the runtimes to be installed (Settings → Install…), and the clips to exist:
`Scripts/bench/clips/*.wav` are gitignored, so run `Scripts/bench/generate_clips.sh` first.
Reads only the bench clips — never a user recording, meeting index, or transcript.

The refine stage (F631). This script measures recognition only. To see what Quick Dictation's
refinement then does to the same words, give its `--json` files to the opt-in Swift bench. The
bench sends each raw transcript through `DictationRefiner` as the app does, against the installed
refine helper, and prints the per-word raw-vs-delivered table. Each file records the language
setting its run used (`language`, null = Automatic), and the bench labels conditions by it:

    Scripts/bench/dictation-ab.py --clips encs,cs --words --json /tmp/raw-auto.json
    Scripts/bench/dictation-ab.py --clips encs,cs --words --language English --json /tmp/raw-en.json
    WHISPERMEET_REFINE_BENCH=1 WHISPERMEET_REFINE_BENCH_RAW=/tmp/raw-auto.json:/tmp/raw-en.json \\
        swift test --disable-sandbox --no-parallel --filter RefineStageBenchTests

(On a Command Line Tools Mac, add the framework flags AGENTS.md lists under Build commands.)
"""
import argparse
import importlib.util
import json
import os
import subprocess
import sys
import tempfile
import time
import unicodedata

BENCH = os.path.dirname(os.path.abspath(__file__))
CLIPS = os.path.join(BENCH, "clips")
SUPPORT = os.path.expanduser("~/Library/Application Support/WhisperMeet")

# F628 — the meeting engine's argv and payload reader are F293's, not a second copy. Loaded by path
# as `benchmark.py` loads it; it is stdlib-only, so this script still runs on the system python3.
_meeting_spec = importlib.util.spec_from_file_location(
    "qwen_meeting_engine", os.path.join(BENCH, "qwen_meeting_engine.py"))
qwen_meeting_engine = importlib.util.module_from_spec(_meeting_spec)
_meeting_spec.loader.exec_module(qwen_meeting_engine)

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
    # F628: the same Qwen weights through the script a MEETING runs — QwenASRClient's paths under
    # Runtime/Qwen3ASR and its forced environment (QwenASRClient.makeEnvironment). One process per
    # clip, as the app runs one per meeting, so every clip's seconds include the model and aligner
    # load. Not in DEFAULT_ENGINES; ask for it with --engine qwen-meeting.
    "qwen-meeting": {
        "label": "Qwen3-ASR 1.7B (meeting path)",
        "kind": "meeting",
        "python": f"{SUPPORT}/Runtime/Qwen3ASR/venv/bin/python",
        "script": f"{SUPPORT}/Runtime/Qwen3ASR/qwen_transcribe.py",
        "model": f"{SUPPORT}/Runtime/Qwen3ASR/model",
        "aligner": f"{SUPPORT}/Runtime/Qwen3ASR/aligner",
        "env": {"HF_HUB_OFFLINE": "1", "TRANSFORMERS_OFFLINE": "1"},
    },
}

# What a run with no --engine compares: the two Quick Dictation helpers.
DEFAULT_ENGINES = ("qwen3-asr-1.7b-8bit", "turbo")


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


def matches_clip_filter(clip_id, patterns):
    """Whether `clip_id` is named exactly, or by prefix, by one of `patterns` (F589 --clips)."""
    return any(clip_id == pattern or clip_id.startswith(pattern) for pattern in patterns)


def word_diff(reference, hypothesis):
    """Per-word kept/dropped verdicts for `reference["words"]` against `hypothesis` (F589).

    "Kept" is a normalized substring match — good enough for the CJK words here (no word spaces,
    so a substring check is the natural containment test) and for the Latin words in cs1-3.
    "Dropped" only says the word is not verbatim present; it does NOT guess a replacement, because
    guessing "replaced by X" automatically is unreliable — the raw hypothesis is included so a
    human reviewing the table can read off what actually stands in the word's place, if anything.
    """
    hyp_norm = "".join(normalize(hypothesis))
    results = []
    for word in reference.get("words", []):
        word_norm = "".join(normalize(word))
        kept = bool(word_norm) and word_norm in hyp_norm
        results.append({"word": word, "kept": kept})
    return results


def helper_environment(spec):
    environment = dict(os.environ)
    environment.update({"PYTHONUNBUFFERED": "1", "HF_HUB_DISABLE_PROGRESS_BARS": "1"})
    environment.update(spec["env"])
    environment["PATH"] = "/opt/homebrew/bin:/usr/local/bin:" + environment.get("PATH", "")
    return environment


def selected_clips(references, clip_filter):
    """(clip id, reference, wav path) for every clip the run covers, in id order."""
    for clip_id, reference in sorted(references.items()):
        if clip_filter and not matches_clip_filter(clip_id, clip_filter):
            continue
        wav = os.path.join(CLIPS, f"{clip_id}.wav")
        if not os.path.exists(wav):
            raise SystemExit(f"missing {wav} — run Scripts/bench/generate_clips.sh first")
        yield clip_id, reference, wav


def clip_row(clip_id, reference, text, elapsed, helper_error, reported_language):
    rate = error_rate(reference["text"], text, reference["lang"] in ("zh", "cs", "encs"))
    row = {"clip": clip_id, "lang": reference["lang"], "seconds": round(elapsed, 3),
           "text": text, "reference": reference["text"],
           "error_rate": round(rate, 4), "helper_error": helper_error,
           "reported_language": reported_language}
    if "words" in reference:
        row["words"] = word_diff(reference, text)
    return row


def print_row(key, row):
    print(f"  {key:22} {row['clip']}  {row['seconds']:6.2f}s  err={row['error_rate']:.3f}  "
          f"{row['text']!r}", flush=True)
    if row["helper_error"]:
        print(f"    helper error: {row['helper_error']}", flush=True)
    for w in row.get("words", []):
        print(f"    word {w['word']!r:16} {'KEPT' if w['kept'] else 'DROPPED'}", flush=True)


def run_engine(key, spec, references, verbose, clip_filter=None, language=None):
    environment = helper_environment(spec)

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
            # This is the F24 signature: chatter on the JSON wire, meaning the INSTALLED helper
            # predates a shipped fix.
            #
            # The advice here used to say the app syncs only the selected engine's helper and to
            # switch engines in Settings. That stopped being true at F25 (F208):
            # `DictationController.ensureHelperInstalled` syncs EVERY dictation engine's helper from
            # `DictationTranscriptionEngine.allCases`, plus the refine helper, plus the Qwen meeting
            # helper since F207 — and it runs on enable, on an engine change, on a self-test and
            # when accessibility is granted. So switching engines was never the thing that fixed
            # this; opening the app at all is.
            #
            # Which makes a stale installed copy mean something more specific: either the app has
            # not been launched since the fix was built, or its own sync failed. The bundle is the
            # source of truth either way, so copying it over is the direct repair and the log says
            # whether the app tried.
            hint = ("\nThe helper wrote a non-JSON line on its protocol stream, so the installed "
                    f"copy at\n  {spec['script']}\npredates a shipped fix.\n\nThe app syncs all "
                    "dictation helpers from its bundle whenever dictation is enabled, the engine "
                    "changes,\na self-test runs, or accessibility is granted (F25/F207) — so this "
                    "means it has not been\nlaunched since the fix was built, or its sync failed. "
                    "Either open the current build once, or\ncopy the bundled helper over the "
                    "installed one, then re-run. To see whether the app tried:\n"
                    "  log show --last 1h --predicate 'subsystem == \"com.whispermeet.app\"' "
                    "| grep -i helper")
        raise SystemExit(f"{key}: helper never reported ready.\n{detail}{hint}")

    rows = []
    for clip_id, reference, wav in selected_clips(references, clip_filter):
        # language: null is the app's "Detect automatically" default; --language overrides it to
        # the exact pinned string the app sends (WhisperLanguage.commandLineValue, e.g. "English").
        request = {"wavPath": wav, "language": language, "initialPrompt": None}
        clip_started = time.monotonic()
        process.stdin.write(json.dumps(request) + "\n")
        process.stdin.flush()
        response = json.loads(process.stdout.readline())
        elapsed = time.monotonic() - clip_started
        row = clip_row(clip_id, reference, response.get("text") or "", elapsed,
                       response.get("error"), response.get("language"))
        rows.append(row)
        if verbose:
            print_row(key, row)

    process.stdin.close()
    process.wait(timeout=30)
    process.stdout.close()
    process.stderr.close()
    # `language` is the setting this run sent (None = Automatic), which no row can tell you: a
    # pinned helper echoes the name it was sent, an automatic one reports what it detected (F631).
    return {"engine": key, "label": spec["label"], "language": language,
            "cold_seconds": round(cold_seconds, 2), "clips": rows}


def run_meeting_engine(key, spec, references, verbose, clip_filter=None, language=None,
                       runner=subprocess.run, timeout=1800):
    """The meeting path (F628): one `qwen_transcribe.py` process per clip, reading `--output`.

    `language=None` is the app's "Detect automatically", which `QwenASRClient` sends to this helper
    as `auto` (`language.commandLineValue ?? "auto"`); a pinned value such as "English" is passed
    through as the app would pass it. A run that writes no output is a recorded total miss carrying
    the helper's stderr tail, never a skipped clip — skipping would quietly raise the row's score.
    """
    environment = helper_environment(spec)
    rows = []
    with tempfile.TemporaryDirectory(prefix="dictation-ab-meeting-") as work:
        output = os.path.join(work, "meeting-out.json")
        for clip_id, reference, wav in selected_clips(references, clip_filter):
            # One work file serves every clip, so the previous clip's must go first: a helper that
            # dies before writing would otherwise be credited with the last clip's transcript.
            if os.path.exists(output):
                os.remove(output)
            command = qwen_meeting_engine.meeting_engine_command(
                spec["python"], spec["script"], spec["model"], spec["aligner"],
                wav, output, language or "auto")
            clip_started = time.monotonic()
            completed = runner(command, capture_output=True, text=True, env=environment,
                               timeout=timeout)
            elapsed = time.monotonic() - clip_started
            try:
                text, detected = qwen_meeting_engine.read_meeting_payload(
                    output, diagnostic=(completed.stderr or completed.stdout or ""))
                helper_error = None
            except RuntimeError as failure:
                text, detected, helper_error = "", None, str(failure)
            row = clip_row(clip_id, reference, text, elapsed, helper_error, detected)
            rows.append(row)
            if verbose:
                print_row(key, row)
    # No daemon, so no separate cold start: the load is inside every clip's seconds.
    return {"engine": key, "label": spec["label"], "language": language,
            "cold_seconds": None, "clips": rows}


def table(results):
    languages = ("en", "zh", "cs", "encs")
    out = ["| engine | cold start | warm per clip | en | zh | code-switch | en-dominant code-switch |",
           "|---|---|---|---|---|---|---|"]
    for result in results:
        clips = result["clips"]
        warm = sum(c["seconds"] for c in clips) / len(clips)
        cells = []
        for lang in languages:
            subset = [c["error_rate"] for c in clips if c["lang"] == lang]
            cells.append(f"{sum(subset) / len(subset):.3f}" if subset else "—")
        if result["cold_seconds"] is None:
            # The meeting row: a process per clip, so its per-clip seconds include the load.
            timing = f"in every clip | {warm:.2f} s (cold)"
        else:
            timing = f"{result['cold_seconds']:.1f} s | {warm:.2f} s"
        out.append(f"| {result['label']} | {timing} | " + " | ".join(cells) + " |")
    return "\n".join(out)


def word_table(results):
    """One row per (engine, clip, word) with its kept/dropped verdict (F589 --words)."""
    out = ["| engine | clip | word | verdict | hypothesis |", "|---|---|---|---|---|"]
    for result in results:
        for clip in result["clips"]:
            for w in clip.get("words", []):
                verdict = "kept" if w["kept"] else "DROPPED"
                out.append(f"| {result['label']} | {clip['clip']} | {w['word']} | {verdict} | "
                           f"{clip['text']!r} |")
    return "\n".join(out)


def main():
    parser = argparse.ArgumentParser(description=__doc__,
                                     formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--engine", choices=sorted(ENGINES), action="append",
                        help="restrict to one engine (repeatable); default is the two "
                             "dictation engines. qwen-meeting runs the meeting script instead")
    parser.add_argument("--clips", metavar="ID[,ID...]",
                        help="restrict to clip ids or id-prefixes (comma-separated), "
                             "e.g. --clips encs,cs; default is every clip in references.json")
    parser.add_argument("--language", metavar="VALUE", default=None,
                        help="pin the wire protocol's language field to VALUE (e.g. English, "
                             "Chinese) instead of the default null/automatic")
    parser.add_argument("--words", action="store_true",
                        help="print the per-word kept/dropped table for clips whose reference "
                             "carries a \"words\" list (F589)")
    parser.add_argument("--json", metavar="PATH", help="write per-clip detail as JSON")
    parser.add_argument("--quiet", action="store_true", help="table only")
    arguments = parser.parse_args()

    with open(os.path.join(CLIPS, "references.json"), encoding="utf-8") as handle:
        references = json.load(handle)

    clip_filter = arguments.clips.split(",") if arguments.clips else None

    results = []
    for key in (arguments.engine or DEFAULT_ENGINES):
        spec = ENGINES[key]
        if not (os.path.exists(spec["python"]) and os.path.exists(spec["script"])):
            print(f"skip {key}: runtime not installed", file=sys.stderr)
            continue
        if not arguments.quiet:
            # Only note the language when --language actually overrode the default (automatic),
            # so an ordinary run's header doesn't read as if something had been pinned.
            suffix = f" (language={arguments.language!r})" if arguments.language else ""
            print(f"== {key}{suffix} ==", flush=True)
        run = run_meeting_engine if spec.get("kind") == "meeting" else run_engine
        results.append(run(key, spec, references, not arguments.quiet,
                           clip_filter=clip_filter, language=arguments.language))

    if not results:
        raise SystemExit("no engine runtime installed — nothing to compare")

    print()
    print(table(results))
    print("\nLatency varies run to run and with thermal state; error rates are deterministic "
          "for a given clip set.")
    if arguments.words:
        print()
        print(word_table(results))
    if arguments.json:
        with open(arguments.json, "w", encoding="utf-8") as handle:
            json.dump(results, handle, ensure_ascii=False, indent=2)
        print(f"wrote {arguments.json}")


if __name__ == "__main__":
    sys.exit(main())
