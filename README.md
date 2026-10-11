<p align="center">
  <img src="site/icon-512.png" width="112" height="112" alt="Pippa's app icon: three wobbly blue rings on a light tile">
</p>

<h1 align="center">Pippa</h1>

<p align="center">
  <b>Just drop it on Pippa.</b><br>
  A small pill on your Mac. Drop a letter, a folder or a few photos on it, pick a step, done.<br>
  The AI runs on your Mac. No account, no subscription.
</p>

<p align="center">
  <a href="https://github.com/tschnorpfeil/pippa/releases/latest/download/Pippa.dmg"><b>Download for Mac</b></a> ·
  <a href="https://heypippa.app">heypippa.app</a> ·
  free and open source (MIT)
</p>

<p align="center">
  <img src="docs/images/demo-tidy.gif" width="960" alt="The Downloads folder is dragged onto Pippa. She shows where 38 files would go (Invoices, Photos, Letters, Programs), nothing is changed yet. One click on '38 Dateien ordnen' sorts them, and 'Undo' brings everything back.">
</p>

Pippa is for people who don't pay for an AI subscription and never open Terminal. Her menus are in English or German, and she answers in the language you write in.

## What she does

- **Tidy up a folder.** She shows first where everything would go and waits for your OK. Undo puts it all back.
- **Understand a letter.** What does it say, what do I have to do, by when? With the passage it came from.
- **Find files again.** "Where is the invoice for my helmet?" searches your Mac.
- **Answer emails.** Select a mail in Apple Mail and ask. She checks your calendar and puts a reply into Mail as a draft. She never sends mail.
- **Office work.** *Check the total* in Excel adds the numbers up again in code and points out rows a total leaves out. Invoices become a table (`Rechnungen.csv`) that opens in Excel. Your files stay as they are.
- **PDF tools, no AI needed.** Make PDFs and photos smaller, combine scans into one PDF, convert between PDF, JPG and PNG.
- **Calendar, reminders, the web.** Add an appointment or a reminder, or look something up online.

<p align="center">
  <img src="docs/images/demo-letter.gif" width="480" alt="A rental agreement is dropped on Pippa and she answers when the notice is due.">
  <img src="docs/images/demo-excel.gif" width="480" alt="In Excel, Pippa checks a total and finds that it leaves out the row 'Müll'. Nothing in the table is changed.">
</p>

<p align="center">
  <img src="docs/images/demo-pdf-tools.gif" width="480" alt="A large PDF is dropped on Pippa, who offers 'Kleiner machen' (make smaller).">
</p>

<sub>Recorded from the demo on [heypippa.app](https://heypippa.app), shown in German. Names and files are made up.</sub>

## Private by design

- **The AI runs on your Mac.** No Pippa account, server or usage statistics.
- **She reads only when you ask,** and only what you can open yourself.
- **What she remembers is one text file on your Mac.** She refuses to store passwords and account, card or ID numbers.
- **The network is used for** the one-time model download, updates, web lookups, and ChatGPT if you connect your own subscription (optional).

Worth knowing: Pippa runs without the macOS App Sandbox, because a sandboxed app cannot set up her agent. Keep Time Machine on, as you would anyway.

## Install

You need a Mac with Apple silicon (M1 or later), macOS 15 or later, and 3 to 6 GB of free space.

1. Download [Pippa.dmg](https://github.com/tschnorpfeil/pippa/releases/latest/download/Pippa.dmg) and drag Pippa into Applications.
2. Open her and say yes to the one-time AI download. Everything else sets itself up, and updates arrive by themselves.

| Memory | Model | Download |
|---|---|---|
| 8 GB | Qwen3.5 4B | about 2.7 GB |
| 16 GB or more | Qwen3.5 9B | about 5.7 GB |

A matching model from LM Studio, Ollama or the Hugging Face cache is reused.

## How it works

The Swift app draws the pill and connects to Mail, Calendar, Reminders and Excel. Behind it, the [Pi](https://github.com/earendil-works/pi) agent does the work with a local model run by [llama.cpp](https://github.com/ggml-org/llama.cpp). Pippa's abilities are Pi skills in [`runtime/pippa-skills`](runtime/pippa-skills): plain text files, not app code.

```
Pippa.app (Swift)      pill, cards, settings, MCP server for Mail, Calendar, Excel
 ├─ llama-server       the local model, on 127.0.0.1 only
 └─ pi --mode rpc      the agent, with Pippa's skills and pi-web-access
```

## Building from source

Apple silicon, macOS 15+, Command Line Tools with Swift 6 and `cmake`.

```sh
scripts/build-app.sh                        # dist/Pippa.app
swift run --package-path app PippaChecks    # checks, no model needed
```

More in [docs/development.md](docs/development.md) and [docs/updating-pi.md](docs/updating-pi.md).

## Credits and license

Built on [Pi](https://github.com/earendil-works/pi), [llama.cpp](https://github.com/ggml-org/llama.cpp), [pi-web-access](https://github.com/nicobailon/pi-web-access), [Node.js](https://nodejs.org), [Sparkle](https://sparkle-project.org) and the open [Qwen](https://huggingface.co/Qwen) models. Full list: [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).

[MIT](LICENSE). Contributions welcome, see [CONTRIBUTING.md](CONTRIBUTING.md).

<sub>Pippa is an independent project, not affiliated with Apple, Microsoft, OpenAI, Alibaba Cloud or Earendil Works. Mac and macOS are trademarks of Apple Inc., Excel of Microsoft Corporation, ChatGPT of OpenAI.</sub>
