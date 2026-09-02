#!/usr/bin/env python3
"""Unit tests for the offline local-Qwen Terminal chat helper (F204)."""

import importlib.util
import os
import subprocess
import tempfile
import unittest


_SCRIPT = os.path.join(os.path.dirname(__file__), "..", "qwen_chat.py")
_LAUNCHER = os.path.join(os.path.dirname(__file__), "..", "qwen-chat")
_spec = importlib.util.spec_from_file_location("qwen_chat", _SCRIPT)
qwen_chat = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(qwen_chat)


class OfflineEnvironmentTests(unittest.TestCase):
    def test_forces_hugging_face_and_transformers_offline_without_mutating_input(self):
        original = {"HOME": "/example", "HF_HUB_OFFLINE": "0"}

        environment = qwen_chat.offline_environment(original)

        self.assertEqual(original["HF_HUB_OFFLINE"], "0")
        self.assertEqual(environment["HF_HUB_OFFLINE"], "1")
        self.assertEqual(environment["TRANSFORMERS_OFFLINE"], "1")
        self.assertEqual(environment["HOME"], "/example")


class RuntimeValidationTests(unittest.TestCase):
    def test_launcher_explains_a_missing_runtime_before_attempting_python(self):
        completed = subprocess.run(
            [_LAUNCHER],
            env={"PATH": os.environ["PATH"], "HOME": "/private/tmp/qwen-chat-no-runtime"},
            text=True,
            capture_output=True,
            check=False,
        )

        self.assertEqual(completed.returncode, 2)
        self.assertIn("Install Local Model", completed.stderr)

    def test_reports_each_missing_runtime_part(self):
        with tempfile.TemporaryDirectory() as directory:
            missing = qwen_chat.missing_runtime_parts(directory)

        self.assertEqual(missing, ["venv/bin/python", "model"])

    def test_accepts_the_minimal_managed_runtime_layout(self):
        with tempfile.TemporaryDirectory() as directory:
            python = os.path.join(directory, "venv", "bin", "python")
            os.makedirs(os.path.dirname(python))
            with open(python, "w", encoding="utf-8"):
                pass
            os.chmod(python, 0o755)
            os.mkdir(os.path.join(directory, "model"))

            missing = qwen_chat.missing_runtime_parts(directory)

        self.assertEqual(missing, [])


class ConversationTests(unittest.TestCase):
    def test_bounds_retained_exchanges_and_keeps_roles_in_order(self):
        history = []
        history = qwen_chat.append_exchange(history, "one", "first", max_turns=2)
        history = qwen_chat.append_exchange(history, "two", "second", max_turns=2)
        history = qwen_chat.append_exchange(history, "three", "third", max_turns=2)

        self.assertEqual(
            history,
            [
                {"role": "user", "content": "two"},
                {"role": "assistant", "content": "second"},
                {"role": "user", "content": "three"},
                {"role": "assistant", "content": "third"},
            ],
        )


if __name__ == "__main__":
    unittest.main(verbosity=2)
