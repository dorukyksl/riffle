"""Scripts/l10n.py, run on a copy of the project: `check` fails when a generated table isn't what `generate` would
write from its JSON, and says to run `generate`.

  python3 Tests/L10n/test_l10n.py   (Scripts/test.sh l10n runs it)
"""
import json
import os
import shutil
import subprocess
import sys
import tempfile
import unittest

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))


class GeneratedTablesTests(unittest.TestCase):
    def setUp(self):
        folder = tempfile.mkdtemp()
        self.addCleanup(shutil.rmtree, folder)
        self.folder = folder
        os.makedirs(os.path.join(folder, "Scripts"))
        shutil.copy(os.path.join(ROOT, "Scripts", "l10n.py"), os.path.join(folder, "Scripts"))
        shutil.copytree(os.path.join(ROOT, "Sources", "Riffle"), os.path.join(folder, "Sources", "Riffle"))
        shutil.copytree(os.path.join(ROOT, "Localization"), os.path.join(folder, "Localization"))

    def l10n(self, *arguments):
        return subprocess.run([sys.executable, "-I", os.path.join(self.folder, "Scripts", "l10n.py"), *arguments],
                              capture_output=True, text=True)

    def path(self, *parts):
        return os.path.join(self.folder, *parts)

    def test_tables_that_match_their_json_pass(self):
        result = self.l10n("check")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("19 generated tables match their JSON", result.stdout)

    def test_a_json_edited_without_generating_fails_until_generate_runs(self):
        path = self.path("Localization", "de.json")
        with open(path, encoding="utf-8") as handle:
            table = json.load(handle)
        english = sorted(table)[0]
        table[english] += " (neu)"
        with open(path, "w", encoding="utf-8") as handle:
            json.dump(table, handle, ensure_ascii=False, indent=2)

        result = self.l10n("check")
        self.assertEqual(result.returncode, 1)
        self.assertIn(os.path.join("Translations", "de.swift"), result.stderr)
        self.assertIn("python3 Scripts/l10n.py generate", result.stderr)
        # One language at a time: only the stale one fails.
        self.assertEqual(self.l10n("check", "de").returncode, 1)
        self.assertEqual(self.l10n("check", "fr").returncode, 0)

        self.assertEqual(self.l10n("generate").returncode, 0)
        result = self.l10n("check")
        self.assertEqual(result.returncode, 0, result.stderr)
        with open(self.path("Sources", "Riffle", "Localization", "Translations", "de.swift"), encoding="utf-8") as handle:
            self.assertIn(" (neu)", handle.read())

    def test_a_hand_edited_or_missing_table_fails(self):
        with open(self.path("Sources", "Riffle", "Localization", "Translations", "ja.swift"), "a", encoding="utf-8") as handle:
            handle.write("// edited by hand\n")
        os.remove(self.path("Sources", "Riffle", "Localization", "Translations", "sv.swift"))
        result = self.l10n("check")
        self.assertEqual(result.returncode, 1)
        self.assertIn("2 generated table(s)", result.stderr)
        self.assertIn(os.path.join("Translations", "ja.swift"), result.stderr)
        self.assertIn(os.path.join("Translations", "sv.swift"), result.stderr)


if __name__ == "__main__":
    unittest.main()
