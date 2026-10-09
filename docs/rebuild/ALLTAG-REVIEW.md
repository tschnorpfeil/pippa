# Alltagsnutzen — kurze Rangliste

09.10.2026. Produkturteil für Menschen ohne Technikkenntnisse, keine gemessene Nutzungsstatistik.
Priorität = geschätzte Häufigkeit × bisheriger Aufwand für die Person (je 1–5). Technischer Aufwand extra.

| Rang | Alltag / Ergebnis | H × A | Umsetzung mit Pi / vorhandener Pippa-Fähigkeit |
|---|---|---:|---|
| 1 | „Wo ist die Rechnung?“ → anklickbare Funde, Suchumfang und Lücken klar | 5 × 4 = 20 | Neuer Spotlight-Skill, vorhandene Pi-Skill-Ladung; kein App-Suchsystem. Kleiner Aufwand. |
| 2 | Brief verstehen → „Das musst du tun, bis dann, so viel kostet es“ mit Fundstelle | 4 × 4 = 16 | `brief-verstehen`, `read_document`, vorhandene PDF-Vorschau. Kleiner Aufwand für klare Darstellung; klickbare zitierte Fundstellen innerhalb des Dokuments sind noch offen. |
| 3 | Antwort/Kündigung formulieren → prüfbarer Entwurf mit echten Angaben oder Platzhaltern | 4 × 3 = 12 | `antwort-schreiben`, Pi + unsent `mail_draft`; Kopieren schon möglich. Kleiner Aufwand. |
| 4 | Frist/Termin aus Brief oder Mail → konkreter Vorschlag, Eintrag, Rückgängig | 3 × 4 = 12 | `fristen-erkennen`, `termin-aus-mail`, Kalender-/Erinnerungswerkzeuge. Kleiner Aufwand; Quelle und Datum müssen sichtbar bleiben. |
| 5 | Steuerunterlagen sammeln → Fundliste, anschließend Rechnungstabelle auf Wunsch | 2 × 5 = 10 | Spotlight-Skill + `rechnung-auslesen`, Pis `write` für CSV. Mittlerer Aufwand: Vollständigkeit ehrlich benennen, keine Garantie „alles gefunden“. |
| 6 | Downloads ordnen → verständliche Vorher/Nachher-Vorschau, dann Rückgängig | 2 × 4 = 8 | `list_folder`, `move_files` und vorhandene Vorschau/Undo. Kleine UI-Arbeit; keine neue Ordner-Engine. |

Drei UI-Prioritäten: ein wahrer Statussatz statt überlappender „Bereite …“-/Schrittzeilen; Ergebnisse mit direktem Öffnen/Kopieren/Rückgängig; bei Fehlern Grund, Teilresultat und passender nächster Schritt. Keine zusätzlichen Menüs, Router oder Planansichten. Lange Wartezeit bleibt das größte praktische Hindernis; die offenen Kaltstart- und Kontextmessungen bleiben in TASKS.md.
