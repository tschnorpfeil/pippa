# Nachmessung neue Sprachzeile (PR #11) — 10.10.2026

Branch `claude/project-thread-fej234` (Prompt-Stand 8779859 = 47021a4), Runtime ohne Guard (`runtime/pippa-tools`:
pippa-tools, pippa-assist, pippa-mcp). Sonst wie die Hauptmessung (`../README.md`): gleicher gepatchter llama-server,
ctx 32768, Fake-HOME, Mock-MCP. Web-Erweiterung (`pippa-web`) nicht geladen (bräuchte npm-Download; keine der vier
Aufgaben nutzt das Web, A und B gleich). Je Aufgabe 3 Läufe, A und B abwechselnd, frischer Server je Block.

Neue Zeilen: DE „Antworte in der Sprache der Frage, nicht der Dokumente: … mit du (nie Sie) …“,
EN „Answer in the question's language, not the documents': …; in German du, never Sie.“ Für die englischen Fragen
gilt (wie in der Hauptmessung) der englische Prompt, geprüft in `raw/first-request-*-en-summary.json`.

## Ergebnis

| | A K2 vorher | A K2 neu | B Qwen vorher | B Qwen neu |
|---|---|---|---|---|
| Englische Frage → englische Antwort | 4/6 | **0/6** | 1/6 | **0/6** |
| zusammenfassen (DE): du-Antworten | 1/3 | 2/3 | 0/3 | 2/3 |
| ja/teilweise/nein, 4 Aufgaben × 3 | 3/8/1 | 2/10/0 | 4/8/0 | 2/9/1 |

- **Regression:** Mit der neuen Zeile antworten beide Modelle auf **alle** englischen Fragen deutsch (meist mit Sie).
  Vorher schaffte K2 4/6. Vermutung: Der englische Prompt nennt jetzt ausdrücklich „German … du“ und zieht so
  Richtung Deutsch; nicht gegengeprüft.
- **du/Sie bei deutschen Fragen besser:** zusammenfassen jetzt je 2/3 mit du (vorher K2 1/3, Qwen 0/3).
  Mail-Entwürfe an die Hausverwaltung siezen zu Recht.
- **Erfolg:** Kein Fortschritt; die englischen Aufgaben fallen wegen der Sprache auf „teilweise“. Qwen r2 en-multi: 48
  Werkzeugaufrufe (las jede Datei, 300 s), falsche Summe, kein Schleifenstopp. Mail-Antwort: beide setzen `reply_to`
  oft falsch (Mailtext bzw. Absenderadresse statt `selected`).

Bewertungen mit Begründung: `grades.json`; Rohdaten: `raw/` (Antworten, Zeiten, Werkzeugaufrufe, Server-Logs).

## Gegenprobe: englische Zeile ohne Deutsch-Halbsatz (351211a) — 10.10.2026

Branch-Stand 2fb6ca7 (main gemergt), englischer Prompt: „Answer in the question's language, not the documents': calm,
friendly, plain words.“ Nur en-multi und en-summary, je 3× A und B abwechselnd. Der Lauf wartete ~25 min, bis ein
llama-server eines anderen Threads fertig war. Rohdaten: `raw-en2/`.

| Englische Frage → englische Antwort | K2 | Qwen |
|---|---|---|
| alte Zeile („in the person's language“) | 4/6 | 1/6 |
| mit „in German du, never Sie“ | 0/6 | 0/6 |
| ohne Deutsch-Halbsatz | 3/6 | 1/6 |

- Der Deutsch-Halbsatz war die Ursache der Regression: ohne ihn ist K2 wieder etwa auf dem alten Stand.
- **Qwen bleibt bei 1/6:** Bei deutschen Dokumenten antwortet Qwen auf Deutsch, egal welche dieser Prompt-Zeilen.
  Das lässt sich mit einer Zeile im System-Prompt nicht beheben.
- Inhaltlich (Rubrik ohne Sprachabzug): 11/12 richtig; K2 r2 en-multi deutete „bezahlt“ als „nur eine Rechnung als
  bezahlt markiert“.
