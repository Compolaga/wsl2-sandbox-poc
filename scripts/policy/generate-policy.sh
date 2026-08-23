#!/usr/bin/env bash
# Genereert een lokale Windows-testpayload uit een bevestigde intake.
# Installeert niets.
set -uo pipefail
SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
source "$SCRIPT_DIR/../lib/repo-root.sh"
REPO_ROOT="$(sandbox_repo_root "$SCRIPT_DIR")" || exit $?
cd "$REPO_ROOT"
IN="${1:-}"
UIT="${2:-local/managed-settings.windows.generated.json}"
FORCE=()
[ "${3:-}" = "--force" ] && FORCE=(--force)
[ -n "$IN" ] || { echo "gebruik: ./bin/sandbox policy generate local/policy-input.json [uitvoer.json] [--force]"; exit 2; }
"$SCRIPT_DIR/agent-gate.sh" generate --intake "$IN" || exit 2
python3 tools/policy_generator.py "$IN" "$UIT" "${FORCE[@]}" || exit $?
"$SCRIPT_DIR/check-configs.sh" "$UIT"
