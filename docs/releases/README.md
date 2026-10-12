# Release notes

One file per release, `<version>.md`, used as the body of the GitHub release. Everything on GitHub is in English
(see [CLAUDE.md](../../CLAUDE.md)); Pippa's German menus are not a reason for German release notes.

Every release starts with the same two paragraphs, so a first-time visitor knows what Pippa does, which Mac she needs
and which file to download before the AI download starts:

```markdown
# Pippa <version>

Pippa is a small helper on your Mac's screen for everyday paperwork. Drop a letter, a PDF, a folder or a few photos on her: she explains what a letter wants from you and by when, makes PDFs smaller or combines them, and tidies up folders. The AI runs on your Mac, with no account and no subscription.

**You need** a Mac with Apple silicon (M1 or later) and macOS 15 or later. **Download** `Pippa.dmg` below, open it and drag Pippa to Applications. On first start she downloads her AI once (about 3 to 6 GB, depending on your Mac's memory).

**New in Pippa <version>**

- **Short bold summary.** One or two plain sentences on what the person notices.
```

Name buttons and windows by their English label. Write for people who never open Terminal: no "model", "token",
"prompt" or "agent". The HTML comment at the top of each file is a note for us and stays invisible on GitHub.
