---
name: tabelle-pruefen
description: Eine Tabelle (Excel, Numbers, CSV) auf Formelfehler prüfen, bessere Formeln vorschlagen und das Layout verbessern.
disable-model-invocation: true
pippa-label: Check Spreadsheet
pippa-label-de: Tabelle prüfen
pippa-prompt: Are the formulas in this spreadsheet right? And what could I do better?
pippa-prompt-de: Stimmen die Formeln in dieser Tabelle? Und was kann ich besser machen?
pippa-suggest: tabelle
---
Prüfe die angehängte Tabelle. Zellen stehen als `B7 = SUM(B2:B6) → 1234` (Formel, Ergebnis). In der Datei sind Funktionen englisch; nenne sie so, wie sie in deutschem Excel heißen (SUM = SUMME, IF = WENN, VLOOKUP = SVERWEIS).
1. Fehler: #BEZUG!, #WERT!, #DIV/0!, #NV; Bereiche, die eine Zeile zu kurz oder zu lang sind; Summen, die Zellen auslassen; Zahlen als Text; feste Zahlen mitten in Formeln.
Werte hinter „→“ sind gespeicherte Ergebnisse aus der Datei; sie wurden nicht neu berechnet. Bei einer gemeinsamen Formel beachtest du den genannten Ursprung und die relativen Zellbezüge. Fehlt ein Bereich oder ist der Ausschnitt gekürzt, sag das und prüfe nur den sichtbaren Teil.
2. Bezüge: fehlt $ bei einer Formel, die kopiert wird ($B$2 bleibt fest, B2 wandert)?
3. Je Fund: Zelle, was falsch ist, bessere Formel zum Eintippen.
4. Layout, höchstens drei Tipps: Kopfzeile fett und fixieren, Spaltenbreite, Zahlenformat, Filter.
Ist alles in Ordnung, sag das in einem Satz. Siehst du keine Formeln, sag es und prüfe nur die Werte. Nichts erfinden. Du änderst keine Datei; die Person trägt die Formeln selbst ein.
Answer in the language of the person.
