#!/usr/bin/env bash
# Draait IN de WSL2-distro. Meet de vier dingen die alleen daar te meten zijn.
#
# De truc voor meting 1: geen Claude-authenticatie nodig. Het Windows-bestand bevat
# requiredMinimumVersion op een absurd hoge waarde. Claude Code hoort dan te weigeren op te
# starten. Weigert hij hier, dan heeft die policy de WSL-grens overgestoken en werkt
# wslInheritsWindowsSettings. Start hij gewoon, dan niet.
set -uo pipefail
WINCFG="/mnt/c/Program Files/ClaudeCode/managed-settings.json"

echo "=== omgeving ==="
echo "  distro : ${WSL_DISTRO_NAME:-GEEN WSL}"
echo "  kernel : $(uname -r)"
echo "  claude : $(claude --version 2>&1 | head -1)"
echo "  bwrap  : $(command -v bwrap >/dev/null && bwrap --version || echo ONTBREEKT)"
echo "  userns : $(sysctl -n kernel.apparmor_restrict_unprivileged_userns 2>/dev/null || echo 'sleutel bestaat niet')"
echo

echo "=== 1. Bereikt het Windows-bestand de distro? ==="
if [ -f "$WINCFG" ]; then
  echo "  Windows-bestand aanwezig"
  grep -o '"wslInheritsWindowsSettings": *[a-z]*' "$WINCFG" | sed 's/^/    /'
  grep -o '"requiredMinimumVersion": *"[^"]*"' "$WINCFG" | sed 's/^/    /'
else
  echo "  GEEN Windows-bestand gevonden op $WINCFG"
fi
[ -f /etc/claude-code/managed-settings.json ] \
  && echo "  LET OP: er staat OOK een bestand in de distro - dan meet je dat" \
  || echo "  geen bestand in de distro (goed: je meet alleen de Windows-route)"
echo
echo "  Claude Code starten met die policy actief:"
UIT="$(claude -p "zeg OK" 2>&1 | head -4)"
RC=$?
echo "$UIT" | sed 's/^/    /'
echo "    exitcode: $RC"
echo
if grep -qiE "version|minimum|upgrade|update.*required" <<<"$UIT"; then
  echo "  UITKOMST: hij weigert op de versie-eis -> de Windows-policy BEREIKT de distro."
elif grep -qiE "not logged in|/login" <<<"$UIT"; then
  echo "  UITKOMST: hij komt tot de inlogcontrole, dus de versie-eis hield hem NIET tegen"
  echo "            -> de Windows-policy bereikt de distro NIET."
else
  echo "  UITKOMST: onduidelijk, lees de uitvoer hierboven."
fi
echo

echo "=== 2. Waarnaar resolvet ~ over de WSL-grens? ==="
echo "  Linux-home   : $HOME"
echo "  Windows-home : $(cmd.exe /c echo %USERPROFILE% 2>/dev/null | tr -d '\r')"
echo "  Relevant omdat elk beschermd pad in de config met ~/ begint."
echo

echo "=== 3. Houdt bubblewrap met onze config? ==="
if command -v srt >/dev/null && [ -f /tmp/slice1.json ]; then
  python3 - <<'PY'
import json
fs = json.load(open("/tmp/slice1.json"))["sandbox"]["filesystem"]
json.dump({"filesystem": {"denyRead": fs["denyRead"], "allowRead": fs["allowRead"],
                          "allowWrite": fs["allowWrite"], "denyWrite": []},
           "network": {"allowedDomains": [], "deniedDomains": []}},
          open("/tmp/srt.json", "w"))
PY
  mkdir -p ~/probe-a ~/repos/probe-7f3a91b2/deelproject
  echo "PROBE-TOKEN-7f3a91b2 beschermd" > ~/probe-a/bestand.txt
  echo "gewoon-leesbaar" > ~/repos/probe-7f3a91b2/deelproject/app.js
  printf '  beschermd pad : '
  srt -s /tmp/srt.json -c "cat $HOME/probe-a/bestand.txt" 2>&1 | grep -qF PROBE-TOKEN-7f3a91b2 \
    && echo "TOKEN GELEKT" || echo "geblokkeerd"
  printf '  toegestaan pad: '
  srt -s /tmp/srt.json -c "cat $HOME/repos/probe-7f3a91b2/deelproject/app.js" 2>&1 | grep -qF gewoon-leesbaar \
    && echo "leesbaar (goed)" || echo "OOK GEBLOKKEERD - te streng"
else
  echo "  srt of /tmp/slice1.json ontbreekt"
fi
echo

echo "=== 4. Het cmd.exe-gat (Unix-socket) ==="
echo "  seccomp-filter: $(npm ls -g @anthropic-ai/sandbox-runtime 2>/dev/null | sed -n 2p | sed 's/[^@]*@/@/')"
if command -v srt >/dev/null && [ -f /tmp/srt.json ]; then
  WU="$(cmd.exe /c echo %USERNAME% 2>/dev/null | tr -d '\r')"
  echo "  Windows-gebruiker: $WU"
  printf '  cmd.exe vanuit de sandbox: '
  srt -s /tmp/srt.json -c "/mnt/c/Windows/System32/cmd.exe /c echo VANUIT-CMD" 2>&1 | grep -qF VANUIT-CMD \
    && echo "START WEL - de Unix-socket staat open" || echo "geblokkeerd"
fi
