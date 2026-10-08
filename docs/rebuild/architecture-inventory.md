# Architektur-Inventur: Was macht Pi, was macht Pippa?

Stand: 2026-10-08. Gelesen (nur lesend): `pippa-public` main @ `0123049`, Pi 1.1.0 aus
`fast-tidy/.build/pi-payload/release/node_modules/@earendil-works/`. LOC = `wc -l`.
Zielbild (entschieden): **Pi ist das Gehirn; Pippa ist Gesicht, Sicherheitsnetz und Mac-Anschluss.**
Modelle: nur Apple Foundation Models (AFM, on-device, macOS 26+) und K2 Horizon (llama.cpp). Gemma raus.
Vermutungen sind mit *(Vermutung)* markiert.

---

## 1. Was Pi mitbringt

Vorhandene Pakete im Payload: `pi-coding-agent`, `pi-agent-core`, `pi-ai`, `pi-codemode`, `pi-mcp`, `pi-tui`,
`pi-telemetry`, `chord`. **`pi-web-access` ist nicht im Pi-Payload** – es steckt nur in `runtime/pippa-web`
(npm `pi-web-access@0.37.0`, zwei Dateien gebündelt).

| Fähigkeit | Was genau | Doku |
|---|---|---|
| Built-in-Tools | `read`, `bash`, `edit`, `write` **aktiv per Default**; `grep`, `find`, `ls` vorhanden, aber nur per `--tools`/`defaultTools` | `docs/cli.md#tools`, `docs/settings.md` (`defaultTools`) |
| Tool-Auswahl | `--tools` (Allowlist oder `+name/-name`), `--exclude-tools`, `--no-builtin-tools` | `docs/cli.md` Z. 111–138 |
| Extensions | `registerTool`, Events `tool_call` (blocken/Input ändern), `tool_result` (ersetzen), `before_provider_request`, `context`, `session_before_compact`, `appendEntry`, `prepareLoadout` (Tool-Beschreibungen ersetzen), `ctx.executeTool` | `docs/extensions.md` |
| **Keine Rechteprüfung** | Pi fragt nicht vor Tool-Calls, keine Sandbox | `docs/security.md` Z. 3, 33 |
| Skills | Name+Beschreibung in den Systemprompt, Modell liest `SKILL.md` selbst; `/skill:name` erzwingt; `disable-model-invocation: true` = nur per Befehl; laden über Skill-Ordner oder `--skill <path>` | `docs/skills.md`, `docs/cli.md` (`--skill`, `--no-skills`) |
| Skills über RPC | `prompt` expandiert `/skill:name …` vor dem Senden | `docs/rpc-commands.md` Z. 33 |
| MCP nativ | stdio/HTTP, `exposure` `direct`/`codemode`/`deferred`/`hidden`, `toolExposure`, Ergebnis > 20 KB wird gekürzt; `pi.registerMcpServer` aus Extension | `docs/mcp.md` |
| Codemode | QuickJS-Skript ruft Tools parallel; `models.classify()` für Klassifikator-Modelle | `docs/codemode.md` |
| llama.cpp | Router-Modus, `/llama`, Provider `llama.cpp`; **Chat-Modelle als Klassifikatoren** (choice/bool/score über Next-Token-Wahrscheinlichkeiten, prompt-cache-freundlich) via `ctx.modelRegistry.classify()` | `docs/llama-cpp.md` Z. 89–106 |
| Pi startet keine Modellserver | – | `runtime/pippa-local-server/index.ts` Kommentar, `docs/llama-cpp.md` |
| Sessions | Session pro ID, `--session-dir`, Baum/Fork | `docs/sessions.md`, `docs/session-format.md` |
| Compaction | Auto bei `contextTokens > contextWindow − reserveTokens` (Default 16384), `modelOverrides` | `docs/compaction.md` Z. 27–42, 417–463 |
| RPC / SDK | JSONL über stdio; Extension-UI-Records (confirm/select) | `docs/rpc.md`, `docs/rpc-extension-ui.md`, `docs/sdk.md` |
| Packages | Extensions+Skills+Deps per npm/git verteilen | `docs/packages.md` |
| Provider | OpenAI-/Anthropic-kompatibel via `models.json`; **kein Apple-FM-Provider** in `pi-ai` (grep leer) | `docs/providers.md`, `docs/custom-provider.md` |
| Web | **Kein eingebautes Web-Such/Fetch-Tool** in Pi 1.1.0 | grep in `dist/` |

---

## 2. Bestandsaufnahme

Spalte „Modell direkt“: ruft Pippa ein Modell **an Pi vorbei**? (LS = llama-server per `LocalModelJSON`, AFM = Apple FM).

### 2a. Pi-Laufzeit (`runtime/`)

| Komponente | Was (1 Zeile) | Dateien | LOC | Modell direkt | Pi-Äquivalent | Empfehlung |
|---|---|---|---|---|---|---|
| Guard: Policy + Rückfrage | Vor jedem nicht-lesenden Tool-Call fragen (Presets `undo-first`/`ask-all`), Args einfrieren, fremden Tools/Extensions misstrauen | `pippa-guard/pippa-guard.ts`, `policy.ts`, `self-asking.ts` | 536+166+69 | nein | keins (Pi fragt nie, `security.md`) – nur der Hook `tool_call` | **KEEP** – das ist das Sicherheitsnetz. |
| Guard: Undo/Backup + Quittung | APFS-Klon vor `write`/`edit`, Manifest pro Aufruf, `pippa-receipt` via `appendEntry`, Restore | `pippa-guard.ts`, `files.ts`, `restore.mjs`; Swift: `PippaCore/PiUndo.swift` | 134+101+307 | nein | keins | **KEEP**. Passt genau zu „Dateiänderungen über Pi-bash/-Tools, Guard sichert“. Lücke: `bash` ist nur Log, außer schlichtem `mkdir`/`rm`/`mv` → Frage 6. |
| Eigene Dateitools | `list_folder`, `rename_or_move`, `move_files` (Batch, ein Undo), `move_to_trash` | `pippa-guard/pippa-tools.ts` | 192 | nein | `ls` (Built-in, nicht aktiv), `bash mv`/`trash` | `list_folder`: **REPLACE-WITH-PI** prüfen (`--tools +ls`; *Vermutung*: `ls` liefert keine Größen/Datum, dann KEEP). `move_files`: **KEEP-AS-SHORTCUT** – gemessen „r7: 16 Turns, 211 s für 15 Dateien“ ohne Batch (Kommentar `pippa-tools.ts` Z. 11). `rename_or_move`/`move_to_trash`: **KEEP** (Trash statt `rm`, sauberes Undo). |
| `budget.ts`: Request-Umschreiben | Ersetzt Parameter-Beschreibungen der Built-ins im Provider-Request; kürzt Built-in-Beschreibungen über `prepareLoadout` | `pippa-guard/budget.ts` (+ `BUILTIN_DESCRIPTIONS` in `pippa-tools.ts`) | 92 | nein | `prepareLoadout` nur für Beschreibungen, nicht für Parameter (Kommentar `budget.ts`) | **KEEP-AS-SHORTCUT**, Nutzen aber messen: Kommentar nennt nur „edit allein ~190 Tokens“, „Tool-Beschreibungen ~990 Tokens“, keine Sekunden. Zerbrechlich bei Pi-Updates (greift in Payload-Form ein). |
| `tool_result`-Deckel | Kürzt Tool-Ergebnisse auf ~0,75 Zeichen pro Kontext-Token (16k → 12 288 Zeichen) | `budget.ts` `capResult`/`resultLimit` | (in 92) | nein | Pi kürzt `read`/`bash` erst bei 50 KB; MCP > 20 KB (`mcp.md`) | **KEEP**, solange 16k-Kontext existiert. |
| MCP-Anbindung | Registriert App-MCP-Server nur für diese Session, Token aus env gelöscht | `pippa-guard/pippa-mcp.ts` | 57 | nein | **schon Pi-nativ** (`pi.registerMcpServer`) | **KEEP**. |
| `pippa-skills` (16 Ordner) | Anleitungen im Skill-Format + Pippa-Felder (`pippa-label`, `pippa-suggest` …) | `runtime/pippa-skills/*/SKILL.md`; Swift `PippaCore/Skills.swift` | 6–18 je Datei; Swift ≈140 | – | Pi-Skills (`skills.md`) | **Erreichen Pi nicht als Skills**: kein `--skill`, nicht in `~/.pi/agent/skills`; alle 16 haben `disable-model-invocation: true`. Swift liest sie und setzt den Text vor die Nachricht (`PiSkillTurn`, `PiConversationDefault.swift`) oder nutzt ihn als System-Prompt für direkte LS-Aufrufe (`Prompts`: dokument-einordnen, rechnung-auslesen, fristen-erkennen, frist-berechnen; `LetterModel`: aktionen-vorschlagen, online-pruefen); `termin-aus-mail` wird in MCP-Ergebnisse gehängt. → Button-Skills **REPLACE-WITH-PI**: `--skill <bundle>/pippa-skills` + RPC-`prompt` mit `/skill:name …`. |
| `pippa-web` | Eigener Node-Fetch-Prozess (DuckDuckGo-Suche + Seitentext), nur von der App gestartet | `runtime/pippa-web/src/fetcher.mjs`, `build-web-provider.mjs` | 249+24 | nein | `pi-web-access` als Pi-Package (nicht installiert) | **KEEP** (nutzt bereits `pi-web-access`-Code). Als Pi-Package ginge das Modell direkt ins Netz, vorbei an QueryGuard und Einwilligungskarte. |
| `pippa-local-server` | Terminal-Extension: startet llama-server für `pi` im Terminal, gemeinsames Lock mit der App | `runtime/pippa-local-server/{index.ts,common.mjs,ensure.mjs,supervisor.mjs}` | 107+219+84+108 | nein | keins (Pi startet keine Server); Pi hat `llama.cpp`-Router-Provider | **KEEP**. Prüfen, ob `pippa-local` durch Pis nativen `llama.cpp`-Provider ersetzbar ist (Frage 7). |

### 2b. App: Pi-Start, Anbindung, Sicherheitsnetz

| Komponente | Was | Dateien | LOC | Modell direkt | Pi-Äquivalent | Empfehlung |
|---|---|---|---|---|---|---|
| Pi-Start | Kommandozeile: `--extension` guard/tools/mcp, `--no-context-files`, `--no-approve`, eigener `--system-prompt`, Session pro Gespräch, offline-env | `PiRPC/PippaPiLaunch.swift`, `+MCP.swift` | 126+29 | nein | CLI | **KEEP**. **Kein `--tools`, kein `--skill`** → aktiv nur `read`,`bash`,`edit`,`write` + Pippa-Tools + MCP (sofern Nutzer-`defaultTools` nichts ändert). `grep`/`find`/`ls` im Guard-`READ_ONLY` sind toter Pfad. Systemprompt in Swift (de/en); `persona.md` geht nur in Fixflows. |
| PiRPC-Client | Startet `pi --mode rpc`, JSONL, Events, Extension-UI | `PiRPC/PiRPCClient.swift`, `PiActionReceipt.swift` | 410+168 | nein | Pis `RpcClient` (nur TS) | **KEEP**. |
| Gespräch (RPC-Chat) | Gesprächsfluss, gezeigte Dinge, Kaltstart-Anzeige | `Pippa/App/PiRPCChat*.swift` | 540+140+51 | nein | – | **KEEP** (Gesicht). |
| Gezeigter Kontext | Beschreibt gezeigte Dateien mit Pfad + passendem Tool; Pi liest selbst | `PippaCore/PiShownContext.swift` | 240 | nein | – | **KEEP**. „ContextSelection“ existiert nicht mehr (nur Kommentar). |
| App-MCP-Server | `calendar_read`, `reminders_read`, `mail_selected`, `mail_search`, `excel_selection`, `read_document` (PDF/OCR/Office/Mail), `web_search`, `read_web_page`; schreibend `calendar_add`, `reminder_add`, `mail_draft` | `PippaCore/MCP/*` (6 Dateien) | 1967 | nein | Pi-MCP-Client nativ; Inhalte Mac-spezifisch | **KEEP** – Kern des Mac-Anschlusses (TCC auf „Pippa“). |
| Web-Gate | QueryGuard (keine persönlichen Daten in Suchanfragen), Karte, Fetcher | `PippaCore/Lookup/*` | 1197 | nein | keins | **KEEP** (Sicherheitsnetz). |
| Antwort-Prüfung | `SourceFidelity` (streicht unbelegte Daten/Beträge), `PiReadLedger`, `MailDraftOffer` | `SourceFidelity.swift`, `PiReadLedger.swift`, `MailDraftOffer.swift` | 558+148+150 | nein | keins | **KEEP**. `MailDraftOffer` entstand wegen Gemma-Fehlverhalten → mit K2 neu prüfen. |
| Online-Provider (BYO-Cloud) | `pippa-online` in models.json, Loopback-Proxy fragt vor jedem Request | `PiSetup/PiOnlineProvider.swift`, `PippaOnlineProxy.swift` (438), `PippaOnlineDesk.swift` | ≈600 *(Schätzung)* | nein (Pi ruft, Proxy fragt) | Pi-Provider nativ (ohne Rückfrage) | Passt nicht zu „nur AFM + K2“ → **Frage 3**. |
| Installer/Setup | Pi installieren, `models.json`, Terminal-Extension kopieren, Lock | `PippaCore/PiSetup/*` | 2303 | nein | Packages nur teilweise | **KEEP**. |

### 2c. Fixflows, die Modelle **direkt** aufrufen (an Pi vorbei)

| Komponente | Was | Dateien | LOC | Modell direkt | Pi-Äquivalent | Empfehlung |
|---|---|---|---|---|---|---|
| `LocalModelJSON` | Strukturierter Call an llama-server (`/v1/chat/completions`, `response_format: json_schema`, Temp 0.1) | `PippaCore/LocalModelJSON.swift` | 70 | **LS** | kein Schema-JSON über RPC; nur `classify` (choice/bool/score) | Basis aller LS-Bypässe; bleibt, solange einer der Flüsse unten bleibt. |
| `LocalEngine.askModel` / `letterJSON` | Wrapper: Lease am geteilten Server, Replay für Checks | `PippaCore/LocalEngine.swift` Z. 372–436 | (in 1161) | **LS** | – | je Fluss (unten). |
| `LocalEngine` gesamt | Modell-Download/-Wahl, Übersicht, Sortieren, Rechnungen, Fristen, Export, Undo, Integrationen | `LocalEngine.swift`, `Engine.swift`, `StubEngine.swift` | 1161+327+278 | **LS** | – | Executor/Undo/Integrationen **KEEP**; Modellteile je Fluss. |
| Prompts | Persona + Skill-Text als System-Prompt; JSON-Schemas | `PippaCore/Prompts.swift`, `Resources/persona.md` | 65 | (Daten für LS) | Skills | mit den Flüssen mitziehen. |
| Aufräumen: `TidyIntent` + `FolderLookup` | Erkennt „räum Downloads auf“ im Code (kein Modell), leitet am Pi vorbei in nativen Fluss | `PippaCore/TidyIntent.swift` (FolderLookup ab Z. 140), `Pippa/App/AppModel+Tidy.swift`, Weiche `AppModel.swift` Z. 1480 | 222+45 | nein | Pi: `list_folder` + `move_files` (so im Systemprompt) | **KEEP-AS-SHORTCUT** – Vorschau-Karte, ein Undo für den Job. Zahl nur indirekt (211 s/15 Dateien ohne Batch); **neu messen** Pi+`move_files` vs. nativ. |
| `PreSort` | Ordnet ohne Modell nach Typ/Name/EXIF/Duplikat | `PippaCore/PreSort.swift` | 130 | nein | – | **KEEP**. |
| `proposeSort` + `TidyClassifier` | Stufe 3: unklare Dokumente einordnen (Kategorie, Absender, Art, Datum, Betreff) | `LocalEngine.swift` Z. 657–780, `TidyClassifier.swift` | ≈120+150 | **AFM** zuerst, dann **LS** | Pi-`classify` nur Kategorie, nicht Absender/Datum | **KEEP-AS-SHORTCUT**: AFM ~3 s/Datei vs. lokal p50 26 s, max 39 s (Gemma 12B, `TidyClassifier.swift` Z. 17). LS-Zweig mit K2 neu messen; bei ähnlich langsam → LS-Zweig **DELETE**. |
| Rechnungen + Export | Typ/Datum/Absender/Betrag/Beleg je Datei; CSV/XLSX | `LocalEngine.extractInvoices` (Z. 971), `Export.swift`, `Analysis.swift` | ≈40+219+259 | **LS** | Pi + Skill `rechnung-auslesen` + `write` | Frage 5. **REPLACE-WITH-PI** nur, wenn Messung gleiche Trefferquote zeigt; sonst KEEP-AS-SHORTCUT. Export-Code KEEP. |
| Fristen | Fristen + Zitat + Seite, relative Fristen rechnen, im Code prüfen | `LocalEngine.modelDeadlines`/`deadlines` (Z. 1021–1058), `DeadlineAnalysis.swift`, `Deadlines.swift` | ≈40+114+495 | **LS** | Pi + Skill `fristen-erkennen` | wie Rechnungen. `Deadlines.swift`-Muster laut Kommentar „Vergleichs-Fixtures“, aber `LetterFacts` nutzt sie → nicht ungeprüft löschen. |
| Brief: `LetterModel` / `LetterActions` | „Nächste Schritte“ (Schema aus erlaubten Aktionen) und „Online prüfen“ (Anfrage → Fetch → Zitate) | `Letter/LetterModel.swift`, `LetterActions.swift`, `LocalEngine.proposeLetterActions/checkOnline` | 118+157 | **LS** | Pi-Gespräch mit `web_search`/`read_web_page` (vorhanden) | `checkOnline`: **REPLACE-WITH-PI** (gleiches `WebAccessGate`, `/skill:online-pruefen`). `proposeLetterActions`: KEEP-AS-SHORTCUT oder **DELETE** (Typ-Aktionen kommen sofort aus Code) → Frage 5. |
| Brief: `LetterFacts.refined` | Erste Zeile zum Brief schärfen | `Letter/LetterFacts.swift`, `QuickModel.swift`, `LetterController.swift` Z. 363 | 292+112 | **AFM** | keins (Pi kann AFM nicht) | **KEEP-AS-SHORTCUT** (kein Kaltstart). Keine Messzahl. |
| Brief: Entwurf | Entwurf per Pi-Session pro Brief, Skill-Text vorangestellt | `LetterController.swift` Z. 505–560 | (in 893) | nein | `/skill:antwort-schreiben` | **REPLACE-WITH-PI** (nur Skill-Mechanismus). |
| `LetterController` | Mail → Zeile → Aktionen → Entwurf → in Mail einfügen | `Pippa/App/LetterController.swift`, `Letter/MailReply*.swift` | 893+222 | indirekt | – | **KEEP** (Gesicht/Mac). |
| `DocumentSuggestions` | Rolle eines Dokuments für passende Buttons | `PippaCore/DocumentSuggestions.swift`, `TrayController.swift` Z. 69 | 178 | **AFM** (16 Tokens, Temp 0) | Pi-`classify` (nur llama.cpp, Kaltstart) | **KEEP-AS-SHORTCUT** – Deko darf keinen großen Modellstart auslösen. Keine Messzahl. |
| `ThingActions` | Welche Buttons (Format + Rolle + Gewohnheiten) | `ThingActions.swift`, `Habits.swift` | 155+78 | nein | – | **KEEP**. |
| `QuickModel` | AFM-Wrapper | `PippaCore/QuickModel.swift` | 112 | **AFM** | keins | **KEEP** – einziger AFM-Zugang. |
| Kalender-Intent | „Was habe ich morgen?“ im Code erkannt, nativ beantwortet | `PippaCore/Calendar/*`, Weiche `AppModel.swift` Z. 1472 | 737 | nein | Pi + `calendar_read` | **KEEP-AS-SHORTCUT** (kein Modellstart). Keine Messzahl. Kommentar nennt falsches Tool `read_calendar`. |
| Tabellen-Summe, Werkzeuge (PDF, Verkleinern, OCR-Ebene) | reiner Code | `Sheet/*`, `Tools/*` | 1067+925 | nein | – | **KEEP**. |

### 2d. Modelle, Server, Kaltstart

| Komponente | Was | Dateien | LOC | Modell direkt | Pi-Äquivalent | Empfehlung |
|---|---|---|---|---|---|---|
| `ModelSelector` + Tabelle | 8 GB → `qwen3.5-4b-q4`; 16 GB+ → `k2-horizon-7b`; 24 GB+ „Gründlicher“ → `qwen3.6-35b-a3b-iq3` | `PippaCore/Models.swift` Z. 95–180 | (in 648) | – | keins | **KEEP**, Tabelle nach Fragen 1–2. **Befund:** `k2-horizon-7b` hat in `catalog.json` **kein `pinned`** → `choose()` liefert `.modelUnavailable` für 16 GB+ (Z. 149), bis `scripts/pin-model.sh` läuft. |
| Katalog | 17 Modelle, davon 2 Gemma | `Resources/catalog.json` | – | – | – | auf Tabellen-Keys eindampfen. |
| `LlamaServer` | Prozess, Port/Key, Idle-Unload, Slot-Save/Restore, Lease | `LlamaServer.swift`, `PiSetup/PiLocalServer.swift`, `PiServerLock.swift` | 594+164+… | startet LS | Pi startet keine Server | **KEEP**. Gemma-spezifisch: `--swa-full` (Z. 170–173). *Vermutung:* `--reasoning off` gilt auch für Pi-Gespräche auf demselben Server, obwohl K2 `reasoning_effort: low` bekommt – prüfen. |
| `ColdStart` | Ladefortschritt | `ColdStart.swift`, `PiRPCChat+ColdStart.swift` | 171+51 | nein | keins | **KEEP**. |
| `ExistingModels` | Modelle aus LM Studio/Ollama übernehmen | `ExistingModels.swift` | 71 | nein | – | KEEP. |

### 2e. Entwickler-Ziele

| Ziel | LOC | Modell direkt | Empfehlung |
|---|---|---|---|
| `PiRPCR2Spike`, `PiRPCR3Spike`, `PiRPCR10Spike`, `PiSetupSpike`, `PippaLive` (inkl. `DecisionSpike` mit AFM, `TidySpeedLive`) | 3791 zusammen | ja (AFM, LS) | Spikes mit Gemma-Default: **DELETE** oder auf K2. `TidySpeedLive` behalten (Messzahlen für Fragen 4–5). |

---

## 3. Gemma-Fundstellen

Gemma steht **nicht** mehr in `ModelSelector.table`; erreichbar nur über `ModelSelector.named` / `PIPPA_PI_MODEL` / gespeichertes `piModel`.

| Ort | Fundstelle | Art |
|---|---|---|
| `app/Sources/PippaCore/Resources/catalog.json` | `gemma-4-26b-a4b` (Z. 172ff), `gemma-4-12b` (Z. 282ff) inkl. `thinkingRequired` (von Swift nicht gelesen) | Daten – entfernen |
| `PippaCore/LlamaServer.swift` Z. 60–61, 164–173, 255; `PiSetup/PiLocalServer.swift` Z. 124–126 | `--swa-full` + `PIPPA_LLAMA_SWA_FULL` | Code – nach K2-Messung entfernen |
| `PippaCore/PiSetup/PiSetupFlow.swift` Z. 82; `Pippa/App/PiSetupController.swift` Z. 16 | Migration „Gemma 4 12B → K2“ | Migrationspfad **behalten**, solange Nutzer mit Gemma existieren |
| `PippaCore/TidyClassifier.swift` Z. 17 | Messung „gemma-4-12b p50 26 s“ | Kommentar – mit K2 neu messen |
| `MailDraftOffer.swift` Z. 3; `MCP/PippaMCPTurn.swift` Z. 285; `MCP/PippaMCPWrite.swift` Z. 349; `runtime/pippa-guard/pippa-tools.ts` Z. 94; `pippa-guard.ts` Z. 429; `files.ts` Z. 83, 102; `Pippa/App/PiReceiptSnapshot.swift` Z. 7 | Begründungen für Schutzcode | Kommentar – Schutz bleibt, Text neutralisieren |
| `PippaChecks/R7Checks.swift` Z. 59–110; `Wave2dChecks.swift` Z. 64–180; `main.swift` Z. 613–615, 762–763; `SetupChecks.swift` Z. 205–229; `TerminalAutostartChecks.swift` Z. 26–31, 186 | Tests mit Key `gemma-4-12b` (hängen am Katalogeintrag) | auf `k2-horizon-7b` umstellen, **bevor** der Eintrag fällt |
| `PippaChecks/R3Checks.swift` Z. 256–347; `SourceFidelityChecks.swift` Z. 4, 58, 142 | echte Gemma-Antworten als Fixtures | dürfen bleiben, nur umbenennen |
| `PiRPCR2Spike/main.swift` Z. 92, `R7.swift` Z. 63; `PiRPCR3Spike/main.swift` Z. 10, 80; `PiSetupSpike/main.swift` Z. 41; `PippaLive/W4aLetterLive.swift` Z. 8, 19; `PippaLive/TidySpeedLive.swift` Z. 60 | Default-Modell `gemma-4-12b` | Dev – Default auf K2 |
| `runtime/pippa-local-server/test/real-pi.test.mjs` Z. 41–51; `test/autostart.test.mjs` Z. 57–61, 134–135 | Modell-ID (nur String) | Tests – umbenennen |
| `scripts/pi-rpc-spike.sh` Z. 10, 43–45, 63, 91–142 | Default `gemma`, GGUF-Pfad | Dev-Skript |
| `docs/development.md` Z. 194; `docs/settings-simplification.md` Z. 51, 61 | Beispiele/Historie | Doku |
| `README.md` Z. 122; `THIRD_PARTY_NOTICES.md` Z. 18 | Lizenzhinweis Gemma 4 | entfernen, sobald Gemma nicht mehr ladbar |
| `site/` | keine Treffer | – |

---

## 4. Offene Fragen an den Owner

> Stand nach dem Umbau: Fragen 1–3, 5, 6, 8, 9 sind in `HANDOFF.md` (Owner-Entscheidungen) bzw. in den Commits
> beantwortet; 4 (Messungen) und 7 (llama.cpp-Provider) stehen in `MAC-HANDOFF.md`. Die Tabellen oben beschreiben
> den Stand **vor** dem Umbau.

1. **8-GB-Macs ohne Gemma/Qwen:** K2 7B braucht 8,5 GiB, Budget bei 8 GB ist 4,8 GiB (`Models.swift` Z. 106). Heute: `qwen3.5-4b-q4`. Bei „nur AFM + K2“ bliebe 8 GB **nur AFM**, das Pi nicht ansprechen kann. Optionen: (a) Qwen 4B als Ausnahme behalten, (b) 8 GB ohne Pi-Gespräch, nur Fixflows mit AFM, (c) AFM als lokaler OpenAI-kompatibler Endpunkt für Pi (Shim wie `PippaOnlineProxy`) – neuer Code, Tool-Calling mit AFM ungetestet.
2. **„Gründlicher“ (Qwen3.6 35B-A3B IQ3, 24 GB+) streichen?** Ersatz `k2-horizon-mova-36b-a4b` ist `pending` (llama.cpp PR #29535).
3. **Eigener Online-Dienst (`pippa-online`):** behalten oder entfernen?
4. **Welche Abkürzungen sind durch Zahlen gedeckt?** Im Code belegt nur: AFM-Einordnen ~3 s vs. lokal p50 26 s/Datei (Gemma 12B); ohne `move_files` 211 s für 15 Dateien. **Keine** Zahlen für Kalender-Intent, `DocumentSuggestions`, `LetterFacts.refined`, `budget.ts` (Sekunden), Rechnungen/Fristen LS vs. Pi. Vor Entscheidung messen (`PippaLive`)?
5. **Rechnungen, Fristen, Brief-Vorschläge:** Schema-JSON direkt an llama-server (heute) oder Pi-Gespräch mit Skill? Pi bietet kein erzwungenes JSON über RPC, nur `classify`.
6. **Dateiänderungen per bash:** Guard sichert nur `mkdir`/schlichtes `rm`/`mv`; sonst „nicht wiederherstellbar“, in `undo-first` wird gefragt. So lassen, und Systemprompt bevorzugt weiter die eigenen Tools?
7. **`pippa-local` vs. Pis `llama.cpp`-Provider:** Umstieg bringt `/llama`, Router, `classify()`, kostet Installer-/Lock-Umbau. Gewünscht?
8. **Compaction:** Pippa setzt keine `compaction`-Werte. Mit `contextWindow` 16384 und Default `reserveTokens` 16384 wäre die Schwelle 0 *(Vermutung: Compaction vor jedem Prompt)*. `compaction.modelOverrides` für `pippa-local/<id>` setzen?
9. **K2 Horizon 7B ist nicht gepinnt** – vor Release `scripts/pin-model.sh`, sonst kein Modell für 16 GB+.

---

## 5. Vorgeschlagene Reihenfolge

Jeder Schritt einzeln commit- und revertierbar; Gates lokal (`PippaChecks`, `node --test`).

1. **K2 pinnen** (`scripts/pin-model.sh k2-horizon-7b …`) – reine Daten.
2. **Gemma aus Tests/Spikes lösen:** Checks, Spikes, Skripte, runtime-Tests auf `k2-horizon-7b`; Katalog bleibt noch.
3. **Gemma aus Katalog** + README/THIRD_PARTY_NOTICES; Migrationspfad in `PiSetupFlow` bleibt.
4. **Compaction-Override** für `pippa-local` beim Schreiben der Pi-Settings (oder belegen, dass Pi selbst kappt).
5. **Skills echt an Pi:** `--skill <bundle>/pippa-skills` in `PippaPiLaunch.arguments`; `PiSkillTurn` schickt `/skill:name <Nachricht>`. `disable-model-invocation: true` bleibt (kein Prompt-Zuwachs). Rückweg: Flag raus.
6. **`--tools` explizit** (`read,bash,edit,write,list_folder,rename_or_move,move_files,move_to_trash` + `mcp__pippa__*`), damit Nutzer-`defaultTools` nichts einschalten; optional `ls` statt `list_folder` testen.
7. **Messen** (`PippaLive tidy-speed` mit K2; Kalender-Intent vs. Pi; `budget.ts` an/aus) → Zahlen für Frage 4.
8. **Nach Messung:** LS-Zweig in `TidyClassifier` behalten/löschen; `--swa-full` entfernen, falls K2 es nicht braucht.
9. **„Online prüfen“ im Brief** auf Pi-Gespräch + `/skill:online-pruefen` + vorhandenes `WebAccessGate`; dann `LetterModel.check*` und `LocalEngine.checkOnline` löschen.
10. **Rechnungen/Fristen/Brief-Vorschläge** erst nach Frage 5; bis dahin unverändert.
11. **Modelltabelle** nach Fragen 1–2 anpassen (eine Zeile je Fall in `ModelSelector.table`).
