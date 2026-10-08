#!/usr/bin/env python3
"""The Summary table of `benchmark.py`'s results.md (F438).

Its own stdlib-only module for the reason `qwen_meeting_engine.py` is one: `benchmark.py` imports
whisper, mlx_whisper, jiwer and opencc at module scope, none of which the system python3 that
`Scripts/quality-check.sh` runs has, so nothing inside it can be covered by a gated test.

A row is what `benchmark.py` records per clip: `clip`, `lang`, `sec`, `det`, `metric`, `val`,
`hyp`. An errored clip has `sec == -1` and `val == nan`.

**An errored clip counts against its engine.** The Summary used to average over the clips that
survived, with no count, so an engine that timed out on the two hard Chinese clips reported the easy
one's CER as its 中文 number and left the slow clips out of its seconds — and the Summary is the
table that gets quoted when an engine default is chosen. An errored clip now scores 1.0, a total
miss: what an empty transcript scores, and the rule `qwen_meeting_engine` already applies to a clip
it could not transcribe. It has no latency, so the seconds say how many clips they cover instead.
"""

#: The score of a clip the engine raised on: the WER/CER of an empty transcript.
TOTAL_MISS = 1.0


def is_error(row):
    """Whether the engine raised on this clip. `val != val` is NaN, which is also how a row read
    back from results.json (`BENCH_APPEND=1`) carries it."""
    val = row.get("val")
    return row.get("sec", -1) < 0 or val != val


def accuracy_cell(rows, lang):
    """Mean WER/CER over every clip of `lang`, an errored one scored as a total miss."""
    picked = [row for row in rows if row["lang"] == lang]
    if not picked:
        return "—"
    errors = sum(1 for row in picked if is_error(row))
    values = [TOTAL_MISS if is_error(row) else row["val"] for row in picked]
    text = f"{sum(values) / len(values):.3f}"
    if errors:
        text += f" ({errors} of {len(picked)} errored, scored {TOTAL_MISS:.1f})"
    return text


def latency_cell(rows):
    """Mean seconds over the clips that ran, saying how many that is when it is not all of them."""
    if not rows:
        return "—"
    ran = [row["sec"] for row in rows if not is_error(row)]
    if not ran:
        return f"— (0 of {len(rows)} ran)"
    text = f"{sum(ran) / len(ran):.2f}"
    if len(ran) < len(rows):
        text += f" ({len(ran)} of {len(rows)} ran)"
    return text


def errored_clips(results):
    """(engine, clip) for every clip an engine raised on. `benchmark.py` exits non-zero when this is
    not empty, so a run that lost clips cannot pass for a complete one."""
    return [(name, row["clip"]) for name in results for row in results[name] if is_error(row)]


def summary_lines(results):
    """The Summary heading and table, one row per engine, in `results`' order."""
    lines = ["## Summary\n",
             "| engine | avg sec | EN WER | 中文 CER | code-switch CER |",
             "|---|---|---|---|---|"]
    for name in results:
        rows = results[name]
        lines.append(f"| {name} | {latency_cell(rows)} | {accuracy_cell(rows, 'en')} | "
                     f"{accuracy_cell(rows, 'zh')} | {accuracy_cell(rows, 'cs')} |")
    lines += [
        "",
        f"An errored clip is scored as a total miss ({TOTAL_MISS:.1f}, what an empty transcript "
        "scores) and left out of avg sec; a cell says how many clips errored or ran when that is not "
        "all of them. A dash means no clip of that language. The benchmark exits non-zero when any "
        "clip errored.",
    ]
    return lines
