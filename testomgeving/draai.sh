#!/usr/bin/env bash
# Draait de bestaande suite in de Linux-container. Alles wat we al hebben, ongewijzigd.
#
#   ./draai.sh nulmeting    geen policy: alles moet lekken (bewijst dat de tests kunnen falen)
#   ./draai.sh slice1       user settings
#   ./draai.sh slice2       managed settings in /etc/claude-code (de echte grens)
#   ./draai.sh shell        interactieve shell in de container
#
# De config-dir van je personal-profiel wordt read-only meegemount voor de authenticatie.
set -uo pipefail
cd "$(dirname "$0")/.."
sandbox="$(pwd)"
CFG="${CLAUDE_PROFILE_DIR:-$HOME/.claude-personal}"
[ -d "$CFG" ] || { echo "FOUT: $CFG bestaat niet. Zet CLAUDE_PROFILE_DIR."; exit 2; }

MODE="${1:-nulmeting}"
case "$MODE" in
  nulmeting) POLICY=""            ; ARG="--red" ;;
  slice1)    POLICY="slice1"      ; ARG=""      ;;
  slice2)    POLICY="slice2"      ; ARG=""      ;;
  shell)     POLICY=""            ; ARG=""      ;;
  *) echo "onbekende modus: $MODE"; exit 2 ;;
esac

# De suite komt read-only binnen; evidence/ schrijft naar een aparte gemounte map, zodat de
# uitkomst op de Mac blijft staan als de container weg is.
mkdir -p "$sandbox/evidence"

BOOT='set -e
cp -r /repo /home/dev/repo && chmod -R u+w /home/dev/repo
mkdir -p /home/dev/.claude
cp -r /cfg/. /home/dev/.claude/ 2>/dev/null || true
case "'"$POLICY"'" in
  slice1) cp /home/dev/repo/config/settings.slice1.json /home/dev/.claude/settings.json ;;
  slice2) sudo mkdir -p /etc/claude-code
          sudo cp /home/dev/repo/config/managed-settings.linux.json /etc/claude-code/managed-settings.json ;;
esac
echo "== omgeving =="
echo "  claude:  $(claude --version 2>&1 | head -1)"
echo "  bwrap:   $(command -v bwrap) $(bwrap --version 2>/dev/null)"
echo "  socat:   $(command -v socat)"
echo "  seccomp: $(npm ls -g @anthropic-ai/sandbox-runtime 2>/dev/null | sed -n 2p | tr -d " ")"
echo "  userns:  $(sysctl -n kernel.apparmor_restrict_unprivileged_userns 2>/dev/null || echo "n.v.t.")"
echo
cd /home/dev/repo
./fixture.sh >/dev/null 2>&1 || { echo "fixture faalde"; ./fixture.sh; exit 2; }
set +e
./run.sh '"$ARG"'
rc=$?
cp -r /home/dev/repo/evidence/. /evidence/ 2>/dev/null || true
exit $rc'

if [ "$MODE" = "shell" ]; then
  exec docker run --rm -it \
    -v "$sandbox:/repo:ro" -v "$CFG:/cfg:ro" -v "$sandbox/evidence:/evidence" \
    wsl2-sandbox bash -lc 'cp -r /repo /home/dev/repo && chmod -R u+w /home/dev/repo && mkdir -p /home/dev/.claude && cp -r /cfg/. /home/dev/.claude/ && cd /home/dev/repo && exec bash'
fi

docker run --rm \
  -v "$sandbox:/repo:ro" -v "$CFG:/cfg:ro" -v "$sandbox/evidence:/evidence" \
  wsl2-sandbox bash -lc "$BOOT"
