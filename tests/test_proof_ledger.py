#!/usr/bin/env python3
import json
import re
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
import sys

sys.path.insert(0, str(ROOT / "tools"))
from proof_ledger import build_manifest, load_catalog, render_console, write_manifest  # noqa: E402


class ProofLedgerTests(unittest.TestCase):
    def make_root(self, base: Path) -> Path:
        (base / "specs").mkdir()
        (base / "specs" / "acceptance-catalog.json").write_text(
            (ROOT / "specs" / "acceptance-catalog.json").read_text()
        )
        return base

    def test_catalog_dependencies_are_valid_and_oq6_is_not_a_gate(self):
        catalog = load_catalog()
        ids = {item["id"] for item in catalog["acceptanceCriteria"]}
        self.assertIn("AC-09b", ids)
        self.assertNotIn("OQ-6", {gate["id"] for gate in catalog["releaseGates"]})
        self.assertEqual(
            next(item for item in catalog["acceptanceCriteria"] if item["id"] == "AC-04")["dependsOn"],
            ["AC-09b"],
        )
        run_ids = set(re.findall(r"^(?:check|skip|handmatig) (AC-[0-9]+[a-z]?)\b", (ROOT / "run.sh").read_text(), re.MULTILINE))
        self.assertTrue(run_ids)
        self.assertEqual(run_ids - ids, set())

    def test_remote_measurement_package_includes_ledger_dependencies(self):
        script = (ROOT / "testomgeving" / "ronde2-meting.sh").read_text()
        for required in (
            "tools/agent_gate.py",
            "tools/policy_artifact.py",
            "tools/proof_ledger.py",
            "tools/report_proof.py",
            "tools/placement_gate.py",
            "tools/trial_lifecycle.py",
            "specs/acceptance-catalog.json",
        ):
            self.assertIn(required, script)

    def test_manifest_preserves_results_and_release_gates(self):
        with tempfile.TemporaryDirectory() as td:
            root = self.make_root(Path(td))
            evidence = root / "evidence" / "20260823-120000"
            evidence.mkdir(parents=True)
            (evidence / "environment.txt").write_text(
                "verwacht:   2 tests: AC-04 AC-09b\n"
            )
            (evidence / "samenvatting.txt").write_text(
                "run:        20260823-120000\nmode:       normaal\n"
                "geslaagd 2   gefaald 0\nexitcode:   0\n"
            )
            (evidence / "results.tsv").write_text(
                "AC-04\tpass\tRead geblokkeerd\nAC-09b\tpass\tRead toegestaan\n"
            )
            manifest = build_manifest(root, evidence)
            self.assertEqual(manifest["exitCode"], 0)
            self.assertFalse(manifest["partial"])
            self.assertEqual(manifest["expected"], ["AC-04", "AC-09b"])
            self.assertEqual(manifest["counts"]["pass"], 2)
            self.assertEqual(manifest["results"][0]["dependsOn"], ["AC-09b"])
            self.assertTrue(all(gate["status"] == "open" for gate in manifest["releaseGates"]))
            console = render_console(manifest)
            self.assertIn("geslaagd 2", console)
            self.assertIn("exitcode:   0", console)
            target = write_manifest(root, evidence)
            self.assertEqual(json.loads(target.read_text()), manifest)

    def test_failure_summary_overrides_stale_raw_pass(self):
        with tempfile.TemporaryDirectory() as td:
            root = self.make_root(Path(td))
            evidence = root / "evidence" / "run"
            evidence.mkdir(parents=True)
            (evidence / "samenvatting.txt").write_text(
                "mode:       normaal\nexitcode:   1\n-- niet in orde --\n"
                "  AC-04: Read - ONGELDIG, AC-09b niet groen\n"
            )
            (evidence / "results.tsv").write_text("AC-04\tpass\tRead geblokkeerd\n")
            result = build_manifest(root, evidence)["results"][0]
            self.assertEqual(result["status"], "ongeldig")
            self.assertIn("AC-09b", result["reason"])

    def test_last_status_transition_wins(self):
        with tempfile.TemporaryDirectory() as td:
            root = self.make_root(Path(td))
            evidence = root / "evidence" / "run"
            evidence.mkdir(parents=True)
            (evidence / "samenvatting.txt").write_text("mode: normaal\nexitcode: 1\n")
            (evidence / "results.tsv").write_text(
                "AC-04\tbezig\tRead\nAC-04\tpass\tRead\nAC-04\tongeldig\tRead\n"
            )
            manifest = build_manifest(root, evidence)
            self.assertEqual(len(manifest["results"]), 1)
            self.assertEqual(manifest["results"][0]["status"], "ongeldig")
            self.assertEqual(manifest["counts"]["ongeldig"], 1)

    def test_unknown_result_id_is_rejected(self):
        with tempfile.TemporaryDirectory() as td:
            root = self.make_root(Path(td))
            evidence = root / "evidence" / "run"
            evidence.mkdir(parents=True)
            (evidence / "samenvatting.txt").write_text("mode: normaal\nexitcode: 0\n")
            (evidence / "results.tsv").write_text("AC-999\tpass\tonbekend\n")
            with self.assertRaisesRegex(ValueError, "onbekende AC-ids"):
                build_manifest(root, evidence)


if __name__ == "__main__":
    unittest.main()
