<p align="center"><img src="site/icon-512.png" width="112" height="112" alt="Pippa's app icon: three wobbly blue rings on a light tile"></p>
<h1 align="center">Pippa</h1>
<p align="center"><b>Paperwork on your Mac? Done.</b><br>
The free Mac helper for people who'd rather not learn AI. Her built-in AI runs on your Mac.</p>

<p align="center">
  <img src="https://img.shields.io/badge/macOS-15%2B-000000?logo=apple&logoColor=white" alt="macOS 15 or later">
  <img src="https://img.shields.io/badge/Apple%20silicon-M1%2B-000000" alt="Apple silicon, M1 or later">
  <img src="https://img.shields.io/badge/native-Swift-F05138?logo=swift&logoColor=white" alt="Native Swift app">
  <img src="https://img.shields.io/badge/language-English%20%7C%20Deutsch-2b6cb0" alt="Language: English and German">
  <img src="https://img.shields.io/badge/account-not%20needed-2f855a" alt="No account needed">
  <a href="LICENSE"><img src="https://img.shields.io/badge/license-MIT-2b6cb0" alt="MIT license"></a>
  <a href="https://github.com/tschnorpfeil/pippa/releases/latest"><img src="https://img.shields.io/github/v/release/tschnorpfeil/pippa?label=release&display_name=release" alt="Latest release"></a>
</p>

Cloud assistants read your documents on their servers, and most local AI apps stop at a chat window. Pippa hands back finished results, and the first ones need no AI download:

- **Ready to send.** Photos and scans become one PDF in your order; she checks that every page made it in and shows whether it fits the size limit you set (say, 10 MB). No AI download needed.
- **Letter explained.** What a German letter wants from you, by when, and the sentence that says so. A PDF or a phone photo works. Ask, and the deadline goes into Reminders. Check amounts and dates against the original. Answers may be in German.
- **Downloads tidied.** See the new folders before anything moves. Changed your mind? Undo.

Also: reply drafts in Mail (you send them; she never does), Calendar entries, reminders, file search and Excel totals.

Drop files on Pippa or bring her up with ⌃⌥ Space (she lives in the menu bar), then pick a job or just ask.

<p align="center"><a href="https://github.com/tschnorpfeil/pippa/releases/latest/download/Pippa.dmg"><b>Download Pippa.dmg</b></a> (under 100 MB, signed and notarized) · <a href="https://heypippa.app/en/">Website</a> · <a href="https://github.com/tschnorpfeil/pippa/releases/latest">What's new</a></p>

<p align="center"><sub>Apple silicon (M1 or later), macOS 15 or later. Photo and PDF jobs work right away. For the rest, Pippa picks the AI that fits your Mac and asks before downloading it: about 2.7 GB with 8 GB of memory, 5.7 GB with 16 or 18 GB, 16.8 GB with 24 GB or more (<a href="#will-it-run-on-my-mac">details</a>). If LM Studio, Ollama or Hugging Face already has the same file, she uses it instead of downloading it again. Prefer an online AI? Sign in with ChatGPT or add your own key.</sub></p>

<p align="center"><img src="docs/images/demo-letter.gif" width="960" alt="Scripted website demo with made-up files: asked when notice is due before moving out at the end of March, Pippa answers 'By December 31', explains the three-month notice period and quotes the passage from the lease"><br>
<sub>Scripted demo from an earlier version of the website, with made-up files. Not a live AI session.</sub></p>

**Private by default.** Her built-in AI runs on your Mac. No account, no tracking in the app. Prefer an online AI? Sign in with ChatGPT or add your own OpenAI or Anthropic API key, then switch it on in Settings. While it's on, your conversations and what Pippa reads for them go to that service. Mail, Calendar and Reminders may sync through your accounts, and she asks before searching the web. More in [Privacy and permissions](docs/privacy-and-permissions.md).

## Why Pippa

Keep ChatGPT if you like it: Pippa can use your subscription as her online AI.

| | Pippa | ChatGPT & Claude apps | Local AI chat apps | Apple Intelligence |
|---|---|---|---|---|
| What you get back | One PDF, a tidied folder, a reminder, an unsent Mail draft | Answers; some modes also work on your files | Mostly chat answers; a few also edit files | Rewrites, summaries and Shortcuts actions you build |
| First useful result | Photo and PDF jobs right after install, before any AI download | After you sign in | After an AI download | On by default on supported Macs, once Apple's download has finished |
| Where your letter is read | On your Mac by default; online AI only if you turn it on | On the provider's servers | On your computer by default | On the device, or on Apple's Private Cloud Compute |
| German letters and deadlines | Tuned for German letters; quotes the sentence behind each deadline | Capable, once you upload the letter | General-purpose chat | General summaries |
| Mail, Calendar, Reminders | Unsent Mail drafts, Calendar events, reminders | Through connectors, mostly to online accounts | Varies; a few draft mail or add events | Built into Apple's apps |
| Cost, account, code | Free, no account, open source (MIT) | Account needed; paid plans for more; closed source | Mostly free, no account; many open source | Included with supported Macs; closed source |

<sub>As of October 2026; other apps change quickly.</sub>

## What she can do

- **Files and PDFs:** one PDF from photos and scans, smaller PDFs and photos, JPG or PNG copies, text from images and PDFs, and Tidy Up with a preview and Undo. None of this needs the AI download.
- **Letters and documents:** what a letter wants and by when, with the passage that says so; questions about PDFs, Word files and photos of documents; shorter or clearer text, and checklists from your notes.
- **Mail, Calendar and Reminders:** reply text for the message you selected in Mail, or an unsent draft in Mail for you to review and send; appointments and reminders, added when you ask.
- **Excel:** check a total and find rows it leaves out, without changing the sheet; turn a stack of invoices into one spreadsheet with totals.
- **Finding things:** files by what's in them, photos in your library, and the web after she asks you.
- **Morning overview (optional):** today's appointments and due reminders at a time you choose. It stays off until you turn it on.

More, with examples and limits: [What Pippa can do](docs/what-pippa-can-do.md).

## Will it run on my Mac?

You need a Mac with **Apple silicon (M1 or later)** and **macOS 15 or later**. Intel Macs are not supported.

Photo and PDF jobs work without any AI download. For everything else, Pippa picks her AI based on your Mac's memory and asks before downloading it:

| Your Mac's memory | Pippa's AI download |
|---|---|
| 8 GB | About 2.7 GB |
| 16 GB or 18 GB | About 5.7 GB |
| 24 GB or more | About 16.8 GB |

Leave some extra disk space for the app and your results. If the same file is already on your Mac from LM Studio, Ollama or Hugging Face, Pippa uses it instead of downloading it again. Apple Intelligence is optional: on macOS 26, when it is turned on, Pippa lets Apple Intelligence handle a few quick jobs, such as short text selections and sorting unclear files while tidying. Which AI each Mac gets, and why: [Pippa's local AI](docs/models.md).

## Good to know

- **Local AI can miss details.** Check important names, amounts and dates against the original. If Pippa gets something wrong, [open an issue](https://github.com/tschnorpfeil/pippa/issues) with the version, what you asked and what happened, using made-up examples.
- **Letter help is tuned for German.** Letter and deadline detection is built for German documents.
- **Undo covers supported file changes,** such as tidying, moves and edited files. If you change those files elsewhere afterwards, a safe restore may not be possible.
- **She acts when you ask.** If you ask her to add a reminder or move a file, she does it without asking again. Tidy Up shows a preview first; for anything else, check the result.
- **She runs outside the App Sandbox** so she can work with your folders and Mac apps; a sandboxed app couldn't. macOS still asks before she reaches Documents, Calendar or Photos. Details: [Privacy and permissions](docs/privacy-and-permissions.md).
- **Updates arrive inside the app.** Pippa checks daily and installs when you quit or after a while without input, never in the middle of your work.
- **Uninstall:** [how to remove Pippa and her files](docs/privacy-and-permissions.md#remove-pippa).

## Build from source

You need an Apple silicon Mac with macOS 15 or later, the Command Line Tools with Swift 6 (`xcode-select --install`) and `cmake`. Xcode is not needed.

```sh
scripts/build-app.sh                        # dist/Pippa.app
swift run --package-path app PippaChecks    # checks, no AI download needed
```

Architecture, checks and releases: [Developing Pippa](docs/development.md). Before a pull request, read [Contributing](CONTRIBUTING.md).

## Credits and license

Built on [Pi](https://github.com/earendil-works/pi), [llama.cpp](https://github.com/ggml-org/llama.cpp), [pi-web-access](https://github.com/nicobailon/pi-web-access), [Node.js](https://nodejs.org), [Sparkle](https://sparkle-project.org) and the open [Qwen](https://huggingface.co/Qwen) models. Full list: [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).

[MIT licensed](LICENSE), © 2026 Tobias Schnorpfeil. Pippa is an independent project, not affiliated with Apple, Microsoft, OpenAI, Anthropic, Alibaba Cloud or Earendil Works. Mac and macOS are trademarks of Apple Inc.; Excel is a trademark of Microsoft Corporation.
