#!/usr/bin/env python3
"""Concatenate per-segment `say`+`afconvert` WAV clips into one code-switch bench clip (F589).

`generate_clips.sh` synthesizes each language run of an English-dominant, Mandarin-embedded
sentence as its own single-voice WAV (English voice for the English runs, Mandarin voice for the
embedded words), then calls this to splice them back into one clip with a short silence between
segments — the shape a real code-switched dictation actually has, rather than one TTS voice reading
mixed-script text (which is what `cs1-3` are, and is a different, already-covered case).

Usage: splice_codeswitch.py OUTPUT.wav SILENCE_MS SEGMENT1.wav SEGMENT2.wav [...]

All segment WAVs must share the same (nchannels, sampwidth, framerate) — `generate_clips.sh`'s own
`afconvert -f WAVE -d LEI16@16000 -c 1` guarantees that for every segment it produces. Fails loudly
on a mismatch rather than silently resampling, so a future format change is caught here rather than
producing a subtly wrong bench clip.
"""
import sys
import wave


def main(argv):
    if len(argv) < 4:
        raise SystemExit(f"usage: {argv[0]} OUTPUT.wav SILENCE_MS SEGMENT.wav [SEGMENT.wav ...]")
    output_path = argv[1]
    silence_ms = float(argv[2])
    segment_paths = argv[3:]

    params = None
    frames = []
    for path in segment_paths:
        with wave.open(path, "rb") as handle:
            these_params = (handle.getnchannels(), handle.getsampwidth(), handle.getframerate())
            if params is None:
                params = these_params
            elif these_params != params:
                raise SystemExit(
                    f"{path}: format {these_params} does not match first segment's {params}"
                )
            frames.append(handle.readframes(handle.getnframes()))

    nchannels, sampwidth, framerate = params
    silence_frame_count = int(framerate * (silence_ms / 1000.0))
    silence = b"\x00" * (silence_frame_count * nchannels * sampwidth)

    joined = silence.join(frames)
    with wave.open(output_path, "wb") as handle:
        handle.setnchannels(nchannels)
        handle.setsampwidth(sampwidth)
        handle.setframerate(framerate)
        handle.writeframes(joined)


if __name__ == "__main__":
    sys.exit(main(sys.argv))
