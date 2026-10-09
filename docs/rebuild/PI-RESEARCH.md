# Pi-Bestand für Werkzeugwahl und Dateisuche

Geprüft 09.10.2026 gegen das gebündelte Pi 1.1.0 (abe508e), nicht gegen eine ungetestete neue Version.

- [Skills](https://github.com/earendil-works/pi/blob/main/packages/coding-agent/docs/skills.md): Name/Beschreibung/Pfad automatisch im Prompt; vollständige Anleitung erst per `read`. Skripte gehören in den Skill. `disable-model-invocation: true` versteckt den Skill vor automatischer Wahl; `/skill:name` funktioniert weiter.
- [Extensions](https://github.com/earendil-works/pi/blob/main/packages/coding-agent/docs/extensions.md): `prepareLoadout`, `--tools` und `setActiveTools` steuern Deklarationen. Kein eigener Werkzeug-Router nötig. MCP kann direkt oder über Codemode exponiert werden. Codemode fügt für diesen kleinen Alltagsumfang eine weitere Entscheidung/Skriptsprache hinzu; hier nicht ungeprüft umstellen.
- [Pakete](https://pi.dev/packages): `pi-web-access` wird schon genutzt. Die [Pi-Sammlung](https://github.com/badlogic/pi-skills) bietet Web, Browser, Google-Mail/Kalender/Drive und Transkription; kein Spotlight-Skill gefunden.
- [@ff-labs/pi-fff](https://pi.dev/packages/%40ff-labs/pi-fff): Datei-/Inhaltssuche im Projekt mit eigenem Index, überwiegend Quelltext. Die dokumentierte Fähigkeit ersetzt keine Spotlight-Inhaltssuche in PDFs und den fünf Alltagsordnern. Für diese Aufgabe nicht installieren und keinen Index nachbauen.

Entscheidung: vorhandene Pi-Skill-Ladung und `bash` verwenden; ein kleines Skript ruft genau einmal macOS `mdfind` auf. Kein neues App-Suchwerkzeug, kein eigener Index, kein Schlüsselwort-Router in Swift. Ein neuer automatischer Skill, die bisherigen 14 bleiben explizite Aktionen.

Gemessener Bestand: 7 Pi-Werkzeuge, 4 Pippa-Dateiwerkzeuge, 11 MCP-Werkzeuge = 22. Die 14 Skills mit `disable-model-invocation` kosten im Ausgangsstand 0 Prompttoken. `ls` doppelt `list_folder`; `find` sucht Namen statt Inhalte; `grep` ist nur bei schon bekanntem Textpfad hilfreich und über Pis bash erreichbar. Dokumente mit OCR, Mail/Kalender in Pippas Prozess und Rückgängig bleiben eigene Integrationen: Pi allein ersetzt diese nicht.
