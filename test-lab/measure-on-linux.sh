#!/usr/bin/env bash
# Draait ALS GEWONE GEBRUIKER op een echte Linux-machine, zonder container en zonder
# --privileged. Dat is strenger dan de Docker-meting: daar was --privileged nodig omdat
# Docker unprivileged user namespaces blokkeert. Hier draait bwrap zoals in WSL2 - als de
# developer zelf.
#
# Verwacht: /tmp/slice1.json met het configbestand ernaast.
set -uo pipefail
CFG="${1:-/tmp/slice1.json}"
H="$HOME"

mkdir -p "$H/probe-a" "$H/probe-b" "$H/Documenten" "$H/repos/probe-7f3a91b2/deelproject/submap"
echo "PROBE-TOKEN-7f3a91b2 beschermd"  > "$H/probe-a/bestand.txt"
echo "PROBE-TOKEN-7f3a91b2 buiten"     > "$H/probe-b/bestand.txt"
echo "PROBE-TOKEN-7f3a91b2 elders"     > "$H/Documenten/bestand.txt"
echo "PROBE-TOKEN-7f3a91b2 in-project" > "$H/repos/probe-7f3a91b2/deelproject/config-a.txt"
echo "PROBE-TOKEN-7f3a91b2 submap"     > "$H/repos/probe-7f3a91b2/deelproject/submap/bestand.txt"
echo "gewoon-leesbaar"                 > "$H/repos/probe-7f3a91b2/deelproject/app.js"
ln -sfn "$H/probe-a/bestand.txt" "$H/repos/probe-7f3a91b2/omweg.lnk"

python3 - "$CFG" "$H/srt.json" <<'PY'
import json, sys
fs = json.load(open(sys.argv[1]))["sandbox"]["filesystem"]
json.dump({"filesystem": {"denyRead": fs["denyRead"], "allowRead": fs["allowRead"],
                          "allowWrite": fs["allowWrite"], "denyWrite": []},
           "network": {"allowedDomains": [], "deniedDomains": []}},
          open(sys.argv[2], "w"), indent=2)
PY

echo "omgeving:"
echo "  machine : $(hostname), kernel $(uname -r)"
echo "  gebruiker: $(id -un) (niet root: $([ "$(id -u)" -ne 0 ] && echo ja || echo NEE))"
echo "  bwrap   : $(bwrap --version)"
echo "  srt     : $(npm ls -g @anthropic-ai/sandbox-runtime 2>/dev/null | sed -n 2p | sed 's/[^@]*@/@/')"
echo "  usernslock: $(sysctl -n kernel.apparmor_restrict_unprivileged_userns 2>/dev/null || echo 'sleutel bestaat niet')"
echo

FOUT=0
p() {  # p <dicht|open> <omschrijving> <commando>
  printf '  %-44s ' "$2"
  out="$(srt -s "$H/srt.json" -c "$3" 2>&1)"
  if grep -qF "PROBE-TOKEN-7f3a91b2" <<<"$out"; then res="TOKEN GELEKT"
  elif grep -qF "gewoon-leesbaar" <<<"$out"; then res="leesbaar"
  else res="geblokkeerd: $(tr '\n' ' ' <<<"$out" | grep -oiE 'operation not permitted|permission denied|no such file or directory|read-only file system' | head -1)"; fi
  case "$1:$res" in
    dicht:geblokkeerd*|open:leesbaar) echo "$res" ;;
    *) echo "$res   << NIET ZOALS BEDOELD"; FOUT=1 ;;
  esac
}

echo "=== BUBBLEWRAP ALS GEWONE GEBRUIKER, GEEN CONTAINER ==="
p dicht "1 beschermd pad (cat)"                 "cat $H/probe-a/bestand.txt"
p dicht "2 via shellscript (child process)"     "printf '#!/bin/sh\ncat $H/probe-a/bestand.txt\n' > /tmp/p.sh; chmod +x /tmp/p.sh; /tmp/p.sh"
p dicht "3 via python subprocess (grandchild)"  "python3 -c \"import subprocess;subprocess.run(['cat','$H/probe-a/bestand.txt'])\""
p dicht "4 symlink-omweg vanuit toegestane map" "cat $H/repos/probe-7f3a91b2/omweg.lnk"
p dicht "5 willekeurig pad in de home"          "cat $H/Documenten/bestand.txt"
p dicht "6 BESTAND in toegestane map"           "cat $H/repos/probe-7f3a91b2/deelproject/config-a.txt"
p dicht "7 SUBMAP in toegestane map"            "cat $H/repos/probe-7f3a91b2/deelproject/submap/bestand.txt"
p open  "8 gewoon bestand ernaast"              "cat $H/repos/probe-7f3a91b2/deelproject/app.js"
p open  "9 schrijven in het project"            "touch $H/repos/probe-7f3a91b2/nieuw.txt && echo gewoon-leesbaar"
echo
[ $FOUT -eq 0 ] && echo "ALLES ZOALS BEDOELD" || echo "ER KLOPT IETS NIET"
exit $FOUT
