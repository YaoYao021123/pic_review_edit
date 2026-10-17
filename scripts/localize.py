#!/usr/bin/env python3
"""Localization helper for Lucet 光集 (no Xcode needed).

The source language is Simplified Chinese: the Chinese text in the code *is* the
key. The Swift compiler lists every key it will look up (SwiftUI Text/Button/…,
String(localized:), L(…)) via -emit-localized-strings; English lives in
Localization/en.lproj/Localizable.strings.

  python3 scripts/localize.py extract   # rebuild the key list (.build/loc-strings)
  python3 scripts/localize.py audit     # Chinese literals the app would show untranslated
  python3 scripts/localize.py missing   # keys with no English yet
  python3 scripts/localize.py check     # audit + missing + unused; exit 1 on problems

Mark a line that must stay Chinese (e.g. text sent to an API, test data) with
`// loc:ignore`; a whole file with `// loc:ignore-file` near the top.
"""
import json
import os
import re
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
STRINGS_DATA = ROOT / ".build/loc-strings"
SOURCES = [ROOT / "Sources/MediaCore", ROOT / "Sources/MediaWorkbenchApp"]
ENGLISH = ROOT / "Localization/en.lproj/Localizable.strings"
CJK = re.compile(r"[\u3400-\u9fff\uff00-\uffef\u3000-\u303f]")


def extract():
    # Incremental builds only rewrite the files they recompile, so keep the rest;
    # keys() skips files whose source is gone.
    STRINGS_DATA.mkdir(parents=True, exist_ok=True)
    command = ["swift", "build", "--scratch-path", str(ROOT / ".build/loc"),
               "-Xswiftc", "-emit-localized-strings",
               "-Xswiftc", "-emit-localized-strings-path", "-Xswiftc", str(STRINGS_DATA)]
    result = subprocess.run(command, cwd=ROOT, capture_output=True, text=True)
    if result.returncode != 0:
        sys.stderr.write(result.stdout[-4000:] + result.stderr[-4000:])
        sys.exit(result.returncode)


def keys():
    """{key: [(file, line, column)]} from the compiler's stringsdata files."""
    found = {}
    for path in sorted(STRINGS_DATA.glob("*.stringsdata")):
        data = json.loads(path.read_text())
        if not any((folder / Path(data["source"]).name).exists() for folder in SOURCES):
            continue
        for table, entries in data.get("tables", {}).items():
            for entry in entries:
                location = entry.get("location", {})
                found.setdefault(entry["key"], []).append(
                    (data["source"], location.get("startingLine"), location.get("startingColumn")))
    return found


def literals(text, spans=False):
    """Yields (line, column, value) for every string literal (1-based, column of the opening quote);
    with spans=True, (line, column, value, start, end) with character offsets.
    Handles comments, escapes, multi-line and raw strings, and nested interpolation."""
    i, n, line, line_start = 0, len(text), 1, 0

    def advance(to):
        nonlocal i, line, line_start
        while i < to:
            if text[i] == "\n":
                line += 1
                line_start = i + 1
            i += 1

    def position(index):
        """(line, UTF-8 byte column) of a character offset; the compiler reports byte columns."""
        line_number = text.count("\n", 0, index) + 1
        begin = text.rfind("\n", 0, index) + 1
        return line_number, len(text[begin:index].encode("utf-8")) + 1

    def read_string(start, nested):
        """Returns (end_index, value) for the literal starting at text[start] (a '#' or '"').
        Literals inside its interpolations are appended to `nested` as (start, end, value)."""
        j, hashes = start, 0
        while text[j] == "#":
            hashes += 1
            j += 1
        multi = text.startswith('"""', j)
        quote = '"""' if multi else '"'
        j += len(quote)
        close = quote + "#" * hashes
        escape = "\\" + "#" * hashes
        value = []
        while j < n:
            if text.startswith(close, j):
                return j + len(close), "".join(value)
            if text.startswith(escape, j):
                k = j + len(escape)
                if k < n and text[k] == "(":
                    depth, k = 1, k + 1
                    while k < n and depth:
                        if text[k] in '"#' and (text[k] == '"' or text.startswith('#"', k)):
                            inner_start = k
                            k, inner = read_string(k, nested)
                            nested.append((inner_start, k, inner))
                            continue
                        depth += {"(": 1, ")": -1}.get(text[k], 0)
                        k += 1
                    value.append("{…}")
                    j = k
                    continue
                value.append(text[j:k + 1])
                j = k + 1
                continue
            if not multi and text[j] == "\n":
                return j, "".join(value)
            value.append(text[j])
            j += 1
        return n, "".join(value)

    while i < n:
        c = text[i]
        if text.startswith("//", i):
            end = text.find("\n", i)
            advance(n if end < 0 else end)
        elif text.startswith("/*", i):
            end = text.find("*/", i + 2)
            advance(n if end < 0 else end + 2)
        elif c == '"' or (c == "#" and re.match(r'#+"', text[i:i + 8])):
            start = i
            nested = []
            end, value = read_string(i, nested)
            for s_, e_, v_ in [(start, end, value)] + nested:
                l_, c_ = position(s_)
                yield (l_, c_, v_, s_, e_) if spans else (l_, c_, v_)
            advance(end)
        else:
            advance(i + 1)


SKIP_WRAP = [re.compile(p) for p in (
    r"^\s*(public |private |fileprivate )?case\s+\w+\s*=",       # enum raw values
    r"^\s*case\s+\"",                                          # switch patterns
    r"(==|!=)\s*$",                                               # comparisons (text before the literal)
    r"verbatim:\s*$",
)]


def wrap(found):
    """Wraps every uncovered Chinese literal in L(…). Review the diff; identifiers are skipped."""
    covered = {(Path(f).name, l, c) for locations in found.values() for f, l, c in locations}
    changed = 0
    for folder in SOURCES:
        for path in sorted(folder.glob("*.swift")):
            text = path.read_text()
            if "// loc:ignore-file" in text[:2000]:
                continue
            lines = text.split("\n")
            targets = []
            for line, column, value, start, end in literals(text, spans=True):
                if not CJK.search(value) or (path.name, line, column) in covered:
                    continue
                source_line, previous = lines[line - 1], lines[line - 2] if line > 1 else ""
                if "loc:ignore" in source_line or "loc:ignore-next" in previous:
                    continue
                before = source_line.encode("utf-8")[:column - 1].decode("utf-8", "ignore")
                if any(p.search(before) for p in SKIP_WRAP):
                    print(f"skipped (identifier?): {path.relative_to(ROOT)}:{line}: {value[:60]}")
                    continue
                if before.rstrip().endswith("L(") or before.rstrip().endswith("localized:"):
                    continue
                targets.append((start, end))
            # Nested literals (inside another literal's interpolation) are wrapped too, so
            # insert at every boundary from the end of the file backwards.
            inserts = sorted([(s, "L(") for s, _ in targets] + [(e, ")") for _, e in targets], reverse=True)
            for position, token in inserts:
                text = text[:position] + token + text[position:]
            if targets:
                path.write_text(text)
                changed += len(targets)
                print(f"wrapped {len(targets):4d} in {path.relative_to(ROOT)}")
    print(f"{changed} literals wrapped")


def audit(found):
    covered = {(Path(f).name, l, c) for locations in found.values() for f, l, c in locations}
    problems = []
    for folder in SOURCES:
        for path in sorted(folder.glob("*.swift")):
            text = path.read_text()
            if "// loc:ignore-file" in text[:2000]:
                continue
            lines = text.split("\n")
            for line, column, value in literals(text):
                if not CJK.search(value):
                    continue
                source_line = lines[line - 1]
                previous = lines[line - 2] if line > 1 else ""
                if "loc:ignore" in source_line or "loc:ignore-next" in previous:
                    continue
                # A literal inside another localized literal's interpolation is covered by the outer key.
                if (path.name, line, column) in covered:
                    continue
                problems.append(f"{path.relative_to(ROOT)}:{line}:{column}: {value[:90]}")
    return problems


def parse_strings(path):
    """English table; plural entries in the .stringsdict beside it count as translated."""
    table = {}
    plurals = path.with_suffix(".stringsdict")
    if plurals.exists():
        import plistlib
        for key, entry in plistlib.loads(plurals.read_bytes()).items():
            table[key] = key  # placeholders match by construction
    if not path.exists():
        return table
    pattern = re.compile(r'^"((?:[^"\\]|\\.)*)"\s*=\s*"((?:[^"\\]|\\.)*)";', re.M)
    for key, value in pattern.findall(path.read_text()):
        table[unescape(key)] = unescape(value)
    return table


def unescape(s):
    return re.sub(r'\\(.)', lambda m: {"n": "\n", "t": "\t", '"': '"', "\\": "\\"}.get(m.group(1), m.group(0)), s)


def escape(s):
    return s.replace("\\", "\\\\").replace('"', '\\"').replace("\n", "\\n").replace("\t", "\\t")


def placeholders(s):
    return sorted(re.findall(r"%(?:\d+\$)?[-+ #0]*\d*(?:\.\d+)?(?:ll|l|h)?[dfs@uxXeEgGc]", s))


def write_strings(found, english):
    """Rewrites the English table grouped by the source file that first uses each key."""
    by_file = {}
    plural_keys = set()
    plurals = ENGLISH.with_suffix(".stringsdict")
    if plurals.exists():
        import plistlib
        plural_keys = set(plistlib.loads(plurals.read_bytes()))
    for key, locations in found.items():
        if key in english and key not in plural_keys:
            file, line, _ = min(locations, key=lambda l: (Path(l[0]).name, l[1] or 0))
            by_file.setdefault(Path(file).name, []).append((line or 0, key))
    out = ["/* English for Lucet 光集. Keys are the Simplified Chinese source text.",
           "   Maintained with scripts/localize.py (merge / check). */", ""]
    for file in sorted(by_file):
        out.append(f"/* {file} */")
        for _, key in sorted(by_file[file]):
            out.append(f'"{escape(key)}" = "{escape(english[key])}";')
        out.append("")
    leftover = sorted(k for k in english if k not in found and k not in plural_keys)
    if leftover:
        out.append("/* Not used by the current code (kept until reviewed) */")
        out += [f'"{escape(k)}" = "{escape(english[k])}";' for k in leftover]
        out.append("")
    ENGLISH.parent.mkdir(parents=True, exist_ok=True)
    ENGLISH.write_text("\n".join(out))


def sync_chinese_plurals():
    """Chinese has no plural forms, but every plural key needs a zh-Hans entry too: a key missing
    there falls back to the development language (English) for .stringsdict lookups."""
    import plistlib
    english = ENGLISH.with_suffix(".stringsdict")
    if not english.exists():
        return
    spec = re.compile(r"%(?:\d+\$)?[-+ #0]*\d*(?:\.\d+)?(?:ll|l|h)?[dfs@uxXeEgGc]")
    chinese = {}
    for key, entry in plistlib.loads(english.read_bytes()).items():
        match = re.search(r"%(?:(\d+)\$)?#@n@", entry["NSStringLocalizedFormatKey"])
        index = int(match.group(1)) if match and match.group(1) else 1
        specs = list(spec.finditer(key))
        multiple, parts, last = len(specs) > 1, [], 0
        for number, found in enumerate(specs, start=1):
            parts.append(key[last:found.start()])
            if number == index:
                parts.append(f"%{number}$#@n@" if multiple else "%#@n@")
            else:
                parts.append(f"%{number}${found.group(0)[1:]}" if multiple else found.group(0))
            last = found.end()
        parts.append(key[last:])
        chinese[key] = {"NSStringLocalizedFormatKey": "".join(parts),
                        "n": {"NSStringFormatSpecTypeKey": "NSStringPluralRuleType",
                              "NSStringFormatValueTypeKey": "lld", "other": "%lld"}}
    target = ROOT / "Localization/zh-Hans.lproj/Localizable.stringsdict"
    data = plistlib.dumps(chinese, sort_keys=True)
    if not target.exists() or target.read_bytes() != data:
        target.write_bytes(data)
        print("updated", target.relative_to(ROOT))


def main():
    command = sys.argv[1] if len(sys.argv) > 1 else "check"
    if command in ("extract", "check"):
        extract()
    found = keys()
    english = parse_strings(ENGLISH)
    status = 0
    if command in ("audit", "check"):
        problems = audit(found)
        for problem in problems:
            print("untranslatable:", problem)
        status |= bool(problems)
    if command in ("missing", "check"):
        # Chinese keys, plus explicit ids like "filter.photos" (String(localized:defaultValue:)).
        missing = [k for k in found if k not in english and (CJK.search(k) or re.fullmatch(r"[a-z]+(\.[A-Za-z0-9]+)+", k))]
        for key in sorted(missing):
            f, l, _ = found[key][0]
            print(f"missing: {Path(f).name}:{l}: {key}")
        status |= bool(missing)
        mismatched = [k for k in found if k in english and placeholders(k) != placeholders(english[k])]
        for key in mismatched:
            print(f"placeholders differ: {key!r} -> {english[key]!r}")
        status |= bool(mismatched)
    if command == "check":
        sync_chinese_plurals()
        unused = [k for k in english if k not in found]
        for key in unused:
            print("unused:", key)
        print(f"{len(found)} keys, {len(english)} English, {len(unused)} unused")
    if command == "merge":
        # merge <file.json>: {chinese key: english}
        additions = json.loads(Path(sys.argv[2]).read_text())
        english.update(additions)
        write_strings(found, english)
        sync_chinese_plurals()
        print(f"{len(additions)} merged, {len(english)} English entries")
    if command == "wrap":
        wrap(found)
    if command == "dump":
        json.dump({k: [f"{Path(f).name}:{l}" for f, l, _ in v] for k, v in found.items()},
                  sys.stdout, ensure_ascii=False, indent=1)
    sys.exit(status)


if __name__ == "__main__":
    main()
