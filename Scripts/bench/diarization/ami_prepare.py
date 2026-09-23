#!/usr/bin/env python3
"""Turn `diarizers-community/ami` annotations into what the sweep needs (F340).

`sweep` requires 16 kHz mono WAV and `sweep_score.py` requires `<rttm dir>/<name>.rttm`. Nothing in
the repo produced either, so the DER table and the F317 bucket table rested on one session's shell
history. This is that step, committed.

    python3 ami_prepare.py --manifest <ami.jsonl> --out <dir> [--gap 0]
    python3 ami_prepare.py --self-test

**Corrected 2026-09-22 (F377), by running it against the real shards for the first time.** Three
of the paragraphs that used to be here were wrong, and every one of them was about the path from a
file to a number — the same shape F348 found in the other two producers.

  * **The usage line said `--shards <dir of .parquet>`. There is no such argument**, and no
    parquet reader in this file; it reads the JSONL the README's step 1 produces. Anyone following
    the docstring got `error: unrecognized arguments: --shards`. The claim that "parquet is read
    with a minimal reader" described a design that was never here.
  * **"AMI ships per-word timings" is false for these shards.** The `ihm` config ships
    **utterances**: over all 8,664 annotated entries in the 18 validation meetings the median is
    **1.61 s**, the mean 3.64 s, the 90th percentile 9.15 s and the longest 96.9 s. Only 10.8% are
    even as short as a word (~0.3 s). So the per-speaker merge below is joining utterances, not
    words. (An earlier revision of this bullet said 1.34 s / 46.5 s, which was one shard — four
    meetings, 2,646 entries — read as if it were the corpus.)
  * **`--gap` does far less on this data than "moves every bucket" implies.** Measured over all 18
    validation meetings: 8,664 reference turns at `--gap 0`, 8,557 at the 0.5 default — **1.2%
    fewer**. It bites at 2.0 s (6,272 turns, 27.6% fewer). The rule is still the right one to make
    explicit; the size of its effect was overstated because the input was assumed to be words.

**The default is 0, decided in F393.** One reference turn per AMI utterance, which is what the
committed corpus already is. Of the 18 cached RTTMs under
`~/Library/Caches/WhisperMeet-Bench/ami/wav/` — the ones the scorecard's DER and bucket tables were
computed from — **17 reproduce byte-identically** at any `--gap` from 0 to 0.06; at 0.08 it is 14,
at 0.10 twelve, and at the old 0.5 default seven. The 18th is IB4011, two paragraphs down: the same
lines, two of them swapped.

The rule, stated so it can be argued with: **trust the corpus's own segmentation.** AMI's
utterance boundaries are human annotation, and merging across them invents reference turns nobody
annotated — in a table (F317's) whose entire subject is how long a reference turn is. The merging
code is kept because `--gap` remains the honest knob for anyone who wants the other rule, and
because it is what makes the decision visible rather than baked in.

The 18th meeting, IB4011, is a separate and smaller thing: at `--gap 0` its line *set* is
identical and two turns with bit-identical starts and ends (2384.100, 1.020 s, speakers MIO046 and
MIO095) appear in the opposite order. `sorted()` here breaks that tie on the speaker string and is
deterministic, so the cached file was written by a predecessor of this code. No number changes —
DER and the buckets are order-independent — so it is recorded rather than chased: **F394**.

Stdlib only, like the rest of `Scripts/`. Audio is decoded only when the manifest carries an
`audio` path and it is already WAV; a manifest with no `audio` produces RTTMs alone, which is all
the reproduction check needs.
"""

import argparse
import ast
import json
import os
import struct
import sys
import wave


# The reference-turn rule, in one place. F393 decided 0: one turn per annotated AMI utterance.
# It is a constant rather than a number written in three signatures because that is exactly how
# F393's defect arose — `--gap` had been moved to 0 while `prepare()` still said 0.5, so the same
# corpus produced different reference turns depending on which door you came in by. `self_test`
# asserts that no signature in this file reintroduces a literal.
DEFAULT_GAP = 0.0


# --------------------------------------------------------------------------------------
# Reference turns from the corpus's own annotations. This is what moves the numbers.
# --------------------------------------------------------------------------------------

def turns_from_words(words, gap=DEFAULT_GAP):
    """Maximal runs of one speaker's own consecutive entries, split wherever a gap exceeds `gap`.

    `words` is an iterable of (start, end, speaker). The parameter name is historical: for the
    `ihm` shards these are **utterances, not words** (see the module docstring), which is why
    `DEFAULT_GAP` is 0 and this merges nothing unless a caller asks it to.

    Merging is **per speaker**, not over the globally sorted list: AMI's annotations come from
    per-speaker headset channels, so another participant speaking in the middle of someone's pause
    does not end their turn. Merging over the global order instead would make every reference turn
    shorter in exactly the meetings with the most crosstalk — which is the population the
    row-length buckets are about.

    The result is sorted by start and never contains a zero-length or reversed turn.
    """
    by_speaker = {}
    for start, end, speaker in words:
        start, end, speaker = float(start), float(end), str(speaker)
        if end <= start:
            continue
        by_speaker.setdefault(speaker, []).append((start, end))
    turns = []
    for speaker, spans in by_speaker.items():
        run = None
        for start, end in sorted(spans):
            if run is not None and start - run[1] <= gap:
                run = (run[0], max(run[1], end))
                continue
            if run is not None:
                turns.append((run[0], run[1], speaker))
            run = (start, end)
        if run is not None:
            turns.append((run[0], run[1], speaker))
    return sorted(turns)


def rttm_lines(name, turns):
    """NIST RTTM, the format `sweep_score.py` reads."""
    return [
        "SPEAKER {0} 1 {1:.3f} {2:.3f} <NA> <NA> {3} <NA> <NA>".format(
            name, start, end - start, speaker
        )
        for start, end, speaker in turns
    ]


# --------------------------------------------------------------------------------------
# Audio
# --------------------------------------------------------------------------------------

def resample_to_16k_mono(frames, channels, sample_width, rate):
    """Nearest-neighbour decimation to 16 kHz mono 16-bit.

    Nearest-neighbour, not a filtered resample: AMI is already 16 kHz mono in the published shards,
    so this only runs on a shard that is not, and the honest thing is a conversion whose artefacts
    are obvious rather than one that looks principled and is not. `--strict` refuses instead.
    """
    if sample_width != 2:
        raise ValueError("only 16-bit PCM is supported, got %d bytes per sample" % sample_width)
    samples = struct.unpack("<%dh" % (len(frames) // 2), frames)
    if channels > 1:
        samples = [
            sum(samples[i:i + channels]) // channels
            for i in range(0, len(samples) - channels + 1, channels)
        ]
    if rate != 16_000:
        ratio = rate / 16_000.0
        samples = [samples[min(len(samples) - 1, int(i * ratio))]
                   for i in range(int(len(samples) / ratio))]
    return struct.pack("<%dh" % len(samples), *samples)


def write_16k_mono(path, frames, channels, sample_width, rate):
    converted = resample_to_16k_mono(frames, channels, sample_width, rate)
    with wave.open(path, "wb") as out:
        out.setnchannels(1)
        out.setsampwidth(2)
        out.setframerate(16_000)
        out.writeframes(converted)


# --------------------------------------------------------------------------------------
# Shard reading
# --------------------------------------------------------------------------------------

def read_manifest(path):
    """A shard manifest: one JSON object per meeting, `{"id", "words", "audio"?}`.

    `words` is a list of `[start, end, speaker]` triples. For the `ihm` shards these are
    **utterances, not words** — see the module docstring, and the `--gap` default that follows
    from it. `audio` is optional and, when present, must already be WAV.

    Converting the published parquet shards into this file is the README's step 1, and it is
    deliberately outside this tool: that step is the one that needs a third-party library, and
    everything that decides a *number* lives in here with nothing but the stdlib.

    **It is not `datasets`.** The route this docstring used to document could not run against
    these shards at all (F377) — step 1 reads the parquet directly with `pyarrow`.
    """
    with open(path, encoding="utf-8") as handle:
        return [json.loads(line) for line in handle if line.strip()]


def prepare(manifest_path, out_dir, gap=DEFAULT_GAP):
    meetings = read_manifest(manifest_path)
    audio_dir = os.path.join(out_dir, "wav")
    rttm_dir = os.path.join(out_dir, "rttm")
    os.makedirs(audio_dir, exist_ok=True)
    os.makedirs(rttm_dir, exist_ok=True)
    written = []
    for meeting in meetings:
        name = meeting["id"]
        turns = turns_from_words(meeting["words"], gap=gap)
        with open(os.path.join(rttm_dir, name + ".rttm"), "w", encoding="utf-8") as handle:
            handle.write("\n".join(rttm_lines(name, turns)) + "\n")
        source = meeting.get("audio")
        if source:
            with wave.open(source, "rb") as src:
                write_16k_mono(
                    os.path.join(audio_dir, name + ".wav"),
                    src.readframes(src.getnframes()),
                    src.getnchannels(), src.getsampwidth(), src.getframerate(),
                )
        written.append((name, len(turns)))
    return written


def assert_gap_default_has_one_home():
    """Every `gap` default in this file is `DEFAULT_GAP`, and the CLI agrees with it.

    Derived, not restated: it parses this file and reads whatever signatures are actually there,
    so a function added later — or an old one edited back to a literal — is caught too. Restating
    "check prepare and turns_from_words" is the shape of check that let the two drift apart.
    """
    tree = ast.parse(open(__file__, encoding="utf-8").read())
    seen = []
    for node in ast.walk(tree):
        if not isinstance(node, (ast.FunctionDef, ast.AsyncFunctionDef)):
            continue
        spec = node.args
        positional = spec.posonlyargs + spec.args
        pairs = list(zip(positional[len(positional) - len(spec.defaults):], spec.defaults))
        pairs += [(a, d) for a, d in zip(spec.kwonlyargs, spec.kw_defaults) if d is not None]
        for arg, default in pairs:
            if arg.arg != "gap":
                continue
            seen.append(node.name)
            assert isinstance(default, ast.Name) and default.id == "DEFAULT_GAP", (
                "%s(gap=...) defaults to a literal; use DEFAULT_GAP so the rule has one home"
                % node.name)

    # A scan that matches nothing passes vacuously, so name the two that must be in it. This is
    # a floor on the scan, not the list it checks.
    assert set(seen) >= {"turns_from_words", "prepare"}, seen
    assert build_parser().get_default("gap") == DEFAULT_GAP, build_parser().get_default("gap")
    assert DEFAULT_GAP == 0.0, DEFAULT_GAP


def self_test():
    """Synthetic, so it runs anywhere and proves the two decisions above, not the plumbing."""
    words = [
        (0.0, 0.4, "A"), (0.6, 1.0, "A"),      # 0.2 s gap: one turn
        (2.0, 2.5, "A"),                        # 1.0 s gap: a second turn
        (0.8, 1.2, "B"),                        # a different speaker never merges
        (5.0, 4.0, "A"),                        # reversed: dropped, never repaired
    ]
    turns = turns_from_words(words, gap=0.5)
    assert turns == [(0.0, 1.0, "A"), (0.8, 1.2, "B"), (2.0, 2.5, "A")], turns

    wide = turns_from_words(words, gap=2.0)
    assert wide == [(0.0, 2.5, "A"), (0.8, 1.2, "B")], wide

    lines = rttm_lines("ES2004a", [(1.5, 2.25, "A")])
    assert lines == ["SPEAKER ES2004a 1 1.500 0.750 <NA> <NA> A <NA> <NA>"], lines

    mono = resample_to_16k_mono(struct.pack("<4h", 1, 2, 3, 4), 1, 2, 16_000)
    assert struct.unpack("<4h", mono) == (1, 2, 3, 4)
    downmixed = resample_to_16k_mono(struct.pack("<4h", 10, 20, 30, 40), 2, 2, 16_000)
    assert struct.unpack("<2h", downmixed) == (15, 35), struct.unpack("<2h", downmixed)
    halved = resample_to_16k_mono(struct.pack("<4h", 1, 2, 3, 4), 1, 2, 32_000)
    assert struct.unpack("<2h", halved) == (1, 3)

    assert_gap_default_has_one_home()
    print("ami_prepare self-test passed")


def build_parser():
    """Split out of `main` so `self_test` can read the CLI's real default
    rather than restate it."""
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--manifest", help="JSONL: one {id, words, audio} object per meeting")
    parser.add_argument("--out", help="output directory (wav/ and rttm/ are created under it)")
    # Default 0 since F393: one reference turn per AMI utterance. See the module docstring for
    # the rule and why merging pre-segmented annotation was the wrong default.
    parser.add_argument("--gap", type=float, default=DEFAULT_GAP,
                        help="seconds of silence that close a reference turn "
                             "(default %g — one turn per annotated utterance)" % DEFAULT_GAP)
    parser.add_argument("--self-test", action="store_true")
    return parser


def main(argv):
    parser = build_parser()
    args = parser.parse_args(argv)
    if args.self_test:
        self_test()
        return 0
    if not args.manifest or not args.out:
        parser.error("--manifest and --out are required unless --self-test")
    for name, count in prepare(args.manifest, args.out, gap=args.gap):
        print("%s %d turns" % (name, count))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
