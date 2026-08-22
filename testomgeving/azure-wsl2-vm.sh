#!/usr/bin/env bash
# Zet een Windows-VM in Azure neer waarin WSL2 wél kan draaien.
#
# Waarom de cloud en niet een VM op de Mac: Apple Silicon kent geen geneste virtualisatie
# voor Windows-ARM-gasten, dus Hyper-V en daarmee WSL2 werken daar niet. Parallels zegt dat
# zelf: https://kb.parallels.com/en/129497. Azure's v3-series en nieuwer ondersteunt geneste
# virtualisatie wel, dus daar draait WSL2 gewoon.
#
#   ./azure-wsl2-vm.sh maak      VM aanmaken (vraagt om bevestiging, toont de kosten)
#   ./azure-wsl2-vm.sh verbind   RDP-verbinding openen
#   ./azure-wsl2-vm.sh weg       alles opruimen - DOE DIT als je klaar bent, het kost per uur
#
# Kosten: een Standard_D2s_v3 kost ongeveer EUR 0,10 per uur in West-Europa, plus een paar
# cent voor de schijf. Een testmiddag is dus een euro of twee. De VM blijft kosten zolang hij
# aan staat, ook als je hem niet gebruikt - vandaar 'weg'.

set -uo pipefail

ABO="${AZ_ABONNEMENT:-}"
GROEP="${AZ_GROEP:-rg-wsl2-claude-code-sandbox}"
LOCATIE="${AZ_LOCATIE:-westeurope}"
VM="${AZ_VM:-vm-wsl2-sandbox}"
MAAT="${AZ_MAAT:-Standard_D2s_v3}"   # v3+ = geneste virtualisatie
# Windows Server 2022 in plaats van Windows 11: gemeten 21-08-2026 dat de win11-Pro-images
# niet in de galerij staan (alleen AVD/M365-varianten, met licentie-eisen). Server 2022 heeft
# die complicatie niet en draait WSL2 gewoon.
IMAGE="MicrosoftWindowsServer:windowsserver2022:2022-datacenter-azure-edition:latest"

case "${1:-}" in
maak)
  if [ -n "$ABO" ]; then
    az account set --subscription "$ABO" || exit 2
  else
    ABO="$(az account show --query name -o tsv 2>/dev/null)" \
      || { echo "Geen actieve Azure-login. Draai eerst: az login"; exit 2; }
  fi
  echo "Abonnement : $ABO"
  echo "Groep      : $GROEP  (nieuw, in $LOCATIE)"
  echo "VM         : $VM, $MAAT, Windows Server 2022 (HyperVGen V1,V2 - geverifieerd)"
  echo "Kosten     : ~EUR 0,10/uur zolang hij aan staat"
  echo
  read -r -p "Aanmaken? [j/N] " a; case "$a" in j|J|ja|Ja) ;; *) echo "Afgebroken."; exit 0 ;; esac

  az group create -n "$GROEP" -l "$LOCATIE" -o none || exit 2

  # Wachtwoord komt uit de omgeving of wordt gegenereerd; het wordt nooit afgedrukt.
  PW="${AZ_VM_WACHTWOORD:-$(LC_ALL=C tr -dc 'A-Za-z0-9!#%+=' </dev/urandom | head -c 24)Aa1!}"
  printf '%s' "$PW" > "$HOME/.azure-wsl2-sandbox-wachtwoord"
  chmod 600 "$HOME/.azure-wsl2-sandbox-wachtwoord"

  az vm create -g "$GROEP" -n "$VM" --image "$IMAGE" --size "$MAAT" \
    --admin-username sandboxadmin --admin-password "$PW" \
    --public-ip-sku Standard --nsg-rule RDP -o none || exit 2

  # RDP alleen open voor jouw eigen IP, niet voor de hele wereld.
  MIJN_IP="$(curl -s https://api.ipify.org)"
  az network nsg rule update -g "$GROEP" --nsg-name "${VM}NSG" -n rdp \
    --source-address-prefixes "$MIJN_IP" -o none 2>/dev/null

  IP="$(az vm show -d -g "$GROEP" -n "$VM" --query publicIps -o tsv)"
  echo
  echo "Klaar. RDP naar $IP, gebruiker sandboxadmin."
  echo "Wachtwoord staat in ~/.azure-wsl2-sandbox-wachtwoord (alleen voor jou leesbaar)."
  echo "RDP staat alleen open voor $MIJN_IP."
  echo
  echo "Volgende stap, in de VM (PowerShell als admin):"
  echo "  wsl --install -d Ubuntu     en daarna herstarten"
  echo "Daarna: testomgeving/in-wsl2.sh volgen."
  ;;

verbind)
  IP="$(az vm show -d -g "$GROEP" -n "$VM" --query publicIps -o tsv 2>/dev/null)"
  [ -z "$IP" ] && { echo "VM niet gevonden. Eerst 'maak'."; exit 2; }
  echo "RDP naar $IP, gebruiker sandboxadmin"
  echo "Wachtwoord: cat ~/.azure-wsl2-sandbox-wachtwoord"
  open "rdp://full%20address=s:$IP:3389&username=s:sandboxadmin" 2>/dev/null \
    || echo "Open je RDP-client met bovenstaand adres."
  ;;

weg)
  echo "Dit verwijdert resourcegroep '$GROEP' met alles erin, onomkeerbaar."
  read -r -p "Zeker weten? [j/N] " a; case "$a" in j|J|ja|Ja) ;; *) echo "Afgebroken."; exit 0 ;; esac
  az group delete -n "$GROEP" --yes --no-wait && echo "Verwijderen gestart."
  rm -f "$HOME/.azure-wsl2-sandbox-wachtwoord"
  ;;

*) sed -n '1,20p' "$0" | sed 's/^# \{0,1\}//'; exit 1 ;;
esac
