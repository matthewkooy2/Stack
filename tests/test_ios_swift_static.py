"""Tests for the toolchain-free Swift checks (scripts/ci/ios-swift-static.py) and the app's backend contract."""
import importlib.util
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location("ios_swift_static", ROOT / "scripts" / "ci" / "ios-swift-static.py")
checker = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(checker)


def scan_text(text: str) -> list[str]:
    with tempfile.TemporaryDirectory() as directory:
        path = Path(directory) / "Sample.swift"
        path.write_text(text, encoding="utf8")
        # scan() reports paths relative to the repository root; place the file under it virtually.
        original = checker.ROOT
        checker.ROOT = Path(directory)
        try:
            return checker.scan(path)
        finally:
            checker.ROOT = original


class DelimiterScanTests(unittest.TestCase):
    def test_balanced_source_passes(self):
        self.assertEqual(scan_text('struct A { func f() -> Int { return [1, 2].count } }\n'), [])

    def test_unclosed_brace_is_reported(self):
        self.assertTrue(any("never closed" in p for p in scan_text("struct A {\n")))

    def test_extra_closer_is_reported(self):
        self.assertTrue(any("unmatched" in p for p in scan_text("struct A { }\n}\n")))

    def test_interpolation_and_raw_strings_are_understood(self):
        source = 'let a = "x \\(f(1, g(2))) y"\nlet b = #"{"k": "\\d+"}"#\nlet c = """\n  ( \\(d) \n  """\n'
        self.assertEqual(scan_text(source), [])

    def test_unterminated_string_is_reported(self):
        self.assertTrue(any("unterminated" in p for p in scan_text('let a = "open\n')))

    def test_comments_are_ignored(self):
        self.assertEqual(scan_text("// ) } ]\n/* ( { [ */\nlet a = 1\n"), [])


class RepositoryTests(unittest.TestCase):
    def test_swift_sources_are_structurally_sound(self):
        self.assertEqual(checker.main(), 0)

    def test_every_backend_call_is_a_published_function(self):
        self.assertEqual(checker.check_backend_calls(), [])

    def test_project_spec_is_complete(self):
        self.assertEqual(checker.check_project(), [])


if __name__ == "__main__":
    unittest.main()
