#!/usr/bin/env python3
import tempfile
import unittest
import json
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
import sys

sys.path.insert(0, str(ROOT / "tools"))
from report_proof import build, main  # noqa: E402


class ReportProofTests(unittest.TestCase):
    def test_always_keeps_second_laptop_open(self):
        with tempfile.TemporaryDirectory() as td:
            root = Path(td)
            ev = root / "evidence" / "20260822-190000"
            ev.mkdir(parents=True)
            (ev / "samenvatting.txt").write_text(
                "mode:       normaal\ngeslaagd 22   gefaald 0\nexitcode:   0\n"
            )
            (ev / "AC-04.txt").write_text("ok\n")
            tekst = build(root, ev)
            self.assertIn("Tweede developer-laptop", tekst)
            self.assertNotIn("OQ-6", tekst)
            self.assertIn("- [ ]", tekst)
            self.assertIn("geen uitrolklaar bewijs", tekst)
            self.assertEqual(main(["--root", str(root), "--evidence", str(ev)]), 0)
            self.assertTrue((ev / "proof-matrix.md").is_file())
            inhoud = (ev / "proof-matrix.md").read_text()
            self.assertIn("Tweede developer-laptop", inhoud)
            self.assertIn("docs/VERIFICATION.md", inhoud)
            self.assertIn("niet gedraaid", inhoud)

    def test_prefers_structured_manifest_but_keeps_legacy_summary_compatible(self):
        with tempfile.TemporaryDirectory() as td:
            root = Path(td)
            ev = root / "evidence" / "20260823-190000"
            ev.mkdir(parents=True)
            (ev / "samenvatting.txt").write_text("mode: normaal\nexitcode: 1\n")
            (ev / "run.json").write_text(json.dumps({
                "schemaVersion": 1,
                "results": [{"id": "AC-04", "status": "ongeldig"}],
                "releaseGates": [{"id": "second-developer-laptop", "description": "Tweede developer-laptop gecontroleerd", "status": "open"}],
            }))
            tekst = build(root, ev)
            self.assertIn("| AC-04 |", tekst)
            self.assertIn("| ongeldig |", tekst)
            self.assertIn("- [ ] Tweede developer-laptop gecontroleerd", tekst)
            self.assertNotIn("OQ-6", tekst)


if __name__ == "__main__":
    unittest.main()
