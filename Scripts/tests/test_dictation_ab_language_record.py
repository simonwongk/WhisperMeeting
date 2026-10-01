#!/usr/bin/env python3
"""`dictation-ab.py --json` records the language setting each run used (F631).

Run: python3 Scripts/tests/test_dictation_ab_language_record.py

The refine-stage bench (`Tests/WhisperCoreTests/RefineStageBenchTests.swift`) reads these JSON
files and labels each condition, F589-style, as "<engine>, Automatic" or "<engine>, English". The
setting cannot be recovered from the rows: under Automatic, Whisper reports the language it
detected ("en"), and pinned to English it echoes "English", so a row's `reported_language` names
an outcome, not the instruction. Only the run knows what it sent, so the run must say.

`None` is the app's "Detect automatically", written as JSON null. It is not the same as a missing
key, which is how a file written before F631 reads, and the Swift side keeps the two apart.
"""

import importlib.util
import json
import os
import sys
import tempfile
import unittest

_HERE = os.path.dirname(os.path.abspath(__file__))
_REPO = os.path.abspath(os.path.join(_HERE, "..", ".."))
# A hyphenated file name cannot be imported by name, hence the spec.
_spec = importlib.util.spec_from_file_location(
    "dictation_ab", os.path.join(_REPO, "Scripts", "bench", "dictation-ab.py"))
ab = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(ab)

REFERENCE = {"lang": "encs", "text": "I'll ping 王老师 about the 作业 tonight.",
             "words": ["王老师", "作业"]}

# A stand-in dictation daemon: the handshake, then one reply per request on the JSON-lines wire
# `run_engine` speaks. It echoes the request's language, as the real helpers echo a pinned one.
FAKE_DAEMON = (
    "import json, sys\n"
    "print(json.dumps({'ready': True}), flush=True)\n"
    "for line in sys.stdin:\n"
    "    request = json.loads(line)\n"
    "    print(json.dumps({'text': 'x', 'language': request.get('language')}), flush=True)\n"
)


class Workspace:
    """A temporary CLIPS directory with one (empty) clip and a fake daemon script."""

    def __enter__(self):
        self.directory = tempfile.TemporaryDirectory()
        root = self.directory.name
        open(os.path.join(root, "encs4.wav"), "wb").close()
        with open(os.path.join(root, "references.json"), "w", encoding="utf-8") as handle:
            json.dump({"encs4": REFERENCE}, handle, ensure_ascii=False)
        self.daemon = os.path.join(root, "fake_daemon.py")
        with open(self.daemon, "w", encoding="utf-8") as handle:
            handle.write(FAKE_DAEMON)
        self.previous_clips = ab.CLIPS
        ab.CLIPS = root
        return self

    def __exit__(self, *exc):
        ab.CLIPS = self.previous_clips
        self.directory.cleanup()

    def daemon_spec(self):
        return {"label": "Fake daemon", "python": sys.executable, "script": self.daemon,
                "args": [], "env": {}}


class FakeCompleted:
    stdout, stderr, returncode = "", "", 0


def writing_runner(command, **keywords):
    """Stands in for `subprocess.run` on the meeting script: writes its `--output` payload."""
    with open(command[command.index("--output") + 1], "w", encoding="utf-8") as handle:
        json.dump({"text": "x", "language": "en"}, handle)
    return FakeCompleted()


class DictationRunTests(unittest.TestCase):
    def test_automatic_is_recorded_as_none_not_left_out(self):
        with Workspace() as space:
            result = ab.run_engine("fake", space.daemon_spec(), {"encs4": REFERENCE},
                                   verbose=False, language=None)
        self.assertIn("language", result)
        self.assertIsNone(result["language"])

    def test_a_pinned_language_is_recorded_as_sent(self):
        with Workspace() as space:
            result = ab.run_engine("fake", space.daemon_spec(), {"encs4": REFERENCE},
                                   verbose=False, language="English")
        self.assertEqual(result["language"], "English")


class MeetingRunTests(unittest.TestCase):
    def test_the_meeting_row_records_its_setting_too(self):
        with Workspace():
            automatic = ab.run_meeting_engine("qwen-meeting", ab.ENGINES["qwen-meeting"],
                                              {"encs4": REFERENCE}, verbose=False,
                                              language=None, runner=writing_runner)
            english = ab.run_meeting_engine("qwen-meeting", ab.ENGINES["qwen-meeting"],
                                            {"encs4": REFERENCE}, verbose=False,
                                            language="English", runner=writing_runner)
        self.assertIn("language", automatic)
        self.assertIsNone(automatic["language"])
        self.assertEqual(english["language"], "English")


class JsonOutputTests(unittest.TestCase):
    def test_the_json_file_carries_the_setting(self):
        """End to end through `main()`, which is what writes the file the Swift bench reads."""
        with Workspace() as space:
            previous_engines, previous_argv = ab.ENGINES, sys.argv
            ab.ENGINES = {"fake": space.daemon_spec()}
            output = os.path.join(space.directory.name, "raw.json")
            sys.argv = ["dictation-ab.py", "--engine", "fake", "--language", "English",
                        "--json", output, "--quiet"]
            try:
                ab.main()
            finally:
                ab.ENGINES, sys.argv = previous_engines, previous_argv
            with open(output, encoding="utf-8") as handle:
                written = json.load(handle)
        self.assertEqual([run["language"] for run in written], ["English"])


if __name__ == "__main__":
    unittest.main(verbosity=2)
