#!/usr/bin/env python3
"""Unit tests for the bench's meeting-path engine (Scripts/bench/qwen_meeting_engine.py).

Run: python3 Scripts/tests/test_benchmark_meeting_engine.py

F293, the other half of F241. The bench's Qwen row goes through `qwen_server.py`, the *dictation*
daemon: `grep -c qwen_transcribe` is 0 across `benchmark.py` and `qwen_server.py`. Meetings run
`Scripts/qwen_transcribe.py`, which chunks and batches differently — so every Qwen number the bench
has produced describes a path no meeting takes, and a regression in the meeting path could not show
up while the bench improved.

What is tested here is the part that can be wrong without a model: the argv the engine builds, the
language convention it shares with the daemon row, and how it reads the helper's output. The
first test is the ticket's actual claim — that the command names the meeting script — because an
engine that quietly pointed back at the daemon would produce a plausible second row measuring the
same thing twice, which is worse than having no second row.
"""

import importlib.util
import json
import os
import tempfile
import unittest

_HERE = os.path.dirname(os.path.abspath(__file__))
# Its own module rather than inside `benchmark.py`, which imports whisper, mlx_whisper, jiwer and
# opencc at module scope — none of them present in the system python3 that `quality-check.sh` runs.
# Testing around that would have meant an ungated test file; extracting the engine keeps it gated.
_SCRIPT = os.path.join(_HERE, "..", "bench", "qwen_meeting_engine.py")
_spec = importlib.util.spec_from_file_location("qwen_meeting_engine", _SCRIPT)
bench = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(bench)


class CommandTests(unittest.TestCase):
    def test_the_command_runs_the_meeting_script_not_the_dictation_daemon(self):
        """F293's whole point, asserted rather than assumed."""
        command = bench.meeting_engine_command(
            python="/rt/venv/bin/python3", script="/rt/qwen_transcribe.py",
            model="/rt/model", aligner="/rt/aligner",
            audio="/clips/en1.wav", output="/tmp/out.json", language="English",
        )
        self.assertTrue(command[1].endswith("qwen_transcribe.py"), command)
        self.assertNotIn("qwen_server.py", " ".join(command))
        self.assertNotIn("qwen_dictate_server.py", " ".join(command))

    def test_every_required_argument_is_present(self):
        """`qwen_transcribe.py` declares --model, --aligner, --audio and --output required, so a
        missing one is an argparse exit rather than a bad number — but it would be discovered only
        during a long run."""
        command = bench.meeting_engine_command(
            python="py", script="s.py", model="m", aligner="a",
            audio="in.wav", output="out.json", language="Chinese",
        )
        for flag, value in (("--model", "m"), ("--aligner", "a"),
                            ("--audio", "in.wav"), ("--output", "out.json"),
                            ("--language", "Chinese")):
            self.assertIn(flag, command)
            self.assertEqual(command[command.index(flag) + 1], value)

    def test_the_python_interpreter_leads_the_command(self):
        command = bench.meeting_engine_command(
            python="/rt/venv/bin/python3", script="s.py", model="m", aligner="a",
            audio="in.wav", output="out.json", language="auto",
        )
        self.assertEqual(command[0], "/rt/venv/bin/python3")


class LanguageTests(unittest.TestCase):
    def test_the_language_convention_matches_the_daemon_row(self):
        """Both rows must be told the same thing or the comparison measures the instruction, not the
        path. `QwenServer.transcribe` maps en → English, zh → Chinese."""
        self.assertEqual(bench.meeting_engine_language("en"), "English")
        self.assertEqual(bench.meeting_engine_language("zh"), "Chinese")

    def test_a_code_switch_clip_asks_for_auto_rather_than_guessing(self):
        """The daemon row sends "Chinese" for anything not `en`, which on a code-switched clip is a
        guess this engine should not copy: F271 measured Whisper dropping half a mixed clip after
        detecting one language. `auto` lets the helper's own detection answer."""
        self.assertEqual(bench.meeting_engine_language("cs"), "auto")

    def test_the_environment_override_is_honoured(self):
        previous = os.environ.get("QWEN_BENCH_LANGUAGE")
        os.environ["QWEN_BENCH_LANGUAGE"] = "Chinese"
        try:
            self.assertEqual(bench.meeting_engine_language("en"), "Chinese")
        finally:
            if previous is None:
                del os.environ["QWEN_BENCH_LANGUAGE"]
            else:
                os.environ["QWEN_BENCH_LANGUAGE"] = previous


class PayloadTests(unittest.TestCase):
    def test_the_transcript_and_detected_language_are_read_back(self):
        with tempfile.TemporaryDirectory() as directory:
            path = os.path.join(directory, "out.json")
            with open(path, "w", encoding="utf-8") as handle:
                json.dump({"text": " hello there ", "language": "en",
                           "alignedItems": [], "alignmentWarning": None}, handle)
            text, detected = bench.read_meeting_payload(path)
            self.assertEqual(text, "hello there")
            self.assertEqual(detected, "en")

    def test_a_null_language_reads_as_auto_not_as_a_language(self):
        """`qwen_transcribe.py` writes `language: null` when it cannot tell. Reporting that as a
        detected language would put a wrong label in the results table."""
        with tempfile.TemporaryDirectory() as directory:
            path = os.path.join(directory, "out.json")
            with open(path, "w", encoding="utf-8") as handle:
                json.dump({"text": "…", "language": None}, handle)
            self.assertEqual(bench.read_meeting_payload(path)[1], "auto")

    def test_an_empty_transcript_is_returned_rather_than_treated_as_success(self):
        """An empty transcript scores as a total miss, which is the honest result — silently
        skipping it would quietly raise the engine's average."""
        with tempfile.TemporaryDirectory() as directory:
            path = os.path.join(directory, "out.json")
            with open(path, "w", encoding="utf-8") as handle:
                json.dump({"text": "", "language": "en"}, handle)
            self.assertEqual(bench.read_meeting_payload(path)[0], "")

    def test_a_missing_output_file_raises_with_the_helpers_own_words(self):
        """The helper writes its diagnostics to stderr and its result to --output, so an exit with
        no file is the failure that needs the stderr tail attached — otherwise a run fails with
        'no such file' and the reason is in a pipe nobody kept."""
        with self.assertRaises(RuntimeError) as caught:
            bench.read_meeting_payload("/nonexistent/out.json",
                                       diagnostic="Traceback…\nMemoryError")
        self.assertIn("MemoryError", str(caught.exception))


if __name__ == "__main__":
    unittest.main()
