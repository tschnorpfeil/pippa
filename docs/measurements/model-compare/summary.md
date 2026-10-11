| Metric | A k2-horizon-7b medium | B qwen3.5-9b-q4 medium | C qwen3.5-9b-q4 off |
|---|---|---|---|
| Agentic success yes/partial/no | 16/13/1 of 30 | 17/12/1 of 30 | 9/8/13 of 30 |
| Loops / aborts | 1 | 0 | 0 |
| HTTP errors (template) | 0 | 0 | 0 |
| Invented facts (manual) | 8 | 2 | 2 |
| Tool calls per task | 2 (1–24) | 2 (0–8) | 1 (0–21) |
| First word cold, s | 12.4 (4.9–48.1) | 17.0 (14.8–42.3) | 6.5 (3.9–6.7) |
| First word warm, s | 31.3 (3.7–93.5) | 13.4 (2.1–44.9) | 0.5 (0.3–6.3) |
| Total per task warm, s | 48.8 (13.4–419.7) | 22.7 (8.0–74.8) | 14.7 (2.0–83.9) |
| Total per task all, s | 48.0 (13.4–419.7) | 27.8 (8.0–74.8) | 15.4 (2.0–83.9) |
| Server load, s | 1.8 (1.5–2.0) | 1.8 (1.5–2.0) | 0.8 (0.8–0.8) |
| llama-server peak RSS, MB | 9284 (8671–10156) | 7988 (7586–9005) | 9527 (7763–9606) |
| llama-server footprint, MB | 4824 (4481–5745) | 3217 (2492–3597) | 4148 (1190–4190) |
| Pi peak RSS, MB | 135 (103–137) | 135 (122–137) | 135 (134–137) |
| File search 6 (per round) | 6 / 6 / 6 | 6 / 6 / 6 | 6 / 6 / 5 |
| Tool choice 25 (per round) | 25 / 25 / 25 | 25 / 25 / 25 | 21 / 22 / 21 |
| r7 first word, s | 13.8 (5.8–20.4) | 7.5 (2.4–18.5) | 0.7 (0.5–3.8) |
| r7 total, s | 18.9 (7.7–28.4) | 11.3 (4.4–21.6) | 5.2 (2.4–9.3) |
| Blind language rating, German questions (1–5) | 2.88 (n 24) | 3.83 (n 24) | 3.79 (n 24) |
| Blind language rating, all incl. English (1–5) | 2.90 (n 30) | 3.43 (n 30) | 3.43 (n 30) |

Per task (yes/partial/no over rounds):

| Task | A | B | C |
|---|---|---|---|
| multi-rechnungen | ✓ ✓ ✓ | ✓ ✓ ✓ | ✓ ✓ ✓ |
| vergleich | ✓ ✓ ✓ | ✓ ✓ ✓ | ✗ ✗ ✗ |
| zusammenfassen | ~ ~ ~ | ~ ✓ ~ | ~ ✓ ✓ |
| ordner-ueberblick | ~ ✓ ~ | ✓ ~ ✓ | ✓ ~ ✓ |
| web-recherche | ✓ ✓ ✓ | ✓ ✓ ✓ | ✗ ✗ ~ |
| web-plus-datei | ~ ~ ~ | ✗ ~ ~ | ✗ ✗ ~ |
| mail-antwort | ~ ~ ✗ | ✓ ~ ✓ | ✓ ✗ ✗ |
| termin | ✓ ✓ ✓ | ✓ ~ ✓ | ✗ ✓ ✗ |
| en-multi | ✓ ✓ ~ | ~ ✓ ~ | ~ ✗ ✗ |
| en-summary | ~ ~ ✓ | ~ ~ ~ | ~ ~ ~ |
