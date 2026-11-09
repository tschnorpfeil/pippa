import contextlib
import copy
import io
import hashlib
import importlib.util
import json
import os
import pathlib
import subprocess
import tempfile
import unittest
import unittest.mock

ROOT = pathlib.Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location("mirror_model", ROOT / "scripts/mirror-model.py")
mirror = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mirror)

REVISION = "a48173b246ac705be75c05bedf1a0666db522d53"


def fixture_model(files, part_size=10_000):
    return {
        "key": "test-model", "label": "Test Model", "repo": "org/Test-Model", "license": "MIT, declared on the card",
        "mirror": {"url": f"https://github.com/tschnorpfeil/pippa/releases/download/model-test-model-{REVISION[:7]}/",
                   "partSize": part_size},
        "pinned": {"revision": REVISION, "files": files},
    }


def pin(path, data):
    return {"path": path, "size": len(data), "sha256": hashlib.sha256(data).hexdigest()}


class MirrorNames(unittest.TestCase):
    def test_path_slashes_become_double_dashes(self):
        self.assertEqual(mirror.asset_name("model.safetensors"), "model.safetensors")
        self.assertEqual(mirror.asset_name("sub/dir/config.json"), "sub--dir--config.json")

    def test_files_up_to_part_size_stay_whole(self):
        self.assertEqual(mirror.assets_for("a/b.json", 10_000, 10_000), [("a--b.json", 0, 10_000)])
        self.assertEqual(mirror.assets_for("tiny", 1, 10_000), [("tiny", 0, 1)])

    def test_larger_files_are_split_into_numbered_parts(self):
        self.assertEqual(mirror.assets_for("w/m.bin", 25_001, 10_000),
                         [("w--m.bin.part-0", 0, 10_000), ("w--m.bin.part-1", 10_000, 10_000), ("w--m.bin.part-2", 20_000, 5_001)])
        # The real model: three parts below GitHub's 2 GiB asset limit, the same names Pippa asks for.
        parts = mirror.assets_for("model.safetensors", 5_038_161_163, 2_000_000_000)
        self.assertEqual([name for name, _, _ in parts], [f"model.safetensors.part-{i}" for i in range(3)])
        self.assertEqual([length for _, _, length in parts], [2_000_000_000, 2_000_000_000, 1_038_161_163])
        self.assertTrue(all(length < mirror.ASSET_LIMIT for _, _, length in parts))

    def test_tag_uses_the_short_revision(self):
        self.assertEqual(mirror.mirror_tag("ornith-1.5-9b-mlx-4bit", REVISION), "model-ornith-1.5-9b-mlx-4bit-a48173b")


class MirrorSplit(unittest.TestCase):
    def test_split_parts_join_to_the_file(self):
        data = os.urandom(25_001)
        with tempfile.TemporaryDirectory() as folder:
            folder = pathlib.Path(folder)
            source, work = folder / "m.bin", folder / "work"
            source.write_bytes(data)
            work.mkdir()
            written = mirror.split(source, "w/m.bin", len(data), 10_000, hashlib.sha256(data).hexdigest(), work)
            self.assertEqual([p.name for p in written], ["w--m.bin.part-0", "w--m.bin.part-1", "w--m.bin.part-2"])
            self.assertEqual([p.stat().st_size for p in written], [10_000, 10_000, 5_001])
            self.assertEqual(b"".join(p.read_bytes() for p in written), data)
            self.assertEqual(source.read_bytes(), data)

    def test_small_file_is_linked_under_its_asset_name(self):
        data = b"{}"
        with tempfile.TemporaryDirectory() as folder:
            folder = pathlib.Path(folder)
            source = folder / "config.json"
            source.write_bytes(data)
            written = mirror.split(source, "sub/config.json", 2, 10_000, hashlib.sha256(data).hexdigest(), folder)
            self.assertEqual([p.name for p in written], ["sub--config.json"])
            self.assertEqual(written[0].read_bytes(), data)

    def test_split_refuses_parts_that_do_not_match_the_pin(self):
        data = os.urandom(12_345)
        with tempfile.TemporaryDirectory() as folder:
            folder = pathlib.Path(folder)
            (folder / "m.bin").write_bytes(data)
            with self.assertRaises(mirror.MirrorError):
                mirror.split(folder / "m.bin", "m.bin", len(data), 10_000, "0" * 64, folder)


class MirrorLocate(unittest.TestCase):
    def test_finds_verified_copies_and_skips_mismatches(self):
        weights, config = os.urandom(30_000), b'{"a": 1}'
        model = fixture_model([pin("config.json", config), pin("model.safetensors", weights)])
        with tempfile.TemporaryDirectory() as home:
            home = pathlib.Path(home)
            omlx = home / ".omlx/models/org/Test-Model"
            omlx.mkdir(parents=True)
            (omlx / "config.json").write_bytes(config)
            (omlx / "model.safetensors").write_bytes(weights[:-1] + b"x")  # same size, other bytes
            snapshot = home / f".cache/huggingface/hub/models--org--Test-Model/snapshots/{REVISION}"
            snapshot.mkdir(parents=True)
            (snapshot / "model.safetensors").write_bytes(weights)
            env = {k: v for k, v in os.environ.items() if k not in ("HF_HOME", "HF_HUB_CACHE")}
            with unittest.mock.patch.dict(os.environ, env, clear=True):
                found, skipped = mirror.locate(model, home)
            self.assertEqual(found["config.json"], (omlx / "config.json", "oMLX"))
            self.assertEqual(found["model.safetensors"], (snapshot / "model.safetensors", "Hugging Face cache"))
            self.assertEqual(len(skipped), 1)
            self.assertIn("SHA-256", skipped[0])

    def test_stops_without_a_matching_copy(self):
        model = fixture_model([pin("model.safetensors", b"right bytes")])
        with tempfile.TemporaryDirectory() as home:
            home = pathlib.Path(home)
            omlx = home / ".omlx/models/org/Test-Model"
            omlx.mkdir(parents=True)
            (omlx / "model.safetensors").write_bytes(b"wrong")
            with self.assertRaisesRegex(mirror.MirrorError, "5 bytes, pinned 11"):
                mirror.locate(model, home)

    def test_dry_run_only_reads(self):
        weights = os.urandom(25_000)
        model = fixture_model([pin("model.safetensors", weights)])
        with tempfile.TemporaryDirectory() as home:
            home = pathlib.Path(home)
            catalog = home / "catalog.json"
            catalog.write_text(json.dumps({"models": [model]}))
            omlx = home / ".omlx/models/org/Test-Model"
            omlx.mkdir(parents=True)
            (omlx / "model.safetensors").write_bytes(weights)
            before = sorted(p for p in home.rglob("*"))
            with unittest.mock.patch.object(mirror.shutil, "which", return_value=None), \
                    unittest.mock.patch.object(mirror, "gh", side_effect=AssertionError("gh called in a dry run")), \
                    contextlib.redirect_stdout(io.StringIO()) as output:
                self.assertEqual(mirror.main(["test-model", "--dry-run"], home=home, catalog=catalog), 0)
            self.assertIn("upload  model.safetensors.part-2 (5000 bytes", output.getvalue())
            self.assertEqual(sorted(p for p in home.rglob("*")), before)


class MirrorCatalogRules(unittest.TestCase):
    def test_valid_mirror_has_no_problems(self):
        self.assertEqual(mirror.mirror_problems(fixture_model([])), [])

    def test_rules(self):
        base = fixture_model([])
        cases = {
            "license": lambda m: m.pop("license"),
            "is not": lambda m: m["mirror"].update(url=m["mirror"]["url"].replace("a48173b", "a48173c")),
            "this repo": lambda m: m["mirror"].update(url=m["mirror"]["url"].replace("tschnorpfeil/pippa", "someone/else")),
            "2 GiB": lambda m: m["mirror"].update(partSize=2 * 1024 ** 3),
        }
        for expected, change in cases.items():
            model = copy.deepcopy(base)
            change(model)
            problems = mirror.mirror_problems(model)
            self.assertTrue(problems, expected)
            self.assertTrue(any(expected in p for p in problems), (expected, problems))

    def test_main_refuses_a_model_without_license(self):
        model = fixture_model([pin("a", b"a")])
        del model["license"]
        with tempfile.TemporaryDirectory() as home:
            catalog = pathlib.Path(home) / "catalog.json"
            catalog.write_text(json.dumps({"models": [model]}))
            with self.assertRaisesRegex(mirror.MirrorError, "license"), contextlib.redirect_stdout(io.StringIO()):
                mirror.main(["test-model", "--dry-run"], home=home, catalog=catalog)

    def test_shipped_catalog_passes(self):
        result = subprocess.run(["python3", str(ROOT / "scripts/check-default-models.py")], capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        catalog = json.loads(mirror.catalog_path().read_text(encoding="utf-8"))
        for model in catalog["models"]:
            if "mirror" in model:
                self.assertEqual(mirror.mirror_problems(model), [])

    def test_release_notes_name_source_revision_license_and_check(self):
        notes = mirror.release_notes(fixture_model([pin("a/b", b"x")]))
        for text in ("not an app release", "https://huggingface.co/org/Test-Model/tree/" + REVISION, REVISION,
                     "MIT, declared on the card", "SHA-256", "MODEL-CARD.md", "`a/b`"):
            self.assertIn(text, notes)

if __name__ == "__main__":
    unittest.main()
