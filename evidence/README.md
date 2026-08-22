# Evidence

De ruwe meetuitvoer is bewust niet opgenomen in de publieke repository. Die bevat absolute
lokale paden en omgevingsmetadata.

De scripts schrijven nieuwe resultaten naar deze map. Een run bevat onder meer:

- `environment.txt` met versies en hashes van de gebruikte configuratie;
- één uitvoerbestand per acceptatiecriterium;
- `samenvatting.txt` met de status en exitcode.

De conclusies uit de oorspronkelijke metingen staan in
[`../decisions.md`](../decisions.md). Herhaal de controles op de eigen doelomgeving; beschouw
oude evidence nooit als bewijs voor een andere laptop of Claude Code-versie.
