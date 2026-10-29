# Privacy and permissions

What Pippa reads, what goes online and when, what macOS lets her do, and how to take things back. For how it is
built, see [Developing Pippa](development.md); the website's [privacy policy](https://heypippa.app/datenschutz.html)
is in German.

## In short

- **Her AI runs on your Mac.** By default, her built-in AI reads your letters, PDFs and photos on your Mac. No Pippa
  account, no Pippa server, no tracking in the app.
- **Online AI only if you turn it on.** Sign in with ChatGPT or add your own OpenAI or Anthropic key, then switch it on
  in Settings. While it's on, that service receives your conversations and what Pippa reads for them.
- **She never sends your mail.** Replies wait as unsent drafts in Apple Mail, and events and reminders go into Calendar
  and Reminders. Those apps may sync through your accounts, such as iCloud.
- **Online only where needed.** Downloads, updates and web lookups use the internet, and she asks before searching the
  web. The code is open source (MIT), so anyone can check.

## Where her AI runs

- **On your Mac, by default.** Pippa's AI runs in llama.cpp's `llama-server` on your Mac. It only accepts connections
  from your own Mac and needs a key that Pippa keeps in her own folder. Which AI your Mac gets: [Pippa's local AI](models.md).
- **Apple Intelligence, if you have it.** On macOS 26 with Apple Intelligence turned on, Pippa lets it handle a few
  quick jobs, such as short text selections and sorting unclear files while tidying.
- **No account and no analytics.** Pippa has no sign-up and no server of her own, and the app collects no usage
  statistics. The website heypippa.app counts page visits and download clicks; the app does not.

## Online AI, only if you switch it on

Online AI is off until you turn it on in Settings. Only one online service can be on at a time: turning one on turns
the other off. The menu always says where Pippa is working, for example "Runs on this Mac" or "Online · ChatGPT".

**ChatGPT (your subscription).** Choose **Sign in with ChatGPT**; the sign-in happens in your browser. Then switch it
on. Pippa asks first: "Your conversation and everything Pippa reads for it will be sent to OpenAI. You can switch back
to the AI on this Mac at any time." Switching it off keeps the sign-in; **Sign Out** ends it. Pi in Terminal shares
this sign-in, so signing out applies there too.

**Your own OpenAI or Anthropic account.** Turn on **Use my own online AI**, choose the provider, and enter a model ID
and your API key. The key is saved in your macOS Keychain. **Test and Save** sends one short test message, with no
files and nothing from your conversations. While the switch is on, your conversations and what you show Pippa go to
that service. **Remove** deletes the connection and the key. A custom OpenAI-compatible server set up in an earlier
version keeps working; new ones can't be added.

Web searches never go through a signed-in online AI.

## When Pippa goes online

| What | When |
|---|---|
| Downloading her AI | Once, after you say OK. The file comes from Hugging Face and is checked before use. |
| Update checks | Once a day, from this repository's releases. Updates install when you quit or after a while without input. |
| Web searches | The first search in an answer shows you the exact search text and waits for your OK. |
| Reading web pages | Pages from your own message or from that answer's search results are read without asking again. Any other address is asked for. Addresses on your Mac or your local network are never read. |
| Online AI | Only while you have it switched on (see above). |
| Commands that go online | Pippa's command-line helper asks before a command that goes online, such as downloading a file. |
| Mail, Calendar, Reminders, Photos | These are Apple's apps. They may sync through your accounts, such as iCloud or your mail server, as usual. |

Apart from the cases above, your files, conversations and Undo history stay on your Mac.

## What macOS asks for

macOS asks you the first time Pippa needs each kind of access. You can review and change it any time in **System
Settings → Privacy & Security**. In Pippa's Settings, **Permissions** shows what is allowed; when something was
denied, a blocked action offers **Open System Settings**.

| Access | What Pippa does with it |
|---|---|
| Desktop, Documents, Downloads | Reads and tidies files there when you ask. You can undo her changes. |
| Cloud folders and external drives | The same for iCloud Drive, OneDrive, Dropbox, Google Drive, USB sticks and external disks. |
| Calendar | Reads appointments for the period you ask about or for the morning overview, and adds events and deadlines when you ask, which she can remove again. |
| Reminders | Reads open and due reminders when you ask and for the morning overview; adds deadlines from your letters when you ask, and can remove them again. |
| Photos | Shows the matching photos from your library. She doesn't change or upload anything. |
| Contacts | Looks up addresses and phone numbers. She doesn't change them. |
| Automation (Mail, Excel and others) | Reads the email you selected in Mail and the table you're looking at in Excel, opens Numbers tables you give her, searches your photos and notes, and saves unsent drafts in Mail. |

## Why she runs outside the App Sandbox

Pippa runs outside Apple's App Sandbox so she can work with your folders and Mac apps; a sandboxed app couldn't, and it
couldn't set up and start Pi, her assistant core, in your home folder either. Released copies are signed with a
Developer ID and notarized by Apple. The app uses the Hardened Runtime with four extra rights: Automation, Calendars
(which covers Reminders), Photos and Contacts. The bundled Node.js that runs Pi has two more: just-in-time compilation
and loading code libraries not signed by Pippa's developer.

Instead of the App Sandbox, Pippa has her own controls:

- **A sandbox for her command line.** Pippa can run small utilities, for example to convert a file. These commands run
  inside a sandbox that macOS enforces. Without asking, they may read what you can read and write only in Pippa's
  working folder and temporary folders. Going online, or changing files in your own folders, needs your OK first;
  before an approved change, existing files get a backup copy. They can't delete files for
  good outside those folders, write to `~/Library` (except iCloud Drive and cloud folders), hidden folders such as
  `~/.ssh` or Pippa's own folder, or control other apps.
- **Fixed tools for Mac apps.** Changes to other apps go through three dedicated tools: add an event, add a reminder,
  save an unsent Mail draft. Her Mail tool only saves drafts; sending is up to you.
- **A read-only mode for drafts.** When she writes a draft into her own text field, such as a reply to a letter, she
  can only read: no file changes, no command line, no web, and no changes in other apps.
- **Your documents are data, not orders.** Files, emails and web pages she reads can't widen what she is allowed to do.
  Your personal Pi extensions, Pi project settings and context files in your folders don't join her sessions.
- **A record of what actually ran.** The "what happened" line under an answer comes from the tools that ran, not from
  the AI's wording.

This is not a guarantee that nothing can go wrong. Once you allow a command to go online, it can send what it was
given. Check results, especially for actions you didn't expect.

## Actions and Undo

- **When you ask for a specific action, she carries it out.** If you ask her to add a reminder or move a file, she does
  it without asking again. Tidy Up is different: you see the new folders first, and nothing moves until you say so.
- **Undo under the answer.** Moves, new files, files moved to the Trash and edited files are recorded, so **Undo**
  under the answer can take them back.
- **Copies before changes.** Before she edits or overwrites an existing file (up to 1 GB), a copy goes to
  `~/Library/Application Support/Pippa/Backups`. Copies are kept for 30 days, also when a task failed or you pressed
  Stop.
- **Limits.** If you change those files elsewhere afterwards, a safe restore may not be possible. Not every app action
  can be undone; check events, reminders and drafts in their apps.
- **Your originals stay unchanged** when she makes a PDF, a smaller copy, JPG or PNG copies, or an invoice spreadsheet.
  The results are new files.

## What she remembers

- **Facts you can check.** Settings → **What Pippa remembers** lists the facts she keeps about you; you can remove any of
  them. She keeps at most 30, and refuses account, card, ID, tax and phone numbers and passwords.
- **Stored on your Mac.** Facts, conversations, task records and the Undo history are stored on your Mac.
- **A log without contents.** The log in `~/Library/Logs/Pippa` records the version and events, not file contents.

## Where Pippa keeps things

| What | Where |
|---|---|
| Conversations, Undo history, task records, settings, backups, her AI (by default) | `~/Library/Application Support/Pippa` |
| Results, dropped mails and images, table copies | `~/Library/Caches/Pippa` |
| Her AI, if you already had a shared `~/models` folder | `~/models` |
| Preferences | `~/Library/Preferences/io.github.tschnorpfeil.pippa.plist` |
| Log | `~/Library/Logs/Pippa` |
| Pi, her assistant core, shared with Pi in Terminal | `~/.pi/agent` and `~/.local/share/pi-node` |

To open a hidden folder in Finder, choose **Go → Go to Folder…** (Shift-Command-G) and paste the path.

## Remove Pippa

1. Quit Pippa and move `Pippa.app` to the Trash.
2. Remove `~/Library/Application Support/Pippa`, `~/Library/Preferences/io.github.tschnorpfeil.pippa.plist`,
   `~/Library/Caches/Pippa`, `~/Library/Caches/io.github.tschnorpfeil.pippa` and `~/Library/Logs/Pippa`. From older versions, also remove
   `~/Library/Containers/io.github.tschnorpfeil.pippa`.
3. If her AI file is in `~/models`, remove it there as well.
4. Pippa set up Pi in `~/.pi/agent` and `~/.local/share/pi-node`. If you don't use Pi in Terminal yourself, you can
   remove both. If you do, remove only `~/.pi/agent/extensions/pippa-local-server` and the `pippa-local` entry (and
   `pippa-online`, if present) in `~/.pi/agent/models.json`.
5. Optionally, remove Pippa's entries in **System Settings → Privacy & Security**.
