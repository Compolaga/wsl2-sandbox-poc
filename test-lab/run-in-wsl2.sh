#!/usr/bin/env bash
# Draai dit IN de WSL2-distro, op de Windows-machine. Dit is stap B: de vier dingen die
# alleen daar te meten zijn.
#
# Kopieer eerst de hele repo-map naar de distro, bijvoorbeeld:
#   git clone <of> scp -r wsl2-claude-code-sandbox/ gebruiker@machine:~/
#
#   ./run-in-wsl2.sh voorbereiden   afhankelijkheden installeren en controleren
#   ./run-in-wsl2.sh meet           de vier WSL-specifieke metingen
set -uo pipefail
cd "$(dirname "$0")/.."
sandbox="$(pwd)"
WINCFG="/mnt/c/Program Files/ClaudeCode/managed-settings.json"

case "${1:-meet}" in
voorbereiden)
  echo "== afhankelijkheden =="
  sudo apt-get update -qq && sudo apt-get install -y -qq bubblewrap socat ripgrep python3 || exit 2
  command -v node >/dev/null || { curl -fsSL https://deb.nodesource.com/setup_22.x | sudo -E bash - && sudo apt-get install -y -qq nodejs; }
  command -v claude >/dev/null || sudo npm install -g @anthropic-ai/claude-code
  sudo npm install -g @anthropic-ai/sandbox-runtime
  echo
  echo "== controle =="
  printf '  WSL-versie   : %s\n' "${WSL_DISTRO_NAME:-GEEN WSL}"
  printf '  bwrap        : %s\n' "$(command -v bwrap || echo ONTBREEKT)"
  printf '  socat        : %s\n' "$(command -v socat || echo ONTBREEKT)"
  printf '  ripgrep      : %s\n' "$(command -v rg || echo ONTBREEKT)"
  printf '  claude       : %s\n' "$(claude --version 2>&1 | head -1)"
  U="$(sysctl -n kernel.apparmor_restrict_unprivileged_userns 2>/dev/null || echo 'sleutel bestaat niet')"
  printf '  userns-lock  : %s\n' "$U"
  [ "$U" = "1" ] && cat <<'EOF'

  LET OP: AppArmor blokkeert de user namespaces die bubblewrap nodig heeft.
  Zet dit eerst recht, anders start de sandbox niet:

    sudo tee /etc/apparmor.d/bwrap > /dev/null <<'PROFIEL'
    abi <abi/4.0>,
    include <tunables/global>
    profile bwrap /usr/bin/bwrap flags=(unconfined) {
      userns,
      include if exists <local/bwrap>
    }
    PROFIEL
    sudo systemctl reload apparmor

  Werkt systemctl niet in deze distro, laad het profiel dan met:

    sudo apparmor_parser -r /etc/apparmor.d/bwrap
EOF
  [ "$U" = "1" ] && {
    echo
    echo "VOORBEREIDING NOG NIET KLAAR: pas AppArmor aan en draai 'voorbereiden' opnieuw."
    exit 3
  }
  echo
  echo "Klaar. Log daarna in met 'claude auth login' en draai: ./run-in-wsl2.sh meet"
  ;;

meet)
  [ -n "${WSL_DISTRO_NAME:-}" ] || { echo "FOUT: dit is geen WSL2-distro."; exit 2; }
  claude auth status >/dev/null 2>&1 \
    || { echo "FOUT: Claude is niet ingelogd. Draai eerst 'claude auth login'."; exit 2; }
  D="$sandbox/evidence/wsl2-$(date +%Y%m%d-%H%M%S)"; mkdir -p "$D"
  exec > >(tee "$D/wsl2.txt") 2>&1

  echo "WSL-SPECIFIEKE METINGEN"
  echo "distro: $WSL_DISTRO_NAME   kernel: $(uname -r)   claude: $(claude --version 2>&1|head -1)"
  echo

  echo "== 1. Bereikt het Windows-bestand de distro? (AC-15) =="
  if [ -f "$WINCFG" ]; then
    echo "  Windows-bestand aanwezig: $WINCFG"
    grep -q '"wslInheritsWindowsSettings": *true' "$WINCFG" \
      && echo "  wslInheritsWindowsSettings: true" \
      || { echo "  FOUT: wslInheritsWindowsSettings ONTBREEKT of staat op false"; exit 2; }
  else
    echo "  FOUT: GEEN Windows-bestand op $WINCFG - zet dat er eerst neer (met Windows-admin)"
    exit 2
  fi
  if [ -f /etc/claude-code/managed-settings.json ]; then
    echo "  FOUT: er staat OOK een bestand in de distro; haal dat weg, anders meet je niet alleen de Windows-route"
    exit 2
  else
    echo "  geen bestand in de distro (goed, dan meet je alleen de Windows-route)"
  fi
  echo
  echo "  Wat claude zelf zegt over zijn policy:"
  claude --debug-file /tmp/dbg.log -p "zeg OK" >/dev/null 2>&1
  grep -iE "managed|policy|settings" /tmp/dbg.log 2>/dev/null | head -8 | sed 's/^/    /'
  echo

  echo "== 2. Waarnaar resolvet ~ over de WSL-grens? (OQ-7) =="
  echo "  Linux-home    : $HOME"
  echo "  Windows-home  : $(cmd.exe /c echo %USERPROFILE% 2>/dev/null | tr -d '\r')"
  echo "  De config gebruikt ~/ voor elk beschermd pad. Blijkt uit meting 3 dat niets"
  echo "  beschermd is terwijl de config klopt, dan is dit de reden."
  echo

  echo "== 3. Houdt de sandbox? =="
  ./bin/sandbox fixtures setup >/dev/null 2>&1 || { echo "  fixture faalde"; ./bin/sandbox fixtures setup; }
  ./bin/sandbox test
  echo

  echo "== 4. Het Unix-socket-gat via cmd.exe (AC-24) =="
  echo "  seccomp-filter: $(npm ls -g @anthropic-ai/sandbox-runtime 2>/dev/null | sed -n 2p | sed 's/[^@]*@/@/')"
  echo "  Zie AC-24 in de run hierboven."
  echo
  echo "bewijs: ${D#$sandbox/}/wsl2.txt"
  ;;
esac
