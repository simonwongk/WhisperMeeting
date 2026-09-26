#!/usr/bin/env python3
"""Every script suite is run by the gate as `python3 <file>` — so a test defined *below* the file's
`if __name__ == "__main__": unittest.main()` line is never collected there: unittest.main() runs
and exits before the interpreter reaches the class. `python3 -m unittest` imports the module first
and does collect it, which is how three F512 tests passed standalone and were silently absent from
the gate (the gate said 15 where the module holds 18). Nothing may follow the guard."""

import glob
import os
import re
import unittest

TESTS_DIR = os.path.dirname(os.path.abspath(__file__))
GUARD = re.compile(r'^if __name__ == ["\']__main__["\']:')
DEFINITION = re.compile(r"^(class |def test_|    def test_)")


def definitions_below_the_main_guard(path):
    with open(path, encoding="utf-8") as handle:
        lines = handle.read().splitlines()
    guard_at = next((i for i, line in enumerate(lines) if GUARD.match(line)), None)
    if guard_at is None:
        return []
    return [
        f"{os.path.basename(path)}:{i + 1}: {line.strip()}"
        for i, line in enumerate(lines[guard_at + 1:], start=guard_at + 1)
        if DEFINITION.match(line)
    ]


class SuiteLayoutTests(unittest.TestCase):
    def test_no_test_is_defined_below_a_suite_main_guard(self):
        offenders = []
        for path in sorted(glob.glob(os.path.join(TESTS_DIR, "test_*.py"))):
            offenders.extend(definitions_below_the_main_guard(path))
        self.assertEqual(offenders, [], "defined after unittest.main(), so `python3 <file>` never runs them:\n"
                         + "\n".join(offenders))

    def test_the_check_sees_a_definition_below_the_guard(self):
        import tempfile
        with tempfile.NamedTemporaryFile("w", suffix="_test_x.py", delete=False) as handle:
            handle.write('import unittest\nif __name__ == "__main__":\n    unittest.main()\n\nclass Late(unittest.TestCase):\n    def test_x(self): pass\n')
            path = handle.name
        try:
            self.assertEqual(len(definitions_below_the_main_guard(path)), 2)
        finally:
            os.unlink(path)


if __name__ == "__main__":
    unittest.main(verbosity=2)
