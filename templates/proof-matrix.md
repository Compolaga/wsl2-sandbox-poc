# Bewijsmatrix — invullen aan het einde van de run

`run.sh` schrijft een ingevulde kopie naar `evidence/<stempel>/proof-matrix.md`. Dit bestand
is het handmatige noodsjabloon; de automatische rijen en vrijgavepoorten komen uit
`specs/acceptance-catalog.json`. Vul ontbrekende handmatige rijen aan met **pass**, **fail**, **ongeldig**,
**niet gedraaid** of **handmatig nog open**.
Claim nooit "de sandbox houdt" als een rij die hieronder als vrijgavepoort staat nog open is.

Laptop: ____________________   Distro/user: ____________________   Datum: __________

| AC / controle | Wat het bewijst | Uitkomst | Bewijs |
|---|---|---|---|
| A1–A11 | Aannames van deze laptop | | |
| Installatie-toestemming | Gebruiker heeft ja gezegd vóór apt/npm/WSL | | AskUserQuestion |
| Workspace-intake | Gekozen roots + blacklist bevestigd | | `local/policy-input.json` |
| Windows → WSL | Gekozen Windows-mappen staan in Linux, niet als symlink naar `/mnt` | | `bring-workspace.sh` |
| `check-configs.sh` payload | Locks en `_beschermd` overleefden de merge | | |
| `selftest.sh` | Het harnas kan falen | | *geen* sandbox-bewijs |
| `run.sh --red` | Containmentproeven lekken zonder policy | | |
| `run.sh` groen | Canary komt niet terug; toegestane paden wel | | |
| AC-04 / 08 / 18 | Read-tool op expliciete deny-paden | | |
| AC-09b | Read-tool geeft een toegestaan bestand wél terug | | |
| AC-14 | Zonder bwrap start Claude Code niet | | handmatig |
| AC-15 | Alleen het Windows-bestand maakt de policy actief in WSL | | handmatig |
| AC-16 | Zonder `wslInheritsWindowsSettings` verdwijnt het effect | | handmatig; zonder AC-16 bewijst AC-15 niets |
| AC-21 | MCP toevoegen in de distro wordt geweigerd | | handmatig |
| AC-23 | Interactief: pad buiten `permissions.deny` vraagt goedkeuring | | handmatig, geen containment |
| AC-24 | `cmd.exe` leest de canary niet vanuit de sandbox | | plus voorwaarde dat `cmd.exe` erbuiten wél werkt |
| VERIFICATIE.md | Twaalf interactieve controles in een gewone sessie | | |

## Nog niet vrijgegeven — dit blijft open

- [ ] Tweede **developer-laptop** (niet de laptop waarop deze run draaide) heeft dezelfde matrix groen, inclusief AC-16 en VERIFICATIE.md.
- [ ] OQ-1: echte klantdatapaden staan in `_beschermd`, niet alleen fixtures.
- [ ] Policy is teruggedraaid of bewust blijven staan; rollbackmarker gecontroleerd.
- [ ] Fixtures opgeruimd (`VERIFICATIE.md` § Opruimen).

Zonder de tweede developer-laptop is dit een proef op één machine, geen uitrolklaar bewijs.
