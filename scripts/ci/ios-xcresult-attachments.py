#!/usr/bin/env python3
"""Export kept test attachments (screenshots) from Xcode .xcresult bundles.

Windows and Linux cannot read a raw .xcresult, so the macOS CI job runs this next to the result bundle and
uploads the PNGs plus a manifest. It only reads the bundle with `xcrun xcresulttool`; no third-party packages.

Two routes are tried, in order, and every failure is recorded in manifest.json rather than hidden:
  1. the object graph: `xcresulttool get [--legacy] --format json` from the root record down through
     actions -> testsRef -> summaryRef -> activity attachments, exporting each payload with
     `xcresulttool export [--legacy] --type file --id <payloadRef>` (Xcode 15, and Xcode 16+ with --legacy);
  2. `xcresulttool export attachments`, which newer Xcode writes with its own manifest.

The exit status is 0 even when nothing could be exported: the build and test steps own the job's result,
and this step is evidence only. Pass --strict to fail when no attachment was exported.
"""
import argparse
import json
import re
import shutil
import subprocess
import sys
from pathlib import Path

IMAGE_TYPES = {"public.png": ".png", "public.jpeg": ".jpg", "public.heic": ".heic"}
IMAGE_SUFFIXES = {".png", ".jpg", ".jpeg", ".heic"}


def run_command(command):
    """Run a command; return (returncode, stdout, stderr). A missing tool is a failed command, not a crash."""
    try:
        done = subprocess.run(command, capture_output=True, text=True, check=False)
    except OSError as error:
        return 127, "", str(error)
    return done.returncode, done.stdout, done.stderr


def value(node):
    """Unwrap xcresulttool's `{"_type":..., "_value": x}` scalar wrapper."""
    if isinstance(node, dict) and "_value" in node:
        return node["_value"]
    return node


def text(node):
    result = value(node)
    return result if isinstance(result, str) else ""


def walk(node):
    """Every dict in a JSON tree, parents first."""
    if isinstance(node, dict):
        yield node
        for child in node.values():
            yield from walk(child)
    elif isinstance(node, list):
        for child in node:
            yield from walk(child)


def ref_id(node):
    """The `id` of a reference object such as testsRef, summaryRef or payloadRef."""
    if isinstance(node, dict):
        return text(node.get("id"))
    return ""


def safe(name, fallback="item"):
    cleaned = re.sub(r"[^A-Za-z0-9._-]+", "-", name).strip("-.")
    return (cleaned or fallback)[:80]


class Exporter:
    def __init__(self, output, runner=run_command):
        self.output = Path(output)
        self.runner = runner
        self.attachments = []
        self.errors = []
        self.method = "none"
        self.legacy_flag = []
        self.counter = 0

    # MARK: object graph route

    def tool(self, *arguments):
        return ["xcrun", "xcresulttool", *arguments]

    def get(self, bundle, identifier=None):
        """Parsed JSON for the root record or a reference, or None. Remembers whether --legacy is needed."""
        variants = [self.legacy_flag] if self.method == "graph" else [["--legacy"], []]
        failures = []
        for flag in variants:
            command = self.tool("get", *flag, "--format", "json", "--path", str(bundle))
            if identifier:
                command += ["--id", identifier]
            code, out, err = self.runner(command)
            if code == 0:
                try:
                    parsed = json.loads(out)
                except ValueError:
                    failures.append(f"{' '.join(command)}: output was not JSON")
                    continue
                if self.method != "graph":
                    self.method = "graph"
                    self.legacy_flag = flag
                return parsed
            failures.append(f"{' '.join(command)}: exit {code}: {err.strip()[:300]}")
        self.errors.extend(failures)
        return None

    def export_file(self, bundle, identifier, destination):
        command = self.tool("export", *self.legacy_flag, "--type", "file", "--path", str(bundle),
                            "--id", identifier, "--output-path", str(destination))
        code, _, err = self.runner(command)
        if code != 0:
            self.errors.append(f"{' '.join(command)}: exit {code}: {err.strip()[:300]}")
            return False
        if not Path(destination).exists():
            self.errors.append(f"{' '.join(command)}: reported success but wrote no file")
            return False
        return True

    def attachments_in(self, summary):
        """Attachment dicts anywhere inside a test summary's activities."""
        for node in walk(summary):
            if "payloadRef" in node and ref_id(node["payloadRef"]):
                yield node

    def export_graph(self, bundle):
        root = self.get(bundle)
        if root is None:
            return False
        summaries = []
        for node in walk(root):
            tests_ref = ref_id(node.get("testsRef")) if "testsRef" in node else ""
            if not tests_ref:
                continue
            plan = self.get(bundle, tests_ref)
            if plan is None:
                continue
            for item in walk(plan):
                summary_ref = ref_id(item.get("summaryRef")) if "summaryRef" in item else ""
                if summary_ref:
                    label = text(item.get("identifier")) or text(item.get("name"))
                    summaries.append((label, summary_ref))
        if not summaries:
            self.errors.append(f"{bundle}: the result contains no test summaries")
        seen = set()
        for label, summary_ref in summaries:
            summary = self.get(bundle, summary_ref)
            if summary is None:
                continue
            test = label or text(summary.get("identifier")) or text(summary.get("name")) or "test"
            for attachment in self.attachments_in(summary):
                payload = ref_id(attachment["payloadRef"])
                if payload in seen:
                    continue
                seen.add(payload)
                self.save_attachment(bundle, test, attachment, payload)
        return True

    def save_attachment(self, bundle, test, attachment, payload):
        name = text(attachment.get("name")) or text(attachment.get("filename")) or "attachment"
        kind = text(attachment.get("uniformTypeIdentifier"))
        filename = text(attachment.get("filename"))
        suffix = IMAGE_TYPES.get(kind) or Path(filename).suffix.lower()
        if suffix not in IMAGE_SUFFIXES and kind and kind not in IMAGE_TYPES:
            return  # logs and other non-image evidence are not screenshots
        suffix = ".jpg" if suffix == ".jpeg" else (suffix or ".png")
        self.counter += 1
        target = self.output / f"{self.counter:03d}-{safe(test.split('/')[-1], 'test')}-{safe(name, 'attachment')}{suffix}"
        if self.export_file(bundle, payload, target):
            self.attachments.append({
                "test": test, "name": name, "file": target.name, "type": kind or suffix.lstrip("."),
                "lifetime": text(attachment.get("lifetime")),
            })

    # MARK: newer export route

    def export_attachments_command(self, bundle):
        folder = self.output / f"_attachments-{safe(bundle.name)}"
        command = self.tool("export", "attachments", "--path", str(bundle), "--output-path", str(folder))
        code, _, err = self.runner(command)
        if code != 0:
            help_code, help_out, _ = self.runner(self.tool("--help"))
            known = help_out.strip().splitlines()[:6] if help_code == 0 else ["xcresulttool did not answer --help"]
            self.errors.append(f"{' '.join(command)}: exit {code}: {err.strip()[:300]}; xcresulttool says: {' | '.join(known)}")
            return False
        manifest = folder / "manifest.json"
        entries = []
        if manifest.exists():
            try:
                entries = json.loads(manifest.read_text(encoding="utf8"))
            except ValueError:
                self.errors.append(f"{manifest}: not valid JSON")
        self.method = "export-attachments"
        for entry in entries if isinstance(entries, list) else []:
            test = entry.get("testIdentifier") or entry.get("testIdentifierURL") or entry.get("testName") or "test"
            for item in entry.get("attachments", []):
                stored = item.get("exportedFileName", "")
                source = folder / stored
                if not stored or not source.exists():
                    continue
                suffix = source.suffix.lower()
                if suffix not in IMAGE_SUFFIXES:
                    continue
                name = item.get("suggestedHumanReadableName") or Path(stored).stem
                self.counter += 1
                target = self.output / f"{self.counter:03d}-{safe(str(test).split('/')[-1], 'test')}-{safe(name, 'attachment')}{suffix}"
                shutil.copyfile(source, target)
                self.attachments.append({"test": str(test), "name": name, "file": target.name,
                                         "type": suffix.lstrip("."), "lifetime": "keepAlways"})
        shutil.rmtree(folder, ignore_errors=True)
        return True

    # MARK: driver

    def export(self, bundles):
        self.output.mkdir(parents=True, exist_ok=True)
        if not bundles:
            self.errors.append("no .xcresult bundle was found")
        for bundle in bundles:
            before = len(self.attachments)
            self.method = "none"
            self.export_graph(bundle)
            if len(self.attachments) == before:
                self.export_attachments_command(bundle)
            if len(self.attachments) == before:
                self.errors.append(f"{bundle}: no screenshot attachments could be exported")
        return self.write_manifest([str(bundle) for bundle in bundles])

    def write_manifest(self, bundles):
        manifest = {
            "results": bundles,
            "method": self.method,
            "exported": len(self.attachments),
            "attachments": self.attachments,
            "errors": self.errors,
        }
        (self.output / "manifest.json").write_text(json.dumps(manifest, indent=2) + "\n", encoding="utf8")
        return manifest


def find_bundles(paths):
    found = []
    for item in paths:
        path = Path(item)
        if path.is_dir() and path.suffix == ".xcresult":
            found.append(path)
        elif path.is_dir():
            found.extend(sorted(path.glob("*.xcresult")))
    return found


def main(argv=None, runner=run_command):
    parser = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    parser.add_argument("results", nargs="*", help=".xcresult bundles, or directories that contain them")
    parser.add_argument("--output", required=True, help="directory for the exported PNGs and manifest.json")
    parser.add_argument("--strict", action="store_true", help="exit 1 when no attachment was exported")
    args = parser.parse_args(argv)
    manifest = Exporter(args.output, runner).export(find_bundles(args.results))
    print(f"Exported {manifest['exported']} attachment(s) using {manifest['method']}.")
    for error in manifest["errors"]:
        print(f"::warning::xcresult export: {error}")
    return 1 if args.strict and manifest["exported"] == 0 else 0


if __name__ == "__main__":
    sys.exit(main())
