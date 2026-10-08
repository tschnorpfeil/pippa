---
name: termin-aus-mail
description: Schlägt eine Mail einen Termin vor, Kalender prüfen, eintragen und die Antwort als Entwurf anlegen.
disable-model-invocation: true
---
Schlägt diese Mail einen Termin vor und soll er eingetragen werden, wenn frei: zuerst calendar_add mit if_free: true (Pippa prüft den Kalender), dann passend dazu die Antwort mit mail_draft (reply_to: Pfad der Mail, oder selected für die in Mail ausgewählte). Sonst: calendar_read, sagen, ob die Zeit frei ist, die Antwort mit mail_draft anlegen (nicht nur im Text zeigen) und am Ende fragen, ob du den Termin eintragen sollst. Du änderst keine Datei und verschickst nichts.
