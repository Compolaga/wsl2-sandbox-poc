# WSL2 Claude Code CLI sandbox

Deze repository laat zien hoe een centraal beheerde Claude Code-policy in WSL2 beschermde
paden afsluit voor zowel Bash als de Read-tool, terwijl normaal development in bevestigde
workspaces blijft werken.

De containment is aangetoond met automatische testfixtures en handmatige verificatie op een
Windows-laptop. Uitrol voor echte gevoelige data wacht nog
op inventarisatie van die paden en herhaling van de volledige verificatie op een tweede
developer-laptop na Intune-uitrol.

## Status

**Aangetoond:**

- een Windows-policy bereikt Claude Code in WSL2 via `wslInheritsWindowsSettings`;
- de OS-sandbox houdt beschermde fixturepaden dicht, inclusief de `/mnt/c`- en
  `cmd.exe`-routes;
- een developer kan managed sandbox- en leesregels niet oprekken;
- zonder bubblewrap start Claude Code niet;
- de automatische suite en de interactieve controles, inclusief de Read-tool, zijn op
  23-08-2026 op één Windows-laptop groen doorlopen.

De aanvullende laptopuitvoer staat niet in deze publieke clone. De conclusie is vastgelegd
in [decisions.md](decisions.md), maar moet door ITOps op de doelomgeving opnieuw worden
bewezen.

**Nog nodig vóór teamuitrol:**

- inventariseer de echte gevoelige paden en neem ze op in de gegenereerde policy (OQ-1);
- controleer de gebruikte toolchains en package-feeds — de huidige proef toont normaal
  development alleen voor Node aan;
- doorloop na Intune-uitrol de automatische én handmatige route op een tweede
  developer-laptop.

De actuele vragen en hun gevolgen staan in [open-questions.md](open-questions.md).

## Hoe de bescherming werkt

Claude Code gebruikt hier twee beheerde lagen voor dezelfde beschermde paden:

1. de sandbox begrenst Bash en subprocessen op OS-niveau;
2. `permissions.deny` begrenst Claude's eigen Read-tool.

Die lagen zijn niet symmetrisch. De sandbox kan de Linux-home op één of meer bevestigde
workspaces na afsluiten. De Read-tool blokkeert alleen paden die expliciet in de denylijst
staan. Daarom is de inventarisatie van echte gevoelige paden een uitrolvoorwaarde en geen
administratief detail.

## Aan de slag

**Begin bij de [Agentpoort in HANDOFF.md](HANDOFF.md#agentpoort--eerst-vragen-dan-pas-doen).**
Die route vraagt vóór installaties, workspacekeuzes en policyplaatsing om expliciete
toestemming en genereert daarna de laptop-specifieke Windows-payload.

Gebruik voor een proef een VM of aparte testlaptop. Regel eerst een Windows-adminrollback
én een WSL-snapshot; de policy kan anders Claude Code of workspaces onbereikbaar maken.
`~/repos` is alleen het fixturepad en nooit een organisatiekeuze.

De volledige uitvoerroute, voorwaarden, drie fasen, commando's en teardown staan in
[HANDOFF.md](HANDOFF.md). Voer de statische Windows-template niet rechtstreeks uit.

## Verificatie en vrijgave

**Volledige verificatie is de automatische suite plus de interactieve controles plus een
herhaling door ITOps op een tweede laptop.** [VERIFICATIE.md](VERIFICATIE.md) bevat de
verwachte uitkomsten, handmatige systeemcontroles, alle acceptatiecriteria en de
vrijgavepoort.

De automatische suite is fail-closed diagnostiek: een probe die niet aantoonbaar is
uitgevoerd wordt ongeldig, niet groen. Daardoor kan `run.sh` de interactieve route niet
vervangen.

## Documentatie

- [HANDOFF.md](HANDOFF.md) — veilig installeren, configureren, uitrollen en terugdraaien.
- [VERIFICATIE.md](VERIFICATIE.md) — automatisch en handmatig verifiëren en vrijgeven.
- [decisions.md](decisions.md) — gedateerde besluiten, bronnen en meetconclusies.
- [open-questions.md](open-questions.md) — open of uitgestelde keuzes met eigenaar en gevolg.
- [evidence/README.md](evidence/README.md) — bewijsformaat, herhaalbaarheid en beperkingen.
- [templates/proof-matrix.md](templates/proof-matrix.md) — aftekenlijst per laptop.

## Reikwijdte

Deze repository test niet de Intune-dienst zelf, bootst geen domain-joined of
Defender-beheerde laptop na en dekt geen native Windows-versie van Claude Code. De policy is
ook geen grens tegen een developer met lokale admin die het beheerde bestand of de Claude
Code-binary kan vervangen.
