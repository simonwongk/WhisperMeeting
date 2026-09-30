#!/usr/bin/env python3
"""`Scripts/rehearse-recovery.sh` is run for real, in every mode, into a throwaway TMPDIR (F550).

Run: python3 Scripts/tests/test_rehearse_recovery.py

Nothing ran the rehearsal before this file, which is how F550 went unseen: `--keep` performs the
by-hand restore BEFORE it keeps the directory, so the library it hands over is already repaired. A
responder who followed RECOVERY.md and launched WhisperMeet against it got two healthy meetings, no
read-only banner and no Recover Library button, which is nothing to practise on.

`--keep-damaged` is the mode that stops before the restore and leaves the damage the app detects.
The app-side half — that WhisperMeet really opens that directory read-only, and that the restore steps
RECOVERY.md gives bring both meetings back — is `RecoveryRehearsalLibraryTests` in the Swift suite,
which runs this same script.

The script writes only under `mktemp -d "${TMPDIR:-/tmp}/…"`, so pointing TMPDIR at a fresh
directory confines every mode to it, and a mode that is supposed to clean up can be checked by
listing that directory afterwards.
"""

import json
import os
import re
import shutil
import struct
import subprocess
import tempfile
import unittest

REPO = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
SCRIPT = os.path.join(REPO, "Scripts", "rehearse-recovery.sh")
FIRST_MEETING = "11111111-1111-4111-8111-111111111111"


class RehearseRecoveryTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp(prefix="rehearse-recovery-test-")

    def tearDown(self):
        shutil.rmtree(self.tmp, ignore_errors=True)

    def run_script(self, *args):
        environment = dict(os.environ, TMPDIR=self.tmp)
        return subprocess.run(
            ["zsh", SCRIPT, *args], env=environment, capture_output=True, text=True, timeout=60
        )

    def kept_root(self, result):
        match = re.search(r"^Rehearsal library: (.+)$", result.stdout, re.MULTILINE)
        self.assertIsNotNone(match, result.stdout + result.stderr)
        root = match.group(1)
        self.assertTrue(root.startswith(self.tmp), f"{root} escaped TMPDIR {self.tmp}")
        return root

    def read(self, root, name):
        with open(os.path.join(root, name), encoding="utf-8") as handle:
            return handle.read()

    def test_default_mode_verifies_the_by_hand_restore_and_cleans_up(self):
        result = self.run_script()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("2 meetings are back", result.stdout)
        self.assertEqual(os.listdir(self.tmp), [], "the default mode must remove its directory")

    def test_keep_hands_over_the_library_the_script_already_restored(self):
        # Pinned so the difference between the two keep modes is stated, not assumed: `--keep` is
        # the by-hand rehearsal's result, and is healthy by design.
        result = self.run_script("--keep")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        root = self.kept_root(result)
        self.assertEqual(len(json.loads(self.read(root, "meetings.json"))), 2)
        self.assertTrue(os.path.exists(os.path.join(root, "meetings.json.before-restore")))
        # Its library is healthy, so it must not tell the responder to recover it, and it must say
        # which mode does.
        self.assertNotIn("It opens read-only", result.stdout)
        self.assertIn("Use --keep-damaged to practise Recover Library", result.stdout)

    def test_keep_damaged_leaves_the_damage_the_app_detects(self):
        result = self.run_script("--keep-damaged")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        root = self.kept_root(result)
        self.assertTrue(os.path.isdir(root), "--keep-damaged must keep its directory")

        # The incident shape, unrepaired: both live copies are `[]` and no restore happened.
        self.assertEqual(self.read(root, "meetings.json"), "[]")
        self.assertEqual(self.read(root, "meetings.backup.json"), "[]")
        self.assertFalse(os.path.exists(os.path.join(root, "meetings.json.before-restore")),
                         "--keep-damaged must stop before the by-hand restore")
        self.assertNotIn("meetings are back", result.stdout)

        generations = sorted(os.listdir(os.path.join(root, "meetings.history")))
        self.assertEqual(len(generations), 3, generations)

        # An empty index is only suspicious beside a FINALIZED recording (MeetingStore's
        # suspect-empty check), so the folder must hold a WAV whose header the app can parse and
        # whose declared data is really on disk — a stub would leave the library opening healthy.
        wav = os.path.join(root, "Recordings", FIRST_MEETING, "meeting.wav")
        with open(wav, "rb") as handle:
            data = handle.read()
        self.assertEqual(data[0:4], b"RIFF")
        (riff_size,) = struct.unpack("<I", data[4:8])
        self.assertEqual(riff_size, len(data) - 8)
        self.assertEqual(data[8:16], b"WAVEfmt ")
        channels, rate, byte_rate, block_align, bits = struct.unpack("<HIIHH", data[22:36])
        self.assertEqual(data[36:40], b"data")
        (declared,) = struct.unpack("<I", data[40:44])
        self.assertGreater(declared, 0)
        self.assertEqual(byte_rate, rate * channels * bits // 8)
        self.assertEqual(len(data), 44 + declared, "the declared data must be on disk")

        self.assertIn("Recover Library", result.stdout)
        self.assertIn(f'WHISPERMEET_LIBRARY="{root}"', result.stdout)

    def test_generation_names_carry_the_apps_store_fingerprint(self):
        # The golden values `storeFingerprintMatchesItsPublishedGoldenValues` pins for
        # `StoreFingerprint.of`. The rehearsal named its generations with a SHA-256 prefix, which
        # the app reads as "bytes do not match the name" and refuses to restore.
        import sys
        sys.path.insert(0, os.path.join(REPO, "Scripts"))
        from store_fingerprint import fingerprint
        goldens = [
            (b"", "3e4b04065d2477ff"),
            (b"a", "0cfa8263a6f0cdd2"),
            (bytes(range(31)), "a4f0f937f661e633"),
            (bytes(range(32)), "cf39be82c81c31de"),
            (bytes(range(100)), "34b6bd87828b245b"),
            (b'[{"id":"A","title":"Quarterly review"}]', "9899e4e313d81d5e"),
        ]
        for payload, expected in goldens:
            self.assertEqual(fingerprint(payload), expected, payload)

        result = self.run_script("--keep-damaged")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        history = os.path.join(self.kept_root(result), "meetings.history")
        for name in os.listdir(history):
            with open(os.path.join(history, name), "rb") as handle:
                self.assertEqual(name.split("-")[2], fingerprint(handle.read()) + ".json", name)

    def test_an_unknown_argument_is_refused_rather_than_run_as_the_default(self):
        # A typo such as `--keep-damage` used to run the default mode, which restores and then
        # deletes the directory — so the responder found nothing to open and no error saying why.
        result = self.run_script("--keep-damage")
        self.assertNotEqual(result.returncode, 0, result.stdout)
        self.assertIn("--keep-damage", result.stderr)
        self.assertEqual(os.listdir(self.tmp), [], "a refused run must not build a library")


if __name__ == "__main__":
    unittest.main(verbosity=2)
