#!/usr/bin/env bash
# Spiegelbeeld van de laptopproef, in omgekeerde volgorde.
# Haalt nooit pakketten weg zolang de policy nog een sandbox eist.
set -uo pipefail
cd "$(dirname "$0")"

echo "== teardown: eerst bewijs, dan policy, pas daarna de rest =="

# 1. Bewijs uit de clone, vóór iemand de clone wist.
WIN_BEWIJS=""
if [ -n "${WSL_DISTRO_NAME:-}" ] && command -v wslpath >/dev/null; then
  WIN_HOME="$(wslpath -u "$(cmd.exe /c 'echo %USERPROFILE%' 2>/dev/null | tr -d '\r')" 2>/dev/null || true)"
  if [ -n "$WIN_HOME" ]; then
    WIN_BEWIJS="$WIN_HOME/poc-bewijs-$(date +%Y%m%d)"
  fi
fi
if [ -z "$WIN_BEWIJS" ]; then
  WIN_BEWIJS="$HOME/poc-bewijs-$(date +%Y%m%d)"
fi
if [ -d evidence ] && [ -n "$(ls -A evidence 2>/dev/null)" ]; then
  mkdir -p "$WIN_BEWIJS"
  cp -a evidence/. "$WIN_BEWIJS/"
  echo "bewijs gekopieerd naar $WIN_BEWIJS"
  echo "Daarin staan lokale paden. Niet naar een publieke repo."
else
  echo "LET OP: geen evidence/ gevonden om te kopiëren."
fi

# 2. Policy moet eraf zijn. Anders is bwrap-purge AC-14 als blijvende staat.
POLICY_ACTIEF=0
for cfg in "/mnt/c/Program Files/ClaudeCode/managed-settings.json" \
           /etc/claude-code/managed-settings.json; do
  [ -f "$cfg" ] || continue
  python3 - "$cfg" <<'PY' && POLICY_ACTIEF=1
import json, sys
try:
    d = json.load(open(sys.argv[1]))
except Exception:
    sys.exit(1)
sb = d.get("sandbox") or {}
sys.exit(0 if sb.get("enabled") and sb.get("failIfUnavailable") else 1)
PY
done

if [ "$POLICY_ACTIEF" -eq 1 ]; then
  echo
  echo "STOP. Er staat nog een policy die een sandbox eist."
  echo "Haal die eerst weg met rollback-policy.ps1 in een Windows-admin-PowerShell,"
  echo "draai wsl --shutdown, en controleer dat claude weer start."
  echo "bwrap, socat of Node nu weghalen maakt Claude Code permanent onstartbaar (AC-14)."
  exit 2
fi

if ! command -v claude >/dev/null; then
  echo "LET OP: claude ontbreekt. Controleer of dat zo hoorde vóór de proef."
else
  if claude --version >/dev/null 2>&1; then
    echo "claude start nog. Goed: de policy is geen val meer."
  else
    echo "LET OP: claude start niet. Stop met pakketten weghalen tot dat is opgelost."
  fi
fi

# 3. Fixture, niet teardown.
if [ -x ./fixture.sh ]; then
  ./fixture.sh --clean || echo "LET OP: fixture.sh --clean gaf een fout."
fi

echo
echo "fixture.sh --clean is klaar. Dat is geen teardown. Nog te doen, met de hand:"
echo "  - ~/.claude/settings.json terug (VERIFICATIE.md § Opruimen)"
echo "  - PoC-paden uit ~/.claude.json"
echo "  - ~/.claude/.credentials.json als je op een ander account bent ingelogd"
echo "  - lege ~/probe-a ~/probe-b, zelf aangemaakt ~/repos, deze clone"
echo "  - apt-cache debs; pakketten alleen weg als de beginstaat dat zegt"
echo "  - snapshot herstellen als de distro te ver is afgeweken: herstel-snapshot.ps1"
echo
echo "Zelfcontrole tegen local/beginstaat/ (of ~/poc-beginstaat-*):"
if [ -f local/beginstaat/dpkg.txt ]; then
  echo "  dpkg-was:     local/beginstaat/dpkg.txt"
  echo "  claude-was:   local/beginstaat/versies.txt"
  echo "  auth-was:     local/beginstaat/auth.txt"
else
  echo "  GEEN beginstaat gevonden. Teardown is dan archeologie."
fi
echo
echo "Laat een tweede paar ogen de beginstaat naast de machine leggen."
echo "Zeg niet dat er is opgeruimd tot die ronde klaar is."
