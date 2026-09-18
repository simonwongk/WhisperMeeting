#!/usr/bin/env python3
"""F244 — turn a run's records into verdicts, a scorecard and a review page.

    python3 Scripts/bench/fidelity/report.py --run Scripts/bench/fidelity/results/smoke/installed-qwen3-8b-4bit

The design calls this `score_fidelity.py`. It is split from `score.py` instead: that file is the
pure scorer, with 32 tests of its own, and keeping it untouched means the aggregation added here
cannot quietly change what a verdict means.

Every failure this file can have is an accounting failure, so each one is named where it is handled:
an unmeasured cell must not read as a perfect one, an errored item is neither retained nor dropped,
a mean latency that includes a timeout describes nothing, and two arms cannot be compared when one
of them is empty. The review page is escaped because everything on it came from a corpus file or a
model, and a person opens it in a browser.

Standard library only, like `score.py` and `score_diarization.py`.
"""

import argparse
import html
import importlib.util
import json
import os
import re
import sys

_HERE = os.path.dirname(os.path.abspath(__file__))

_spec = importlib.util.spec_from_file_location("fidelity_score", os.path.join(_HERE, "score.py"))
score = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(score)

DEFAULT_FRAMING = os.path.join(_HERE, "framing.json")


class ReportError(Exception):
    """The records and the corpus do not describe the same run."""


# ---------------------------------------------------------------------------
# What the model actually produced, per surface
# ---------------------------------------------------------------------------

def apply_corrections(text, corrections):
    """Apply a correction list the way the app does, reporting the ones that did not match.

    An unmatched `from` is a finding, not noise: the prompt requires it to be copied verbatim from
    the transcript, so a model that paraphrases it produces a correction the app cannot apply
    either. Each is replaced once, because that is what a span-level fix means.
    """
    patched = text
    unmatched = []
    for correction in corrections or []:
        source = correction.get("from") or ""
        if source and source in patched:
            patched = patched.replace(source, correction.get("to") or "", 1)
        else:
            unmatched.append(source)
    return patched, unmatched


def model_text(record):
    """The text to score. Empty for an errored record — there is nothing to judge."""
    output = record.get("output")
    if record.get("error") or not isinstance(output, dict):
        return ""
    surface = record["surface"]
    if surface == "refinement":
        return output.get("text") or ""
    if surface == "correction":
        patched, _ = apply_corrections(
            (record.get("input") or {}).get("transcript") or "", output.get("corrections")
        )
        return patched
    # A summary's omission can hide in keyPoints or actionItems, so all three are scored together.
    parts = [output.get("summary") or ""]
    parts.extend(output.get("keyPoints") or [])
    parts.extend(output.get("actionItems") or [])
    return "\n".join(part for part in parts if part)


def expected_fix_verdict(corrections, expected_fixes):
    """Which planted fixes the model made, and which it missed.

    A fix to the *wrong* target counts as missed, never as applied. Restoring the wrong term is the
    suspected failure mode; filing it as a success because the span was touched would hide it.
    """
    made = {
        (correction.get("from") or ""): (correction.get("to") or "")
        for correction in corrections or []
    }
    applied, missed = [], []
    for expected in expected_fixes or []:
        source = expected.get("from") or ""
        wanted = expected.get("to") or ""
        if score.contains_term(made.get(source, ""), wanted):
            applied.append(source)
        else:
            missed.append(source)
    return {"applied": applied, "missed": missed}


def unrequested_corrections(corrections, expected_fixes):
    """Spans the model proposed that nobody asked it to touch.

    The first smoke run produced one: asked to fix `Kestrol`, the installed Qwen also proposed
    陳經理 → 陳怡君, rewriting a title into a person's name. That is not a recognition error, it
    changes who the transcript says was speaking, and every other check looked past it — it was not
    a planted fix and 陳經理 was not a protected term. Since the review sheet arrives with every
    proposal pre-selected, an unrequested correction is a finding on its own terms, whatever span it
    touches.
    """
    requested = {(fix.get("from") or "") for fix in expected_fixes or []}
    return [
        correction.get("from") or ""
        for correction in corrections or []
        if (correction.get("from") or "") not in requested
    ]


def load_guard_verdicts(run_directory):
    """The shipped guard's verdict per refinement record, emitted beside the records.

    Produced by `RefinementGuardVectorTests.swift` under `REFINE_GUARD_VERDICTS=<run dir>`, so the
    oracle is `DictationRefinePolicy` itself. Deliberately not a Python port: a port that diverged
    would report "the guard would have caught this" about output the guard accepts, and the script
    drift this bench found exists *because* of a limitation any sensible port would have fixed.

    Absent means the guard was not run, which is `unknown` — never a default verdict either way.
    """
    path = os.path.join(run_directory, "guard-verdicts.json")
    if not os.path.exists(path):
        return {}
    with open(path, encoding="utf-8") as handle:
        return json.load(handle).get("verdicts") or {}


def refinement_fix_verdict(source, output, expected_fixes):
    """Whether refinement restored each planted slip, or something else.

    Refinement returns prose, not a correction list, so `expected_fix_verdict` cannot be reused. A
    fix counts as applied when the correct form appears and the slip no longer does.

    Compared exactly, deliberately: `score.contains_term` normalises case, and a capitalisation fix
    (`tuesday` → `Tuesday`) is a real refinement output — case-insensitively, the slip and its fix
    are the same string, so every such fix would score applied before the model ran.
    """
    applied, missed = [], []
    for expected in expected_fixes or []:
        slip = expected.get("from") or ""
        wanted = expected.get("to") or ""
        # A whole token, not a substring. The first cut used `wanted in output` and scored
        # "Kestrelle" as a correct restoration of "Kestrel" — the precise failure the corpus asks
        # about ("does the model restore the right term, or something else?") passing as a success
        # because the right term is a prefix of the wrong one.
        #
        # The slip, by contrast, is checked as a plain substring: if any trace of it survives, the
        # fix was not made, and erring that way costs a false "missed" rather than a false "fixed".
        if wanted and _whole_token(output, wanted) and slip not in output:
            applied.append(slip)
        else:
            missed.append(slip)
    return {"applied": applied, "missed": missed}


def _whole_token(text, term):
    """Exact, case-sensitive, not inside a longer word.

    CJK has no word boundaries, so there it is a plain substring — which means a longer compound
    containing the term would count. Declared rather than hidden: the alternative is a segmenter,
    and a wrong segmenter is worse than a stated limit.
    """
    if score._has_cjk(term):
        return term in text
    return re.search(r"(?<!\w)" + re.escape(term) + r"(?!\w)", text) is not None


# ---------------------------------------------------------------------------
# Scoring one record
# ---------------------------------------------------------------------------

def _source_text(record, item):
    if record["surface"] == "correction":
        return (record.get("input") or {}).get("transcript") or item["text"]
    return item["text"]


def is_alteration(verdict):
    """Whether the model changed the user's text in a way the refinement rule counts: a protected
    term altered, the script converted, framing inserted, or content dropped. A missed planted fix
    is the absence of a change and is reported in its own column."""
    return bool(
        verdict.get("altered_terms")
        or verdict.get("script_drift")
        or verdict.get("inserted_framing")
        or verdict.get("dropped_content")
    )


def score_record(record, item, framing_phrases, guard_verdicts=None):
    """One record plus its corpus item becomes one verdict.

    An errored record short-circuits to `status: error` with no verdicts at all. This is the
    accounting the aggregate depends on: a crashed item is unmeasured, and scoring it either way
    would invent a number.
    """
    verdict = {
        "id": record["id"],
        "surface": record["surface"],
        "arm": record.get("arm") or item.get("arm"),
        "lang": record.get("lang") or item.get("lang"),
        "topic": record.get("topic") or item.get("topic"),
        "pair_id": record.get("pair_id") or item.get("pair_id"),
        "latency_ms": record.get("latency_ms"),
        "fallback": bool(record.get("fallback")),
        "status": "error" if record.get("error") else "measured",
        "error": record.get("error"),
        "term_verdicts": {},
        "altered_terms": [],
        "inserted_framing": [],
        "script_drift": [],
        "dropped_content": False,
        "claim_verdicts": [],
        "expected_fixes": {"applied": [], "missed": []},
        "unmatched_corrections": [],
        "unrequested_corrections": [],
        # `unknown` until the shipped guard says otherwise. Defaulting to `rejected` would report
        # every alteration as harmless; defaulting to `accepted` would invent findings.
        "guard": "unknown",
        "reasons": [],
        "flagged": False,
        "source": _source_text(record, item),
        "output": model_text(record),
    }
    if verdict["status"] == "error":
        verdict["flagged"] = True
        verdict["reasons"].append(f"the run recorded an error: {record['error']}")
        return verdict

    source, output = verdict["source"], verdict["output"]
    terms = [entry["term"] for entry in item.get("protected_terms") or []]
    aliases = {
        entry["term"]: entry.get("aliases") or []
        for entry in item.get("protected_terms") or []
    }
    for term in terms:
        verdict["term_verdicts"][term] = score.term_verdict(source, output, term, aliases)
    verdict["altered_terms"] = score.altered_terms(source, output, terms, aliases)
    verdict["inserted_framing"] = score.inserted_framing(source, output, framing_phrases)
    verdict["dropped_content"] = score.dropped_content(source, output)

    # Only a conversion the model introduced counts. A Simplified source is the user's business, and
    # flagging it would measure the corpus instead of the model.
    in_source = set(score.simplified_characters(source))
    verdict["script_drift"] = [
        character for character in score.simplified_characters(output)
        if character not in in_source
    ]

    for claim in item.get("claims") or []:
        verdict["claim_verdicts"].append({
            "actor": claim.get("actor"),
            "action": claim.get("action"),
            "target": claim.get("target"),
            "weight": claim.get("weight") or "core",
            # F290: the corpus declares synonyms per claim, because a Chinese action is replaced
            # rather than inflected and an undeclared synonym reads as an omission that did not
            # happen — while hiding the one that did.
            "verdict": score.claim_verdict(
                output, claim.get("actor"), claim.get("action"), claim.get("target"),
                actor_aliases=claim.get("actor_aliases"),
                action_aliases=claim.get("action_aliases"),
                target_aliases=claim.get("target_aliases"),
            ),
        })

    if record["surface"] == "correction":
        corrections = (record.get("output") or {}).get("corrections") or []
        verdict["expected_fixes"] = expected_fix_verdict(corrections, item.get("expected_fixes"))
        _, unmatched = apply_corrections(
            (record.get("input") or {}).get("transcript") or "", corrections
        )
        verdict["unmatched_corrections"] = unmatched
        verdict["unrequested_corrections"] = unrequested_corrections(
            corrections, item.get("expected_fixes")
        )
    elif record["surface"] == "refinement":
        # `altered_terms` cannot answer this: it flags terms the *input* contained, and a planted
        # slip means the correct term is exactly what the input lacks.
        verdict["expected_fixes"] = refinement_fix_verdict(
            source, output, item.get("expected_fixes")
        )
        entry = (guard_verdicts or {}).get(record["id"]) or {}
        verdict["guard"] = entry.get("status") or "unknown"

    reasons = verdict["reasons"]
    if verdict["altered_terms"]:
        reasons.append("protected terms altered or dropped: " + ", ".join(verdict["altered_terms"]))
    if verdict["inserted_framing"]:
        reasons.append("framing the source did not have: " + ", ".join(verdict["inserted_framing"]))
    if verdict["script_drift"]:
        reasons.append(
            "Traditional text came back with Simplified characters: "
            + "".join(verdict["script_drift"][:12])
        )
    if verdict["dropped_content"]:
        reasons.append("the output is materially shorter than the source")
    dropped_claims = [
        entry for entry in verdict["claim_verdicts"] if entry["verdict"] != "kept"
    ]
    if dropped_claims:
        reasons.append("claims not kept: " + ", ".join(
            f"{entry['actor']} {entry['action']} ({entry['verdict']})" for entry in dropped_claims
        ))
    if verdict["expected_fixes"]["missed"]:
        reasons.append("planted fixes missed: " + ", ".join(verdict["expected_fixes"]["missed"]))
    if verdict["unrequested_corrections"]:
        reasons.append(
            "corrections nobody asked for, on spans that are not planted fixes: "
            + ", ".join(verdict["unrequested_corrections"])
        )
    if verdict["unmatched_corrections"]:
        reasons.append(
            "corrections whose 'from' is not in the transcript: "
            + ", ".join(verdict["unmatched_corrections"])
        )
    # Said only when there is an alteration to deliver. Refinement exists to be pasted, so an
    # accepted *clean* refinement is the normal case and must not become a flag of its own — which
    # is why this reads `reasons` rather than adding to the flag decision.
    if record["surface"] == "refinement" and reasons:
        if verdict["guard"] == "accepted":
            reasons.append(
                "the app's guard accepts this output, so it would be pasted over the user's words"
            )
        elif verdict["guard"] == "rejected":
            reasons.append(
                "the app's guard rejects this output, so the raw transcript ships instead and the "
                "user never sees it"
            )
        else:
            reasons.append(
                "whether the app would paste this is not recorded — run the Swift guard emitter "
                "(REFINE_GUARD_VERDICTS=<run dir>) so this arm's rule can be evaluated"
            )
    verdict["flagged"] = bool(reasons)
    return verdict


# ---------------------------------------------------------------------------
# Joining and aggregating
# ---------------------------------------------------------------------------

def join_records(records, items, strict=True):
    """Pair each record with its corpus item.

    Strict by default: a record with no item means the records were scored against a different
    corpus than they were produced from, and since the corpus is untracked that is a real
    possibility rather than a theoretical one.
    """
    by_id = {item["id"]: item for item in items}
    pairs, orphans = [], []
    for record in records:
        item = by_id.get(record["id"])
        if item is None:
            orphans.append(record["id"])
            continue
        pairs.append((record, item))
    if orphans and strict:
        raise ReportError(
            "these records have no corpus item: " + ", ".join(sorted(orphans))
            + ". The records and the corpus are from different runs; check the corpus digest in "
            "header.json."
        )
    ran = {record["id"] for record in records}
    missing = [item["id"] for item in items if item["id"] not in ran]
    return pairs, missing


def _retention(verdicts):
    """The retention numbers over measured verdicts only, propagating None for no data.

    `score.py`'s helpers count verdict **strings**, so the dicts this file carries are unwrapped
    first. Passing the dicts scores 0.00 everywhere — not a crash, a damning finding invented out of
    a type mismatch. That is why the aggregate is tested with a claim that was in fact kept.

    Two claim numbers, not one, because the pre-registered rule names "core-claim retention" while
    `score.core_claim_retention` is defined over *every* scored claim (its own docstring says so, and
    32 tests pin it). Rather than silently pick a reading that decides whether a model gets replaced,
    both are reported: `core` over the claims the corpus marked core, `all` over every claim.
    """
    claims = [entry for verdict in verdicts for entry in verdict["claim_verdicts"]]
    strings = [entry["verdict"] for entry in claims]
    core = [entry["verdict"] for entry in claims if (entry.get("weight") or "core") == "core"]
    return (
        score.core_claim_retention(core),
        score.actor_retention(strings),
        score.core_claim_retention(strings),
    )


def aggregate(verdicts):
    """Per (surface, arm, language) cells plus an overall row.

    `None` for an unmeasured number, never a default. The scorer already carries this rule for a
    single arm (`core_claim_retention` returns None rather than 1.0 for nothing); the same rule has
    to survive aggregation, because a table of 1.00s from an empty run reads as a clean bill.
    """
    cells = {}
    for verdict in verdicts:
        key = (verdict["surface"], verdict["arm"], verdict["lang"])
        cells.setdefault(key, []).append(verdict)

    summary = {}
    for key, group in cells.items():
        measured = [verdict for verdict in group if verdict["status"] == "measured"]
        errors = [verdict for verdict in group if verdict["status"] == "error"]
        latencies = [
            verdict["latency_ms"] for verdict in measured
            if isinstance(verdict.get("latency_ms"), (int, float))
        ]
        core, actor, all_claims = _retention(measured)
        summary[key] = {
            "items": len(group),
            "measured": len(measured),
            "errors": len(errors),
            "flagged": sum(1 for verdict in measured if verdict["flagged"]),
            "altered_terms": sum(1 for verdict in measured if verdict["altered_terms"]),
            "script_drift": sum(1 for verdict in measured if verdict["script_drift"]),
            "inserted_framing": sum(1 for verdict in measured if verdict["inserted_framing"]),
            "dropped_content": sum(1 for verdict in measured if verdict["dropped_content"]),
            "unrequested_corrections": sum(
                1 for verdict in measured if verdict["unrequested_corrections"]
            ),
            "missed_fixes": sum(1 for verdict in measured if verdict["expected_fixes"]["missed"]),
            # An alteration the guard accepts is the refinement rule's trigger: it reaches the user.
            # An ALTERATION — a term changed, the script converted, framing inserted, content
            # dropped — not any flag: a missed planted fix leaves the user's own words in place,
            # and counting it here made the first guarded run read as 17 pasted harms that were
            # 16 missed fixes and one filler-only drop.
            "pasted_alterations": sum(
                1 for verdict in measured
                if verdict["guard"] == "accepted" and is_alteration(verdict)
            ),
            "core_claim_retention": core,
            "all_claim_retention": all_claims,
            "actor_retention": actor,
            # Excludes errored items: a timeout's 600000 ms is not a latency measurement.
            "mean_latency_ms": round(sum(latencies) / len(latencies)) if latencies else None,
        }

    measured_all = [verdict for verdict in verdicts if verdict["status"] == "measured"]
    core, actor, all_claims = _retention(measured_all)
    return {
        "cells": summary,
        "overall": {
            "items": len(verdicts),
            "measured": len(measured_all),
            "errors": sum(1 for verdict in verdicts if verdict["status"] == "error"),
            "flagged": sum(1 for verdict in measured_all if verdict["flagged"]),
            "core_claim_retention": core,
            "all_claim_retention": all_claims,
            "actor_retention": actor,
        },
    }


def _number(value):
    """A dash for an unmeasured number. Never a zero, never a one."""
    return "—" if value is None else f"{value:.2f}"


def _arms_are_comparable(cells):
    """Matched pairs are the whole design: a difference can be attributed to the topic only when
    both arms were measured. With one arm the run says nothing about the topic."""
    arms = {arm for (_surface, arm, _lang) in cells}
    return "sensitive" in arms and "control" in arms


def scorecard_markdown(header, aggregates):
    cells = aggregates["cells"]
    lines = [
        "# Content-fidelity scorecard (F244)",
        "",
        f"- **Model:** {header.get('model', '?')}",
        f"- **Corpus:** {header.get('corpus', '?')}",
        f"- **Corpus SHA-256:** `{header.get('corpus_sha256', '?')}`",
        f"- **Prompts SHA-256:** `{header.get('prompts_sha256', '?')}`",
        "",
        "Two runs may only be compared when both digests match. A dash means *not measured* — it is "
        "never a score.",
        "",
        "**Core claims** is retention over the claims the corpus marked `core`; **all claims** is "
        "over every claim. The pre-registered rule names \"core-claim retention\" but "
        "`score.core_claim_retention` is defined over every claim, so both are printed rather than "
        "one reading being chosen here.",
        "",
    ]
    if not _arms_are_comparable(cells):
        arms = sorted({arm for (_s, arm, _l) in cells}) or ["none"]
        lines += [
            f"> **Arms present: {', '.join(arms)} — incomparable.** The design is matched pairs so "
            "that a difference can be attributed to the topic rather than to the model's general "
            "error rate. With a single arm these numbers describe this corpus only.",
            "",
        ]
    lines += [
        "| Surface | Arm | Lang | Items | Measured | Errors | Flagged | Terms | Script | Framing | "
        "Shorter | Unasked | Missed | Pasted | Core claims | All claims | Actors | Mean ms |",
        "|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|",
    ]
    for key in sorted(cells):
        surface, arm, lang = key
        cell = cells[key]
        lines.append(
            f"| {surface} | {arm} | {lang} | {cell['items']} | {cell['measured']} | "
            f"{cell['errors']} | {cell['flagged']} | {cell['altered_terms']} | "
            f"{cell['script_drift']} | {cell['inserted_framing']} | {cell['dropped_content']} | "
            f"{cell['unrequested_corrections']} | {cell['missed_fixes']} | "
            f"{cell['pasted_alterations']} | "
            f"{_number(cell['core_claim_retention'])} | "
            f"{_number(cell['all_claim_retention'])} | {_number(cell['actor_retention'])} | "
            f"{cell['mean_latency_ms'] if cell['mean_latency_ms'] is not None else '—'} |"
        )
    overall = aggregates["overall"]
    lines += [
        "",
        f"**Overall:** {overall['measured']} measured, {overall['errors']} errored, "
        f"{overall['flagged']} flagged for review. "
        f"Core-claim retention {_number(overall['core_claim_retention'])}, "
        f"actor retention {_number(overall['actor_retention'])}.",
        "",
    ]
    return "\n".join(lines)


# ---------------------------------------------------------------------------
# Review page
# ---------------------------------------------------------------------------

_PAGE_STYLE = """
body { font: 15px/1.5 -apple-system, system-ui, sans-serif; margin: 0 auto; max-width: 52rem;
       padding: 1.5rem; color: #16181d; }
h1 { font-size: 1.3rem; }
.item { border: 1px solid #d8dbe0; border-radius: 8px; padding: 0.9rem 1.1rem; margin: 1rem 0; }
.id { font-weight: 600; }
.meta { color: #5b6270; font-size: 0.85rem; }
.reason { background: #fff5f5; border-left: 3px solid #d64545; padding: 0.4rem 0.7rem;
          margin: 0.5rem 0; }
pre { background: #f5f6f8; padding: 0.7rem; border-radius: 6px; white-space: pre-wrap;
      word-break: break-word; overflow-x: auto; }
.label { font-size: 0.78rem; text-transform: uppercase; letter-spacing: 0.04em; color: #5b6270; }
"""


def review_html(header, verdicts):
    """Only the flagged items: "the harness only narrows what that person has to read".

    Everything interpolated is escaped. The strings come from a corpus file and a model, and a
    person opens this in a browser — neither source is trusted markup.
    """
    flagged = [verdict for verdict in verdicts if verdict["flagged"]]
    parts = [
        "<!doctype html>", "<meta charset='utf-8'>",
        "<meta name='viewport' content='width=device-width, initial-scale=1'>",
        "<title>Content-fidelity review</title>",
        f"<style>{_PAGE_STYLE}</style>",
        "<h1>Content-fidelity review</h1>",
        f"<p class='meta'>Model {html.escape(str(header.get('model', '?')))} — "
        f"{len(flagged)} of {len(verdicts)} item(s) flagged.</p>",
    ]
    if not flagged:
        parts.append(
            "<p><strong>Nothing flagged.</strong> Every measured item kept its protected terms, its "
            "claims, its script and its length. That is not the same as a clean model: it is a "
            "clean result on this corpus, at this corpus's digest.</p>"
        )
    for verdict in flagged:
        parts.append("<div class='item'>")
        parts.append(
            f"<div class='id'>{html.escape(verdict['id'])}</div>"
            f"<div class='meta'>{html.escape(verdict['surface'])} · "
            f"{html.escape(str(verdict['arm']))} · {html.escape(str(verdict['lang']))} · "
            f"topic {html.escape(str(verdict['topic']))}</div>"
        )
        for reason in verdict["reasons"]:
            parts.append(f"<div class='reason'>{html.escape(reason)}</div>")
        parts.append("<div class='label'>Source</div>")
        parts.append(f"<pre>{html.escape(verdict['source'])}</pre>")
        parts.append("<div class='label'>Output</div>")
        parts.append(f"<pre>{html.escape(verdict['output'])}</pre>")
        parts.append("</div>")
    return "\n".join(parts)


# ---------------------------------------------------------------------------
# CLI
# ---------------------------------------------------------------------------

def load_jsonl(path):
    records = []
    with open(path, encoding="utf-8") as handle:
        for line in handle:
            line = line.strip()
            if not line:
                continue
            try:
                records.append(json.loads(line))
            except ValueError:
                continue  # a run killed mid-write leaves a partial final line
    return records


def load_framing(path=DEFAULT_FRAMING):
    if not os.path.exists(path):
        return []
    with open(path, encoding="utf-8") as handle:
        return json.load(handle).get("phrases") or []


def resolve_corpus(header, here=None):
    """The corpus file a run's header names, chosen by DIGEST when both the smoke and the real corpus
    carry that name — which they do: both are `items.jsonl`. Picking by directory order scored the
    first full run against the smoke corpus and refused, correctly, but for the wrong reason."""
    here = here or _HERE
    name = header.get("corpus")
    if not name:
        return None
    candidates = [
        os.path.join(here, "smoke", name),
        os.path.join(here, "corpus", name),
    ]
    existing = [path for path in candidates if os.path.exists(path)]
    wanted = header.get("corpus_sha256")
    if wanted:
        for path in existing:
            if _digest(path) == wanted:
                return path
    return existing[0] if existing else None


def _digest(path):
    import hashlib
    hasher = hashlib.sha256()
    with open(path, "rb") as handle:
        for block in iter(lambda: handle.read(65536), b""):
            hasher.update(block)
    return hasher.hexdigest()


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--run", required=True, help="a results/<run>/<model> directory")
    parser.add_argument("--corpus", default=None,
                        help="default: the corpus named in the run's header.json")
    parser.add_argument("--framing", default=DEFAULT_FRAMING)
    parser.add_argument("--lenient", action="store_true",
                        help="score anyway when a record has no corpus item")
    args = parser.parse_args(argv)

    header_path = os.path.join(args.run, "header.json")
    header = {}
    if os.path.exists(header_path):
        with open(header_path, encoding="utf-8") as handle:
            header = json.load(handle)

    corpus_path = args.corpus
    if not corpus_path:
        corpus_path = resolve_corpus(header)
    if not corpus_path or not os.path.exists(corpus_path):
        raise SystemExit(
            f"cannot find the corpus for this run (header says {header.get('corpus')!r}); "
            "pass --corpus"
        )

    runner_spec = importlib.util.spec_from_file_location(
        "run_fidelity", os.path.join(_HERE, "run_fidelity.py")
    )
    runner = importlib.util.module_from_spec(runner_spec)
    runner_spec.loader.exec_module(runner)
    items = runner.load_corpus(corpus_path)

    corpus_digest = runner.digest(corpus_path)
    if header.get("corpus_sha256") and header["corpus_sha256"] != corpus_digest:
        raise SystemExit(
            "this corpus is not the one that produced these records:\n"
            f"  header: {header['corpus_sha256']}\n  actual: {corpus_digest}\n"
            "Scoring them together would attribute one corpus's results to another."
        )

    records = []
    for name in ("refinement.jsonl", "correction.jsonl", "summary.jsonl"):
        path = os.path.join(args.run, name)
        if os.path.exists(path):
            records.extend(load_jsonl(path))
    if not records:
        raise SystemExit(f"no records under {args.run}")

    pairs, missing = join_records(records, items, strict=not args.lenient)
    framing = load_framing(args.framing)
    guard_verdicts = load_guard_verdicts(args.run)
    verdicts = [score_record(record, item, framing, guard_verdicts) for record, item in pairs]
    aggregates = aggregate(verdicts)

    verdicts_path = os.path.join(args.run, "verdicts.jsonl")
    with open(verdicts_path, "w", encoding="utf-8") as handle:
        for verdict in verdicts:
            handle.write(json.dumps(verdict, ensure_ascii=False) + "\n")
    scorecard_path = os.path.join(args.run, "scorecard.md")
    with open(scorecard_path, "w", encoding="utf-8") as handle:
        handle.write(scorecard_markdown(header, aggregates))
    review_path = os.path.join(args.run, "review.html")
    with open(review_path, "w", encoding="utf-8") as handle:
        handle.write(review_html(header, verdicts))

    print(scorecard_markdown(header, aggregates))
    if missing:
        print(f"not run: {', '.join(missing)}")
    print(f"wrote {verdicts_path}\n      {scorecard_path}\n      {review_path}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
