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


class TemperatureFallbackTests(unittest.TestCase):
    """F210 — the ladder the single-window path replicates from `mlx_whisper.transcribe`.

    Pinned rather than trusted, because the whole change rests on behaving identically to a pinned
    library version. If a runtime upgrade moves these, this fails and the fast path should be
    re-verified against the bench clips before shipping — which is what caught the segment-slicing
    difference in the first place.
    """

    def test_the_ladder_matches_the_installed_transcribe(self):
        self.assertEqual(server.FALLBACK_TEMPERATURES, (0.0, 0.2, 0.4, 0.6, 0.8, 1.0))
        self.assertEqual(server.COMPRESSION_RATIO_THRESHOLD, 2.4)
        self.assertEqual(server.LOGPROB_THRESHOLD, -1.0)
        self.assertEqual(server.NO_SPEECH_THRESHOLD, 0.6)

    def test_a_good_result_does_not_retry(self):
        self.assertFalse(server.needs_temperature_fallback(1.2, -0.3, 0.05))

    def test_repetitive_output_retries(self):
        self.assertTrue(server.needs_temperature_fallback(3.0, -0.3, 0.05))

    def test_low_confidence_retries(self):
        self.assertTrue(server.needs_temperature_fallback(1.2, -1.5, 0.05))

    def test_silence_is_accepted_rather_than_retried_six_times(self):
        """The `no_speech` clause comes LAST and sets the flag back to False.

        This is the ordering that makes the function worth having: written as one boolean
        expression it reads as an `and`, and a silent clip would then be re-decoded at all six
        temperatures — six encoder-free but not free decodes, for a clip with nothing in it.
        """
        self.assertFalse(server.needs_temperature_fallback(3.0, -1.5, 0.9))
        # And a marginal clip just under the silence threshold still retries.
        self.assertTrue(server.needs_temperature_fallback(3.0, -1.5, 0.6))

    def test_thresholds_are_exclusive_at_the_boundary(self):
        """`>` and `<`, not `>=`/`<=` — matching `transcribe.py:229/234/239` exactly."""
        self.assertFalse(server.needs_temperature_fallback(2.4, -1.0, 0.0))


class SingleWindowFastPathTests(unittest.TestCase):
    """F210 — the fast path must DECLINE rather than fail, for anything it cannot handle.

    Same principle as the raw-frames audio fast path above: a fast path that cannot be taken must
    never fail a dictation. These run with no mlx installed, which is also the most important
    decline case — CI has no runtime, and neither does a Mac that has not installed one.
    """

    def test_a_missing_runtime_declines_instead_of_raising(self):
        self.assertIsNone(
            server.transcribe_single_window(None, None, [0.0] * 1600, "repo/name", None, None)
        )

    def test_an_unexpected_failure_declines_instead_of_raising(self):
        class Exploding:
            float16 = "f16"

            def __getattr__(self, name):
                raise RuntimeError("runtime internals moved")

        self.assertIsNone(
            server.transcribe_single_window(
                None, Exploding(), [0.0] * 1600, "repo/name", None, None
            )
        )


if __name__ == "__main__":
    unittest.main()
