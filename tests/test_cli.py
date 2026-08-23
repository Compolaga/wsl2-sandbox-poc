import os
import stat
import subprocess
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
CLI = ROOT / "bin" / "sandbox"


def run(command, *, cwd, env=None):
    return subprocess.run(
        [str(part) for part in command],
        cwd=cwd,
        env=env,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        check=False,
    )


class SandboxCliContractTests(unittest.TestCase):
    def test_help_works_outside_repository(self):
        with tempfile.TemporaryDirectory() as outside:
            result = run([CLI, "--help"], cwd=outside)

        self.assertEqual(result.returncode, 0)
        self.assertIn("bin/sandbox <commando>", result.stdout)
        self.assertEqual(result.stderr, "")

    def test_unknown_command_has_distinct_usage_error(self):
        result = run([CLI, "does-not-exist"], cwd=ROOT)

        self.assertEqual(result.returncode, 2)
        self.assertEqual(result.stdout, "")
        self.assertIn("onbekend of onvolledig commando", result.stderr)
        self.assertIn("bin/sandbox <commando>", result.stderr)

    def test_workspace_preserves_direct_script_contract_from_external_cwd(self):
        direct = run([ROOT / "scripts/policy/bring-workspace.sh"], cwd=ROOT)
        with tempfile.TemporaryDirectory() as outside:
            via_cli = run([CLI, "workspace"], cwd=outside)

        self.assertEqual(via_cli.returncode, direct.returncode)
        self.assertEqual(via_cli.stdout, direct.stdout)
        self.assertEqual(via_cli.stderr, direct.stderr)

    def test_policy_generate_preserves_direct_script_contract(self):
        direct = run([ROOT / "scripts/policy/generate-policy.sh"], cwd=ROOT)
        with tempfile.TemporaryDirectory() as outside:
            via_cli = run([CLI, "policy", "generate"], cwd=outside)

        self.assertEqual(via_cli.returncode, direct.returncode)
        self.assertEqual(via_cli.stdout, direct.stdout)
        self.assertEqual(via_cli.stderr, direct.stderr)

    def test_proof_preserves_arguments_output_and_exit_code(self):
        missing = "evidence/cli-contract-does-not-exist"
        direct = run([ROOT / "scripts/policy/report-proof.sh", missing], cwd=ROOT)
        with tempfile.TemporaryDirectory() as outside:
            via_cli = run([CLI, "proof", missing], cwd=outside)

        self.assertEqual(via_cli.returncode, direct.returncode)
        self.assertEqual(via_cli.stdout, direct.stdout)
        self.assertEqual(via_cli.stderr, direct.stderr)

    def test_dispatch_passes_arguments_and_exit_code_without_rewriting(self):
        with tempfile.TemporaryDirectory() as temp:
            fake_root = Path(temp) / "repo"
            (fake_root / "bin").mkdir(parents=True)
            (fake_root / "scripts" / "lib").mkdir(parents=True)
            (fake_root / "bin" / "sandbox").write_bytes(CLI.read_bytes())
            (fake_root / "scripts" / "lib" / "repo-root.sh").write_bytes(
                (ROOT / "scripts" / "lib" / "repo-root.sh").read_bytes()
            )
            (fake_root / "scripts" / "trial").mkdir()
            stub = fake_root / "scripts" / "trial" / "run-tests.sh"
            stub.write_text(
                "#!/usr/bin/env bash\n"
                "printf 'arg=<%s>\\n' \"$@\"\n"
                "printf 'stderr-contract\\n' >&2\n"
                "exit 37\n"
            )
            for path in (fake_root / "bin" / "sandbox", stub):
                path.chmod(path.stat().st_mode | stat.S_IXUSR)

            outside = Path(temp) / "outside"
            outside.mkdir()
            result = run(
                [fake_root / "bin" / "sandbox", "test", "argument met spaties", "*"],
                cwd=outside,
            )

        self.assertEqual(result.returncode, 37)
        self.assertEqual(result.stdout, "arg=<argument met spaties>\narg=<*>\n")
        self.assertEqual(result.stderr, "stderr-contract\n")

    def test_windows_command_fails_cleanly_without_powershell(self):
        env = os.environ.copy()
        with tempfile.TemporaryDirectory():
            # Keep only the base POSIX tools used during startup. PowerShell is
            # installed outside these paths on supported macOS development hosts.
            env["PATH"] = "/usr/bin:/bin"
            result = run(
                ["/bin/bash", CLI, "snapshot", "create"], cwd=ROOT, env=env
            )

        self.assertEqual(result.returncode, 2)
        self.assertIn("vereist Windows PowerShell of PowerShell 7", result.stderr)

    def test_lifecycle_interface_is_available_outside_repository(self):
        with tempfile.TemporaryDirectory() as outside:
            result = run([CLI, "status"], cwd=outside)

        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("fase:", result.stdout)


if __name__ == "__main__":
    unittest.main()
