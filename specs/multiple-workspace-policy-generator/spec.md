# Multiple workspace policy generator

## Why

Een Windows-laptop mag niet ongemerkt de vaste PoC-aanname `~/repos` overnemen. De gebruiker
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
- Een tweede generatie naar hetzelfde pad faalt zonder `--force`.

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
