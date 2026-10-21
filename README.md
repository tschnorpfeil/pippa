<p align="center">
  <img src="site/icon-512.png" width="112" height="112" alt="Pippa's app icon: three wobbly blue rings on a light tile">
</p>

<h1 align="center">Pippa</h1>

<p align="center">
  <b>Your private AI assistant for everyday Mac tasks.</b><br>
  Turn photos into a PDF. Understand a letter. Find a file. Prepare a reply.<br>
  Drop something on Pippa or tell her what you need.
</p>

<p align="center">
  <a href="https://github.com/tschnorpfeil/pippa/releases/latest/download/Pippa.dmg"><b>Download for Mac</b></a> ·
  <a href="https://heypippa.app/en/">Website &amp; interactive demo</a> ·
  <a href="https://github.com/tschnorpfeil/pippa/releases/tag/v0.3.12-727">What's new in 0.3.12</a>
</p>

<p align="center">
  Apple silicon · macOS 15 or later · English &amp; German<br>
  Free and open source · No Pippa account or subscription
</p>

Pippa is a personal AI agent for macOS, living in a small pill on your desktop. She works with your files, Apple Mail, Calendar, Reminders and Excel. Her built-in AI runs on your Mac. Photo and PDF tools work before AI setup.

<p align="center">
  <img src="docs/images/demo-tidy.gif" width="960" alt="Illustrative demo: Pippa previews a Downloads folder organized into Invoices, Photos, Letters and Apps, then shows Organize and Undo controls.">
</p>

<sub>These animations record the scripted website demo with fictional files, rather than live AI sessions.</sub>

## Your first useful result

1. Download [Pippa.dmg](https://github.com/tschnorpfeil/pippa/releases/latest/download/Pippa.dmg), open it and drag Pippa to Applications.
2. Open Pippa and choose photos or PDFs from setup. Combine scans into a PDF, make a file smaller or extract its text. These actions need neither an AI download nor Apple Intelligence.
3. Open the result, show it in Finder or save it where you need it. If saving fails, your result stays available so you can try again.

For AI conversations, Pippa asks before downloading her local AI. No Terminal, API key or separate AI app needed. Updates arrive through Pippa.

## Everyday work, with fewer steps

| What you need | How Pippa helps |
|---|---|
| **A PDF ready to share** | Combine photos or scans, reduce file size, convert images to PDF, JPG or PNG, or extract text from images and PDFs. |
| **A folder you can navigate again** | Drop a folder and choose Organize. Review the proposed destinations before moving files; supported moves have Undo. |
| **A letter you can act on** | Ask what it says, what it asks you to do and which passage supports the answer. Letter and deadline extraction is currently tuned for German documents. |
| **A file you cannot find** | Ask “Where is the invoice for my helmet?” Pippa searches the Mac's existing index and links to the files she finds. |
| **A reply ready to review** | Work from a message in Apple Mail. Prepare reply text, or ask Pippa in chat to create an unsent draft in Mail for you to review and send. |
| **Less spreadsheet busywork** | Check an Excel total with code, identify omitted rows or turn invoices into a CSV table. These actions leave the source files unchanged. |
| **An appointment or a reminder** | Ask Pippa to add it to Calendar or Reminders. macOS controls app access, and Pippa shows the reported action in the conversation. |
| **A clearer piece of writing** | Shorten text, fix spelling or turn a selection into a checklist. Eligible short selections use Apple's on-device intelligence when available. |

File utilities run in code; open-ended tasks use AI. Answer quality and speed vary, so review important names, amounts and dates against the source. File search uses Spotlight; files that are not indexed or downloaded may be missing.

<p align="center">
  <img src="docs/images/demo-letter.gif" width="480" alt="Scripted demo: a question about a lease receives a proposed deadline and a supporting passage.">
  <img src="docs/images/demo-excel.gif" width="480" alt="Scripted demo: Pippa checks an Excel total and highlights an omitted row without changing the spreadsheet.">
</p>

## Local by default, clear about access

- **Local AI, no Pippa server.** Pippa's built-in model processes your requests on your Mac. Pippa has no account requirement or usage analytics.
- **Permissions belong to you.** Mac integrations use macOS permissions. A directly requested action can run without another confirmation; folder organization has a preview before changes.
- **Undo where supported.** Supported file changes keep backups, including after errors or Stop. Changes made elsewhere can prevent a safe restore. Not every native app action supports Undo.
- **Memory you can inspect.** Review or remove saved facts in Settings. Facts, conversation history and task records are stored locally.
- **Network use has a purpose.** Model downloads, updates and web lookups use the network. An optional online AI service receives the content needed for its requests. General tasks can request network access, and Mail, Calendar and Reminders may sync through your configured accounts.

Pippa runs outside the macOS App Sandbox, with her own controls for agent tools and macOS permissions for connected apps. Details: [privacy policy (German)](https://heypippa.app/datenschutz.html) and [architecture](docs/development.md).

## Will it run on my Mac?

You need **Apple silicon (M1 or later)** and **macOS 15 or later**. Intel Macs are not supported. Photo and PDF actions are available without downloading a language model.

For local AI, Pippa chooses a default based on your Mac's memory:

| Mac memory | Default local model | Download size |
|---|---|---|
| 8 GB | Qwen3.5 4B | About 2.7 GB |
| 16 GB or more | Qwen3.5 9B | About 5.7 GB |

Allow additional disk space for the app and your results. Pippa can reuse an exact supported model file found in an LM Studio, Ollama or Hugging Face cache; other models or quantizations may still require a download. Apple Intelligence is optional; eligible features use it on macOS 26 or later when it is enabled and available.

See the [0.3.12 release notes](https://github.com/tschnorpfeil/pippa/releases/tag/v0.3.12-727) for tested environments and validation limits.

## What's next

[The 0.3.13 roadmap](docs/roadmap-0.3.13.md) prioritizes completed everyday tasks, dependable Mac actions and less friction from first launch to finished result.

Found a task Pippa could not finish? [Report it](https://github.com/tschnorpfeil/pippa/issues) with the version, what you asked, what happened and what you expected. Use fictional examples and remove personal content from screenshots or logs.

## Build and contribute

Native Swift code handles the interface, file utilities and Mac integrations. [Pi](https://github.com/earendil-works/pi) coordinates model-driven tasks with Pippa's scoped tools and [bundled skills](runtime/pippa-skills). [llama.cpp](https://github.com/ggml-org/llama.cpp) runs the local model on a loopback-only server.

Building requires Apple silicon, macOS 15+, Command Line Tools with Swift 6 and `cmake`:

```sh
scripts/build-app.sh                        # dist/Pippa.app
swift run --package-path app PippaChecks    # checks, no model needed
```

See [development and architecture](docs/development.md), [updating Pi](docs/updating-pi.md) and [contributing](CONTRIBUTING.md).

## Credits and license

Built on [Pi](https://github.com/earendil-works/pi), [llama.cpp](https://github.com/ggml-org/llama.cpp), [pi-web-access](https://github.com/nicobailon/pi-web-access), [Node.js](https://nodejs.org), [Sparkle](https://sparkle-project.org) and the open [Qwen](https://huggingface.co/Qwen) models. Full list: [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).

[MIT licensed](LICENSE). Pippa is an independent project, not affiliated with Apple, Microsoft, OpenAI, Alibaba Cloud or Earendil Works. Mac and macOS are trademarks of Apple Inc.; Excel is a trademark of Microsoft Corporation.
