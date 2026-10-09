# Werkzeugwahl und Dateisuche — Messung 09.10.2026

Ausgangsstand c3c7c1c, zunächst Worktree af04, seit Owner-Korrektur `/Users/ts/Developer/pippa` auf `main` (Fetch: identische Basis). Kein Push, PR, Release oder CI.
Pi 1.1.0 (abe508e), gepatchter llama-server, K2 Horizon 7B Q4_K_M, medium, Temperatur 0.6, Kontext 32768, ein Server/ein Slot. Baseline und Zwischenfassungen in af04, abschließende Fassung auf main (übertragene Quellen bytegleich, Pfade bei Tokenzahlen mitgezählt). Alle Läufe mit `HOME` und `CFFIXED_USER_HOME`; ausschließlich erfundene Belege, MCP-Mock statt Mail/Kalender/Excel.

## Bestand und Werkzeugwahl

| Messung | Vorher | Nachher |
|---|---:|---:|
| Deklarierte Werkzeuge | 22 | 19 |
| Skills | 14 explizit | 14 explizit + 1 automatisch |
| Werkzeugdeklarationen im K2-Template | 1436 Token | 1287 Token (−10,4 %) |
| Identische Frage, erster Pi-Testprompt inkl. Werkzeuge/Skill-Metadaten | 1894 Token | 1874 Token (−1,1 %) |
| Passende erste Werkzeugwahl, fester Satz | 23/25 (92 %) | 25/25 (100 %) |

Der Vergleich umfasst je eine stochastische Stichprobe bei Temperatur 0.6; wiederholte Läufe können andere Entscheidungen ergeben.

Die 14 bisherigen Skills haben `disable-model-invocation: true` und kosten vor normalen Fragen **0 Token**. Die neue automatische Skill-Beschreibung kostet zusätzlichen Kontext; die Einsparung des gesamten Prompts ist daher kleiner als die der Werkzeugdeklarationen. Cache-Lesetoken sind mitgezählt.

Verbleibend: Pi `read`, `bash`, `edit`, `write`; Pippa `list_folder`, `rename_or_move`, `move_files`, `move_to_trash`; MCP `calendar_read`, `reminders_read`, `mail_selected`, `mail_search`, `excel_selection`, `read_document`, `web_search`, `read_web_page`, `calendar_add`, `reminder_add`, `mail_draft`.
`ls` doppelt `list_folder`; `find` ist Namenssuche; `grep` bleibt für bekannte Textpfade über `bash` erreichbar. `write` benennt Speichern direkt, `bash` seine Rolle als Rückfall. Kein neuer Router, kein dynamischer Sonderpfad.

Fester Satz in `scripts/quality/tool-choice.json`: sechs Dateiformulierungen; Auflisten, Aufräumen, Umbenennen, Papierkorb; PDF/Text lesen; Kalender/Erinnerungen/Mailauswahl/Mailsuche/Excel; Termin/Erinnerung/Entwurf; Wetter/Webseite; Text speichern/ändern; normale Antwort. Die erste Wahl wird vor jeder Ausführung blockiert. Bei Dateifragen gilt `read` nur dann als Treffer, wenn es den Suchskill lädt. Argumentqualität und gesamte Antwort werden damit noch nicht bewertet.
Vorherige Fehler: PDF → `find`, Text speichern → `bash`. Eine frühere Fassung schaffte 25/25, die nächste 22/25, die dritte 24/25, die vierte 23/25; die abschließende Fassung auf main 25/25. Eine Stichprobe ist keine Garantie für jede mögliche Frage. Keine gemessene Beschleunigung behauptet. Eine spätere Gesamtprobe (22/25) zeigte neue Fehlwahlen (Suchskill fürs Aufräumen, Ordnerliste vor Umbenennen/Papierkorb). Diese Zwischenprobe bleibt archiviert; die Beschreibungen grenzen Inhaltssuche von Ordnen ab und nennen die bereits vorhandene Pfadprüfung der Änderungswerkzeuge. Die 24/25-Probe verwechselte Excel-Auswahl mit Dateisuche. Über Pis vorhandenes `prepareLoadout` benennt die Beschreibung nun die Auswahl im offenen Excel und den fehlenden Pfadbedarf; kein neuer App-Code. Die nächste Probe (23/25) wählte Excel richtig, lud aber wieder den Suchskill beim Aufräumen und prüfte Umbenennen per Shell vorab. Die Skill-Abgrenzung steht deshalb jetzt auf Englisch wie die Werkzeugbeschreibungen, und Umbenennen benennt ausdrücklich die fehlende Vorprüfung.

## Dateien nach Inhalt finden

Pi lädt den Skill über seinen vorhandenen Mechanismus. Ein Skriptaufruf, darin genau **ein `mdfind`** über fünf Orte: Documents, Desktop, Downloads, iCloud Drive und Library/CloudStorage. Wörter und das optionale Jahr schränken **Inhalt** ein. Keine eigene Indizierung, kein App-Suchwerkzeug, kein Namensrouter. Fehlende Ordner, Fehler, Kürzung und Grenzen des Spotlight-Index werden ausgegeben.

Der Korpus umfasst acht erzeugte PDFs mit absichtlich bedeutungslosen Dateinamen in allen fünf Orten. Eine Datei namens `2023.pdf` enthält Urlaub 2026, nicht die gesuchte Zahnarztrechnung. Die Rechnung 2023 heißt `a.pdf`; eine zweite Rechnung enthält 2024. Steuer 2025 erfordert drei Treffer über drei Orte.
Spotlight indexiert versteckte `.codex`-/`.build`-Pfade hier nicht. Deshalb liegt der Fake-HOME im ignorierten `dist/tool-search-home` des gleichen Pippa-Repositories, außerhalb versteckter Pfade. Keine echten Benutzerordner werden durchsucht. Der Baseline-`mdfind`-Shim erzwingt ebenfalls diesen Suchbereich.

Direktes Skript: **8/8** erwartete Treffermengen, einschließlich falsches Jahr/kein Treffer; **107–150 ms** je Aufruf, vorhandener warmer Spotlight-Index. Dazu fehlende fünf Ordner und ungültiges Jahr geprüft. Das misst weder Indexaufbau noch K2-Latenz.

Der Modellvergleich prüft die **erste ausgegebene Suchstrategie nach optionalem Skill-Lesen**: deren Werkzeugergebnis muss exakt die erwartete Dateimenge enthalten. Ein paralleler späterer Suchaufruf rettet den ersten nicht. Vorbereitendes `ls` zählt deshalb als erfolglose erste Strategie. Der Lauf endet nach diesem Ergebnis; spätere Antwortqualität/Schleifen sind kein Bestandteil dieser Quote. Vorher nutzen einzelne Befehle mehrere `mdfind`-Aufrufe; danach soll der Skill einen liefern.

K2 ohne Skill: **3/6**; mit der abschließenden Skill-Fassung: **6/6**. Mit Skill jeweils genau ein Skript-/Spotlight-Aufruf.

| Formulierung | Ohne Skill | Mit Skill | Richtige Funde |
|---|---:|---:|---:|
| Unterlagen für Steuer 2025 | ✗ | ✓ | 3 |
| Dokument zur Kaution | ✗ | ✓ | 1 |
| PDF zur Hausratversicherung | ✓ | ✓ | 1 |
| Rechnung vom Zahnarzt 2023 | ✗ | ✓ | 1 |
| Info zu Nebenkostenabrechnung 2024 | ✓ | ✓ | 1 |
| Wo ist der Mietvertrag? | ✓ | ✓ | 1 |

Die Modell-Suchläufe dauerten mit Skill rund 27–38 s bis zum ersten Suchergebnis. Das ist weiterhin zu lang für den Alltag; gegenüber den schnelleren Baseline-Fällen keine Beschleunigung. Frühere Skill-Läufe brauchten 36–107 s, die normale Antwort in zwei Gesamtproben 135/160 s. Die Latenz streut stark.

Sechs Einzelwerte stehen in `measurements/tool-choice-before-search-final.json` und `measurements/tool-choice-after-search-links.json`. Eine Zwischenfassung des Skills schaffte 5/6: K2 stellte bei Steuer ein unnötiges `ls && node` voran und brauchte eine Freigabe. Die Anleitung verbietet diesen Vorbereitungsschritt jetzt ausdrücklich. Ein weiterer 5/6-Lauf listete bei „wo ist“ zuerst Dokumente auf. Die Skill-Beschreibung grenzt die Suche nach unbekannten Dokumenten von Sortieren, bekannten Pfaden und App-Auswahlen ab; `list_folder` verweist Inhaltssuche an den Skill. Beide Zwischenläufe sind ebenfalls archiviert.

Zusätzlicher vollständiger K2-Dialog „Such die Rechnung vom Zahnarzt aus 2023“: **1/1** erledigt, **ein** Spotlight-Aufruf, korrekter Fund, kein Schleifenabbruch. Die erste Antwort (71 s) gab den Pfad als Code aus; nach einem konkreten Markdown-Beispiel im Skill ist **1/1** Fund im Antworttext verlinkt (75 s). K2 liest dabei weiterhin unnötig das PDF: **3 Werkzeugaufrufe** (Skill lesen, suchen, Dokument lesen), obwohl die Skill-Anleitung bei reinen Suchfragen davon abrät. Dafür keine eigene Routinglogik gebaut; die Latenz bleibt offen. `pippa-search-result` enthielt genau den tatsächlichen Fundort. Diese beiden Dialoge sind separat archiviert.

## Ehrlicher Abbruch und anklickbare Funde

Realer Pi-Lauf mit kontrollierten Antworten: vier identische Suchausführungen, danach drei Blockierungen → **ein** dauerhafter Schleifenabbruch mit **einem** tatsächlichen Teilfund. Die App sagt, dass die Aufgabe unvollständig ist, und zeigt vorhandene Funde statt „versuch es nochmal“. Ein leerer Suchstand behauptet nicht, dass die Dateien nicht existieren. Die 200er-Grenze hatte einen Randfehler: Das Skript meldet bei 200 zurückgegebenen Pfaden bereits Kürzung; der Abbruch verlor diesen Hinweis. Gezielter Test vorher **0/1**, nachher **1/1**, einschließlich Reset vor der nächsten Frage. Der Guard erhält nun das Kürzungsflag des Skripts.

Bestehende Darstellung ließ **0/2** lokale Dateilinks zu. Mit den vom gebündelten Skript bestätigten Pfaden funktionieren **2/2**, während **5/5** fremde/manipulierte Ziele inaktiv bleiben. Fundorte werden mit der Antwort gespeichert. Das ist der gemessene Grund für die kleine App-Anpassung; Pi kann Ergebnisse liefern, aber die Swift-Darstellung musste sie bisher verwerfen. Keine nachgebaute Suche.

## Nachprüfen und Grenzen

- Native Checks: **615/615**, Standard-OCR; Guard inkl. echtem Pi: **58/58**, keine übersprungen; Übersetzungen: **1202 Schlüssel**, keine Lücken. Swift-App gebaut; `git diff --check` sauber.
- Der separate Schnell-OCR-Modus scheitert am bestehenden Kleingedruckt-Fixture. Standardmodus besteht; kein OCR-Umbau in dieser Aufgabe.
- Keine echten Mail-/Kalenderdaten, keine echten privaten Dateien, kein Apple-FM-Vergleich. Die geforderte Modellmessung hier ist K2 mit/ohne Skill.
- Nicht indexierte Inhalte, ungeladene Cloud-Dateien und Scans ohne erkannten Text können fehlen. „Alle Unterlagen“ bedeutet keine Vollständigkeitsgarantie.
- Kaltstart/KV-Sicherung, Statusüberlappung und Faktenverlust/Compaction bei 32k bleiben ungemessen/offen in TASKS.md.

Reproduktion: `scripts/quality/mcp-schema.py` exportiert die echten elf MCP-Deklarationen ohne App-/Datenzugriff. Baseline mit `git archive c3c7c1c runtime/pippa-skills runtime/pippa-guard app/Sources/PiRPC/PippaPiLaunch.swift` nach `.build/tool-before` sichern. Korpus mit `make-search-corpus.swift` im sichtbaren Fake-HOME erzeugen, dessen synthetische PDFs von Spotlight indexieren lassen. `check-file-search.mjs` prüft das Skript. `tool-choice.mjs <payload> <llama-URL> before` beziehungsweise `final-main` prüft 25 erste Werkzeugwahlen; `PIPPA_SEARCH_FLOW=1` mit Labels `before-search-final`/`after-search-links` und IDs `tax document pdf invoice info where` prüft die sechs ersten Suchstrategien. `token-prefix.mjs` zählt über `/apply-template` + `/tokenize` die Deklarationen mit einer identischen Frage (initiale System-/Benutzernachricht, ohne spätere Werkzeugantworten). Für einen vollständigen Dialog zusätzlich `PIPPA_SEARCH_DIALOGUE=1`, Label `after-dialogue-links`, ID `invoice`; Zeitgrenze 300 s statt 180 s, Abschluss, ein Suchaufruf und korrekter Dateilink erforderlich. Beide HOME-Variablen setzen; bestehende private Dienste nicht anbinden, maximal einen Server starten.

[Pi-Recherche](PI-RESEARCH.md) · [kurzer Nutzenreview](ALLTAG-REVIEW.md) · [Arbeitsliste](TOOL-SEARCH-TASKS.md)
