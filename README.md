<p align="center">
  <img src="site/icon-512.png" width="112" height="112" alt="Pippa's app icon: three wobbly blue rings on a light tile">
</p>

<h1 align="center">Pippa</h1>

<p align="center">
  <b>Your private AI agent on the Mac.</b><br>
  Ask her anything, or drop a letter, a folder or a few photos on her. She helps you get the work done.<br>
  Her built-in AI runs on your Mac. No account, no subscription.
</p>

<p align="center">
  <a href="https://github.com/tschnorpfeil/pippa/releases/latest/download/Pippa.dmg"><b>Download for Mac</b></a> ·
  <a href="https://heypippa.app">heypippa.app</a> ·
  free and open source (MIT)
</p>

<p align="center">
  <img src="docs/images/demo-tidy.gif" width="960" alt="The Downloads folder is dragged onto Pippa. She shows where 38 files would go (Invoices, Photos, Letters, Apps) before changing anything. One click on 'Organize 38 Files' sorts them, and 'Undo' brings everything back.">
</p>

Think of ChatGPT, but living in a small pill on your Mac and working with your own files, Mail and Calendar. Pippa doesn't only chat: she reads the letter, sorts the folder, writes the reply into Mail. That is what makes her an agent rather than a chat window.

She is made for people who don't pay for an AI subscription and never open Terminal. Her menus are in English or German, and she answers in the language you write in.

## Private, because she runs on your Mac

- **The built-in AI runs on your Mac.** No Pippa account, no Pippa server, no usage statistics.
- **Mac app access uses macOS permissions.** Directly requested actions can run without a second confirmation.
- **Supported file changes have Undo.** Pippa keeps available backups; changes made elsewhere can prevent a safe restore. Native app actions do not all support Undo.
- **What she remembers is one text file on your Mac.** You can review and remove saved facts in Settings.
- **Online routes are optional.** Downloads, updates and web lookups use the network. If you connect an online AI service, it receives the content needed for that request. Mail, Calendar and Reminders can sync through your configured accounts. General tasks can also request network access.

Worth knowing: Pippa runs without the macOS App Sandbox, because a sandboxed app cannot set up her agent. Keep Time Machine on, as you would anyway.

## What she does for you

- **Ask her anything.** Click the pill and type, like in a chat. She answers on your Mac, and you can add files for her to look at.
- **Tidy up a folder.** The Organize action shows where files would go and waits for your OK. Supported moves can be undone.
- **Understand a letter.** What does it say, what do I have to do, by when? With the passage it came from.
- **Find files again.** "Where is the invoice for my helmet?" searches your Mac.
- **Answer emails.** Select a mail in Apple Mail and ask. She can check your calendar and put a reply into Mail as a draft for you to review and send.
- **Office work.** *Check the total* in Excel adds the numbers up again in code and points out rows a total leaves out. Invoices become a CSV table that opens in Excel. Your files stay as they are.
- **Everyday extras, no AI needed.** Make PDFs and photos smaller, combine scans into one PDF, convert between PDF, JPG and PNG.
- **Calendar, reminders, the web.** Add an appointment or a reminder, or look something up online.

<p align="center">
  <img src="docs/images/demo-letter.gif" width="480" alt="Lease.pdf is dropped on Pippa with the question 'I'm moving out at the end of March. When do I have to give notice?' She answers 'By December 31' and quotes § 4 of the lease.">
  <img src="docs/images/demo-excel.gif" width="480" alt="In Excel, Pippa checks a total and finds that it leaves out the row 'Trash'. Nothing in the table is changed.">
</p>

<p align="center">
  <img src="docs/images/demo-pdf-tools.gif" width="480" alt="Tax notice.pdf is dropped on Pippa. After 'Make smaller' she offers 'Tax notice (smaller).pdf' to drag where it is needed, with Undo.">
</p>

<sub>Recorded from the demo on [heypippa.app/en](https://heypippa.app/en/). Names and files are made up.</sub>

## Install

You need a Mac with Apple silicon (M1 or later) and macOS 15 or later. Initial AI setup needs about 3 to 6 GB for its download, plus space for the app and your results.

1. Download [Pippa.dmg](https://github.com/tschnorpfeil/pippa/releases/latest/download/Pippa.dmg) and drag Pippa into Applications.
2. Open her and start with photos or PDFs immediately. For AI chat, choose whether to download her AI; a compatible existing copy can be reused. Pippa checks for app updates.

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
