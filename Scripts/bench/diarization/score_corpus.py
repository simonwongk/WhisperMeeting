#!/usr/bin/env python3
"""Score a directory of diarization runs against the F217 corpus.

Usage: score_corpus.py <hypothesis_dir> [--json] [--corpus <dir>]

Reports per-stratum-group DER and, more importantly, displayed-label precision and coverage: what a
reader would actually see after SpeakerOverlay's conservative rule. A corpus-wide micro-average is
printed too, but it is dominated by whichever fixture carries the most speaker-time, so the grouped
table is the one to read.
"""
import argparse
import glob
import json
import os
import re
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from score_diarization import (score, jaccard_error_rate, displayed_label_metrics,
                               optimal_mapping, normalise)

# `confidence` may be a float, the literal `n/a` (single cluster), or absent. Accepting only digits
# drops the whole line and silently loses every turn of a single-speaker recording.
SEGMENT = re.compile(
    r'^\s*([0-9]+\.[0-9]+)\s*--\s*([0-9]+\.[0-9]+)\s+speaker_([0-9]+)'
    r'(?:\s+confidence=(n/a|-?[0-9.]+))?\s*$')

GROUPS = [
    ("2-speaker clean", ["en_2spk_alt", "long_turns", "overlap_2spk", "rapid_turns"]),
    ("2-speaker adverse", ["noisy_en_snr10", "noisy_en_snr03", "silence_heavy",
                           "zh_2spk_alt", "codeswitch_2spk"]),
    ("1 speaker", ["mono_1spk"]),
    ("3+ speakers", ["en_3spk", "en_5spk", "twotrack_basic", "twotrack_bleed"]),
    ("long-form", ["longform_30min"]),
]


def parse_hypothesis(path):
    """Same contract as the Swift adapter: discard everything before the literal `Started`."""
    turns, started = [], False
    with open(path) as handle:
        for line in handle:
            if not started:
                if line.strip() == "Started":
                    started = True
                continue
            match = SEGMENT.match(line)
            if match:
                turns.append((float(match.group(1)), float(match.group(2)),
                              "spk" + match.group(3)))
    # Densify in first-appearance order, as the adapter does: the runtime's ids are sparse.
    order, dense = {}, []
    for start, end, label in turns:
        if label not in order:
            order[label] = len(order)
        dense.append((start, end, "c%d" % order[label]))
    return dense


def score_fixture(corpus_dir, hyp_dir, fixture_id):
    truth = json.load(open(os.path.join(corpus_dir, fixture_id + ".truth.json")))
    hyp_path = os.path.join(hyp_dir, fixture_id + ".txt")
    if not os.path.exists(hyp_path):
        return None
    hypothesis = parse_hypothesis(hyp_path)
    reference = [(t["start"], t["end"], t["speaker"]) for t in truth["turns"]]
    uem = [(0.0, truth["duration"])]

    if not reference:
        # No-speech fixture: DER is undefined; the only failure mode is false alarm.
        return {"id": fixture_id, "stratum": truth["stratum"], "no_speech": True,
                "false_alarm": sum(e - s for s, e, _ in normalise(hypothesis)),
                "speakers_hypothesis": len({l for _, _, l in hypothesis})}

    primary = score(reference, hypothesis, uem, 0.0, False)
    nist = score(reference, hypothesis, uem, 0.5, True)
    jer = jaccard_error_rate(reference, hypothesis, uem, 0.0, False)
    mapping = optimal_mapping(normalise(hypothesis), normalise(reference))
    displayed = displayed_label_metrics(reference, hypothesis, mapping=mapping)
    return {"id": fixture_id, "stratum": truth["stratum"], "no_speech": False,
            "der": primary["der"], "der_nist": nist["der"], "jer": jer["jer"],
            "total": primary["total"],
            "errors": primary["miss"] + primary["false_alarm"] + primary["confusion"],
            "speakers_reference": primary["speakers_reference"],
            "speakers_hypothesis": primary["speakers_hypothesis"],
            "rows": displayed["segments"], "shown": displayed["labelled"],
            "right": displayed["labelled_correct"]}


def precision(right, shown):
    """A dash when nothing was shown: `displayed_label_metrics` calls that case 1.0, and this used
    to print 0.0% for it — two definitions where F343 asks for one (F480)."""
    return "%.1f%%" % (100.0 * right / shown) if shown else "—"


# generate_corpus.py's DEFAULT_OUT; kept literal so this script needs nothing but the scorer.
DEFAULT_CORPUS = os.path.join(os.path.dirname(os.path.abspath(__file__)), "out")


def main():
    parser = argparse.ArgumentParser(description=__doc__,
                                     formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("hypothesis_dir", help="one <fixture id>.txt of runtime output per fixture")
    parser.add_argument("--json", action="store_true")
    parser.add_argument("--corpus", default=DEFAULT_CORPUS,
                        help="directory of <fixture id>.truth.json (default: out/ beside this script, "
                             "where generate_corpus.py writes)")
    args = parser.parse_args()
    hyp_dir = args.hypothesis_dir
    corpus_dir = args.corpus
    fixtures = sorted(os.path.basename(p)[:-len(".truth.json")]
                      for p in glob.glob(os.path.join(corpus_dir, "*.truth.json")))
    if not fixtures:
        print("no *.truth.json in %r — generate the corpus (generate_corpus.py --out <dir>) and pass "
              "--corpus <dir>" % corpus_dir, file=sys.stderr)
        return 1
    results = {}
    for fixture_id in fixtures:
        scored = score_fixture(corpus_dir, hyp_dir, fixture_id)
        if scored:
            results[fixture_id] = scored

    # Every fixture is accounted for by id. One with no hypothesis — the runtime crashed on it, or
    # the wrong directory was given — used to vanish from every table without a word, so the hard
    # fixtures quietly improved "ALL speech fixtures"; with none at all, the aggregate divided by
    # zero (F480).
    missing = [fixture_id for fixture_id in fixtures if fixture_id not in results]
    if not results:
        print("no <fixture id>.txt in %r for any of the %d corpus fixtures — nothing was scored"
              % (hyp_dir, len(fixtures)), file=sys.stderr)
        return 1
    accounted = "scored %d of %d corpus fixtures" % (len(results), len(fixtures))
    if missing:
        accounted += "; no hypothesis for: " + ", ".join(missing)

    if args.json:
        if missing:
            print(accounted, file=sys.stderr)   # stdout stays parseable JSON
        print(json.dumps(results, indent=2, sort_keys=True))
        return 0

    print(accounted)
    print()
    print("%-22s %-17s %8s %9s %4s %4s %6s %6s %9s" % (
        "fixture", "stratum", "DER", "DER-NIST", "ref", "hyp", "rows", "shown", "precision"))
    for fixture_id in fixtures:
        r = results.get(fixture_id)
        if not r:
            continue
        if r["no_speech"]:
            print("%-22s %-17s %8s %9s %4d %4d %6s %6s %9s   false alarm %.2fs" % (
                r["id"], r["stratum"], "n/a", "n/a", 0, r["speakers_hypothesis"],
                "-", "-", "-", r["false_alarm"]))
            continue
        print("%-22s %-17s %7.2f%% %8.2f%% %4d %4d %6d %6d %9s" % (
            r["id"], r["stratum"], 100 * r["der"], 100 * r["der_nist"],
            r["speakers_reference"], r["speakers_hypothesis"],
            r["rows"], r["shown"], precision(r["right"], r["shown"])))

    print()
    print("%-24s %8s %7s %7s %10s" % ("group", "DER", "rows", "shown", "precision"))
    for name, ids in GROUPS:
        total = errors = 0.0
        rows = shown = right = 0
        for fixture_id in ids:
            r = results.get(fixture_id)
            if not r or r["no_speech"]:
                continue
            total += r["total"]
            errors += r["errors"]
            rows += r["rows"]
            shown += r["shown"]
            right += r["right"]
        if not rows:
            continue
        print("%-24s %7.2f%% %7d %7d %10s  (coverage %.1f%%)" % (
            name, 100 * errors / total, rows, shown, precision(right, shown), 100 * shown / rows))

    speech = [r for r in results.values() if not r["no_speech"]]
    for label, subset in (("ALL speech fixtures", speech),
                          ("EXCLUDING long-form", [r for r in speech if r["id"] != "longform_30min"])):
        if not subset:
            continue
        total = sum(r["total"] for r in subset)
        errors = sum(r["errors"] for r in subset)
        rows = sum(r["rows"] for r in subset)
        shown = sum(r["shown"] for r in subset)
        right = sum(r["right"] for r in subset)
        print("%-24s %7.2f%% %7d %7d %10s  (coverage %.1f%%)" % (
            label, 100 * errors / total, rows, shown, precision(right, shown), 100 * shown / rows))
    return 0


if __name__ == "__main__":
    sys.exit(main())
