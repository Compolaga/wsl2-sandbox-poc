#!/usr/bin/env bash
# Plaatst uitsluitend de gegenereerde payload. De statische template is geen bron.
set -uo pipefail
cd "$(dirname "$0")"

./agent-gate.sh place || exit 2

GEN="local/managed-settings.windows.generated.json"
[ -f "$GEN" ] || { echo "FOUT: $GEN ontbreekt."; exit 2; }

case "$GEN" in
  *config/managed-settings.windows.json)
    echo "FOUT: de statische template mag niet geplaatst worden."; exit 2 ;;
esac

command -v powershell.exe >/dev/null || {
  echo "FOUT: powershell.exe ontbreekt. Draai place-policy.ps1 vanuit een Windows-admin-PowerShell:"
  echo "  .\\place-policy.ps1 -Source <windows-pad-naar-generated.json>"
  exit 2
}

WIN_GEN="$(wslpath -w "$PWD/$GEN")"
WIN_PS1="$(wslpath -w "$PWD/place-policy.ps1")"
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "$WIN_PS1" -Source "$WIN_GEN"
echo "Als de kopie lukte: wsl --shutdown en open de distro opnieuw."
