#!/usr/bin/env python3
"""Riffle's translations.

Every user-facing string is written in the code as a Turkish/English pair, `L.t("Ayarlar", "Settings")` (or `L.f(...)`
when it has values in it). The other 19 languages look the English text up in a table.

  python3 Scripts/l10n.py extract   writes Localization/source.json: every pair in Sources, with where it is used
  python3 Scripts/l10n.py check     every Localization/<language>.json covers every string, placeholders intact, and
                                    every Sources/Riffle/Localization/Translations/<language>.swift is what `generate`
                                    writes from it (the app uses the Swift: a JSON edited without `generate` fails)
  python3 Scripts/l10n.py check de  the same for one language
  python3 Scripts/l10n.py generate  check the JSON, then write Sources/Riffle/Localization/Translations/<language>.swift
  python3 Scripts/l10n.py generate --partial   only the finished languages (the rest stay empty), for previews

Edit the JSON files, never the generated Swift.
"""
import json
import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SOURCES = os.path.join(ROOT, "Sources", "Riffle")
STRINGS = os.path.join(ROOT, "Localization")
OUTPUT = os.path.join(SOURCES, "Localization", "Translations")

# Language code in the JSON file name -> the Swift name of its table (see Translations.swift).
LANGUAGES = {
    "ar": "ar", "de": "de", "es": "es", "fr": "fr", "he": "he", "id": "id", "it": "it", "ja": "ja", "ko": "ko",
    "nl": "nl", "pl": "pl", "pt-BR": "ptBR", "ru": "ru", "sv": "sv", "th": "th", "vi": "vi",
    "zh-CN": "zhCN", "zh-HK": "zhHK", "zh-TW": "zhTW",
}

# Strings that are the same in every language (names, symbols); a translation may still change them.
SAME_EVERYWHERE = {"Riffle", "Liquid Glass", "%1$@ / %2$@ pencere"}

CALL = re.compile(r"\bL\.(t|f)\(")
PLACEHOLDER = re.compile(r"%(?:\d+\$)?[@dDuUxXoOfeEgGcCsSpaA%]")


def fail(message):
    print("l10n: " + message, file=sys.stderr)
    sys.exit(1)


def read_literal(text, start):
    """Reads the Swift string literal opening at `start`; returns (value, index after it)."""
    if text.startswith('"""', start) or text[start] != '"':
        return None, start
    value = []
    index = start + 1
    while index < len(text):
        character = text[index]
        if character == '"':
            return "".join(value), index + 1
        if character == "\n":
            return None, start
        if character == "\\":
            following = text[index + 1]
            if following == "(":
                raise ValueError("interpolation: use L.f with %1$@ placeholders instead")
            if following == "u" and text[index + 2] == "{":
                end = text.index("}", index)
                value.append(chr(int(text[index + 3:end], 16)))
                index = end + 1
                continue
            simple = {"\\": "\\", '"': '"', "'": "'", "n": "\n", "t": "\t", "r": "\r", "0": "\0"}
            if following not in simple:
                raise ValueError("unknown escape \\" + following)
            value.append(simple[following])
            index += 2
            continue
        value.append(character)
        index += 1
    return None, start


def skip_space(text, index):
    while index < len(text) and text[index] in " \t\r\n":
        index += 1
    return index


def extract():
    entries = {}
    problems = []
    for folder, _, files in os.walk(SOURCES):
        if os.path.relpath(folder, SOURCES).startswith(os.path.join("Localization", "Translations")):
            continue
        for name in sorted(files):
            if not name.endswith(".swift"):
                continue
            path = os.path.join(folder, name)
            text = open(path, encoding="utf-8").read()
            relative = os.path.relpath(path, ROOT)
            for match in CALL.finditer(text):
                line = text.count("\n", 0, match.start()) + 1
                where = "%s:%d" % (relative, line)
                if text[:match.start()].rsplit("\n", 1)[-1].lstrip().startswith("//"):
                    continue
                try:
                    index = skip_space(text, match.end())
                    turkish, index = read_literal(text, index)
                    index = skip_space(text, index)
                    if turkish is None or index >= len(text) or text[index] != ",":
                        raise ValueError("the Turkish text isn't one plain string literal")
                    index = skip_space(text, index + 1)
                    english, index = read_literal(text, index)
                    index = skip_space(text, index)
                    if english is None or text[index] not in ",)":
                        raise ValueError("the English text isn't one plain string literal")
                except (ValueError, IndexError) as error:
                    problems.append("%s: %s" % (where, error))
                    continue
                is_format = match.group(1) == "f"
                code = text.split("\n")[line - 1].strip()
                entry = entries.setdefault(english, {"en": english, "tr": turkish, "format": is_format, "uses": [], "code": code})
                if entry["tr"] != turkish:
                    problems.append("%s: \"%s\" is also used with another Turkish text (%s)" % (where, english, entry["uses"][0]))
                entry["format"] = entry["format"] or is_format
                entry["uses"].append(where)
    if problems:
        fail("cannot read every string:\n  " + "\n  ".join(problems))
    source = sorted(entries.values(), key=lambda entry: (entry["uses"][0], entry["en"]))
    os.makedirs(STRINGS, exist_ok=True)
    with open(os.path.join(STRINGS, "source.json"), "w", encoding="utf-8") as handle:
        json.dump(source, handle, ensure_ascii=False, indent=2)
        handle.write("\n")
    print("l10n: %d strings in %d places" % (len(source), sum(len(entry["uses"]) for entry in source)))
    return source


def placeholders(text):
    return sorted(PLACEHOLDER.findall(text))


def check(only=None):
    source = extract()
    keys = {entry["en"]: entry for entry in source}
    problems = []
    tables = {}
    for code in ([only] if only else LANGUAGES):
        path = os.path.join(STRINGS, code + ".json")
        if not os.path.exists(path):
            problems.append("%s.json is missing" % code)
            continue
        try:
            table = json.load(open(path, encoding="utf-8"))
        except json.JSONDecodeError as error:
            problems.append("%s.json: %s" % (code, error))
            continue
        for english in keys:
            if english not in table:
                problems.append("%s: no translation for \"%s\"" % (code, english))
            elif not isinstance(table[english], str) or not table[english].strip():
                problems.append("%s: empty translation for \"%s\"" % (code, english))
            elif keys[english]["format"] and placeholders(table[english]) != placeholders(english):
                problems.append("%s: placeholders differ for \"%s\": %s" % (code, english, table[english]))
            elif not keys[english]["format"] and "%" in table[english] and "%" not in english:
                problems.append("%s: stray %% in \"%s\": %s" % (code, english, table[english]))
        for english in table:
            if english not in keys:
                problems.append("%s: \"%s\" isn't used anymore" % (code, english))
        tables[code] = table
    if problems:
        fail("%d problems:\n  %s" % (len(problems), "\n  ".join(problems)))
    print("l10n: %d languages cover all %d strings" % (len(tables), len(keys)))
    return tables


def swift_literal(text):
    out = []
    for character in text:
        if character == "\\":
            out.append("\\\\")
        elif character == '"':
            out.append('\\"')
        elif character == "\n":
            out.append("\\n")
        elif character == "\t":
            out.append("\\t")
        elif ord(character) < 0x20:
            out.append("\\u{%x}" % ord(character))
        else:
            out.append(character)
    return '"' + "".join(out) + '"'


def table_path(code):
    return os.path.join(OUTPUT, LANGUAGES[code] + ".swift")


def render(code, table):
    """The Swift `generate` writes for one language's table."""
    name = LANGUAGES[code]
    lines = ["// Generated by Scripts/l10n.py from Localization/%s.json: edit the JSON, not this file." % code,
             "extension Translations {"]
    if table:
        lines.append("    static let %s: [String: String] = [" % name)
        for english in sorted(table):
            lines.append("        %s: %s," % (swift_literal(english), swift_literal(table[english])))
        lines.append("    ]")
    else:
        lines.append("    static let %s: [String: String] = [:]" % name)
    lines += ["}", ""]
    return "\n".join(lines)


def check_generated(tables):
    """Every generated table is what `generate` would write from its JSON. Kept out of `check()`, which `generate` runs
    first: bringing a stale table up to date is what `generate` is for."""
    stale = []
    for code in sorted(tables):
        path = table_path(code)
        try:
            with open(path, encoding="utf-8", newline="") as handle:
                current = handle.read()
        except FileNotFoundError:
            current = None
        if current != render(code, tables[code]):
            stale.append(os.path.relpath(path, ROOT))
    if stale:
        fail("%d generated table(s) don't match their JSON, run `python3 Scripts/l10n.py generate`:\n  %s"
             % (len(stale), "\n  ".join(stale)))
    print("l10n: %d generated tables match their JSON" % len(tables))


def generate(partial=False):
    """`partial`: only the languages whose JSON exists and passes; the others keep an empty table (for previews)."""
    if partial:
        tables = {}
        for code in LANGUAGES:
            if os.path.exists(os.path.join(STRINGS, code + ".json")):
                tables.update(check(code))
    else:
        tables = check()
    os.makedirs(OUTPUT, exist_ok=True)
    for code in LANGUAGES:
        with open(table_path(code), "w", encoding="utf-8", newline="") as handle:
            handle.write(render(code, tables.get(code, {})))
    print("l10n: wrote %d tables" % len(tables))


if __name__ == "__main__":
    command = sys.argv[1] if len(sys.argv) > 1 else "check"
    if command == "generate" and "--partial" in sys.argv:
        generate(partial=True)
    elif command == "check":
        only = sys.argv[2] if len(sys.argv) > 2 else None
        if only is not None and only not in LANGUAGES:
            fail("unknown language " + only)
        check_generated(check(only))
    else:
        {"extract": extract, "generate": generate}.get(command, lambda: fail("unknown command " + command))()
