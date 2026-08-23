# Evidence

De ruwe meetuitvoer is bewust niet opgenomen in de publieke repository. Die bevat absolute
lokale paden en omgevingsmetadata.

De scripts schrijven nieuwe resultaten naar deze map. Een run bevat onder meer:

- `environment.txt` met versies en hashes van de gebruikte configuratie;
- één uitvoerbestand per acceptatiecriterium;
- `results.tsv` als kleine, ruwe overdracht uit de Bash-probes;
- `run.json` als gestructureerd runmanifest met uitkomsten, afhankelijkheden en vrijgavepoorten;
- `samenvatting.txt` met de status en exitcode;
- `proof-matrix.md` met de automatische en handmatige vrijgaverijen.

`specs/acceptance-catalog.json` is de bron voor AC-metadata, geldige statussen,
afhankelijkheden en vrijgavepoorten. `samenvatting.txt` blijft bestaan voor mensen en voor
bestaande evidence; nieuwe console- en matrixuitvoer worden uit `run.json` gerenderd.
`report-proof.sh` kan een oude evidence-map zonder `run.json` nog steeds lezen.

Geen `samenvatting.txt` betekent dat de run is afgebroken. De SHA-256-hashes binden het
bewijs aan de gebruikte configbestanden, niet aan de effectieve samengevoegde policy; die
effectieve merge kan deze opzet niet interactievrij uitdraaien. Dat is een benoemde
bewijsgrens.

De conclusies uit de oorspronkelijke metingen staan in
[`../decisions.md`](../decisions.md). Herhaal de controles op de eigen doelomgeving; beschouw
oude evidence nooit als bewijs voor een andere laptop of Claude Code-versie.

De WSL2-metingen zijn uitgevoerd in wegwerp-VM's in Azure en op een Windows-laptop. In Azure
waren de automatische containment-, lockdown- en WSL2-systeemproeven groen; de
niet-interactieve Claude-probes die door de permissionlaag niet aantoonbaar werden uitgevoerd
zijn terecht als ongeldig vastgelegd. Op 23-08-2026 waren op de Windows-laptop de
automatische suite én de handmatige route uit `VERIFICATIE.md` groen, inclusief de
Read-tool-controles. De ruwe uitvoer van die aanvullende laptoprun staat niet in deze
publieke repository; `decisions.md` registreert de conclusie en de herkomst, maar is geen
vervanging voor controleerbaar bewijs. ITOps herhaalt daarom na Intune-uitrol de volledige
route op een tweede developer-laptop.

macOS-runs zonder actieve policy zeggen alleen iets over het testharnas. Ze bewijzen de
Windows-policy, `wslInheritsWindowsSettings`, `/mnt/c` en het `cmd.exe`-gat niet.
