# ppedv Calltracking

Wahlversuche, Erreichbarkeit und Gesprächszeit des Vertriebsteams aus **Linkus Lite** —
live im Team-Dashboard.

- **Dashboard:** https://ppedv-calltracking.vercel.app (Team-Code)
- **Einrichtung PC:** https://ppedv-calltracking.vercel.app/einrichtung/

## So funktioniert es

Auf jedem Vertriebs-PC läuft ein kleiner Agent (PowerShell, startet mit Windows). Er liest
das Linkus-Log mit, erkennt die Nebenstelle und meldet die Anrufe (Zeit, Nummer, Ergebnis,
Klingel- und Gesprächsdauer) an das Dashboard. Linkus-Logs und Zugangsdaten verlassen den
PC nicht. Lokal bleiben wie bisher die eigene Live-Ansicht (`http://localhost:8765`) und
der Powerdialer für NINA.

| Nebenstelle | Person |
|---|---|
| +49 8677 9889-30 | Mario |
| +49 8677 9889-16 | Jasmin |
| +49 8677 9889-64 | Katharina |

Neue Person: in `api/ct.js` unter `TEAM` eintragen (erscheint sonst als „Nebenstelle NN“).

## Kennzahlen

- **Wahlversuche:** jeder Klick in Linkus (brutto)
- **Erreicht:** Anruf angenommen · **Quote:** erreicht ÷ beendete Versuche
- **Gespräche ≥ 1 min:** echte Gespräche statt Mailbox/Kurzkontakt
- **Technisch nicht erreichbar:** ungültig, nicht erreichbar, abgelehnt, nicht rausgegangen

## Betrieb

- Push auf `main` → Vercel deployt.
- Vercel: Blob-Store (privat) mit dem Projekt verbinden (`BLOB_READ_WRITE_TOKEN`).
- Agent geändert → `agent/zip-bauen.ps1` ausführen, ZIP mit committen.
