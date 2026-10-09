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
- [x] Werkzeug-Schritte in der „Denkt nach“-Zeile und in der Quittung (`4f4ca97`).
- [x] K2-Denkstufe nach dem Patch: high bleibt (gepatcht high 20/20, Median 6,6 s; low 18/20, 9,6 s).
- [x] 2026-10-09 auf Wunsch des Owners: K2-Standard ist jetzt medium (gepatcht, Notiz lesen: medium 19/20, high 9/10,
      Mac unter Fremdlast). Anlass: kalte Ein-Satz-Frage über Pi dauerte 91 s, davon 66 s Nachdenken auf high.
- [ ] Restliche Texte aus dem Audit (KI/Wissen-Begriff, Einstellungen „API-Schlüssel“, Skill-Labels, englische Meldungen der Terminal-Erweiterung).
- [ ] Phase 3/4: Szenarien mit K2 + Apple FM in der echten App, UI-Rundgang.
- [x] Schleifenbremse im Guard, `read` auf Dokumente → `read_document`, Mail-Hinweis nur auf Wunsch (`4cfbcc8`, `a31e0fa`, `1892c0f`).
- [x] ⌘V mit Datei oder Bild hängt an wie Ziehen (`198cd17`).
- [x] Einordnen beim Aufräumen gemessen: Apple FM p50 2,0 s/Datei, K2-Rückfall p50 3,2 s/Datei → Rückfall bleibt.
- [ ] Erste OCR nach längerer Pause: 53–60 s im Spike (warm 0,08 s/Seite); in der App nach Leerlauf nachmessen.
      09.10. (macOS 27.0.1, frischer Prozess, `PippaLive ocr-bench`): `documents` kalt 33,0 s / warm 0,08 s; `accurate` kalt 0,11 s / warm 0,07 s,
      beide CER 0 % auf den Fixtures. Die App nutzt ab macOS 26 `documents`. In der App nach Leerlauf weiter offen (Klicks blockiert).
- [ ] K2-Deutsch: Kernfakten stimmen, aber Füllsätze und Halbsätze (r2 b/s/n); Owner-Entscheidung, ob Qwen später wieder verglichen wird.
- [x] Nachtrag 09.10. früh: Freigabe-Karte/Kontrast/Vorschauzeile (`77ad89b`), Speicherplatz-Fehler + „Im Hintergrund weiterladen“ (`7aa17ba`),
      Beispiele im leeren Gespräch (`c7bcac5`), Papierkorb-Quittung (`b15b005`), K2 Temperatur 0.6 (`efae00c`), Schriftgröße (`a51a5d8`).
- [x] r7 latency Endstand (K2 gepatcht, high, 0.6): 18/18 mit Antwort, erstes Wort Median ~12 s, gesamt ~16 s; Kaltstart 11,7 s.
- [x] Owner 09.10.: durchgehend „KI“ / “AI” (`ae28782`). Gemma-1.0-Frage entfällt: es gibt noch keine Nutzer.
- [x] llama.cpp upstream (09.10. geprüft): kein Issue/PR zu den K2-Denk-Tags, Parser auf master unverändert → Patch bleibt.
- [ ] UI-Rundgang offen: Einstellungen „Gemerkte Aktionen“,
      „Für weitere Antworten“ → „Verwendete Dateien (n)“, Mail-Karte „Ich sende nichts“, Workspace-Szene `workspace-02-overview` (schon auf main rot).
- [ ] Echte Klicks in der App (Erststart, Drag-and-drop, ⌘V, Rechtedialoge) – nur Snapshots und Spikes gelaufen.
      09.10.: Pippa ist `accessory`, Computer-Use sieht sie nicht → `PIPPA_REGULAR_APP=1` + `CFFIXED_USER_HOME` (development.md).
      Erststart-Karte erscheint korrekt („Darf ich jetzt meine KI laden? 5,6 GB“); Klicks selbst noch nicht gelaufen.

## UI/UX (09.10.2026)

- [ ] Fixplan in `docs/rebuild/UI-FIXPLAN.md` (Phasen 1–5: kleine Fehler, Struktur, lebendige Pille, Belege im Text, Aufgaben zum Antippen).

## Owner-Funde 09.10. vormittags (echte App)

- [x] KI-Download im Pi-Weg: „bereitet das Laden vor …“ ewig, „Jetzt laden“ ohne Wirkung, offline keine Meldung (`5242632`).
- [x] Favicon weiß mit Ring (`c76b6fb`).
- [ ] Drag-and-drop auf Pippa klappt nicht, wenn das Fenster offen ist.
- [ ] Kaltstart-Fortschritt („Mache mich bereit … 14 s“) auf 10/10: echter Anteil, klare Schritte.
- [ ] „Such alle Unterlagen für Steuer 2025“: Pippa fragt nach Websuche, findet lokal nichts und fragt zurück. Ziel: wie die
      Website-Demo (Inhaltssuche, mehrere Ordner, Liste mit Fundstellen).
