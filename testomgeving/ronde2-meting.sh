#!/usr/bin/env bash
# Ronde 2 van de ingelogde meting in de bestaande Azure-VM (vm3 / rg-wsl2-poc3).
#
# Waarom dit script bestaat: de agent mag jouw API-token niet aanraken of versturen.
# Alles wat met de token gebeurt, gebeurt dus hier, onder jouw hand, en is hieronder
# na te lezen. Dit script bouwt bij elke run een vers pakket van de lokale suite en zet dat
# samen met de token op de VM, zodat de meting nooit ongemerkt een oude run.sh gebruikt.
#
# Wat de vorige ronde afbrak: de Bash-tool weigerde de probe met
# "<error>Contains simple_expansion</error>" — de rc-afvang stond als $?/$rc op de
# commandoregel. Die zit nu in een scriptbestand; de markers zijn ongewijzigd.
#
# Gebruik:
#   ./ronde2-meting.sh ~/.poc-token            # meten, VM laten staan
#   ./ronde2-meting.sh ~/.poc-token --afbreken # meten en daarna de resourcegroep slopen
#   ./ronde2-meting.sh ~/.poc-token "" AC-00p  # alleen één AC meten (diagnostiek)
#
# Over de token, eerlijk en volledig:
#   1. inner2.sh doet `rm -f /mnt/c/poc/token` direct na het inlezen, dus het bestand
#      staat er seconden. Tijdens de run zit de token alleen in de omgeving van het
#      proces, niet op schijf.
#   2. `az group delete` gooit VM, OS-schijf en NIC weg. Wat op die schijf stond —
#      inclusief het run-command-script waarmee jij de token uploadt, dat Azure op de
#      VM wegschrijft onder C:\Packages\Plugins\... — verdwijnt daarmee.
#   3. Wat ik NIET kan garanderen: Azure's eigen control plane. Een run-command-aanroep
#      gaat met zijn scriptinhoud door Azure's API, en of die inhoud in de activity log
#      of extensie-historie bewaard blijft, bepaalt Azure — niet dit script en niet de
#      VM. Reken de token dus als "geweest" en trek hem daarna in.
#   4. Daarom: maak een VERSE token voor deze run en trek hem na afloop in door
#      opnieuw `claude setup-token` te draaien op dat account. Dat is de enige
#      garantie die niet van Azure afhangt.

set -uo pipefail

TOKEN_PAD="${1:-}"
AFBREKEN="${2:-}"
FILTER="${3:-}"
RG="rg-wsl2-poc3"
VM="vm3"

rood() { printf '\033[31m%s\033[0m\n' "$*"; }
groen() { printf '\033[32m%s\033[0m\n' "$*"; }

[ -n "$TOKEN_PAD" ] || { rood "FOUT: geef het pad naar je tokenbestand mee, bv. ~/.poc-token"; exit 2; }
[ -s "$TOKEN_PAD" ] || { rood "FOUT: $TOKEN_PAD bestaat niet of is leeg"; exit 2; }
[ -z "$FILTER" ] || [[ "$FILTER" =~ ^AC-[0-9]+[a-z]?$ ]] \
  || { rood "FOUT: filter moet leeg zijn of een AC-id, bijvoorbeeld AC-00p"; exit 2; }

# Voorwaardetest op de token zelf: een verkeerd bestand kost je twintig minuten VM-tijd
# en levert een run op die op authenticatie faalt in plaats van iets te meten.
TOKEN_LENGTE="$(tr -d '[:space:]' < "$TOKEN_PAD" | wc -c | tr -d ' ')"
if ! tr -d '[:space:]' < "$TOKEN_PAD" | grep -Eq '^sk-ant-oat[A-Za-z0-9_-]{80,}$'; then
  rood "FOUT: $TOKEN_PAD bevat na verwijderen van wordwrap geen volledige sk-ant-oat-token."
  exit 2
fi
if [ "$TOKEN_LENGTE" -lt 100 ]; then
  rood "FOUT: token lijkt afgekapt ($TOKEN_LENGTE tekens, verwacht ongeveer 108)."
  exit 2
fi

az vm show -g "$RG" -n "$VM" --query name -o tsv >/dev/null 2>&1 \
  || { rood "FOUT: $VM in $RG bestaat niet (meer). Dan is een verse VM nodig."; exit 2; }

WERK="$(mktemp -d)"
trap 'rm -rf "$WERK"' EXIT

# Altijd de huidige lokale suite meten; evidence en testomgeving horen niet in het pakket.
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
tar czf "$WERK/pakket.tgz" -C "$ROOT" \
  run.sh fixture.sh beoordeel.sh check-configs.sh selftest.sh config

# ---------------------------------------------------------------- distro-script
cat > "$WERK/inner2.sh" <<'INNER'
#!/bin/bash
exec > /mnt/c/poc/distro2.log 2>&1
set -x
rm -rf /home/dev/poc && mkdir -p /home/dev/poc
tar xzf /mnt/c/poc/pakket.tgz -C /home/dev/poc
chown -R dev:dev /home/dev/poc
chmod +x /home/dev/poc/*.sh
if [ ! -s /mnt/c/poc/token ]; then echo "GEEN-TOKEN"; exit 3; fi
TOK="$(tr -d ' \r\n' < /mnt/c/poc/token)"
rm -f /mnt/c/poc/token          # token van schijf af, meteen na inlezen
sudo -u dev env CLAUDE_CODE_OAUTH_TOKEN="$TOK" HOME=/home/dev bash -lc '
  cd ~/poc
  ./fixture.sh > /mnt/c/poc/fixture.out 2>&1
  FILTER="$(tr -d " \r\n" < /mnt/c/poc/filter)"
  if [ -n "$FILTER" ]; then
    ./run.sh "$FILTER" > /mnt/c/poc/run.out 2>&1
  else
    ./run.sh           > /mnt/c/poc/run.out 2>&1
  fi
  echo "RUN-RC=$?" >> /mnt/c/poc/run.out
  laatste=$(ls -dt evidence/*/ 2>/dev/null | head -1)
  echo "EVIDENCEMAP=$laatste" >> /mnt/c/poc/run.out
  [ -n "$laatste" ] && tar czf /mnt/c/poc/evidence.tgz -C evidence "$(basename "$laatste")"
'
echo "SUITE-KLAAR"
INNER

# ------------------------------------------------------- windows-kant (als user)
# Deze taak moet als pocadmin lopen: WSL weigert onder SYSTEM, en dat is precies
# waar run-command in draait. Vandaar de geplande taak.
cat > "$WERK/als-gebruiker.ps1" <<'PS1'
$ErrorActionPreference='Continue'
function Log($m){ "$(Get-Date -f HH:mm:ss) $m" | Out-File C:\poc\progress.log -Append -Encoding utf8 }
Log "ronde2 start als $env:USERNAME"
Log ("distros=" + ((& wsl.exe -l -q 2>&1 | Out-String) -replace "`0","" -replace "\s+"," "))
& wsl.exe -d poc -u root -- bash /mnt/c/poc/inner2.sh 2>&1 | Out-File C:\poc\progress.log -Append -Encoding utf8
Log "ronde2 klaar"
PS1

b64() { base64 -i "$1" | tr -d '\n'; }
I="$(b64 "$WERK/inner2.sh")"
P="$(b64 "$WERK/als-gebruiker.ps1")"
Q="$(b64 "$WERK/pakket.tgz")"
printf '%s\n' "$FILTER" > "$WERK/filter"
F="$(b64 "$WERK/filter")"
tr -d ' \r\n' < "$TOKEN_PAD" > "$WERK/token"
T="$(b64 "$WERK/token")"

echo "1/4 scripts en token naar de VM, en de oude uitvoer opruimen"
az vm run-command invoke -g "$RG" -n "$VM" --command-id RunPowerShellScript --scripts "
Remove-Item C:\poc\run.out,C:\poc\fixture.out,C:\poc\evidence.tgz,C:\poc\distro2.log -Force -ErrorAction SilentlyContinue
[IO.File]::WriteAllBytes('C:\poc\inner2.sh',[Convert]::FromBase64String('$I'))
[IO.File]::WriteAllBytes('C:\poc\als-gebruiker.ps1',[Convert]::FromBase64String('$P'))
[IO.File]::WriteAllBytes('C:\poc\pakket.tgz',[Convert]::FromBase64String('$Q'))
[IO.File]::WriteAllBytes('C:\poc\filter',[Convert]::FromBase64String('$F'))
[IO.File]::WriteAllBytes('C:\poc\token',[Convert]::FromBase64String('$T'))
'geplaatst: ' + ((Get-ChildItem C:\poc\inner2.sh,C:\poc\als-gebruiker.ps1,C:\poc\pakket.tgz,C:\poc\filter,C:\poc\token | Measure-Object).Count) + ' bestanden'
" --query "value[0].message" -o tsv | tail -3
rm -f "$WERK/token"

echo "2/4 taak starten (draait als pocadmin, niet als SYSTEM)"
az vm run-command invoke -g "$RG" -n "$VM" --command-id RunPowerShellScript \
  --scripts "schtasks /run /tn PocWsl | Out-String" --query "value[0].message" -o tsv | tail -2

echo "3/4 wachten op de uitslag (max 20 min, peiling elke 90 s)"
for i in $(seq 1 14); do
  sleep 90
  UIT="$(az vm run-command invoke -g "$RG" -n "$VM" --command-id RunPowerShellScript \
        --scripts "if ((Test-Path C:\poc\run.out) -and (Select-String -Path C:\poc\run.out -Pattern '^RUN-RC=' -Quiet)) { 'KLAAR'; Get-Content C:\poc\run.out -Tail 6 } else { 'BEZIG'; if (Test-Path C:\poc\run.out) { Get-Content C:\poc\run.out -Tail 6 } else { Get-Content C:\poc\progress.log -Tail 2 } }" \
        --query "value[0].message" -o tsv 2>/dev/null)"
  echo "--- peiling $i"; echo "$UIT" | tail -6
  case "$UIT" in *KLAAR*) break;; esac
done

echo "4/4 bewijs ophalen"
cd "$(dirname "$0")/.." || exit 1
az vm run-command invoke -g "$RG" -n "$VM" --command-id RunPowerShellScript \
  --scripts "Get-Content C:\poc\run.out -Raw" --query "value[0].message" -o tsv > "$WERK/run.out" 2>/dev/null
if az vm run-command invoke -g "$RG" -n "$VM" --command-id RunPowerShellScript \
     --scripts "if (Test-Path C:\poc\evidence.tgz) { [Convert]::ToBase64String([IO.File]::ReadAllBytes('C:\poc\evidence.tgz')) }" \
     --query "value[0].message" -o tsv 2>/dev/null | grep -v '^\[std' | tr -d ' \n' > "$WERK/ev.b64" \
   && [ -s "$WERK/ev.b64" ]; then
  base64 -d -i "$WERK/ev.b64" -o "$WERK/ev.tgz" && tar xzf "$WERK/ev.tgz" -C evidence \
    && groen "bewijs uitgepakt in evidence/ ($(tar tzf "$WERK/ev.tgz" | head -1))"
else
  rood "geen evidence.tgz op de VM — kijk in de uitvoer hieronder waar het strandde"
fi
echo "=== run.out ==="; cat "$WERK/run.out"

if [ "$AFBREKEN" = "--afbreken" ]; then
  echo; echo "resourcegroep $RG wordt verwijderd (VM, schijf en NIC, dus ook alles wat er nog op stond)"
  az group delete -n "$RG" --yes --no-wait && groen "verwijdering gestart; controleer met: az group exists -n $RG"
else
  echo
  echo "VM staat nog. Sloop hem zodra je het bewijs hebt:"
  echo "  az group delete -n $RG --yes"
  echo "En trek daarna de token in met een verse 'claude setup-token'."
fi
