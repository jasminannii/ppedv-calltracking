# ppedv Calltracking — Projektkontext für Claude

Repo von Jasmin Meilner (ppedv AG, Vertrieb). Team-Calltracking der Vertriebsmitarbeiter
über **Linkus Lite** (Yeastar S-Series, Nebenstellen +49 8677 9889-NN).
Arbeitsweise wie im Kompetenzmatrix-Repo: Deutsch, kurz, wenig Text in Oberflächen,
ppedv-Design (Navy `#2E4879` + Orange `#EA8F13`), nicht gendern, nach jeder Änderung
committen, auf `main` pushen, Vercel-Status prüfen.

## Aufbau

| Pfad | Was |
|---|---|
| `index.html` | Team-Dashboard (Login mit Team-Code; Heute/Gestern/7/30 Tage; Personen-Karten, KPIs, Stunden-/Tageschart, Ergebnisse, letzte Versuche, CSV) |
| `einrichtung/` | Anleitung + Download `ppedv-calltracking-agent.zip` |
| `api/ct.js` | Vercel-Funktion: `status`, `einrichten`, `pruefen`, `code`, `sync` (Agent), `daten` (Dashboard) |
| `agent/…/linkus-dashboard/` | Agent für die PCs = Jasmins erster Entwurf (server.ps1, lokales Dashboard, Powerdialer) **plus** Team-Sync und `installieren.ps1` |
| `agent/zip-bauen.ps1` | ZIP neu bauen — **nach jeder Agent-Änderung ausführen und mit committen** |

## Datenfluss

1. `server.ps1` liest `%APPDATA%\Linkus Lite\logs\Desktop.log` (nur lesend), erkennt die
   Nebenstelle aus `registername: 'NN'`.
2. Alle 30 s Prüfung; geänderte Tage werden höchstens alle 90 s an `/api/ct?a=sync`
   gesendet (Header `x-team-code`), sonst alle 15 min ein Lebenszeichen.
3. Blob: `tage/<JJJJ-MM-TT>/<nebenstelle>.json` (privat), `nebenstellen.json`, `zugang.json`
   (scrypt-Hash des Team-Codes). Team-Code legt die erste Person im Dashboard fest.
4. Namen: `TEAM` in `api/ct.js` (30 Mario, 16 Jasmin, 64 Katharina). Unbekannte
   Nebenstellen erscheinen automatisch als „Nebenstelle NN“.

## Wichtig

- **Nie** Linkus-Logs, `anrufe-historie.tsv`, Anrufprotokolle oder `einstellungen.json`
  committen — die Logs enthalten SIP-Zugangsdaten, die Protokolle Kundendaten.
- Das Agent-ZIP ist öffentlich ladbar → keine Nummern/Passwörter im Agent-Code.
- Blob-Kontingent (Hobby): deshalb Drosselung im Agent. Bei deutlich mehr Personen
  auf Upstash Redis o. ä. umstellen oder die Yeastar-API (CDR) direkt anbinden.
- Leistungsdaten von Mitarbeitern → Betriebsrat/Datenschutz vor dem Rollout klären.
