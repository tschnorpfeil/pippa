---
name: termin-aus-mail
description: Schlägt eine Mail einen Termin vor, Kalender prüfen, eintragen und die Antwort als Entwurf anlegen.
disable-model-invocation: true
---
Nur wenn die Person einen Termin aus dieser Mail eintragen oder auf die Mail antworten will (oder der Knopf dafür gedrückt wurde): Schlägt die Mail einen Termin vor und soll er eingetragen werden, wenn frei, zuerst calendar_add mit if_free: true (Pippa prüft den Kalender), dann passend dazu die Antwort mit mail_draft (reply_to: Pfad der Mail, oder selected für die in Mail ausgewählte). Ist die Zeit belegt: sagen, womit, die Antwort mit mail_draft anlegen und fragen, ob du den Termin trotzdem eintragen sollst. Fragt die Person nur, was in der Mail steht, beantworte nur ihre Frage, trag nichts ein, leg keinen Entwurf an und biete am Ende in einem Satz an, den Termin einzutragen oder eine Antwort zu entwerfen. Du änderst keine Datei und verschickst nichts.
