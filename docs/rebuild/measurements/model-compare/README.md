# Modellvergleich K2 Horizon 7B vs. Qwen3.5-9B — Messung 09.10.2026

Basis `origin/main` 19a9b48, Branch `claude/model-test-k2-qwen`. Harness: `scripts/quality/model-compare/` (README dort).
Mac mit 24 GB, Last bei Blockstart 0,8–3,0. Kein Download nötig: beide GGUF lagen schon auf dem Mac, SHA256 = Katalog-Pin
(`k2-horizon-7b` eb89c15a…, `qwen3.5-9b-q4` 03b74727…).

## Ergebnis nach der vorab festgelegten Regel

| Bedingung (Qwen gegen K2) | B Qwen denkend | C Qwen ohne Denken |
|---|---|---|
| Agentisch erfolgreich ≥ K2 − 1 (K2: 16) | ✓ 17 | ✗ 9 |
| Keine neuen Schleifen (K2: 1) | ✓ 0 | ✓ 0 |
| Deutsch blind ≥ K2 (K2: 2,88) | ✓ 3,83 | ✓ 3,79 |
| Gesamtzeit ≤ K2 + 20 % (K2: 48,0 s) | ✓ 27,8 s | ✓ 15,4 s |
| **Wird Standard** | **ja** | nein |

Nach der Regel wird **Qwen3.5-9B mit Denken (B)** Standard. Bekannte Schwächen von B, die die Regel nicht abdeckt, stehen
unten unter „Anomalien“ (vor allem: englische Fragen bekommen deutsche Antworten).

## Zusammenfassung (Median, Spanne in Klammern)

| Messung | A K2 medium | B Qwen denkend | C Qwen ohne Denken |
|---|---|---|---|
| Agentisch ja/teilweise/nein (30 Läufe) | 16/13/1 | 17/12/1 | 9/8/13 |
| Schleifen/Abbrüche | 1 | 0 | 0 |
| Template-Fehler (HTTP 400) | 0 | 0 | 0 |
| Läufe mit erfundenen Fakten | 8 | 2 | 2 |
| Werkzeugaufrufe je Aufgabe | 2 (1–24) | 2 (0–8) | 1 (0–21) |
| Erstes Wort kalt, s | 12,4 (4,9–48,1) | 17,0 (14,8–42,3) | 6,5 (3,9–6,7) |
| Erstes Wort warm, s | 31,3 (3,7–93,5) | 13,4 (2,1–44,9) | 0,5 (0,3–6,3) |
| Gesamtzeit je Aufgabe, s | 48,0 (13,4–419,7) | 27,8 (8,0–74,8) | 15,4 (2,0–83,9) |
| llama-server Peak RSS, MB | 9284 (8671–10156) | 7988 (7586–9005) | 9527 (7763–9606) |
| llama-server Footprint, MB | 4824 (4481–5745) | 3217 (2492–3597) | 4148 (1190–4190) |
| Dateisuche 6 (je Runde) | 6 / 6 / 6 | 6 / 6 / 6 | 6 / 6 / 5 |
| Werkzeugwahl 25 (je Runde) | 25 / 25 / 25 | 25 / 25 / 25 | 21 / 22 / 21 |
| r7 erstes Wort, s (18 Antworten) | 13,8 (5,8–20,4) | 7,5 (2,4–18,5) | 0,7 (0,5–3,8) |
| r7 gesamt, s | 18,9 (7,7–28,4) | 11,3 (4,4–21,6) | 5,2 (2,4–9,3) |
| Sprache blind, deutsche Fragen (1–5, n 24) | 2,88 | 3,83 | 3,79 |
| Sprache blind, alle inkl. Englisch (n 30) | 2,90 | 3,43 | 3,43 |

Je Aufgabe (✓ ja, ~ teilweise, ✗ nein; Runde 1/2/3):

| Aufgabe | A | B | C |
|---|---|---|---|
| multi-rechnungen | ✓ ✓ ✓ | ✓ ✓ ✓ | ✓ ✓ ✓ |
| vergleich | ✓ ✓ ✓ | ✓ ✓ ✓ | ✗ ✗ ✗ |
| zusammenfassen | ~ ~ ~ | ~ ✓ ~ | ~ ✓ ✓ |
| ordner-ueberblick | ~ ✓ ~ | ✓ ~ ✓ | ✓ ~ ✓ |
| web-recherche | ✓ ✓ ✓ | ✓ ✓ ✓ | ✗ ✗ ~ |
| web-plus-datei | ~ ~ ~ | ✗ ~ ~ | ✗ ✗ ~ |
| mail-antwort | ~ ~ ✗ | ✓ ~ ✓ | ✓ ✗ ✗ |
| termin | ✓ ✓ ✓ | ✓ ~ ✓ | ✗ ✓ ✗ |
| en-multi | ✓ ✓ ~ | ~ ✓ ~ | ~ ✗ ✗ |
| en-summary | ~ ~ ✓ | ~ ~ ~ | ~ ~ ~ |

## Anomalien

- **B/C antworten auf englische Fragen deutsch** (B: 5 von 6 englischen Läufen, C: 4 von 6; K2: 2 von 6), obwohl dann
  der englische System-Prompt gilt. Im Rubrik höchstens „teilweise“, in der Blindbewertung höchstens 2.
- **B siezt** oft trotz „mit du“ im Prompt; die Blindbewertung hat das abgezogen, B liegt trotzdem vorn.
- **K2-Schleife:** A r3 mail-antwort: 24 Werkzeugaufrufe, durchsucht das Dateisystem nach der schon gelesenen Mail,
  nach 420 s vom Token-Limit gestoppt, kein Entwurf. Pippas Schleifenstopp griff nicht (verschiedene Befehle).
- **K2 erfindet konkrete Daten:** Sonderkündigungsfristen im Brief in 4 von 6 Zusammenfassungen mit selbst errechnetem,
  falschem Datum; einmal „bis 31. August 2024“; einmal eine erfundene Monatssumme.
- **web-plus-datei:** keine Variante hat bei „Schau auch nach, wie man kündigt“ im Web gesucht; alle antworten aus der
  Police. Deshalb nirgends ein „ja“. Pippas Prompt nennt kein Datum, „ist die Frist noch drin“ verstand jede Variante als
  „steht sie drin“.
- **C (ohne Denken)** sucht oft nicht, fragt nach dem Pfad (Vergleich 0/3), erfindet Preise ohne Websuche
  (42,50 €, 50 €), legt Erinnerungen oder Entwürfe nur im Text an. Einmal chinesische Zeichen in der Antwort.
- **B:** einmal Datum `27.11.2026` statt `YYYY-MM-DD` (das echte Werkzeug lehnt das ab), einmal `reply_to` mit dem ganzen
  Mail-JSON.
- Keine Template-Fehler: Pi schickt die Systemnachricht (als `developer`) als erste Nachricht, llama.cpp#20733 trat nicht
  auf. Varianten B2/C2 waren daher nicht nötig.
- Speicher: RSS enthält die gemappten Modellseiten, Footprint die Metal-Puffer nur teilweise; beides nur grob vergleichbar.

## Methode

- **Gleich für alle:** Pi 1.1.0, Pippas System-Prompt, Werkzeugliste, Skills, Guard, MCP-Erweiterung aus `main`;
  derselbe gepatchte llama-server b11503 (K2-Think-Tag-Patch, berührt nur den K2-Parser); `--ctx-size 32768 --parallel 1`,
  KV q8_0; identische Prompts und synthetischer Korpus.
- **Varianten:** A wie in Pippa (Katalog-Sampling am Server: temp 0.6, top-p 0.95, top-k 0, min-p 0; Denkstufe medium).
  B/C über Pippas Qwen-Weg (`enable_thinking` via `qwen-chat-template`); Sampling per Request über Pis
  `samplingParamsByThinkingLevel`: B medium temp 0.6/top_p 0.95/top_k 20, C off temp 0.7/top_p 0.8/presence_penalty 1.5.
  Keine Qwen-spezifische Anpassung an Prompt oder Skills.
- **Ablauf:** 3 Runden × A,B,C abwechselnd; je Block frischer llama-server, dann 10 agentische Dialoge (erster = kalt),
  Dateisuche 6, Werkzeugwahl 25. r7 Latenz (18 Antworten) je Variante über Pippas eigenen Serverweg (`PiRPCR2Spike`).
  Vor jedem Serverstart: kein anderer llama-server, Last < 10 (einmal gewartet, als ein Server eines anderen Threads lief).
- **Isolation:** Fake-HOME (`HOME` und `CFFIXED_USER_HOME`) mit 20 erfundenen PDFs; Werkzeuge nur dort (eigene
  Isolations-Erweiterung, blockierte u. a. K2s Suche außerhalb). MCP-Mock für Mail, Kalender, Erinnerungen, Web
  (gespeicherte Seiten, für alle gleich); Freigaben automatisch „erlauben“ und protokolliert. Keine echten Daten.
- **Bewertung:** automatische Vorbewertung (`tasks.mjs`), dann jede der 90 Antworten von Hand nach dem Rubrik
  (`grades.json`, mit Begründung). Gleiche Regeln für alle: falsche Sprache → höchstens teilweise; falscher Fakt im
  Kernergebnis → teilweise; „erfunden“ = konkrete Zahl/Datum/Aussage, die nicht in den Quellen steht.
- **Blindbewertung Sprache:** `answers-blind.md` (X/Y/Z je Aufgabe und Runde zufällig), bewertet von einem separaten
  Claude-Agenten, der nur diese Datei gesehen hat (`blind-ratings.json`); Zuordnung in `blind-key.json`. Ein
  menschlicher Blick auf `answers-blind.md` wäre die stärkere Prüfung.

## Grenzen

- 3 Läufe je Aufgabe und Variante, Temperatur > 0: Unterschiede von 1–2 Läufen sind Rauschen.
- Mock-Web statt echter Suche; der optionale Live-Web-Lauf wurde nicht gemacht.
- Kaltstart = erster Dialog nach Serverstart (Modell im Seitencache warm, KV-Cache leer); kein Kaltstart von der Platte.
- Der gepatchte Server stammt aus dem Build-Cache des Haupt-Checkouts (Patch-Fassung mit `const char *` statt
  `std::string`, inhaltlich gleich).

## Dateien

`summary.md`/`summary.json` (aus `summarize.mjs`), `grades.json`, `answers-blind.md`, `blind-ratings.json`,
`blind-key.json`, `raw/` (je Block: `agentic-*`, `search-*`, `choice-*`, `block-*`, Server-Logs; `r7-*.log`;
`first-request-*.json` = erste Modellanfrage je Variante). Pfade anonymisiert (`<repo>`, `<home>`).
