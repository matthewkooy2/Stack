"""Regression tests for fail-closed audits and narrowly scoped exceptions."""
from copy import deepcopy
from datetime import date
import importlib.util
import json
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("security_audit", ROOT / "scripts/security_audit.py")
audit = importlib.util.module_from_spec(spec)
spec.loader.exec_module(audit)


class SecurityAuditTests(unittest.TestCase):
    def setUp(self):
        self.document = {"exceptions": [{"advisory": "GHSA-vfj7-8cjw-p6xm", "package": "braces", "version": "3.0.3", "scope": "Build tooling", "reason": "Reviewed exposure", "mitigation": "Trusted configuration", "owner": "Maintainers", "review_by": "2026-11-04"}]}
        self.approved = audit.exceptions(self.document, date(2026, 10, 6))
        entry = self.document["exceptions"][0]
        self.name = entry["package"]
        self.node = "node_modules/" + self.name
        self.report = {
            "auditReportVersion": 2,
            "metadata": {"vulnerabilities": {"total": 2}},
            "vulnerabilities": {
                self.name: {"severity": "high", "nodes": [self.node], "via": [{
                    "name": self.name, "severity": "high",
                    "url": "https://github.com/advisories/" + entry["advisory"]}]},
                "expo": {"severity": "high", "nodes": ["node_modules/expo"],
                         "via": [self.name]},
            },
        }
        self.lock = {"packages": {self.node: {"version": entry["version"]}}}

    def test_exact_exception_and_propagated_metavulnerability_pass(self):
        self.assertEqual(audit.npm_findings(self.report, self.lock, self.approved), [])

    def test_new_advisory_on_accepted_package_fails(self):
        self.report["vulnerabilities"][self.name]["via"][0]["url"] = "https://github.com/advisories/GHSA-1234-5678-abcd"
        self.assertTrue(audit.npm_findings(self.report, self.lock, self.approved))

    def test_new_advisory_on_parent_still_fails(self):
        self.report["vulnerabilities"]["expo"]["via"].append({
            "name": "expo", "severity": "critical", "url": "https://github.com/advisories/GHSA-1234-5678-abcd"})
        self.assertTrue(audit.npm_findings(self.report, self.lock, self.approved))

    def test_exception_does_not_cover_changed_or_mixed_versions(self):
        for packages in ({self.node: {"version": "3.0.2"}},
                         {self.node: {"version": "3.0.3"}, "nested": {"version": "3.0.2"}}):
            self.lock["packages"] = packages
            self.report["vulnerabilities"][self.name]["nodes"] = list(packages)
            self.assertTrue(audit.npm_findings(self.report, self.lock, self.approved))

    def test_exception_does_not_cover_a_different_package(self):
        item = self.report["vulnerabilities"].pop(self.name)
        item["via"][0]["name"] = "other"
        self.report["vulnerabilities"]["other"] = item
        self.report["vulnerabilities"]["expo"]["via"] = ["other"]
        self.assertTrue(audit.npm_findings(self.report, self.lock, self.approved))

    def test_exception_expires_on_review_date(self):
        with self.assertRaises(ValueError):
            audit.exceptions(self.document, date(2026, 11, 4))

    def test_missing_exception_metadata_and_duplicates_fail(self):
        for field in ("owner", "reason", "mitigation", "review_by"):
            doc = deepcopy(self.document)
            del doc["exceptions"][0][field]
            with self.assertRaises(ValueError):
                audit.exceptions(doc, date(2026, 10, 6))
        self.document["exceptions"].append(self.document["exceptions"][0])
        with self.assertRaises(ValueError):
            audit.exceptions(self.document, date(2026, 10, 6))

    def test_scanner_error_missing_evidence_and_unknown_severity_fail(self):
        variants = [
            {"error": {"code": "ENOAUDIT"}},
            {},
            {"auditReportVersion": 2, "vulnerabilities": {}},
            deepcopy(self.report),
            deepcopy(self.report),
            deepcopy(self.report),
        ]
        variants[3]["vulnerabilities"][self.name]["via"] = ["absent"]
        variants[4]["vulnerabilities"][self.name]["via"][0]["severity"] = "unknown"
        variants[5]["metadata"]["vulnerabilities"]["total"] = 5
        for report in variants:
            with self.assertRaises(ValueError):
                audit.npm_findings(report, self.lock, self.approved)

    def test_advisory_cycle_without_direct_evidence_fails(self):
        self.report["vulnerabilities"][self.name]["via"] = ["expo"]
        with self.assertRaises(ValueError):
            audit.npm_findings(self.report, self.lock, self.approved)

    def test_moderate_is_reported_but_not_blocking(self):
        self.report["vulnerabilities"][self.name]["via"][0]["severity"] = "moderate"
        self.assertEqual(audit.npm_findings(self.report, self.lock, {}), [])

    def test_python_findings_block_and_skipped_packages_fail(self):
        self.assertTrue(audit.python_findings({"dependencies": [{
            "name": "example", "version": "1", "vulns": [{"id": "PYSEC-123"}]}]}))
        self.assertEqual(audit.python_findings({"dependencies": [{
            "name": "example", "version": "1", "vulns": []}]}), [])
        for report in ({}, {"dependencies": []}, {"dependencies": [{
                "name": "unknown", "skip_reason": "not found"}]}):
            with self.assertRaises(ValueError):
                audit.python_findings(report)

    def test_jac_web_and_mobile_declarations_include_dev_dependencies(self):
        import tomllib
        config = tomllib.loads((ROOT / "jac.toml").read_text())
        web = audit.npm_manifest(config, "web")
        mobile = audit.npm_manifest(config, "mobile")
        self.assertEqual(web["dependencies"]["react-router-dom"], "7.18.4")
        self.assertIn("vite", web["devDependencies"])
        self.assertEqual(mobile["dependencies"]["react-native-svg"], "15.15.5")
        self.assertIn("react-native-web", mobile["dependencies"])

    def test_python_scan_includes_dev_and_separate_environments(self):
        import tomllib
        config = tomllib.loads((ROOT / "jac.toml").read_text())
        api = audit.python_requirements(config, "api")
        browser = audit.python_requirements(config, "browser")
        discovery = audit.python_requirements(config, "discovery")
        self.assertNotIn("jaclang", api)
        self.assertIn("reportlab==4.4.10", api)
        self.assertIn("playwright==1.58.0", browser)
        self.assertIn("playwright==1.55.0", discovery)


if __name__ == "__main__":
    unittest.main()
