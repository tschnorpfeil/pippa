# Developing Pippa

How Pippa is put together, how to build, check and release it, and where it keeps things. The [README](../README.md)
covers what Pippa does; [What Pippa can do](what-pippa-can-do.md), [Pippa's local AI](models.md) and
[Privacy and permissions](privacy-and-permissions.md) give users the details. [Updating Pi](updating-pi.md) covers moving
to a new Pi release. The plan is [Pippa next](pippa-next-architecture.md), where things stand is in the
[roadmap](ROADMAP.md), and older plans and measurements are in [archive/](archive/).

## Architecture

Pi is the harness, Pippa is the window and the hands. [Pi](https://github.com/earendil-works/pi) does the reasoning,
tool choice, sessions, compaction, skills and memory. Pippa is a regular native Mac app: Dock icon, app menus, one chat window, a menu bar shortcut and an optional pill
with a conversation sidebar, a first-run card and settings. Mac access (Mail, Calendar, Reminders, Photos, documents,
PDF building) is one MCP server inside the app process, so macOS asks for "Pippa" and the permission belongs to the app.
[oMLX](https://github.com/jundot/omlx) (MLX) runs the local model on a loopback-only server; it and the model are
downloaded at setup, not bundled ([decision](omlx-switch.md)).

No code decides what the person means before Pi does, and no code rewrites Pi's answer afterwards. Tools return facts,
not raw data: sorted, with full timestamps, at most 20 entries, documents read to text.

```
Pippa.app (Swift, SwiftUI)
 ├─ oMLX (Python runtime)           local model on 127.0.0.1, started by the app, unloads the model when idle
 ├─ pi --mode rpc                   the agent, one Pi session per Pippa conversation
 │   ├─ --extension pippa-tools     file tools, memory, small-model helps (runtime/pippa-tools)
 │   ├─ --extension pippa-web       web search and pages: pi-web-access (runtime/pippa-web)
 │   └─ pippa-mcp.ts ─────────────► Pippa's MCP server inside the app (127.0.0.1, key per Pi process)
```

**Tools.** The model sees a fixed list (`PippaPiLaunch.tools`, passed with `--tools`):

| Owner | Tools |
|---|---|
| Pi | `read` (documents come back as text in the same call), `bash`, `write` |
| pi-web-access (`runtime/pippa-web`) | `web_search`, `fetch_content` |
| `runtime/pippa-tools/pippa-tools.ts` | `search_files` (Spotlight), `list_folder`, `move_files` (`to: "trash"` moves to the Trash) |
| `runtime/pippa-tools/pippa-memory.ts` | `remember` (facts in `memory.md`, at most 30 lines) |
| App MCP server (`mcp__pippa__*`) | `calendar_read`, `reminders_read`, `mail_search`, `mail_read`, `photos_search`, `front_read`, `read_document`, `calendar_add`, `reminder_add`, `mail_draft`, `prepare_files` |

**Conversation path.** `PiSession` (app) starts the pinned Pi with Pippa's Node through `PippaPiLaunch` and
`PiRPCClient` (`app/Sources/PiRPC`). Flags: `--no-extensions` plus explicit `--extension`s, `--no-context-files` (an
`AGENTS.md` in a user folder could inject instructions), `--no-approve` (project-local `.pi/` settings are ignored),
`--session-dir` in Pippa's support folder and `--session-id` per conversation, `--system-prompt` with Pippa's short
prompt (under 300 tokens), `--tools` with the list above, `--no-skills --skill <bundle>/pippa-skills`, and
`--provider/--model` from the installer or the online route. The agent directory is the shared `~/.pi/agent`, but the
person's extensions, context files and MCP servers do not join Pippa's sessions. Before the first question, the client
checks that every native tool is registered (`PiNativeReadiness`).

**Cards and receipts.** Pi's `tool_execution_start` and `tool_execution_end` events say what ran. `PiTurnReceipt`
turns them into one line per call that changed something, never from model text: `move_files` to the Trash is a
trash line, any other destination a move. Cards for mail, events, reminders, photos and prepared PDFs come from the
in-process MCP server's own read and write notes (`PippaMCPService`), so no `structuredContent` round trip is needed.

**Pippa's extensions (`runtime/pippa-tools`).**

- `pippa-tools.ts`: `search_files` (`search.mjs`; content, file name and folder search in the home folder and iCloud
  Drive, newest first; an empty result never proves absence), `list_folder` (`list-folder.ts`), `move_files`
  (`files.ts`; never overwrites; the Trash through `/usr/bin/trash`). It also shortens the parameter texts of Pi's
  built-in tools and caps each result to the context window (`budget.ts`), and wraps `bash` in a macOS sandbox
  (`shell.ts`).
- `pippa-assist.ts` keeps a small local model on track: it stops identical repeated calls, sends documents that Pi's
  `read` would return as bytes to `read_document` (`document.ts`), and copies a file to `Backups` before it is changed.
- `pippa-memory.ts`: "what Pippa knows about you", one fact per line in `memory.md` (`PIPPA_MEMORY_FILE`), added to the
  system prompt as its own section. `remember` refuses account, card, ID, tax and phone numbers and passwords.
- `pippa-mcp.ts` registers the app's MCP server for this Pi session with `pi.registerMcpServer`, from `PIPPA_MCP_URL`
  and `PIPPA_MCP_TOKEN` (loopback only, a new key per Pi process, removed from `process.env` afterwards). Nothing is
  written to `~/.pi/agent/mcp.json`, so the terminal Pi never sees the server.

**MCP server (`app/Sources/PippaCore/MCP`).** Streamable HTTP on 127.0.0.1 inside the app (`PippaMCPServer`). Readers
in `PippaMCPTools.swift` and `PippaMCPTurn.swift` (`read_document`, with text recognition for scans), writers in
`PippaMCPWrite.swift` (event, reminder, unsent Mail draft; only during an answer), and `prepare_files`
(`PippaMCPFilePreparation.swift`: ordered photos and PDFs into one verified PDF, optionally aimed at a size limit).

**Web access (`runtime/pippa-web`).** `index.ts` loads the pinned `pi-web-access` with Pippa's settings in
`<Application Support>/Pippa/pi-web` (`PIPPA_WEB_DIR`): DuckDuckGo only, no switch to another signed-in provider. The
person's own `~/.pi` web settings are never read or changed. The first search of an answer asks the person.

**Local model.** One model, Ornith 1.5 9B (MLX 4-bit), the only entry in
`app/Sources/PippaCore/Resources/catalog.json`. `ModelSelector` (`Models.swift`) only decides whether it fits: Apple
silicon with 16 GB or more, 32K context from 24 GB, 16K on 16 GB. `OMLXServer` runs oMLX from the Python runtime
(`MLXRuntime`, manifest `Resources/mlx-runtime.json`, built by `scripts/build-mlx-runtime.sh`) on a fixed loopback port
with a key file; oMLX unloads the model by itself after an idle timeout. Runtime and model are downloaded only after
consent (resumable, SHA256-verified), or the model is cloned from oMLX's or Hugging Face's folders
(`ExistingModels.swift`). A catalog model is pinned with `scripts/pin-model.sh <catalog-key> <hf-repo> [<file>]`;
`build-app.sh` refuses an unpinned model (`scripts/check-default-models.py`). See [Pippa's local AI](models.md).

**Setup (`app/Sources/PippaCore/PiSetup`).** `PiInstaller` copies the bundled Pi payload into Pi's managed layout
(`~/.pi/agent/install/releases/<version>`), puts Node under `~/.local/share/pi-node` and writes the `pippa-local`
provider into `models.json`. `PiLocalServer` plans the oMLX server for it, `PiModelTuning` sets thinking and
compaction per model in Pi's `settings.json`. See [Updating Pi](updating-pi.md).

**Online AI.** `PiProviderSettings` presents the bundled Pi’s provider catalog and authentication methods through
`PiProviderClient` and `runtime/pippa-auth/pi-providers.mjs`. The helper uses public `ModelRuntime` APIs; interactive
prompts are correlated JSONL over stdin/stdout. Credentials stay in Pi’s credential store and routing persists only
provider/model metadata (`InferenceSettings.piModel`). `PiSession` passes the selected provider/model directly to Pi.
Provider setup and online chat do not require a local model download. The model must be explicitly selected; catalog order is not treated as a recommended default. Browser, device-code, API-key, optional text,
secret, and select prompts use the same bridge. Pi owns credential refresh and provider-specific behavior.

Older `subscriptionModel` settings map to Pi’s `openai` provider. Existing Keychain connections retain their old
`pippa-online` route until the person chooses a Pi provider; their keys are not silently migrated. The compatibility
form appears only for existing connections. Online activation always requires an explicit **Use [provider]** action.

**Terminal autostart (`runtime/pippa-local-server`).** Installed as `~/.pi/agent/extensions/pippa-local-server`. When
the terminal `pi` uses provider `pippa-local` and nothing answers, it starts the oMLX server through a detached
supervisor from the app's launch file (`pippa-local-server.json`). One lock file (`local-server.lock`) keeps app and
terminal from running two.

**Skills (`runtime/pippa-skills`).** One Pi skill per folder (`SKILL.md`), in German, bundled and loaded with
`--skill`. `PIPPA_SKILLS_DIR` overrides the folder for development.

## Repository layout

| Path | Contents |
|---|---|
| `app/Sources/Pippa` | The app: Dock/app menus, menu bar shortcut, optional pill, chat window, settings, first-run card, hotkey, Sparkle updates, `PiSession`, `Pippa --ask` |
| `app/Sources/PippaCore` | Model catalog and download, runtime download, oMLX server, Pi installer, MCP server, Mail/Calendar/Reminders/Photos readers and writers, PDF building, journal |
| `app/Sources/PiRPC` | Starts Pi with Pippa's flags, speaks JSON lines over stdin and stdout, turns tool events into receipts |
| `app/Sources/PippaChecks` | Checks without a model |
| `app/Sources/PiRPCChecks` | RPC lifecycle and receipts against a fake Pi process |
| `app/Sources/PippaUpdateProbe` | Probe for a real Sparkle update through a loopback feed |
| `app/Packaging` | `Info.plist` and its translations, entitlements, icon generator, pinned Node, Pi, fd and rg; `mlx-runtime/` (lock file for the runtime builder) |
| `runtime/` | Pi extensions (`pippa-tools`), web access (`pippa-web`), provider discovery/sign-in bridge (`pippa-auth`), terminal autostart (`pippa-local-server`), skills (`pippa-skills`) |
| `scripts/` | Build, verify, DMG, release and check scripts |
| `site/` | Static website, German and English, no build step |
| `docs/` | This guide, user docs, [plan](pippa-next-architecture.md), [tasks](pippa-next-tasks.md), [roadmap](ROADMAP.md), [archive](archive/) |

## Requirements

Apple silicon Mac, macOS 26.2 or later, Command Line Tools with Swift 6 (`xcode-select --install`). Xcode is not needed, which is why checks run as executables instead of XCTest. Node 22.19 or later for the
runtime tests. The app ships its own pinned Node (`app/Packaging/node-release.json`) and Pi release
(`app/Packaging/pi-release`); users need neither Terminal nor npm.

## Build, verify, package

```sh
scripts/build-app.sh      # dist/Pippa.app (arm64); ad-hoc signed without PIPPA_SIGN_IDENTITY
scripts/verify-app.sh     # signature, entitlements, helpers, Pi payload, permission texts, runtime probe
scripts/make-dmg.sh       # dist/Pippa.dmg
```

`build-app.sh` runs a release `swift build`, fills `Contents/Info.plist` from `app/Packaging/Info.plist` (version from
`Pippa.version` in `PippaCore.swift`), copies the SwiftPM resources and the Info.plist translations, draws the icon
(`app/Packaging/make-icon.swift`), adds fd and rg (`search-tools.json`, SHA256-verified, cached in
`~/Library/Caches/pippa-build`), bundles Node and web access (`bundle-web.sh`), the Pi install payload
(`bundle-pi-payload.sh`), the skills, the sign-in helper and the extension sources Pi loads from
`runtime/pippa-tools` (without tests), and signs everything from the inside out. The oMLX runtime and the model are
not in the app; `scripts/build-mlx-runtime.sh` builds the runtime archive that setup downloads.

| Variable | Effect |
|---|---|
| `PIPPA_SIGN_IDENTITY` | `Developer ID Application: Name (TEAMID)`; without it signing is ad hoc |
| `PIPPA_NOTARY_PROFILE` | Keychain profile for `xcrun notarytool`; without it `make-dmg.sh` does not notarize |
| `PIPPA_SKIP_BUILD=1` | Package the existing release build |
| `PIPPA_CACHE` | Download cache (default `~/Library/Caches/pippa-build`) |
| `PIPPA_BUILD_JOBS` | Parallel compile jobs (default: cores minus two) |
| `PIPPA_ALLOW_UNPINNED=1` | Local test builds only: allow an unpinned default model |
| `PIPPA_DMG_LAYOUT` | Finder window layout in the DMG: unset only when the Terminal may already control Finder, `1` try and let macOS ask, `0` skip |
| `PIPPA_REQUIRE_DISTRIBUTION=1` | Developer ID, notarization and Gatekeeper become mandatory (`release.sh` sets it) |

`verify-app.sh` takes `--verify-runtime` (the default) or `--no-runtime`. The runtime probe runs
`Pippa --verify-runtime` in the unmodified signed bundle (`BundleVerification.swift`) and loads no user data.

**Signing and entitlements.** Pippa runs without the App Sandbox because a sandboxed app cannot set up and start Pi in
the home folder. `Pippa.entitlements` holds only Hardened Runtime rights; `Node.entitlements` adds JIT and turns
library validation off, because the terminal Pi loads add-ons the person installs. fd, rg and esbuild
carry no entitlements. With a Developer ID all code is signed with one team ID; ad-hoc builds run without Hardened
Runtime. `verify-app.sh` asserts all of this. An ad-hoc build runs on your own Mac; elsewhere macOS asks for *System
Settings → Privacy & Security → Open Anyway*. With a Developer ID and a notary profile (`xcrun notarytool
store-credentials …`), `make-dmg.sh` signs, notarizes and staples the DMG.

## Checks

```sh
swift build --package-path app                                          # all targets
swift run --package-path app PippaChecks                                # native checks, no model
swift run --package-path app PiRPCChecks                                # RPC lifecycle against a fake Pi process
python3 scripts/check-strings.py                                        # every UI text in en and de
python3 scripts/check-default-models.py                                 # the catalog model is pinned
python3 -m unittest discover -s scripts/tests -p 'test_*.py'            # release and fixture scripts
node --experimental-strip-types --test $(ls runtime/pippa-tools/*.test.mjs | grep -v /real-pi-)  # extensions, no Pi needed
node --test runtime/pippa-auth/*.test.mjs                               # Provider/login bridge (no network)
node --experimental-strip-types --test runtime/pippa-local-server/test/autostart.test.mjs   # terminal autostart, fake server
scripts/check-downloads.sh                                              # downloader fixtures; build PippaChecks first
app/.build/debug/Pippa --check-approvals                                # in-app questions (Approvals), no window
node scripts/check-site.cjs                                             # website content and behavior
```

**Against the real Pi.** `runtime/pippa-tools/real-pi-*.test.mjs`, `runtime/pippa-local-server/test/real-pi.test.mjs`
and the Pi-dependent parts of `shell.test.mjs` load the pinned Pi and are skipped without one. Point them at it with
`PIPPA_PI_CLI`:

```sh
mkdir -p .build/pi-release && cp app/Packaging/pi-release/package*.json .build/pi-release/
(cd .build/pi-release && npm ci --ignore-scripts)
export PIPPA_PI_CLI="$PWD/.build/pi-release/node_modules/@earendil-works/pi-coding-agent/dist/bundle/cli.js"
node --experimental-strip-types --test runtime/pippa-tools/*.test.mjs runtime/pippa-local-server/test/*.test.mjs
(cd runtime/pippa-web && npm ci --ignore-scripts && npm test)           # web access in the real Pi
```

`scripts/bump-pi.sh <version>` runs these, `scripts/pi-rpc-smoke.mjs` and the installer checks against a new Pi release.

`PippaChecks` runs everything by default; `PIPPA_<AREA>_CHECKS=1` (see `app/Sources/PippaChecks/main.swift`) runs one
area only. Some areas need extra input: `PIPPA_SETUP_CHECKS=1` and `PIPPA_MCP_CHECKS=1` use a real payload from
`PIPPA_PI_PAYLOAD` (build one with `scripts/bundle-pi-payload.sh .build/pi-payload --with-node`). `PIPPA_PERF=1`
enables the slow speed checks; `PIPPA_OCR_FAST=1` uses the fast text recognizer.

**CI.** `.github/workflows/ci.yml` is the fast gate on pull requests and pushes to `main` (not for documentation-only
changes): string check, script tests, `swift build`, `PippaChecks`, `PiRPCChecks` and the runtime tests that don't need
the real Pi. `.github/workflows/heavy.yml` runs the real-Pi tests, the web access tests
and, if asked, an ad-hoc `Pippa.app` artifact; it runs only by hand (`workflow_dispatch`) and on release tags (`v*`).
`.github/workflows/pages.yml` checks `site/` and publishes it to GitHub Pages from `main`.

## Working with a real model

**Headless.** `Pippa --ask "…"` asks one question through the same `PiSession` path as the window and prints each tool
call, its result, the cards and the answer, then quits (`HeadlessAsk.swift`). It uses the person's real setup, Pi and
model, so run it with the AI already set up:

```sh
swift build --package-path app --product Pippa
app/.build/debug/Pippa --ask "What's on my calendar this week?"
dist/Pippa.app/Contents/MacOS/Pippa --ask "Find my lease and tell me the notice period"
```

`Pippa --make-pdf <files…>` runs the **One PDF** button's job (`prepare_files`, no model) and prints the result.

A debug build without a bundle loads the extensions and web access from this checkout's `runtime/`. macOS asks for
Calendar, Mail or Photos in the name of the process that runs it; a re-signed development copy asks again.

**Developer switches.** `PIPPA_PI_HOME` (a fake home for Pi's install), `PIPPA_PI_PAYLOAD`, `PIPPA_PI_MODEL` (a model
id from `models.json` instead of the first), `PIPPA_PI_EXTENSIONS`, `PIPPA_PI_WEB`, `PIPPA_PI_MCP`, `PIPPA_SKILLS_DIR`,
`PIPPA_MLX_RUNTIME_DIR` (an unpacked oMLX runtime, used as it is), `PIPPA_MLX_RUNTIME_ARCHIVE` (install the runtime
from a local archive instead of the download; the hash is still checked), `PIPPA_HF_ENDPOINT` (another Hugging Face
endpoint), `PIPPA_TRASH_DIR` (a test folder instead of the real Trash), `PIPPA_LOG_DIR` and `PIPPA_RESULTS_DIR`.
`PI_CODING_AGENT_DIR` is passed through to Pi, so a test can keep `~/.pi` untouched.

**Clicking through the real app.** Pippa is a regular app with a Dock icon, app menus, and Command-Tab support.
The chat opens on launch; closing it keeps Pippa running, and clicking the Dock icon restores it. The pill is optional
and off unless enabled in Settings; an explicit saved preference is retained. For a clean first start, point Foundation at a fake home and Pi's setup at its own folder:
`open --env PIPPA_NO_MOVE=1 --env CFFIXED_USER_HOME=$PWD/.build/fakehome --env HOME=$PWD/.build/fakehome --env PIPPA_PI_HOME=$PWD/.build/fakehome dist/Pippa.app`.
Preferences (`io.github.tschnorpfeil.pippa`) still go to the real account through `cfprefsd`: export them first
(`defaults export io.github.tschnorpfeil.pippa ~/pippa-prefs.plist`) and import them afterwards. `PIPPA_NO_MOVE=1`
skips the "move to Applications" question (`AppMover`); debug builds ask only with `PIPPA_TRY_MOVE=1`.

**Synthetic test files.** `python3 scripts/create-usability-fixtures.py [<folder>] [--language en]` writes made-up
letters and invoices and a shareable ZIP (default `dist/Pippa-Testdateien`), so a tester never needs real data. It
refuses to overwrite an existing folder.

## Localization

English is the development language and the fallback; German is a full translation, chosen by the system language.
Only text a person sees is translated. German document analysis and the German skills stay German by design.

**Format.** Plain `.strings` files, not `.xcstrings`, because the build uses only the Command Line Tools.
`Package.swift` sets `defaultLocalization: "en"`. `<language>.lproj` folders inside a `.process` resource directory
become localized resources in `Bundle.module` and must not contain subfolders.

| Module | Call | Files |
|---|---|---|
| `PippaCore` | `L("…", table: "Core")` | `app/Sources/PippaCore/Resources/{en,de}.lproj/<Table>.strings` |
| `Pippa` | `T("…", table: "App")` | `app/Sources/Pippa/Localization/{en,de}.lproj/<Table>.strings` (`App`, `CalendarUI`, `Island`, `Settings`, `Views`) |
| App bundle | system | `app/Packaging/Localization/{en,de}.lproj/{InfoPlist,ServicesMenu}.strings`, copied by `build-app.sh` |

**Rules.**

- The key is the English text: `L("Nothing was changed.", table: "Core")`. A missing key shows the English key.
- Keys are plain string literals without interpolation; values go in as arguments:
  `T("Moved %lld files to %@", table: "Views", count, folderName)`. Use `%@` for text, `%lld` for `Int`.
- If German needs another word order, use positions in the German value: `"%2$@: %1$lld Dateien verschoben"`.
- Every key goes into both `en.lproj` and `de.lproj` of its table.
- In SwiftUI pass a `String`: `Text(T("Open", table: "Views"))`. Do not rely on `LocalizedStringKey` lookups.
- In the `Pippa` module a generic type parameter must not be called `T`; it would hide the function.
- No `.stringsdict`: write sentences that work for any number, or use separate keys for one and many.
- Tone: English is calm and plain (no "model", "token", "prompt", "agent"); German addresses the person as "du".

`python3 scripts/check-strings.py` (also in CI; `--verbose` for details) checks that every literal key is in `en` and
`de` of the right table, that both languages have the same keys and placeholders, that no key is left without a call,
and that the packaging strings match `Info.plist`.

## Releasing

```sh
PIPPA_SIGN_IDENTITY='Developer ID Application: … (TEAMID)' PIPPA_NOTARY_PROFILE=<profile> scripts/release.sh [tag]
```

Everything is local: no push, tag or GitHub release. The script requires a clean commit and the Sparkle EdDSA key in
the Keychain (account `ed25519`, or `PIPPA_SPARKLE_ACCOUNT`). It checks the public key against `SUPublicEDKey` in
`Info.plist`, runs `build-app.sh`, `make-dmg.sh` and `verify-app.sh` with `PIPPA_REQUIRE_DISTRIBUTION=1`, and writes
`dist/releases/<tag>/` (default `v<version>-<build>`) with the versioned DMG, a stable-name `Pippa.dmg`, `appcast.xml`
(`write-appcast.py`), `SHA256SUMS` and `commit.txt`. The DMG and `appcast.xml` go into the same GitHub release, because
the in-app update feed is `releases/latest/download/appcast.xml`. The release body is `docs/releases/<version>.md`, in
English only ([format](releases/README.md)). Without the Sparkle key, `PIPPA_NO_SPARKLE=1` still builds the signed,
notarized DMG; its `appcast.xml` names the new version without a download. Never attach an older release's
`appcast.xml`.

**Update key.** Run once on the Mac that builds releases:

```sh
swift package --package-path app resolve
app/.build/artifacts/sparkle/Sparkle/bin/generate_keys             # creates the key in the login Keychain, or shows it
app/.build/artifacts/sparkle/Sparkle/bin/generate_keys -x pippa-update-key.txt   # backup: into the password manager, then delete
```

The printed public key goes into `SUPublicEDKey` in `app/Packaging/Info.plist`. Keep `SUVerifyUpdateBeforeExtraction`
on: it lets a new key take over from an old one for a DMG signed by the same team.

**Updates.** Sparkle 2.10.0 is pinned exactly. Pippa checks daily, downloads in the background and installs on quit or
after a while without input. To test a real update from an installed build without touching it:

```sh
PIPPA_PROBE_AUTOMATIC=1 PIPPA_SIGN_IDENTITY=… scripts/prepare-update-probe.sh /Applications/Pippa.app dist/releases/<tag>
python3 -m http.server 18765 --bind 127.0.0.1 --directory dist/update-probe/feed
open -n "dist/update-probe/Pippa Updateprobe.app"
```

The result is in `dist/update-probe/events.log` (`UPDATE INSTALLED`). Sparkle records its check state in the host's
defaults domain, so back up that preferences file first.

**Pi.** Move to a new Pi release with `scripts/bump-pi.sh <version>`; see [Updating Pi](updating-pi.md).

## Where Pippa keeps things

| What | Where |
|---|---|
| Conversations (`conversations/`), Pi sessions (`pi-sessions/`), Pi's working folder (`pi-work/`), `memory.md`, `Backups/`, web settings (`pi-web/`), `journal.sqlite`, oMLX and its model (`omlx/`), the Python runtime (`mlx-runtime/`), `settings.json` | `~/Library/Application Support/Pippa/` |
| Tool results (`Results/`), read mails and their attachments (`Inbox/`), `pippa.lock` | `~/Library/Caches/Pippa/` |
| Preferences | `~/Library/Preferences/io.github.tschnorpfeil.pippa.plist` |
| Log `pippa.log` (version and events, no file contents; `PIPPA_LOG_DIR` overrides) | `~/Library/Logs/Pippa/` |
| Pi release, settings, `models.json`, the person's own Pi extensions | `~/.pi/agent` |
| Node for the terminal `pi` | `~/.local/share/pi-node` |
| Build cache (developers) | `~/Library/Caches/pippa-build` |

**Network.** Only these go out: the model download from Hugging Face and the oMLX runtime from Pippa's GitHub
releases (both after consent), Sparkle's update check, web
search and page reads (the first search of an answer is asked for), and the online AI the person switches on. Files,
conversations and the model otherwise stay on the Mac.

**Uninstall.** Quit Pippa, move `Pippa.app` to the Trash, then remove `~/Library/Application Support/Pippa`, the
preferences file above, `~/Library/Caches/Pippa`, `~/Library/Caches/io.github.tschnorpfeil.pippa` and
`~/Library/Logs/Pippa`.

## Website

`site/` is static HTML with self-hosted fonts and scripts, in German with an English version under `site/en/`.
Production pages count visits and download clicks through a GoatCounter image request; this is disabled on localhost
and when Do Not Track is enabled. The app collects no usage analytics.

```sh
python3 -m http.server 8088 --directory site
node scripts/check-site.cjs           # content and behavior checks
node scripts/check-site-launch.cjs    # publication gate: required files
```

### Provider integration checks

```sh
node --test runtime/pippa-auth/*.test.mjs
PIPPA_PROVIDER_CHECKS=1 PIPPA_PI_PAYLOAD="$PWD/.build/pi-payload-1.5.0" swift run --package-path app --jobs 2 PippaChecks
node scripts/provider-setup-smoke.mjs dist/Pippa.app
```

The focused Swift checks cover settings compatibility and the duplex helper lifecycle. The app smoke uses a fresh
HOME and a loopback scripted responder to exercise the actual chat route without a local model or real credentials.
`verify-app.sh --verify-runtime` also checks provider discovery inside the signed bundle. Real account login requires
a person’s interaction and is not part of these offline checks.

Pi 1.5 includes Anthropic, OpenAI/ChatGPT, OpenRouter, OpenCode, and xAI. Its separate `openai-codex` provider is marked
legacy. Google Antigravity is not built in; Google Gemini and Vertex are listed with their actual Pi capabilities.

### Mac app window checks

After building the app, run `scripts/check-window-lifecycle.sh`. It clones the bundle with APFS, assigns a temporary
bundle identifier, and launches it through LaunchServices with an isolated HOME, so real preferences and Pi state
stay untouched. It exercises closing, minimizing, reopening, draft preservation, app menus, hiding/unhiding, and the
optional non-key pill. Setup, updates, and model servers do not run. If macOS reports `loginwindow` as the frontmost
app, three checks that need real keyboard focus are explicitly skipped; rerun from an unlocked interactive desktop
to exercise them. Background replies update a Dock badge and do not activate Pippa.
