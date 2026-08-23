#!/usr/bin/env bash
# Schrijft en toont de bewijsmatrix. Eén groene run is geen vrijgave.
set -uo pipefail
SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
source "$SCRIPT_DIR/../lib/repo-root.sh"
REPO_ROOT="$(sandbox_repo_root "$SCRIPT_DIR")" || exit $?
cd "$REPO_ROOT"
EV="${1:-}"
if [ -z "$EV" ]; then
  EV="$(ls -1d evidence/[0-9]* 2>/dev/null | tail -n 1 || true)"
fi
[ -n "$EV" ] && [ -d "$EV" ] || { echo "FOUT: geef een evidence-map: ./bin/sandbox proof evidence/<stempel>"; exit 2; }
command -v python3 >/dev/null || { echo "FOUT: python3 ontbreekt."; exit 2; }
[ ! -f "$EV/results.tsv" ] || python3 tools/proof_ledger.py --evidence "$EV"
python3 tools/report_proof.py --evidence "$EV"
echo
echo "Eén groene bin/sandbox test is geen vrijgave. De tweede developer-laptop staat nog open."
