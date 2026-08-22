#!/bin/bash
# Meet alle acceptatiecriteria die zonder Claude-inlog te meten zijn, IN een WSL2-distro,
# als gewone gebruiker. Draait als root en zet zelf een gebruiker op.
#
# De truc door het hele script heen: policy-keys met een zichtbaar opstart-effect. Claude
# Code weigert te starten bij een te lage versie of een ontbrekende sandbox-afhankelijkheid,
# en dat is waarneembaar zonder ooit in te loggen. Zo zijn de lock-keys en de
# leveringsvraag te toetsen met een wegwerp-VM.
set -uo pipefail
DEV=dev
DH=/home/$DEV
W="/mnt/c/Program Files/ClaudeCode/managed-settings.json"

id "$DEV" >/dev/null 2>&1 || useradd -m -s /bin/bash "$DEV"
echo "=== OMGEVING ==="
echo "  distro : ${WSL_DISTRO_NAME:-onbekend}   kernel: $(uname -r)"
echo "  claude : $(claude --version 2>&1 | head -1)"
echo "  bwrap  : $(bwrap --version 2>&1)"
echo "  srt    : $(npm ls -g @anthropic-ai/sandbox-runtime 2>/dev/null | sed -n 2p | sed 's/[^@]*@/@/')"
echo "  userns : $(sysctl -n kernel.apparmor_restrict_unprivileged_userns 2>/dev/null || echo 'sleutel bestaat niet')"
echo "  user   : $DEV (uid $(id -u $DEV))"
echo

# ---------------------------------------------------------------- fixture
sudo -u $DEV bash -c "
mkdir -p $DH/probe-a $DH/probe-b $DH/Documenten $DH/repos/probe-7f3a91b2/deelproject/submap
echo 'PROBE-TOKEN-7f3a91b2 beschermd'  > $DH/probe-a/bestand.txt
echo 'PROBE-TOKEN-7f3a91b2 buiten'     > $DH/probe-b/bestand.txt
echo 'PROBE-TOKEN-7f3a91b2 elders'     > $DH/Documenten/bestand.txt
echo 'PROBE-TOKEN-7f3a91b2 in-project' > $DH/repos/probe-7f3a91b2/deelproject/config-a.txt
echo 'PROBE-TOKEN-7f3a91b2 submap'     > $DH/repos/probe-7f3a91b2/deelproject/submap/bestand.txt
echo 'gewoon-leesbaar'                 > $DH/repos/probe-7f3a91b2/deelproject/app.js
ln -sfn $DH/probe-a/bestand.txt $DH/repos/probe-7f3a91b2/omweg.lnk
"
python3 - "$DH" <<'PY'
import json, sys
dh = sys.argv[1]
fs = json.load(open("/mnt/c/poc/slice1.json"))["sandbox"]["filesystem"]
# ~/ resolvet voor srt naar de home van wie hem aanroept; expliciet maken zodat de meting
# niet afhangt van hoe de tilde geinterpreteerd wordt.
def fix(l): return [str(p).replace("~/", dh + "/") for p in l]
json.dump({"filesystem": {"denyRead": fix(fs["denyRead"]), "allowRead": fix(fs["allowRead"]),
                          "allowWrite": fix(fs["allowWrite"]), "denyWrite": []},
           "network": {"allowedDomains": [], "deniedDomains": []}},
          open("/tmp/srt.json", "w"), indent=1)
PY
chmod 644 /tmp/srt.json

FOUT=0
p() {  # p <dicht|open> <ac> <omschrijving> <commando>
  printf '  %-6s %-40s ' "$2" "$3"
  out="$(sudo -u $DEV srt -s /tmp/srt.json -c "$4" 2>&1)"
  if grep -qF "PROBE-TOKEN-7f3a91b2" <<<"$out"; then res="TOKEN GELEKT"
  elif grep -qF "gewoon-leesbaar" <<<"$out"; then res="leesbaar"
  else res="geblokkeerd"; fi
  case "$1:$res" in
    dicht:geblokkeerd|open:leesbaar) echo "$res" ;;
    *) echo "$res   << NIET ZOALS BEDOELD"; FOUT=1 ;;
  esac
}

echo "=== CONTAINMENT IN WSL2, ALS GEWONE GEBRUIKER ==="
p dicht AC-01 "beschermd pad (cat)"                 "cat $DH/probe-a/bestand.txt"
p dicht AC-02 "via shellscript (child process)"     "printf '#!/bin/sh\ncat $DH/probe-a/bestand.txt\n' > /tmp/p.sh; chmod +x /tmp/p.sh; /tmp/p.sh"
p dicht AC-03 "via python subprocess (grandchild)"  "python3 -c \"import subprocess;subprocess.run(['cat','$DH/probe-a/bestand.txt'])\""
p dicht AC-06 "symlink-omweg uit toegestane map"    "cat $DH/repos/probe-7f3a91b2/omweg.lnk"
p dicht AC-22 "willekeurig pad in de home"          "cat $DH/Documenten/bestand.txt"
p dicht AC-17 "BESTAND in toegestane map"           "cat $DH/repos/probe-7f3a91b2/deelproject/config-a.txt"
p dicht AC-19 "SUBMAP in toegestane map"            "cat $DH/repos/probe-7f3a91b2/deelproject/submap/bestand.txt"
p open  AC-20 "gewoon bestand ernaast"              "cat $DH/repos/probe-7f3a91b2/deelproject/app.js"
p open  AC-09 "schrijven in het project"            "touch $DH/repos/probe-7f3a91b2/nieuw.txt && echo gewoon-leesbaar"
echo

echo "=== AC-05 grep over de beschermde mappen ==="
printf '  AC-05  %-40s ' "recursieve grep"
out="$(sudo -u $DEV srt -s /tmp/srt.json -c "grep -rF PROBE-TOKEN- $DH/probe-a $DH/probe-b" 2>&1)"
grep -qF "PROBE-TOKEN-7f3a91b2" <<<"$out" && { echo "TOKEN GELEKT   << NIET ZOALS BEDOELD"; FOUT=1; } || echo "geblokkeerd"
echo

echo "=== AC-24 het cmd.exe-gat (Unix-socket) ==="
WU="$(sudo -u $DEV cmd.exe /c echo %USERNAME% 2>/dev/null | tr -d '\r')"
echo "  Windows-gebruiker: ${WU:-onbekend}"
printf '  AC-24p %-40s ' "cmd.exe buiten de sandbox"
sudo -u $DEV /mnt/c/Windows/System32/cmd.exe /c "echo BUITEN-OK" 2>/dev/null | grep -qF BUITEN-OK \
  && echo "aanroepbaar (voorwaarde ok)" || { echo "NIET aanroepbaar - AC-24 zegt dan niets"; }
printf '  AC-24  %-40s ' "cmd.exe VANUIT de sandbox"
out="$(sudo -u $DEV srt -s /tmp/srt.json -c "/mnt/c/Windows/System32/cmd.exe /c echo VANUIT-CMD" 2>&1)"
grep -qF "VANUIT-CMD" <<<"$out" && { echo "START WEL - Unix-socket staat open"; FOUT=1; } || echo "geblokkeerd"
echo

echo "=== AC-11/12/13 KAN DE DEVELOPER DE POLICY OPREKKEN? ==="
echo "  Managed (Windows-kant) eist requiredMinimumVersion 999.0.0."
echo "  De developer probeert dat in zijn eigen settings te overrulen."
sudo -u $DEV mkdir -p $DH/.claude
for poging in '{"requiredMinimumVersion":"0.0.1"}' '{"sandbox":{"enabled":false},"requiredMinimumVersion":"0.0.1"}'; do
  echo "$poging" | sudo -u $DEV tee $DH/.claude/settings.json >/dev/null
  printf '  %-52s ' "$(echo "$poging" | cut -c1-50)"
  out="$(sudo -u $DEV claude -p 'zeg OK' 2>&1 | head -2)"
  if grep -qi "older than the minimum version" <<<"$out"; then echo "managed WINT"
  else echo "developer wint   << GEEN GRENS"; FOUT=1; fi
done
sudo -u $DEV rm -f $DH/.claude/settings.json
echo

echo "=== AC-14 zonder bwrap weigert Claude Code te starten ==="
echo "  (managed heeft failIfUnavailable: true)"
cp /mnt/c/poc/geen-versie-eis.json "$W" 2>/dev/null && echo "  versie-eis tijdelijk weg, zodat AC-14 niet daarop afgaat"
mv /usr/bin/bwrap /usr/bin/bwrap.uit 2>/dev/null
printf '  AC-14  %-40s ' "bwrap weggehaald"
out="$(sudo -u $DEV claude -p 'zeg OK' 2>&1 | head -3)"
if grep -qiE "sandbox|bubblewrap|bwrap|dependen" <<<"$out"; then echo "weigert op de sandbox-afhankelijkheid"
elif grep -qiE "not logged in|/login" <<<"$out"; then echo "START TOCH   << failIfUnavailable werkt niet"; FOUT=1
else echo "onduidelijk: $(echo "$out" | head -1 | cut -c1-40)"; fi
mv /usr/bin/bwrap.uit /usr/bin/bwrap 2>/dev/null
echo

echo "=== OQ-7 waarnaar resolvet ~ over de WSL-grens ==="
echo "  Linux-home van $DEV : $DH"
echo "  Windows-home        : $(sudo -u $DEV cmd.exe /c echo %USERPROFILE% 2>/dev/null | tr -d '\r')"
echo

echo "=== AC-21 managed-mcp.json in WSL2 ==="
printf '  AC-21  %-40s ' "claude mcp list"
sudo -u $DEV claude mcp list 2>&1 | head -3 | sed 's/^/         /'
echo
[ $FOUT -eq 0 ] && echo "ALLES ZOALS BEDOELD" || echo "ER KLOPT IETS NIET - zie de gemarkeerde regels"
echo "=== EINDE ==="
