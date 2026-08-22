#!/usr/bin/env python3
import json
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "tools"))
from policy_generator import IntakeError, generate, load_json, write_atomic  # noqa: E402


class GeneratorTests(unittest.TestCase):
    def setUp(self):
        self.template = load_json(ROOT / "config/managed-settings.windows.json")
        self.intake = {
            "askedVia": "AskUserQuestion",
            "confirmed": True,
            "workspaces": [
                {"path": "/home/dev/work/client-a", "access": "read-write", "contents": ["repo"]},
                {"path": "/home/dev/work/reference", "access": "read-only", "contents": ["docs"]},
            ],
            "protectedPaths": [
                {"path": "/home/dev/work/client-a/secrets", "reason": "secrets"},
                {"path": "/home/dev/.ssh", "reason": "keys"},
            ],
            "allowedDomains": ["pkgs.example.test"],
        }

    def test_happy_path(self):
        out = generate(self.intake, self.template)
        fs = out["sandbox"]["filesystem"]
        self.assertIn("/home/dev/work/client-a", fs["allowRead"])
        self.assertIn("/home/dev/work/reference", fs["allowRead"])
        self.assertIn("/home/dev/work/client-a", fs["allowWrite"])
        self.assertNotIn("/home/dev/work/reference", fs["allowWrite"])
        self.assertIn("/home/dev/work/client-a/secrets", fs["denyRead"])
        self.assertIn("/home/dev/.ssh", fs["denyRead"])
        self.assertIn("Read(//home/dev/work/client-a/secrets/**)", out["permissions"]["deny"])
        self.assertIn("pkgs.example.test", out["sandbox"]["network"]["allowedDomains"])
        self.assertTrue(out["sandbox"]["failIfUnavailable"])
        self.assertFalse(out["sandbox"]["allowUnsandboxedCommands"])
        self.assertTrue(out["sandbox"]["filesystem"]["allowManagedReadPathsOnly"])
        self.assertTrue(out["wslInheritsWindowsSettings"])
        self.assertIn("~/repos", out["sandbox"]["filesystem"]["allowRead"])
        self.assertIn("~/repos", out["sandbox"]["filesystem"]["allowWrite"])

    def test_rejects_unconfirmed_intake(self):
        intake = dict(self.intake)
        intake["confirmed"] = False
        with self.assertRaises(IntakeError):
            generate(intake, self.template)
        del intake["confirmed"]
        with self.assertRaises(IntakeError):
            generate(intake, self.template)

    def test_rejects_mnt_and_root(self):
        for pad in ("/", "~", "/home", "/mnt/c/Users/dev/src"):
            intake = {
                "askedVia": "AskUserQuestion",
                "confirmed": True,
                "workspaces": [{"path": pad, "access": "read-write"}],
            }
            with self.assertRaises(IntakeError):
                generate(intake, self.template)

    def test_mnt_needs_double_confirmation(self):
        intake = {
            "askedVia": "AskUserQuestion",
            "confirmed": True,
            "allowWindowsMounts": True,
            "workspaces": [{"path": "/mnt/c/Users/dev/src", "access": "read-write"}],
        }
        with self.assertRaises(IntakeError):
            generate(intake, self.template)
        intake["allowWindowsMountsConfirmed"] = True
        out = generate(intake, self.template)
        self.assertIn("/mnt/c/Users/dev/src", out["sandbox"]["filesystem"]["allowRead"])

    def test_no_partial_file_on_error(self):
        with tempfile.TemporaryDirectory() as td:
            doel = Path(td) / "out.json"
            with self.assertRaises(IntakeError):
                data = generate({"workspaces": [{"path": "/", "access": "read-write"}]}, self.template)
                write_atomic(doel, data, False)
            self.assertFalse(doel.exists())

    def test_force_required(self):
        out = generate(self.intake, self.template)
        with tempfile.TemporaryDirectory() as td:
            doel = Path(td) / "out.json"
            write_atomic(doel, out, False)
            with self.assertRaises(IntakeError):
                write_atomic(doel, out, False)
            write_atomic(doel, out, True)

    def test_check_configs_accepts_generated(self):
        out = generate(self.intake, self.template)
        with tempfile.TemporaryDirectory() as td:
            doel = Path(td) / "payload.json"
            write_atomic(doel, out, False)
            rc = subprocess.run(
                [str(ROOT / "check-configs.sh"), str(doel)],
                cwd=ROOT,
                capture_output=True,
                text=True,
            )
            self.assertEqual(rc.returncode, 0, rc.stdout + rc.stderr)

    def test_merge_keeps_unknown_keys(self):
        with tempfile.TemporaryDirectory() as td:
            bestaand = Path(td) / "bestaand.json"
            payload = {
                "cleanupPeriodDays": 14,
                "allowManagedPermissionRulesOnly": True,
                "permissions": {"deny": ["Read(//**/OneDrive*/**)"]},
                "allowedMcpServers": [{"serverUrl": "https://mcp.example.test"}],
            }
            bestaand.write_text(json.dumps(payload))
            intake = dict(self.intake)
            intake["existingManagedSettings"] = str(bestaand)
            out = generate(intake, self.template)
            self.assertEqual(out["cleanupPeriodDays"], 14)
            self.assertIn("Read(//**/OneDrive*/**)", out["permissions"]["deny"])
            self.assertEqual(out["allowedMcpServers"][0]["serverUrl"], "https://mcp.example.test")


if __name__ == "__main__":
    unittest.main()
