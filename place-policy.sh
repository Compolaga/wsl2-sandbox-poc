#!/usr/bin/env bash
# Plaatst uitsluitend de gegenereerde payload. De statische template is geen bron.
set -uo pipefail
cd "$(dirname "$0")"

MANIFEST="local/placement-manifest.json"
python3 tools/placement_gate.py create --root "$PWD" --manifest "$MANIFEST" || exit $?
python3 tools/placement_gate.py verify --root "$PWD" --manifest "$MANIFEST" >/dev/null || exit $?
python3 tools/trial_lifecycle.py plan place --root "$PWD" || exit $?

command -v powershell.exe >/dev/null || {
  echo "FOUT: powershell.exe ontbreekt. Draai place-policy.ps1 vanuit een Windows-admin-PowerShell:"
  echo "  .\\place-policy.ps1 -Manifest <windows-pad-naar-placement-manifest.json>"
  exit 2
}

WIN_MANIFEST="$(wslpath -w "$PWD/$MANIFEST")"
WIN_PS1="$(wslpath -w "$PWD/place-policy.ps1")"
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "$WIN_PS1" -Manifest "$WIN_MANIFEST"
echo "Als de kopie lukte: wsl --shutdown en open de distro opnieuw."
