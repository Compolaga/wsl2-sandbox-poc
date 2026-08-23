# Multiple workspace policy generator

## Why

Een Windows-laptop mag niet ongemerkt de vaste standaardaanname `~/repos` overnemen. De gebruiker
kiest eerst één of meer toegestane WSL-workspaces en de beschermde uitzonderingen; pas daarna
mag een testpayload ontstaan.

## Tags

`@server-state`

## Given

- De Windows-template bevat de bestaande sandbox- en managed security-locks.
- De bevestigde intake bevat:
  - `/home/dev/work/client-a` als `read-write`;
  - `/home/dev/work/reference` als `read-only`;
  - `/home/dev/work/client-a/secrets` als beschermd pad;
  - `/home/dev/.ssh` als beschermd pad;
  - `pkgs.example.test` als toegestaan domein.
- Er bestaat nog geen gegenereerde payload.

## When

De policygenerator draait met het intakebestand en een lokaal uitvoerpad.

## Then

- De payload is geldige JSON.
- Beide workspaces staan in `sandbox.filesystem.allowRead`.
- Alleen `/home/dev/work/client-a` staat in `sandbox.filesystem.allowWrite`.
- Beide beschermde paden staan in `sandbox.filesystem.denyRead`.
- Voor beide beschermde paden staat een overeenkomstige `Read(...)`-regel in
  `permissions.deny`.
- `pkgs.example.test` staat in `sandbox.network.allowedDomains`.
- `failIfUnavailable`, `allowUnsandboxedCommands`, `allowManagedReadPathsOnly`,
  `allowManagedDomainsOnly` en `wslInheritsWindowsSettings` behouden hun veilige waarden.
- De gegenereerde payload slaagt voor `check-configs.sh`.
- Genereren, `check-configs.sh` en de plaatsingspoort gebruiken één gedeelde definitie
  voor padnormalisatie, locks, beschermde-paddekking en intake-workspace-dekking.
- De plaatsingspoort weigert een na generatie verzwakte of onvolledige payload.
- Een tweede generatie naar hetzelfde pad faalt zonder `--force`.
- `~/repos` blijft in `allowRead` en `allowWrite` staan voor de testfixtures.
- Een intake zonder `confirmed: true` of zonder `askedVia` faalt zonder uitvoerbestand.
- `/mnt` als workspace faalt tenzij zowel `allowWindowsMounts` als
  `allowWindowsMountsConfirmed` true zijn.

## Rejection scenarios

### Given

Een intake noemt `/`, `/home`, `~` of een pad onder `/mnt` als workspace zonder
`allowWindowsMounts: true`.

### When

De generator draait.

### Then

- De generator eindigt met een niet-nul exitcode.
- De fout noemt het afgewezen pad en de reden.
- Er wordt geen gedeeltelijk uitvoerbestand achtergelaten.

### Given

De intake probeert een bestaande security-lock te verzwakken of bevat een conflict met de
bestaande managed settings.

### When

De generator draait.

### Then

- De generator stopt met een concrete conflictmelding.
- De bestaande managed settings en het uitvoerpad blijven ongewijzigd.

### Given

`local/consent.json` of `local/policy-input.json` ontbreekt, of de intake is niet bevestigd.

### When

`./install-prereqs.sh`, `./generate-policy.sh`, `./place-policy.sh`, `./bring-workspace.sh bind`
zonder `--i-approved-bind`, of `./run.sh` (groen) draait.

### Then

- Het script eindigt met een niet-nul exitcode.
- Er wordt niets geïnstalleerd, gegenereerd of geplaatst.
- De fout noemt het ontbrekende bestand of de ontbrekende bevestiging.

De generate-poort valideert precies het intakepad dat als eerste argument aan
`generate-policy.sh` is gegeven; een ander geldig `local/policy-input.json` mag een
ongeldige gekozen intake niet maskeren.

Voor plaatsing maakt `tools/placement_gate.py` pas na alle controles
`local/placement-manifest.json`. Dat manifest bindt consent, intake, beginstaat,
snapshot, rollback-roundtrip, rode nulmeting, referentietemplate en de exacte payload
met SHA-256 aan elkaar. Zowel `place-policy.sh` als direct gebruik van
`place-policy.ps1 -Manifest ...` verifieert dit manifest opnieuw. De PowerShell-adapter
accepteert geen losse payloadbron.

De laptopproef bewaart daarnaast bewezen faseovergangen in het append-only,
hash-gekoppelde `local/trial-lifecycle.jsonl`. `tools/trial_lifecycle.py` biedt alleen
`status`, `verify`, `plan` en `record`: de shell- en PowerShellscripts blijven de adapters
die OS-acties uitvoeren. Plaatsing, volledige verificatie, policy-rollback en de
post-rollback runtimecontrole binden elk een lokaal bewijsbestand met SHA-256. Een
onderbroken plaatsing/rollback, gewijzigde bewijsfile of verbroken hashketen blokkeert
volgende acties. Cleanup wordt nooit door de module uitgevoerd en is pas planbaar nadat
`policy-removed` én `runtime-verified` zijn bewezen.
