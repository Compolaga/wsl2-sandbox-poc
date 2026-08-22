#!/usr/bin/env python3
import json
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
import sys

sys.path.insert(0, str(ROOT / "tools"))
from agent_gate import GateError, main, require_consent, require_green, require_intake, require_place  # noqa: E402


def schrijf(pad: Path, data: dict) -> None:
    pad.parent.mkdir(parents=True, exist_ok=True)
    pad.write_text(json.dumps(data, indent=2) + "\n")


class GateTests(unittest.TestCase):
    def setUp(self):
        self.td = Path(tempfile.mkdtemp())
        self.addCleanup(lambda: shutil.rmtree(self.td, ignore_errors=True))
        self.consent = {
            "askedVia": "AskUserQuestion",
            "confirmedAt": "2026-08-22T18:00:00+02:00",
            "wsl": False,
            "apt": True,
            "nodeClaude": True,
        }
        self.intake = {
            "askedVia": "AskUserQuestion",
            "confirmed": True,
            "confirmedAt": "2026-08-22T18:05:00+02:00",
            "bringMode": "copy",
            "bindApproved": False,
            "workspaces": [{"path": "/home/dev/work/a", "access": "read-write"}],
        }

    def maak_voorbereiding(self):
        staat = self.td / "local" / "beginstaat"
        staat.mkdir(parents=True, exist_ok=True)
        (staat / "dpkg.txt").write_text("ii  bubblewrap\n")
        schrijf(self.td / "local" / "snapshot.json", {"distro": "Ubuntu", "tar": r"C:\snap.tar"})
        (self.td / "local" / "rollback-roundtrip.ok").write_text("ok\n")

    def test_missing_consent_fails(self):
        with self.assertRaises(GateError):
            require_consent(self.td)

    def test_apt_refused_when_false(self):
        data = dict(self.consent)
        data["apt"] = False
        schrijf(self.td / "local" / "consent.json", data)
        with self.assertRaises(GateError):
            require_consent(self.td, "apt")

    def test_unconfirmed_intake_fails(self):
        schrijf(self.td / "local" / "policy-input.json", {**self.intake, "confirmed": False})
        with self.assertRaises(GateError):
            require_intake(self.td)

    def test_green_without_intake_fails(self):
        with self.assertRaises(GateError):
            require_green(self.td)
        self.assertEqual(main(["green", "--root", str(self.td)]), 2)

    def test_place_rejects_static_template_and_missing_red(self):
        schrijf(self.td / "local" / "consent.json", self.consent)
        schrijf(self.td / "local" / "policy-input.json", self.intake)
        with self.assertRaises(GateError) as ctx:
            require_place(self.td)
        self.assertIn("ontbreekt", str(ctx.exception))

    def test_place_requires_snapshot(self):
        schrijf(self.td / "local" / "consent.json", self.consent)
        schrijf(self.td / "local" / "policy-input.json", self.intake)
        with self.assertRaises(GateError) as ctx:
            require_place(self.td)
        self.assertIn("beginstaat", str(ctx.exception))

    def test_place_requires_red_and_matching_payload(self):
        schrijf(self.td / "local" / "consent.json", self.consent)
        schrijf(self.td / "local" / "policy-input.json", self.intake)
        self.maak_voorbereiding()
        payload = {"sandbox": {"filesystem": {"allowRead": ["/home/dev/work/a"]}}}
        schrijf(self.td / "local" / "managed-settings.windows.generated.json", payload)
        with self.assertRaises(GateError) as ctx:
            require_place(self.td)
        self.assertIn("nulmeting", str(ctx.exception))

        ev = self.td / "evidence" / "20260822-180000-red"
        ev.mkdir(parents=True)
        (ev / "samenvatting.txt").write_text(
            "mode:       nulmeting suite\nexitcode:   0\n"
        )
        require_place(self.td)

    def test_place_rejects_payload_missing_workspace(self):
        schrijf(self.td / "local" / "consent.json", self.consent)
        schrijf(self.td / "local" / "policy-input.json", self.intake)
        self.maak_voorbereiding()
        schrijf(
            self.td / "local" / "managed-settings.windows.generated.json",
            {"sandbox": {"filesystem": {"allowRead": ["~/repos"]}}},
        )
        ev = self.td / "evidence" / "20260822-180000-red"
        ev.mkdir(parents=True)
        (ev / "samenvatting.txt").write_text("mode:       nulmeting suite\nexitcode:   0\n")
        with self.assertRaises(GateError):
            require_place(self.td)

    def test_bring_workspace_refuses_ungated_bind_and_symlink(self):
        script = ROOT / "bring-workspace.sh"
        bind = subprocess.run(
            [str(script), "bind", r"C:\Users\x\src", "/home/dev/work/x"],
            cwd=ROOT,
            capture_output=True,
            text=True,
        )
        self.assertEqual(bind.returncode, 2)
        self.assertIn("--i-approved-bind", bind.stdout + bind.stderr)
        link = subprocess.run(
            [str(script), "symlink", r"C:\Users\x\src", "/home/dev/work/x"],
            cwd=ROOT,
            capture_output=True,
            text=True,
        )
        self.assertEqual(link.returncode, 2)
        self.assertIn("AC-06", link.stdout + link.stderr)

    def test_bind_requires_second_yes(self):
        schrijf(self.td / "local" / "policy-input.json", {**self.intake, "bringMode": "bind"})
        self.assertEqual(main(["bind", "--root", str(self.td)]), 2)
        schrijf(
            self.td / "local" / "policy-input.json",
            {**self.intake, "bringMode": "bind", "bindApproved": True},
        )
        self.assertEqual(main(["bind", "--root", str(self.td)]), 0)


if __name__ == "__main__":
    unittest.main()
