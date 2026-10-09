# Handoff an den Mac-Agenten: Umbau Pi-first fertig bauen, testen, messen

Stand 08.10.2026. Sprache mit dem Owner: Deutsch, knapp. `docs/rebuild/` ist intern und wird **vor dem nächsten
Öffentlichschalten gelöscht**.

## Ausgangslage

Eine Cloud-Session ohne Mac hat den Umbau aus `docs/rebuild/HANDOFF.md` weitgehend umgesetzt. Die Commits liegen auf
dem Branch **`claude/happy-ride-ilnibc`** (Basis `1c9ad8b` auf `main`). Lies zuerst:

1. `docs/rebuild/HANDOFF.md` (Auftrag, Arbeitsregeln, Owner-Entscheidungen)
2. `docs/rebuild/TASKS.md` (Stand je Schritt)
3. `git log --oneline 1c9ad8b..claude/happy-ride-ilnibc` und die Commit-Texte (sie begründen jede Änderung)
4. `docs/development.md` (beschreibt schon den neuen Stand)

**CI-Stand (macos-26, Xcode 26.6, Lauf 37812738506):** `swift build` aller Targets grün. PippaChecks: 3 rot, alle ohne
Bezug zum Umbau: „Default model is pinned“ (erwartet, K2 nicht gepinnt) und zwei OCR-Checks („large heading and fine
print …“ in `ToolChecks.swift`, „accurate recognition reads amount, date and umlaut“ in `OCRChecks.swift`), auch im
Neustart rot. OCR-Code und -Checks hat der Umbau nicht angefasst; ein CI-Lauf auf `main` zum Vergleich existiert nicht.
Lokal auf dem Mac prüfen, ob sie auf `main` ebenfalls rot sind (vermutlich Vision-Änderung im neuen macOS/Xcode).
Die Node-Tests im CI liefen wegen des Abbruchs nicht; lokal laufen lassen.

**Vorher:** Der Swift-Teil wurde in der Cloud-Session **nie gebaut**. Geprüft wurde er nur mit einem Syntax-Parser (tree-sitter) und einer
gezielten Durchsicht auf Compile-Fehler (ohne Fund). Node-, Guard-, Web-, Autostart-, String-, Site- und Release-Gates
waren unter Linux grün; der Guard-Test „backup is an APFS clone“ läuft nur auf macOS sinnvoll.

## Was umgesetzt ist (Kurzfassung)

- Gemma komplett entfernt (Katalog, Tests, Spikes, Skripte, Lizenzhinweise).
- Pi steuert Denkstufe und Compaction: models.json mit `reasoning`/`thinkingLevelMap`/Template-Schalter (K2:
  `reasoning_effort`, Qwen: `enable_thinking`), Pis `settings.json` mit `modelThinkingLevels` und
  `compaction.modelOverrides` (`PiModelTuning.swift`). Kein `--reasoning off` mehr am Pi-Server.
- Pi startet mit `--tools <feste Liste>` und `--no-skills --skill <bundle>/pippa-skills`; Knöpfe schicken
  `/skill:name …`. `fd` 10.3.0 und `rg` 14.1.1 werden gepinnt nach `Contents/Helpers` gebündelt
  (`app/Packaging/search-tools.json`, `build-app.sh`, `verify-app.sh`). Guard: `fd`, `mdfind`, `mdls` = nur schauen.
- Feste JSON-Abläufe raus: Rechnungen → Pi + Skill `rechnung-auslesen` schreibt `Rechnungen.csv`; Fristen → Muster-Karte
  (Code) + Pi mit Skill `fristen-erkennen` und `calendar_add`; Brief „Online prüfen“ → Pi + Skill `online-pruefen`;
  Modell-Vorschläge im Brief weg. `LocalModelJSON` nur noch als Rückfall beim Aufräumen ohne Apple FM.
- Eigener Online-Dienst über Pis Provider ohne Rückfrage (`pippa-online` mit echter Adresse,
  `apiKey: "$PIPPA_ONLINE_KEY"` nur in der Umgebung von Pippas Pi). Proxy, Karte, Desk entfernt.
- Vorspann ans Modell gemessen (Pi 1.1.0, Ersatzserver, Zeichen/4): vorher ~984, jetzt ~1269 Tokens
  (drei Such-Werkzeuge mehr, Beschreibungen gekürzt).

## Deine Aufgaben, in dieser Reihenfolge

Jeder Schritt einzeln, Gates grün, eigener Commit mit Messzahl, wo gemessen wurde. Tests mit falschem HOME, höchstens
ein llama-server, messen nur bei Last < 10. Nichts in `~/.pi`, `~/.local`, `~/models`,
`~/Library/Application Support/Pippa` anfassen; `~/Library/Caches/pippa-live` ist read only.

1. **Bauen und Checks.** `git fetch && git switch claude/happy-ride-ilnibc`. Dann `swift build --package-path app` (alle
   Targets) und `swift run --package-path app PippaChecks` mit falschem HOME. Compile-Fehler und rote Checks
   beheben; sie stammen sehr wahrscheinlich aus den Löschungen in Schritt 7 und 8 (siehe Commits `38e5cd7`, `90b329b`,
   `ab0e3cc`). Danach die Node-Gates aus `docs/development.md` „Checks“, mit Pi-Payload
   (`scripts/bundle-pi-payload.sh .build/pi-payload --with-node`, `PIPPA_PI_PAYLOAD=…`).
2. **K2 pinnen** (in der Cloud war Hugging Face gesperrt): `scripts/pin-model.sh k2-horizon-7b IFM/K2-Horizon-7B-GGUF`.
   Danach muss `python3 scripts/check-default-models.py` grün sein. Den Dateinamen der GGUF in
   `scripts/pi-rpc-spike.sh` prüfen (dort geraten: `K2-Horizon-7B-Q4_K_M.gguf`).
3. **Kleines K2 für 8 GB:** Auf Hugging Face (IFM) nach einem GGUF eines kleinen K2 Horizon suchen (Owner nennt
   „3,7B“, der llama.cpp-PR einen 4B-Test). Gibt es eins: in den Katalog, pinnen, in `ModelSelector.table` für 8 GB
   eintragen, testen. Sonst bleibt Qwen3.5 4B; dem Owner melden.
4. **K2 mit Pi testen** (lief noch nie): `scripts/pi-rpc-spike.sh setup`, dann `r7 latency|cold|slot|sort`,
   Werkzeugaufrufe, eine deutsche Mail-Antwort (`r3`), dazu:
   - Denkstufe: K2 auf „low“ (Standard) und „medium“; Qwen 4B auf „off“; kommt `reasoning_content` getrennt an, bleibt
     die Antwort Deutsch und kurz?
   - Compaction: ein langes Gespräch auf 16k, löst Pi erst über ~12k aus?
   - Prüfe, ob K2 `--swa-full` braucht (Sliding-Window-Layer?). Wenn nein: `--swa-full` und `PIPPA_LLAMA_SWA_FULL`
     entfernen (Fundstellen: `LlamaServer.swift`, `PiLocalServer.swift`, R7-Checks).
5. **Abkürzungen messen** (Zahlen in die Commits):
   - Aufräumen: nativer Fluss gegen Pi + `move_files` mit K2 (`PippaLive tidy-speed`).
   - Einordnen beim Aufräumen: Apple FM gegen lokal mit K2. Ist lokal ähnlich langsam wie früher (p50 26 s/Datei),
     den Rückfallweg über `LocalModelJSON` löschen (`TidyClassifier` `.local`, `LocalEngine.askModel`,
     `LocalModelJSON.swift`, W4a-Checks dazu).
   - Kalender-Intent im Code gegen Pi + `calendar_read`.
   - `budget.ts` an/aus (Sekunden bis zur ersten Antwort).
   - Erste Antwort kalt/warm, Vorspann in Tokens (echte Tokenzahl aus llama-server statt Zeichen/4).
   Nach den Zahlen: behalten oder löschen, jeweils mit Zahl im Commit.
6. **Die umgebauten Abläufe in der echten App durchklicken** (nur Testdaten, keine echten Mail-, Kalender- oder
   Excel-Daten ohne Freigabe):
   - „Rechnungen als Tabelle“: Pi schreibt `Rechnungen.csv` neben die Rechnungen, Rückgängig funktioniert.
   - Brief mit Frist: Karte mit „In Kalender“ (aus dem Code); Brief ohne erkannte Frist → „Fristen eintragen“ geht ins
     Gespräch, Pi trägt mit `calendar_add` ein, der Guard fragt vorher.
   - Brief „Online prüfen“: das Gespräch übernimmt, die Web-Karte zeigt die Suchanfrage vor dem Senden.
   - Einzeldatei-Übersicht: Einordnen läuft über Apple FM (vorher direkter llama-server-Aufruf). Wie lange dauert es?
   - Eigener Online-Dienst: einschalten, eine Frage, ausschalten; `pippa-online` verschwindet aus models.json.
   - Skill-Knöpfe (z. B. „Einfach erklären“): Pi bekommt den Skill aufgeklappt; ein gleichnamiger Skill in
     `~/.pi/agent/skills` des falschen HOME darf nicht gewinnen.
   - Datei suchen: „Wo ist mein Mietvertrag?“ → Pi nutzt `find`/`grep`/`mdfind`, nicht `web_search`.
7. **App bauen und prüfen:** `scripts/build-app.sh` (lädt `fd`/`rg` gepinnt) und
   `scripts/verify-app.sh --verify-runtime`. Nicht nach `/Applications` installieren ohne Freigabe.
8. **Doku nachziehen:** `README.md`, `docs/development.md` auf die Messzahlen; `docs/rebuild/TASKS.md` abhaken.

## Vorher mit dem Owner klären (nicht selbst entscheiden)

- **Schritt 7b, Umstieg auf Pis `llama.cpp`-Provider.** Der Owner hat „umsteigen“ gewählt, kannte aber diese Befunde
  noch nicht:
  - Pi 1.1.0 lädt die Router-Modelle beim Start nur aus seinem Cache (`models-store.json`); mit `PI_OFFLINE` fragt er
    den Router gar nicht ab. Ohne eigene kleine Pippa-Erweiterung, die vor dem ersten Prompt
    `ctx.modelRegistry.refresh({ providers: ["llama.cpp"], allowNetwork: true })` ruft und dann das Modell setzt,
    findet Pi K2 nicht zuverlässig. `PI_OFFLINE` aufzuheben wäre schlechter (dann darf Pi auch pi.dev erreichen).
  - Der Provider erkennt Denkstufen nur bei `enable_thinking`-Vorlagen; K2 braucht `modelOverrides`
    (`reasoning`, `thinkingLevelMap`, `compat`) wie heute in models.json.
  - llama.cpp b11503 hat alles für den Router: `--models-preset` (INI pro Modell), `--models-max 1`,
    `--models-autoload`, `--sleep-idle-seconds`. Neu zu bauen wären Start/Stop in `LlamaServer`, Ladefortschritt
    (`ColdStart`, der Router startet Kindprozesse), Slot-Cache, der Terminal-Autostart (`runtime/pippa-local-server`)
    und der Installer.
  Vorschlag: erst die Messungen oben, dann mit dem Owner entscheiden, ob der Umstieg den Umbau lohnt.
- **Nutzer von Release 1.0.0 haben Gemma 4 12B.** Weil Gemma aus dem Katalog ist, greift „altes Modell weiter
  nutzen, während K2 lädt“ nicht mehr; sie müssen erst K2 laden (5,6 GB). Die Terminal-Erweiterung sagt dann „Öffne
  Pippa“. Gemma-Datei bleibt auf der Platte (Modelle nie löschen). Akzeptieren oder einen reinen Migrationseintrag
  behalten?
  → Owner 09.10.: entfällt, es gibt noch keine Nutzer von 1.0.

## Harte Regeln (aus HANDOFF.md, gelten weiter)

- `git push` nur auf `claude/happy-ride-ilnibc` (oder einen Branch, den der Owner nennt), nie auf `main`; PRs, Merges,
  Releases, Notarisierung, Deploys, Sichtbarkeit nur nach ausdrücklicher Freigabe im Chat.
- Keine neuen eigenen Werkzeuge oder Modellaufrufe an Pi vorbei ohne Owner-Entscheidung; Ausnahme Mac-Spezifisches
  (Mail, Kalender, Erinnerungen, Excel, OCR, Apple FM). Eine Abkürzung braucht eine Messzahl im Commit.
- Lange Läufe enden mit **Blockiert auf mich**, **Geändert**, **Gefunden**.
