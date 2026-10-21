#!/usr/bin/env python3
"""Creates only synthetic test files and a shareable ZIP.

Pippa speaks German and English, so the fixtures come in both languages: `--language de`
keeps the original German set, `--language en` produces the equivalent English set. Every
name, amount, date and address in either set is invented, so a tester can safely read a
file, dictate it and delete the folder afterwards.
"""
import argparse
import pathlib
import zipfile

DEFAULT_ROOT = "dist/Pippa-Testdateien"

# The German set, unchanged from the first version of this script.
GERMAN_FILES = {
    "Rechnung Strom.txt": "Stadtwerke Musterstadt\nRechnung\nRechnungsdatum: 06.10.2026\nGesamtbetrag: 42,50 EUR\nBitte zahlen Sie bis zum 31.10.2026.\n",
    "Brief Hausverwaltung.txt": "Hausverwaltung Beispiel\n06.10.2026\nNebenkostenabrechnung\nIhre Nachzahlung beträgt 18,00 EUR.\nBitte überweisen Sie die Nachzahlung bis zum 20.11.2026.\n",
    "Notiz Einkauf.txt": "Milch, Brot und Äpfel kaufen. Die Fahrradlampe reparieren.\n",
    "Lied.mp3": "Synthetische Dateinamenprobe. Kein echtes Audio.\n",
    "Lies mich.txt": "Alle Dateien sind erfunden. Bitte nur diesen Testordner aufräumen.\n",
}

# The English set: the same five kinds of example, the same amounts and deadlines in
# euros, so a tester's check does not depend on the language.
ENGLISH_FILES = {
    "Electricity Bill.txt": "Musterstadt City Utilities\nInvoice\nInvoice date: 06.10.2026\nTotal amount: 42,50 EUR\nPlease pay by 31.10.2026.\n",
    "Letter Property Management.txt": "Example Property Management\n06.10.2026\nService charge statement\nYour additional payment is 18,00 EUR.\nPlease transfer the additional payment by 20.11.2026.\n",
    "Shopping Note.txt": "Buy milk, bread and apples. Repair the bicycle lamp.\n",
    "Song.mp3": "Synthetic filename sample. No real audio.\n",
    "Read Me.txt": "All files are invented. Please only clean up this test folder.\n",
}

# The ZIP that goes into the folder, one small archive per set.
GERMAN_ARCHIVE = {"Lies mich.txt": "Synthetische Archivprobe.\n"}
ENGLISH_ARCHIVE = {"Read Me.txt": "Synthetic archive sample.\n"}


def parse_arguments():
    parser = argparse.ArgumentParser(
        description="Creates synthetic test files and a shareable ZIP.",
    )
    parser.add_argument(
        "output_path",
        nargs="?",
        default=DEFAULT_ROOT,
        help=f"folder to create (default: {DEFAULT_ROOT})",
    )
    parser.add_argument(
        "--language",
        choices=("de", "en"),
        default="de",
        help="language of the generated set (default: de)",
    )
    return parser.parse_args()


def main():
    arguments = parse_arguments()
    root = pathlib.Path(arguments.output_path)
    output = root.with_suffix(".zip")
    if root.exists() or output.exists():
        raise SystemExit("Target already exists; pass a new folder for a new run.")

    if arguments.language == "en":
        files, archive_files = ENGLISH_FILES, ENGLISH_ARCHIVE
    else:
        files, archive_files = GERMAN_FILES, GERMAN_ARCHIVE

    root.mkdir(parents=True)
    for name, text in files.items():
        (root / name).write_text(text, encoding="utf-8")
    with zipfile.ZipFile(root / "Paket.zip", "w", zipfile.ZIP_DEFLATED) as archive:
        for name, text in archive_files.items():
            archive.writestr(name, text)
    with zipfile.ZipFile(output, "w", zipfile.ZIP_DEFLATED) as archive:
        for path in sorted(root.iterdir()):
            archive.write(path, arcname=root.name + "/" + path.name)
    print(output.resolve())


if __name__ == "__main__":
    main()
