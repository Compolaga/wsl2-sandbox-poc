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
from placement_gate import create_manifest, verify_manifest  # noqa: E402
from policy_artifact import generate, load_json  # noqa: E402


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

    def gegenereerde_payload(self):
        template = load_json(ROOT / "config" / "managed-settings.windows.json")
        return generate(self.intake, template)

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

    def test_generate_gate_validates_the_supplied_intake_not_the_default(self):
        schrijf(self.td / "local" / "policy-input.json", self.intake)
        other = self.td / "chosen-input.json"
        schrijf(other, {**self.intake, "confirmed": False})
        self.assertEqual(
            main(["generate", "--root", str(self.td), "--intake", str(other)]),
            2,
        )

        schrijf(self.td / "local" / "policy-input.json", {**self.intake, "confirmed": False})
        schrijf(other, self.intake)
        self.assertEqual(
            main(["generate", "--root", str(self.td), "--intake", str(other)]),
            0,
        )

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
        payload = self.gegenereerde_payload()
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
        payload = self.gegenereerde_payload()
        payload["sandbox"]["filesystem"]["allowRead"].remove("/home/dev/work/a")
        schrijf(self.td / "local" / "managed-settings.windows.generated.json", payload)
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

    def test_place_rejects_payload_that_weakens_a_lock(self):
        schrijf(self.td / "local" / "consent.json", self.consent)
        schrijf(self.td / "local" / "policy-input.json", self.intake)
        self.maak_voorbereiding()
        payload = self.gegenereerde_payload()
        payload["sandbox"]["allowUnsandboxedCommands"] = True
        schrijf(self.td / "local" / "managed-settings.windows.generated.json", payload)
        ev = self.td / "evidence" / "20260822-180000-red"
        ev.mkdir(parents=True)
        (ev / "samenvatting.txt").write_text("mode: nulmeting suite\nexitcode: 0\n")
        with self.assertRaisesRegex(GateError, "allowUnsandboxedCommands"):
            require_place(self.td)

    def maak_geldige_plaatsing(self):
        schrijf(self.td / "local" / "consent.json", self.consent)
        schrijf(self.td / "local" / "policy-input.json", self.intake)
        self.maak_voorbereiding()
        (self.td / "config").mkdir(parents=True, exist_ok=True)
        shutil.copy2(
            ROOT / "config" / "managed-settings.windows.json",
            self.td / "config" / "managed-settings.windows.json",
        )
        schrijf(
            self.td / "local" / "managed-settings.windows.generated.json",
            self.gegenereerde_payload(),
        )
        ev = self.td / "evidence" / "20260822-180000-red"
        ev.mkdir(parents=True)
        (ev / "samenvatting.txt").write_text("mode: nulmeting suite\nexitcode: 0\n")

    def test_manifest_binds_every_prerequisite_to_the_exact_payload(self):
        self.maak_geldige_plaatsing()
        manifest = create_manifest(self.td)
        expected = self.td / "local" / "managed-settings.windows.generated.json"
        self.assertEqual(verify_manifest(manifest), expected.resolve())
        data = json.loads(manifest.read_text())
        self.assertEqual(
            {entry["id"] for entry in data["files"]},
            {
                "consent", "intake", "policy", "template", "beginstaat",
                "snapshot", "rollback-roundtrip", "red-baseline",
            },
        )

    def test_placement_cli_creates_and_verifies_the_manifest(self):
        self.maak_geldige_plaatsing()
        manifest = self.td / "local" / "placement-manifest.json"
        create = subprocess.run(
            [
                sys.executable, str(ROOT / "tools" / "placement_gate.py"), "create",
                "--root", str(self.td), "--manifest", str(manifest),
            ],
            capture_output=True,
            text=True,
        )
        self.assertEqual(create.returncode, 0, create.stdout + create.stderr)
        verify = subprocess.run(
            [
                sys.executable, str(ROOT / "tools" / "placement_gate.py"), "verify",
                "--root", str(self.td), "--manifest", str(manifest), "--json",
            ],
            capture_output=True,
            text=True,
        )
        self.assertEqual(verify.returncode, 0, verify.stdout + verify.stderr)
        result = json.loads(verify.stdout)
        self.assertEqual(
            Path(result["artifact"]),
            (self.td / "local" / "managed-settings.windows.generated.json").resolve(),
        )
        self.assertEqual(len(result["sha256"]), 64)

    def test_manifest_rejects_payload_changed_after_attestation(self):
        self.maak_geldige_plaatsing()
        manifest = create_manifest(self.td)
        payload_path = self.td / "local" / "managed-settings.windows.generated.json"
        payload = json.loads(payload_path.read_text())
        payload["sandbox"]["allowUnsandboxedCommands"] = True
        schrijf(payload_path, payload)
        with self.assertRaisesRegex(GateError, "SHA-256 mismatch voor policy"):
            verify_manifest(manifest)

    def test_manifest_rejects_intake_changed_after_attestation(self):
        self.maak_geldige_plaatsing()
        manifest = create_manifest(self.td)
        schrijf(
            self.td / "local" / "policy-input.json",
            {**self.intake, "workspaces": [{"path": "/home/dev/work/b", "access": "read-write"}]},
        )
        with self.assertRaisesRegex(GateError, "SHA-256 mismatch voor intake"):
            verify_manifest(manifest)

    def test_direct_powershell_adapter_has_no_source_bypass(self):
        script = (ROOT / "place-policy.ps1").read_text()
        self.assertIn("[string]$Manifest", script)
        self.assertNotIn("[string]$Source", script)
        self.assertIn("placement_gate.py", script)
        self.assertIn("verify --root", script)


if __name__ == "__main__":
    unittest.main()
