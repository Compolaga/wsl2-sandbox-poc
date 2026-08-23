# Open vragen

Twee vragen staan open: OQ-6 en OQ-8. OQ-5 en OQ-7 zijn opgelost. Twee zijn niet beantwoord
maar uitgesteld tot de implementatie met ITOps: OQ-1 en OQ-2.

Het zwaarste risico zit niet bij de open vragen maar bij de uitgestelde: zolang OQ-1 niet
beantwoord is, beschermt de policy fixture-paden en niet de echte klantdata.

Voor een macOS-proef komt **OQ-8 als eerste aan de beurt** — verkeerd gokken sluit je daar
direct buiten. OQ-8 raakt de Windows-payload niet, omdat die een expliciete `allowRead`
heeft. **OQ-6** is geen technische onzekerheid maar een beslissing die ITOps voor uitrol
moet nemen, en staat daarom in de vrijgavepoort van de README. OQ-7 moet op een nieuwe
doellaptop als regressiecontrole worden herhaald, maar de onderzoeksvraag zelf is beantwoord.

| # | Vraag | Stand |
|---|---|---|
| OQ-1 | Waar staat de geïnventariseerde gevoelige data? | **Uitgesteld** tot de implementatie. Eigenaar: Luc en ITOps samen. Voor de proef niet nodig — de fixture plant canaries op alle kandidaat-locaties — maar tot dit beantwoord is beschermt de policy fixture-paden, niet de echte. |
| OQ-2 | Welke toolchains gebruiken ZET-developers? | **Uitgesteld** tot de implementatie. Eigenaar: ITOps. Luc gaf 21-08 aan: bijna allemaal, proef doet alleen Node. `allowRead` en `allowedDomains` zijn daarop teruggebracht. |
| OQ-3 | Wat staat er nú in ITOps' `managed-settings.json`? | **Beantwoord** 21-08 via screenshot. Zie [decisions.md](decisions.md), "Wat ITOps nu heeft". |
| OQ-4 | Welke Claude Code-versie rolt ZET uit? | **Beantwoord** door Luc, 21-08: latest. Of elke gebruikte key in die versie zit is niet nagetrokken — A10 in de handoff draagt ITOps op dat per key in de documentatie te doen. |
| OQ-5 | Hoe blokkeer je MCP in WSL2? | **Opgelost.** Via settings-keys in plaats van `managed-mcp.json` — die route is gemeten. Zie hieronder. |
| OQ-6 | Kan een developer interactief goedkeuring geven voor lezen buiten de werkdirectory? | **Open.** Zie hieronder — dit is het gat dat AC-23 blootlegt. |
| OQ-7 | Waarnaar resolvet `~` in een configbestand op de Windows-kant, gelezen vanuit de distro? | **Opgelost 22-08-2026.** Gemeten in Azure WSL2: naar de Linux-home (`/home/dev`), niet het Windows-profiel. Bewijs in `evidence/wsl2-dev-20260822-100200/`; herhaal als regressiecontrole op de doellaptop. |
| OQ-8 | Wat doet `allowManagedReadPathsOnly: true` als er géén `allowRead` in de managed config staat? | **Open, en het raakt je eigen laptop het eerst.** Zie hieronder. |

## OQ-5 — MCP blokkeren in WSL2: opgelost, en anders dan gedacht

**Je hoeft `managed-mcp.json` niet de distro in te krijgen.** Dezelfde blokkade is uit te
drukken in settings-keys, en van die route is op 21-08-2026 gemeten dat hij de WSL-grens
oversteekt.

`managed-mcp.json` is een standalone bestand met eigen paden per platform; over meereizen met
`wslInheritsWindowsSettings` zegt de documentatie niets, en dat is dus een gok. Maar
`allowedMcpServers` en `allowManagedMcpServersOnly` zijn gewone settings-keys, en die zitten
in het bestand waarvan we hebben gemeten dat Claude Code het in de distro leest.

In de configs staat nu:

```json
"allowManagedMcpServersOnly": true,
"allowedMcpServers": []
```

Een **lege array** betekent: geen enkele server toegestaan. Wil ZET bepaalde servers wél,
vul die lijst dan met de servers uit ITOps' bestaande `managed-mcp.json`, herkenbaar aan
hun `serverUrl` of `serverCommand` — niet aan hun naam, want die kan een developer zelf
kiezen. `allowManagedMcpServersOnly` zorgt dat hij de lijst niet kan oprekken.

**Er ligt al een tweede laag:** ITOps' `permissions.deny` bevat `mcp__*`, wat elke
MCP-tool blokkeert. Ook een settings-key, dus die reist ook mee. Servers kunnen dan hooguit
laden, maar hun tools zijn onbruikbaar.

**Wil je het toch dubbel**, dan kan `managed-mcp.json` alsnog de distro in via een
Intune-script dat `wsl -d <distro> -u root cp …` naar `/etc/claude-code/managed-mcp.json`
doet. Let dan op de valkuil die we gemeten hebben: Intune draait als SYSTEM, en WSL weigert
onder dat account.

## OQ-6 — de Read-laag beschermt alleen wat er letterlijk in staat

De sandbox-laag kent een inversie: `denyRead: ["~/"]` met `allowRead: ["~/repos"]` zet de
hele home dicht op één map na. De Read-laag kent die niet, want deny wint daar altijd van
allow — `deny ~/**` met `allow ~/repos` zou het project ook dichtgooien. Voor de Read-tool
geldt dus alleen de expliciete lijst in `permissions.deny`.

Wat daarbuiten valt is niet geblokkeerd maar **goedkeuringsplichtig**: lezen buiten de
werkdirectory vraagt de developer om toestemming. In een niet-interactieve run (`claude -p`,
zoals de testsuite) mislukt dat en lijkt het op containment. In een interactieve sessie —
wat developers de hele dag gebruiken — klikt de developer die toestemming gewoon weg.

Daarom is AC-23 geen containment-test maar een handmatige constatering. **De vraag aan
ITOps:** dicht de uitrol dat af, bijvoorbeeld door een vaste `defaultMode` of door lezen
buiten de werkdirectory te blokkeren? Zo niet, dan is de gedragsregel dat elk gevoelig pad
letterlijk in `permissions.deny` moet staan, en is de inventaris uit OQ-1 geen luxe maar
een voorwaarde.

## OQ-7 — waarnaar resolvet `~` over de WSL-grens? [OPGELOST 22-08-2026]

`config/managed-settings.windows.json` staat op de Windows-kant maar wordt gelezen door de
client in de distro. Alle paden erin gebruiken `~/`. Resolvet die tilde naar het
Windows-profiel in plaats van naar `/home/<user>`, dan is `denyRead: ["~/"]` in de distro
leeg en is er geen enkele bescherming — terwijl de config er correct uitziet.

**Gemeten, 22-08-2026:** `~` resolvet in de distro naar de Linux-home (`/home/dev`), niet
naar het Windows-profiel — en de containmentmeting met precies deze paden hield
(`evidence/wsl2-dev-20260822-100200/`). Het risico hieronder heeft zich dus niet
voorgedaan; de tekst blijft staan als uitleg waarom de meting nodig was.

AC-15 beantwoordt dit als je erop let: gaan de containment-tests met alleen het
Windows-bestand niet groen terwijl de config klopt, dan is dit de reden. De uitwijk is
vooraf te kiezen: schrijf de paden als `//home/<user>/**` in plaats van `~/`, of gebruik in
`allowRead`/`denyRead` een expliciet absoluut pad per developer.

## OQ-8 — een lege managed allowRead met de lock aan

`config/managed-settings.macos-test.json` zet `allowManagedReadPathsOnly: true` en heeft
bewust geen `allowRead`. De aanname in dat bestand is dat de lock alleen `allowRead`-regels
uit lagere scopes negeert en dat alles buiten `denyRead` gewoon leesbaar blijft. Die aanname
staat nergens in de documentatie; bij elke andere claim in [decisions.md](decisions.md) staat
een bron, bij deze niet.

Is de aanname fout, dan is de effectieve leeslijst leeg en kan Claude Code op die machine
niets meer lezen — precies het buitensluiten dat de README belooft te voorkomen, en de
preflight in `run.sh` slaat er niet op aan, want die kijkt alleen naar een brede `denyRead`.

**Verifieer het vóór je de config installeert, niet erna.** Zet het bestand neer en draai als
eerste:

```bash
./run.sh AC-20
```

AC-20 leest `~/repos/probe-7f3a91b2/deelproject/app.js`, een pad dat buiten de smalle
`denyRead` valt. Blijft die groen, dan klopt de aanname. Gaat hij rood, draai dan meteen
`./unlock.sh` — dan is de lock strenger dan gedacht en hoort er een expliciete `allowRead` in
de managed config.
