#!/usr/bin/env python3
"""Unit tests for `Scripts/bench/dictation-ab.py`'s meeting-path engine (F628).

Run: python3 Scripts/tests/test_dictation_ab_meeting.py

F589 measured the dictation helpers per word on the English-dominant code-switch clips and found
Qwen writing the spoken 王老师 as "Wang老师". Whether a MEETING does the same could not be asked of
this script: it drove only the dictation daemons, and a meeting runs `Scripts/qwen_transcribe.py`
as one process per file with its own chunking and batched decode. F628 adds that path as an
engine, built through the bench's existing meeting glue (`qwen_meeting_engine.py`, F293) so there
is one argv builder and not two.

What is tested is what can be wrong without a model: that the engine names the meeting script and
the installed model and aligner, that the app's "Detect automatically" reaches the helper as
`auto`, that the helper's `--output` payload becomes the row `--words` scores, and that a run with
no output is a recorded miss with the helper's own words rather than a crash or a silent skip.
"""

import importlib.util
import json
import os
import re
import tempfile
import unittest

_HERE = os.path.dirname(os.path.abspath(__file__))
_REPO = os.path.abspath(os.path.join(_HERE, "..", ".."))
# A hyphenated file name cannot be imported by name, hence the spec. The module is stdlib-only
# (qwen_meeting_engine.py is too), so the system python3 `quality-check.sh` runs can load it.
_SCRIPT = os.path.join(_REPO, "Scripts", "bench", "dictation-ab.py")
_spec = importlib.util.spec_from_file_location("dictation_ab", _SCRIPT)
ab = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(ab)

ENCS4 = {"lang": "encs", "text": "I'll ping 王老师 about the 作业 tonight.",
         "words": ["王老师", "作业"]}


class FakeCompleted:
    def __init__(self, stdout="", stderr=""):
        self.stdout, self.stderr, self.returncode = stdout, stderr, 0


class Recorder:
    """Stands in for `subprocess.run`: records each call and writes (or does not write) the
    helper's `--output` file the way `qwen_transcribe.py` would."""

    def __init__(self, payload=None, stderr=""):
        self.payload, self.stderr, self.calls = payload, stderr, []

    def __call__(self, command, **keywords):
        self.calls.append((command, keywords))
        if self.payload is not None:
            output = command[command.index("--output") + 1]
            with open(output, "w", encoding="utf-8") as handle:
                json.dump(self.payload, handle, ensure_ascii=False)
        return FakeCompleted(stderr=self.stderr)


def with_clip(test):
    """Runs `test(clips_dir)` with a CLIPS directory holding an (empty) encs4.wav. The engine only
    checks the file exists and hands its path to the helper, so no audio is needed."""
    def wrapper(self):
        with tempfile.TemporaryDirectory() as directory:
            open(os.path.join(directory, "encs4.wav"), "wb").close()
            previous = ab.CLIPS
            ab.CLIPS = directory
            try:
                test(self, directory)
            finally:
                ab.CLIPS = previous
    return wrapper


class EngineSpecTests(unittest.TestCase):
    def test_the_meeting_engine_runs_the_installed_meeting_script(self):
        spec = ab.ENGINES["qwen-meeting"]
        runtime = f"{ab.SUPPORT}/Runtime/Qwen3ASR"
        # The paths QwenASRClient.swift resolves (venv/bin/python, qwen_transcribe.py, model/,
        # aligner/ under Runtime/Qwen3ASR) — not the dictation daemon.
        self.assertEqual(spec["python"], f"{runtime}/venv/bin/python")
        self.assertEqual(spec["script"], f"{runtime}/qwen_transcribe.py")
        self.assertEqual(spec["model"], f"{runtime}/model")
        self.assertEqual(spec["aligner"], f"{runtime}/aligner")

    def test_the_environment_carries_every_variable_the_app_forces(self):
        """Derived from `QwenASRClient.makeEnvironment`'s source rather than restated, so a
        variable the app starts forcing shows up here as a failure instead of as a bench that
        quietly runs a different environment."""
        with open(os.path.join(_REPO, "Sources", "WhisperCore", "QwenASRClient.swift"),
                  encoding="utf-8") as handle:
            source = handle.read()
        forced = dict(re.findall(r'environment\["(\w+)"\] = "([^"]*)"', source))
        self.assertIn("HF_HUB_OFFLINE", forced)  # the regex still reads the source at all
        self.assertIn("PATH", forced)
        environment = ab.helper_environment(ab.ENGINES["qwen-meeting"])
        for name, value in forced.items():
            if "\\(" in value:
                # An interpolation (PATH is `"/opt/homebrew/bin:/usr/local/bin:\(existingPath)"`):
                # the literal part before it is what the app forces; the rest is inherited.
                prefix = value.split("\\(", 1)[0]
                self.assertTrue((environment.get(name) or "").startswith(prefix), name)
            else:
                self.assertEqual(environment.get(name), value, name)

    def test_the_meeting_row_is_opt_in(self):
        """A control row, not a dictation engine: the default run still compares the two dictation
        helpers, and pays no per-clip model load it did not ask for."""
        self.assertNotIn("qwen-meeting", ab.DEFAULT_ENGINES)
        self.assertEqual(sorted(ab.DEFAULT_ENGINES), ["qwen3-asr-1.7b-8bit", "turbo"])


class MeetingRunTests(unittest.TestCase):
    @with_clip
    def test_automatic_reaches_the_helper_as_auto(self, clips):
        """The app sends `language.commandLineValue ?? "auto"`; dictation-ab's automatic default
        is `None`. They must meet at `auto`, or the row measures an instruction no meeting gets."""
        runner = Recorder(payload={"text": "x", "language": "en"})
        ab.run_meeting_engine("qwen-meeting", ab.ENGINES["qwen-meeting"], {"encs4": ENCS4},
                              verbose=False, language=None, runner=runner)
        command = runner.calls[0][0]
        self.assertEqual(command[command.index("--language") + 1], "auto")

    @with_clip
    def test_a_pinned_language_is_passed_through(self, clips):
        runner = Recorder(payload={"text": "x", "language": "en"})
        ab.run_meeting_engine("qwen-meeting", ab.ENGINES["qwen-meeting"], {"encs4": ENCS4},
                              verbose=False, language="English", runner=runner)
        command = runner.calls[0][0]
        self.assertEqual(command[command.index("--language") + 1], "English")

    @with_clip
    def test_the_argv_is_the_meeting_glue_s_with_the_clip(self, clips):
        spec = ab.ENGINES["qwen-meeting"]
        runner = Recorder(payload={"text": "x", "language": "en"})
        ab.run_meeting_engine("qwen-meeting", spec, {"encs4": ENCS4},
                              verbose=False, language=None, runner=runner)
        command, keywords = runner.calls[0]
        output = command[command.index("--output") + 1]
        self.assertEqual(command, ab.qwen_meeting_engine.meeting_engine_command(
            spec["python"], spec["script"], spec["model"], spec["aligner"],
            os.path.join(clips, "encs4.wav"), output, "auto"))
        self.assertEqual(keywords["env"].get("HF_HUB_OFFLINE"), "1")

    @with_clip
    def test_the_payload_becomes_the_row_words_scores(self, clips):
        """The F589 observation as a fixture: a half-transliterated name is DROPPED, the intact
        word beside it is kept, and the hypothesis text is the helper's, verbatim."""
        runner = Recorder(payload={"text": "I'll ping Wang老师 about the 作业 tonight.",
                                   "language": "en", "alignedItems": [],
                                   "alignmentWarning": None})
        result = ab.run_meeting_engine("qwen-meeting", ab.ENGINES["qwen-meeting"],
                                       {"encs4": ENCS4}, verbose=False, runner=runner)
        row = result["clips"][0]
        self.assertEqual(row["text"], "I'll ping Wang老师 about the 作业 tonight.")
        self.assertEqual(row["reported_language"], "en")
        self.assertIsNone(row["helper_error"])
        self.assertEqual(row["words"], [{"word": "王老师", "kept": False},
                                        {"word": "作业", "kept": True}])
        table = ab.word_table([result])
        self.assertIn("| Qwen3-ASR 1.7B (meeting path) | encs4 | 王老师 | DROPPED |", table)

    @with_clip
    def test_no_output_is_a_recorded_miss_with_the_helpers_words(self, clips):
        runner = Recorder(payload=None, stderr="Traceback…\nMemoryError")
        result = ab.run_meeting_engine("qwen-meeting", ab.ENGINES["qwen-meeting"],
                                       {"encs4": ENCS4}, verbose=False, runner=runner)
        row = result["clips"][0]
        self.assertEqual(row["text"], "")
        self.assertIn("MemoryError", row["helper_error"])
        self.assertEqual(row["error_rate"], 1.0)

    @with_clip
    def test_a_stale_output_from_the_previous_clip_is_not_read_as_this_clips(self, clips):
        """One work file serves every clip; a helper that dies before writing must not be
        credited with the previous clip's transcript."""
        open(os.path.join(clips, "encs5.wav"), "wb").close()
        references = {"encs4": ENCS4,
                      "encs5": {"lang": "encs", "text": "Our 预算 for Q4 is still under review.",
                                "words": ["预算"]}}
        calls = []

        def runner(command, **keywords):
            calls.append(command)
            if len(calls) == 1:
                with open(command[command.index("--output") + 1], "w", encoding="utf-8") as f:
                    json.dump({"text": "I'll ping 王老师 about the 作业 tonight.",
                               "language": "en"}, f, ensure_ascii=False)
            return FakeCompleted(stderr="died")

        result = ab.run_meeting_engine("qwen-meeting", ab.ENGINES["qwen-meeting"], references,
                                       verbose=False, runner=runner)
        second = result["clips"][1]
        self.assertEqual(second["clip"], "encs5")
        self.assertEqual(second["text"], "")
        self.assertIn("died", second["helper_error"])

    @with_clip
    def test_the_summary_table_renders_a_row_with_no_warm_cold_split(self, clips):
        """Every meeting clip is its own process, so there is no separate cold start to report;
        the table must say so rather than crash formatting a missing number."""
        runner = Recorder(payload={"text": "x", "language": "en"})
        result = ab.run_meeting_engine("qwen-meeting", ab.ENGINES["qwen-meeting"],
                                       {"encs4": ENCS4}, verbose=False, runner=runner)
        self.assertIn("Qwen3-ASR 1.7B (meeting path)", ab.table([result]))


if __name__ == "__main__":
    unittest.main()
