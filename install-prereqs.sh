#!/usr/bin/env bash
# Installeert alleen clusters die in local/consent.json op true staan.
# Losse apt-get / npm install -g is een mislukte run.
set -uo pipefail
cd "$(dirname "$0")"

[ -f local/consent.json ] || {
  echo "FOUT: local/consent.json ontbreekt. Doorloop HANDOFF.md vraag 1 via AskUserQuestion."
  echo "Kopieer templates/consent.example.json naar local/consent.json en zet alleen"
  echo "goedgekeurde clusters op true."
  exit 2
}

if ! command -v python3 >/dev/null; then
  if grep -q '"apt": true' local/consent.json; then
    sudo apt-get update
    sudo apt-get install -y python3
  else
    echo "FOUT: python3 ontbreekt en apt is niet goedgekeurd in local/consent.json."
    exit 2
  fi
fi

./agent-gate.sh install || exit 2

if [ "${1:-}" = "--dry-run" ]; then
  python3 - <<'PY'
import json
d = json.load(open("local/consent.json"))
print("zou doen:")
print("  wsl:       ", "alleen signaleren; WSL installeer je vanuit Windows" if d.get("wsl") else "overslaan")
print("  apt:       ", "bubblewrap socat python3 rsync" if d.get("apt") else "overslaan")
print("  nodeClaude:", "claude-code + sandbox-runtime" if d.get("nodeClaude") else "overslaan")
PY
  exit 0
fi

cluster() { python3 -c "import json,sys; d=json.load(open('local/consent.json')); sys.exit(0 if d.get(sys.argv[1]) is True else 1)" "$1"; }

if cluster wsl; then
  if [ -z "${WSL_DISTRO_NAME:-}" ]; then
    echo "WSL is goedgekeurd, maar dit script draait niet in een distro."
    echo "Installeer of upgrade WSL vanuit een Windows-admin-PowerShell, daarna hier verder."
    echo "  wsl --install -d Ubuntu"
    exit 2
  fi
  echo "WSL-distro is er al: $WSL_DISTRO_NAME"
fi

if cluster apt; then
  ./agent-gate.sh install-apt || exit 2
  sudo apt-get update
  sudo apt-get install -y bubblewrap socat python3 rsync
else
  echo "apt niet goedgekeurd; installeer bubblewrap/socat/python3/rsync niet."
fi

if cluster nodeClaude; then
  ./agent-gate.sh install-node || exit 2
  if ! command -v npm >/dev/null; then
    echo "FOUT: npm ontbreekt. Installeer Node in de distro en draai dit script opnieuw."
    exit 2
  fi
  npm install -g @anthropic-ai/claude-code @anthropic-ai/sandbox-runtime
else
  echo "Node/Claude niet goedgekeurd; installeer ze niet."
fi

echo "install-prereqs klaar. Log in met: claude auth login"
