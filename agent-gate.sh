#!/usr/bin/env bash
# Weigert de volgende stap als AskUserQuestion-antwoorden niet zijn vastgelegd.
set -uo pipefail
cd "$(dirname "$0")"
CMD="${1:-}"
[ -n "$CMD" ] || { echo "gebruik: ./agent-gate.sh consent|intake|install|generate|bind|place|green"; exit 2; }

case "$CMD" in
  consent|install|install-wsl|install-apt|install-node)
    [ -f local/consent.json ] || {
      echo "FOUT: local/consent.json ontbreekt."
      echo "Stel eerst de AskUserQuestion-vragen uit HANDOFF.md (vraag 1) en schrijf de"
      echo "antwoorden weg. Voorbeeld: templates/consent.example.json"
      exit 2
    }
    ;;
  intake|generate|bind|green)
    [ -f local/policy-input.json ] || {
      echo "FOUT: local/policy-input.json ontbreekt."
      echo "Vraag de workspaces via AskUserQuestion (HANDOFF.md vraag 2) en bevestig ze."
      echo "Voorbeeld: templates/policy-input.example.json"
      exit 2
    }
    ;;
  place)
    [ -f local/consent.json ] || { echo "FOUT: local/consent.json ontbreekt."; exit 2; }
    [ -f local/policy-input.json ] || { echo "FOUT: local/policy-input.json ontbreekt."; exit 2; }
    ;;
esac

command -v python3 >/dev/null || {
  echo "FOUT: python3 ontbreekt. Als apt is goedgekeurd: ./install-prereqs.sh"
  exit 2
}
python3 tools/agent_gate.py "$@"
