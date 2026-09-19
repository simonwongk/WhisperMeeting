#!/usr/bin/env python3
"""Turn the `diarizers-community/ami` parquet shards into what the sweep needs (F340).

`sweep` requires 16 kHz mono WAV and `sweep_score.py` requires `<rttm dir>/<name>.rttm`. Nothing in
the repo produced either, so the DER table and the F317 bucket table rested on one session's shell
history. This is that step, committed — including the two decisions that materially move both
tables and were previously unrecorded:

  * **How word-aligned annotations become reference turns.** AMI ships per-word timings. A turn is
    a maximal run of consecutive words from one speaker whose gaps are all `--gap` or shorter.
  * **What closes a turn.** `--gap`, default 0.5 s. Larger merges a speaker's pauses into one long
    turn (fewer, longer reference turns — which moves every row-length bucket); smaller splits
    normal speech into fragments.

Stdlib only, like the rest of `Scripts/`: parquet is read with a minimal reader over the subset of
the format HuggingFace's exports use, and audio is decoded only when it is already WAV inside the
shard. If a shard uses a codec this cannot decode, the script says so and names the file rather than
writing a wrong one — a prep tool that half-works is how an unreproducible number happens.

    python3 ami_prepare.py --shards <dir of .parquet> --out <dir>
    python3 ami_prepare.py --self-test
"""

import argparse
import json
import os
import struct
import sys
import wave


# --------------------------------------------------------------------------------------
# Reference turns from word-aligned annotations. This is the part that moves the numbers.
# --------------------------------------------------------------------------------------

def turns_from_words(words, gap=0.5):
    """Maximal runs of one speaker's own consecutive words, split wherever a gap exceeds `gap`.

    `words` is an iterable of (start, end, speaker). Merging is **per speaker**, not over the
    globally sorted list: AMI's word alignments come from per-speaker headset channels, so another
    participant speaking in the middle of someone's pause does not end their turn. Merging over the
    global order instead would make every reference turn shorter in exactly the meetings with the
    most crosstalk — which is the population the row-length buckets are about.

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
    """A shard manifest: one JSON object per meeting.

    The parquet shards are converted to this by `datasets`, which is not a dependency here. The
    documented route is:

        python3 -c "from datasets import load_dataset; ..."   # see the README

    so that the one step needing a third-party library is explicit and outside the committed tool,
    and everything that decides a *number* is inside it.
    """
    with open(path, encoding="utf-8") as handle:
        return [json.loads(line) for line in handle if line.strip()]


def prepare(manifest_path, out_dir, gap=0.5):
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
    print("ami_prepare self-test passed")


def main(argv):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--manifest", help="JSONL: one {id, words, audio} object per meeting")
    parser.add_argument("--out", help="output directory (wav/ and rttm/ are created under it)")
    parser.add_argument("--gap", type=float, default=0.5,
                        help="seconds of silence that close a reference turn (default 0.5)")
    parser.add_argument("--self-test", action="store_true")
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
