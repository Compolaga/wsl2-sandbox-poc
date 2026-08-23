# Besluiten en waar ze vandaan komen

De sandbox dekt alleen Bash en zijn subprocessen; Claude's eigen Read-tool valt erbuiten.
Daarom bestaat elke config uit twee lagen die dezelfde paden dragen. Dat is de bevinding
waar de hele opzet op rust — de rest van dit document is de onderbouwing.

## Repository-interface, 23-08-2026

`bin/sandbox` is de enige stabiele publieke commandoregelinterface. De shell- en
PowerShellbestanden onder `scripts/` zijn interne platformadapters: hun locatie en
onderlinge aanroepen mogen veranderen zonder dat gebruikers nieuwe commando's hoeven te
leren. Deze migratie is bewust breaking voor automatisering die rechtstreeks naar de
voormalige rootscripts verwees; er blijven geen forwarding wrappers in de root achter.

De inhoudelijke policy-, lifecycle-, bewijs- en veiligheidsregels zijn niet gewijzigd.
Alleen de interface, Engelse bestandsnamen en repository-indeling zijn aangepast. De
PowerShelladapters blijven rechtstreeks bruikbaar wanneer een Windows-adminsessie vereist
is; hun volledige pad onder `scripts/windows/` moet dan expliciet worden gebruikt.

## Feiten uit de documentatie

Elk citaat hieronder is op 21-08-2026 letterlijk teruggevonden in de opgehaalde documentatie
van code.claude.com; de schemaregels komen uit het JSON-schema op json.schemastore.org. Een
beoordelingsronde markeerde deze als ongeverifieerd — dat is hersteld, ze zijn stuk voor stuk
nagetrokken.

| Feit | Bron |
|---|---|
| Sandbox draait op macOS, Linux en WSL2; native Windows niet | [sandboxing](https://code.claude.com/docs/en/sandboxing#get-started) |
| WSL2 gebruikt bubblewrap + socat, net als Linux | [sandboxing](https://code.claude.com/docs/en/sandboxing#os-level-enforcement) |
| **De sandbox dekt alleen Bash en zijn subprocessen** | [sandboxing](https://code.claude.com/docs/en/sandboxing#permission-rules): *"It applies only to Bash commands and their child processes."* |
| De Read-tool blokkeer je met een `permissions.deny` `Read(...)`-regel; die wordt óók in de sandbox-config gemerged | zelfde sectie |
| Whitelisten kan: `denyRead: ["~/"]` + `allowRead` | [sandboxing](https://code.claude.com/docs/en/sandboxing#filesystem-isolation) |
| Een deny houdt stand binnen een bredere allow, ook met wildcard: `allowRead: ["~/"]` met `denyRead: ["~/**/.env"]` blokkeert elke `.env` en laat de rest leesbaar | [sandboxing](https://code.claude.com/docs/en/sandboxing#filesystem-isolation), tabel "When read rules overlap" |
| Deny wint altijd van allow, en een managed regel is door geen enkele lagere scope te overrulen | [permissions](https://code.claude.com/docs/en/permissions) |
| `allowRead` merget over álle scopes → zonder `allowManagedReadPathsOnly` rekt een dev zijn eigen whitelist op | [sandboxing](https://code.claude.com/docs/en/sandboxing#keep-developers-from-widening-the-policy) |
| Padregels gelden alleen voor `Read(...)` en `Edit(...)`; een `Write(...)`-padregel wordt nooit geraadpleegd | [permissions](https://code.claude.com/docs/en/permissions) |
| `Read(**/x)` is verankerd aan de werkdirectory; `Read(//**/x)` aan de filesystem-root | [permissions](https://code.claude.com/docs/en/permissions) |
| Server-managed settings (Admin Console) zijn *"a client-side control, not a security boundary"* | [server-managed-settings](https://code.claude.com/docs/en/server-managed-settings#security-considerations) |
| **WSL start Windows-binaries over een Unix-socket; de sandbox kan die alleen blokkeren met de optionele seccomp-filter** | [sandboxing](https://code.claude.com/docs/en/sandboxing#set-up-linux-and-wsl2), WSL2-notes |
| Op Ubuntu 24.04+ blokkeert AppArmor de user namespaces die bubblewrap nodig heeft | [sandboxing](https://code.claude.com/docs/en/sandboxing#set-up-linux-and-wsl2) |

**Afgeleid, niet letterlijk gedocumenteerd:** dat WSL2 zónder `wslInheritsWindowsSettings`
alleen `/etc/claude-code/` leest. De schemabeschrijving zegt wat er gebeurt als de vlag aan
staat ("reads managed settings from the Windows policy chain **in addition to**
/etc/claude-code"), niet wat er zonder gebeurt. AC-16 is de verifier.

**Tegenstrijdige bronnen, nog niet beslecht:** over de betekenis van één slash in
`sandbox.filesystem`-paden. De prose-documentatie zegt dat `/tmp/build` absoluut is en
benoemt expliciet dat dit verschilt van permission-regels. De schemabeschrijving van
`allowWrite` zegt daarentegen dat `/` "relative to settings file" is en `//` absoluut. De
configs volgen de prose-doc. **AC-07 is de enige test die de vraag echt beantwoordt:** die
raakt `denyRead: ["/mnt/"]`, en lekt de canary uit het Windows-profiel, dan wordt `/mnt/`
niet als absoluut pad gelezen en had het schema gelijk. Draait alleen op WSL2.

AC-10 was hier eerder ook als verifier genoemd, maar dat is bij nader inzien onjuist. De
standaard van de sandbox is *lezen mag overal behalve wat je denyt*; `/usr`, `/bin` en de
andere systeempaden in `allowRead` vallen buiten onze deny-lijst en zijn dus hoe dan ook
leesbaar. Die entries doen op dit moment niets en staan er defensief in, voor het geval de
deny-lijst ooit breder wordt. Een falende build zegt daarom niets over de slash-vraag — hij
heeft een handvol waarschijnlijker oorzaken.

Gaat AC-07 rood, dan krijgen alle absolute paden in de drie configs een dubbele slash.
`Read(//mnt/**)` in `permissions.deny` gebruikt die al, want daar is de dubbele slash
onbetwist.

Een tweede ambiguïteit van dezelfde soort stond als OQ-7 in
[open-questions.md](open-questions.md): waarnaar `~` resolvet in een configbestand dat op de
Windows-kant staat en vanuit de distro wordt gelezen. Die vraag is op 22-08-2026 beantwoord;
zie de meting hieronder.

## Gemeten, 22-08-2026

**De sandbox houdt óók in WSL2, als gewone gebruiker — en de developer kan de policy niet
oprekken.** Zelfde Azure-opzet, nu WSL 2.7.12, distro via `wsl --import` (sha256 van de
rootfs geverifieerd), gemeten als gebruiker `dev` (uid 1001), niet als root. Alle negen
containmentproeven deden wat bedoeld: beschermde paden dicht (ook via child- en
grandchild-processen, symlink-omweg en recursieve grep, én bestand/submap ín een toegestane
map), terwijl het gewone bestand ernaast leesbaar bleef en schrijven in het project werkte —
die twee open proeven zijn de controle dat er niet simpelweg álles dichtzat, zoals in de
ongeldige root-run van 21-08. Verder gemeten: AC-11/12/13 (eigen `settings.json` met
`requiredMinimumVersion: "0.0.1"` en `sandbox.enabled: false` — managed wint beide keren),
AC-14 (bwrap weggehaald → Claude Code weigert te starten op de sandbox-afhankelijkheid) en
AC-24 mét voorwaardetest: `cmd.exe` was buiten de sandbox aanroepbaar en vanuit de sandbox
geblokkeerd (srt 0.0.73, met seccomp-filter). OQ-7 is daarmee ook beantwoord: `~` resolvet
in de distro naar de Linux-home (`/home/dev`), niet naar het Windows-profiel. Bewijs:
`evidence/wsl2-dev-20260822-100200/` (meting + provenance).

In deze Azure-meting niet gemeten, want dat vraagt een ingelogde Claude: de
Read-tool-laag (AC-04/08/18) en gedrag in een echte interactieve sessie. De VM is na de
meting verwijderd. Die laag is later wel handmatig op een Windows-laptop geverifieerd; zie
de aanvulling hieronder.

## Geautomatiseerde Claude-probes in WSL2, 22-08-2026

Een volgende Azure-run gebruikte wel een geldige ingelogde Claude (2.1.239), maar leverde
bewust geen groen bewijs op. De auto-permission/tool-classifier onderschepte de
markerconstructie vóór de eigenlijke Bash-probe: achtereenvolgens shell-expansies, een
vooraf geschreven script, een base64/Python-wrapper, accolades en subshells; de volledig
leesbare losse commandoketen werd goedkeuringsplichtig. `bin/sandbox test` markeerde dit als ONGELDIG
in plaats van containment te claimen. De Read-pogingen AC-04/08/18 leken geblokkeerd, maar
AC-09b (de toegestane positieve Read-controle) vroeg eveneens toestemming, zodat ook die
uitkomsten terecht ongeldig bleven. Bewijs:
`evidence/20260822-133237/`, `evidence/20260822-135058/`,
`evidence/20260822-135634/`, `evidence/20260822-140122/` en
`evidence/20260822-140644-AC-00p/`.

Besluit: de geautomatiseerde `claude -p`-suite blijft een fail-closed diagnostisch hulpmiddel,
maar is geen vrijgavepoort. De interactieve controles in [VERIFICATION.md](VERIFICATION.md)
zijn leidend voor de Read-laag en de Bash-probes; `bin/sandbox self-test` en
`bin/sandbox policy validate` blijven
wel volledig geautomatiseerd.

## Windows-laptopproef, 22-08-2026

Op een echte Windows 11-laptop (WSL 2.3.24, Ubuntu 24.04, Claude Code 2.1.240 in de distro)
werden de geautomatiseerde acceptatietests groen ná een lokale `bin/sandbox test`-patch en na
stille root-installaties. AC-14 en AC-21 zijn daar handmatig gedaan; AC-16, AC-23 en
VERIFICATION.md niet. De agent vroeg geen workspaces en liet de policy actief staan.

Besluit: de kern van de sandbox is herhaalbaar op hardware, maar de handoff is pas
agent-klaar met AskUserQuestion-poorten die de CLI afdwingt (`bin/sandbox install`,
`bin/sandbox policy generate`, `bin/sandbox policy place`, groene `bin/sandbox test`), een gegenereerde
workspace-payload en een bewijsmatrix die één laptop niet als vrijgave telt. Zie
[HANDOFF.md](HANDOFF.md#agentpoort--eerst-vragen-dan-pas-doen).

De teardown van diezelfde dag is mislukt: geen distro-snapshot, UAC bij terugdraaien drie
keer weggeklikt, `bwrap` eerder weg dan de policy. Besluit: geen snapshot betekent geen
proef; afbreken in omgekeerde volgorde; `bin/sandbox fixtures clean` is geen teardown. Zie
[HANDOFF.md § Terugdraaien](HANDOFF.md#terugdraaien).

### Aanvullende verificatie op Windows-laptop, uitgevoerd 23-08-2026

**De automatische suite én de handmatige controles uit `VERIFICATION.md` zijn op 23-08-2026
op een Windows-laptop groen doorlopen, inclusief de Read-tool-controles AC-04/08/18.**
Daarmee is de eerdere status “nog niet gemeten” achterhaald; die status hierboven beschrijft
alleen de eerste laptopproef van 22-08.

De ruwe uitvoer van deze aanvullende run staat niet in de publieke clone. Dit is daarom een
gedateerde, aan Luc herleidbare meetconclusie, geen bewijs dat een lezer uit deze repository
zelf kan controleren. Voor uitrol moet ITOps dezelfde automatische en handmatige route na
Intune-uitrol op een tweede developer-laptop herhalen en de bewijsmatrix bewaren.

### OQ-6 opgelost: interactieve Read-goedkeuring is geaccepteerd, 23-08-2026

**ITOps accepteert dat de Read-tool alleen de expliciete paden in `permissions.deny`
afdwingbaar blokkeert.** Paden daarbuiten kunnen interactief een goedkeuringsvraag geven;
AC-23 blijft dit op iedere doellaptop handmatig controleren. Luc bevestigde op 23-08-2026
dat hiervoor geen aanvullende blokkade of apart vrijgavebesluit nodig is en dat ITOps deze
werking accepteert.

Gevolg: OQ-6 is geen open vrijgavevoorwaarde meer. De inventarisatie uit OQ-1 blijft wel
verplicht, omdat ieder werkelijk gevoelig pad expliciet in `permissions.deny` moet staan.

## Gemeten, 21-08-2026

**wslInheritsWindowsSettings werkt — bewezen in een echte WSL2-omgeving.** Azure VM,
Windows Server 2022, WSL 2.3.26, Ubuntu 24.04, Claude Code 2.1.238. Op
`C:\Program Files\ClaudeCode\managed-settings.json` stond de vlag plus
`requiredMinimumVersion: "999.0.0"`; in `/etc/claude-code/` stond niets. Claude Code in de
distro weigerde te starten:

> Claude Code 2.1.238 is older than the minimum version required by your organization (999.0.0).

Negatieve controle: zelfde bestand, zelfde versie-eis, alleen de vlag weggehaald — dan komt
hij gewoon door tot de inlogcontrole. **De policy bereikt de distro, en alleen dankzij die
vlag.** Er was geen inlog voor nodig: een policy-key met een opstart-effect volstaat als
meetinstrument. Bewijs: `evidence/wsl2-*/wsl2.txt`.

**WSL2 kent de AppArmor-restrictie niet.** `kernel.apparmor_restrict_unprivileged_userns`
bestaat er niet ("geen-sleutel"), anders dan op Ubuntu op bare metal waar hij op 1 stond.
Voorwaarde A4 geldt dus voor een gewone Ubuntu-machine, maar naar het zich laat aanzien niet
voor WSL2. Controleer hem toch, want dit is één distro-versie op één machine.

**Vier dingen over de uitrol, alle vier gemeten** — drie ervan staan slecht of niet
gedocumenteerd, de vierde juist wel:

1. WSL weigert te draaien onder een SYSTEM-account (`WSL_E_LOCAL_SYSTEM_NOT_SUPPORTED`).
   Intune draait als SYSTEM, dus `wsl` aanroepen vanuit een Intune-script werkt niet.
2. WSL-distro's zijn per gebruiker geregistreerd, in
   `HKCU\Software\Microsoft\Windows\CurrentVersion\Lxss`. Wat SYSTEM installeert, bestaat
   niet voor de developer (`WSL_E_DISTRO_NOT_FOUND`).
3. `wsl --install -d Ubuntu --no-launch` meldt "Ubuntu has been installed. The operation
   completed successfully" en registreert de distro toch niet — `wsl --list` zegt daarna
   "no installed distributions". Niet Server-specifiek: hetzelfde is op regulier Windows
   gemeld in [microsoft/WSL#10646](https://github.com/microsoft/WSL/issues/10646).
4. `wsl --import` met een rootfs-tarball van cloud-images.ubuntu.com is wél volledig
   scriptbaar. Dat is niet alleen wat bij ons werkte: Microsoft noemt `wsl --export`/`--import`
   van een goedgekeurd image expliciet als ondersteunde enterprise-route
   ([WSL for your company](https://learn.microsoft.com/en-us/windows/wsl/enterprise)).
   Verifieer de tarball wel tegen `SHA256SUMS` en `SHA256SUMS.gpg` uit dezelfde map.

**De OS-laag houdt.** In een Ubuntu 24.04-container met bubblewrap 0.9.0 en
`@anthropic-ai/sandbox-runtime` 0.0.73, met ons eigen `sandbox.filesystem`-blok uit
`config/settings.slice1.json`: negen probes, negen keer zoals bedoeld. Beschermde paden dicht
via `cat`, via een child-shellscript, via een grandchild python-subprocess, via een symlink
vanuit de toegestane map, en voor een willekeurig ander pad in de home. Het project bleef
lees- en schrijfbaar. Het historische bewijs blijft bewaard in
`evidence/bubblewrap-*/bubblewrap.txt`. De bijbehorende Docker-reproductieroute is bewust
verwijderd: die vereiste `--privileged`, kon de Windows- en WSL2-grenzen niet toetsen en is
inmiddels ingehaald door de sterkere metingen op echte Linux-hardware en in WSL2.

**Het patroon "map open, bestanden erin dicht" werkt.** Dat was onzeker: de README van
`sandbox-runtime` zegt *"allowRead takes precedence over denyRead"*, wat zou betekenen dat een
allow op `~/repos` een deny op `~/repos/**/config-a.txt` overruled. Gemeten gedrag is het
omgekeerde — de specifiekere deny wint. Probe 6 en 7 zijn dicht terwijl `app.js` ernaast
leesbaar blijft.

**Op echte Linux-hardware houdt het ook, als gewone gebruiker.** Dezelfde negen probes op
valto-mcp (Hetzner Cloud, Ubuntu, kernel 6.8.0-90), gedraaid als een niet-root gebruiker
zonder container en zonder verhoogde rechten: negen keer zoals bedoeld. Dat is strenger dan
de Docker-meting, waar `--privileged` nodig was omdat Docker unprivileged user namespaces
blokkeert. Bewijs: `evidence/linux-native-*/linux-native.txt`.

**Voorwaarde A4 is gemeten, niet aangenomen.** Op die Ubuntu stond
`kernel.apparmor_restrict_unprivileged_userns` op 1. Met die lock aan faalt bwrap voor een
gewone gebruiker met `bwrap: setting up uid map: Permission denied`. Met de lock uit werkt
hij. Dat bevestigt A4 uit de handoff: op Ubuntu 24.04 en later moet die restrictie eerst
geregeld worden, anders start de sandbox niet.

**Hetzner kan geen WSL2 leveren.** `valto-mcp` is zelf een KVM-gast: geen `/dev/kvm`, geen
`vmx`/`svm`-flags, dus er kan geen VM op draaien. Hetzner Cloud biedt geneste virtualisatie
op geen enkele instance; alleen hun dedicated (bare metal) lijn zou het kunnen, en dat is een
nieuwe server huren. De server is na de meting weer schoon achtergelaten: testgebruiker,
pakketten en de sysctl-wijziging zijn teruggedraaid, productie draait ongewijzigd door.

**Azure kan het wel.** Op een `Standard_D2s_v3` in west-europe met Windows Server 2022,
gemeten in de gast zelf: `VirtualizationFirmwareEnabled: True` en
`SecondLevelAddressTranslation: True` — dat is precies wat Hyper-V en daarmee WSL2 nodig
hebben. De features `Microsoft-Windows-Subsystem-Linux` en `VirtualMachinePlatform` lieten
zich installeren met "The operation completed successfully". Kosten ongeveer EUR 0,10 per
uur. Script: `test-lab/azure-wsl2-vm.sh`.

**Een Windows-VM op deze Mac kan geen WSL2 draaien.** Geneste virtualisatie is er voor
Windows-ARM-gasten niet op Apple Silicon. Parallels' eigen documentatie zegt het letterlijk:
*"Nested Virtualization is not available. If you plan to use Hyper-V or Hyper-V-based
technologies inside Windows, this will not work."* en *"WSL2 also will not work; use WSL1 as a
workaround."* ([Parallels KB 129497](https://kb.parallels.com/en/129497)). UTM's geneste
virtualisatie werkt alleen voor Linux-gasten. De WSL-specifieke vragen (OQ-7, AC-15, AC-16,
AC-24) zijn dus alleen te beantwoorden op echte Windows-hardware of een cloud-VM met geneste
virtualisatie.

## Besluiten van Luc, 21-08-2026

Uit de grillingronde; de annotaties liggen op Lucs machine en zijn niet nodig om dit uit te
voeren.

- Whitelisten, niet blacklisten.
- Alle claims bewijzen door uit te voeren, zo dicht mogelijk op de doelomgeving.
- Admin Console valt af: Luc is Admin, geen Owner, en wil geen org-brede policy zetten.
- ITOps rolt `managed-settings.json` al uit via Intune; daar hangt onze config in.
- Repo's kwamen voor de eerste proef in `~/repos` in de distro, niet op `/mnt/c/`.
  **Achterhaald voor uitrol op 22-08-2026:** echte workspaces worden per laptop uit
  bevestigde intake gegenereerd; `~/repos` blijft alleen voor fixtures. Bron: Lucs correctie
  na de eerste Windows-laptopproef en de Agentpoort in `HANDOFF.md`.
- Voor de proef alleen Node als toolchain; uitbreiden gebeurt bij de implementatie.

## Wat ITOps nu heeft

Zijn bestand botst niet met het onze — wij voegen een `sandbox`-blok toe dat er nog niet is,
en onze `Read(...)`-regels breiden zijn lijst uit. Drie dingen moeten wel terug naar hem: er
is vandaag geen Bash-bescherming, negen `Write(...)`-regels doen niets, en vier patronen
missen hun doel. Die drie staan uitgeschreven in [HANDOFF.md](HANDOFF.md).

Wat er nu in `C:\Program Files\ClaudeCode\managed-settings.json` staat: één
`permissions.deny`-lijst met bestandspatronen (`App.config`, `Web.config`,
`appsettings*.json`, `*.pfx`, `*.cer`, `*.kdbx`, `bin/`, `obj/`, `OneDrive*/`) in `Read`-,
`Edit`- en `Write`-vorm, plus `mcp__*`, `cleanupPeriodDays: 7` en
`allowManagedPermissionRulesOnly: true`. Geen `sandbox`-blok.

Zijn aanpak en de onze werken op verschillende assen: hij zwartlijst bestandstypen, wij
witlijsten locaties.
