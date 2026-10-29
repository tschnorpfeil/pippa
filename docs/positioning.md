# Positioning: what Pippa promises and how we say it

Decision record · 28 October 2026 · Applies to the README, heypippa.app, release notes and launch posts

**Headline: "The AI assistant that actually gets things done." / „Die KI-Assistentin, die wirklich was erledigt."** (chosen 29 October 2026, replacing "Paperwork on your Mac? Done."; the promise below is unchanged) Pippa is the free Mac helper that turns
paperwork into a finished result: photos become one PDF ready to send, a German letter is explained with what it wants,
by when and the sentence that says so, Downloads get a tidy folder, a reply waits as a draft in Mail. The PDF jobs work
before any AI download, and her built-in AI runs on the Mac with no account.

## Why this hook

- **"Private, on-device AI" is no longer ours to win.** In October 2026 Hob (Frigade, free and MIT, Mac, Windows and
  Linux), Underdog (Conway Research, invite-only beta) and Apple Intelligence all lead with it. A privacy headline makes
  Pippa look like a smaller version of them. Privacy stays the proof line ("Her built-in AI runs on your Mac"), not the
  headline.
- **Finished results are an open position.** Local AI apps mostly stop at a chat window; cloud assistants want the letter
  on their servers. Nobody leads with the PDF, the deadline sentence or the tidied folder, and nobody gives the first
  result before the AI download.
- **The first audience searches for jobs, not AI**: „Brief vom Finanzamt verstehen", „Fotos zu PDF Mac",
  „PDF verkleinern". The question H1 passes the five-second test without knowing what Pippa is, keeps "AI" out of the
  first words for AI-wary readers and does not depend on the pill or the window layout.
- **Do not fight on feature count.** Hob has form filling, charts, image understanding, dictation and 32 languages. Pippa
  wins on what she leaves behind in the Mac's own apps and on German paperwork. Never claim a rival lacks something
  without checking it on the day.
- **Keep ChatGPT users.** "Keep ChatGPT if you like it: Pippa can use your subscription as her online AI."

## Words

| Use | Avoid in public copy |
|---|---|
| "helper" / „Helferin" | "agent", "pill", "LLM", "model", "token", "prompt" |
| "Her built-in AI runs on your Mac" / „Pippas KI läuft auf deinem Mac" | "private" in an H1 or tagline; "offline"; "nothing leaves your Mac" |
| "under 100 MB" for the DMG (80.7 MB for 0.3.16; recheck each release) | static version or size badges |
| "AI assistant", "local AI" only in `<title>`, meta, the GitHub description and topics | "Ihre KI" at the start of a German sentence (reads as formal „Sie") |

The site's banned-phrase list in `scripts/check-site.cjs` stays the source of truth for absolute claims.

## Copy in use

| | English | German |
|---|---|---|
| Eyebrow | Your free helper for the Mac | Deine kostenlose Helferin für den Mac |
| H1 | The AI assistant that actually gets things done. | Die KI-Assistentin, die wirklich was erledigt. |
| Subhead | Photos turn into one PDF ready to send, a German letter into plain words with its deadline, a messy Downloads folder into order. Her AI runs on your Mac. | Aus Fotos wird ein versandfertiges PDF, aus Amtsdeutsch Klartext samt Frist, aus Download-Chaos Ordnung. Pippas KI läuft auf deinem Mac. |
| First use | Give Pippa a few photos: the PDF is ready before you download any AI. | Gib Pippa ein paar Fotos: Das PDF steht, bevor du überhaupt eine KI lädst. |
| Product Hunt | Paperwork on your Mac? Drop it on Pippa. Done. | |
| GitHub description | Free Mac helper with local AI: photos to one PDF, German letters explained, tidy folders, Mail drafts. MIT, no account | |

GitHub topics: `macos`, `macos-app`, `swift`, `swiftui`, `apple-silicon`, `local-ai`, `local-llm`, `llm`, `llama-cpp`,
`ai-assistant`, `on-device-ai`, `pdf`, `ocr`, `paperwork`, `productivity`, `apple-mail`, `reminders`, `german`,
`privacy`, `open-source`. Remove `offline`: web lookups, updates and the optional online AI make it untrue.

## Launch gates

Do not post to Show HN, Product Hunt or Reddit until all of these hold:

1. A real 15–20 second recording with made-up files replaces the scripted GIF at the top of the README (letter with
   deadline and quoted sentence, then photos to one PDF within a 10 MB target).
2. The 8 GB and 16 GB tiers have run on physical Macs, together with a fresh permission profile.
3. Five German letters with the English interface come back with English answers; otherwise the English copy keeps
   "Answers may be in German."
4. The comparison table's rival cells are rechecked and dated.
5. The DMG is English-neutral with an "Applications" link and a guaranteed Finder layout.
6. The app uses one English name for the folder action ("Tidy Up" on the line, "Organize" in the sheet today).
7. `node scripts/check-site.cjs && node scripts/check-site-launch.cjs` pass, and the repository description and topics
   are updated.

## Launch posts

- **Show HN:** "Show HN: Pippa – a native Mac helper for paperwork, with local AI (MIT)". First comment: why (German
  letters carry tax IDs; something to install for parents), the three jobs, what is different (first result before any
  AI download, llama.cpp with Pi as the agent core, reuse of LM Studio/Ollama/Hugging Face files, Mail drafts never
  sent, optional ChatGPT sign-in), honest limits, and the question "which chore should she finish next?". Post Tuesday
  to Thursday, US morning, and stay in the thread.
- **Product Hunt:** 30–60 s silent video whose first frame is the letter answer with its quoted sentence. Maker comment
  under 200 words; ask for feedback, not upvotes. Launch 12:01 AM PT.
- **r/macapps:** free, native, first job needs no AI at all; disclose being the maker. Later r/LocalLLaMA (tier picks,
  llama.cpp, file reuse) and German subreddits only after gate 3.
- **AlternativeTo:** list as an alternative to Apple Intelligence, ChatGPT, Claude, Hob, Jan, LM Studio, Ollama, Msty,
  Elephas, and for PDF searchers Smallpdf and iLovePDF. Do not tag "Works offline".
