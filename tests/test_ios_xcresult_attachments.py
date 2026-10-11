"""Tests for scripts/ci/ios-xcresult-attachments.py using stub xcresulttool output; no Xcode needed."""
import importlib.util
import json
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location("ios_xcresult_attachments", ROOT / "scripts" / "ci" / "ios-xcresult-attachments.py")
helper = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(helper)


def scalar(text):
    return {"_type": {"_name": "String"}, "_value": text}


def ref(identifier):
    return {"_type": {"_name": "Reference"}, "id": scalar(identifier)}


def attachment(name, payload, kind="public.png", lifetime="keepAlways", filename=None):
    return {
        "_type": {"_name": "ActionTestAttachment"},
        "name": scalar(name), "uniformTypeIdentifier": scalar(kind), "lifetime": scalar(lifetime),
        "filename": scalar(filename or f"{payload}.png"), "payloadRef": ref(payload),
    }


ROOT_JSON = {"actions": {"_values": [{"actionResult": {"testsRef": ref("tests-1")}}]}}
PLAN_JSON = {"summaries": {"_values": [{"testableSummaries": {"_values": [{"tests": {"_values": [
    {"subtests": {"_values": [
        {"identifier": scalar("ScreenFlowUITests/testSettings()"), "summaryRef": ref("summary-settings")},
        {"identifier": scalar("ScreenFlowUITests/testJobs()"), "summaryRef": ref("summary-jobs")},
    ]}},
]}}]}}]}}
SUMMARIES = {
    "summary-settings": {"activitySummaries": {"_values": [
        {"attachments": {"_values": [attachment("settings-hub", "p1"), attachment("settings-trace", "p2", kind="public.log", filename="trace.log")]}},
        {"subactivities": {"_values": [{"attachments": {"_values": [attachment("settings-draft retained", "p3")]}}]}},
    ]}},
    "summary-jobs": {"activitySummaries": {"_values": [{"attachments": {"_values": [
        attachment("jobs-detail", "p4"), attachment("jobs-detail", "p4"),
    ]}}]}},
}


ORIGINAL_JOBS = SUMMARIES["summary-jobs"]


class StubTool:
    """A fake `xcrun xcresulttool`. `legacy` states whether `get` needs --legacy (Xcode 16) or rejects it."""

    def __init__(self, legacy=True, graph=True, attachments_command=False):
        self.legacy = legacy
        self.graph = graph
        self.attachments_command = attachments_command
        self.commands = []

    def __call__(self, command):
        self.commands.append(command)
        words = command[2:]
        if words[:1] == ["--help"]:
            return 0, "Usage: xcresulttool <subcommand>\n  export\n  get\n", ""
        wants_legacy = "--legacy" in words
        if words[0] == "export" and words[1] == "attachments":
            if not self.attachments_command:
                return 64, "", "unknown subcommand"
            folder = Path(words[words.index("--output-path") + 1])
            folder.mkdir(parents=True)
            (folder / "A1.png").write_bytes(b"png-one")
            (folder / "notes.txt").write_text("not an image")
            manifest = [{"testIdentifier": "ScreenFlowUITests/testNetwork()",
                         "attachments": [{"exportedFileName": "A1.png", "suggestedHumanReadableName": "network list_0_ABC"},
                                         {"exportedFileName": "notes.txt", "suggestedHumanReadableName": "notes"}]}]
            (folder / "manifest.json").write_text(json.dumps(manifest))
            return 0, "", ""
        if not self.graph or wants_legacy != self.legacy:
            return 64, "", "legacy format requires --legacy" if not wants_legacy else "unknown option --legacy"
        if words[0] == "get":
            identifier = words[words.index("--id") + 1] if "--id" in words else ""
            if not identifier:
                return 0, json.dumps(ROOT_JSON), ""
            if identifier == "tests-1":
                return 0, json.dumps(PLAN_JSON), ""
            if identifier in SUMMARIES:
                return 0, json.dumps(SUMMARIES[identifier]), ""
            return 1, "", "no such id"
        if words[0] == "export":
            target = Path(words[words.index("--output-path") + 1])
            target.write_bytes(("bytes-of-" + words[words.index("--id") + 1]).encode())
            return 0, "", ""
        return 2, "", "unexpected"


class ExportTests(unittest.TestCase):
    def export(self, tool, bundles=("Run.xcresult",)):
        directory = tempfile.TemporaryDirectory()
        self.addCleanup(directory.cleanup)
        out = Path(directory.name) / "evidence"
        paths = []
        for name in bundles:
            path = Path(directory.name) / name
            path.mkdir()
            paths.append(path)
        manifest = helper.Exporter(out, tool).export(paths)
        return out, manifest

    def test_graph_with_legacy_flag_exports_images_and_names(self):
        tool = StubTool(legacy=True)
        out, manifest = self.export(tool)
        self.assertEqual(manifest["method"], "graph")
        self.assertEqual(manifest["errors"], [])
        names = [(item["test"], item["name"]) for item in manifest["attachments"]]
        self.assertEqual(names, [
            ("ScreenFlowUITests/testSettings()", "settings-hub"),
            ("ScreenFlowUITests/testSettings()", "settings-draft retained"),
            ("ScreenFlowUITests/testJobs()", "jobs-detail"),
        ])
        for item in manifest["attachments"]:
            self.assertTrue((out / item["file"]).read_bytes().startswith(b"bytes-of-"))
            self.assertTrue(item["file"].endswith(".png"))
            self.assertEqual(item["lifetime"], "keepAlways")
        self.assertTrue(json.loads((out / "manifest.json").read_text())["attachments"])
        self.assertTrue(any("--legacy" in command for command in tool.commands))

    def test_plain_text_diagnostics_are_exported_as_txt(self):
        extra = {"activitySummaries": {"_values": [{"attachments": {"_values": [
            attachment("ax-tree-reveal-failed", "p9", kind="public.plain-text", filename="tree.txt")]}}]}}
        SUMMARIES["summary-jobs"] = extra
        self.addCleanup(lambda: SUMMARIES.__setitem__("summary-jobs", ORIGINAL_JOBS))
        out, manifest = self.export(StubTool())
        tree = [item for item in manifest["attachments"] if item["name"] == "ax-tree-reveal-failed"]
        self.assertEqual(len(tree), 1)
        self.assertTrue(tree[0]["file"].endswith(".txt"))
        self.assertTrue((out / tree[0]["file"]).exists())

    def test_xcode15_get_without_legacy_flag(self):
        tool = StubTool(legacy=False)
        _, manifest = self.export(tool)
        self.assertEqual(manifest["method"], "graph")
        self.assertEqual(manifest["exported"], 3)
        exports = [command for command in tool.commands if "export" in command and "--type" in command]
        self.assertTrue(exports and all("--legacy" not in command for command in exports))
        self.assertTrue(all(command[command.index("--type") + 1] == "file" for command in exports))

    def test_newer_export_attachments_when_the_graph_is_unavailable(self):
        tool = StubTool(graph=False, attachments_command=True)
        out, manifest = self.export(tool)
        self.assertEqual(manifest["method"], "export-attachments")
        self.assertEqual([item["name"] for item in manifest["attachments"]], ["network list_0_ABC", "notes"])
        self.assertEqual((out / manifest["attachments"][0]["file"]).read_bytes(), b"png-one")
        self.assertTrue(manifest["errors"], "the failed graph route stays on record")

    def test_total_failure_is_recorded_not_raised(self):
        tool = StubTool(graph=False, attachments_command=False)
        out, manifest = self.export(tool)
        self.assertEqual(manifest["exported"], 0)
        joined = " ".join(manifest["errors"])
        self.assertIn("no screenshot attachments could be exported", joined)
        self.assertIn("unknown subcommand", joined)
        self.assertEqual(json.loads((out / "manifest.json").read_text())["exported"], 0)

    def test_missing_tool_is_a_failed_command(self):
        code, _, err = helper.run_command(["definitely-not-a-real-tool-xyz"])
        self.assertNotEqual(code, 0)
        self.assertTrue(err)

    def test_main_never_masks_but_strict_fails_when_empty(self):
        with tempfile.TemporaryDirectory() as directory:
            out = str(Path(directory) / "out")
            bundle = Path(directory) / "Test.xcresult"
            bundle.mkdir()
            failing = StubTool(graph=False)
            self.assertEqual(helper.main([str(bundle), "--output", out], runner=failing), 0)
            self.assertEqual(helper.main([str(bundle), "--output", out, "--strict"], runner=failing), 1)
            self.assertEqual(helper.main([str(bundle), "--output", out, "--strict"], runner=StubTool()), 0)

    def test_no_bundle_is_an_explicit_error(self):
        with tempfile.TemporaryDirectory() as directory:
            manifest = helper.Exporter(Path(directory) / "out", StubTool()).export(helper.find_bundles([directory]))
            self.assertIn("no .xcresult bundle was found", manifest["errors"])


if __name__ == "__main__":
    unittest.main()
