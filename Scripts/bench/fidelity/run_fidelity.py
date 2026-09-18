#!/usr/bin/env python3
"""F244 — run the content-fidelity corpus through the app's own AI helpers, one model at a time.

    python3 Scripts/bench/fidelity/run_fidelity.py --smoke
    python3 Scripts/bench/fidelity/run_fidelity.py --corpus Scripts/bench/fidelity/corpus/items.jsonl

Why the app's helpers rather than a harness of our own: the question is what *this app* does to the
user's words, and a reimplementation answers a different question. So the prompts come from
`prompts.json` (which `FidelityPromptFixtureTests.swift` keeps byte-equal to the Swift source), the
request shapes are the ones `LocalSummarizer`, `LocalTranscriptCorrector` and `WarmRefineEngine`
send, and the scripts are the installed ones under
`~/Library/Application Support/WhisperMeet/Runtime/Summarizer/`, opened read-only.

Three text surfaces are covered here: refinement (resident server), correction and summary (one-shot
helpers). The ASR arm in the design is deliberately absent: its clips are the corpus's refinement
lines rendered by `say`, so it cannot be built before the corpus exists.

Records go to `results/<run>/<model>/<surface>.jsonl`, one JSON object per item, carrying the input,
the raw output, the latency, `fallback` and `error`. Every run writes a `header.json` recording the
SHA-256 of the corpus and of `prompts.json`: the corpus is untracked, so those digests are the only
record of what produced a number, and two runs may only be compared when they match.

Resumable: re-running skips items already recorded *without* an error. A failed item is unfinished
work and runs again, because counting it as done would shrink the sample on every retry.

No third-party imports at module scope — the tests and `--dry-run` must work under the plain system
python3 that `Scripts/quality-check.sh` provides. Only the real model calls need the app's venv, and
those run as subprocesses of it, never in this interpreter.
"""

import argparse
import hashlib
import json
import os
import subprocess
import sys
import time

SURFACES = ("refinement", "correction", "summary")
REQUIRED_FIELDS = ("id", "surface", "arm", "lang", "topic", "pair_id", "text")

_HERE = os.path.dirname(os.path.abspath(__file__))
# The scorer's character table decides which prompt arm a Chinese item gets (F244), the way
# report.py loads it: by path, because this directory is not a package.
import importlib.util  # noqa: E402
_score_spec = importlib.util.spec_from_file_location("fidelity_score", os.path.join(_HERE, "score.py"))
score = importlib.util.module_from_spec(_score_spec)
_score_spec.loader.exec_module(score)

DEFAULT_PROMPTS = os.path.join(_HERE, "prompts.json")
DEFAULT_CORPUS = os.path.join(_HERE, "corpus", "items.jsonl")
SMOKE_CORPUS = os.path.join(_HERE, "smoke", "items.jsonl")
DEFAULT_RESULTS = os.path.join(_HERE, "results")

RUNTIME = os.path.expanduser(
    "~/Library/Application Support/WhisperMeet/Runtime/Summarizer"
)


class PromptMismatch(Exception):
    """The fixture and the harness disagree, or a needed language arm is absent."""


class CorpusError(Exception):
    """The corpus cannot be trusted: a missing field, or two items sharing an id."""


# ---------------------------------------------------------------------------
# Prompts
# ---------------------------------------------------------------------------

def load_prompts(path=DEFAULT_PROMPTS):
    with open(path, encoding="utf-8") as handle:
        return json.load(handle)


def correction_user_content(transcript, vocabulary, reference):
    """Mirror of `LocalTranscriptCorrector.userContent`.

    Deliberately a mirror and not an approximation: `verify_correction_layout` compares it against
    the rendered sample the Swift test generated, so a drift here fails loudly instead of quietly
    measuring a differently-shaped request.
    """
    parts = ["Transcript:\n" + transcript]
    if vocabulary:
        parts.append(
            "Correct business vocabulary:\n" + "\n".join("- " + term for term in vocabulary)
        )
    if reference:
        parts.append("Reference document:\n" + reference)
    return "\n\n".join(parts)


def verify_correction_layout(prompts):
    """Fail the run before it starts if this file's assembly has drifted from Swift's."""
    for name, sample in sorted(prompts.get("correctionUserContent", {}).items()):
        built = correction_user_content(
            sample["transcript"], sample.get("vocabulary") or [], sample.get("reference")
        )
        if built != sample["rendered"]:
            raise PromptMismatch(
                "the assembled correction turn no longer matches the fixture's rendered sample "
                f"'{name}'. Either Scripts/bench/fidelity/prompts.json is stale (regenerate it with "
                "FIDELITY_PROMPTS_REGENERATE=1 swift test --filter fixtureMatchesTheLivePrompts) or "
                "correction_user_content here needs the same change LocalTranscriptCorrector got."
            )


def _arm(prompts, group, key, label):
    arms = prompts.get(group) or {}
    if key not in arms:
        raise PromptMismatch(
            f"no {label} prompt for language '{key}'. The fixture carries "
            f"{sorted(arms)} — an item in a language with no arm would be measured against a prompt "
            "the app never sends, so this stops rather than falling back."
        )
    return arms[key]


def refine_system_prompt(prompts, language, text=None):
    """`None` is a real case: refinement can run before language detection settles.

    For Chinese the app reads the script from the dictation itself and names it (F244), so the
    bench does the same with the scorer's own table: a Traditional item is measured against the
    `zh-Hant` arm, a Simplified one against `zh-Hans`, and a mixed or script-neutral one against
    the bare `zh` prompt — exactly the prompt `DictationRefiner` would send for that text."""
    key = language or "none"
    if language == "zh" and text:
        key = score.script_form(text) or "zh"
    return _arm(prompts, "refineSystem", key, "refinement")


def summary_system_prompt(prompts, language):
    return _arm(prompts, "summarySystem", language or "none", "summary")


# ---------------------------------------------------------------------------
# Corpus
# ---------------------------------------------------------------------------

def load_corpus(path):
    items = []
    seen = set()
    with open(path, encoding="utf-8") as handle:
        for number, line in enumerate(handle, start=1):
            line = line.strip()
            if not line:
                continue
            try:
                item = json.loads(line)
            except ValueError as error:
                raise CorpusError(f"{path}:{number} is not JSON: {error}") from error
            missing = [field for field in REQUIRED_FIELDS if not item.get(field)]
            if missing:
                raise CorpusError(
                    f"{path}:{number} (id {item.get('id', '?')}) is missing {', '.join(missing)}"
                )
            if item["surface"] not in SURFACES:
                raise CorpusError(
                    f"{path}:{number} (id {item['id']}) has unknown surface '{item['surface']}'"
                )
            if item["id"] in seen:
                raise CorpusError(
                    f"{path}:{number} repeats id '{item['id']}'. Resume keys on the id, so a "
                    "duplicate makes one item unrunnable and the other uncountable."
                )
            seen.add(item["id"])
            items.append(item)
    return items


def items_for_surface(items, surface, limit=None):
    picked = [item for item in items if item["surface"] == surface]
    return picked[:limit] if limit else picked


# ---------------------------------------------------------------------------
# Results
# ---------------------------------------------------------------------------

def digest(path):
    hasher = hashlib.sha256()
    with open(path, "rb") as handle:
        for block in iter(lambda: handle.read(65536), b""):
            hasher.update(block)
    return hasher.hexdigest()


def run_header(corpus_path, prompts_path, model):
    return {
        "model": model,
        "corpus": os.path.basename(corpus_path),
        "corpus_sha256": digest(corpus_path),
        "prompts_sha256": digest(prompts_path),
    }


def completed_ids(path):
    """Ids already done. A record with an `error` is unfinished work, not a result.

    Tolerant of a truncated final line: a run killed mid-write must not cost every completed item
    before it. The partial record simply runs again.
    """
    done = set()
    if not os.path.exists(path):
        return done
    with open(path, encoding="utf-8") as handle:
        for line in handle:
            line = line.strip()
            if not line:
                continue
            try:
                record = json.loads(line)
            except ValueError:
                continue
            if record.get("id") and not record.get("error"):
                done.add(record["id"])
    return done


class JsonlSink:
    """Append-and-flush per record, so a killed run keeps everything it had finished."""

    def __init__(self, path):
        os.makedirs(os.path.dirname(path), exist_ok=True)
        self._handle = open(path, "a", encoding="utf-8")

    def write(self, record):
        self._handle.write(json.dumps(record, ensure_ascii=False) + "\n")
        self._handle.flush()
        os.fsync(self._handle.fileno())

    def close(self):
        self._handle.close()


# ---------------------------------------------------------------------------
# Running one surface
# ---------------------------------------------------------------------------

def build_request(item, surface, prompts):
    """The request each surface's helper actually expects.

    The field names differ and the difference is silent: `refine_server.py` reads `text`, the
    one-shot helpers read `transcript`, and sending the wrong one yields an empty result with no
    error at all.
    """
    if surface == "refinement":
        return {
            "systemPrompt": refine_system_prompt(prompts, item.get("lang"), item["text"]),
            "text": item["text"],
            "maxTokens": int(item.get("max_tokens") or 256),
        }
    if surface == "correction":
        return {
            "systemPrompt": prompts["correctionSystem"],
            "transcript": correction_user_content(
                item["text"], item.get("vocabulary") or [], item.get("reference")
            ),
        }
    if surface == "summary":
        return {
            "systemPrompt": summary_system_prompt(prompts, item.get("lang")),
            "transcript": item["text"],
        }
    raise CorpusError(f"unknown surface '{surface}'")


def run_surface(items, surface, prompts, invoke, sink, already=frozenset(), clock=None,
                on_progress=None):
    """Drive every item of one surface through `invoke`, recording one line each.

    `invoke(surface, request) -> dict` is injected so the orchestration is testable without a
    model — and so the same code path runs in the tests and in the real run.
    """
    clock = clock or time.perf_counter
    counts = {"completed": 0, "failed": 0, "skipped": 0}
    for item in items:
        if item["id"] in already:
            counts["skipped"] += 1
            continue
        request = build_request(item, surface, prompts)
        started = clock()
        output, error, fallback = None, None, False
        try:
            result = invoke(surface, request)
        except KeyboardInterrupt:
            # Never swallowed: an hour-long run has to stay interruptible.
            raise
        except Exception as failure:  # one bad item must not cost the rest of the run
            error = f"{type(failure).__name__}: {failure}"
        else:
            if isinstance(result, dict) and result.get("error"):
                error = str(result["error"])
            else:
                output = result
                fallback = bool(isinstance(result, dict) and result.get("fallback"))
        elapsed_ms = round((clock() - started) * 1000)
        sink.write({
            "id": item["id"],
            "surface": surface,
            "arm": item["arm"],
            "lang": item["lang"],
            "topic": item["topic"],
            "pair_id": item["pair_id"],
            # The item's protected terms ride along so the Swift guard emitter can apply the app's
            # term guard (F245) to this record without the corpus: in the app the list is the
            # user's vocabulary; here it is what the corpus says must survive.
            "protected_terms": [entry["term"] for entry in item.get("protected_terms") or []],
            "input": request,
            "output": output,
            "latency_ms": elapsed_ms,
            "fallback": fallback,
            "error": error,
        })
        counts["failed" if error else "completed"] += 1
        if on_progress:
            on_progress(item["id"], error, elapsed_ms)
    return counts


# ---------------------------------------------------------------------------
# GPU contention (the F212 lesson: a contended GPU invalidates every latency number)
# ---------------------------------------------------------------------------

def other_mlx_processes(ps_output, own_pid):
    found = []
    for line in ps_output.splitlines():
        fields = line.split()
        if len(fields) < 3:
            continue
        pid = fields[1]
        if pid == str(own_pid):
            continue
        if "mlx" in line.lower():
            found.append(line.strip())
    return found


def warn_on_contention(out=sys.stderr):
    try:
        listing = subprocess.run(
            ["ps", "-axo", "uid,pid,command"], capture_output=True, text=True, timeout=10
        ).stdout
    except Exception:  # a warning that cannot be produced must not stop the run
        return []
    busy = other_mlx_processes(listing, os.getpid())
    for line in busy:
        print(f"[warn] another mlx process is running; latency numbers will be contended: {line}",
              file=out)
    return busy


# ---------------------------------------------------------------------------
# Real invocation against the installed runtime
# ---------------------------------------------------------------------------

def _runtime_paths(python=None, model=None):
    """The app's installed runtime by default; a candidate model and the bench venv when given
    (F244 candidates, fetched by `models.py`). The helper SCRIPTS are always the app's own — the
    point is to measure what the app's prompts and post-processing do with different weights."""
    python = python or os.path.join(RUNTIME, "venv", "bin", "python3")
    model = model or os.path.join(RUNTIME, "model")
    missing = [path for path in (python, model) if not os.path.exists(path)]
    if missing:
        raise SystemExit(
            "the app's summarizer runtime is not installed: missing "
            + ", ".join(missing)
            + "\nInstall it in the app (Settings → AI), or pass --dry-run to check the corpus only."
        )
    return python, model


def one_shot_invoker(script_name, python, model, work_dir, timeout=600):
    """Run `summarize_local.py` / `correct_local.py` the way the app does: a JSON file in, a JSON
    file out, stdout/stderr drained and kept out of the result (F24)."""
    script = os.path.join(RUNTIME, script_name)

    def invoke(surface, request):
        request_path = os.path.join(work_dir, f"{surface}-in.json")
        output_path = os.path.join(work_dir, f"{surface}-out.json")
        with open(request_path, "w", encoding="utf-8") as handle:
            json.dump(request, handle, ensure_ascii=False)
        if os.path.exists(output_path):
            os.remove(output_path)
        completed = subprocess.run(
            [python, script, "--model", model, "--input", request_path, "--output", output_path],
            capture_output=True, text=True, timeout=timeout,
        )
        if not os.path.exists(output_path):
            tail = (completed.stderr or completed.stdout or "").strip().splitlines()[-3:]
            raise RuntimeError(
                f"{script_name} exited {completed.returncode} and wrote no output: {' / '.join(tail)}"
            )
        with open(output_path, encoding="utf-8") as handle:
            return json.load(handle)

    return invoke


class RefineServer:
    """`refine_server.py` held resident, the way `WarmRefineEngine` holds it.

    One process for the whole surface: the point of the resident server is that the prompt cache
    survives between requests, and re-spawning per item would measure a cold path the app never
    takes.
    """

    def __init__(self, python, model, timeout=300):
        self._process = subprocess.Popen(
            [python, os.path.join(RUNTIME, "refine_server.py"), "--model", model],
            stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
            text=True, bufsize=1,
        )
        self._timeout = timeout
        handshake = self._process.stdout.readline()
        if not handshake:
            raise RuntimeError("refine_server.py exited before reporting ready")
        state = json.loads(handshake)
        if not state.get("ready"):
            raise RuntimeError(f"refine_server.py did not become ready: {state}")

    def invoke(self, surface, request):
        self._process.stdin.write(json.dumps(request, ensure_ascii=False) + "\n")
        self._process.stdin.flush()
        line = self._process.stdout.readline()
        if not line:
            raise RuntimeError("refine_server.py closed its output mid-run")
        return json.loads(line)

    def close(self):
        try:
            self._process.stdin.close()
            self._process.wait(timeout=30)
        except Exception:
            self._process.kill()


# ---------------------------------------------------------------------------
# CLI
# ---------------------------------------------------------------------------

def parse_args(argv=None):
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--corpus", default=None,
                        help=f"default: {DEFAULT_CORPUS} (or the tracked smoke corpus with --smoke)")
    parser.add_argument("--prompts", default=DEFAULT_PROMPTS)
    parser.add_argument("--results", default=DEFAULT_RESULTS)
    parser.add_argument("--model-name", default="installed-qwen3-8b-4bit",
                        help="label for the results directory; the weights come from the app unless --model-dir is given")
    parser.add_argument("--model-dir", default=None,
                        help="a candidate model directory (see models.py); the app's helper scripts run over it")
    parser.add_argument("--python", default=None,
                        help="the interpreter to run the helpers with; default: the app's runtime venv. "
                             "Candidates need the bench venv (models.py venv)")
    parser.add_argument("--surfaces", default=",".join(SURFACES))
    parser.add_argument("--limit", type=int, default=None, help="items per surface")
    parser.add_argument("--smoke", action="store_true",
                        help="two items per surface from the tracked neutral corpus")
    parser.add_argument("--dry-run", action="store_true",
                        help="validate corpus and prompts, call no model")
    parser.add_argument("--run-id", default=None, help="results subdirectory; default: smoke or 'run'")
    return parser.parse_args(argv)


def main(argv=None):
    args = parse_args(argv)
    corpus_path = args.corpus or (SMOKE_CORPUS if args.smoke else DEFAULT_CORPUS)
    if not os.path.exists(corpus_path):
        raise SystemExit(
            f"no corpus at {corpus_path}.\nThe sensitive corpus is local-only and still blocked on "
            "the user's terminology review of corpus/APPENDIX.md; --smoke runs the tracked neutral "
            "one instead."
        )

    prompts = load_prompts(args.prompts)
    verify_correction_layout(prompts)
    items = load_corpus(corpus_path)
    limit = 2 if args.smoke and args.limit is None else args.limit
    surfaces = [name for name in args.surfaces.split(",") if name]
    for name in surfaces:
        if name not in SURFACES:
            raise SystemExit(f"unknown surface '{name}'; known: {', '.join(SURFACES)}")

    header = run_header(corpus_path, args.prompts, args.model_name)
    if args.model_dir:
        header["model_dir"] = os.path.abspath(args.model_dir)
    plan = {name: items_for_surface(items, name, limit) for name in surfaces}
    print(f"corpus {header['corpus']} ({header['corpus_sha256'][:12]}…), "
          f"prompts {header['prompts_sha256'][:12]}…")
    for name in surfaces:
        print(f"  {name}: {len(plan[name])} item(s)")

    if args.dry_run:
        print("dry run: corpus and prompts validated, no model called.")
        return 0

    warn_on_contention()
    python, model = _runtime_paths(args.python, args.model_dir)
    run_id = args.run_id or ("smoke" if args.smoke else "run")
    out_dir = os.path.join(args.results, run_id, args.model_name)
    os.makedirs(out_dir, exist_ok=True)
    with open(os.path.join(out_dir, "header.json"), "w", encoding="utf-8") as handle:
        json.dump(header, handle, indent=2, sort_keys=True)

    work_dir = os.path.join(out_dir, "work")
    os.makedirs(work_dir, exist_ok=True)
    totals = {"completed": 0, "failed": 0, "skipped": 0}
    for name in surfaces:
        if not plan[name]:
            continue
        path = os.path.join(out_dir, f"{name}.jsonl")
        sink = JsonlSink(path)
        server = None
        try:
            if name == "refinement":
                server = RefineServer(python, model)
                invoke = server.invoke
            else:
                script = "summarize_local.py" if name == "summary" else "correct_local.py"
                invoke = one_shot_invoker(script, python, model, work_dir)
            counts = run_surface(
                plan[name], name, prompts, invoke, sink,
                already=completed_ids(path),
                on_progress=lambda item_id, error, ms: print(
                    f"  [{name}] {item_id}: {'ERROR ' + error if error else str(ms) + ' ms'}"
                ),
            )
        finally:
            sink.close()
            if server:
                server.close()
        for key in totals:
            totals[key] += counts[key]
        print(f"  {name}: {counts}")

    print(f"wrote {out_dir}")
    print(f"totals: {totals}")
    return 1 if totals["failed"] else 0


if __name__ == "__main__":
    sys.exit(main())
