#!/usr/bin/env python3
"""F490 part 2 — resample_to_16k_mono's docstring pointed at a `--strict` refusal mode that does
not exist.

Run: python3 Scripts/tests/test_ami_prepare.py

The docstring said a non-16 kHz/mono shard gets nearest-neighbour decimation and "`--strict`
refuses instead" — but `build_parser` has only ever defined `--manifest`, `--out`, `--gap` and
`--self-test`. A reader pointed at that safeguard by the docstring, while working on a different
function in the same file (F418), gets `argparse: error: unrecognized arguments: --strict` and no
such refusal mode to fall back on.

F418 — `prepare` converted audio by decoding the whole WAV into Python ints, 2.08 GB resident for
TS3004c's 95 MB, and only the already-16 kHz-mono path had ever run on a real file: every AMI shard
is 16 kHz mono, so the down-mix and the resampling had four hand-made samples each behind them.
`StreamedConversionTests` pins the streamed conversion's memory, and runs both of those branches on
real WAV files.
"""

import array
import importlib.util
import json
import os
import shutil
import struct
import sys
import tempfile
import tracemalloc
import unittest
import wave

_HERE = os.path.dirname(os.path.abspath(__file__))
_MODULE_PATH = os.path.normpath(
    os.path.join(_HERE, "..", "bench", "diarization", "ami_prepare.py")
)


def _load_module():
    spec = importlib.util.spec_from_file_location("ami_prepare", _MODULE_PATH)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


class StrictFlagClaimTests(unittest.TestCase):
    def setUp(self):
        self.module = _load_module()

    def test_the_docstring_no_longer_claims_a_nonexistent_strict_flag(self):
        doc = self.module.resample_to_16k_mono.__doc__ or ""
        self.assertNotIn(
            "refuses instead", doc,
            "resample_to_16k_mono's docstring must not claim a --strict flag exists when "
            "build_parser does not define one",
        )

    def test_build_parser_genuinely_has_no_strict_flag(self):
        parser = self.module.build_parser()
        with self.assertRaises(SystemExit):
            # argparse writes its error to stderr and calls sys.exit(2); redirect stderr so the
            # test's own output stays clean.
            original_stderr = sys.stderr
            sys.stderr = open(os.devnull, "w")
            try:
                parser.parse_args(["--strict"])
            finally:
                sys.stderr.close()
                sys.stderr = original_stderr


def _signal(frames, channels):
    """A deterministic 16-bit signal `frames` long. Nearly every value is outside the -5..256 range
    Python caches, as real audio's are, so decoding it costs an int object per sample."""
    period = array.array("h", [((i * 7919) % 24001) - 12000 for i in range(401 * channels)])
    return (period * (frames // 401 + 1))[: frames * channels]


def _write_wav(path, samples, channels, rate):
    with wave.open(path, "wb") as out:
        out.setnchannels(channels)
        out.setsampwidth(2)
        out.setframerate(rate)
        out.writeframes(samples.tobytes())


def _riff(channels, rate, data):
    """A well-formed 16-bit PCM RIFF/WAVE whose data chunk is exactly `data`, whole frames or not,
    with the pad byte RIFF requires after an odd-length chunk. Built by hand so that both are
    exactly what the test says, rather than whatever `wave`'s writer does with a partial frame."""
    block = channels * 2
    fmt = struct.pack("<HHIIHH", 1, channels, rate, rate * block, block, 16)
    pad = b"\x00" if len(data) % 2 else b""
    body = (b"WAVE" + b"fmt " + struct.pack("<I", len(fmt)) + fmt
            + b"data" + struct.pack("<I", len(data)) + data + pad)
    return b"RIFF" + struct.pack("<I", len(body)) + body


def _read_wav(path):
    """((channels, sample width, rate), frames) — the frames exactly as `prepare` reads them."""
    with wave.open(path, "rb") as src:
        params = (src.getnchannels(), src.getsampwidth(), src.getframerate())
        return params, src.readframes(src.getnframes())


def _samples(frames):
    decoded = array.array("h")
    decoded.frombytes(frames)
    return list(decoded)


class StreamedConversionTests(unittest.TestCase):
    """F418: the conversion holds a block, not the recording, and its two non-trivial branches run
    on real WAV files rather than on four hand-made samples."""

    def setUp(self):
        self.module = _load_module()
        self.root = tempfile.mkdtemp()
        self.out = os.path.join(self.root, "out")

    def tearDown(self):
        shutil.rmtree(self.root)

    def source(self, name, samples, channels, rate):
        path = os.path.join(self.root, name + ".source.wav")
        _write_wav(path, samples, channels, rate)
        return path

    def prepare(self, name, source):
        """Run the real entry point on a one-meeting manifest; returns the WAV it wrote."""
        manifest = os.path.join(self.root, name + ".jsonl")
        with open(manifest, "w", encoding="utf-8") as handle:
            handle.write(json.dumps({"id": name, "words": [[0.0, 1.0, "A"]], "audio": source}) + "\n")
        self.module.prepare(manifest, self.out)
        return os.path.join(self.out, "wav", name + ".wav")

    def test_prepare_holds_a_block_of_audio_not_the_whole_recording(self):
        # 8 MiB of 16 kHz mono (262 s), the format every AMI shard is already in. The whole-file
        # conversion peaked at 26.9x this in Python allocations (225,330,571 bytes, measured on
        # Python 3.9 before F418); a streamed one holds a block.
        source = self.source("long", _signal(4 * 1024 * 1024, 1), 1, 16_000)
        tracemalloc.start()
        try:
            self.prepare("long", source)
            _, peak = tracemalloc.get_traced_memory()
        finally:
            tracemalloc.stop()
        size = os.path.getsize(source)
        self.assertLess(peak, size // 8,
                        "peak of %d bytes of Python allocations to convert a %d-byte WAV" % (peak, size))

    def test_every_conversion_path_holds_a_block_not_the_recording(self):
        # The pass-through above is one path. Down-mixing decodes, and resampling also reads the
        # file twice, so each is measured on its own: quadrupling the recording must not grow the
        # peak. Explicit 1,024-frame blocks keep it fast; the files are 16 and 64 blocks long.
        for channels, rate in [(2, 16_000), (1, 32_000), (2, 44_100), (3, 8_000)]:
            peaks = []
            for frames in (16 * 1_024, 64 * 1_024):
                source = self.source("grow", _signal(frames, channels), channels, rate)
                tracemalloc.start()
                try:
                    self.module.convert_to_16k_mono(
                        source, os.path.join(self.root, "grow.wav"), block_frames=1_024)
                    peaks.append(tracemalloc.get_traced_memory()[1])
                finally:
                    tracemalloc.stop()
            with self.subTest(channels=channels, rate=rate):
                self.assertLess(peaks[1], peaks[0] * 1.25, "peaks at 16 and 64 blocks: %r" % peaks)

    def test_an_already_16k_mono_source_comes_out_byte_identical(self):
        # Three default-size (65,536-frame) blocks and a last one that is not full.
        source = self.source("mono", _signal(3 * 65_536 + 123, 1), 1, 16_000)
        params, frames = _read_wav(self.prepare("mono", source))
        self.assertEqual(params, (1, 2, 16_000))
        self.assertEqual(frames, _read_wav(source)[1])

    def test_a_real_stereo_wav_is_downmixed_to_the_floor_of_its_mean(self):
        pairs = [(-3, 0), (3, 0), (10, 21), (-32768, -32768), (32767, 32767), (32767, -32768), (-1, 0)]
        source = self.source("stereo", array.array("h", [s for pair in pairs for s in pair]), 2, 16_000)
        params, frames = _read_wav(self.prepare("stereo", source))
        self.assertEqual(params, (1, 2, 16_000))
        # Floor, as `//` is. Truncating toward zero would give -1 and 0 where -2 and -1 are expected.
        self.assertEqual(_samples(frames), [-2, 1, 15, -32768, 32767, -1, -1])

    def test_a_real_32k_wav_is_decimated_to_every_other_sample(self):
        source = self.source("wide", array.array("h", [1000 * k - 4000 for k in range(10)]), 1, 32_000)
        params, frames = _read_wav(self.prepare("wide", source))
        self.assertEqual(params, (1, 2, 16_000))
        self.assertEqual(_samples(frames), [-4000, -2000, 0, 2000, 4000])

    def test_block_boundaries_change_no_sample(self):
        # The whole-buffer `resample_to_16k_mono` is the definition; the streamed conversion must
        # agree with it byte for byte wherever the blocks fall. 44.1 and 22.05 kHz are non-integer
        # ratios, 8 kHz upsamples, and three channels is not stereo. 1-frame blocks put a boundary
        # between every pair of frames; a 1,000-frame file ends in a short block at 7 and 64, and
        # is a single short block at 4,096.
        for channels, rate in [(1, 16_000), (2, 16_000), (1, 32_000), (1, 44_100),
                               (2, 48_000), (1, 8_000), (3, 22_050)]:
            source = self.source("shape", _signal(1_000, channels), channels, rate)
            expected = self.module.resample_to_16k_mono(_read_wav(source)[1], channels, 2, rate)
            for block_frames in (1, 7, 64, 4_096):
                with self.subTest(channels=channels, rate=rate, block_frames=block_frames):
                    dest = os.path.join(self.root, "shape.wav")
                    self.module.convert_to_16k_mono(source, dest, block_frames=block_frames)
                    params, frames = _read_wav(dest)
                    self.assertEqual(params, (1, 2, 16_000))
                    self.assertEqual(frames, expected)

    def test_a_truncated_source_converts_what_it_holds(self):
        # A WAV cut short holds fewer frames than its header promises. The definition converts
        # what reads back, so the resampling must count that rather than trust `getnframes()`,
        # and a down-mix drops the half-frame at the end. 9 divides the 999 whole frames the stereo
        # sources keep, so 9-frame blocks put that half-frame in a block of its own; 65,536 is the
        # default, one block for the whole file.
        for channels, rate in [(1, 32_000), (2, 48_000), (2, 16_000)]:
            source = self.source("short", _signal(1_000, channels), channels, rate)
            with open(source, "r+b") as handle:
                handle.truncate(os.path.getsize(source) - 2)
            with wave.open(source, "rb") as src:
                promised = src.getnframes() * channels * 2
            held = _read_wav(source)[1]
            self.assertLess(len(held), promised, "the premise: the header promises more than is held")
            expected = self.module.resample_to_16k_mono(held, channels, 2, rate)
            for block_frames in (9, 65_536):
                with self.subTest(channels=channels, rate=rate, block_frames=block_frames):
                    dest = os.path.join(self.root, "short.wav")
                    self.module.convert_to_16k_mono(source, dest, block_frames=block_frames)
                    self.assertEqual(_read_wav(dest)[1], expected)

    def test_bytes_past_the_last_whole_frame_of_a_data_chunk_are_ignored(self):
        # A well-formed WAV can declare a data chunk that is not a whole number of frames. The
        # definition's input is `readframes(getnframes())`, which reads the whole frames and never
        # the bytes past them, so those bytes change nothing — and an odd count of them must not
        # read as audio ending in half a sample. 7-frame blocks do not divide the 1,000 frames, so
        # the last whole-frame block is short as well.
        for channels, rate, stray in [(1, 16_000, 1), (2, 16_000, 1), (2, 16_000, 3),
                                      (1, 32_000, 1), (2, 44_100, 3), (3, 8_000, 5),
                                      (3, 22_050, 4)]:
            source = os.path.join(self.root, "stray.source.wav")
            with open(source, "wb") as handle:
                handle.write(_riff(channels, rate, _signal(1_000, channels).tobytes()
                                   + bytes(range(1, stray + 1))))
            params, frames = _read_wav(source)
            self.assertEqual(len(frames), 1_000 * channels * 2,
                             "the premise: the header's whole frames are the 1,000 written")
            expected = self.module.resample_to_16k_mono(frames, channels, 2, rate)
            for block_frames in (7, 65_536):
                with self.subTest(channels=channels, rate=rate, stray=stray,
                                  block_frames=block_frames):
                    dest = os.path.join(self.root, "stray.wav")
                    self.module.convert_to_16k_mono(source, dest, block_frames=block_frames)
                    self.assertEqual(_read_wav(dest)[1], expected)

    def test_a_conversion_that_fails_partway_leaves_the_earlier_output_alone(self):
        # Audio that ends in half a sample fails on the last block, after the earlier blocks were
        # converted. Streaming straight into the destination would replace the earlier run's
        # output with a shorter WAV whose header is well-formed — a truncated meeting that reads
        # as a whole one.
        source = self.source("cut", _signal(3 * 1_024, 1), 1, 16_000)
        with open(source, "r+b") as handle:
            handle.truncate(os.path.getsize(source) - 1)
        dest = os.path.join(self.root, "cut.wav")
        with open(dest, "wb") as handle:
            handle.write(b"an earlier run's output")
        with self.assertRaises(ValueError):
            self.module.convert_to_16k_mono(source, dest, block_frames=1_024)
        with open(dest, "rb") as handle:
            self.assertEqual(handle.read(), b"an earlier run's output")
        self.assertEqual(sorted(os.listdir(self.root)), ["cut.source.wav", "cut.wav"])


if __name__ == "__main__":
    unittest.main(verbosity=2)
