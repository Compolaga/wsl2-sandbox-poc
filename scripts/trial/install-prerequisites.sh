#!/usr/bin/env bash
# Installeert alleen clusters die in local/consent.json op true staan.
# Losse apt-get / npm install -g is een mislukte run.
set -uo pipefail
SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
source "$SCRIPT_DIR/../lib/repo-root.sh"
REPO_ROOT="$(sandbox_repo_root "$SCRIPT_DIR")" || exit $?
cd "$REPO_ROOT"

[ -f local/consent.json ] || {
  echo "FOUT: local/consent.json ontbreekt. Doorloop docs/HANDOFF.md vraag 1 via AskUserQuestion."
  echo "Kopieer templates/consent.example.json naar local/consent.json en zet alleen"
  echo "goedgekeurde clusters op true."
  exit 2
}

[ -f local/beginstaat/dpkg.txt ] || [ -f local/beginstaat/omgeving.txt ] || {
  echo "FOUT: local/beginstaat ontbreekt. Draai eerst ./bin/sandbox baseline, nog vóór apt."
  exit 2
}
[ -f local/snapshot.json ] || {
  echo "FOUT: local/snapshot.json ontbreekt. Geen WSL-snapshot betekent geen proef."
  exit 2
}

if ! command -v python3 >/dev/null; then
  if grep -q '"apt": true' local/consent.json; then
    sudo apt-get update
    sudo apt-get install -y --no-install-recommends python3
  else
    echo "FOUT: python3 ontbreekt en apt is niet goedgekeurd in local/consent.json."
    exit 2
  fi
fi

"$REPO_ROOT/scripts/policy/agent-gate.sh" install || exit 2
"$REPO_ROOT/scripts/policy/agent-gate.sh" voorbereiding || exit 2
python3 tools/trial_lifecycle.py plan install --root "$PWD" || exit 2

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

python3 tools/trial_lifecycle.py record install-started --root "$PWD" \
  --evidence local/consent.json --if-absent || exit 2

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
  "$REPO_ROOT/scripts/policy/agent-gate.sh" install-apt || exit 2
  sudo apt-get update
  sudo apt-get install -y --no-install-recommends bubblewrap socat python3 rsync
else
  echo "apt niet goedgekeurd; installeer bubblewrap/socat/python3/rsync niet."
fi

if cluster nodeClaude; then
  "$REPO_ROOT/scripts/policy/agent-gate.sh" install-node || exit 2
  if ! command -v npm >/dev/null; then
    echo "FOUT: npm ontbreekt. Installeer Node in de distro en draai dit script opnieuw."
    exit 2
  fi
  if command -v claude >/dev/null; then
    echo "claude staat er al: $(claude --version 2>/dev/null | head -1)"
    echo "Een te oude versie is een bevinding, geen stille upgrade. Zie A10 in docs/HANDOFF.md."
    echo "Alleen sandbox-runtime wordt nagekeken."
    npm install -g @anthropic-ai/sandbox-runtime
  else
    [ -d "$HOME/.claude" ] && cp -a "$HOME/.claude" "$HOME/.claude.voor-sandbox"
    [ -e "$HOME/.claude.json" ] && cp -p "$HOME/.claude.json" "$HOME/.claude.json.voor-sandbox"
    npm install -g @anthropic-ai/claude-code @anthropic-ai/sandbox-runtime
  fi
else
  echo "Node/Claude niet goedgekeurd; installeer ze niet."
fi

{
  echo "recordedAt: $(date -Iseconds)"
  echo "claude: $(claude --version 2>&1 | head -1 || true)"
  echo "bwrap: $(bwrap --version 2>&1 | head -1 || true)"
  echo "socat: $(command -v socat || true)"
} > local/install-completed.txt
python3 tools/trial_lifecycle.py record install-completed --root "$PWD" \
  --evidence local/install-completed.txt --if-absent || exit 2
echo "install-prereqs klaar. Log in met: claude auth login"
