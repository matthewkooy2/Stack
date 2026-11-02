"""Audit declared npm/Python dependencies; fail closed on incomplete scans.

Generated manifests and unfiltered reports live under ignored .jac/security.
Existing npm exceptions apply only to direct advisories on exact locked versions.
"""
import argparse
from datetime import date
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tomllib

ROOT = Path(__file__).resolve().parents[1]
NPM_TARGETS = ("native", "web", "mobile")
PYTHON_TARGETS = ("api", "browser", "discovery")
BLOCKING = {"high", "critical"}


def exceptions(document, today=None):
    today = today or date.today()
    approved = {}
    for entry in document["exceptions"]:
        for field in ("advisory", "package", "version", "scope", "reason",
                      "mitigation", "owner", "review_by"):
            if not isinstance(entry.get(field), str) or not entry[field].strip():
                raise ValueError(f"Exception requires {field}")
        if not re.fullmatch(r"GHSA-[a-z0-9]{4}-[a-z0-9]{4}-[a-z0-9]{4}", entry["advisory"]):
            raise ValueError("Exception requires a specific GHSA identifier")
        if date.fromisoformat(entry["review_by"]) <= today:
            raise ValueError(f"Exception expired: {entry['advisory']} ({entry['review_by']})")
        key = (entry["advisory"], entry["package"])
        if key in approved:
            raise ValueError(f"Duplicate exception: {key}")
        approved[key] = entry
    return approved


def npm_findings(report, lock, approved):
    if report.get("error") or report.get("auditReportVersion") != 2:
        raise ValueError("npm audit failed or returned an unsupported report")
    findings = report.get("vulnerabilities")
    if not isinstance(findings, dict) or not isinstance(report.get("metadata"), dict):
        raise ValueError("Incomplete npm audit report")
    failures = []
    complete = set()
    accepted_logged = set()

    def visit(name, trail):
        if name in complete:
            return True
        if name in trail:
            return False
        item = findings[name]
        if item.get("severity") not in {"info", "low", "moderate", "high", "critical"}:
            raise ValueError(f"Unknown npm severity: {name}")
        if not isinstance(item.get("via"), list) or not item["via"]:
            raise ValueError(f"Missing npm advisory evidence: {name}")
        evidence = False
        for via in item["via"]:
            if isinstance(via, str):
                if via not in findings:
                    raise ValueError(f"Unresolved npm advisory: {via}")
                evidence = visit(via, trail | {name}) or evidence
                continue
            if not isinstance(via, dict):
                raise ValueError("Malformed npm advisory")
            evidence = True
            severity = via.get("severity")
            if severity not in {"info", "low", "moderate", "high", "critical"}:
                raise ValueError("Missing npm advisory severity")
            if severity not in BLOCKING:
                continue
            match = re.fullmatch(r"https://github.com/advisories/(GHSA-[a-z0-9-]+)",
                                 via.get("url", ""))
            advisory = match[1] if match else via.get("url", "unknown advisory")
            entry = approved.get((advisory, name))
            nodes = item.get("nodes", [])
            versions = {lock.get("packages", {}).get(node, {}).get("version") for node in nodes}
            if (entry and via.get("name") == name and nodes
                    and versions == {entry["version"]}):
                if (advisory, name) not in accepted_logged:
                    print(f"ACCEPTED until {entry['review_by']}: {name}@{entry['version']} {advisory}")
                    accepted_logged.add((advisory, name))
            else:
                failures.append(f"{name} {advisory} ({severity}); versions: {sorted(str(v) for v in versions)}")

        if evidence:
            complete.add(name)
        return evidence

    for name in findings:
        if not visit(name, set()):
            raise ValueError(f"Advisory cycle without evidence: {name}")
    total = report["metadata"].get("vulnerabilities", {}).get("total")
    if not isinstance(total, int) or total != len(findings):
        raise ValueError("npm audit vulnerability count does not match evidence")
    return sorted(set(failures))


def python_findings(report):
    dependencies = report.get("dependencies")
    if not isinstance(dependencies, list) or not dependencies:
        raise ValueError("Missing Python dependency evidence")
    failures = []
    for dependency in dependencies:
        if (dependency.get("skip_reason") or not dependency.get("version")
                or not isinstance(dependency.get("vulns"), list)):
            raise ValueError(f"Unaudited Python dependency: {dependency.get('name')}")
        for vuln in dependency["vulns"]:
            if not vuln.get("id"):
                raise ValueError("Missing Python advisory identifier")
            failures.append(f"{dependency['name']}@{dependency['version']} {vuln['id']}")
    return failures


def npm_manifest(config, target):
    table = config["dependencies"]["npm"]
    dependencies = {name: version for name, version in table.items() if isinstance(version, str)}
    app = "workspace" if target == "web" else "mobile"
    app_table = config["apps"][app].get("dependencies", {}).get("npm", {})
    dependencies.update({name: version for name, version in app_table.items() if isinstance(version, str)})
    # Native-only overrides are declarations too; include them for the mobile scan.
    if target == "mobile":
        dependencies.update(app_table.get("native", {}))
    return {"name": f"stack-security-{target}", "version": "0.0.0", "private": True,
            "dependencies": dependencies, "devDependencies": table.get("dev", {})}


def python_requirements(config, target, root=ROOT):
    if target == "discovery":
        return (root / "discovery/browser-requirements.txt").read_text()
    if target == "browser":
        config = tomllib.loads((root / "deploy/browser.jac.toml").read_text())
    requirements = []  # Jac itself is a standalone binary, not this PyPI distribution.
    for table in ("dependencies", "dev-dependencies"):
        requirements.extend(name + spec for name, spec in config.get(table, {}).items()
                            if isinstance(spec, str))
    if target == "browser":
        requirements.extend((root / "deploy/browser-requirements.txt").read_text().splitlines())
    return "\n".join(requirements) + "\n"


def run(command, cwd, allowed=(0,)):
    result = subprocess.run(command, cwd=cwd, text=True, capture_output=True, timeout=600)
    if result.stderr:
        print(result.stderr, file=sys.stderr)
    if result.returncode not in allowed:
        raise RuntimeError(f"Scanner/installer failed ({result.returncode}): {result.stdout}")
    return result


def scan(ecosystem, target, root=ROOT):
    approved = exceptions(json.loads((root / "docs/dependency-exceptions.json").read_text()))
    output = root / ".jac/security" / f"{ecosystem}-{target}"
    output.mkdir(parents=True, exist_ok=True)
    config = tomllib.loads((root / "jac.toml").read_text())
    if ecosystem == "npm":
        npm = shutil.which("npm.cmd" if os.name == "nt" else "npm")
        if not npm:
            raise RuntimeError("npm is required")
        if target == "native":
            for name in ("package.json", "package-lock.json"):
                shutil.copyfile(root / "native" / name, output / name)
            # Verify manifest/lock agreement; never execute package lifecycle scripts.
            run([npm, "ci", "--ignore-scripts", "--no-audit", "--no-fund"], output)
        else:
            (output / "package.json").write_text(json.dumps(npm_manifest(config, target), indent=2) + "\n")
            run([npm, "install", "--package-lock-only", "--ignore-scripts", "--no-audit", "--no-fund"], output)
        result = run([npm, "audit", "--package-lock-only", "--ignore-scripts", "--include=dev",
                      "--audit-level=high", "--json"], output, (0, 1))
        (output / "audit.json").write_text(result.stdout)
        report = json.loads(result.stdout)
        lock = json.loads((output / "package-lock.json").read_text())
        failures = npm_findings(report, lock, approved)
        print(json.dumps(report, indent=2))
        if result.returncode and not report["vulnerabilities"]:
            raise ValueError("npm failed without vulnerability evidence")
    else:
        requirements = output / "requirements.txt"
        requirements.write_text(python_requirements(config, target, root))
        # Resolve transitive dependencies, not just the declared top-level pins.
        result = run([sys.executable, "-m", "pip_audit", "--strict", "--progress-spinner=off",
                      "-r", str(requirements), "-f", "json"], root, (0, 1))
        (output / "audit.json").write_text(result.stdout)
        report = json.loads(result.stdout)
        failures = python_findings(report)
        print(json.dumps(report, indent=2))
        if result.returncode and not failures:
            raise ValueError("pip-audit failed without vulnerability evidence")
    for failure in failures:
        print(f"BLOCKED: {failure}", file=sys.stderr)
    return 1 if failures else 0


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("ecosystem", choices=("npm", "python", "exceptions"))
    parser.add_argument("target", nargs="?")
    args = parser.parse_args()
    try:
        if args.ecosystem == "exceptions":
            exceptions(json.loads((ROOT / "docs/dependency-exceptions.json").read_text()))
            print("Security exceptions are valid and unexpired.")
            return 0
        targets = NPM_TARGETS if args.ecosystem == "npm" else PYTHON_TARGETS
        if args.target not in targets:
            parser.error(f"target must be one of {targets}")
        return scan(args.ecosystem, args.target)
    except (ValueError, KeyError, TypeError, OSError, RuntimeError, subprocess.TimeoutExpired) as error:
        print(f"Security audit failed: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
