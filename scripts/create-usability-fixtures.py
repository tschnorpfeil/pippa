#!/usr/bin/env python3
"""Creates only synthetic test files and a shareable ZIP. Names and contents stay German on purpose (German-only app)."""
import pathlib
import sys
import zipfile

root = pathlib.Path(sys.argv[1] if len(sys.argv) > 1 else "dist/Pippa-Testdateien")
output = root.with_suffix(".zip")
if root.exists() or output.exists():
    raise SystemExit("Target already exists; pass a new folder for a new run.")
root.mkdir(parents=True)
files = {
    "Rechnung Strom.txt": "Stadtwerke Musterstadt\nRechnung\nRechnungsdatum: 06.10.2026\nGesamtbetrag: 42,50 EUR\nBitte zahlen Sie bis zum 31.10.2026.\n",
    "Brief Hausverwaltung.txt": "Hausverwaltung Beispiel\n06.10.2026\nNebenkostenabrechnung\nIhre Nachzahlung beträgt 18,00 EUR.\nBitte überweisen Sie die Nachzahlung bis zum 20.11.2026.\n",
    "Notiz Einkauf.txt": "Milch, Brot und Äpfel kaufen. Die Fahrradlampe reparieren.\n",
    "Lied.mp3": "Synthetische Dateinamenprobe. Kein echtes Audio.\n",
    "Lies mich.txt": "Alle Dateien sind erfunden. Bitte nur diesen Testordner aufräumen.\n",
}
for name, text in files.items():
    (root / name).write_text(text, encoding="utf-8")
with zipfile.ZipFile(root / "Paket.zip", "w", zipfile.ZIP_DEFLATED) as archive:
    archive.writestr("Lies mich.txt", "Synthetische Archivprobe.\n")
with zipfile.ZipFile(output, "w", zipfile.ZIP_DEFLATED) as archive:
    for path in sorted(root.iterdir()):
        archive.write(path, arcname=root.name + "/" + path.name)
print(output.resolve())
