# Pippa UX: ehrlicher Stand und Richtung

Stand 09.10.2026. Grundlage: Code auf `main` (19a9b48), `UI-FIXPLAN.md` (Review von ~150 Snapshots), `ALLTAG-REVIEW.md`,
die Website `site/index.html` und der Pillen-Prototyp (https://claude.ai/artifact/DjW1DXrhMLBL2KKbSbH5Wb).
Nicht in der echten App geklickt: Diese Bewertung stützt sich auf Code und Snapshot-Review, nicht auf Nutzertests.

## Das Wichtigste in drei Sätzen

1. **Die Website ist liebenswerter als die App.** heypippa.app hat handgeschriebene Sprechblasen, Bagel Fat One,
   Linoleumgrün und eine Figur, die lächelt; in der App kommt davon fast nur die Figur an, der Rest ist Systemblau,
   graue Etiketten und eine Linkliste.
2. **Die Pille verspricht mehr, als sie heute hält.** Dateien auf der Pille öffnen zwar schon eine Zeile mit drei
   Aktionen, aber Fragen und Antworten passieren in einem 760 pt breiten Gesprächsfenster, also genau dort, wo jede
   Chat-App auch ist. Die Pille selbst sagt „Pippa“ oder „Pippa liest …“
   und vergisst, dass eine Antwort fertig ist, sobald das Fenster zu ist.
3. **Warten ist das größte Gefühlsproblem.** Kalt 91 s, warm ~9,5 s: Wer nicht sieht, was passiert, hält Pippa für
   kaputt. Die Denkzeile im Gespräch ist gut und ehrlich, aber nur sichtbar, solange das Fenster offen ist.

## Noten heute (0–10)

| Bereich | Note | Warum |
|---|---:|---|
| Figur (Mark) | 9 | Eigenständig, vier Zustände, ruhig im Leerlauf, „Bewegung reduzieren“ beachtet. Das Beste an Pippa. |
| Ablegen auf die Pille | 8 | „Hier ablegen“/„Loslassen“ ist klar, danach die Zeile mit bis zu drei Aktionen. Ob es die richtigen sind, ist ungeprüft. |
| Pille während der Arbeit | 4 | Nur Kaltstart und `busy` werden genannt, sonst „Pippa“. Kein Fortschritt, kein Ergebnis-Zustand. |
| Ergebnis | 6 | Quittungen mit Rückgängig sind stark. Antworten sind Fließtext; Frist und Betrag stehen irgendwo darin. |
| Fehler | 4 | „That didn’t work“ ohne Grund und ohne passenden nächsten Schritt (Fixplan 1.1). |
| Freigaben | 6 | Ehrlich und sicher; drei Knöpfe und ein Erklärsatz sind zu viel (Fixplan 2.4). |
| Gespräch | 6 | Solide, aber mit Systemzeilen, doppelten Anhängen und Technikwörtern in der Denkzeile (Fixplan 2.1, 2.5). |
| Leerer Zustand | 5 | „Was möchtest du tun?“ mit vier blauen Links. Wirkt wie ein Formular, nicht wie Pippa. |
| Sprache | 8 | Ich-Form, Du, kurz, keine Technik. Die App spricht schon wie Pippa. |
| Charme | 4 | Kein einziger Moment, über den man jemandem erzählt. Die Website hat zwei, die App keinen. |

## Nordstern

**Pippa ist eine Pille, die manchmal ein Gespräch aufmacht, nicht ein Chatfenster mit Pille.**

Messbar: Anteil der Aufgaben, die enden, ohne dass das große Gesprächsfenster aufging. Heute fast null; Ziel für
die Top-3-Alltagsfälle aus `ALLTAG-REVIEW.md` (Rechnung finden, Brief verstehen, Antwort schreiben) mehr als die Hälfte.

## Sechs Regeln, an denen sich jeder Bildschirm misst

Gemeinsam mit dem Prototyp formuliert; sie ergänzen die Leitregeln im Fixplan.

1. **Hinlegen statt Prompten.** Nach dem Ablegen stehen zwei bis drei Verben aus dem Inhalt da. Tippen geht immer,
   ist aber nie Pflicht.
2. **Die Pille erzählt.** Sie sagt in ein paar Wörtern, was gerade wirklich passiert, mit Anteil nur, wenn es etwas zu
   zählen gibt. Alles kommt aus echten Ereignissen (`WorkPhase`), nichts ist geschätzt.
3. **Nie ungefragt aufspringen.** Pippa reißt kein Fenster auf. Fertig, Frage, Problem: Die Pille zeigt es und wartet.
4. **Ergebnis zuerst.** Ein Satz, der sagt, was zu tun ist, mit Beleg zum Antippen und einem Hauptknopf.
   Nachfragen geht darunter.
5. **Ergebnisse sind Dinge.** Ein PDF zieht man aus der Pille in Mail, ein Entwurf liegt als Entwurf in Mail,
   eine Frist steht im Kalender, alles mit Rückgängig.
6. **Charme in kleinen Dosen.** Die handgeschriebene Sprechblase der Website kommt für genau drei Momente in die App:
   „Fertig!“, „Wieder wie vorher.“, „Leg was auf mich!“ beim allerersten Start. Nie während der Arbeit, nie zweimal
   hintereinander, aus bei „Bewegung reduzieren“.

## Was die anderen nachbauen wollen werden

- **Die Pille, die erzählt und lächelt.** Kein Spinner, kein „Thinking…“, sondern „Lese Mietvertrag · 2/4“, und am
  Ende ein Lächeln mit „Deine Antwort ist da“, das stehen bleibt, bis man schaut.
- **Drei Verben nach dem Ablegen.** Die Antwort auf „Was kann ich hier eigentlich fragen?“, bevor die Frage entsteht.
- **Belege, die man antippt.** „Mietvertrag, S. 2“ öffnet das Dokument an der markierten Stelle (Fixplan Phase 4).
- **Ergebnis aus der Pille ziehen.** `TakeDrag.swift` kann das schon; es fehlt nur die Karte, die es zeigt.

## Bauplan nach Wirkung

Gebaut wird auf dem Mac erst nach der Abnahme der Web-Recherche (Owner 09.10.). Reihenfolge wie im Prototyp:

| # | Schritt | Stand |
|---|---|---|
| 1 | Pille spiegelt die echte Arbeit (Fixplan 3.1, 3.2) | **Entwurf in diesem Branch** (`PillStatus`), ungebaut |
| 2 | Drei Ausgänge, Ergebnis bleibt stehen (3.3) | **Entwurf in diesem Branch** für Antworten im Gespräch; Aufgaben-Quittungen (3.5) fehlen noch |
| 3 | Verben direkt an der Pille nach dem Ablegen (5.1) | **gibt es schon:** Dateien auf der Pille öffnen die Zeile (`ShellMode.line`) mit bis zu drei Aktionen aus `ThingActions.offered` (Rolle des Dokuments, gelernte Gewohnheiten). Offen: im echten Klicktest prüfen, ob die drei die richtigen sind |
| 4 | Ergebnis-Karte mit Beleg (Phase 4) | offen |
| 5 | Freigabe mit zwei Knöpfen (2.4) | offen, Owner-Frage im Fixplan |
| 6 | Ergebnis als Ding ziehen | offen, klein |
| 7 | Hilfe beim Kopieren | offen; Owner 09.10.: beim ersten Mal fragen, danach in den Einstellungen abschaltbar |
| 8 | Sprechblase und Haptik für drei Momente | **erster Schritt in diesem Branch:** „Deine Antwort ist da“ steht handgeschrieben (Gochi Hand, gebündelt) in der Pille; Sprechblase und Haptik offen |
| – | Leerer Zustand: Beispiele als Karten mit Symbol (5.2) | **Entwurf in diesem Branch** |

Fixplan Phase 1 (Fehlerkarte mit Grund, Willkommen, Kürzel aus Knöpfen) bleibt parallel sinnvoll und ist klein.

## Was dieser Branch ändert

- `PippaCore/PillStatus.swift`: reine Funktion von (Phase, Schritt, Ausgang, busy) auf Ton, Satz und Anteil.
  Kurzformen: „Lese Mietvertrag · 2/4“, „Lese den Scan · Seite 2/5“, „Schaue in Kontoauszug“, „Schreibe …“,
  „Kurz eine Frage“, „Deine Antwort ist da“, „Hat nicht geklappt“. Dateinamen ohne Endung, ab 22 Zeichen mit „…“.
  Pis eigene Schritte („Suche in deinen Dokumenten nach …“) ab 34 Zeichen gekürzt.
- `AppModel.pillOutcome`: Endet eine Antwort, während nur die Pille zu sehen ist, bleibt „Deine Antwort ist da“
  (grün, Häkchen, Figur lächelt) oder „Hat nicht geklappt“ (bernstein, Ausrufezeichen, Figur traurig) stehen, bis das
  Gespräch geöffnet wird. Ein Klick öffnet dann immer das ganze Gespräch, nicht die kompakte Form.
- `PillContent`: Ton als leichte Tönung, Rand und Zeichen, nie nur Farbe. Balken nur bei Zählbarem. Schimmer nur beim
  Arbeiten, aus bei „Bewegung reduzieren“.
- „Deine Antwort ist da“ in Gochi Hand, der Handschrift der Website (`HandFont` in `Theme.swift`, Schrift mit
  Lizenz in `Resources/Fonts`, Eintrag in `THIRD_PARTY_NOTICES.md`).
- Leeres Gespräch: vier Beispiele als Karten mit Symbol im 2×2-Raster statt blauer Linkliste.
- `PillStatusChecks`: Kurzformen in beiden Sprachen, Längen, keine Technikwörter, Vorrang (Frage > Arbeit > Ausgang).

**Ungebaut.** Geschrieben in einer Cloud-Umgebung ohne Swift. `check-strings.py` ist grün. Auf dem Mac nötig:
`swift build`, `swift run PippaChecks` (`PIPPA_THOUGHT_CHECKS=1` für den schnellen Teil), dann mit
`PIPPA_REGULAR_APP=1` eine Frage stellen, Fenster schließen, Pille beobachten, hell/dunkel, „Bewegung reduzieren“,
große Schrift.

## Offene Entscheidungen

- **Ergebnis in der Pille:** bleibt stehen, bis angesehen (so umgesetzt), oder nach 10 Minuten zurück zu „Pippa“?
- **Guard-Frage bei geschlossenem Fenster:** Heute öffnet sich das Gespräch dafür von selbst (`onNeedsPerson`).
  Regel 3 spräche für „Kurz eine Frage“ in der Pille und Warten. Nicht geändert, weil Pi solange blockiert ist;
  nach dem ersten echten Test entscheiden.
