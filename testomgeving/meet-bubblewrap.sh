#!/usr/bin/env bash
# Meet de OS-laag: houdt bubblewrap onze eigen configuratie, in een echte Linux-omgeving?
#
# Dit gebruikt @anthropic-ai/sandbox-runtime (`srt`), de standalone versie van dezelfde
# primitieven die Claude Code's sandbox gebruikt. Voordeel: geen Claude-authenticatie nodig,
# dus geen tokens en geen afhankelijkheid van het oordeel van een model over of een probe
# legitiem is. Wat hier houdt, houdt in WSL2 om dezelfde reden - die gebruikt bubblewrap ook.
#
# Wat hier NIET mee te toetsen is: wslInheritsWindowsSettings, /mnt/c, het cmd.exe-gat, en
# de managed-only lock-keys (die zitten in Claude Code, niet in srt). Dat is stap B.
#
#   ./meet-bubblewrap.sh              draait en schrijft naar ../evidence/
#   ./meet-bubblewrap.sh --geen-bewijs  alleen op het scherm
set -uo pipefail
cd "$(dirname "$0")/.."
sandbox="$(pwd)"

command -v docker >/dev/null || { echo "FOUT: docker ontbreekt"; exit 2; }
docker image inspect wsl2-sandbox >/dev/null 2>&1 || { echo "Image bouwen..."; docker build -t wsl2-sandbox "$sandbox/testomgeving" >/dev/null || exit 2; }

# --privileged is nodig omdat Docker standaard geen unprivileged user namespaces toestaat en
# bubblewrap die nodig heeft. Dat is een beperking van de container, niet van de sandbox: in
# WSL2 draait bwrap gewoon als de gebruiker.
UIT="$(docker run --rm --privileged -v "$sandbox:/repo:ro" wsl2-sandbox bash -lc '
mkdir -p ~/probe-a ~/probe-b ~/repos/probe-7f3a91b2/deelproject/submap ~/Documenten
echo "PROBE-TOKEN-7f3a91b2 beschermd"  > ~/probe-a/bestand.txt
echo "PROBE-TOKEN-7f3a91b2 buiten"     > ~/probe-b/bestand.txt
echo "PROBE-TOKEN-7f3a91b2 elders"     > ~/Documenten/bestand.txt
echo "PROBE-TOKEN-7f3a91b2 in-project" > ~/repos/probe-7f3a91b2/deelproject/config-a.txt
echo "PROBE-TOKEN-7f3a91b2 submap"     > ~/repos/probe-7f3a91b2/deelproject/submap/bestand.txt
echo "gewoon-leesbaar"                 > ~/repos/probe-7f3a91b2/deelproject/app.js
ln -sfn /home/dev/probe-a/bestand.txt ~/repos/probe-7f3a91b2/omweg.lnk

python3 -c "
import json
fs=json.load(open(\"/repo/config/settings.slice1.json\"))[\"sandbox\"][\"filesystem\"]
json.dump({\"filesystem\":{\"denyRead\":fs[\"denyRead\"],\"allowRead\":fs[\"allowRead\"],
                          \"allowWrite\":fs[\"allowWrite\"],\"denyWrite\":[]},
           \"network\":{\"allowedDomains\":[],\"deniedDomains\":[]}}, open(\"/home/dev/srt.json\",\"w\"))"

echo "omgeving:"
echo "  kernel:  $(uname -r)"
echo "  bwrap:   $(bwrap --version)"
echo "  srt:     $(npm ls -g @anthropic-ai/sandbox-runtime 2>/dev/null | sed -n 2p | sed "s/[^@]*@/@/")"
echo "  config:  config/settings.slice1.json, blok sandbox.filesystem"
echo
FOUT=0
p() { printf "  %-44s " "$2"; out="$(srt -s /home/dev/srt.json -c "$3" 2>&1)"
      if grep -qF "PROBE-TOKEN-7f3a91b2" <<<"$out"; then res="TOKEN GELEKT"
      elif grep -qF "gewoon-leesbaar" <<<"$out"; then res="leesbaar"
      else res="geblokkeerd: $(echo "$out" | tr "\n" " " | grep -oiE "operation not permitted|permission denied|no such file or directory|read-only file system" | head -1)"; fi
      case "$1:$res" in
        dicht:geblokkeerd*|open:leesbaar) echo "$res" ;;
        *) echo "$res   << NIET ZOALS BEDOELD"; FOUT=1 ;;
      esac; }
p dicht "1 beschermd pad (cat)"                 "cat /home/dev/probe-a/bestand.txt"
p dicht "2 via shellscript (child process)"     "printf \"#!/bin/sh\ncat /home/dev/probe-a/bestand.txt\n\" > /tmp/p.sh; chmod +x /tmp/p.sh; /tmp/p.sh"
p dicht "3 via python subprocess (grandchild)"  "python3 -c \"import subprocess;subprocess.run([\\\"cat\\\",\\\"/home/dev/probe-a/bestand.txt\\\"])\""
p dicht "4 symlink-omweg vanuit toegestane map" "cat /home/dev/repos/probe-7f3a91b2/omweg.lnk"
p dicht "5 willekeurig pad in de home"          "cat /home/dev/Documenten/bestand.txt"
p dicht "6 BESTAND in toegestane map"           "cat /home/dev/repos/probe-7f3a91b2/deelproject/config-a.txt"
p dicht "7 SUBMAP in toegestane map"            "cat /home/dev/repos/probe-7f3a91b2/deelproject/submap/bestand.txt"
p open  "8 gewoon bestand ernaast"              "cat /home/dev/repos/probe-7f3a91b2/deelproject/app.js"
p open  "9 schrijven in het project"            "touch /home/dev/repos/probe-7f3a91b2/nieuw.txt && echo gewoon-leesbaar"
echo
[ $FOUT -eq 0 ] && echo "ALLES ZOALS BEDOELD" || echo "ER KLOPT IETS NIET"
exit $FOUT' 2>&1)"
RC=$?

echo "$UIT"

if [ "${1:-}" != "--geen-bewijs" ]; then
  D="$sandbox/evidence/bubblewrap-$(date +%Y%m%d-%H%M%S)"; mkdir -p "$D"
  {
    echo "BUBBLEWRAP-HANDHAVING IN EEN ECHTE LINUX-OMGEVING"
    echo "Dit meet de OS-laag met onze eigen config, zonder Claude en zonder VM."
    echo "Het zegt NIETS over wslInheritsWindowsSettings, /mnt/c of de managed lock-keys."
    echo
    echo "host:   $(uname -sm) / Docker $(docker version --format '{{.Server.Version}}' 2>/dev/null)"
    shasum -a 256 "$sandbox/config/settings.slice1.json" "$sandbox/testomgeving/Dockerfile" \
                  "$sandbox/testomgeving/meet-bubblewrap.sh" 2>/dev/null
    echo
    echo "$UIT"
    echo
    echo "exitcode: $RC"
  } > "$D/bubblewrap.txt"
  echo
  echo "vastgelegd in: ${D#$sandbox/}/bubblewrap.txt"
fi
exit $RC
