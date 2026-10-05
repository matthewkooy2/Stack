"""Keep published evaluation inputs synthetic and reproducible."""
import importlib.util
import json
from pathlib import Path
import unittest
from urllib.parse import urlsplit

FIXTURES = Path(__file__).parent / "fixtures"


class FixtureProvenance(unittest.TestCase):
    def test_synthetic_matrix_is_reproducible_and_uses_example_urls(self):
        spec = importlib.util.spec_from_file_location("generator", FIXTURES / "generate_matching_heldout.py")
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        actual = json.loads((FIXTURES / "matching_heldout.json").read_text(encoding="utf-8"))
        self.assertEqual(actual, module.build())
        self.assertEqual(len(actual["listings"]), 68)
        self.assertEqual(len(actual["personas"]), 7)
        for item in actual["listings"].values():
            self.assertTrue(item["company"].startswith("Synthetic Harbor Employer "))
            self.assertEqual(urlsplit(item["url"]).hostname, "example.invalid")
            self.assertIn("Fictional test vacancy", item["description"])
        for labels in actual["labels"].values():
            self.assertEqual(set(labels.values()), {"suitable", "unknown", "unsuitable"})


if __name__ == "__main__":
    unittest.main()
