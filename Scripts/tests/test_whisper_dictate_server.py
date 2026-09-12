#!/usr/bin/env python3
"""Unit tests for the direct-WAV fast path in Scripts/whisper_dictate_server.py (F206).

Run: python3 Scripts/tests/test_whisper_dictate_server.py

`mlx_whisper.load_audio` forks an `ffmpeg` process for every request to down-mix and resample the
clip (site-packages/mlx_whisper/audio.py:41-59). WhisperMeet's own recorder already writes exactly
what the model wants — 16-bit PCM, mono, 16 kHz (`WAVWriter` + `DictationCaptureLimits.sampleRate`)
— so that fork is pure per-dictation overhead. Measured on this Mac: 27.6 ms median for a 3.1 s
clip, versus ~0 ms for a stdlib `wave` read, with byte-identical samples.

Imports only the helper's pure pieces (no mlx_whisper import at module scope), mirroring
test_refine_server.py, so this runs under plain system python3 with no runtime installed.
"""

import importlib.util
import os
import struct
import tempfile
import unittest
import wave

_SCRIPT = os.path.join(os.path.dirname(__file__), "..", "whisper_dictate_server.py")
_spec = importlib.util.spec_from_file_location("whisper_dictate_server", _SCRIPT)
server = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(server)


def write_wav(path, frames, channels=1, sampwidth=2, framerate=16000):
    with wave.open(path, "wb") as handle:
        handle.setnchannels(channels)
        handle.setsampwidth(sampwidth)
        handle.setframerate(framerate)
        handle.writeframes(frames)


def pcm16(samples):
    return struct.pack("<%dh" % len(samples), *samples)


class ConformingPCM16FramesTests(unittest.TestCase):
    def setUp(self):
        self.dir = tempfile.mkdtemp()

    def path(self, name):
        return os.path.join(self.dir, name)

    def test_returns_exact_frame_bytes_for_the_recorder_s_own_format(self):
        """A clip in the app's own capture format is read directly, byte for byte."""
        samples = [0, 1, -1, 32767, -32768, 1234, -4321]
        expected = pcm16(samples)
        path = self.path("mono16k.wav")
        write_wav(path, expected)

        self.assertEqual(server.conforming_pcm16_frames(path), expected)

    def test_rejects_a_different_sample_rate(self):
        """44.1 kHz must fall back to the resampling decoder, never be read as 16 kHz."""
        path = self.path("44k.wav")
        write_wav(path, pcm16([1, 2, 3]), framerate=44100)

        self.assertIsNone(server.conforming_pcm16_frames(path))

    def test_rejects_stereo(self):
        """Two channels need down-mixing, which this fast path deliberately does not do."""
        path = self.path("stereo.wav")
        write_wav(path, pcm16([1, 2, 3, 4]), channels=2)

        self.assertIsNone(server.conforming_pcm16_frames(path))

    def test_rejects_8_bit_samples(self):
        """8-bit PCM is not the int16 layout the conversion assumes."""
        path = self.path("eight.wav")
        write_wav(path, b"\x01\x02\x03", sampwidth=1)

        self.assertIsNone(server.conforming_pcm16_frames(path))

    def test_returns_none_for_a_file_that_is_not_a_wav(self):
        """A corrupt or non-WAV clip falls back instead of raising and failing the dictation."""
        path = self.path("not-a-wav.wav")
        with open(path, "wb") as handle:
            handle.write(b"this is not a RIFF file")

        self.assertIsNone(server.conforming_pcm16_frames(path))

    def test_returns_none_for_a_missing_file(self):
        """A vanished clip must reach the normal decoder, which owns that error message."""
        self.assertIsNone(server.conforming_pcm16_frames(self.path("gone.wav")))

    def test_accepts_an_empty_but_valid_clip(self):
        """A zero-length capture is well-formed; it must not be mistaken for a format mismatch."""
        path = self.path("empty.wav")
        write_wav(path, b"")

        self.assertEqual(server.conforming_pcm16_frames(path), b"")

    def test_honours_an_explicit_sample_rate(self):
        """The expected rate is a parameter so it can stay tied to DictationCaptureLimits."""
        path = self.path("8k.wav")
        write_wav(path, pcm16([5, 6]), framerate=8000)

        self.assertIsNone(server.conforming_pcm16_frames(path, sample_rate=16000))
        self.assertEqual(
            server.conforming_pcm16_frames(path, sample_rate=8000), pcm16([5, 6])
        )


class PrewarmDecodeOptionsTests(unittest.TestCase):
    """The readiness prewarm exists to make the model and its kernels resident; its transcript is
    discarded. Whisper's default decode retries the clip at six temperatures whenever the result
    trips its compression-ratio / logprob thresholds — which pure digital silence always does — so
    the shipped prewarm paid five extra full decodes for a result nobody reads. Measured on the
    installed runtime with the model already resident: 2631 ms default vs 1276 ms greedy, i.e.
    ~1.35 s off every helper start (every cold start and every post-eviction reload)."""

    def test_prewarm_uses_a_single_greedy_pass(self):
        calls = []

        def fake_transcribe(audio, **kwargs):
            calls.append((audio, kwargs))
            return {"text": ""}

        server.prewarm(fake_transcribe, audio=[0.0] * 1600, mlx_repo="repo/name")

        self.assertEqual(len(calls), 1)
        _, kwargs = calls[0]
        self.assertEqual(kwargs["temperature"], 0.0)

    def test_prewarm_keeps_stdout_silent_and_targets_the_request_path(self):
        """verbose MUST stay None (False still prints) and the task must match real requests, or
        the prewarm compiles a different path than the one dictation actually uses."""
        calls = []

        def fake_transcribe(audio, **kwargs):
            calls.append(kwargs)
            return {"text": ""}

        server.prewarm(fake_transcribe, audio=[0.0] * 1600, mlx_repo="repo/name")

        self.assertIsNone(calls[0]["verbose"])
        self.assertEqual(calls[0]["task"], "transcribe")
        self.assertEqual(calls[0]["path_or_hf_repo"], "repo/name")


if __name__ == "__main__":
    unittest.main()
