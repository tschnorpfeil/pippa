import base64
import csv
import hashlib
import importlib.util
import io
import json
import pathlib
import tempfile
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location("mlx_runtime_sources", ROOT / "scripts/mlx-runtime-sources.py")
sources = importlib.util.module_from_spec(spec)
spec.loader.exec_module(sources)

SHA = "ff0d649ba4e550c031a5d27bb7a4a89b30b35607483fd42010bda2164c0547ad"
COMMIT = "0d4d3d04f8ab7ce4a51e7209e8615755a48ba94d"
LOCK = f"""# Pinned dependencies (header)
# Generated; do not edit by hand.
aiohttp==3.13.3 \\
    --hash=sha256:{"a" * 64} \\
    --hash=sha256:{"b" * 64}
    # via omlx

mlx-lm @ git+https://github.com/ml-explore/mlx-lm@{COMMIT}
    # via omlx
omlx @ https://github.com/jundot/omlx/archive/refs/tags/v0.7.3.tar.gz \\
    --hash=sha256:{SHA}
    # via -r requirements.in
yarl==1.25.1 \\
    --hash=sha256:{"c" * 64}
    # via aiohttp
"""


class SplitTests(unittest.TestCase):
    def test_wheels_and_sources_are_separated(self):
        binary, found = sources.split(LOCK)
        self.assertEqual(
            found,
            [
                ("git", "mlx-lm", "https://github.com/ml-explore/mlx-lm", COMMIT),
                ("archive", "omlx", "https://github.com/jundot/omlx/archive/refs/tags/v0.7.3.tar.gz", SHA),
            ],
        )
        self.assertIn("aiohttp==3.13.3", binary)
        self.assertIn("yarl==1.25.1", binary)
        self.assertNotIn("omlx @", binary)
        self.assertNotIn("git+", binary)
        self.assertNotIn("header", binary)

    def test_unpinned_entries_are_refused(self):
        for lock in ("requests==2.0\n", "foo @ git+https://github.com/a/b@main\n", "foo @ https://x/y.tar.gz\n"):
            with self.subTest(lock=lock), self.assertRaises(ValueError):
                sources.split(lock)


class BuildRequiresTests(unittest.TestCase):
    def test_union_keeps_first_seen_order(self):
        with tempfile.TemporaryDirectory() as tmp:
            a, b = pathlib.Path(tmp, "a.toml"), pathlib.Path(tmp, "b.toml")
            a.write_text('[build-system]\nrequires = ["setuptools>=61.0", "wheel", "mlx==0.32.4"]\n')
            b.write_text('[build-system]\nrequires = ["setuptools>=80", "wheel"]\n')
            self.assertEqual(sources.build_requires([a, b]), ["setuptools>=61.0", "wheel", "mlx==0.32.4", "setuptools>=80"])

    def test_missing_build_system_is_refused(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = pathlib.Path(tmp, "pyproject.toml")
            path.write_text('[project]\nname = "x"\n')
            with self.assertRaises(ValueError):
                sources.build_requires([path])


TOOLS_LOCK = f"""# header
cmake==4.4.4 \\
    --hash=sha256:{"1" * 64}
    # via -r build-tools.in
packaging==26.3 \\
    --hash=sha256:{"2" * 64}
    # via
    #   setuptools-scm
    #   vcs-versioning
    #   wheel
setuptools==84.2.1 \\
    --hash=sha256:{"3" * 64}
    # via
    #   -r build-tools.in
    #   setuptools-scm
setuptools-scm==10.3.4 \\
    --hash=sha256:{"4" * 64}
    # via -r build-tools.in
vcs-versioning==2.6.0 \\
    --hash=sha256:{"5" * 64}
    # via setuptools-scm
wheel==0.48.0 \\
    --hash=sha256:{"6" * 64}
    # via -r build-tools.in
"""


class ToolsTests(unittest.TestCase):
    def tools(self, requires, skip=()):
        with tempfile.TemporaryDirectory() as tmp:
            path = pathlib.Path(tmp, "pyproject.toml")
            path.write_text("[build-system]\nrequires = %s\n" % json.dumps(requires))
            text = sources.tools_for(TOOLS_LOCK, path, skip)
        return [block.split("==")[0] for block in sources.entries(text)]

    def test_only_what_the_source_names_and_pulls_in(self):
        self.assertEqual(self.tools(["setuptools>=64"]), ["setuptools"])
        self.assertEqual(self.tools(["setuptools>=61.0", "wheel"]), ["packaging", "setuptools", "wheel"])
        self.assertEqual(
            self.tools(["setuptools>=80", "setuptools-scm>=9"]),
            ["packaging", "setuptools", "setuptools-scm", "vcs-versioning"],
        )

    def test_skipped_names_and_missing_tools(self):
        self.assertEqual(
            self.tools(["setuptools>=61.0", "wheel", "cmake>=3.27", "mlx==0.32.4"], skip=["mlx"]),
            ["cmake", "packaging", "setuptools", "wheel"],
        )
        with self.assertRaises(ValueError):
            self.tools(["setuptools", "nanobind==3.1.0"])


class DirectUrlTests(unittest.TestCase):
    def test_json_matches_what_uv_writes(self):
        self.assertEqual(
            sources.direct_url_json("archive", "https://github.com/jundot/omlx/archive/refs/tags/v0.7.3.tar.gz"),
            '{"url":"https://github.com/jundot/omlx/archive/refs/tags/v0.7.3.tar.gz","archive_info":{}}',
        )
        self.assertEqual(
            sources.direct_url_json("git", "https://github.com/ml-explore/mlx-lm", COMMIT),
            '{"url":"https://github.com/ml-explore/mlx-lm","vcs_info":{"vcs":"git","commit_id":"%s",'
            '"requested_revision":"%s"}}' % (COMMIT, COMMIT),
        )

    def test_record_row_is_written_once(self):
        with tempfile.TemporaryDirectory() as tmp:
            dist_info = pathlib.Path(tmp, "mlx_lm-0.32.3.dev8+g0d4d3d04f.dist-info")
            dist_info.mkdir()
            (dist_info / "uv_cache.json").write_text('{"timestamp":{}}')
            (dist_info / "RECORD").write_text(
                "mlx_lm/__init__.py,sha256=abc,10\n"
                f"{dist_info.name}/uv_cache.json,sha256=x,16\n"
                f"{dist_info.name}/direct_url.json,sha256=old,5\n"
                f"{dist_info.name}/RECORD,,\n"
            )
            content = sources.direct_url_json("git", "https://github.com/ml-explore/mlx-lm", COMMIT)
            for _ in range(2):
                sources.record_direct_url(tmp, "mlx-lm", content)
            self.assertEqual((dist_info / "direct_url.json").read_text(), content)
            rows = list(csv.reader(io.StringIO((dist_info / "RECORD").read_text())))
            digest = base64.urlsafe_b64encode(hashlib.sha256(content.encode()).digest()).rstrip(b"=").decode()
            direct = [row for row in rows if row[0].endswith("direct_url.json")]
            self.assertEqual(direct, [[f"{dist_info.name}/direct_url.json", f"sha256={digest}", str(len(content))]])
            self.assertIn(["mlx_lm/__init__.py", "sha256=abc", "10"], rows)
            self.assertFalse((dist_info / "uv_cache.json").exists())
            self.assertFalse([row for row in rows if row[0].endswith("uv_cache.json")])

    def test_unknown_distribution_is_refused(self):
        with tempfile.TemporaryDirectory() as tmp, self.assertRaises(ValueError):
            sources.record_direct_url(tmp, "omlx", "{}")


if __name__ == "__main__":
    unittest.main()
