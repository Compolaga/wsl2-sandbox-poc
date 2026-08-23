#!/usr/bin/env bash
# Schrijft en toont de bewijsmatrix. Eén groene run is geen vrijgave.
set -uo pipefail
cd "$(dirname "$0")"
EV="${1:-}"
if [ -z "$EV" ]; then
  EV="$(ls -1d evidence/[0-9]* 2>/dev/null | tail -n 1 || true)"
fi
[ -n "$EV" ] && [ -d "$EV" ] || { echo "FOUT: geef een evidence-map: ./report-proof.sh evidence/<stempel>"; exit 2; }
command -v python3 >/dev/null || { echo "FOUT: python3 ontbreekt."; exit 2; }
[ ! -f "$EV/results.tsv" ] || python3 tools/proof_ledger.py --evidence "$EV"
python3 tools/report_proof.py --evidence "$EV"
echo
echo "Eén groene run.sh is geen vrijgave. De tweede developer-laptop staat nog open."
