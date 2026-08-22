# Design: intake en policygenerator voor meerdere workspaces

## Doel

De handoff mag `~/repos` niet als organisatiekeuze aannemen. Voordat een agent software
installeert of managed settings plaatst, vraagt hij welke WSL-workspaces toegankelijk moeten
zijn, welke toegang iedere workspace krijgt en welke paden desondanks beschermd blijven.
Daarna genereert hij een lokale testpayload die statisch wordt gevalideerd.

## Verplichte intakepoort

`HANDOFF.md` krijgt vóór de huidige laptopprocedure een harde stop. De agent vraagt via **AskUserQuestion**, één
onderwerp per keer, inclusief toestemming vóór elke installatie:

1. Welke absolute WSL/Linux-paden zijn workspaces? Er mogen meerdere roots zijn.
2. Welke bestaande of nieuwe projecten horen per root? Een repository wordt nooit zonder
   aparte bevestiging verplaatst.
3. Is iedere root alleen leesbaar of ook schrijfbaar voor sandboxed Bash?
4. Welke bestanden of submappen binnen iedere workspace blijven beschermd?
5. Welke gevoelige paden buiten de workspaces moeten ook voor Claude's Read-tool expliciet
   worden geblokkeerd?
6. Welke proxyvariabelen en package-/API-domeinen zijn nodig?
7. Welke bestaande managed settings moeten behouden en gemerged worden?

De agent vat de antwoorden samen en vraagt één bevestiging. Zonder bevestiging mag hij geen
payload genereren, mappen aanmaken, repositories verplaatsen of policy installeren.

## Intakebestand

De bevestigde antwoorden komen in een lokaal, git-genegeerd bestand:
`local/policy-input.json`. Het schema bevat:

- `workspaces`: unieke roots met `path`, `access` (`read-only` of `read-write`) en een
  beschrijvende `contents`-lijst;
- `protectedPaths`: paden met `path` en `reason`;
- `allowedDomains`;
- optionele `proxy` (`HTTPS_PROXY` en `NO_PROXY`);
- optioneel pad naar een bestaande managed-settings-payload.

`local/` wordt genegeerd door git. Het intakebestand bevat geen tokens of wachtwoorden.

## Padregels

De generator:

- accepteert absolute Linux-paden en `~/...`, en normaliseert trailing slashes;
- ondersteunt meerdere en geneste workspace-roots;
- weigert `/`, `~`, `/home`, systeempaden en standaard ieder pad onder `/mnt`;
- accepteert `/mnt` alleen met een expliciete `allowWindowsMounts: true` plus een zichtbare
  waarschuwing in de uitvoer;
- controleert dat ieder beschermd pad onder een workspace of onder de Linux-home ligt;
- voegt ieder beschermd pad toe aan zowel `sandbox.filesystem.denyRead` als
  `permissions.deny`;
- voegt iedere workspace toe aan `allowRead` en alleen `read-write`-roots aan `allowWrite`;
- behoudt de vaste runtimepaden en lock-keys uit de bestaande Windows-template.

Een brede workspace geeft dus geen toegang tot een beschermd kindpad: de specifieke
`denyRead` en `Read(...)`-regel blijven leidend.

## Generator en uitvoer

Een Pythonmodule `tools/policy_generator.py` wordt de enige plek die intake naar policy
vertaalt. Een dun script `generate-policy.sh` verzorgt de CLI:

```bash
./generate-policy.sh local/policy-input.json \
  local/managed-settings.windows.generated.json
```

De generator leest `config/managed-settings.windows.json` als basistemplate, past uitsluitend
de workspace-, beschermde-pad-, domein- en proxyvelden aan en schrijft atomair naar het
doelpad. Een bestaand doelbestand wordt niet zonder `--force` overschreven.

Na generatie draait het script automatisch:

```bash
./check-configs.sh local/managed-settings.windows.generated.json
```

Daarna toont het een samenvatting van workspaces, schrijftoegang, beschermde paden en
netwerktoegang. Het installeert niets.

## Bestaande managed settings

De generator vervangt geen bestaande organisatiepolicy. Als de intake een bestaand bestand
opgeeft, merge hij:

- bestaande onbekende top-level keys behouden;
- bestaande `permissions.deny` verenigen met de gegenereerde regels;
- bestaande MCP-config behouden, tenzij de intake die expliciet invult;
- security-locks uit de PoC mogen niet worden verzwakt;
- conflicten stoppen de generatie met een concrete fout in plaats van automatisch te kiezen.

## Verificatie

De regressietests zijn gewone Python-unittests en de bestaande shellzelftests:

- meerdere read-only/read-write roots komen in de juiste lijsten;
- beschermde kindpaden staan op beide lagen;
- `/mnt` en te brede roots worden standaard geweigerd;
- bestaande settings blijven behouden;
- security-locks kunnen niet worden verzwakt;
- ongeldige of ontbrekende intake faalt zonder uitvoerbestand;
- gegenereerde JSON slaagt voor `check-configs.sh`.

`VERIFICATIE.md` krijgt daarnaast laptopstappen die de gekozen roots gebruiken: een normaal
bestand per workspace moet leesbaar zijn, een tijdelijk canarybestand op ieder type beschermd
pad niet. Testbestanden worden alleen met botsingscontrole gemaakt en marker-gebaseerd
opgeruimd.

## Windows-mappen de distro in

`bring-workspace.sh` kopieert standaard een Windows-pad naar een Linux-workspace. Twee
argumenten zonder modus is copy. Bind-mount is geen peer: het script eist
`--i-approved-bind` én `bindApproved: true` in de intake. Een symlink van Linux naar
`/mnt/c` is verboden: dat is de omweg die AC-06 meet. Een Windows-junction naar
`\\wsl$\<distro>\<linux-pad>` mag wél.

Installeren, genereren, plaatsen en een groene `run.sh` lopen via `agent-gate.sh`. Zonder
`local/consent.json` / bevestigde `local/policy-input.json` stoppen die scripts. De
statische Windows-template is geen plaatsbare bron; alleen
`local/managed-settings.windows.generated.json` gaat naar Program Files, en alleen na een
geslaagde rode nulmeting.

## Bewijsmatrix

`run.sh` schrijft aan het einde [templates/proof-matrix.md](../../../templates/proof-matrix.md)
naar `evidence/<stempel>/proof-matrix.md`. De tweede developer-laptop blijft daar altijd
open. Eén groene `run.sh` is geen vrijgave.

## Niet-doelen

- Repositories automatisch verplaatsen of clonen zonder AskUserQuestion.
- Organisatiepaden zelf ontdekken.
- Tokens, proxycredentials of secrets opslaan.
- Een `/mnt`-workspace stil toestaan.
- Een symlink van een Linux-workspace naar `/mnt/c`.
- De gegenereerde lokale payload committen.
