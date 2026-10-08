# Handoff: Mac mini (M6, 24 GB) – aufräumen, bauen, Ende-zu-Ende testen

Stand 08.10.2026. Sprache mit dem Owner: Deutsch, knapp. `docs/rebuild/` ist intern und wird **vor dem nächsten
Öffentlichschalten gelöscht**. Dieses Dokument ersetzt nicht `MAC-HANDOFF.md`, es baut darauf auf.

## Zuerst lesen

1. `docs/rebuild/HANDOFF.md`: Auftrag, Arbeitsregeln, Owner-Entscheidungen
2. `docs/rebuild/MAC-HANDOFF.md`: was umgesetzt ist, CI-Stand, offene Punkte, Fragen an den Owner
3. `docs/rebuild/TASKS.md`
4. `git log --oneline 1c9ad8b..origin/claude/happy-ride-ilnibc` mit den Commit-Texten
5. `docs/development.md` und `docs/settings-simplification.md`

Arbeite auf Branch **`claude/happy-ride-ilnibc`** (`git fetch && git switch claude/happy-ride-ilnibc`).

## Diese Maschine

Mac mini, Apple M6, **24 GB** → Speicherstufe 24 in `ModelSelector.table`: Standard **K2 Horizon 7B mit 32k Kontext**,
„Gründlicher“ in den Einstellungen sichtbar (**Qwen3.6 35B-A3B IQ3**, 13,7 GB, Budget 18 GiB). Apple Foundation Models
sollten verfügbar sein (macOS 26). Prüfe beides zuerst und notiere macOS-, Xcode- und Swift-Version.

## Phase 0: Alte Pippa-Versionen entfernen (Owner-Auftrag)

Ziel: ein sauberer Erststart wie bei einer neuen Person. **Erst eine Bestandsliste zeigen** (Pfad, Größe, was es ist),
dann einmal beim Owner bestätigen lassen, dann löschen. Nichts löschen, was nicht eindeutig von Pippa stammt.

Suchen und auflisten:

- App-Kopien: `/Applications/Pippa*.app`, `~/Applications`, `~/Downloads/Pippa*`, DMGs, `.build/*/Pippa.app` in alten
  Checkouts; laufende Prozesse (`pgrep -fl Pippa`, `pgrep -fl llama-server`, `pgrep -fl "pi --mode rpc"`) vorher beenden.
- Daten: `~/Library/Application Support/Pippa` (Einstellungen, Sitzungen, Undo-Ordner, `llama-slots`, Schlüssel-Datei,
  Journal), `~/Library/Caches/io.github.tschnorpfeil.pippa`, `~/Library/Caches/pippa-build`,
  `~/Library/HTTPStorages/io.github.tschnorpfeil.pippa`, `~/Library/Preferences/io.github.tschnorpfeil.pippa.plist`
  (`defaults delete io.github.tschnorpfeil.pippa`), `~/Library/Saved Application State/io.github.tschnorpfeil.pippa*`,
  Sparkle-Reste, Anmeldeobjekt (Systemeinstellungen → Allgemein → Anmeldeobjekte).
- Was Pippa in Pi installiert hat: `~/.pi/agent/install/releases/*` (nur von Pippa angelegt, siehe
  `install-state.json` im Pippa-Support-Ordner), `~/.pi/agent/extensions/pippa-local-server` (hat `.pippa-managed`),
  in `~/.pi/agent/models.json` die Provider `pippa-local` und `pippa-online`, in `~/.pi/agent/settings.json` die
  Einträge `pippa-local/*` unter `compaction.modelOverrides` und `modelThinkingLevels`, `models.json.pippa-*.bak`,
  `~/.local/share/pi-node`. Hat der Owner selbst ein Pi eingerichtet, nur Pippas Teile entfernen und eine Kopie von
  `~/.pi/agent` anlegen, bevor du etwas änderst.
- Schlüsselbund: Einträge mit Dienst `de.pippa.model-credentials` (nur nach Rückfrage, der Owner verliert sonst seinen
  API-Schlüssel).
- macOS-Rechte zurücksetzen, damit der Erststart die Abfragen wirklich zeigt:
  `tccutil reset All io.github.tschnorpfeil.pippa`.
- **Modelle (GGUF) nicht löschen**, sondern auflisten (Ort, Größe, SHA256 gegen `catalog.json`): Pippas Modellordner,
  `~/models`, LM Studio, Ollama, Hugging-Face-Cache, `~/Library/Caches/pippa-live`. Sie werden für die Tests wieder
  gebraucht und dürfen beim Erststart übernommen werden (das ist selbst ein Testfall). Gemma-Dateien: dem Owner nennen,
  er entscheidet. Für den Test „Erststart mit Download“ die passende Datei nur vorübergehend wegschieben, danach zurück.

Danach: `pgrep` zeigt nichts mehr von Pippa, und keine der Stellen oben enthält noch Pippa-Daten.

## Phase 1: Offene Punkte aus MAC-HANDOFF.md

In der dort beschriebenen Reihenfolge:

1. Bauen und Checks: `swift build` (alle Targets), `PippaChecks`, Node-Gates mit Pi-Payload. CI-Stand: Build grün; rot
   sind „Default model is pinned“ und zwei OCR-Checks. Klären, ob die OCR-Checks auf `main` ebenfalls rot sind; wenn ja,
   die Ursache suchen (vermutlich eine Vision-Änderung) und beheben, ohne einen Test abzuschalten.
2. K2 pinnen (`scripts/pin-model.sh k2-horizon-7b IFM/K2-Horizon-7B-GGUF`) und ein kleines K2 für 8 GB suchen.
3. K2 mit Pi testen, Denkstufe, Compaction, `--swa-full`.
4. Abkürzungen messen und danach behalten oder löschen, jeweils mit Zahl im Commit.

## Phase 2: App bauen

`scripts/build-app.sh` (lädt llama.cpp, Node, Pi-Payload, `fd`/`rg` gepinnt) und
`scripts/verify-app.sh --verify-runtime`. Installation nach `/Applications` nur nach Freigabe des Owners; zum Testen
reicht die App aus dem Build-Ordner.

## Phase 3: Ende-zu-Ende mit allen Modellen

Für jedes Modell dieselbe Szenarienliste, Zeiten messen (Kaltstart bis erste Worte, warme erste Antwort, Gesamtzeit),
Ergebnis bewerten (richtig / teilweise / falsch, Deutsch, kurz, ehrlich, Werkzeuge korrekt), Speicher-Spitze notieren.
Höchstens ein llama-server gleichzeitig, messen nur bei Last < 10. Nur Testdaten (z. B. `scripts/create-usability-fixtures.py`,
Korpus aus `PippaLive`), keine echten Mails, Kalender oder Excel-Dateien ohne konkrete Freigabe.

| Modell | Katalog-Schlüssel | Wie | Rolle |
|---|---|---|---|
| Apple Foundation Models | – | eingebaut | Dokument-Vorschläge, erste Zeile im Brief, Einordnen beim Aufräumen |
| K2 Horizon 7B | `k2-horizon-7b` | Tabelle (Standard ab 16 GB) | Gespräch über Pi |
| Qwen3.5 9B Q4 | `qwen3.5-9b-q4` | `PIPPA_PI_MODEL` (Entwickler) | Vergleich |
| Qwen3.5 4B Q4 | `qwen3.5-4b-q4` | Tabelle für 8 GB, hier per `PIPPA_PI_MODEL` | 8-GB-Ersatz prüfen |
| Qwen3.6 35B-A3B | `qwen3.6-35b-a3b-iq3` (IQ3_S, 13,7 GB) | „Gründlicher“ in den Einstellungen | Gründlich ab 24 GB |
| Qwen3.6 35B-A3B Q3 | `qwen3.6-35b-a3b-q3` (UD-Q3_K_XL, 16,8 GB) | `PIPPA_PI_MODEL` | Vergleich zu IQ3; passt es in 24 GB neben macOS? |

Szenarien (je Modell; Apple FM nur für seine Rollen):

- Freies Gespräch auf Deutsch und Englisch; Rückfrage; Abbrechen mitten in der Antwort.
- Gezeigte Datei: PDF-Brief erklären („Einfach erklären“), Scan ohne Textebene (OCR), Word, Mail (.eml).
- Skill-Knöpfe: Zusammenfassen, Stichpunkte, Text kürzen/verbessern, Antwort schreiben (Entwurf im Brief),
  Tabelle prüfen.
- Rechnungen als Tabelle → `Rechnungen.csv` mit richtigen Beträgen; Rückgängig.
- Fristen: Brief mit erkennbarer Frist (Karte, „In Kalender“), Brief mit relativer Frist (Pi + `calendar_add`, Guard fragt).
- Brief-Zeile aus Mail (Testpostfach): erste Zeile, Aktionen, Entwurf, in Mail einfügen (nie senden).
- Online prüfen / Websuche: Karte zeigt die Anfrage, keine persönlichen Daten, Quellen mit Link.
- Aufräumen: Downloads-Testordner („räum Downloads auf“), Vorschau, ein Rückgängig für alles; Einordnen mit Apple FM.
- Datei finden: „Wo ist mein Mietvertrag?“ → `find`/`grep`/`mdfind`, nie Websuche.
- Kalender: „Was habe ich morgen?“, Termin anlegen, Erinnerung anlegen (Testkalender).
- Werkzeuge ohne Modell: PDF aus Bildern, Verkleinern, OCR-Ebene, Tabellen-Summe in Excel (falls installiert).
- Langes Gespräch: Compaction greift erst kurz vor dem Kontextende, Antworten bleiben sinnvoll.
- Eigener Online-Dienst (nur mit Schlüssel vom Owner): an, eine Frage, aus.

## Phase 4: UI, UX und Erststart

Prüfe wie eine Person ohne Technikkenntnisse. Screenshots helfen (die Dev-Snapshots in `DevSnapshot.swift`,
`PIPPA_SNAPSHOT`), echte Klicks sind aber Pflicht:

- **Erststart**: Willkommen, Einrichtung (Pi-Installation, Modell übernehmen oder laden, Fortschritt, Abbrechen und
  Fortsetzen), macOS-Rechtedialoge in Pippas Namen, verständliche Fehlertexte (kein Netz, zu wenig Platz).
- **Pille und Gespräch**: Ablegen per Drag-and-drop, Zwischenablage (Text, Bild, Datei kopieren und an Pippa geben,
  Entwurf kopieren), Tastenkürzel, Fokus, Scrollen, Warteschlange, „Denkt nach“-Zeile, Kaltstart-Fortschritt.
- **Animationen**: flüssig, nicht ruckelnd, „Bewegung reduzieren“ respektiert, keine springenden Layouts.
- **Einstellungen**: Standard/Gründlicher (Download-Frage, Wechsel ohne Absturz), eigener Online-Dienst, Sprache
  Deutsch/Englisch, „kurze Texte mitschicken“, Gewohnheiten vergessen, Leerlaufzeit.
- **Barrierefreiheit**: VoiceOver-Ansagen, Tastaturbedienung, Kontrast im hellen und dunklen Modus, große Schrift.
- **Quittungen und Rückgängig**: was passiert ist, steht in klaren Worten da; Rückgängig stellt wirklich alles wieder her.
- **Speicher und Akku/CPU im Leerlauf**: Modell wird nach der Leerlaufzeit entladen, keine Hintergrundlast.
- Sprache in der Oberfläche: kurz, freundlich, du-Form, keine Fachwörter, keine Emojis (siehe
  `app/Sources/PippaCore/Resources/persona.md`).

Jeden Fund mit Schritt zum Nachstellen, erwartet/tatsächlich und Screenshot festhalten. Kleine, klare Fehler beheben
(eigener Commit, Gates grün); größere UX-Änderungen und alles Architektonische erst mit dem Owner abstimmen.

## Ergebnis für den Owner

- Tabelle Modell × Szenario mit Zeiten und Bewertung, Empfehlung pro Speicherstufe (bleibt K2 Standard? lohnt
  Qwen3.6 IQ3 oder Q3 für „Gründlicher“?).
- Liste der UI/UX-Funde, sortiert nach Schwere, mit behobenen und offenen.
- Antworten auf die beiden Owner-Fragen aus `MAC-HANDOFF.md` vorbereiten (llama.cpp-Provider, Gemma-Nutzer von 1.0),
  mit den gemessenen Zahlen.
- `docs/rebuild/TASKS.md` abhaken, Doku mit Messzahlen nachziehen.

## Regeln

- Push nur auf `claude/happy-ride-ilnibc` (oder einen Branch, den der Owner nennt), nie auf `main`; keine PRs, Merges,
  Releases, Notarisierung, Deploys oder Installation nach `/Applications` ohne ausdrückliche Freigabe.
- Tests und Messungen mit falschem HOME, wo die Skripte das vorsehen. Außerhalb von Phase 0 nichts in `~/.pi`,
  `~/.local`, `~/models` oder Pippas Support-Ordner anfassen; `~/Library/Caches/pippa-live` ist read only.
- Keine neuen Modellaufrufe an Pi vorbei ohne Owner-Entscheidung; eine Abkürzung braucht eine Messzahl im Commit.
- Lange Läufe enden mit **Blockiert auf mich**, **Geändert**, **Gefunden**.
