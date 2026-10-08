#!/usr/bin/env python3
"""Checks Pippa's UI translations (docs/development.md, "Localization").

Scans app/Sources/PippaCore for L("…", table: "X") and app/Sources/Pippa for
T("…", table: "X") and verifies:

  - X is a known table of the right module,
  - every key exists in en.lproj/X.strings and de.lproj/X.strings,
  - every .strings file parses, has no duplicate keys, and en and de hold the same keys,
  - format placeholders (%@, %lld, %1$@, …) match between en and de for each key,
  - app/Packaging/Localization/{en,de}.lproj/{InfoPlist,ServicesMenu}.strings parse,
    match each other and name texts that app/Packaging/Info.plist has.

Keys must be plain string literals (no interpolation). Calls with other keys are counted
and listed with --verbose, but not checked. Keys in a table that no code uses are listed
as notes, not errors.

  python3 scripts/check-strings.py [--verbose]

Exit code 1 lists every problem.
"""
from __future__ import annotations

import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
SOURCES = ROOT / "app" / "Sources"

# Funktion -> (Modulordner, Ressourcenordner, Tabellen)
MODULES = {
    "L": ("PippaCore", SOURCES / "PippaCore" / "Resources", ("Core", "Analysis", "Skills", "Tools", "TrayCore", "Letter", "Lookup", "Sheet", "Calendar", "Thought", "Setup", "MCP")),
    "T": ("Pippa", SOURCES / "Pippa" / "Localization", ("App", "Views", "Settings", "Line", "Shelf", "TrayApp", "Call", "SheetUI", "CalendarUI", "ThoughtUI")),
}
LANGUAGES = ("en", "de")

CALL = re.compile(r'(?<![A-Za-z0-9_.])(L|T)\(')
PLACEHOLDER = re.compile(
    r"%(?:(\d+)\$)?[-+#0]*(?:\d+|\*)?(?:\.(?:\d+|\*))?(hh|h|ll|l|q|z|t|j|L)?([@dDiuUxXoOfFeEgGcCsSpaA%])"
)


class Problem(Exception):
    pass


# --- Swift ---------------------------------------------------------------------

SWIFT_ESCAPES = {"n": "\n", "t": "\t", "r": "\r", "0": "\0", '"': '"', "'": "'", "\\": "\\"}


def swift_literal(text: str, start: int) -> tuple[str | None, int]:
    """Parses a single-line Swift string literal at text[start] == '"'.
    Returns (value, end index after closing quote); value None if not a plain literal."""
    if text.startswith('"""', start):
        return None, start
    i = start + 1
    out = []
    while i < len(text):
        c = text[i]
        if c == "\n":
            return None, i
        if c == '"':
            return "".join(out), i + 1
        if c == "\\":
            n = text[i + 1] if i + 1 < len(text) else ""
            if n == "(":
                return None, i  # interpolation: no fixed key
            if n == "u" and text.startswith("{", i + 2):
                close = text.find("}", i + 3)
                if close < 0:
                    return None, i
                out.append(chr(int(text[i + 3:close], 16)))
                i = close + 1
                continue
            if n in SWIFT_ESCAPES:
                out.append(SWIFT_ESCAPES[n])
                i += 2
                continue
            return None, i
        out.append(c)
        i += 1
    return None, i


def blank_comments(text: str) -> str:
    """Replaces Swift comments by spaces (keeps line numbers), leaves string literals alone."""
    out = list(text)
    i, n = 0, len(text)
    in_string = False
    while i < n:
        c = text[i]
        if in_string:
            if text.startswith('"""', i) and in_string == '"""':
                in_string = False
                i += 3
                continue
            if c == "\\":
                i += 2
                continue
            if c == '"' and in_string == '"':
                in_string = False
            elif c == "\n" and in_string == '"':
                in_string = False
            i += 1
            continue
        if text.startswith("//", i):
            j = text.find("\n", i)
            j = n if j < 0 else j
            for k in range(i, j):
                out[k] = " "
            i = j
            continue
        if text.startswith("/*", i):
            depth, j = 1, i + 2
            while j < n and depth:
                if text.startswith("/*", j):
                    depth, j = depth + 1, j + 2
                elif text.startswith("*/", j):
                    depth, j = depth - 1, j + 2
                else:
                    j += 1
            for k in range(i, j):
                if out[k] != "\n":
                    out[k] = " "
            i = j
            continue
        if text.startswith('"""', i):
            in_string = '"""'
            i += 3
            continue
        if c == '"':
            in_string = '"'
        i += 1
    return "".join(out)


TABLE_ARG = re.compile(r'\s*,\s*table:\s*"([^"\\]*)"')


def scan_calls(problems: list[str], skipped: list[str]) -> dict[tuple[str, str], dict[str, list[str]]]:
    """Returns {(function, table): {key: [places]}}."""
    found: dict[tuple[str, str], dict[str, list[str]]] = {}
    for function, (module, _, tables) in MODULES.items():
        for path in sorted((SOURCES / module).rglob("*.swift")):
            raw = path.read_text(encoding="utf-8")
            text = blank_comments(raw)
            rel = path.relative_to(ROOT)
            for match in CALL.finditer(text):
                if match.group(1) != function:
                    # PippaCore has no T (there `T(` is a generic type); in the Pippa module only T counts.
                    if module == "Pippa":
                        line = text.count("\n", 0, match.start()) + 1
                        problems.append(f'{rel}:{line}: use T("…", table: …) in the Pippa module, not L')
                    continue
                if text[:match.start()].rstrip().endswith("func"):
                    continue  # the declaration itself
                line = text.count("\n", 0, match.start()) + 1
                place = f"{rel}:{line}"
                i = match.end()
                while i < len(text) and text[i] in " \t":
                    i += 1
                if i >= len(text) or text[i] != '"':
                    skipped.append(f"{place}: key is not a string literal")
                    continue
                key, end = swift_literal(text, i)
                if key is None:
                    skipped.append(f"{place}: key is not a plain string literal (interpolation or multi-line)")
                    continue
                table_match = TABLE_ARG.match(text, end)
                if not table_match:
                    problems.append(f'{place}: {function}("{key}" …) has no literal table: argument')
                    continue
                table = table_match.group(1)
                if table not in tables:
                    problems.append(f'{place}: table "{table}" is not a {module} table (use one of {", ".join(tables)})')
                    continue
                found.setdefault((function, table), {}).setdefault(key, []).append(place)
    return found


# --- .strings ------------------------------------------------------------------

STRINGS_ESCAPES = {"n": "\n", "t": "\t", "r": "\r", '"': '"', "\\": "\\", "'": "'", "a": "\a", "b": "\b", "f": "\f", "v": "\v"}


def parse_strings(path: Path) -> list[tuple[str, str, int]]:
    """Parses an old-style .strings file ("key" = "value";). Returns [(key, value, line)]."""
    data = path.read_bytes()
    if data.startswith(b"\xef\xbb\xbf"):
        data = data[3:]
    try:
        text = data.decode("utf-8")
    except UnicodeDecodeError as error:
        raise Problem(f"{path.relative_to(ROOT)}: not UTF-8 ({error})")
    rel = path.relative_to(ROOT)
    i, n = 0, len(text)

    def line_at(pos: int) -> int:
        return text.count("\n", 0, pos) + 1

    def skip() -> None:
        nonlocal i
        while i < n:
            if text[i].isspace():
                i += 1
            elif text.startswith("//", i):
                j = text.find("\n", i)
                i = n if j < 0 else j
            elif text.startswith("/*", i):
                j = text.find("*/", i + 2)
                if j < 0:
                    raise Problem(f"{rel}:{line_at(i)}: comment is not closed")
                i = j + 2
            else:
                return

    def quoted() -> str:
        nonlocal i
        if i >= n or text[i] != '"':
            raise Problem(f'{rel}:{line_at(i)}: expected a quoted string ("…")')
        start = i
        i += 1
        out = []
        while i < n:
            c = text[i]
            if c == '"':
                i += 1
                return "".join(out)
            if c == "\\":
                e = text[i + 1] if i + 1 < n else ""
                if e in ("U", "u"):
                    digits = text[i + 2:i + 6]
                    if not re.fullmatch(r"[0-9A-Fa-f]{4}", digits):
                        raise Problem(f"{rel}:{line_at(i)}: invalid \\{e} escape")
                    out.append(chr(int(digits, 16)))
                    i += 6
                    continue
                if e in STRINGS_ESCAPES:
                    out.append(STRINGS_ESCAPES[e])
                    i += 2
                    continue
                raise Problem(f"{rel}:{line_at(i)}: unknown escape \\{e}")
            out.append(c)
            i += 1
        raise Problem(f"{rel}:{line_at(start)}: string is not closed")

    entries = []
    while True:
        skip()
        if i >= n:
            return entries
        line = line_at(i)
        key = quoted()
        skip()
        if i >= n or text[i] != "=":
            raise Problem(f'{rel}:{line}: expected = after "{key}"')
        i += 1
        skip()
        value = quoted()
        skip()
        if i >= n or text[i] != ";":
            raise Problem(f'{rel}:{line}: expected ; after the value of "{key}"')
        i += 1
        entries.append((key, value, line))


def placeholders(text: str) -> dict[int, str] | str:
    """Maps argument position -> conversion; a string describes an error."""
    result: dict[int, str] = {}
    position = 0
    positional = None
    for match in PLACEHOLDER.finditer(text):
        index, length, conversion = match.groups()
        if conversion == "%":
            continue
        if index is not None:
            if positional is False:
                return "mixes positional (%1$@) and plain (%@) placeholders"
            positional = True
            slot = int(index)
        else:
            if positional is True:
                return "mixes positional (%1$@) and plain (%@) placeholders"
            positional = False
            position += 1
            slot = position
        kind = (length or "") + conversion
        if result.get(slot, kind) != kind:
            return f"argument {slot} is used as %{result[slot]} and %{kind}"
        result[slot] = kind
    return result


PACKAGING = ROOT / "app" / "Packaging"


def check_packaging(problems: list[str]) -> None:
    """app/Packaging/Localization/{en,de}.lproj: InfoPlist.strings and ServicesMenu.strings
    parse, hold the same keys in en and de, and refer to texts that Info.plist really has."""
    import plistlib

    info = plistlib.loads((PACKAGING / "Info.plist").read_bytes())
    allowed = {
        "InfoPlist": {k for k, v in info.items() if isinstance(v, str)}
        | {t.get("CFBundleTypeName") for t in info.get("CFBundleDocumentTypes", []) if isinstance(t, dict)},
        "ServicesMenu": {
            s.get("NSMenuItem", {}).get("default") for s in info.get("NSServices", []) if isinstance(s, dict)
        },
    }
    for name, keys_allowed in allowed.items():
        found: dict[str, set[str]] = {}
        for language in LANGUAGES:
            path = PACKAGING / "Localization" / f"{language}.lproj" / f"{name}.strings"
            rel = path.relative_to(ROOT)
            if not path.exists():
                problems.append(f"{rel}: file missing")
                continue
            try:
                entries = parse_strings(path)
            except Problem as error:
                problems.append(str(error))
                continue
            keys = set()
            for key, _, line in entries:
                if key in keys:
                    problems.append(f'{rel}:{line}: duplicate key "{show(key)}"')
                if key not in keys_allowed:
                    problems.append(f'{rel}:{line}: "{show(key)}" is not a text in app/Packaging/Info.plist')
                keys.add(key)
            found[language] = keys
        if len(found) == len(LANGUAGES) and found["en"] != found["de"]:
            differ = sorted(found["en"] ^ found["de"])
            problems.append(f"app/Packaging/Localization {name}.strings: en and de differ in {', '.join(differ)}")
        if name == "ServicesMenu":
            for title in sorted(t for t in keys_allowed if t):
                for language, keys in found.items():
                    if title not in keys:
                        problems.append(f'app/Packaging/Localization/{language}.lproj/ServicesMenu.strings: "{title}" missing')


def show(text: str) -> str:
    return text.replace("\\", "\\\\").replace('"', '\\"').replace("\n", "\\n")


def main() -> int:
    verbose = "--verbose" in sys.argv[1:]
    problems: list[str] = []
    notes: list[str] = []
    skipped: list[str] = []

    tables: dict[tuple[str, str, str], dict[str, str]] = {}
    for function, (module, folder, names) in MODULES.items():
        for language in LANGUAGES:
            for name in names:
                path = folder / f"{language}.lproj" / f"{name}.strings"
                rel = path.relative_to(ROOT)
                if not path.exists():
                    problems.append(f"{rel}: file missing")
                    continue
                try:
                    entries = parse_strings(path)
                except Problem as error:
                    problems.append(str(error))
                    continue
                table: dict[str, str] = {}
                for key, value, line in entries:
                    if key in table:
                        problems.append(f'{rel}:{line}: duplicate key "{show(key)}"')
                    table[key] = value
                tables[(function, name, language)] = table
        # .strings files that are not a known table
        for language in LANGUAGES:
            lproj = folder / f"{language}.lproj"
            if lproj.is_dir():
                for path in sorted(lproj.glob("*.strings")):
                    if path.stem not in names:
                        problems.append(f"{path.relative_to(ROOT)}: unknown table (known: {', '.join(names)})")

    # en and de: same keys, same placeholders
    for function, (module, folder, names) in MODULES.items():
        for name in names:
            en = tables.get((function, name, "en"))
            de = tables.get((function, name, "de"))
            if en is None or de is None:
                continue
            for key in sorted(set(en) - set(de)):
                problems.append(f'{module} {name}: "{show(key)}" is in en.lproj but missing in de.lproj')
            for key in sorted(set(de) - set(en)):
                problems.append(f'{module} {name}: "{show(key)}" is in de.lproj but missing in en.lproj')
            for key in sorted(set(en) & set(de)):
                expected = placeholders(key)
                for language, value in (("en", en[key]), ("de", de[key])):
                    got = placeholders(value)
                    if isinstance(got, str):
                        problems.append(f'{module} {name} {language}: "{show(key)}": {got}')
                    elif not isinstance(expected, str) and got != expected:
                        problems.append(
                            f'{module} {name} {language}: "{show(key)}": placeholders {fmt(got)} do not match the key {fmt(expected)}'
                        )
                if isinstance(expected, str):
                    problems.append(f'{module} {name}: key "{show(key)}": {expected}')

    check_packaging(problems)

    # Aufrufe im Code
    calls = scan_calls(problems, skipped)
    for (function, name), keys in sorted(calls.items()):
        module = MODULES[function][0]
        for language in LANGUAGES:
            table = tables.get((function, name, language))
            if table is None:
                continue
            for key, places in sorted(keys.items()):
                if key not in table:
                    problems.append(f'{places[0]}: "{show(key)}" missing in {module} {language}.lproj/{name}.strings')
    for function, (module, _, names) in MODULES.items():
        for name in names:
            used = calls.get((function, name), {})
            for key in sorted(tables.get((function, name, "en"), {})):
                if key not in used:
                    notes.append(f'{module} {name}: "{show(key)}" is not used by a literal call (dynamic key or stale)')

    used_count = sum(len(keys) for keys in calls.values())
    if verbose:
        for line in notes + skipped:
            print(f"note: {line}")
    if problems:
        print(f"check-strings: {len(problems)} problem(s)")
        for line in problems:
            print(f"  {line}")
        print("Convention: docs/development.md, section \"Localization\".")
        return 1
    print(
        f"check-strings: OK ({used_count} keys used in code, {len(skipped)} non-literal calls, "
        f"{len(notes)} unused table keys{'' if verbose else '; --verbose lists them'})"
    )
    return 0


def fmt(slots: dict[int, str]) -> str:
    if not slots:
        return "(none)"
    return " ".join(f"{index}:%{kind}" for index, kind in sorted(slots.items()))


if __name__ == "__main__":
    sys.exit(main())
