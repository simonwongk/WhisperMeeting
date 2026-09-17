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


class DeprecationNoiseTests(unittest.TestCase):
    """F248 — the MLX deprecation warning must not land inside the model's answer.

    Running `Scripts/qwen-chat` showed `Qwen> mx.metal.device_info is deprecated...` followed by
    the real reply, because `mlx_lm/generate.py:243` calls that deprecated function during
    generation — after the `Qwen> ` prompt has been written.

    Two measured facts shape the fix, and both contradict the ticket's own description:

    1. **It is on fd 2, not stdout.** The ticket proposes routing "library warnings away from
       stdout"; the message never went there. It interleaves in the terminal because both streams
       are the same terminal.
    2. **It is native, not a Python warning.** It escapes `contextlib.redirect_stderr` AND
       `warnings.catch_warnings` — printed from C++ straight to the file descriptor — so
       `warnings.filterwarnings`, the obvious fix, cannot suppress it at all.

    And the fact that makes a clean fix possible: it fires **once per process**, not per call. So it
    can be MOVED rather than suppressed — triggered during load where it reads as startup noise,
    with the redirect scoped to that one deliberate call so nothing real is ever hidden.
    """

    def _source(self):
        with open(_SCRIPT, encoding="utf-8") as handle:
            return handle.read()

    def test_the_warning_is_warmed_before_the_banner(self):
        source = self._source()
        self.assertLess(
            source.index("warm_device_info()"),
            source.index("Local Qwen chat \u2014 offline"),
        )

    def test_warming_suppresses_only_its_own_call(self):
        """The redirect must not span generation. Silencing fd 2 while the model runs would hide a
        real OOM or Metal failure, which is far worse than a cosmetic line."""
        source = self._source()
        body = source[source.index("def warm_device_info"):]
        body = body[:body.index("\ndef ", 1)]
        self.assertIn("dup2", body, "expected an fd-level redirect — the warning is native")
        self.assertIn("device_info", body)
        # Restored in a `finally`, so an exception inside cannot leave the process with stderr
        # pointing at /dev/null for the rest of the session.
        self.assertIn("finally", body)

    def test_warming_never_fails_the_launcher(self):
        """It exists to tidy one cosmetic line. If anything about it breaks — a future MLX without
        `metal`, a machine with no Metal at all — the chat must still start. Under system python3
        there is no mlx, so this test IS that case."""
        qwen_chat.warm_device_info()


if __name__ == "__main__":
    unittest.main(verbosity=2)
