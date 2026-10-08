# Pippa

Pippa opens up the power of coding agents to the everyday person.

Pippa is a small helper that sits at the edge of your Mac's screen. You drag something onto her (a letter, a few photos, a messy folder) or click her while an email or a spreadsheet is open, and she offers two or three next steps in plain words. You can also just type. Behind the friendly surface runs [Pi](https://github.com/earendil-works/pi), a full open-source coding agent, with a language model that runs on your own Mac through [llama.cpp](https://github.com/ggml-org/llama.cpp). Pippa sets all of this up for you, without Terminal, and keeps a hand on the brakes: she asks before anything leaves your Mac and lets you undo changes to files.

Website: [heypippa.app](https://heypippa.app) · Version 1.0 · free and open source (MIT)

Pippa speaks English, and German when your Mac is set to German. She answers in the language you write in.

## What it can do

- **Read a letter or a PDF.** Ask what it says, what you need to do and by when. Amounts and dates come with the passage they were taken from, and Pippa checks in code that the quoted passage really is in the document.
- **Answer an email.** Select a mail in Apple Mail and call Pippa (click her or press **⌃⌥ Space**). She can look at your calendar, write a reply and put it into Mail as a draft. Pippa never sends mail; you send it yourself.
- **Calendar and reminders.** Add an appointment or a reminder, for example a payment deadline from a letter. Both can be undone.
- **Turn photos into one PDF.** Drop scans or phone photos on Pippa and choose *Make one PDF* (with searchable text), *Make smaller*, or convert between PDF, JPG and PNG. This runs entirely on your Mac and needs no model. Your originals are not changed.
- **Tidy a messy folder.** Ask Pippa to tidy your Downloads folder. She sorts files into folders, shows you what went where, and *Undo* puts everything back.
- **Spreadsheets in Excel.** Select cells in Microsoft Excel and call Pippa. *Check the total* adds the numbers up again in code and points out rows a total leaves out or numbers stored as text. Pippa only reads the sheet; she does not write into it. She can also collect invoices from a folder into a table (CSV or Excel file).
- **Look something up online,** after you approve the exact search text.

Because Pi is a real agent with real tools, Pippa can also handle tasks nobody planned for, such as renaming a batch of files. [Privacy and safety](#privacy-and-safety) explains how that is kept in check.

## Privacy and safety

- **The AI runs on your Mac.** The language model is downloaded once, after you agree, and then runs locally through llama.cpp. After that, Pippa works without the internet. There is no Pippa account and no Pippa server, and Pippa does not collect usage statistics. For the Pi it starts, Pippa turns off Pi's telemetry, update check and other start-up network calls (`PI_TELEMETRY=0`, `PI_OFFLINE=1`, `PI_SKIP_VERSION_CHECK=1`).
- **Pippa reads only when you call her,** but then she may read what you yourself can open: files, the selected mail, your calendar. Reading changes nothing, so she does not ask first.
- **Pippa asks before anything leaves your Mac or is deleted for good:** a web search (you see the exact text that goes out), sending, shell commands she cannot recognise as read-only, and permanent deletion.
- **File changes can be undone.** Before Pippa changes, moves or trashes a file, she keeps a copy of the original (an APFS clone, kept for up to seven days and up to 500 MB in total). Each change shows a receipt with an *Undo* button. The receipt is built from what the tools actually did, not from what the model says it did.
- **Online models are optional.** In Settings you can connect an online service (OpenAI or Anthropic) with your own API key, which is stored in the macOS Keychain. Switching it on is your consent: Pi then sends your conversations to that service through its own provider support. The key stays in the Keychain and reaches only Pippa's own Pi, never a file.

The network is used only for the model download (Hugging Face), app updates (Sparkle, from GitHub releases), web lookups you approve, and an online service you connected yourself.

Limits worth knowing: Pippa runs **without** the macOS App Sandbox, because a sandboxed app cannot set up Pi in your home folder. Pippa's checks sit on Pi's tool calls. Pi extensions you install yourself stay active, and anything they do outside a tool call is not seen by Pippa.

## Requirements

- A Mac with Apple silicon (M1 or later)
- macOS 15 or later. On macOS 26 with Apple Intelligence, the instant one-line summary uses the Mac's own model.
- Free disk space for the model, about 3 to 6 GB depending on memory (14 GB more for *More thorough*):

| Memory | Model Pippa picks | Download |
|---|---|---|
| 8 GB | Qwen3.5 4B | about 2.7 GB |
| 16 GB or more | K2 Horizon 7B | about 5.6 GB |
| 24 GB or more, *More thorough* in Settings | Qwen3.6 35B-A3B | about 13.7 GB |

16 GB is recommended. Pippa picks the model for your Mac. The only choice, on Macs with 24 GB or more, is *Pippa's knowledge* in Settings: *Standard* or *More thorough*. Choosing loads the other model while the current one keeps working; switching back is instant, and nothing is deleted. If a matching model is already on your Mac (LM Studio, Ollama, Hugging Face cache), Pippa reuses it instead of downloading it again and leaves the original untouched.

## Install

1. Download [Pippa.dmg](https://github.com/tschnorpfeil/pippa/releases/latest/download/Pippa.dmg) from the latest release.
2. Open it and drag Pippa into Applications.
3. Open Pippa. She asks one question: may she download her AI now (with size and approximate time). Everything else is set up without questions.

During setup Pippa installs the bundled, pinned Pi release at Pi's standard location (`~/.pi/agent`, plus `~/.local/bin/pi` if you have no Pi yet), so the same Pi and the same local model also work from Terminal. An existing Pi install is left as it is. Updates arrive automatically through Sparkle.

## How it works

```
Pippa.app (Swift, SwiftUI)
 ├─ the pill, drag and drop, receipts, settings, setup
 ├─ starts ─► llama-server (llama.cpp)      local model, 127.0.0.1 only
 ├─ starts ─► pi --mode rpc                 the agent, one process per active conversation
 │             ├─ --extension pippa-guard   asks, keeps undo copies, writes receipts
 │             └─ MCP client ─────────────► Pippa's MCP server (inside the app, 127.0.0.1)
 │                                          mail, calendar, reminders, Excel, documents, web
```

- **Pippa app** (`app/Sources/Pippa`, `app/Sources/PippaCore`): the native interface, model download and selection, the installer that sets up Pi, and the features that need no model at all (scans, sheet totals).
- **Pi over RPC** (`app/Sources/PiRPC`): Pippa talks to the real Pi through `pi --mode rpc` (JSON lines over stdin and stdout), with Pippa's own short system prompt, `--no-context-files` (an `AGENTS.md` in a user folder could otherwise inject instructions) and one Pi session per Pippa conversation.
- **Guard extension** (`runtime/pippa-guard`): a Pi extension loaded before any of your own on every start. It sees each tool call, asks where needed, clones files before changing them, and writes receipts that the app turns into the "what happened" line with *Undo*. It also adds four small file tools (`list_folder`, `rename_or_move`, `move_files`, `move_to_trash`) so everyday tasks do not need the shell.
- **MCP server** (`app/Sources/PippaCore/MCP`): the app itself serves the Model Context Protocol on 127.0.0.1 with a per-launch key, registered for Pippa's Pi sessions only (nothing is written to your own Pi configuration). Its tools read the selected mail, search mail, read calendar and reminders, read the Excel selection, read documents (with text recognition for scans), create a mail draft, add an appointment or reminder, and search and read the web. Because the app does the reading, macOS asks for permission in Pippa's name.
- **Abilities and web fetcher**: Pippa's 14 abilities are Pi skills in [`runtime/pippa-skills`](runtime/pippa-skills), bundled and loaded into Pi with `--skill` (your own Pi skills are not mixed in). Web search and page reading run in Pippa's own fetcher process [`runtime/pippa-web`](runtime/pippa-web) (pi-web-access, own lockfile), started by the app only after your approval.
- **llama-server** (`app/Packaging/llama-release.json`): a pinned llama.cpp release (source checksum-verified, plus a small K2 Horizon patch in `app/Packaging/llama-patches`), built by `scripts/build-app.sh` and bundled in the app. It listens on 127.0.0.1 only and unloads the model when idle.

## Building from source

You need Apple silicon, macOS 15 or later and the Command Line Tools with Swift 6 (`xcode-select --install`); Xcode is not required. The build downloads the pinned llama.cpp source and Node.js and installs Pi's locked npm dependencies, all checksum-verified, and compiles llama-server (needs `cmake`, e.g. `brew install cmake`), so it needs network access the first time (cached under `~/Library/Caches/pippa-build`).

```sh
scripts/build-app.sh      # builds dist/Pippa.app (ad-hoc signed without PIPPA_SIGN_IDENTITY)
scripts/verify-app.sh     # signature, entitlements, bundled Pi payload, runtime probe
scripts/make-dmg.sh       # dist/Pippa.dmg
```

Checks that need no model:

```sh
swift run --package-path app PippaChecks                                 # native checks
python3 scripts/check-strings.py                                         # every UI text in English and German
node --experimental-strip-types --test runtime/pippa-guard/*.test.mjs    # guard extension (Node 22.6 or later)
(cd runtime/pippa-web && npm ci --ignore-scripts && npm test)            # web fetcher
```

An ad-hoc signed build runs on your own Mac. For distribution, set `PIPPA_SIGN_IDENTITY` to a Developer ID Application identity and `PIPPA_NOTARY_PROFILE` to a `notarytool` keychain profile; `scripts/release.sh` then prepares the signed, notarized DMG and its appcast locally. More detail, including environment variables and where Pippa stores data: [docs/development.md](docs/development.md).

### Repository layout

| Path | Contents |
|---|---|
| `app/Sources/Pippa` | macOS app: pill, conversation window, settings, setup, Sparkle |
| `app/Sources/PippaCore` | core logic: models, llama-server, Pi installer, MCP server, readers for Mail, Calendar and Excel, scan tools |
| `app/Sources/PiRPC` | client for `pi --mode rpc` |
| `app/Sources/PippaChecks` | checks without a model (`swift run PippaChecks`; no XCTest needed) |
| `app/Packaging` | Info.plist, entitlements, pinned llama.cpp, Node and Pi releases |
| `runtime/pippa-guard` | the guard extension and Pippa's file tools for Pi |
| `runtime/pippa-skills` | Pippa's 14 abilities (Pi skills) |
| `runtime/pippa-web` | Pippa's web fetcher process (search, read pages) |
| `scripts/` | build, verify, DMG, release and check scripts |

## Credits

Pippa builds on:

- [Pi](https://github.com/earendil-works/pi) by Mario Zechner and Earendil Works (MIT), the agent that does the work
- [llama.cpp](https://github.com/ggml-org/llama.cpp) by the ggml authors (MIT), which runs the local model
- [Node.js](https://nodejs.org) (MIT and others), which runs Pi
- [Sparkle](https://sparkle-project.org) (MIT), for updates
- [pi-web-access](https://github.com/nicobailon/pi-web-access) by Nico Bailon (MIT), for web search and page reading
- [Bagel Fat One](https://fonts.google.com/specimen/Bagel+Fat+One) (SIL Open Font License 1.1), the welcome headline
- the open models [K2 Horizon](https://huggingface.co/IFM/K2-Horizon-7B) by MBZUAI and IFM (Apache 2.0) and [Qwen](https://huggingface.co/Qwen) (Apache 2.0). Models are downloaded from Hugging Face on your Mac; they are not part of the app or this repository.

Licence texts and the full list of bundled components: [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).

## License

Pippa is released under the [MIT License](LICENSE).

Pippa is an independent project and is not affiliated with Apple, Microsoft, Google, Alibaba Cloud or Earendil Works. Mac and macOS are trademarks of Apple Inc. Microsoft Excel is a trademark of Microsoft Corporation.
