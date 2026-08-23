#!/usr/bin/env bash
# Haalt de managed-settings van deze machine af. Dit is het noodluik.
#
# Draai dit in een GEWONE terminal, niet vanuit Claude Code: als de policy Claude Code
# blokkeert, kun je hem niet met Claude Code repareren.
#
#   ./bin/sandbox unlock          laat zien wat er staat en vraagt om bevestiging
#   ./bin/sandbox unlock --force  meteen weghalen
#
# Er wordt eerst een kopie bewaard naast het origineel, met tijdstempel.

set -uo pipefail

case "$(uname -s)" in
  Darwin) TARGETS=("/Library/Application Support/ClaudeCode/managed-settings.json"
                   "/Library/Application Support/ClaudeCode/managed-mcp.json") ;;
  Linux)  TARGETS=("/etc/claude-code/managed-settings.json"
                   "/etc/claude-code/managed-mcp.json"
                   "/mnt/c/Program Files/ClaudeCode/managed-settings.json"
                   "/mnt/c/Program Files/ClaudeCode/managed-mcp.json") ;;
  *)      echo "Onbekend platform $(uname -s) - haal het bestand met de hand weg."; exit 2 ;;
esac

FOUND=()
for t in "${TARGETS[@]}"; do [ -f "$t" ] && FOUND+=("$t"); done

if [ ${#FOUND[@]} -eq 0 ]; then
  echo "Niets te doen: er staan geen managed-settings op deze machine."
  echo "Gezocht op:"; printf '  %s\n' "${TARGETS[@]}"
  exit 0
fi

echo "Gevonden:"
for f in "${FOUND[@]}"; do echo "  $f"; done
echo

if [ "${1:-}" != "--force" ]; then
  read -r -p "Weghalen? Er wordt eerst een kopie bewaard. [j/N] " a
  case "$a" in j|J|ja|Ja) ;; *) echo "Afgebroken."; exit 0 ;; esac
fi

TS="$(date +%Y%m%d-%H%M%S)"
VERWIJDERD=0
OVERGESLAGEN=0
for f in "${FOUND[@]}"; do
  case "$f" in
    /mnt/c/*)
      echo "  LET OP: $f staat op de Windows-kant."
      echo "          Weghalen vraagt Windows-adminrechten en raakt iedereen die dit"
      echo "          bestand via Intune krijgt. De juiste terugdraai voor de hele vloot"
      echo "          is de key wslInheritsWindowsSettings uit de Intune-payload halen;"
      echo "          de policy geldt dan weer alleen op Windows en WSL2 valt terug."
      OVERGESLAGEN=$((OVERGESLAGEN+1)); continue ;;
  esac
  sudo cp "$f" "$f.$TS.bak" || { echo "  kopie mislukt, niets verwijderd: $f"; exit 1; }
  echo "  kopie: $f.$TS.bak"
  sudo rm "$f" && { echo "  weg:   $f"; VERWIJDERD=$((VERWIJDERD+1)); }
done

echo
# De slotregel hangt af van wat er echt is gebeurd. Anders meldt dit script "de policy is
# eraf" terwijl er op slice 3 - de uitrol die naar ITOps gaat - niets is verwijderd.
if [ $VERWIJDERD -gt 0 ]; then
  echo "Klaar: $VERWIJDERD bestand(en) verwijderd. Start Claude Code opnieuw."
  echo "Terugzetten kan met: sudo cp '<pad>.$TS.bak' '<pad>'"
  exit 0
fi

echo "ER IS NIETS VERWIJDERD. De policy staat er nog."
if [ $OVERGESLAGEN -gt 0 ]; then
  cat <<'EOF'

Wat je wel kunt doen, van licht naar zwaar:

  1. Voor deze ene laptop: haal het bestand met Windows-adminrechten weg, of
     verwijder daarin de key "wslInheritsWindowsSettings". De policy geldt dan
     weer alleen op de Windows-kant en WSL2 valt terug op onbeschermd.
  2. Voor de hele vloot: haal die key uit de Intune-payload.

Dit script komt niet bij de Windows-kant en kan hier dus niets voor je doen.
EOF
fi
exit 1
