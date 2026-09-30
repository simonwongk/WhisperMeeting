#!/usr/bin/env python3
"""Score a clustering-threshold sweep against RTTM ground truth (F225).

    python3 Scripts/bench/diarization/sweep_score.py <rttm dir> <sweep dir>

`<sweep dir>/<threshold>/<name>.json` is what `runtime-probe`'s `sweep` writes; `<rttm dir>/<name>.rttm`
is the reference. Prints one row per threshold: micro-averaged DER per scoring condition, its
components under the strict condition, and the displayed-label precision and coverage the product's
overlay rule would produce. Stdlib only, like the scorer it drives.
"""
import json
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import score_diarization as sd  # noqa: E402


read_rttm = sd.read_rttm   # one copy, in the shared module (F348)


def main(argv):
    if len(argv) != 2:
        raise SystemExit(__doc__)
    rttm_dir, sweep_dir = argv
    conditions = [name for name, _, _ in sd.CONDITIONS]
    strict = conditions[0]
    # Every threshold is scored and checked before anything is printed (F616). The header used to
    # go out first and each row as it was scored, so a refusal for a later threshold left the header
    # and the earlier rows on stdout: `sweep_score.py rttm sweep > out.md` wrote a well-formed
    # partial table and then exited 1.
    rows = []
    for threshold in sorted(os.listdir(sweep_dir)):
        folder = os.path.join(sweep_dir, threshold)
        if not os.path.isdir(folder):
            continue
        reports, shown, correct, segments = [], 0, 0, 0
        for name in sorted(os.listdir(folder)):
            # Only the sweep's own output. `name[:-5]` on every entry turned a stray `.DS_Store`
            # into a FileNotFoundError against the RTTM directory (F343).
            if not name.endswith(".json"):
                continue
            stem = name[:-5]
            reference = read_rttm(os.path.join(rttm_dir, stem + ".rttm"))
            with open(os.path.join(folder, name), encoding="utf-8") as handle:
                hypothesis = [(t["start"], t["end"], t["speaker"]) for t in json.load(handle)]
            reports.append(sd.score_all_conditions(reference, hypothesis))
            labels = sd.displayed_label_metrics(reference, hypothesis)
            shown += labels["labelled"]
            correct += labels["labelled_correct"]
            segments += labels["segments"]
        # Files scored, not directories seen (F409): an empty threshold folder used to count as
        # scored and then divide by its zero total below — a ZeroDivisionError, not a refusal.
        if not reports:
            raise SystemExit(
                f"no .json hypotheses in {folder!r} — nothing was scored for threshold {threshold}"
            )
        cells = [sd.micro_average(reports, c) for c in conditions]
        first = cells[0]
        # Reference speech, not files read (F616): hypotheses whose same-stem RTTMs have no
        # SPEAKER lines are read and score nothing, and the component split below divided by it.
        if first["total"] <= 0:
            raise SystemExit(
                f"the RTTMs in {rttm_dir!r} for {folder!r} hold no reference speech (no SPEAKER "
                f"lines?) — nothing was scored for threshold {threshold}"
            )
        # `displayed_label_metrics` calls the no-rows case 1.0 — "it was never wrong" — and this
        # printed 0.0 for the same input. One definition, not two (F343).
        precision = (correct / shown) if shown else 1.0
        parts = "/".join(f"{100 * first[k] / first['total']:.1f}" for k in ("miss", "false_alarm", "confusion"))
        rows.append(f"{threshold} | {len(reports)} | " + " | ".join(f"{100 * c['der']:.1f}" for c in cells)
                    + f" | {parts} | {100 * precision:.1f} | {100 * shown / max(1, segments):.1f}")

    # A header with no rows under it reads as "scored, nothing to say". It actually means the two
    # arguments were swapped — the usage is <rttm dir> <sweep dir>, and the README had it backwards
    # until F348 followed its own instructions and got exactly this (F343's lesson, one script over).
    if not rows:
        raise SystemExit(
            f"no threshold directories in {sweep_dir!r} — arguments are <rttm dir> <sweep dir>, "
            "and nothing was scored"
        )
    print("threshold | files | " + " | ".join(f"DER {c}" for c in conditions)
          + f" | miss/FA/confusion ({strict}) | displayed precision | coverage")
    for row in rows:
        print(row)


if __name__ == "__main__":
    main(sys.argv[1:])
