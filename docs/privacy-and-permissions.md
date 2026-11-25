# Privacy and permissions

What Pippa reads, what goes online and when, what macOS lets her do, and how to take things back. For how it is
built, see [Developing Pippa](development.md); the website's [privacy policy](https://heypippa.app/datenschutz.html)
is in German.

## In short

- **Her AI runs on your Mac.** By default, her built-in AI reads your letters, PDFs and photos on your Mac. No Pippa
  account, no Pippa server, no tracking in the app.
- **Online AI only if you turn it on.** Connect one of Pi’s providers in Settings, choose a model, then press **Use [provider]**. While it's on, that service receives what you type. Anything from Mail, documents, Calendar, Reminders or Photos goes along only after Pippa shows you the provider and the exact text, and you press **Send**.
- **She acts, and you can take it back.** What Pippa can undo, she does without asking: an event, a reminder, an
  unsent draft, moving files or sorting mails into folders you already have. Under each answer one line says what she
  did, with one **Undo** for all of it.
- **She never sends anything without your click.** Before something leaves your Mac or cannot be taken back, a card
  shows exactly what happens, and nothing runs until you press its button. Mail, Calendar and Reminders may sync
  through your accounts, such as iCloud.
- **Online only where needed.** Downloads, updates and web lookups use the internet, and she asks before searching the
  web. The code is open source (MIT), so anyone can check.

## Where her AI runs

- **On your Mac, by default.** Pippa's AI runs in [oMLX](https://github.com/jundot/omlx) on your Mac. It only accepts
  connections from your own Mac and needs a key that Pippa keeps in her own folder. Which AI your Mac gets: [Pippa's local AI](models.md).
- **No account and no analytics.** Pippa has no sign-up and no server of her own, and the app collects no usage
  statistics. The website heypippa.app counts page visits and download clicks; the app does not.

## Online AI, only if you switch it on

Online AI is off until you turn it on in Settings. Only one online service can be on at a time: turning one on turns
the other off. Settings always says where Pippa's AI runs.

**Connect and choose.** Settings lists the providers, chat models, and authentication methods supported by the bundled
Pi release. Sign in in your browser or enter an API key, choose a model, and press **Use [provider]**. Connecting an
account alone does not activate online conversations. The screen names the recipient before activation.
**Use this Mac** turns online conversations off and keeps the provider connected.

**Credentials.** Pi manages new API keys and OAuth tokens in its credential file (`~/.pi/agent/auth.json`), shared
with Pi in Terminal. Before an online question, Pi renews an expiring sign-in in that shared store. The running answer gets a private copy of just that provider’s prepared access credentials, which Pippa removes when its Pi process ends. These credentials are not passed in command-line arguments.
**Disconnect** signs the provider out of Pi too; it does not revoke credentials at the provider or remove credentials
configured outside Pippa. Model catalogs can be refreshed without sending conversation contents.

**Existing connections.** A ChatGPT connection from an earlier Pippa release keeps working through Pi. Existing
OpenAI, Anthropic, and compatible-server connections keep their API keys in the macOS Keychain and use the previous
route until you choose a Pi provider. Pippa does not silently move those keys into Pi’s credential file. The existing
connection’s **Remove** action deletes its Keychain entry.

Web searches never go through a signed-in online AI.

## What an online AI gets

An online AI can't read anything on your Mac by itself. It has no access to your files, folders, Mail, Calendar,
Reminders, Photos, the app in front or Pippa's command line, and it never gets your personal notes or Pippa's working
folder. What it receives:

- **What you type**, as you typed it.
- **What you checked and shared.** Attach files, or choose **+ → Selected Email in Mail**, **Calendar, Next 7 Days**
  **Open Reminders**, or **Photo from Photos…**. Pippa reads them on your Mac and shows a review: which provider gets it, your message, and
  each part's text with where it came from. You can edit the text or leave a part out; only what the review shows goes
  out when you press **Send to [provider]**. A picture is never sent, only the text Pippa recognized in it.
  **Cancel** keeps your edits in that conversation while Pippa is open. Choose **Continue Checking…** to resume.
- **Follow-up questions.** Ordinary typed messages share history within the same conversation and provider account.
  Each message you approve in the review starts a separate provider session. To ask about the same excerpt again,
  include it in a new review. Switching back to the Mac resumes the local history.
- **Public web pages**, when web search is on for the online AI. The first search in a conversation asks you. Each answer
  opens pages in a fresh browser session with an empty cookie store. To work with a signed-in page, use the AI on this Mac.

**Choose per source.** In Settings under **AI → Sharing with online AI**, set Mail, Documents, Calendar, Reminders and
Photos each to **Ask before sharing** (the default) or **Only on this Mac**. A source on **Only on this Mac** is never
offered in the review, and the online AI can't add events, reminders or Mail drafts for it either. With an online AI
on, it can still add an event or a reminder, or save a new unsent Mail draft, from what you wrote; it doesn't see your
calendar, your lists or your inbox for that.

**One question while using this Mac.** After you switch back with **Use this Mac**, the chat offers **Ask
[provider]…**: it opens the same review with your message, your attached files and Pippa's last answer here, which
names what that answer read. That one question goes to the provider in a fresh conversation; the next question goes
to the AI on this Mac again. Settings → AI → **Single questions** removes the provider from there.

If the online AI changes while a review is open, nothing is sent and Pippa asks you to check again. An answer that
failed is never sent again on its own: **Try again** opens the review.

**Mac access, only if you allow it.** For the online AI you use, Settings → AI → **Allow Mac access** gives it the same
Mac tools as the AI on this Mac: files, Pippa's command line, Mail, Calendar, Reminders and Photos, without the review. It then acts by the same rules as the AI on this Mac (see
[Actions and copies](#actions-and-copies)).
What those tools read, files you attach, the app in front and, with personal notes on, your notes then go to that
provider. Direct file attachments also bypass the review; the source rules still apply to explicitly reviewed excerpts,
such as **Selected Email in Mail** in the + menu. Pippa still asks before each command that goes online, before a
command that changes your files, and before sending a mail. macOS still asks for each app, and app control from the
command line stays off. It is off by default and holds only for the provider, model and account it
was turned on for: another account, key, address or model, signing out, or turning it off returns to the limits above.
Conversations with Mac access keep their own provider session, so that history never reaches a limited session, another
account or the AI on this Mac. Changes apply to the next question; an answer already running keeps its original access
until it finishes or you press Stop. Messages you approve in a review and single questions keep the limits.

## When Pippa goes online

| What | When |
|---|---|
| Downloading her AI | Once, after you say OK. The model comes from Hugging Face (or, when that fails, from a copy in this repository's releases), the runtime that runs it (Python with oMLX) from this repository's releases; each file is checked before use. |
| Update checks | Once a day, from this repository's releases. Updates install when you quit or after a while without input. |
| Web searches | The first search in a conversation shows you the exact search text and waits for your OK. Your OK covers later searches in that conversation; a new conversation asks again. |
| Reading web pages | Pages from your own message or from that answer's search results are read without asking again. Any other address is asked for. Addresses on your Mac or your local network are never read. |
| Pippa's browser | With the AI on this Mac, Pippa opens a page that needs clicking through in a browser panel in her window; open the window (from Pippa Island: **Open Pippa**) to watch along or to sign in. She asks before each new website and before every click, typed text or choice. A whole form is one question that lists every value she will type or choose and where the form goes. Following a plain link to another page of the website she is on, once you allowed that website in the same answer, doesn't ask again: it opens that address, the same as if she had opened it herself. Links with extra parameters in the address, links to other websites and buttons still ask. Sign-ins, passwords, codes and "I'm not a robot" checks are left to you; she never asks for your password. Cookies and sign-ins stay on your Mac. Addresses on your Mac or your local network are never opened. |
| Provider setup | Browser sign-in, credential setup, and model catalog refresh when requested in Settings. No conversation contents. |
| Online AI | Only while you have it switched on, or for one question you sent with **Ask [provider]…**: what you typed and what you checked and shared (see above). When it says "too many requests", Pippa waits 15, 30, 60 and 60 seconds, shows the countdown and continues. If it is still at its limit, the answer ends with **Continue**, which you can press after a minute. A used-up allowance is named as such. |
| Commands that go online | Pippa's command-line helper asks before each command that goes online, such as downloading a file. A yes covers that one command. |
| Sending a mail | Only a draft Pippa saved in this conversation, after a card that shows recipient, subject and text, and only when you press **Send**. Mail then sends it through your account. |
| Mail, Calendar, Reminders, Photos | These are Apple's apps. They may sync through your accounts, such as iCloud or your mail server, as usual. |

Apart from the cases above, your files and conversations stay on your Mac.

## What macOS asks for

macOS asks you the first time Pippa needs each kind of access. You can review and change it any time in **System
Settings → Privacy & Security**. In Pippa's Settings, the **Permissions** page lists Calendar, Reminders, Mail, Photos
and Files & Folders with their state, read without asking macOS, and opens the matching place in System Settings. When
something was denied, a blocked action offers **Open System Settings** too.

| Access | What Pippa does with it |
|---|---|
| Desktop, Documents, Downloads | Reads, renames and moves files there when you ask. Removed files go to the Trash. |
| Cloud folders and external drives | The same for iCloud Drive, OneDrive, Dropbox, Google Drive, USB sticks and external disks. |
| Calendar | Reads appointments for the period you ask about, and adds events and deadlines when you ask. |
| Reminders | Reads open and due reminders when you ask; adds reminders and deadlines from your letters when you ask. |
| Photos | Shows the matching photos from your library. She doesn't change or upload anything. |
| Automation (Mail and others) | Searches and reads your mail and lists your Mail folders, reads what's open in the app in front when you ask about it, saves unsent drafts, moves inbox mails into existing folders, and sends a draft after you press **Send** on its card. |
| Accessibility | Only when you ask about the app in front and it can't hand over its content any other way: Pippa reads the text its front window hands to Accessibility, which can include text scrolled out of view. Read only: she never clicks, types or changes anything there, and skips password fields. Pippa explains this before macOS asks. |

## Why she runs outside the App Sandbox

Pippa runs outside Apple's App Sandbox so she can work with your folders and Mac apps; a sandboxed app couldn't, and it
couldn't set up and start Pi, her assistant core, in your home folder either. Released copies are signed with a
Developer ID and notarized by Apple. The app uses the Hardened Runtime with three extra rights: Automation, Calendars
(which covers Reminders) and Photos. The bundled Node.js that runs Pi has two more: just-in-time compilation
and loading code libraries not signed by Pippa's developer.

Instead of the App Sandbox, Pippa has her own controls:

- **A sandbox for her command line.** Pippa can run small utilities, for example to convert a file. These commands run
  inside a sandbox that macOS enforces. Without asking, they may read what you can read and write only in Pippa's
  working folder and temporary folders. Each command that goes online needs your OK first. A yes covers that one
  command, not the rest of the answer. Changing files in your own folders needs your OK once per answer, and existing
  files the command names get a backup copy first. They can't delete files for
  good outside those folders, write to `~/Library` (except iCloud Drive and cloud folders), hidden folders such as
  `~/.ssh` or Pippa's own folder, or control other apps. On a Mac without Apple's developer tools, they never start
  python3, git or the other placeholders that would only open Apple's install dialog.
- **Fixed tools for Mac apps.** Changes to other apps go only through dedicated tools: add an event, add a reminder,
  save an unsent Mail draft, move inbox mails into an existing folder, and send one saved draft. Each tool has a fixed
  class: it only reads, changes something Pippa can undo, cannot be undone, or leaves this Mac. The last two run only
  after you press the button on a card. The app checks this in code. No AI decides it, and nothing an AI writes can
  press the button.
- **Your documents are data, not orders.** Files, emails and web pages she reads can't widen what she is allowed to do.
  Your personal Pi extensions, Pi project settings and context files in your folders don't join her sessions.
- **A record of what actually ran.** The "what happened" line under an answer comes from Pippa's own record and the
  checks against Mail, Calendar, Reminders and your files, not from the AI's wording.

This is not a guarantee that nothing can go wrong. Once you allow a command to go online, it can send what it was
given. Check results, especially for actions you didn't expect.

## Actions and copies

- **She does what can be undone without asking.** Up to 0.8, Pippa carried out the specific action you asked for. From
  1.0 she also takes the undoable steps your request implies. "Tidy my inbox" moves mails into your existing folders.
  "Prepare tomorrow" may add a reminder. This holds for the AI on this Mac and for an online AI with **Allow Mac
  access**. An online AI without it keeps the limits above.
- **She always asks first** before anything that cannot be undone or that leaves your Mac: sending a mail, a command
  that goes online, the first web search in an answer, each new website, each click and each form in her browser. A command that changes files in your
  own folders asks too, because Pippa can only copy the files it names. She cannot delete files for good, pay, or
  create mail folders.
- **Mail moves are checked.** Pippa moves mails only from the inbox into an existing folder of the same account, never
  into Trash, Junk, Sent or Drafts. She shows a dry run first, then moves in small batches and looks for each mail in
  its new folder by its Message-ID. If a mail does not show up there, she stops, moves nothing more and tells you which
  mails to check.
- **One record per answer.** Every change is written down before it starts and checked against Mail, Calendar,
  Reminders or the file afterwards. Under the answer one line says what was done and checked, with one **Undo** for the
  whole answer. Undo leaves alone what you changed since. If Pippa was interrupted in the middle, the line says
  "unclear, please check" and she does not repeat that step. Records are kept for 30 days. Web searches, pages she read
  and personal notes are not part of it.
- **Copies before changes.** Before she edits or overwrites an existing file (up to 1 GB), a copy goes to
  `~/Library/Application Support/Pippa/Backups`. Copies are kept for 30 days, also when a task failed or you pressed
  Stop. Moves never overwrite another file, and a file she removes goes to the Trash.
- **Your originals stay unchanged** when she makes a PDF from your photos or scans. The result is a new file.

## What she remembers

- **Facts you can check.** She keeps the facts you tell her about yourself in `memory.md` in her folder; ask her to
  forget one, or edit the file. She keeps at most 30, and refuses account, card, ID, tax and phone numbers and passwords.
  Only the AI on this Mac uses them; an online AI gets them only with **Allow Mac access**.
- **Stored on your Mac.** Facts, conversations and task records are stored on your Mac.
- **A log without contents.** The log in `~/Library/Logs/Pippa` records the version and events, not file contents.

## Where Pippa keeps things

| What | Where |
|---|---|
| Conversations, task records, settings, backups, her AI and its runtime | `~/Library/Application Support/Pippa` |
| Results, dropped mails and images, table copies | `~/Library/Caches/Pippa` |
| Preferences | `~/Library/Preferences/io.github.tschnorpfeil.pippa.plist` |
| Log | `~/Library/Logs/Pippa` |
| Pi, her assistant core, shared with Pi in Terminal | `~/.pi/agent` and `~/.local/share/pi-node` |

To open a hidden folder in Finder, choose **Go → Go to Folder…** (Shift-Command-G) and paste the path.

## Remove Pippa

1. Quit Pippa and move `Pippa.app` to the Trash.
2. Remove `~/Library/Application Support/Pippa`, `~/Library/Preferences/io.github.tschnorpfeil.pippa.plist`,
   `~/Library/Caches/Pippa`, `~/Library/Caches/io.github.tschnorpfeil.pippa` and `~/Library/Logs/Pippa`. From older versions, also remove
   `~/Library/Containers/io.github.tschnorpfeil.pippa`.
3. Versions before the switch to oMLX may have put an AI file (`.gguf`) in `~/models`; remove it there as well.
4. Pippa set up Pi in `~/.pi/agent` and `~/.local/share/pi-node`. If you don't use Pi in Terminal yourself, you can
   remove both. If you do, remove only `~/.pi/agent/extensions/pippa-local-server` and the `pippa-local` entry (and
   `pippa-online`, if present) in `~/.pi/agent/models.json`.
5. Optionally, remove Pippa's entries in **System Settings → Privacy & Security**.
