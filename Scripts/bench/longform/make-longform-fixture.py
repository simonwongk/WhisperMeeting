#!/usr/bin/env python3
"""Build the long-form ASR bench fixture from the committed short clips (F241).

Run: python3 Scripts/bench/longform/make-longform-fixture.py [out_dir]

**Why a generator rather than a committed WAV.** Eight 60-second chunks is ~15 MB of 16 kHz PCM,
and the inputs are already in the repository — so generating is reproducible, adds no binary bloat,
and cannot drift from the clips it is built from. Same shape as
`Scripts/bench/diarization/make-ui-fixtures.sh`.

**What F241 is actually about, corrected.** The ticket says `transcribe_batched` "returns `None`
when `len(chunks) <= 1` at a 60 s chunk duration", so every short clip took the sequential path.
That is **no longer true**: F268 set `ASR_MIN_BATCHED_CHUNKS = 1`, so a single-chunk recording is
batched now. But the ticket's headline — that the bench has never executed the batched meeting path
— is still correct, for the reason in its *second* paragraph rather than its first: neither
`benchmark.py` nor `bench/qwen_server.py` so much as mentions `qwen_transcribe.py`. The bench talks
to a resident daemon, so no chunk threshold could ever have routed it into the meeting script.

This fixture therefore exists for the other two complaints, which are untouched by that:

- **Multi-chunk behaviour.** Batching, cache eviction and the tail chunk only appear past one chunk,
  and nothing in the bench has ever been long enough to produce a second one.
- **Discriminating power.** F240 measured 8-bit and 4-bit scoring EN WER 0.0000 and ZH CER 0.0000 on
  all ten clips, while 4-bit corrupted proper nouns on real audio. A bench that scores a rejected
  configuration perfectly is a null instrument.

The second is the one this cannot promise. Repeating the same ten sentences makes the fixture LONG
without making it HARDER, and the words that broke 4-bit in the field were proper nouns these clips
do not contain. Whether it discriminates is therefore a measurement, not a design claim — run
`score-longform.py` and read the answer.
"""

import json
import pathlib
import sys
import wave

CLIPS = pathlib.Path(__file__).resolve().parents[1] / "clips"
#: Enough passes to exceed eight 60-second chunks, so batching, eviction and a partial tail all run.
TARGET_SECONDS = 8 * 60 + 30
#: Fixed order, so the fixture is byte-identical between runs and between machines. Sorted rather
#: than the reference file's order, because a dict's order is not a promise.
CLIP_ORDER = ["cs1", "cs2", "cs3", "en1", "en2", "en3", "en4", "zh1", "zh2", "zh3"]

#: Per-language fixtures, because a mixed one cannot answer a Whisper question (F271).
#:
#: openai-whisper picks ONE language per file — the mixed fixture above was detected as Chinese and
#: scored WER 0.98 with a 0.47 length ratio, i.e. it dropped over half the content. Both arms of a
#: flag comparison then score ~1.0, which measures language-detection failure rather than the flag
#: and is exactly the null instrument F241 objects to. Qwen handles the mixed one fine; Whisper
#: needs monolingual input, which is why F271 asks for "at least one item **per language**".
#:
#: `cs` is deliberately absent: those clips are code-switched by design, so there is no single
#: language for Whisper to be given, and a cs fixture would reproduce the same defect.
LANGUAGE_SETS = {
    "en": ["en1", "en2", "en3", "en4"],
    "zh": ["zh1", "zh2", "zh3"],
}
#: Shorter than the mixed fixture: four 60 s chunks still exercises batching, eviction and a partial
#: tail, and a Whisper run over this costs minutes per arm on CPU.
LANGUAGE_TARGET_SECONDS = 3 * 60 + 30


def read_clip(path):
    with wave.open(str(path), "rb") as handle:
        if handle.getnchannels() != 1 or handle.getsampwidth() != 2:
            raise SystemExit(f"{path.name}: expected 16-bit mono, got "
                             f"{handle.getnchannels()}ch {handle.getsampwidth() * 8}bit")
        return handle.getframerate(), handle.readframes(handle.getnframes())


def main(argv):
    out_dir = pathlib.Path(argv[1]) if len(argv) > 1 else CLIPS.parent / "longform" / "build"
    out_dir.mkdir(parents=True, exist_ok=True)

    references = json.loads((CLIPS / "references.json").read_text(encoding="utf-8"))
    missing = [name for name in CLIP_ORDER if name not in references]
    if missing:
        raise SystemExit(f"references.json is missing: {', '.join(missing)}")

    rate = None
    pass_frames, pass_text = b"", []
    for name in CLIP_ORDER:
        clip_rate, frames = read_clip(CLIPS / f"{name}.wav")
        if rate is None:
            rate = clip_rate
        elif clip_rate != rate:
            raise SystemExit(f"{name}.wav is {clip_rate} Hz, expected {rate} Hz")
        pass_frames += frames
        pass_text.append(references[name]["text"])

    pass_seconds = len(pass_frames) / 2 / rate
    passes = int(TARGET_SECONDS / pass_seconds) + 1

    audio = out_dir / "longform.wav"
    with wave.open(str(audio), "wb") as handle:
        handle.setnchannels(1)
        handle.setsampwidth(2)
        handle.setframerate(rate)
        for _ in range(passes):
            handle.writeframes(pass_frames)

    total_seconds = passes * pass_seconds
    # The ground truth is the concatenated references, in the same fixed order, repeated the same
    # number of times. Written beside the audio rather than committed, for the same reason the audio
    # is not: it is derived, so a committed copy could disagree with the file it describes.
    (out_dir / "longform.txt").write_text(
        " ".join(" ".join(pass_text) for _ in range(passes)) + "\n", encoding="utf-8"
    )
    (out_dir / "longform.json").write_text(
        json.dumps({
            "audio": audio.name,
            "reference": "longform.txt",
            "sampleRate": rate,
            "seconds": round(total_seconds, 2),
            "passes": passes,
            "clipOrder": CLIP_ORDER,
            # Recorded so a reader can check the chunk count against the runtime's own constant
            # rather than recomputing it — `ASR_CHUNK_SECONDS` is 60.0 in `qwen_transcribe.py`.
            "chunksAt60s": int(total_seconds // 60) + (1 if total_seconds % 60 else 0),
        }, indent=2) + "\n",
        encoding="utf-8",
    )

    print(f"wrote {audio} — {total_seconds:.1f}s, {passes} passes of {pass_seconds:.2f}s")
    print(f"      {int(total_seconds // 60) + 1} chunks at the runtime's 60 s chunk duration")
    print(f"      reference: {out_dir / 'longform.txt'}")

    for language, names in LANGUAGE_SETS.items():
        write_fixture(
            out_dir=out_dir,
            stem=f"longform-{language}",
            names=names,
            references=references,
            rate=rate,
            target_seconds=LANGUAGE_TARGET_SECONDS,
            language=language,
        )
    return 0


def write_fixture(*, out_dir, stem, names, references, rate, target_seconds, language):
    """One monolingual fixture, so a single-language engine can be measured on it."""
    pass_frames, pass_text = b"", []
    for name in names:
        clip_rate, frames = read_clip(CLIPS / f"{name}.wav")
        if clip_rate != rate:
            raise SystemExit(f"{name}.wav is {clip_rate} Hz, expected {rate} Hz")
        pass_frames += frames
        pass_text.append(references[name]["text"])

    pass_seconds = len(pass_frames) / 2 / rate
    passes = int(target_seconds / pass_seconds) + 1
    audio = out_dir / f"{stem}.wav"
    with wave.open(str(audio), "wb") as handle:
        handle.setnchannels(1)
        handle.setsampwidth(2)
        handle.setframerate(rate)
        for _ in range(passes):
            handle.writeframes(pass_frames)

    total = passes * pass_seconds
    (out_dir / f"{stem}.txt").write_text(
        " ".join(" ".join(pass_text) for _ in range(passes)) + "\n", encoding="utf-8"
    )
    (out_dir / f"{stem}.json").write_text(
        json.dumps({
            "audio": audio.name,
            "reference": f"{stem}.txt",
            "language": language,
            "sampleRate": rate,
            "seconds": round(total, 2),
            "passes": passes,
            "clipOrder": names,
            "chunksAt60s": int(total // 60) + (1 if total % 60 else 0),
        }, indent=2) + "\n",
        encoding="utf-8",
    )
    print(f"wrote {audio} — {total:.1f}s, {int(total // 60) + 1} chunks, language={language}")


if __name__ == "__main__":
    sys.exit(main(sys.argv))
