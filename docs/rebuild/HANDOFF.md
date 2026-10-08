# Handoff: Pippa sauber auf Pi umbauen

Stand 08.10.2026. Sprache mit dem Owner: Deutsch, knapp. Dieses Verzeichnis (`docs/rebuild/`) ist intern und muss
**vor dem nächsten Öffentlichschalten gelöscht werden**.

## Auftrag in einem Satz

Pippa wird das freundliche Gesicht für den Pi-Agenten plus ein paar nützliche Mac-Werkzeuge. **Alles, was Pi schon
kann, nutzt Pippa von Pi**, statt es nachzubauen.

## Zuerst lesen

1. `docs/rebuild/architecture-inventory.md`: jedes Pippa-Bauteil, das Pi-Gegenstück und eine Empfehlung.
2. Pis eigene Doku, Version 1.1.0. Nach `npm ci` bzw. im Payload liegt sie unter
   `node_modules/@earendil-works/pi-coding-agent/docs/`. Pflicht sind `extensions.md`, `skills.md`, `cli.md`,
   `settings.md`, `models.md`, `compaction.md`, `mcp.md`, `rpc.md`, `llama-cpp.md` und `packages.md`.
3. `README.md` und `docs/development.md` (Build, Checks).

## Arbeitsregeln (wichtig, die vorige Session hat sich hier verrannt)

- **Vor jedem Bau prüfen, ob Pi oder ein Pi-Paket es schon kann.** Wenn ja, das nutzen. Wenn nein, kurz begründen,
  warum nicht.
- **Keine neuen eigenen Werkzeuge, Pipelines oder Modellaufrufe an Pi vorbei** ohne Owner-Entscheidung. Ausnahme sind
  Mac-spezifische Dinge, die Pi grundsätzlich nicht kann: Mail, Kalender, Erinnerungen, Excel, Texterkennung (OCR)
  und Apple Foundation Models.
- Eine Abkürzung an Pi vorbei ist nur erlaubt, wenn sie **sinnvoll, gut und gemessen schnell** ist. Die Zahl gehört in
  den Commit.
- Kleine Schritte: ein Schritt ergibt einen oder wenige Commits, ist einzeln umkehrbar und bei jedem Commit laufen die
  Gates grün.
- **Architekturfragen stellst du dem Owner, bevor du baust.** Ausführungsschritte machst du ohne Rückfrage.
- Die Aufgabenliste führst du in `docs/rebuild/TASKS.md` und hakst sie dort ab.
- Höchstens wenige Subagenten gleichzeitig. Du prüfst deren Ergebnis selbst, bevor du es integrierst.
- Lange Läufe enden mit den Überschriften **Blockiert auf mich**, **Geändert**, **Gefunden**.

### Harte Regeln

- `git push`, PRs, Merges auf GitHub, CI-Läufe, Releases, Notarisierung, Deploys, Repo-Sichtbarkeit und Installation
  nach `/Applications` nur nach **ausdrücklicher Freigabe im Chat**. Eine Freigabe gilt für genau einen Schritt.
  Fertige Zweige meldest du mit „bereit zum Pushen, ein Befehl genügt“.
- Arbeite auf einem Branch (z. B. `rebuild/pi-first`), nicht direkt auf `main`.
- Niemals Modelle oder Nutzerdaten löschen. Nicht anfassen: das echte `~/.pi`, `~/.local`, `~/models`,
  `~/Library/Application Support/Pippa` und App-Container. `~/Library/Caches/pippa-live` ist READ ONLY.
- Tests laufen mit falschem HOME. Höchstens ein llama-server gleichzeitig. Messen nur bei einer Last unter 10.
- Keine echten Mail-, Kalender- oder Excel-Daten ohne konkrete Freigabe.

## Entscheidungen des Owners (08.10.2026)

| Thema | Entscheidung |
|---|---|
| Prinzip | Pi ist das Gehirn. Pippa ist Gesicht, Sicherheitsnetz (Guard-Extension, Rückgängig) und Mac-Anschluss (MCP-Server in der App, Apple FM, OCR). |
| Modelle | **Gemma fliegt komplett raus.** Es bleiben K2 Horizon über llama.cpp und Apple Foundation Models. |
| Standardmodell | K2 Horizon 7B ab 16 GB. |
| 8-GB-Macs | Gewünscht ist ein kleines K2 Horizon (der Owner nennt „3,7B“; der llama.cpp-PR nennt einen 4B-Test). Prüfe auf Hugging Face, ob es ein GGUF von IFM gibt. Falls ja: in den Katalog aufnehmen, pinnen, testen. Falls nein: Qwen3.5 4B behalten und dem Owner melden. |
| „Gründlicher“ ab 24 GB | **Bleibt** (Qwen3.6 35B-A3B IQ3 in den Einstellungen). |
| Eigener Online-Dienst (OpenAI/Anthropic mit eigenem Schlüssel) | **Bleibt, aber über Pi.** Pis eigene Provider bzw. `models.json` nutzen, keinen eigenen Proxy (`PippaOnlineProxy`, `PippaOnlineDesk`). Soll vor einem Request ins Netz weiter gefragt werden, dann über einen Extension-Hook (`before_provider_request` im Guard), nicht über einen eigenen Proxy. Den Weg vorher kurz mit dem Owner abstimmen. |
| Feste JSON-Abläufe (Rechnungen, Fristen, Brief-Vorschläge, „Online prüfen“) | **Raus.** Sie laufen über Pi mit Skill. Das JSON-Schema war nur das Ausgabeformat für Pippas Karten. Wo Pippa strukturierte Daten braucht (z. B. eine Rechnungstabelle), schreibt Pi die Datei mit seinen Werkzeugen (CSV) oder nutzt ein kleines Hilfswerkzeug. |
| Dateien ändern | Über Pis `bash`/`edit`/`write`. Der Guard sichert vor dem Ändern und macht es rückgängig. Eigene Datei-Werkzeuge nur, wo gemessen nötig (z. B. `move_files`: ein Aufruf statt 16; mit K2 neu messen). |
| Datei suchen | Pis `find`, `grep` und `ls` einschalten. `fd` und `rg` im Paket mitliefern, damit Pi nichts aus dem Netz nachlädt. Optional `mdfind` (Spotlight, findet auch Inhalte in PDF und Word) im Guard als „nur schauen“ erlauben. **Kein** eigenes Suchwerkzeug bauen. |
| Web | `pippa-web` bündelt `pi-web-access` und läuft hinter Pippas Freigabe-Karte und dem Filter für persönliche Daten in Suchanfragen. Bleibt so, solange Pi selbst keine Freigabe vor Netzzugriffen bietet. |
| Apple FM | Behalten für kurze, schnelle Entscheidungen: Dokument-Vorschläge, erste Zeile zum Brief, Einordnen beim Aufräumen (~3 s statt 26 s pro Datei). |

## Fragen, die die vorige Session geklärt hat

- **Reasoning:** Heute erzwingt Pippa `--reasoning off` am llama-server (`LlamaServer.swift:176`) und übergeht damit
  Pi. Pi kann das selbst. Dazu gehören in `models.json` `reasoning: true`, `thinkingLevelMap` und
  `samplingParamsByThinkingLevel`, außerdem eine Standard-Denkstufe pro Session (`docs/models.md`, `settings.md`).
  Ziel: Pi steuert die Denkstufe, Standard „low“ oder „off“ je nach Messung. Hinweis: K2s Vorlage ignoriert „off“ und
  denkt immer mindestens „low“.
- **Kontext:** Pippa setzt den Kontext heute pro Speicherstufe (`ModelSelector.table`): 16k bei 8 und 16 GB, 32k ab
  24 GB. Der Wert landet als `--ctx-size` am Server und als `contextWindow` in Pis `models.json`. 8k und 64k nutzen wir
  nicht. **Fehler:** Pis Compaction löst aus, wenn `Kontext > contextWindow − reserveTokens` gilt, und der Standard ist
  `reserveTokens = 16384`, `keepRecentTokens = 20000` (`compaction.md`). Bei 16k liegt die Schwelle damit bei 0.
  Passende Werte pro Modell setzen (Pi-Settings bzw. `modelOverrides`) und vorher-nachher messen.

## Stand des Codes

- Repo `tschnorpfeil/pippa` (privat seit 08.10.), Branch `main`. Der lokale Stand ist mit diesem Handoff gepusht.
- Release 1.0.0 (Build 300) ist veröffentlicht, aber im privaten Repo derzeit nicht erreichbar.
- **Nicht verifiziert:** Seit Build 300 sind diese Merges in `main` gekommen, und ein voller Lauf aller Gates danach
  steht noch aus:
  - Bildschirm-Fix für die Pille
  - Kaltstart-Fortschritt mit Vorladen
  - K2 als Standard, llama.cpp b11503, Qwen-IQ3-Option
  - Aufräum-Vorschau: Thumbnails, ein einziger Fortschritt, Duplikate in den Papierkorb, Apple FM beim Einordnen,
    Grenze 300

  Bekannt ist: Die OCR-Checks schwanken unter hoher Last, und der Check „default model is pinned“ ist absichtlich rot.
- **K2 Horizon 7B ist nicht gepinnt.** Hugging Face war in der vorigen Umgebung blockiert. Lösung:
  `scripts/pin-model.sh k2-horizon-7b IFM/K2-Horizon-7B-GGUF`. K2 lief noch **nie** mit Pi.
- Release-Prozess: `scripts/release.sh` (Build-Nummer = 299 + Commits), `scripts/prepare-update-probe.sh` und
  `scripts/verify-app.sh --verify-runtime`.

## Reihenfolge

Jeder Schritt einzeln, Gates grün, Commit:

0. Gates auf `main` voll laufen lassen, Fehler einordnen (Last, Flake oder echt) und den Stand festhalten.
1. **K2 pinnen** und ein kleines K2 für 8 GB klären (siehe Entscheidungen). K2 einmal mit Pi gegen die bestehenden
   Abläufe testen (r7-Aufräumen, Werkzeugaufrufe, Mail-Antwort auf Deutsch) und das Ergebnis dem Owner melden.
2. **Gemma raus:** zuerst aus Tests, Spikes und Skripten, danach aus Katalog, README und THIRD_PARTY_NOTICES.
   `--swa-full` entfernen, falls K2 es nicht braucht. Die Fundstellen stehen in Abschnitt 3 der Inventur.
3. **Compaction und Kontext** korrekt setzen und messen.
4. **Reasoning** an Pi übergeben (siehe oben) und messen.
5. **Skills echt an Pi:** `--skill <bundle>/pippa-skills`, Buttons schicken `/skill:name …` über RPC. Das Voranstellen
   von Skill-Text in Swift entfernen.
6. **Pis Werkzeuge ausdrücklich setzen:** `--tools read,bash,edit,write,find,grep,ls,…`. `fd`/`rg` mitliefern,
   `mdfind` im Guard erlauben, Prompt-Zeile „eigene Dateien: find/grep/mdfind, nie web_search“.
7. **Feste JSON-Abläufe raus:** „Online prüfen“, Brief-Vorschläge, Rechnungen und Fristen über Pi plus Skill.
   Anschließend `LocalModelJSON`-Wege, `LetterModel.check*`, `LocalEngine.checkOnline`, `extractInvoices` und
   `modelDeadlines` löschen. Vorher mit dem Owner abstimmen, welche Karten bzw. Ausgaben die App weiter zeigt.
8. **Online-Dienst über Pi-Provider** statt eigenem Proxy, Weg vorher abstimmen.
9. **Abkürzungen neu messen** (Aufräumen nativ gegen Pi + `move_files` mit K2, Kalender-Intent, `budget.ts`
   an und aus). Danach behalten oder löschen, mit Zahl im Commit.
10. Aufräumen: tote Pfade, Kommentare mit „Gemma“, Doku (`README`, `development.md`) auf den neuen Stand.

## Fertig heißt

- Kein Modellaufruf an Pi vorbei außer Apple FM für die genannten kurzen Entscheidungen und gemessene, begründete
  Abkürzungen.
- Gemma ist nirgends mehr im Code. K2 ist gepinnt und mit Pi getestet.
- Alle Gates sind grün: `swift build`, PippaChecks (falsches HOME), check-strings, Guard-, Web- und Autostart-Tests,
  Site-Checks.
- `docs/rebuild/TASKS.md` ist abgehakt. Für den Owner liegt eine kurze Zusammenfassung mit Messzahlen vor
  (vorher/nachher: Vorspann in Tokens, erste Antwort, Aufräumen).
- Release, Website und Öffentlichschalten sind **nicht** Teil dieses Auftrags. Das macht der Owner separat. Vorher
  `docs/rebuild/` löschen.
