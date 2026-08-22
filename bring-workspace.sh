#!/usr/bin/env bash
# Haalt een Windows-map de WSL-Linux-home in. Standaard kopiëren.
# Bind alleen met --i-approved-bind én bindApproved in de intake.
# Geen symlink naar /mnt: die volgt de sandbox als omweg (AC-06).
set -uo pipefail
cd "$(dirname "$0")"

gebruik() {
  cat <<'EOF'
gebruik:
  ./bring-workspace.sh 'C:\Users\naam\src\project' /home/dev/work/project
  ./bring-workspace.sh copy 'C:\Users\naam\src\project' /home/dev/work/project
  ./bring-workspace.sh bind 'C:\Users\naam\src\project' /home/dev/work/project --i-approved-bind

Zonder modus is de actie altijd copy. Bind is geen gelijkwaardig alternatief:
alleen na een tweede AskUserQuestion, bindApproved: true in local/policy-input.json,
en de vlag --i-approved-bind.

Symlink van het Linux-pad naar /mnt/c is bewust niet beschikbaar.
EOF
  exit 2
}

MODUS=""
WIN=""
LINUX=""
BIND_VLAG=""

if [ "${1:-}" = "copy" ] || [ "${1:-}" = "bind" ] || [ "${1:-}" = "symlink" ] || [ "${1:-}" = "link" ] || [ "${1:-}" = "ln" ]; then
  MODUS="$1"
  WIN="${2:-}"
  LINUX="${3:-}"
  BIND_VLAG="${4:-}"
elif [ "$#" -eq 2 ]; then
  MODUS="copy"
  WIN="$1"
  LINUX="$2"
else
  gebruik
fi

[ -n "$WIN" ] && [ -n "$LINUX" ] || gebruik

case "$MODUS" in
  copy) ;;
  bind)
    if [ "$BIND_VLAG" != "--i-approved-bind" ]; then
      echo "FOUT: bind alleen met --i-approved-bind, en alleen als local/policy-input.json"
      echo "bindApproved: true heeft na een tweede AskUserQuestion. Standaard is copy."
      exit 2
    fi
    ./agent-gate.sh bind || exit 2
    ;;
  symlink|link|ln)
    echo "FOUT: symlink naar /mnt is verboden (AC-06)."
    exit 2
    ;;
  *) gebruik ;;
esac

[ -n "${WSL_DISTRO_NAME:-}" ] || { echo "FOUT: draai dit in de WSL2-distro."; exit 2; }

SRC="$(wslpath -u "$WIN" 2>/dev/null || true)"
[ -n "$SRC" ] && [ -d "$SRC" ] || { echo "FOUT: Windows-pad niet gevonden: $WIN"; exit 2; }
case "$LINUX" in
  /mnt|/*mnt*) echo "FOUT: doel moet een Linux-pad zijn, niet onder /mnt."; exit 2 ;;
  /|/home|/root) echo "FOUT: doel is te breed."; exit 2 ;;
esac
if [ -e "$LINUX" ] && [ -n "$(ls -A "$LINUX" 2>/dev/null)" ]; then
  echo "FOUT: $LINUX bestaat al en is niet leeg. Kies een leeg doel of ruim eerst op."
  exit 2
fi
mkdir -p "$LINUX" || exit 2

if [ "$MODUS" = "copy" ]; then
  command -v rsync >/dev/null && rsync -a --info=stats1 "$SRC"/ "$LINUX"/ \
    || cp -a "$SRC"/. "$LINUX"/
  echo "gekopieerd: $WIN -> $LINUX"
  echo "Optioneel vanuit Windows: mklink /J \"${WIN}.wsl\" \"\\\\wsl\$\\${WSL_DISTRO_NAME}${LINUX}\""
  exit 0
fi

echo "LET OP: bind-mount houdt het bestand op de Windows-schijf. De sandbox ziet het Linux-pad,"
echo "maar de data blijft onder /mnt/c."
sudo mount --bind "$SRC" "$LINUX" || exit 2
echo "gebonden: $SRC -> $LINUX"
echo "Deze mount verdwijnt bij wsl --shutdown tenzij je hem zelf in /etc/fstab zet."
