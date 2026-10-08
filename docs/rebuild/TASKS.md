# Aufgaben Umbau Pi-first

Siehe HANDOFF.md, Abschnitt „Reihenfolge“. Hier abhaken. Stand 08.10.2026, Session in einer Linux-Cloud-Umgebung:
kein Swift, kein Mac, Hugging Face gesperrt. Swift-Änderungen sind nur per Syntaxprüfung (tree-sitter) und Durchsicht
geprüft, **nicht gebaut**. Vor dem Mergen auf einem Mac `swift build` und `PippaChecks` laufen lassen.

- [~] 0. Gates auf main: Linux-Teil grün (check-strings, Guard 50/51 – der eine Fehler ist der APFS-Klon-Test, nur auf
      macOS sinnvoll –, Web 14/14, Autostart 9/9, real-pi 1/1, Site, Release). „default model is pinned“ rot wie erwartet.
      Swift-Gates offen (Mac).
- [x] 1. K2 gepinnt (Mac mini, `ce997cc`). Kleines K2 gibt es: `IFM/K2-Horizon-3.7B-GGUF` (Dateien heißen „4B“, Q4_K_M 3,16 GB,
      Apache-2.0), geladen und SHA geprüft, **noch nicht im Katalog** (Owner: Qwen/8 GB vorerst zurückgestellt). K2 mit Pi getestet:
      llama.cpp b11503 parst K2s Denk-Tags nur pro Stufe → Tool-Calls landen im Denktext (low 24/30, medium 0/20, high 30/30).
      Lösung: Patch `app/Packaging/llama-patches/k2-horizon-think-tags.patch`, llama-server wird aus Quelle gebaut (`984f344`);
      gepatcht low 19/20 ohne Leck. Upstream-PR-Entwurf: `docs/rebuild/llama-cpp-k2-pr.md` (nicht eingereicht).
- [x] 2. Gemma raus (Katalog, Tests, Spikes, Skripte, README, Notices). `--swa-full` entfernt (`72a8d9b`): K2 unterstützt es nicht.
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
- [~] 10. Aufräumen, Doku: README, development.md, settings-simplification.md, Datenschutzseite angepasst; toter Code der
      alten Brief-/Web-Abläufe entfernt. Messzahlen in die Doku nach Schritt 9.

Weiter auf dem Mac: `docs/rebuild/MAC-HANDOFF.md`.

## Mac mini, 08./09.10.2026 (Owner-Test und Nachtarbeit)

- [x] Freigabe-Flut: `2>/dev/null`, `| head`, Pipes in Anführungszeichen, `cd`, `xargs grep`, `find -exec grep` zählen als „nur schauen“ (`bef84f0`, `ade426e`).
- [x] Freigabe als Karte im Gespräch statt Fenster, Befehl hinter „Details“ (`6ef4afb`).
- [x] Frage beim Laden merken statt „Frag mich gleich noch einmal“; Guard-Sätze ohne Fachwörter (`1e1e4f4`).
- [x] Prompt: eigene Dateien zuerst mit Spotlight, find/grep nur mit Pfad (`30f6a02`).
- [ ] Werkzeug-Schritte in der „Denkt nach“-Zeile (läuft).
- [ ] K2-Denkstufe nach dem Patch neu wählen (low vs. high, Zeiten ohne Fremdlast).
- [ ] Restliche Texte aus dem Audit (KI/Wissen-Begriff, Einstellungen „API-Schlüssel“, Skill-Labels, englische Meldungen der Terminal-Erweiterung).
- [ ] Phase 3/4: Szenarien mit K2 + Apple FM in der echten App, UI-Rundgang.
