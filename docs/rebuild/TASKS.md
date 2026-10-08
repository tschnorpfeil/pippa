# Aufgaben Umbau Pi-first

Siehe HANDOFF.md, Abschnitt „Reihenfolge“. Hier abhaken. Stand 08.10.2026, Session in einer Linux-Cloud-Umgebung:
kein Swift, kein Mac, Hugging Face gesperrt. Swift-Änderungen sind nur per Syntaxprüfung (tree-sitter) und Durchsicht
geprüft, **nicht gebaut**. Vor dem Mergen auf einem Mac `swift build` und `PippaChecks` laufen lassen.

- [~] 0. Gates auf main: Linux-Teil grün (check-strings, Guard 50/51 – der eine Fehler ist der APFS-Klon-Test, nur auf
      macOS sinnvoll –, Web 14/14, Autostart 9/9, real-pi 1/1, Site, Release). „default model is pinned“ rot wie erwartet.
      Swift-Gates offen (Mac).
- [ ] 1. K2 pinnen, kleines K2 für 8 GB, K2 mit Pi testen – **blockiert**: huggingface.co ist in dieser Umgebung gesperrt.
- [x] 2. Gemma raus (Katalog, Tests, Spikes, Skripte, README, Notices). `--swa-full` bleibt bis zur K2-Messung.
- [x] 3. Compaction und Kontext: `compaction.modelOverrides` je `pippa-local`-Modell (16k: Schwelle 12288 statt 0). Messung offen.
- [x] 4. Reasoning an Pi: `reasoning`/`thinkingLevelMap`/Template-Schalter in models.json, `modelThinkingLevels`,
      kein `--reasoning off` mehr am Pi-Server. Mit echtem Pi gegen Stand-in-Server geprüft. Messung offen.
- [x] 5. Skills echt an Pi: `--no-skills --skill <bundle>`, Buttons schicken `/skill:name …`.
- [x] 6. Pis Werkzeuge: `--tools` fest, `fd`/`rg` gepinnt im Bundle, `fd`/`mdfind`/`mdls` im Guard „nur schauen“.
- [x] 7. Feste JSON-Abläufe raus (gemischt): Rechnungen → Pi + CSV, Fristen → Muster-Karte + Pi mit `calendar_add`,
      „Online prüfen“ → Pi + Web-Karte, Modell-Vorschläge weg. `LocalModelJSON` nur noch Rückfall beim Aufräumen ohne Apple FM.
- [ ] 7b. Umstieg auf Pis `llama.cpp`-Provider – Befund und Optionen beim Owner (siehe Zusammenfassung), noch nicht gebaut.
- [x] 8. Online-Dienst über Pi-Provider, ohne Rückfrage (Owner-Entscheidung): Proxy, Karte und Desk entfernt.
- [ ] 9. Abkürzungen messen – **blockiert**: braucht Mac und Modell.
- [~] 10. Aufräumen, Doku: README, development.md, settings-simplification.md, Datenschutzseite angepasst.
