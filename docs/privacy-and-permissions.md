# Privacy and permissions

What Pippa reads, what goes online and when, what macOS lets her do, and how to take things back. For how it is
built, see [Developing Pippa](development.md); the website's [privacy policy](https://heypippa.app/datenschutz.html)
is in German.

## In short

- **Her AI runs on your Mac.** By default, her built-in AI reads your letters, PDFs and photos on your Mac. No Pippa
  account, no Pippa server, no tracking in the app.
- **Online AI only if you turn it on.** Connect one of Pi’s providers in Settings, choose a model, then press **Use [provider]**. While it's on, that service receives what you type. Anything from Mail, documents, Calendar, Reminders or Photos goes along only after Pippa shows you the provider and the exact text, and you press **Send**.
- **She never sends your mail.** Replies wait as unsent drafts in Apple Mail, and events and reminders go into Calendar
  and Reminders. Those apps may sync through your accounts, such as iCloud.
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
- **Public web pages**, when web search is on for the online AI. The first search in an answer asks you. Each answer
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

## When Pippa goes online

| What | When |
|---|---|
| Downloading her AI | Once, after you say OK. The model comes from Hugging Face (or, when that fails, from a copy in this repository's releases), the runtime that runs it (Python with oMLX) from this repository's releases; each file is checked before use. |
| Update checks | Once a day, from this repository's releases. Updates install when you quit or after a while without input. |
| Web searches | The first search in an answer shows you the exact search text and waits for your OK. |
| Reading web pages | Pages from your own message or from that answer's search results are read without asking again. Any other address is asked for. Addresses on your Mac or your local network are never read. |
| Pippa's browser | With the AI on this Mac, Pippa opens a page that needs clicking through in a browser panel in her window; open the window (from Pippa Island: **Open Pippa**) to watch along or to sign in. She asks before each new website and before every click, typed text or choice. Sign-ins, passwords, codes and "I'm not a robot" checks are left to you; she never asks for your password. Cookies and sign-ins stay on your Mac. Addresses on your Mac or your local network are never opened. |
| Provider setup | Browser sign-in, credential setup, and model catalog refresh when requested in Settings. No conversation contents. |
| Online AI | Only while you have it switched on, or for one question you sent with **Ask [provider]…**: what you typed and what you checked and shared (see above). |
| Commands that go online | Pippa's command-line helper asks before a command that goes online, such as downloading a file. |
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
| Automation (Mail and others) | Searches and reads your inbox in Mail, reads what's open in the app in front when you ask about it, and saves unsent drafts in Mail. |
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
  working folder and temporary folders. Going online, or changing files in your own folders, needs your OK first;
  before an approved change, existing files get a backup copy. They can't delete files for
  good outside those folders, write to `~/Library` (except iCloud Drive and cloud folders), hidden folders such as
  `~/.ssh` or Pippa's own folder, or control other apps. On a Mac without Apple's developer tools, they never start
  python3, git or the other placeholders that would only open Apple's install dialog.
- **Fixed tools for Mac apps.** Changes to other apps go through three dedicated tools: add an event, add a reminder,
  save an unsent Mail draft. Her Mail tool only saves drafts; sending is up to you.
- **Your documents are data, not orders.** Files, emails and web pages she reads can't widen what she is allowed to do.
  Your personal Pi extensions, Pi project settings and context files in your folders don't join her sessions.
- **A record of what actually ran.** The "what happened" line under an answer comes from the tools that ran, not from
  the AI's wording.

This is not a guarantee that nothing can go wrong. Once you allow a command to go online, it can send what it was
given. Check results, especially for actions you didn't expect.

## Actions and copies

- **When you ask for a specific action, she carries it out.** If you ask her to add a reminder or move a file, she does
  it without asking again. Moves never overwrite another file, and a file she removes goes to the Trash.
- **Copies before changes.** Before she edits or overwrites an existing file (up to 1 GB), a copy goes to
  `~/Library/Application Support/Pippa/Backups`. Copies are kept for 30 days, also when a task failed or you pressed
  Stop.
- **Limits.** Events, reminders and drafts she adds stay in their apps; check them there and remove them there if
  needed.
- **Your originals stay unchanged** when she makes a PDF from your photos or scans. The result is a new file.

## What she remembers

- **Facts you can check.** She keeps the facts you tell her about yourself in `memory.md` in her folder; ask her to
  forget one, or edit the file. She keeps at most 30, and refuses account, card, ID, tax and phone numbers and passwords.
  Only the AI on this Mac uses them; an online AI never gets them.
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
