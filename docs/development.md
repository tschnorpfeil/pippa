# Developing Pippa

How Pippa is put together, how to build, check and release it, and where it keeps things. The [README](../README.md)
covers what Pippa does and how it works at a glance; [Updating Pi](updating-pi.md) covers moving to a new Pi release;
[Settings simplification](settings-simplification.md) records which settings exist and why.

## Architecture

```
Pippa.app (Swift, SwiftUI)
 ├─ llama-server (llama.cpp)         local model on 127.0.0.1, started and unloaded by the app
 ├─ pi --mode rpc                    the agent, one Pi session per Pippa conversation
 │   ├─ --extension pippa-tools      file tools, helps for small models (runtime/pippa-tools)
 │   ├─ --extension pippa-web        web search and pages: pi-web-access (runtime/pippa-web)
 │   └─ MCP client ───────────────►  Pippa's MCP server inside the app (127.0.0.1)
```

| Piece | Where | Role |
|---|---|---|
| App | `app/Sources/Pippa` | Pill, conversation window, settings, setup UI, hotkey, Sparkle updates |
| Core | `app/Sources/PippaCore` | Model catalog and selection, downloader, `llama-server`, Pi installer, MCP server, readers for Mail, Calendar and Excel, scan tools, journal |
| Pi RPC client | `app/Sources/PiRPC` | Starts Pi with Pippa's flags and speaks JSON lines over stdin and stdout |
| Pi extensions | `runtime/pippa-tools` | Pippa's small file tools, helps for small local models (document reader instead of raw bytes, loop brake) and the MCP registration; no permissions |
| Terminal autostart | `runtime/pippa-local-server` | Pi extension for the *terminal* `pi`: starts Pippa's llama-server when provider `pippa-local` is used |
| Web access | `runtime/pippa-web` | The Pi package pi-web-access with Pippa's settings, loaded into Pi as an extension |
| Abilities | `runtime/pippa-skills` | 15 Pi skills (`SKILL.md`), bundled with the app and loaded with `--skill` |

**Conversation path.** Pippa starts `pi --mode rpc` with Pippa's Node and the pinned Pi release (`PippaPiLaunch`,
`PiRPCClient`). Flags: `--extension` for the file tools, the helps, web access and the MCP registration; `--no-context-files` (an
`AGENTS.md` in a user folder could otherwise inject instructions); `--no-approve` (project-local `.pi/` settings are
ignored); `--session-dir` in Pippa's support folder and `--session-id` per conversation; `--system-prompt` with Pippa's
own short prompt; `--tools` with a fixed list (Pi's `read`, `bash`, `edit`, `write`, Pippa's file
tools, pi-web-access's `web_search`, `fetch_content`, `get_search_content` and `mcp__pippa__*`, so the person's
`defaultTools` change nothing); `--no-skills --skill <bundle>/pippa-skills`
(only Pippa's skills, a same-named personal skill would otherwise win); `--provider/--model` from the installer. The
agent directory is the shared `~/.pi/agent`, so the person's own Pi extensions stay active. Pi runs every tool without
asking, as in the terminal ("YOLO"); Pippa adds no approvals and no undo of its own. `fd` and `rg` remain available through `bash` next to Pippa's Node in `Contents/Helpers`
(pinned in `app/Packaging/search-tools.json`), which is first in Pi's `PATH`, so Pi never downloads them.

**Thinking and compaction.** Pi steers both. models.json gives each `pippa-local` model `reasoning`, a `thinkingLevelMap`
and the template switch (`chat-template` with `reasoning_effort` for K2, `qwen-chat-template` for Qwen); Pi's llama-server
no longer starts with `--reasoning off`. K2 thinks at "medium" by default. The official b11503 K2 parser only accepted
the think tag of the requested effort, and after tool results K2 often writes the "high" tag, so with medium the tool
call ended up as thinking text (Pi 1.1.0: medium 0/20, high 30/30). The bundled llama-server carries the think-tag patch;
with it (2026-10-09, read a note and answer, Mac busy with other work): medium 19/20, median 10–16 s; high 9/10,
median 13 s; simple questions about the same (medium 9.5 s, high 8.7 s median). Pi's low/off still map to "high".
Pippa replaces its own earlier default "high" in `settings.json` with the new one; any other level stays. Pippa merges into Pi's `settings.json` a startup level per model
(`modelThinkingLevels`, from the catalog's `thinking`, never over the person's own) and `compaction.modelOverrides`
(`reserveTokens` = min(answer limit, context/4), `keepRecentTokens` = 3/8 of the context), so a 16k model compacts above
12k instead of before every prompt (`PiModelTuning`).

**Pippa's extensions (`runtime/pippa-tools`).** Nothing here decides what Pi may do.

- `pippa-tools.ts` adds `list_folder`, `rename_or_move`, `move_files` (files grouped by target subfolder) and
  `move_to_trash`, shortens the parameter texts of Pi's built-in tools in each request and caps each tool result to
  about a quarter of the context window (`budget.ts`).
- `pippa-assist.ts` keeps a small local model on track. Per answer it stops an identical call that failed twice, an
  identical change that already worked once (no duplicate reminders), and any identical call after four runs; after
  three stops it ends the answer (`loopBrake`). A durable `pippa-loop-stop` entry supplies the reason and actual partial
  file locations to the app; the answer is marked incomplete. The exact bundled search script emits
  `pippa-search-result`; only these verified paths enable local links in the saved answer. `read` on a PDF, Word,
  image, mail or spreadsheet is sent to `mcp__pippa__read_document` (`documentForRead`), because Pi's `read` returns
  raw bytes.
- `pippa-mcp.ts` registers Pippa's MCP server for this Pi session from `PIPPA_MCP_URL` and `PIPPA_MCP_TOKEN` (loopback
  only, new key per app start, removed from `process.env` afterwards).
- The "what happened" line under an answer comes from Pi's own tool events (`PiTurnReceipt`: what was called with which
  arguments, whether it failed), never from model text. Lines for events, reminders and mail drafts come from Pippa's
  MCP server itself (`PippaMCPHost.onWrite`).
- An extension question (`extension_ui_request`) from one of the person's own extensions gets a plain Pippa prompt, so
  Pi never waits forever.

**Web access (`runtime/pippa-web`).** `index.ts` loads the pinned Pi package `pi-web-access` (own lockfile) with
Pippa's settings, written to `<Application Support>/Pippa/pi-web/pi/web-search.json` (`PIPPA_WEB_DIR`): Exa without a
key first, then DuckDuckGo; no automatic switch to OpenAI or another signed-in provider; slim results for a small
model. The person's own `~/.pi` web settings are never read or changed. It also repairs a `queries` value that small
models send as a broken string. Pi runs searches and page reads without a card; the receipt names exactly what went
out ("Online nachgesehen: „…“").

**MCP server (`app/Sources/PippaCore/MCP`).** The app serves MCP over Streamable HTTP on 127.0.0.1. Reading tools: mail,
calendar, reminders, Excel selection, documents (with text recognition). Writing tools: calendar event, reminder, unsent
mail draft. Because the app does the work, macOS asks for permission in Pippa's name.

**Local model.** `LlamaServer` runs the pinned llama.cpp `llama-server` on a fixed loopback port with a key file and
unloads the model when idle (`PIPPA_LLAMA_IDLE_SECONDS`). `ModelSelector.choose` picks the model by memory from the
catalog (`app/Sources/PippaCore/Resources/catalog.json`); see [settings-simplification.md](settings-simplification.md).
Models are downloaded only after consent (resumable, SHA256-verified) or adopted from other apps' folders
(`ExistingModels.swift`). A cold start (server not running) shows measured progress in the thought line and the
pill: the server's resident memory against the size of the weights, capped at 95 % until `/health` is 200, then a
short "almost ready" until the first words (`ColdStart.swift`; on Apple silicon the mmap'd weights show in the
resident size, not in the physical footprint). Opening the pill or conversation starts loading ahead of time
(`PiRPCChat+ColdStart.swift`); `PIPPA_LIVE=1 swift run PippaLive coldprogress` measures it. A new or changed catalog model is pinned with `scripts/pin-model.sh <catalog-key> <hf-repo> [<file>]`
(revision, path, size and SHA256 from the Hugging Face API, written into catalog.json); `build-app.sh` refuses a table model
without a pin.

**Setup (`app/Sources/PippaCore/PiSetup`).** `PiInstaller` copies the bundled Pi payload into Pi's managed layout
(`~/.pi/agent/install/releases/<version>`), puts Node under `~/.local/share/pi-node`, and writes the `pippa-local`
provider into `models.json` together with the terminal extension. `PiLocalServer` plans the llama-server for it. How
existing installs are updated is described in [Updating Pi](updating-pi.md).

**Terminal autostart (`runtime/pippa-local-server`).** Installed as `~/.pi/agent/extensions/pippa-local-server`. Before
a request to provider `pippa-local` (`before_provider_request`, and `session_before_compact`) it checks `/health` and,
if nothing answers, starts llama-server through a detached supervisor with the same settings and idle time as the app
(config `pippa-local-server.json` in Pippa's support folder). One lock file (`llama-server-pi.lock`) keeps app and
terminal from ever running two servers.

**Abilities (`runtime/pippa-skills`).** One Pi skill per folder (`SKILL.md`). The 14 action skills use
`disable-model-invocation: true` and cost no prompt space. `dateien-finden` is advertised automatically: Pi reads its
instructions and invokes its Spotlight script once, searching content (including an optional year) in Documents,
Desktop, Downloads, iCloud Drive and CloudStorage. It uses the existing macOS index, so unloaded cloud files and
unindexed content can be missing; an empty result never proves absence. Pi loads them with `--skill`; a button sends `/skill:<name> <message>` (`PiSkillTurn`) and Pi
puts the instructions in front. Swift reads the headers only for buttons and suggestions (`PippaSkill`).
`PIPPA_SKILLS_DIR` overrides the folder for development. Invoices (`rechnung-auslesen`: Pi writes `Rechnungen.csv`),
deadlines (`fristen-erkennen`: Pi adds them with `calendar_add`) and "Check online" on a letter (`online-pruefen`) are
Pi conversations; the code's deadline patterns still fill the deadline cards without a model.

**Own online service.** Switching it on in Settings is the consent. models.json gets `pippa-online` with the service's
own address and `apiKey: "$PIPPA_ONLINE_KEY"`; Pippa reads the key from the Keychain and puts it only into its own Pi's
environment (`PiOnlineProvider`). Pi in the terminal has no key and stops before any request.

**Apple's on-device model.** `AppleQuickModel` for short decisions: document suggestions, the letter's first line, and
classifying unclear documents while tidying (`TidyClassifier`). Measured on the Mac mini M6 (`PippaLive tidy-speed`, 25
unclear files): Apple's model p50 2.0 s per file, all answered; the fallback when it is missing, a direct structured call on
the local server (`LocalModelJSON`) with K2 Horizon 7B, p50 3.2 s per file (it was ~26 s with the old 12B model), so the
fallback stays.

## Requirements

Apple silicon Mac, macOS 15 or later, Command Line Tools with Swift 6 (`xcode-select --install`). Xcode is not needed,
which is why checks run as an executable (`PippaChecks`) instead of XCTest. Node 22.19 or later for the runtime tests.
The app ships its own pinned Node (`app/Packaging/node-release.json`) and Pi release (`app/Packaging/pi-release`); users
need neither Terminal nor npm.

## Repository layout

| Path | Contents |
|---|---|
| `app/Sources/Pippa`, `PippaCore`, `PiRPC` | App, core, Pi client (above) |
| `app/Sources/PippaChecks` | Checks without a model: `swift run --package-path app PippaChecks` |
| `app/Sources/PippaLive` | Flows against a real model, only with `PIPPA_LIVE=1` |
| `app/Sources/PippaUpdateProbe` | Probe for a real Sparkle update through a loopback feed |
| `app/Sources/PiSetupSpike`, `PiRPCR2Spike`, `PiRPCR3Spike` | Developer probes: installer, shown items and online lookup, calendar/reminder/mail draft, own online service. Driven by `scripts/pi-rpc-spike.sh` |
| `app/Fixtures` | Data files used by `PippaLive`, the probes and `PippaChecks` (suggestion cases, answer fixtures, decision gold labels) |
| `app/Packaging` | `Info.plist` and its translations, entitlements, icon generator, pinned llama.cpp, Node and Pi releases |
| `runtime/` | Pippa's Pi extensions, web access, terminal autostart, abilities (above) |
| `scripts/` | Build, verify, DMG, release and check scripts (below) |
| `site/` | Static website, no build step |
| `docs/` | This guide, [Updating Pi](updating-pi.md), [settings](settings-simplification.md) |

## Build, verify, package

```sh
scripts/build-app.sh      # dist/Pippa.app (arm64); ad-hoc signed without PIPPA_SIGN_IDENTITY
scripts/verify-app.sh     # signature, entitlements, helpers, Pi payload, permission texts, runtime probe
scripts/make-dmg.sh       # dist/Pippa.dmg
```

`build-app.sh` runs a release `swift build`, fills `Contents/Info.plist` from `app/Packaging/Info.plist` (version from
`Pippa.version` in `PippaCore.swift`), copies the SwiftPM resources and the Info.plist translations
(`Contents/Resources/<language>.lproj`), draws the icon (`app/Packaging/make-icon.swift`), adds `llama-server`
(static, no dylibs), built with cmake from the pinned llama.cpp source tarball plus the patches in
`app/Packaging/llama-patches` (`llama-release.json`, SHA256-verified, cached in `~/Library/Caches/pippa-build`; cmake from
PATH or `PIPPA_CMAKE`), bundles Node and web access (`bundle-web.sh`: pi-web-access from its lockfile), the Pi install
payload (`bundle-pi-payload.sh`), the abilities and Pippa's extensions, removes Sparkle's XPC services and signs
everything from the inside out. Of `runtime/pippa-tools` only the sources Pi loads are copied (`pippa-tools.ts`,
`pippa-assist.ts`, `pippa-mcp.ts` and their imports), without tests.

| Variable | Effect |
|---|---|
| `PIPPA_SIGN_IDENTITY` | `Developer ID Application: Name (TEAMID)`; without it signing is ad hoc |
| `PIPPA_NOTARY_PROFILE` | Keychain profile for `xcrun notarytool`; without it `make-dmg.sh` does not notarize |
| `PIPPA_SKIP_BUILD=1` | Package the existing release build |
| `PIPPA_CACHE` | Download cache (default `~/Library/Caches/pippa-build`) |
| `PIPPA_DMG_LAYOUT=0` | Skip the Finder window layout in the DMG (for example over SSH) |
| `PIPPA_REQUIRE_DISTRIBUTION=1` | Developer ID, notarization and Gatekeeper become mandatory (`release.sh` sets it) |

`verify-app.sh` takes `--verify-runtime` (the default) or `--no-runtime`. The runtime probe reads resources, abilities
and helpers from the unmodified signed bundle and loads no user data.

**Signing and entitlements.** Pippa runs without the App Sandbox because a sandboxed app cannot set up and start Pi in
the home folder. `Pippa.entitlements` holds only the Hardened Runtime rights it needs (Apple Events, and Calendars for
EventKit, which also covers Reminders). `Node.entitlements` adds JIT and turns library validation off, because the
terminal Pi loads add-ons the person installs. `llama-server` and esbuild carry no entitlements. Desktop, Documents and
Downloads are protected by TCC prompts (texts in `Info.plist`). With a Developer ID all dylibs are signed with one team
ID, so library validation holds; ad-hoc builds have no team ID and run without Hardened Runtime. `verify-app.sh` asserts
all of this.

**Distributing.** An ad-hoc build runs on your own Mac. Elsewhere, macOS 15 and later requires *System Settings →
Privacy & Security → Open Anyway*. To avoid that you need an Apple Developer ID Application certificate and a notary
profile (`xcrun notarytool store-credentials …`); `make-dmg.sh` then signs the DMG, submits it, waits and staples the
ticket.

## Checks

```sh
swift build --package-path app                                          # all targets
swift run --package-path app PippaChecks                                # native checks, no model
python3 scripts/check-strings.py                                        # every UI text in en and de
python3 scripts/check-default-models.py                                 # every model in ModelSelector's table is pinned
node --experimental-strip-types --test runtime/pippa-tools/*.test.mjs   # Pippa's Pi extensions
node --test runtime/pippa-auth/*.test.mjs                               # ChatGPT sign-in helper (no network)
(cd runtime/pippa-web && npm ci --ignore-scripts && npm test)           # web access (loads pi-web-access in the real Pi)
node --test runtime/pippa-local-server/test/autostart.test.mjs          # terminal autostart with a fake llama-server
node scripts/check-site.cjs                                             # website drag behaviour
PYTHONDONTWRITEBYTECODE=1 python3 scripts/tests/test_release.py         # appcast and release metadata
scripts/check-downloads.sh                                              # downloader fixtures; build PippaChecks first
```

`real-pi.test.mjs` (local server) runs against a real Pi and is skipped without one; the web access test uses the Pi
from runtime/pippa-web's own dev dependencies.
Build a payload with `scripts/bundle-pi-payload.sh .build/pi-payload --with-node` and pass
`PIPPA_PI_PAYLOAD=$PWD/.build/pi-payload` (or `PIPPA_PI_CLI` plus `PIPPA_PI_NODE`). `scripts/bump-pi.sh` runs all of
them against a new Pi release.

Some `PippaChecks` groups need extra input and are switched on by environment variables: `PIPPA_SETUP_CHECKS=1` and
`PIPPA_MCP_CHECKS=1` (installer and MCP server with a real payload from `PIPPA_PI_PAYLOAD`, optionally
`PIPPA_PI_PAYLOAD_PREVIOUS` for the old-to-new install), `PIPPA_R6_CHECKS`, `PIPPA_R7_CHECKS`, `PIPPA_R7B_CHECKS`,
`PIPPA_R10_CHECKS`, `PIPPA_W4A_CHECKS`, `PIPPA_THOUGHT_CHECKS`, `PIPPA_DOWNLOAD_CHECKS` and `PIPPA_LEGACY_CHECKS`.
`PIPPA_PERF=1` enables the slow speed checks. `PIPPA_OCR_FAST=1` makes the searchable text layer use the fast
recognizer (CI sets it).

**CI.** `.github/workflows/ci.yml` runs on pushes to `claude/**` branches (not for documentation-only changes) and by
hand, on a `macos-26` runner: string check, `swift build`, `PippaChecks`, the web access tests and the tests of Pippa's Pi extensions.
Started by hand with *app* ticked it also builds an ad-hoc signed `Pippa.app` and uploads it as an artifact.
`.github/workflows/pages.yml` publishes `site/` to GitHub Pages.

## Working with a real model

```sh
scripts/live-test.sh                # smallest catalog model, all flows with timings and checks
scripts/live-test.sh auto           # model chosen by memory, as in the app
scripts/live-test.sh qwen3.5-9b-q4  # any catalog key
```

The script fetches the pinned `llama-server` and the model into `~/Library/Caches/pippa-live` (`PIPPA_LIVE_DIR`),
generates a German test corpus, runs the flows and leaves no `llama-server` behind. It needs network access to GitHub
and Hugging Face. Single steps run through `PIPPA_LIVE=1 swift run PippaLive <step>` (see
`app/Sources/PippaLive/main.swift`). Developer switches in the core: `PIPPA_LLAMA_SERVER`, `PIPPA_MODELS_DIR`,
`PIPPA_MODEL_FILE` (any GGUF, unverified) and `PIPPA_MODEL_TRACE`.

The suggestion and answer runners read their data from `app/Fixtures`. The larger document corpus is generated, not
committed: `swift scripts/quality/make-ctxsug-corpus.swift` writes `.build/quality/ctxsug-corpus`.

**Conversations through the real Pi.** `scripts/pi-rpc-spike.sh` builds a fake HOME under `.build/` with the pinned Pi
and drives the probes against a local llama-server (`setup`, `llama-start`, `app`, `r2`, `r3`, `r7`, `r10`; run it
without arguments for usage). `scripts/pi-setup-ui.sh` records the setup UI and end-to-end runs in the real Pippa
window. Both only read the model files in `~/Library/Caches/pippa-live` and never touch the real `~/.pi`.
`scripts/pi-rpc-smoke.mjs` is the headless Pi RPC smoke test that `bump-pi.sh` uses.

**Native UI fixtures.** The debug build renders scripted scenarios without a model:
`PIPPA_DEMO=1 PIPPA_SNAPSHOT=<fresh dir> PIPPA_SNAPSHOT_ONLY=<scenario> app/.build/debug/Pippa` writes screenshots and a
text report and quits (for example `settings`, `scans`, `calendar`, `ctxsug`, `thoughtline`; see
`app/Sources/Pippa/App/DevSnapshot.swift`). Vary with `PIPPA_SNAPSHOT_WIDTH`, `PIPPA_APPEARANCE=light|dark` and
`PIPPA_REDUCE_MOTION=1`. The bare debug executable shows English strings; run it from a bundle with
`app/Packaging/Info.plist` to see German. These fixtures check state and layout, not model quality.

**Clicking through the real app.** Pippa is a menu bar app (accessory), which UI automation tools that only list
regular apps cannot reach. `PIPPA_REGULAR_APP=1` makes it a regular app with a Dock icon. For a clean first start
without touching your own data, point Foundation at a fake home (`HOME` alone is ignored):
`open --env PIPPA_REGULAR_APP=1 --env PIPPA_NO_MOVE=1 --env CFFIXED_USER_HOME=$PWD/.build/fakehome --env HOME=$PWD/.build/fakehome dist/Pippa.app`.
`PIPPA_NO_MOVE=1` skips the one question a first launch outside Applications asks (move to Applications, `AppMover`);
leave it out to try that question from the disk image. Debug builds ask only with `PIPPA_TRY_MOVE=1`.

**The first minutes.** While setup still runs or the model loads, plain questions get a short answer from Apple
Intelligence (macOS 26 and later, when it is on); anything that needs files, Mail, Calendar, the web or a change waits in
the conversation and goes to Pi once it is ready, together with the quick answers in between
(`PippaCore/StartupBridge.swift`, `StartupBridgeChat`). Without Apple Intelligence every message waits. Tidying, PDFs
from photos, text recognition and calendar questions never wait: they do not need the model.

## Localization

English is the development language and the fallback; German is a full translation, chosen by the system language.
Only text a person sees is translated. Document analysis stays German by design: patterns and keywords for German
letters, deadlines, amounts and IBANs, German date and number formats, CSV for German Excel, and test fixtures with
German document text.

**Format.** Plain `.strings` files, not `.xcstrings`, because the build uses only the Command Line Tools.
`Package.swift` sets `defaultLocalization: "en"`. `<language>.lproj` folders inside a `.process` resource directory
become localized resources in `Bundle.module` and must not contain subfolders.

| Module | Call | Files |
|---|---|---|
| `PippaCore` | `L("…", table: "Core")` | `app/Sources/PippaCore/Resources/{en,de}.lproj/<Table>.strings` |
| `Pippa` | `T("…", table: "Views")` | `app/Sources/Pippa/Localization/{en,de}.lproj/<Table>.strings` |
| App bundle | system | `app/Packaging/Localization/{en,de}.lproj/{InfoPlist,ServicesMenu}.strings`, copied by `build-app.sh` |

There is one table per area (for example `Core`, `Analysis`, `Letter`, `Lookup`, `Sheet`, `Calendar` in PippaCore;
`App`, `Views`, `Settings`, `Line`, `SheetUI`, `ThoughtUI` in the app), so parallel work rarely touches the same file.

**Rules.**

- The key is the English text: `L("Nothing was changed.", table: "Core")`. A missing key shows the English key.
- Keys are plain string literals without interpolation; values go in as arguments: `T("Moved %lld files to %@", table: "Views", count, folderName)`. Use `%@` for text, `%lld` for `Int`, `%d` only for `Int32`. With no arguments nothing is formatted.
- If German needs another word order, use positions in the German value: `"%2$@: %1$lld Dateien verschoben"`.
- Every key goes into both `en.lproj` and `de.lproj` of its table, appended at the end, one per line.
- In SwiftUI pass a `String`: `Text(T("Open", table: "Views"))`, also for `Button`, `Label`, `.help` and `.accessibilityLabel`. Do not rely on `LocalizedStringKey` lookups.
- In the `Pippa` module a generic type parameter must not be called `T`; it would hide the function.
- No `.stringsdict`: write sentences that work for any number, or use separate keys for one and many.
- Dates and numbers shown to the person use `Locale.current`; formats inside documents stay German.
- Tone: English is calm and plain (no "model", "token", "prompt", "agent"); German addresses the person as "du".

`python3 scripts/check-strings.py` (also in CI; `--verbose` for details) checks that every literal key is in `en` and
`de` of the right table, that `.strings` files parse without duplicates, that both languages have the same keys and
placeholders, and that the packaging strings match `Info.plist`. `PippaChecks` checks the English fallback and that the
resource bundle carries both languages.

## Releasing

```sh
PIPPA_SIGN_IDENTITY='Developer ID Application: … (TEAMID)' PIPPA_NOTARY_PROFILE=<profile> scripts/release.sh [tag]
```

Everything is local: no push, tag or GitHub release. The script requires a clean commit and the existing Sparkle EdDSA
key in the Keychain (account `ed25519`, or `PIPPA_SPARKLE_ACCOUNT`). It checks the public key against `SUPublicEDKey` in
`Info.plist`, runs `build-app.sh`, `make-dmg.sh` and `verify-app.sh` with `PIPPA_REQUIRE_DISTRIBUTION=1`, and writes
`dist/releases/<tag>/` (default `v<version>-<build>`) with the versioned DMG, a stable-name `Pippa.dmg`, `appcast.xml`
(`write-appcast.py`), `SHA256SUMS` and `commit.txt`. Publishing is a separate, deliberate step: the DMG and `appcast.xml`
go into the same GitHub release, because the in-app update feed is `releases/latest/download/appcast.xml`.

**Updates.** Sparkle 2.10.0 is pinned exactly. Pippa checks daily, downloads in the background and installs on quit or
after 20 minutes without input, never during work, an open preview or a dialog. To test a real update from an installed
build without touching it:

```sh
PIPPA_PROBE_AUTOMATIC=1 PIPPA_SIGN_IDENTITY=… scripts/prepare-update-probe.sh /Applications/Pippa.app dist/releases/<tag>
python3 -m http.server 18765 --bind 127.0.0.1 --directory dist/update-probe/feed
open -n "dist/update-probe/Pippa Updateprobe.app"
```

The result is in `dist/update-probe/events.log` (`UPDATE INSTALLED`). The probe works on a copy of the host and uses its
own Sparkle framework, but Sparkle records its check state in the host's defaults domain, so back up that preferences
file first.

**Pi.** Move to a new Pi release with `scripts/bump-pi.sh <version>`; see [Updating Pi](updating-pi.md).

## Where Pippa keeps things

| What | Where |
|---|---|
| Journal, task log (`tasklog.sqlite`), conversations, Pi sessions, web settings (`pi-web`), models, settings, `install-state.json` | `~/Library/Application Support/Pippa/` |
| Preferences | `~/Library/Preferences/io.github.tschnorpfeil.pippa.plist` |
| Log `pippa.log` (version and events, no file contents; `PIPPA_LOG_DIR` overrides) | `~/Library/Logs/Pippa/` |
| Pi release, settings, `models.json`, the person's Pi extensions | `~/.pi/agent` |
| Node for the terminal `pi` | `~/.local/share/pi-node` |
| Build cache (developers) | `~/Library/Caches/pippa-build` |

Older versions ran in the App Sandbox and kept everything in `~/Library/Containers/io.github.tschnorpfeil.pippa`. On the
first start without the sandbox, Pippa offers once to copy conversations, settings and journal from there (APFS clone,
into an empty folder; the container is never changed).

**Network.** Only these go out: model download from Hugging Face (after consent), Sparkle's update check, web search and
page reads (each request approved on a card, personal details removed in code first, the query never logged), and the
optional online model the person switches on (Pi's own provider `pippa-online`, key only in the environment of Pippa's Pi). Files,
conversations, journal and the model stay on the Mac.

**Uninstall.** Quit Pippa, move `Pippa.app` to the Trash, then remove `~/Library/Application Support/Pippa`, the
preferences file above, `~/Library/Caches/io.github.tschnorpfeil.pippa`, `~/Library/Logs/Pippa` and, from older
versions, `~/Library/Containers/io.github.tschnorpfeil.pippa`.

## Website

`site/` is static HTML with self-hosted fonts and no analytics.

```sh
python3 -m http.server 8088 --directory site
node scripts/check-site.cjs           # drag behaviour: attraction, 36 px cap, release, reduced motion, edge grabs
node scripts/check-site-launch.cjs    # publication gate: required files; fails while the legal pages are unfinished
```

Attraction and drop logic are in `site/pippaDrag.js`; rendering and the demo flow are in `site/index.html`. Text
changes on the German page must be carried over to `site/en/index.html`. Opening `http://localhost:8088/?perf=1` adds a
local timing diagnostic for the drag; it transmits nothing.
