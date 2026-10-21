import pathlib
import subprocess
import sys
import tempfile
import unittest
import zipfile

ROOT = pathlib.Path(__file__).resolve().parents[2]
GENERATOR = ROOT / "scripts/create-usability-fixtures.py"


def run_generator(*arguments):
    """Runs the generator as a script, the way a tester would."""
    return subprocess.run(
        [sys.executable, str(GENERATOR), *arguments],
        capture_output=True,
        text=True,
        check=False,
    )


class UsabilityFixtures(unittest.TestCase):
    def test_the_default_command_still_creates_the_german_set(self):
        with tempfile.TemporaryDirectory() as folder:
            target = pathlib.Path(folder) / "German"
            result = run_generator(str(target))

            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertTrue((target / "Rechnung Strom.txt").is_file())
            self.assertTrue((target / "Brief Hausverwaltung.txt").is_file())
            self.assertTrue((target / "Notiz Einkauf.txt").is_file())
            self.assertTrue((target / "Lied.mp3").is_file())
            self.assertTrue((target / "Lies mich.txt").is_file())
            self.assertTrue(target.with_suffix(".zip").is_file())

    def test_the_english_option_creates_the_english_set(self):
        with tempfile.TemporaryDirectory() as folder:
            target = pathlib.Path(folder) / "English"
            result = run_generator(str(target), "--language", "en")

            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertTrue((target / "Electricity Bill.txt").is_file())
            self.assertTrue((target / "Letter Property Management.txt").is_file())
            self.assertTrue((target / "Shopping Note.txt").is_file())
            self.assertTrue((target / "Song.mp3").is_file())
            self.assertTrue((target / "Read Me.txt").is_file())
            self.assertTrue(target.with_suffix(".zip").is_file())

    def test_both_sets_carry_the_same_amounts_and_deadlines(self):
        with tempfile.TemporaryDirectory() as folder:
            german = pathlib.Path(folder) / "German"
            english = pathlib.Path(folder) / "English"
            run_generator(str(german))
            run_generator(str(english), "--language", "en")

            german_bill = (german / "Rechnung Strom.txt").read_text(encoding="utf-8")
            english_bill = (english / "Electricity Bill.txt").read_text(encoding="utf-8")
            for expected in ("42,50 EUR", "31.10.2026"):
                self.assertIn(expected, german_bill)
                self.assertIn(expected, english_bill)

            german_letter = (german / "Brief Hausverwaltung.txt").read_text(encoding="utf-8")
            english_letter = (english / "Letter Property Management.txt").read_text(encoding="utf-8")
            for expected in ("18,00 EUR", "20.11.2026"):
                self.assertIn(expected, german_letter)
                self.assertIn(expected, english_letter)

    def test_both_sets_carry_only_invented_data(self):
        with tempfile.TemporaryDirectory() as folder:
            german = pathlib.Path(folder) / "German"
            english = pathlib.Path(folder) / "English"
            run_generator(str(german))
            run_generator(str(english), "--language", "en")

            # The read-me in each set states that nothing is real; the MP3 says it
            # is a filename-only sample. The other files are invented by
            # construction: made-up company names, a made-up street, invented
            # amounts, and no personal name anywhere.
            for folder_path, marker, read_me_name in (
                (german, "erfunden", "Lies mich.txt"),
                (english, "invented", "Read Me.txt"),
            ):
                read_me = folder_path / read_me_name
                self.assertTrue(read_me.is_file(), f"{folder_path.name} has no {read_me_name}")
                self.assertIn(marker, read_me.read_text(encoding="utf-8"))

                for path in folder_path.iterdir():
                    if path.suffix == ".zip" or path.suffix == ".mp3":
                        continue
                    text = path.read_text(encoding="utf-8")
                    self.assertNotIn("@", text, f"{path.name} carries an email address")
                    for personal in ("Max", "Anna", "Peter", "Sarah"):
                        self.assertNotIn(personal, text, f"{path.name} names a person")

    def test_the_mp3_is_a_filename_only_sample(self):
        with tempfile.TemporaryDirectory() as folder:
            target = pathlib.Path(folder) / "English"
            run_generator(str(target), "--language", "en")

            sample = (target / "Song.mp3").read_text(encoding="utf-8")
            self.assertIn("No real audio", sample)

    def test_the_zip_contains_the_files_of_its_own_set(self):
        with tempfile.TemporaryDirectory() as folder:
            target = pathlib.Path(folder) / "English"
            run_generator(str(target), "--language", "en")

            with zipfile.ZipFile(target.with_suffix(".zip")) as archive:
                names = archive.namelist()

            self.assertTrue(any(name.endswith("Electricity Bill.txt") for name in names))
            self.assertFalse(any(name.endswith("Rechnung Strom.txt") for name in names))

    def test_running_against_an_existing_target_refuses_to_overwrite_it(self):
        with tempfile.TemporaryDirectory() as folder:
            target = pathlib.Path(folder) / "German"
            target.mkdir()
            (target / "Rechnung Strom.txt").write_text("keep me\n", encoding="utf-8")

            result = run_generator(str(target))

            self.assertNotEqual(result.returncode, 0)
            self.assertIn("already exists", result.stderr + result.stdout)
            self.assertEqual(
                (target / "Rechnung Strom.txt").read_text(encoding="utf-8"),
                "keep me\n",
            )


if __name__ == "__main__":
    unittest.main()
