#!/usr/bin/env python3
import json
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
import sys

sys.path.insert(0, str(ROOT / "tools"))
from trial_lifecycle import LifecycleError, load_journal, plan, record, status  # noqa: E402


class TrialLifecycleTests(unittest.TestCase):
    def setUp(self):
        self.td = Path(tempfile.mkdtemp())
        self.addCleanup(lambda: shutil.rmtree(self.td, ignore_errors=True))
        (self.td / "local").mkdir()
        (self.td / "local" / "beginstaat").mkdir()
        (self.td / "local" / "beginstaat" / "omgeving.txt").write_text("before\n")
        (self.td / "local" / "snapshot.json").write_text("{}\n")
    def event_evidence(self, event: str) -> str:
        if event in {"placement-started", "policy-placed", "rollback-started"}:
            path = self.td / "local" / "placement-manifest.json"
            path.write_text("{}\n")
            return "local/placement-manifest.json"
        if event == "verification-recorded":
            path = self.td / "evidence" / "run" / "run.json"
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(json.dumps({
                "schemaVersion": 1, "partial": False, "exitCode": 0, "results": []
            }) + "\n")
            return "evidence/run/run.json"
        path = self.td / "local" / f"{event}.txt"
        if event == "policy-removed":
            path.write_text("rollback-selfcheck OK\n")
        elif event == "runtime-verified":
            path.write_text("claude: 1.0\npolicy: niet actief\n")
        else:
            path.write_text("bewijs\n")
        return f"local/{event}.txt"

    def add(self, event: str, evidence: str = "local/event.txt"):
        chosen = self.event_evidence(event) if evidence == "local/event.txt" else evidence
        with patch("trial_lifecycle.verify_manifest", return_value=self.td / "local" / "policy.json"):
            return record(self.td, event, chosen)

    def test_safe_transitions_and_resume_status(self):
        self.add("placement-started")
        self.assertEqual(status(self.td)["phase"], "placement-incomplete")
        with self.assertRaisesRegex(LifecycleError, "Inspecteer"):
            plan(self.td, "verify")
        self.add("policy-placed")
        self.assertEqual(status(self.td)["phase"], "policy-placed")
        plan(self.td, "verify")
        self.add("verification-recorded")
        self.add("rollback-started")
        self.assertEqual(status(self.td)["phase"], "rollback-incomplete")
        plan(self.td, "rollback")
        self.add("policy-removed")
        self.assertEqual(status(self.td)["phase"], "policy-removed")
        with self.assertRaisesRegex(LifecycleError, "geblokkeerd"):
            plan(self.td, "cleanup")
        self.add("runtime-verified")
        self.assertEqual(status(self.td)["phase"], "cleanup-ready")
        self.assertTrue(plan(self.td, "cleanup")["allowed"])

    def test_policy_must_be_removed_before_cleanup(self):
        self.add("placement-started")
        self.add("policy-placed")
        self.add("rollback-started")
        with self.assertRaisesRegex(LifecycleError, "rollback-policy"):
            plan(self.td, "cleanup")
        with self.assertRaisesRegex(LifecycleError, "policy-removed"):
            self.add("runtime-verified")

    def test_invalid_order_is_rejected(self):
        with self.assertRaisesRegex(LifecycleError, "placement-started"):
            self.add("policy-placed")
        with self.assertRaisesRegex(LifecycleError, "policy-placed"):
            self.add("rollback-started")

    def test_changed_or_missing_evidence_invalidates_journal(self):
        entry = self.add("install-started")
        evidence = self.td / entry["evidence"]
        evidence.write_text("gemanipuleerd\n")
        with self.assertRaisesRegex(LifecycleError, "gewijzigd"):
            load_journal(self.td)
        evidence.unlink()
        with self.assertRaisesRegex(LifecycleError, "ontbreekt"):
            load_journal(self.td)

    def test_tampered_hash_chain_is_rejected(self):
        self.add("install-started")
        journal = self.td / "local" / "trial-lifecycle.jsonl"
        entry = json.loads(journal.read_text())
        entry["event"] = "install-completed"
        journal.write_text(json.dumps(entry) + "\n")
        with self.assertRaisesRegex(LifecycleError, "hashketen"):
            load_journal(self.td)

    def test_preparation_allows_install_plan(self):
        self.assertTrue(plan(self.td, "install")["allowed"])
        self.add("install-started")
        self.add("install-completed")
        with self.assertRaisesRegex(LifecycleError, "al voltooid"):
            plan(self.td, "install")
        (self.td / "local" / "snapshot.json").unlink()
        with self.assertRaisesRegex(LifecycleError, "snapshot"):
            plan(self.td, "install")

    def test_verification_requires_full_green_run_manifest(self):
        self.add("placement-started")
        self.add("policy-placed")
        path = self.td / "evidence" / "run" / "run.json"
        path.parent.mkdir(parents=True)
        path.write_text(json.dumps({
            "schemaVersion": 1, "partial": True, "exitCode": 0, "results": []
        }) + "\n")
        with self.assertRaisesRegex(LifecycleError, "niet volledig groen"):
            self.add("verification-recorded", "evidence/run/run.json")

    def test_rollback_requires_selfcheck_log(self):
        self.add("placement-started")
        self.add("policy-placed")
        self.add("rollback-started")
        bad = self.td / "local" / "bad-rollback.log"
        bad.write_text("transcript zonder eindcontrole\n")
        with self.assertRaisesRegex(LifecycleError, "rollbackbewijs"):
            self.add("policy-removed", "local/bad-rollback.log")

    def test_platform_adapters_use_the_lifecycle_interface(self):
        expected = {
            "install-prereqs.sh": ("plan install", "record install-started", "record install-completed"),
            "place-policy.ps1": ("plan place", "record placement-started", "record policy-placed"),
            "rollback-policy.ps1": ("plan rollback", "record rollback-started", "record policy-removed"),
            "teardown.sh": ("lifecycle_cleanup_gate",),
            "run.sh": ("plan verify",),
            "inventaris.sh": ("record beginstate-recorded",),
            "snapshot.ps1": ("record snapshot-recorded",),
            "rollback-roundtrip.ps1": ("record rollback-route-tested",),
        }
        for name, fragments in expected.items():
            text = (ROOT / name).read_text()
            for fragment in fragments:
                self.assertIn(fragment, text, f"{name} mist {fragment}")

    def run_teardown_gate(self) -> subprocess.CompletedProcess:
        command = (
            'source "$1"; lifecycle_cleanup_gate "$2" "$3" "Claude Code 1.0"'
        )
        return subprocess.run(
            [
                "bash", "-c", command, "test-shell",
                str(ROOT / "tools" / "teardown_lifecycle.sh"),
                str(self.td),
                str(ROOT / "tools" / "trial_lifecycle.py"),
            ],
            capture_output=True,
            text=True,
        )

    def test_legacy_teardown_without_journal_keeps_old_route(self):
        result = self.run_teardown_gate()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("legacy teardown", result.stdout)
        self.assertIn("handmatig met de beginstaat", result.stdout)
        self.assertFalse((self.td / "local" / "runtime-after-rollback.txt").exists())

    def test_teardown_with_journal_records_runtime_and_requires_cleanup_plan(self):
        self.add("placement-started")
        self.add("policy-placed")
        self.add("rollback-started")
        self.add("policy-removed")
        result = self.run_teardown_gate()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertNotIn("legacy teardown", result.stdout)
        self.assertIn("runtime-verified", result.stdout)
        self.assertIn("cleanup is veilig", result.stdout)
        self.assertIn("runtime-verified", status(self.td)["events"])

    def test_teardown_with_incomplete_journal_fails_closed(self):
        self.add("placement-started")
        self.add("policy-placed")
        result = self.run_teardown_gate()
        self.assertEqual(result.returncode, 2, result.stdout + result.stderr)
        self.assertIn("policy-removed", result.stdout)


if __name__ == "__main__":
    unittest.main()
