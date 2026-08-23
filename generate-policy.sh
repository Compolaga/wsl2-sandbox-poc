#!/usr/bin/env bash
# Genereert een lokale Windows-testpayload uit een bevestigde intake.
# Installeert niets.
set -uo pipefail
cd "$(dirname "$0")"
IN="${1:-}"
UIT="${2:-local/managed-settings.windows.generated.json}"
FORCE=()
[ "${3:-}" = "--force" ] && FORCE=(--force)
[ -n "$IN" ] || { echo "gebruik: ./generate-policy.sh local/policy-input.json [uitvoer.json] [--force]"; exit 2; }
./agent-gate.sh generate --intake "$IN" || exit 2
python3 tools/policy_generator.py "$IN" "$UIT" "${FORCE[@]}" || exit $?
./check-configs.sh "$UIT"
