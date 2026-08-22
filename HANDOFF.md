# Handoff: sandboxing aanzetten voor Claude Code in WSL2

> **De kern is gevalideerd, 21-08-2026.** In een echte WSL2-omgeving (Windows Server 2022,
> WSL 2.3.26, Ubuntu 24.04) is gemeten dat een policy op
> `C:\Program Files\ClaudeCode\managed-settings.json` daadwerkelijk door Claude Code in de
> distro wordt gelezen — met negatieve controle. Op 22-08-2026 is ook de rest gemeten, in
> WSL2 als gewone gebruiker: de sandbox houdt (negen containmentproeven, mét de controle dat
> toegestane paden gewoon werkten), de developer kan de policy niet overrulen vanuit zijn
> eigen `settings.json`, zonder bwrap weigert Claude Code te starten, en het `cmd.exe`-gat
> (AC-24) was dicht — met de voorwaardetest dat `cmd.exe` buiten de sandbox wél aanroepbaar
> was. `~` resolvet in de distro naar de Linux-home, niet naar het Windows-profiel. Zie
> [decisions.md](decisions.md) en `evidence/wsl2-dev-20260822-100200/`. Wat nog openstaat:
> de Read-tool-laag (AC-04/08/18), want die vraagt een ingelogde Claude.
>
> Wat in `evidence/` staat aan zelftests toetst het testharnas zelf, niet de sandbox — let bij
> het lezen op welk van de twee je voor je hebt.

Vandaag beschermt `managed-settings.json` alleen de tools Read, Edit en Write. Er is geen
`sandbox`-blok, dus wat een developer via Bash laat draaien is niet begrensd: `cat
appsettings.json` levert gewoon de inhoud. Deze handoff voegt dat blok toe, en zet de
Windows-policy zo dat hij ook geldt binnen WSL2.

**Wat je nodig hebt:** dit document, de map waarin het staat (kopieer hem naar de distro —
`agent-gate.sh`, `install-prereqs.sh`, `generate-policy.sh`, `place-policy.sh`,
`bring-workspace.sh`, `fixture.sh`, `run.sh`, `check-configs.sh`, `unlock.sh` en `config/`
horen erbij),
[README.md](README.md#handmatige-procedures) voor de vijf handmatige procedures, en OQ-6 uit
[open-questions.md](open-questions.md) — die heb je nodig omdat hij bepaalt wat AC-23
betekent. OQ-5 is opgelost via settings-keys; de procedure staat verderop. [decisions.md](decisions.md) is
alleen achtergrond. Moet je WSL2 zelf nog uitrollen, begin dan bij
[Bijlage A](#bijlage-a--wsl2-uitrollen-vanuit-intune).

---

## Agentpoort — eerst vragen, dan pas doen

Dit blok is verplicht voor elke Claude Code- of Cursor-agent die deze handoff uitvoert.
De scripts weigeren verder te gaan tot de antwoorden op schijf staan. Gebruik de
**AskUserQuestion**-tool (Claude Code) of het equivalent in Cursor. Een aanname als "dan
maar `~/repos`" is een fout. Een losse `apt-get`, `npm install -g` of kopie van
`config/managed-settings.windows.json` is een mislukte run.

De Windows-proef van 22-08-2026 faalde precies hier: de agent installeerde bubblewrap, Node
en Claude zonder toestemming, nam `~/repos` als workspace, en claimde daarna dat de sandbox
hield terwijl AC-16, AC-23 en VERIFICATIE.md nog openstonden.

Zonder deze twee bestanden doen de scripts niets:

| Bestand | Na vraag | Voorbeeld |
|---|---|---|
| `local/consent.json` | 1 | [templates/consent.example.json](templates/consent.example.json) |
| `local/policy-input.json` | 2, met `confirmed: true` | [templates/policy-input.example.json](templates/policy-input.example.json) |

### Vraag 1 — installaties

Toon wat er ontbreekt (WSL2, distro, `bubblewrap`, `socat`, Node, Claude Code,
`@anthropic-ai/sandbox-runtime`, `python3`) en vraag per cluster:

- Mag ik WSL2 / de Ubuntu-distro installeren of upgraden?
- Mag ik deze apt-pakketten installeren?
- Mag ik Node / Claude Code / sandbox-runtime globaal installeren of upgraden?

Nee op een cluster betekent: stop, schrijf wat er ontbreekt, installeer het niet zelf.
Schrijf daarna `local/consent.json` en installeer **alleen** via:

```bash
./install-prereqs.sh
```

### Vraag 2 — welke paden mag Claude lezen

Vraag, in deze volgorde, één onderwerp per AskUserQuestion:

1. Welke **Windows- of Linux-mappen** moeten in WSL toegankelijk zijn? Meerdere roots mogen.
2. Welke **bestanden of submappen daarbinnen** moeten juist dicht (blacklist in de whitelist)?
3. Welke extra gevoelige paden buiten die workspaces horen in `permissions.deny`
   (`.ssh`, klantdata, …)?
4. Lees-alleen of ook schrijven, per root?

Windows-mappen haal je de distro in door te **kopiëren**. Dat is de voorgeschreven route,
geen keuze. Bind-mount alleen als copy onmogelijk is **én** na een tweede, aparte
AskUserQuestion; zet dan `bindApproved: true`. Een symlink van een Linux-pad naar
`/mnt/c/...` is verboden — dat is de omweg die AC-06 meet. Van Windows naar
`\\wsl$\<distro>\<linux-pad>` mag wél, als Explorer-koppeling na de kopie.

Vat de antwoorden samen, vraag één bevestiging, en schrijf pas daarna
`local/policy-input.json` met `confirmed: true`. Genereer de payload; installeer die nog
niet:

```bash
./generate-policy.sh local/policy-input.json
./bring-workspace.sh 'C:\Users\naam\src\project' /home/<user>/work/project
```

`~/repos` blijft in de payload staan voor de PoC-fixtures. Gebruik hem nooit als
organisatiekeuze.

### Vraag 3 — policy plaatsen

Pas ná een geldige nulmeting (`./run.sh --red`) vraag je of de gegenereerde payload naar
`C:\Program Files\ClaudeCode\managed-settings.json` mag, en of een UAC-prompt oké is.
Noem het bijeffect: `allowedMcpServers: []` zet MCP in WSL (en vaak ook native) dicht.
Plaats **alleen** via:

```bash
./place-policy.sh
```

Dat script weigert zonder consent, zonder bevestigde intake, zonder gegenereerde payload,
zonder geslaagde rode run, en weigert de statische template.

### Einde van de run

`./run.sh` schrijft `evidence/<stempel>/proof-matrix.md` en toont die tabel. Zeg niet
"de sandbox houdt" als een vrijgaverij nog open is. Wat altijd nog open is na één laptop:

- AC-16 als die niet is gedraaid;
- AC-23 (interactieve Read-goedkeuring);
- de twaalf controles in VERIFICATIE.md als die zijn overgeslagen;
- een **tweede developer-laptop**, niet de machine van deze run.

Pas die tweede laptop, plus OQ-1 en OQ-6, maakt dit uitrolklaar. Eén groene `run.sh` is dat niet.

---

## Veilige proef op één Windows-laptop

Deze route is bedoeld om de handoff lokaal te proberen **vóór** Intune. Gebruik een
testlaptop of een laptop waarop tijdelijk verlies van Claude-toegang acceptabel is. De
Windows-config zet in WSL vrijwel de hele Linux-home en `/mnt/` dicht. Repo's werken alleen
in de **bevestigde Linux-workspaces** plus de PoC-fixtures onder `~/repos`. Een Windows-map
die je niet hebt gekopieerd, is daarna onbruikbaar.

1. **Regel de rollback vóór je de policy plaatst.** Open PowerShell als administrator en
   maak, als het bestand al bestaat, een kopie:

   ```powershell
   $p = "$env:ProgramFiles\ClaudeCode\managed-settings.json"
   $b = "$p.before-wsl2-poc"
   $n = "$p.no-original-before-wsl2-poc"
   if ((Test-Path $b) -or (Test-Path $n)) { throw "Oude PoC-rollbackmarker bestaat al" }
   if (Test-Path $p) { Copy-Item $p $b } else { New-Item $n -ItemType File | Out-Null }
   ```

   Terugdraaien doe je vanuit dezelfde administrator-PowerShell:

   ```powershell
   if (Test-Path $b) {
     Copy-Item $b $p -Force
     Remove-Item $b
   } elseif (Test-Path $n) {
     Remove-Item $p -Force -ErrorAction SilentlyContinue
     Remove-Item $n
   } else {
     throw "Geen PoC-rollbackbestand of -marker gevonden"
   }
   wsl --shutdown
   ```

   `unlock.sh` kan het Windows-bestand alleen signaleren; het kan het niet verwijderen.

2. **Doorloop A1 t/m A11 hieronder, ná de Agentpoort.** Installeer in de distro alleen via
   `./install-prereqs.sh` wat de gebruiker in vraag 1 heeft goedgekeurd. Minimaal nodig:
   `bubblewrap`, `socat`, `python3`, Node, Claude Code en `@anthropic-ai/sandbox-runtime`.
   Die laatste is op WSL onderdeel van de grens: zonder seccomp kan een Windows-binary
   buiten de sandbox lezen. Log in met `claude auth login` voordat je `run.sh` gebruikt.

3. **Kopieer deze hele map naar de Linux-home**, niet naar `/mnt/c`, en draai vóór er een
   policy actief is:

   ```bash
   ./selftest.sh
   ./check-configs.sh --selftest
   ./fixture.sh
   ./run.sh --red
   ./fixture.sh --clean
   ```

   De containmentproeven moeten in `--red` lekken; anders kan het harnas niet aantonen dat
   de latere groene run iets meet.

4. **Maak de testpayload uit de bevestigde intake**, niet uit de vaste `~/repos`-aanname.

   ```bash
   ./generate-policy.sh local/policy-input.json
   ```

   Merge het resultaat met een eventueel bestaand managed bestand; vervang dat bestand niet.
   Op een laptop zonder bestaand bestand mag de gegenereerde payload als tijdelijke proef
   dienen. Let op: een lege `allowedMcpServers` blokkeert alle MCP in WSL. Valideer exact
   het bestand dat je gaat plaatsen:

   ```bash
   ./check-configs.sh local/managed-settings.windows.generated.json
   ```

5. **Plaats de gegenereerde payload** met `./place-policy.sh` (Windows-admin / UAC). Zorg dat
   `/etc/claude-code/managed-settings.json` niet óók bestaat, draai `wsl --shutdown` en open
   de distro opnieuw. De statische `config/managed-settings.windows.json` is geen plaatsbare
   bron.

6. **Volg [VERIFICATIE.md](VERIFICATIE.md).** Dat is de korte hoofdroute en gebruikt
   `fixture.sh` met botsingscontrole en marker-gebaseerde cleanup. Draai daarna desgewenst
   `./fixture.sh && ./run.sh`; zorg dat `claude auth login` is afgerond en ruim altijd op
   via de volledige sectie **Opruimen** in `VERIFICATIE.md`. Die herstelt ook een tijdelijk
   overschreven `~/.claude/settings.json`; alleen `./fixture.sh --clean` doet dat niet.

7. **Lees de bewijsmatrix** die `run.sh` naar `evidence/<stempel>/proof-matrix.md` schrijft.
   Draai bij elk onverwacht effect eerst terug. Test daarna AC-14, AC-15/16, AC-21 en AC-23.
   Deze laptopproef is geen vrijgave voor de vloot: daarvoor moet dezelfde matrix groen zijn
   op een **tweede developer-laptop**, plus OQ-1, OQ-6, proxy/package-feeds en de overige
   aannames.

## Stap 0 — controleer eerst of de aannames kloppen

Dit plan is gebouwd zonder toegang tot jullie omgeving. Het rust op de aannames hieronder.
**Loop ze eerst af op één laptop voordat je iets uitrolt.** Klopt er een niet, dan verandert
dat het plan — bij elke aanname staat wat er dan moet gebeuren.

| # | Aanname | Zo controleer je het | Klopt het niet? |
|---|---|---|---|
| A1 | Developers draaien Claude Code **in WSL2**, niet native op Windows | `wsl -l -v` in PowerShell; en in de distro `which claude` | Native Windows kent geen sandbox. Dan is de eerste stap de overstap naar WSL2, niet deze config — lees dan eerst [Bijlage A](#bijlage-a--wsl2-uitrollen-vanuit-intune). |
| A2 | De distro is **WSL2**, niet WSL1 | `wsl -l -v` toont `VERSION 2` | Bubblewrap vraagt kernelfeatures die WSL1 niet heeft. Upgraden of geen sandbox. Beter dan controleren is afdwingen: de [WSL-settings-catalogus in Intune](https://learn.microsoft.com/en-us/windows/wsl/intune) kent onder meer *Allow WSL1*, *Allow the Inbox version of WSL*, *Allow custom kernel configuration* en *Allow the debug shell*. Zonder die policy kan een developer alsnog zelf een WSL1-distro of een eigen kernel registreren. |
| A3 | `bubblewrap` en `socat` zijn te installeren | `which bwrap socat`, anders `sudo apt-get install bubblewrap socat` | Zonder deze twee start de sandbox niet en blokkeert `failIfUnavailable: true` het starten van Claude Code. |
| A4 | Bubblewrap mag **user namespaces** maken | `sysctl kernel.apparmor_restrict_unprivileged_userns` | Geeft dit `1` (Ubuntu 24.04+), dan is een AppArmor-profiel nodig — zie hieronder. Geeft het `0` of "No such file", dan is er niets te doen. Op WSL2 bestond de sleutel in onze meting niet; controleer hem toch, zie hieronder. |
| A5 | De **seccomp-filter** is geïnstalleerd | `npm install -g @anthropic-ai/sandbox-runtime` | Zonder deze optionele filter kan de sandbox Unix-sockets niet blokkeren, en dat is precies hoe WSL Windows-binaries start. Zie het kader hieronder — dit is geen detail. |
| A6 | Developers hebben **geen lokale admin** op hun laptop | jullie eigen beeld van de werkplekinrichting | Met lokale admin kan een developer `C:\Program Files\ClaudeCode\` bewerken en is dit geen grens maar een vangnet. Dat is een andere belofte; zeg dat dan expliciet. |
| A7 | Repo's staan in de **bevestigde Linux-workspaces** (vaak onder `~/work`, niet per se `~/repos`) | AskUserQuestion; daarna `bring-workspace.sh` (copy) voor Windows-mappen | De policy zet `/mnt/` dicht. Een Windows-repo blijft onbruikbaar tot hij is gekopieerd naar een Linux-pad. Bind alleen na een tweede ja. Symlink naar `/mnt/c` is geen oplossing. |
| A8 | Uitgaand verkeer heeft **geen bedrijfsproxy** nodig | `echo $HTTPS_PROXY` in de distro | Met een proxy hoort `HTTPS_PROXY`/`NO_PROXY` in het `env`-blok van de managed settings, anders breekt de sandbox-egress. |
| A9 | Jullie **interne package-feeds** staan in `allowedDomains` | vergelijk je NuGet/npm-config met de lijst in de config | Ontbreekt de Azure DevOps artifact-feed, dan breekt `dotnet restore` binnen de sandbox. Vul aan vóór uitrol. |
| A10 | Claude Code is een **recente versie** en gebruikt geen third-party provider | `claude --version`; `echo $ANTHROPIC_BASE_URL $CLAUDE_CODE_USE_BEDROCK`; lees de minimumversies van `allowManagedReadPathsOnly`, `allowManagedDomainsOnly` en `wslInheritsWindowsSettings` in de [settings-documentatie](https://code.claude.com/docs/en/settings) | Een te oude versie negeert die keys stil — dan lijkt de policy te staan terwijl de lock niet werkt. Een third-party provider verandert hoe settings geladen worden. |
| A11 | `python3` en `node` zijn aanwezig in de distro | `python3 --version`, `node --version` | De preflights lezen de configs met python; de acceptatietests bouwen met node. Zonder deze weigert `run.sh` te starten of slaat hij tests over. |

**A4 op WSL2: waarschijnlijk niets te doen, maar meet het.** Op 21-08-2026 gemeten: in WSL2
(Ubuntu 24.04, WSL 2.3.26) bestaat `kernel.apparmor_restrict_unprivileged_userns` niet — `sysctl`
meldt daar dat de sleutel er niet is. Op een gewone Ubuntu-machine stond dezelfde sleutel wél op
`1`, en faalde bubblewrap voor een niet-root gebruiker met `bwrap: setting up uid map: Permission
denied`. Dat is één distro-versie op één machine, dus draai de check alsnog op je testlaptop
voordat je concludeert dat het profiel hieronder overbodig is.

**A4, als de sysctl `1` teruggeeft.** Op Ubuntu 24.04 en later blokkeert het standaard
AppArmor-beleid de user namespaces die bubblewrap nodig heeft:

```bash
sudo tee /etc/apparmor.d/bwrap > /dev/null <<'EOF'
abi <abi/4.0>,
include <tunables/global>

profile bwrap /usr/bin/bwrap flags=(unconfined) {
  userns,
  include if exists <local/bwrap>
}
EOF
sudo systemctl reload apparmor
```

Het profiel geldt alleen voor `bwrap` zelf, niet voor wat er binnen de sandbox draait.
**Zonder systemd faalt die laatste regel.** Een distro die via `wsl --import` uit een
rootfs-tarball komt heeft geen `[boot] systemd=true` in `/etc/wsl.conf` en dus geen
`systemctl`. Laad het profiel dan met `sudo apparmor_parser -r /etc/apparmor.d/bwrap`, of zet
in plaats van het hele profiel `kernel.apparmor_restrict_unprivileged_userns=0` in een bestand
onder `/etc/sysctl.d/`.

> ### A5 is geen formaliteit — zonder de seccomp-filter is er een gat
>
> Op WSL2 geeft WSL het starten van een Windows-binary (`cmd.exe`, `powershell.exe`, alles
> onder `/mnt/c/`) door aan de Windows-host **over een Unix-socket**. Of een sandboxed
> commando dat mag, hangt aan de Unix-socket-instellingen van de sandbox, en die kunnen de
> socket alleen blokkeren als de optionele seccomp-filter geïnstalleerd is.
>
> Zonder die filter kan een sandboxed commando dus een Windows-programma starten dat op de
> Windows-kant leest — en daar helpt onze `denyRead` op `/mnt/` niet, want het lezen gebeurt
> buiten de distro. Installeer de filter, en zet `allowAllUnixSockets` bewust: aan betekent
> dat je die route toestaat. **AC-24 in de testsuite meet precies dit.** Op 22-08-2026 was
> `cmd.exe` buiten de sandbox aanroepbaar en vanuit de sandbox geblokkeerd; daarmee is de
> meting inclusief voorwaarde geldig. Herhaal AC-24 op de doellaptop omdat WSL- en
> runtimeversies kunnen verschillen.

Controleer deze punten hard tegen de documentatie in plaats van tegen dit document:
[sandboxing](https://code.claude.com/docs/en/sandboxing),
[settings](https://code.claude.com/docs/en/settings),
[permissions](https://code.claude.com/docs/en/permissions).
Dit plan is geschreven op de documentatie van 21 augustus 2026; wijkt die af van wat je nu
leest, dan is de documentatie leidend en dit document verouderd.

---

## Stap 1 — draai eerst de nulmeting, vóór je iets uitrolt

Op de testlaptop, in de distro, **terwijl er nog geen policy staat**:

```bash
./selftest.sh     # toetst of de suite de juiste conclusie trekt; geen policy-bewijs
./fixture.sh      # zet testbestanden neer met een herkenbare canary-string
./run.sh --red
```

Hier moet elke containment-test juist **lekken**. Doet hij dat niet, dan meet de suite niets
en is elk groen resultaat later betekenisloos. Het script weigert te starten als er wel een
policy actief is — vandaar dat dit vóór de merge moet. Bewaar de uitvoer: dat is het bewijs
dat de tests kunnen falen.

Controleer daarna of je configuratie klopt vóór hij naar Intune gaat:

```bash
./check-configs.sh --selftest    # toont eerst dat de bewaker zelf kan falen
./check-configs.sh /pad/naar/je-samengevoegde-managed-settings.json
```

Dat toetst of de lock-keys (`failIfUnavailable`, `allowUnsandboxedCommands`,
`allowManagedReadPathsOnly`, `allowManagedDomainsOnly`) de merge hebben overleefd, en of elk
beschermd pad op beide lagen staat. Juist bij het samenvoegen met je bestaande bestand
sneuvelen die het makkelijkst, en AC-11 t/m AC-14 leunen er volledig op.

---

## Stap 2 — wat je uitrolt

Merge [`config/managed-settings.windows.json`](config/managed-settings.windows.json) in het
bestand dat je al uitrolt naar `C:\Program Files\ClaudeCode\managed-settings.json`.
**Mergen, niet vervangen** — je bestaande `permissions.deny`, `cleanupPeriodDays` en
`allowManagedPermissionRulesOnly` blijven staan.

**Neem ook het `_beschermd`-blok over.** Dat is de enige plek waar een beschermd pad staat,
en `check-configs.sh` toetst daaraan of elk pad op beide lagen zit. Zonder dat blok kan de
check je samengevoegde bestand niet beoordelen.

Vier dingen komen erbij:

1. `"wslInheritsWindowsSettings": true` — dit is de kern. Zonder deze key leest Claude Code
   in de WSL2-distro alleen `/etc/claude-code/managed-settings.json`, een pad binnen de
   distro waar Intune niet bij kan. Je huidige uitrol raakt WSL2 dus niet.
2. Het `sandbox`-blok — de Bash-bescherming die er nu niet is.
3. Extra `Read(...)`-regels naast die van jou, voor de paden die de sandbox ook dicht zet.
4. `allowManagedMcpServersOnly` en `allowedMcpServers` — de gemeten MCP-route voor WSL.
   Een lege lijst blokkeert alle MCP; vul hem met de beheerde servers die beschikbaar
   moeten blijven.

## Stap 3 — verifiëren dat het werkt

**Volg [VERIFICATIE.md](VERIFICATIE.md).** Twaalf controles die je met de hand doet in een
gewone Claude Code-sessie, ongeveer vijftien minuten. Er ligt ook een geautomatiseerde suite
in deze map, maar die is alleen aanvullend: in de managed WSL2-meting onderschepte de
auto-permissionlaag de samengestelde markercommando's vóór de eigenlijke probe. De suite
rekent dat veilig als ONGELDIG, maar kan zonder interactieve goedkeuring geen volledige
vrijgave opleveren. VERIFICATIE.md legt onderaan uit wat daarover gemeten is.

Wat hieronder stond over `./fixture.sh` en `./run.sh` geldt alleen als je de suite alsnog in
een testomgeving wilt draaien.

Op dezelfde laptop, in de distro. **Deze scripts schrijven in de home van die gebruiker:** ze
zetten testbestanden in `~/probe-a`, `~/probe-b` en `~/repos/probe-7f3a91b2`, en op WSL2 één
in het Documents van je Windows-profiel, en `run.sh` merget tijdelijk een vijandige regel in
`~/.claude/settings.json` om te toetsen dat een developer de policy niet kan oprekken, en
zet het bestand daarna terug. Bij een gefilterde run die geen lockdown-test raakt gebeurt
dat niet. Bestaande bestanden worden nooit
overschreven — `fixture.sh` stopt met een melding als een pad al bezet is. De fixture raakt `~/.ssh` en
`~/.aws` bewust niet aan. Doe dit liever
niet op de laptop van iemand die aan het werk is.

**Draai dit als het account van de developer, niet als root.** `~/` resolvet per gebruiker:
een run als root leest `/root` en raakt geen enkel fixture-pad, waarna zowel de beschermde als
de toegestane paden dicht lijken en de uitkomst niets zegt. Dat is precies hoe onze eerste
WSL2-run ongeldig werd. Gaat `~/repos` bij een geldige run alsnog dicht, kijk dan naar OQ-7 in
[open-questions.md](open-questions.md): op 22-08-2026 is gemeten dat `~` naar de Linux-home
resolvet. Herhaal die controle op de doellaptop; als `~/repos` daar toch dichtgaat, stop dan
de proef en draai de Windows-policy terug.

```bash
./run.sh          # draait de acceptatietests tegen de actieve policy
```

Groen betekent: de canary komt in geen enkele uitvoer terug, en normaal development werkt
nog. De suite rekent daarbij een aantal dingen als fout in plaats van als geslaagd: een
verwachte test die overslaat, lege uitvoer, een `claude` die met een foutcode terugkomt, een
commando waarvan de uitvoeringsmarker ontbreekt, en een Read-test waarbij niet vast te
stellen is óf er gelezen is. Dat sluit niet elk denkbaar vals-groen uit — daarvoor is de
nulmeting uit stap 1.

**Ruim daarna op.** De fixture zet een bestand met de naam `bestand.txt` neer in het
Documents van een echt Windows-profiel en testbestanden onder `~/probe-a`, `~/probe-b` en
`~/repos/probe-7f3a91b2`. Hij raakt bestaande `~/.ssh` en `~/.aws` niet aan. Laat de
testbestanden niet staan op een bedrijfslaptop:

```bash
./fixture.sh --clean
```

Dat verwijdert alleen bestanden die de eigen herkenningsregel dragen; alles wat er al stond
blijft staan en wordt gemeld.

Daarnaast vijf controles met de hand, omdat ze admin of een destructieve stap vragen — de
procedures staan in [README.md](README.md#handmatige-procedures):

- `bwrap` weghalen en zien dat Claude Code weigert te starten
- de policy actief zien worden in WSL met alleen het Windows-bestand
- en zonder `wslInheritsWindowsSettings` zien dat hij dat niet is
- `claude mcp list` draaien in de distro
- vaststellen wat de Read-laag níét dekt (AC-23, zie OQ-6)

De vierde controle toetst de inmiddels gekozen route: `allowedMcpServers` en
`allowManagedMcpServersOnly` staan in managed settings en reizen dus mee met
`wslInheritsWindowsSettings`. `managed-mcp.json` hoeft niet mee de distro in. Zie de
oplossing bij OQ-5 in [open-questions.md](open-questions.md).

## Als het misgaat

Op een laptop waar de policy problemen geeft, gebruik je de rollback die je vóór de proef
hebt klaargezet. `unlock.sh` is alleen het noodluik voor managed settings die in de distro
zelf staan:

```bash
./unlock.sh
```

Dat haalt managed-settings weg die ín de distro staan, met een kopie ernaast. **In de
uitrol die jij doet staat het bestand op de Windows-kant**, en daar komt `unlock.sh` niet
bij: hij meldt het pad en stopt. De echte terugdraai voor één laptop is de key
`wslInheritsWindowsSettings` uit de payload halen of het bestand met Windows-admin
weghalen; gebruik voor de laptopproef de concrete PowerShell-rollback bovenaan dit document.
Draai daarna altijd `wsl --shutdown`, anders kan de distro de oude policy nog vasthouden.
Voor de hele vloot is de rollback die key uit de Intune-payload halen. De policy geldt dan
weer alleen op de Windows-kant, precies zoals nu, en WSL2 valt terug op onbeschermd.

## Laat je eigen uitvoering tegenspreken

Dit plan is niet in één keer goed geworden. Het is meerdere rondes langs een onafhankelijke
beoordelaar gegaan, en elke ronde vond dingen die van binnenuit onzichtbaar waren — een
controle die niet kon falen, een reparatie die het probleem verplaatste, een claim in de
documentatie die het script tegensprak. Eén ronde vond dat een controle groen werd omdat het woord "sandbox" in het pad
van de testmap stond; een volgende vond dat de configcontrole die vóór de uitrol staat
letterlijk elke payload goedkeurde. Dat soort dingen zie je niet zelf.

Doe bij de uitvoering hetzelfde. De skills staan hier:
**https://github.com/your-online/agentic-coding-skills/tree/main/skills**

Daar staan `advise-me` (feedback terwijl je bezig bent, in de chat) en `review-my-work` (een
geschreven oordeel over afgerond werk), plus de rubric waar ze tegen toetsen. De werkwijze
die hier iets opleverde:

1. Voer een stap uit — installeren, configureren, testen.
2. Vraag `advise-me` om een oordeel. Die stuurt een aparte beoordelaar op je werk af, met
   verse context en zonder jouw redenering.
3. Verwerk wat eruit komt, ook waar je het er niet mee eens bent — controleer het dan eerst
   zelf in plaats van het over te nemen of weg te wuiven.
4. Herhaal tot er niets substantieels meer uit komt.

Waar het het meest oplevert: nadat je stap 0 hebt doorlopen en je omgeving afwijkt van de
aannames, en nadat de eerste testrun groen is. Groen is precies het moment waarop je het
minst geneigd bent nog te kijken, en waar in deze sessie de meeste vals-groene resultaten
zijn gevonden.

## Drie dingen over je huidige bestand

Los van deze uitrol, gevonden bij het lezen van je configuratie:

**De negen `Write(...)`-regels doen niets.** Claude Code toetst padregels alleen tegen
`Edit(...)` en `Read(...)`; een `Write(...)`-padregel wordt geaccepteerd maar nooit
geraadpleegd. De `Edit`-regels ernaast dekken het schrijven al. Bron: de
[permissions-documentatie](https://code.claude.com/docs/en/permissions).

**Vier patronen missen waarschijnlijk hun doel.** `Read(**/x)` matcht alleen binnen de
huidige werkdirectory en daaronder. Voor `App.config`, `appsettings*.json`, `bin/` en `obj/`
klopt dat — die staan in het project. Voor `OneDrive*/`, `*.pfx`, `*.cer` en `*.kdbx` niet:
die staan meestal buiten de projectmap. Filesystem-breed wordt het met een `//`-anker,
bijvoorbeeld `Read(//**/OneDrive*/**)`.

**De twee lagen zijn niet symmetrisch.** `sandbox.filesystem.denyRead` kent voorouders: `~/`
dekt alles eronder. `permissions.deny` kent die inversie niet, want deny wint altijd van
allow — een `deny ~/**` met `allow ~/repos` zou het project ook dichtgooien. Elk pad dat je
voor de Read-tool wilt beschermen moet daar dus letterlijk staan.

---

## Bijlage A — WSL2 uitrollen vanuit Intune

Alleen nodig als A1 niet klopt en je WSL2 zelf nog moet uitrollen. Wat hieronder staat kwamen
wij tegen bij het opzetten van onze testomgeving (Windows Server 2022, 21-08-2026). Daar ligt
geen bewijsmap van, dus waar een externe bron hetzelfde beschrijft staat die erbij; ga op die
bron af, niet op ons.

**Je hebt twee fasen nodig, want geen enkele Intune-context kan het alleen.** WSL installeren
en `VirtualMachinePlatform` inschakelen vraagt admin, dus dat gaat in SYSTEM-context, met een
reboot erna. Maar WSL weigert onder SYSTEM te draaien — `wsl` aanroepen als SYSTEM geeft
`WSL_E_LOCAL_SYSTEM_NOT_SUPPORTED` (0x8004032E, "Running WSL as local system is not
supported") — en distro's zijn per gebruiker geregistreerd, in
`HKCU\Software\Microsoft\Windows\CurrentVersion\Lxss`. Registreren moet dus in de context van
de developer, die volgens A6 geen admin heeft. Onder het verkeerde account geïnstalleerd
bestaat de distro voor de developer niet: `WSL_E_DISTRO_NOT_FOUND` (zoek op dat symbool, niet
op de hele foutstring — de prefix ervoor verschilt per aanroeproute).

Dus: **fase 1 in SYSTEM-context** (WSL en de feature, dan reboot), **fase 2 in de
gebruikerscontext** (`wsl --import`). Overbrug je die twee met een scheduled task die het
SYSTEM-script aanmaakt — de gebruikelijke brug — let dan op: `Register-ScheduledTask`
accepteert `-Principal` niet samen met `-User`/`-Password`, dat zijn elkaar uitsluitende
parametersets ([documentatie](https://learn.microsoft.com/powershell/module/scheduledtasks/register-scheduledtask)).
Bij ons werkte `schtasks.exe /create /ru <user> /rp <pw>` wel.

**`wsl --install -d Ubuntu --no-launch` meldt succes zonder te registreren.** De uitvoer was
"Ubuntu has been installed. The operation completed successfully", waarna `wsl --list
--verbose` zei: "Windows Subsystem for Linux has no installed distributions" — de distro komt
pas in `HKCU\...\Lxss` bij een eerste interactieve start. Een script dat op de exitcode afgaat
denkt dus dat het klaar is terwijl er niets staat. Hetzelfde is op regulier Windows gemeld in
[microsoft/WSL#10646](https://github.com/microsoft/WSL/issues/10646); onze meting op Server
2022 staat er dus niet alleen.

**`wsl --update` kan stukgaan als de Store geblokkeerd is.** De update komt standaard uit de
Microsoft Store. Is die er niet of staat hij via Intune dicht — wat samen met de aanbevolen
baseline-instelling *Allow the Inbox version of WSL: Disabled* een reële combinatie is — dan
werkt `wsl --update --web-download` wel.

**`wsl --import` is de scriptbare route, en ook die van Microsoft zelf.** Volledig
non-interactief, in de gebruikerscontext:

```
wsl --import Ubuntu C:\wsl\Ubuntu <rootfs.tar.gz> --version 2
```

Microsoft noemt `wsl --export`/`--import` van een goedgekeurd image expliciet als ondersteunde
enterprise-route ([WSL for your company](https://learn.microsoft.com/en-us/windows/wsl/enterprise)).
Wij gebruikten de rootfs van cloud-images.ubuntu.com:
`https://cloud-images.ubuntu.com/wsl/releases/24.04/current/ubuntu-noble-wsl-amd64-24.04lts.rootfs.tar.gz`.
Een eerdere URL op diezelfde site gaf 404 — die paden veranderen, dus controleer hem of host de
tarball zelf. **Verifieer de tarball vóór het importeren** tegen de `SHA256SUMS` in dezelfde
map, en die tegen `SHA256SUMS.gpg`. Dit is het root-filesystem van de omgeving waarin je
vervolgens een vertrouwensgrens legt; ongeverifieerd importeren maakt die grens waardeloos.

**Quoting: codeer je distro-script.** Een commando dat van PowerShell via `wsl` naar `bash -lc`
gaat, verliest onderweg escapes zonder foutmelding. Wat standhoudt is het script base64 sturen:

```
wsl -d Ubuntu -u root bash -c 'echo <base64> | base64 -d | bash'
```

Onze keten was langer dan de jouwe (er zat ook nog `az vm run-command` in), dus dat je dit
precies zo tegenkomt is een gevolgtrekking. Het recept kost niets en neemt de hele klasse weg.
