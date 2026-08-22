#!/usr/bin/env bash
# Haalt een Windows-map de WSL-Linux-home in. Geen symlink naar /mnt:
# die volgt de sandbox als omweg (AC-06). Standaard kopiëren; bind-mount
# alleen na expliciete keuze.
set -uo pipefail
MODUS="${1:-}"
WIN="${2:-}"
LINUX="${3:-}"

gebruik() {
  cat <<'EOF'
gebruik:
  ./bring-workspace.sh copy  'C:\Users\naam\src\project' /home/dev/work/project
  ./bring-workspace.sh bind  'C:\Users\naam\src\project' /home/dev/work/project

copy  — kopieert de inhoud naar een Linux-pad (aanbevolen).
bind  — mount --bind van het /mnt/c-pad op het Linux-pad. Alleen als copy
        niet kan en de gebruiker dat risico heeft goedgekeurd.

Symlink van het Linux-pad naar /mnt/c is bewust niet beschikbaar.
EOF
  exit 2
}

[ -n "$MODUS" ] && [ -n "$WIN" ] && [ -n "$LINUX" ] || gebruik
case "$MODUS" in copy|bind) ;; *) gebruik ;; esac
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
echo "maar de data blijft onder /mnt/c. Gebruik dit alleen na expliciete goedkeuring."
sudo mount --bind "$SRC" "$LINUX" || exit 2
echo "gebonden: $SRC -> $LINUX"
echo "Deze mount verdwijnt bij wsl --shutdown tenzij je hem zelf in /etc/fstab zet."
