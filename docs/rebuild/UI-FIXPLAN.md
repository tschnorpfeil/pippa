# UI/UX-Fixplan

Stand 09.10.2026. Grundlage: Review von ~150 Snapshot-Zuständen (`PIPPA_SNAPSHOT`, de, hell/dunkel), Owner-Rückmeldung
vom selben Tag. Hier abhaken. Jeder Schritt: eigener Commit, Gates grün (`swift build`, `PippaChecks`,
`check-strings`), betroffene Snapshot-Szenarien neu gerendert und angesehen, Vorher/Nachher-Bild im Commit-Text benannt.

## Leitregeln (gelten für jeden Schritt)

1. **Eine Sache, ein Ort.** Was angehängt ist, steht genau einmal sichtbar da.
2. **Eine Karten-Grammatik.** Jede Karte: Überschrift = die Frage oder das Ergebnis in einem Satz, darunter ein Satz
   Erklärung, dann höchstens zwei Knöpfe (rechts der wichtige). Kein kleines graues Etikett über der Überschrift.
3. **Keine Technik im Blick.** Keine Dateiendungen in Fließtext, keine Programmnamen (Spotlight, Pi), keine Pfade,
   keine Tastenkürzel in Knöpfen, keine Schreibmaschinenschrift. Details nur hinter „Details“.
4. **Fortschritt = Satz + Anteil, nie Stoppuhr allein.** „Lese deine Unterlagen · 3 von 4“. Zeit nur, wenn sie
   etwas sagt (> 20 s, dann „dauert noch etwas“ statt Sekundenzähler). Weiter gilt: nichts erfinden, nur echte
   Ereignisse (`WorkPhase`).
5. **Gespräch bleibt.** Pippa bleibt ein Gespräch, wo es eins ist (Owner 09.10.: C abgelehnt). Aufgaben mit
   klarem Ergebnis (Ordnen, Frist, Entwurf) enden zusätzlich in einer Ergebnis-Karte mit Rückgängig.

## Phase 1: Kleine, klare Fehler (je < 1 h, kein Architektureingriff)

- [ ] 1.1 **Fehlerkarte mit Grund und Weg.** `AppModel.swift` („That didn’t work“), `SheetViews`/Fehler-Mode:
      Grund in einem Satz (kein Netz / Datei weg / Pippa ist abgestürzt …), zweiter Knopf passend zum Grund.
      „Problem melden …“ hinter „Details“. Szenario `states` → `12-error`.
- [ ] 1.2 **Willkommen verspricht das Richtige.** `OnboardingViews.swift` („Drop photos or a document on me.“ +
      Foto-PDF-Satz): drei Beispiele aus dem Alltag statt Foto-PDF. Szenario `welcome`, `scans-01`.
- [ ] 1.3 **Kein ⌘↵ im Hauptknopf.** Ordnen-Vorschau (`Sheets.swift`): Kürzel nur als Tooltip. Blasser Knopf
      bekommt einen Satz darunter („Ich schaue noch 25 Dateien an“). Szenario `states` → `07-sort`.
- [ ] 1.4 **„war: IMG_4821.jpg“** (`Sheets.swift`, `"was: %@"`): normale Schrift, grau, „vorher: …“.
- [ ] 1.5 **Kopfzeile kürzt mit „…“** (Gesprächstitel, `ConversationWorkspace.swift`) statt hart abzuschneiden.
- [ ] 1.6 **Eingabefeld leeren bzw. ausgrauen, solange eine Karte fragt** (alter Entwurf „Kündigung“ neben
      Freigabe-Karte). Entwurf bleibt erhalten, wird aber erst nach der Antwort wieder gezeigt.
- [ ] 1.7 **Einstellungen:** Fußzeile verdeckt keine Zeile mehr (Abstand unten = Fußzeilenhöhe);
      „Gemerkte Aktionen“-Text auf zwei Sätze kürzen. Szenario `settings`.
- [ ] 1.8 **Mail-Entwurf ohne innere Scrollleiste**, Karte wächst bis zur Fensterhöhe. Szenario `mailcards`.
- [ ] 1.9 **Snapshot-Szenarien `welcome`/`firstrun`** dokumentieren ihre Startparameter (`PIPPA_DEMO_MODEL=missing`,
      `-model.download.allowed NO`) in `development.md`, damit ein Lauf ohne sie nicht als Fehler erscheint.

## Phase 2: Aufräumen der Struktur (je ½–1 Tag)

- [ ] 2.1 **Anhänge einmal zeigen.** Graue Systemzeilen „Hinzugefügt: …“ (`ConversationController.swift`) und
      „Vorschau zum Ordnen: n Dateien“ (`AppModel.swift`) entfallen; die Chips in der Sprechblase bleiben die eine
      Wahrheit. „Verwendete Dateien (n)“ nur, wenn sie von den Chips der letzten Frage abweichen.
- [ ] 2.2 **Unterer Bereich: höchstens zwei Ebenen.** Karte mit ihren Knöpfen *oder* Chips + Eingabefeld. „Frage
      dazu“ und „Vorschau · Noch nichts geändert“ wandern in die Karte. Szenarien `states` (07, 12, 18), `natural`.
- [ ] 2.3 **Karten-Grammatik** (Leitregel 2) für Fehler, Freigabe, Mail-Frage, Ordnen, Entwurf, Kalender:
      ein gemeinsamer `CardHeader`/`CardActions` in `Theme.swift`, alte Varianten entfernen.
- [ ] 2.4 **Freigabe-Karte mit zwei Knöpfen.** „Erlauben“ / „Nicht erlauben“ + Schalter „Bei dieser Aufgabe nicht
      mehr fragen“. Erklärsatz entfällt. Berührt `runtime/pippa-guard` (Optionen) und `GuardAskCard.swift`;
      Guard-Tests anpassen. Wo möglich Vorher→Nachher zeigen wie beim Ordnen („Scan 3.pdf → Mietvertrag.pdf“).
- [ ] 2.5 **Denkzeile für Menschen.** `WorkStepPhrase.swift`/`Thought.strings`: Schritte ohne Endungen und
      Programmnamen („Suche in deinen Dokumenten nach „Kaution““ statt „Suche mit Spotlight …“, „Schaue in
      deinen Dateien“ statt „.md-Dateien in deinem Benutzerordner“). Werkzeugliste standardmäßig zu, nur die
      aktuelle Zeile + Anteil. Sekundenzähler erst ab 20 s, dann als Satz. `WorkStepChecks` erweitern:
      keine Endung, kein „Spotlight“, kein „Benutzerordner“ in Phrasen.
- [ ] 2.6 **Quittung:** „3 von 4 Quellen gelesen“ bleibt; Zeit („49 s“) nur in Details.

## Phase 3: Lebendige Pille (Idee B, Owner 09.10.: ja)

Ziel: Person schließt das Fenster, weil es dauert; die Pille erzählt weiter und wirkt lebendig, ohne zu nerven.

- [ ] 3.1 **Pille spiegelt `WorkPhase`.** Statt „Pippa liest …“ die kurze Form der Denkzeile:
      „Liest Mietvertrag · 2/4“, „Erkennt Text · Seite 2/5“, „Schreibt …“. Breite wächst weich (max. ~260 pt),
      Text kürzt mit „…“. Quelle: `ColdStart.pillLabel` verallgemeinern zu `ThoughtLine.pillLabel(phase)`.
- [ ] 3.2 **Echter Fortschritt als Ring/Balken**, nur wenn messbar (Seiten, Dateien, Kaltstart). Sonst nur Atmen
      des Zeichens. Keine erfundenen Prozente.
- [ ] 3.3 **Drei Ausgänge sichtbar:**
      fertig → Zeichen lächelt, „Fertig · 2 Fristen gefunden“, Klick öffnet die Antwort;
      braucht dich (`waitingForPerson`) → Akzentfarbe + „Kurz eine Frage“, sanftes einmaliges Wippen;
      Fehler → roter Bogen + „Hat nicht geklappt“, Klick zeigt die Fehlerkarte.
      Ergebnis bleibt stehen, bis die Person es ansieht (nicht nach 3 s weg).
- [ ] 3.4 **Ruhe-Regeln:** „Bewegung reduzieren“ → kein Wippen, kein Schimmer, nur Text. Keine Animation im Leerlauf
      (CPU messen: Leerlauf-Pille < 0,5 % CPU, Zahl in den Commit).
- [ ] 3.5 **Toasts werden Pillen-Zustände**, wenn das Fenster zu ist; offen bleibt der Toast wie heute
      (er ist gut: 9/10).
- [ ] 3.6 VoiceOver: Statuswechsel als Ansage, höchstens eine pro Phase.
- [ ] 3.7 Snapshot-Szenario `pilllive` mit allen Zuständen, hell/dunkel, Bewegung an/aus.

## Phase 4: Belege direkt im Text (Idee D, Owner 09.10.: ja, PRIME ansehen)

Vorhanden in Pippa: `PDFViewerWindow` (öffnet PDF an Seite, markiert Zitat), `Answer.location/quote` (alter
Einzelquellen-Weg), `SourceFidelity` (prüft Daten/Beträge im Code gegen das Gelesene), `PiReadLedger` (was Pi
wirklich gelesen hat). Fehlt: Verweise in freien Pi-Antworten; heute steht „(Test-Plan § 1)“ als toter Text da.

**PRIME (`~/Developer/PRIME`, React/pdf.js) macht es so:**
- Beleg = Tripel `{documentId, page (1-basiert), quote (wörtlich)}` (`src/components/agent/belegEtikett.ts:11`).
  Der Name kommt aus dem Quellen-Register des Zugs, nie vom Modell; „S. N“ nur bei geprüftem Namen.
  Drei Zustände: nicht geprüft / geprüft, nicht gefunden / gefunden.
- Das Modell belegt per Werkzeug `showSource(documentId, page, quote)` (`src/lib/agent/tools/showSource.ts`);
  Fließtext „S. 8“ wird per Remark-Plugin zum Link, aber nur, wenn es für die Seite einen gesammelten Anker gibt
  und die Seite nicht mehrdeutig ist (`markdownPageLinks.ts`, `AgentMessageList.tsx:1004`).
- Prüfung: normalisieren, enthalten oder Token-Überlappung ≥ 0,8 (`src/utils/evidenceGrounding.ts`) – dort nur
  Telemetrie, nichts wird verworfen.
- Rechtecke nie vom Modell, sondern aus der Dokumentgeometrie; mehrdeutig → kein Rechteck
  (`src/utils/nu/nuBelegAnker.ts`).
- Fallen: Trennstriche am Zeilenende (gleiche Heilregel für Extraktion und Markierung, `src/utils/trennstrich.ts`),
  Text in PDF-Anmerkungen fehlt im Seitentext, `\b` versagt vor Umlauten (`(?<![\p{L}\p{N}])` nehmen),
  Seiten-Array nie lückig, Scans ohne Textebene brauchen OCR-Rechtecke.

**Übertragung auf Pippa (Vorschlag):**
- Modell (`{Datei, Seite, Zitat}` + drei Zustände) und 0,8-Prüfung übernehmen; anders als PRIME **verwerfen** wir
  ungeprüfte Belege (passt zu `SourceFidelity`: ein falscher Link ist schlimmer als keiner).
- PDFKit ersetzt pdf.js: `PDFPage.string` je Seite, `PDFDocument.findString`/`PDFSelection` für die Markierung
  (macht `PDFViewerWindow` schon). Scans: Vision liefert normierte Zeilenrechtecke → Rechteck direkt.
- **Anker im Code statt Werkzeugaufruf (zuerst messen):** K2 7B lokal – jeder Werkzeugaufruf kostet einen Umlauf.
  Variante 1 (bevorzugt): Das Modell schreibt natürlich „(Mietvertrag, S. 2)“; der Code verlinkt, wenn die Datei
  gelesen wurde und die Seite existiert, und sucht die Stelle über die Werte des Satzes (Beträge, Daten, Namen –
  dieselbe Suche, die `SourceFidelity` schon macht). Variante 2: Werkzeug `show_source` im Pippa-MCP-Server wie
  PRIME. Entscheidung nach Messung (Anteil richtig verlinkter Sätze, Antwortzeit) – Zahl in den Commit.

- [ ] 4.1 Anker-Datenmodell `SourceAnchor {file, page, quote, rect?, state}` in PippaCore, Seitentext lückenlos.
- [ ] 4.2 Pi-Antwort → Anker (Variante 1, gemessen gegen Variante 2), Prüfung im Code; ungeprüft = kein Link.
- [ ] 4.3 Darstellung: Beleg als kleiner Link am Satzende („Mietvertrag, S. 2“), Klick → `PDFViewerWindow` an der
      Stelle, markiert. Nicht-PDF (Word, Mail, Markdown) → eigene Vorschau mit markierter Stelle.
- [ ] 4.4 Werkzeugprotokoll in der Quittung schrumpft auf „Gelesen: …“ mit denselben Links.
- [ ] 4.5 Checks: Anker treffen den Text (Fixtures mit bekannten Stellen), Scan-PDF mit OCR-Rechteck, kaputte Anker
      werden still weggelassen, nie falsch verlinkt.

## Phase 5: Aufgaben zum Antippen (Idee A, abgeschwächt)

- [ ] 5.1 Nach dem Ablegen einer Datei: zwei bis drei Verben aus dem Inhalt als Knöpfe über dem Eingabefeld
      („Frist eintragen“, „Einfach erklären“, „Antwort schreiben“). Teilweise vorhanden (`ctxsug`); vereinheitlichen
      und für jede abgelegte Datei zeigen. Gespräch bleibt darunter möglich.
- [ ] 5.2 Leeres Gespräch: Beispiele bleiben, aber als Karten mit Symbol statt blauer Linkliste.

## Fragen an den Owner

- Phase-Reihenfolge: 1 → 2 → 3 → 4 → 5 vorgeschlagen; 3 und 4 sind unabhängig und können parallel laufen.
- 2.4 ändert den Guard (TypeScript): zwei Knöpfe + Schalter in Ordnung?
- 3.3 „Ergebnis bleibt stehen, bis angesehen“: einverstanden, oder nach z. B. 10 min zurück zu „Pippa“?

## Prüfung am Ende jeder Phase

Snapshots aller berührten Szenarien hell/dunkel, große Schrift (`TextScale` 1,36), „Bewegung reduzieren“;
echte Klicks (Erststart, Drag-and-drop, ⌘V, Mail-Drop) mit `PIPPA_REGULAR_APP=1` und Fake-HOME
(`CFFIXED_USER_HOME`), siehe `development.md`.
