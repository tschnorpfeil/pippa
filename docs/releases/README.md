# Release notes

One file per release, `<version>.md`, used as the body of the GitHub release. Everything on GitHub is in English
(see [CLAUDE.md](../../CLAUDE.md)); Pippa's German menus are not a reason for German release notes.

Every release starts with the same two paragraphs, so a first-time visitor knows what Pippa does, which Mac she needs
and which file to download before the AI download starts:

```markdown
# Pippa <version>

Pippa is a free Mac helper for paperwork and small chores. Drop a letter, a PDF, a folder or a few photos on her, or ask her something, and she hands back the result: one PDF ready to send, what a letter wants from you and by when, a tidy folder, a reply draft in Mail. Her built-in AI runs on your Mac: no account, no subscription.

**You need** a Mac with Apple silicon (M1 or later) and macOS 15 or later. **Download** `Pippa.dmg` below, open it and drag Pippa to Applications. Photo and PDF actions work before AI setup. For AI chat, Pippa asks before downloading about 3 to 17 GB, depending on your Mac's memory.

**New in Pippa <version>**

- **Short bold summary.** One or two plain sentences on what the person notices.
```

Name buttons and windows by their English label. Write for people who never open Terminal: no "model", "token" or
"prompt". "Free Mac helper" in the first paragraph is how Pippa introduces herself; never call her an "agent" or
mention a "pill", and say what she does instead. The HTML comment at the top of each file is a note for us and stays
invisible on GitHub.
