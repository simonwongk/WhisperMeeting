#!/usr/bin/env python3
"""Regression tests for the static ticket dashboard generator."""
from __future__ import annotations

import importlib.util
import sys
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch


ROOT = Path(__file__).resolve().parents[2]
GENERATOR = ROOT / "Scripts" / "generate-tickets-dashboard.py"
QUALITY_GATE = ROOT / "Scripts" / "quality-check.sh"


def load_generator():
    spec = importlib.util.spec_from_file_location("ticket_dashboard_generator", GENERATOR)
    assert spec and spec.loader
    module = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = module
    spec.loader.exec_module(module)
    return module


class TicketDashboardGeneratorTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temp_directory = tempfile.TemporaryDirectory()
        self.docs = Path(self.temp_directory.name)
        self.generator = load_generator()
        self.generator.ROOT = self.docs.parent
        self.generator.DOCS = self.docs
        self.generator.DASHBOARD = self.docs / "tickets-dashboard.html"
        (self.docs / "TICKETS.md").write_text(
            """# Ticket board

**Next free ID: `F203`.**

# Open tickets

## In progress

### F200 — Keep the dashboard current

- **Status:** in-progress
- **Owner:** /agent
- **Severity:** medium
- **Area:** docs
- **Filed:** 2026-08-03 by /agent

**Problem.** The rendered board is stale.

**Impact.** People cannot see the current work.

**Verification.** The snapshot matches its sources.

## Ready to claim

### F201 — Make the workflow visible

- **Status:** open
- **Owner:** —
- **Severity:** low
- **Area:** docs
- **Filed:** 2026-08-03 by /agent

**Problem.** The board needs an action-first view.

**Impact.** Work is harder to find.

**Verification.** The dashboard groups active work.
""",
            encoding="utf-8",
        )
        (self.docs / "NEEDS_HUMAN.md").write_text(
            """# Needs human

### F202 — Confirm the visual check

- **Status:** needs-human
- **Owner:** —
- **Severity:** low
- **Area:** ui
- **Filed:** 2026-08-03 by /agent

**What I need from you** (~1 minute):

1. Open the app.
2. Confirm the status color changes.

Say "all good" when both checks pass.
Otherwise, describe what changed.

**Problem.** A human needs to look at the rendered transition.

**Impact.** The visual behavior is not confirmed.

**Verification.** Report the observed result.
""",
            encoding="utf-8",
        )
        (self.docs / "TICKET_LOG.md").write_text(
            """# Ticket log

## F199 — Prior work

- **Outcome:** fixed
- **Closed:** 2026-08-02 by /agent
""",
            encoding="utf-8",
        )

    def tearDown(self) -> None:
        self.temp_directory.cleanup()

    def test_check_mode_detects_a_stale_snapshot_without_rewriting_it(self) -> None:
        self.generator.DASHBOARD.write_text("stale snapshot\n", encoding="utf-8")

        with patch.object(sys, "argv", [str(GENERATOR), "--check"]):
            with self.assertRaises(SystemExit) as exit_info:
                self.generator.main()

        self.assertIn("stale", str(exit_info.exception.code))
        self.assertEqual(self.generator.DASHBOARD.read_text(encoding="utf-8"), "stale snapshot\n")

    def test_dashboard_puts_human_actions_first_and_links_to_the_source(self) -> None:
        with patch.object(sys, "argv", [str(GENERATOR)]):
            self.generator.main()

        rendered = self.generator.DASHBOARD.read_text(encoding="utf-8")
        self.assertIn("Needs your action", rendered)
        self.assertIn("Open the app.", rendered)
        self.assertIn('href="NEEDS_HUMAN.md"', rendered)
        self.assertIn("Open NEEDS_HUMAN.md; find F202", rendered)
        self.assertIn("</ol><p>Say", rendered)
        self.assertIn("Say &quot;all good&quot; when both checks pass. Otherwise, describe what changed.", rendered)
        self.assertIn("blocked tickets", rendered)
        self.assertLess(rendered.index("Needs your action"), rendered.index("In progress"))

    def test_previews_do_not_stop_at_a_lowercase_abbreviation(self) -> None:
        preview = self.generator.first_sentence(
            "A chip tap filters vs. triggers row selection for the meeting. A later sentence follows."
        )
        self.assertIn("triggers row selection", preview)
        self.assertNotIn("A later sentence", preview)

    def test_dependency_hint_does_not_claim_an_unresolved_dependency_is_resolved(self) -> None:
        hint = self.generator.dependency_hint("A ticket", {"dependency": "F201 is pending"})
        self.assertEqual(hint, "Depends on F201")

    def test_validator_enforces_open_owner_and_closed_ticket_metadata(self) -> None:
        board = (self.docs / "TICKETS.md").read_text(encoding="utf-8")
        (self.docs / "TICKETS.md").write_text(
            board.replace("### F201 — Make the workflow visible\n\n- **Status:** open\n- **Owner:** —", "### F201 — Make the workflow visible\n\n- **Status:** open\n- **Owner:** /agent"),
            encoding="utf-8",
        )
        _, errors = self.generator.parse_active_file("TICKETS.md")
        self.assertTrue(any("open but its owner is not —" in error for error in errors))

        (self.docs / "TICKET_LOG.md").write_text(
            "# Ticket log\n\n## F199 — Prior work\n\n- **Outcome:** unsupported\n",
            encoding="utf-8",
        )
        _, errors = self.generator.parse_closed()
        self.assertTrue(any("invalid outcome" in error for error in errors))
        self.assertTrue(any("no **Closed:**" in error for error in errors))

    def test_validator_caps_the_human_action_queue(self) -> None:
        source = (self.docs / "NEEDS_HUMAN.md").read_text(encoding="utf-8")
        entry = source[source.index("### F202"):]
        for number in range(203, 208):
            source += "\n" + entry.replace("F202", f"F{number}")
        (self.docs / "NEEDS_HUMAN.md").write_text(source, encoding="utf-8")
        (self.docs / "TICKETS.md").write_text(
            (self.docs / "TICKETS.md").read_text(encoding="utf-8").replace("`F203`", "`F208`"),
            encoding="utf-8",
        )

        with self.assertRaisesRegex(ValueError, "at most 5"):
            self.generator.load_validated()

    def test_quality_gate_checks_the_dashboard_and_both_python_suites_before_swift(self) -> None:
        source = QUALITY_GATE.read_text(encoding="utf-8")
        swift_tests = source.index("swift test")
        for command in (
            "python3 Scripts/generate-tickets-dashboard.py --check",
            "python3 Scripts/tests/test_qwen_transcribe.py",
            "python3 Scripts/tests/test_generate_tickets_dashboard.py",
        ):
            self.assertIn(command, source)
            self.assertLess(source.index(command), swift_tests)


if __name__ == "__main__":
    unittest.main()
