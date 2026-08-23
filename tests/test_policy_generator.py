#!/usr/bin/env python3
import json
import io
import subprocess
import sys
import tempfile
import unittest
from contextlib import redirect_stdout
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "tools"))
from policy_generator import IntakeError, generate, load_json, main, write_atomic  # noqa: E402
from policy_artifact import normalize_linux_path, validate_policy  # noqa: E402


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
                [str(ROOT / "scripts" / "policy" / "check-configs.sh"), str(doel)],
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
            self.assertTrue(out["sandbox"]["failIfUnavailable"])
            self.assertTrue(out["sandbox"]["filesystem"]["allowManagedReadPathsOnly"])

    def test_existing_security_lock_conflicts_fail_without_changing_output(self):
        conflicts = (
            (("sandbox", "failIfUnavailable"), False),
            (("sandbox", "allowUnsandboxedCommands"), True),
            (("sandbox", "filesystem", "allowManagedReadPathsOnly"), False),
            (("sandbox", "network", "allowManagedDomainsOnly"), False),
            (("wslInheritsWindowsSettings",), False),
            (("allowManagedMcpServersOnly",), False),
        )
        for keys, value in conflicts:
            with self.subTest(lock=".".join(keys)):
                with tempfile.TemporaryDirectory() as td:
                    td = Path(td)
                    existing = {}
                    current = existing
                    for key in keys[:-1]:
                        current = current.setdefault(key, {})
                    current[keys[-1]] = value
                    existing_path = td / "existing.json"
                    existing_path.write_text(json.dumps(existing))
                    intake = dict(self.intake)
                    intake["existingManagedSettings"] = str(existing_path)
                    intake_path = td / "intake.json"
                    intake_path.write_text(json.dumps(intake))
                    output_path = td / "generated.json"
                    original = '{"do-not-change": true}\n'
                    output_path.write_text(original)

                    stdout = io.StringIO()
                    with redirect_stdout(stdout):
                        rc = main([
                            str(intake_path),
                            str(output_path),
                            "--template", str(ROOT / "config" / "managed-settings.windows.json"),
                            "--force",
                        ])

                    self.assertEqual(rc, 2)
                    self.assertIn(".".join(keys), stdout.getvalue())
                    self.assertIn("verwacht", stdout.getvalue())
                    self.assertEqual(output_path.read_text(), original)

    def test_generator_and_validator_share_normalization_and_locks(self):
        intake = dict(self.intake)
        intake["workspaces"] = [{"path": "/home/dev/work/client-a/", "access": "read-write"}]
        out = generate(intake, self.template)
        self.assertIn(normalize_linux_path("/home/dev/work/client-a/"), out["sandbox"]["filesystem"]["allowRead"])
        self.assertEqual(validate_policy(out, windows=True, intake=intake), [])

        out["sandbox"]["network"]["allowManagedDomainsOnly"] = False
        errors = validate_policy(out, windows=True, intake=intake)
        self.assertTrue(any("allowManagedDomainsOnly" in error for error in errors))

        out = generate(intake, self.template)
        out["allowManagedMcpServersOnly"] = False
        errors = validate_policy(out, windows=True, intake=intake)
        self.assertTrue(any("allowManagedMcpServersOnly" in error for error in errors))


if __name__ == "__main__":
    unittest.main()
