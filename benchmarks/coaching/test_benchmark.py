"""Manual checks for misleading comparisons, duplicate billing and reference leakage.

Run: python -m unittest discover -s benchmarks/coaching -p 'test_*.py' -v
No network calls, app runtime, candidate code execution, or CI changes.
"""
import argparse
import contextlib
import copy
import io
import json
import os
from pathlib import Path
import sqlite3
import tempfile
import unittest
from unittest.mock import patch

import benchmark as b


def feedback(case):
    return {"summary": "Practice feedback", "strengths": [], "improvements": ["Explain the key decision."],
            "rubric": {d: {"score": case["reference"]["target_scores"][d], "feedback": "Relevant evidence assessed."} for d in b.dimensions(case)},
            "next_exercises": ["Practice the identified gap with one concrete example."],
            "followup_questions": ["What did you verify?", "What would you change?"],
            "evidence": [{"source": "answer", "quote": case["answer"].split(".")[0], "claim": "Candidate statement"}] if case["answer"] else []}


def response(model, value, complete=True):
    text = json.dumps(value)
    p = model["provider"]
    if p == "openai":
        return {"id": "test", "model": model["model"], "status": "completed" if complete else "incomplete",
                "output": [{"content": [{"type": "output_text", "text": text}]}],
                "usage": {"input_tokens": 100, "output_tokens": 50, "output_tokens_details": {"reasoning_tokens": 20}}}
    if p == "anthropic":
        return {"id": "test", "model": model["model"], "stop_reason": "end_turn" if complete else "max_tokens",
                "content": [{"type": "text", "text": text}], "usage": {"input_tokens": 100, "output_tokens": 50}}
    return {"modelVersion": model["model"], "candidates": [{"finishReason": "STOP" if complete else "MAX_TOKENS",
             "content": {"parts": [{"text": text}]}}],
            "usageMetadata": {"promptTokenCount": 100, "candidatesTokenCount": 30, "thoughtsTokenCount": 20}}


class BenchmarkTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.cases = b.load_cases(b.ROOT / "cases.jsonl")
        cls.cfg = b.read_json(b.ROOT / "models.json")

    def args(self, root, **changes):
        values = dict(cases=b.ROOT / "cases.jsonl", models=b.ROOT / "models.json", out=Path(root),
                      candidates="luna,haiku,gemini,gemini25", subset="all", limit=2, repeats=1,
                      max_output=4096, budget=5., timeout=120.)
        values.update(changes)
        return argparse.Namespace(**values)

    def fake_invoke(self, model, system, data, schema, *rest):
        if system == b.JUDGE_SYSTEM:
            self.assertNotIn("model_alias", data)
            self.assertNotIn("requested_model", data)
            return response(model, {"correctness": 3, "grounding": 3, "actionability": 3, "calibration": 3, "issues": []})
        case = next(c for c in self.cases if c["answer"] == data["answer"])
        return response(model, feedback(case))

    def test_corpus_coverage_and_family_holdout(self):
        """Prevents duplicated questions from masquerading as broad coverage."""
        self.assertEqual(len(self.cases), 66)
        self.assertEqual(len({c["question"] for c in self.cases}), 60)
        self.assertEqual(sum(c["track"] == "behavioral" and not c.get("variant_of") for c in self.cases), 24)
        self.assertEqual(sum(c["track"] == "technical" and not c.get("variant_of") for c in self.cases), 36)
        lookup = {c["id"]: c for c in self.cases}
        self.assertEqual({c["tags"][1] for c in self.cases}, {"strong", "partial", "weak"})
        for c in self.cases:
            if c.get("variant_of"):
                self.assertEqual(b.split(c), b.split(lookup[c["variant_of"]]))

    def test_reference_and_quality_tags_never_reach_candidates(self):
        """Prevents an answer-key leak inflating provider results."""
        for c in self.cases:
            self.assertEqual(set(b.public_input(c)), {"question", "answer", "role", "criteria"})

    def test_score_types_empty_answer_and_fabricated_quotes(self):
        """Prevents malformed or fabricated evidence from appearing valid."""
        c = self.cases[0]
        good = feedback(c)
        self.assertEqual(b.grade(c, good)["mean_absolute_error"], 0)
        bad = copy.deepcopy(good)
        bad["rubric"]["specificity"]["score"] = True
        with self.assertRaises(ValueError):
            b.grade(c, bad)
        bad = copy.deepcopy(good)
        bad["evidence"][0]["quote"] = "Fabricated experience that is not in the answer."
        self.assertFalse(b.grade(c, bad)["evidence_valid"])
        empty = next(c for c in self.cases if c["id"] == "b21")
        self.assertTrue(b.grade(empty, feedback(empty))["evidence_valid"])

    def test_requests_use_official_hosts_and_no_reference_data(self):
        """Prevents keys going to arbitrary endpoints and verifies provider dialects."""
        c = self.cases[0]
        keys = {"OPENAI_API_KEY": "fake-openai", "ANTHROPIC_API_KEY": "fake-anthropic", "GEMINI_API_KEY": "fake-gemini"}
        with patch.dict(os.environ, keys):
            for alias in ("luna", "haiku", "gemini", "gemini25"):
                url, headers, body = b.api_request(self.cfg["models"][alias], b.SYSTEM, b.public_input(c), b.coach_schema(c), 4096)
                self.assertTrue(url.startswith("https://"))
                self.assertNotIn("fake-", json.dumps(body))
                self.assertNotIn("target_scores", json.dumps(body))
                self.assertNotIn("key=", url)
                if alias == "luna":
                    self.assertFalse(body["store"])
                    self.assertTrue(body["text"]["format"]["strict"])
                elif alias == "haiku":
                    self.assertEqual(body["output_config"]["format"]["schema"], b.coach_schema(c))
                else:
                    self.assertIn("responseFormat", body["generationConfig"])
                    self.assertIn("x-goog-api-key", headers)

    def test_thinking_and_cache_usage_not_free_or_double_counted(self):
        """Prevents understated spending and double-counted reasoning tokens."""
        for a in ("luna", "haiku", "gemini", "gemini25"):
            m = self.cfg["models"][a]
            cost, _ = b.usage_cost(m, response(m, {}))
            self.assertAlmostEqual(cost, (100 * m["input_per_million"] + 50 * m["output_per_million"]) / 1e6)
            self.assertIsNone(b.usage_cost(m, {})[0])
        m = self.cfg["models"]["luna"]
        raw = response(m, {})
        raw["usage"]["input_tokens_details"] = {"cached_tokens": 60}
        self.assertAlmostEqual(b.usage_cost(m, raw)[0], (40 * .1 + 60 * .01 + 50 * .5) / 1e6)
        m = self.cfg["models"]["haiku"]
        raw = response(m, {})
        raw["usage"]["cache_read_input_tokens"] = 60
        self.assertAlmostEqual(b.usage_cost(m, raw)[0], (100 * .1 + 60 * .01 + 50 * .5) / 1e6)

    def test_truncated_provider_output_is_not_success(self):
        """Prevents truncated feedback from silently passing."""
        for a in ("luna", "haiku", "gemini"):
            m = self.cfg["models"][a]
            with self.assertRaises(ValueError):
                b.extract(m, response(m, {}, complete=False))

    @patch.dict(os.environ, {"OPENAI_API_KEY": "fake", "ANTHROPIC_API_KEY": "fake", "GEMINI_API_KEY": "fake"})
    def test_end_to_end_resume_judge_and_report(self):
        """Prevents duplicate billing on resume and validates PC artifact flow offline."""
        with tempfile.TemporaryDirectory() as temp, patch.object(b, "invoke", side_effect=self.fake_invoke) as call, contextlib.redirect_stdout(io.StringIO()):
            args = self.args(temp, limit=66, repeats=2)
            b.execute(args)
            self.assertEqual(call.call_count, 528)
            b.execute(args)
            self.assertEqual(call.call_count, 528)
            args.repeats = 1
            b.execute(args, judging=True)
            self.assertEqual(call.call_count, 792)
            b.report(args)
            result = b.read_json(Path(temp) / "summary.json")
            for s in result["models"].values():
                self.assertEqual(s["valid"], 132)
                self.assertEqual(s["judged_count"], 66)
                self.assertEqual(s["reference_mae"], 0)
                self.assertEqual(s["repeated_criterion_range_mean"], 0)
                self.assertEqual(s["paired_criterion_delta_mean"], 0)
                self.assertEqual(s["exact_quote_pass_rate"], 1)
            self.assertGreater(result["known_judge_cost_usd"], 0)
            cards = b.read_json(Path(temp) / "blind-review.json")
            self.assertTrue(cards)
            self.assertNotIn("model_alias", cards[0])
            judgments = b.read_rows(Path(temp) / "judgments.jsonl")
            attempts = {r["task_id"]: r for r in b.read_rows(Path(temp) / "attempts.jsonl")}
            for row in judgments:
                candidate = attempts[row["source_task_id"]]["model_alias"]
                self.assertNotEqual(self.cfg["models"][candidate]["provider"], self.cfg["models"][row["model_alias"]]["provider"])

    @patch.dict(os.environ, {"OPENAI_API_KEY": "fake"})
    def test_budget_stops_before_network_and_settings_cannot_mix(self):
        """Prevents overspending the planning allowance or mixing operating points."""
        with tempfile.TemporaryDirectory() as temp, patch.object(b, "invoke") as call, contextlib.redirect_stdout(io.StringIO()):
            args = self.args(temp, candidates="luna", budget=.000001)
            b.execute(args)
            call.assert_not_called()
            args.max_output = 2048
            with self.assertRaises(ValueError):
                b.execute(args)

    @patch.dict(os.environ, {"OPENAI_API_KEY": "fake"})
    def test_unknown_billing_stops_and_prevents_automatic_resume(self):
        """Prevents a timed-out billed request being silently retried for free."""
        with tempfile.TemporaryDirectory() as temp, patch.object(b, "invoke", side_effect=TimeoutError), contextlib.redirect_stdout(io.StringIO()):
            args = self.args(temp, candidates="luna")
            b.execute(args)
            rows = b.read_rows(Path(temp) / "attempts.jsonl")
            self.assertEqual(len(rows), 1)
            self.assertIsNone(rows[0]["cost_usd"])
            with self.assertRaises(ValueError):
                b.execute(args)

    @patch.dict(os.environ, {"OPENAI_API_KEY": "fake"})
    def test_billed_invalid_response_remains_in_denominator_and_cost(self):
        """Prevents cherry-picked successes hiding schema failures or costs."""
        def bad(model, *unused):
            return response(model, {"invalid": True})
        with tempfile.TemporaryDirectory() as temp, patch.object(b, "invoke", side_effect=bad), contextlib.redirect_stdout(io.StringIO()):
            args = self.args(temp, candidates="luna")
            b.execute(args)
            b.report(args)
            s = b.read_json(Path(temp) / "summary.json")["models"]["luna"]
            self.assertEqual(s["attempts"], 2)
            self.assertEqual(s["valid"], 0)
            self.assertGreater(s["known_candidate_cost_usd"], 0)
            self.assertIsNone(s["reference_mae"])
            self.assertIsNone(s["cost_per_valid_result_usd"])

    def test_inflight_marker_blocks_paid_retry(self):
        """Prevents a crash between response receipt and append causing double billing."""
        with tempfile.TemporaryDirectory() as temp:
            (Path(temp) / "inflight.json").write_text("{}")
            with patch.object(b, "invoke") as call, self.assertRaises(ValueError):
                b.execute(self.args(temp))
            call.assert_not_called()

    def test_provisional_technical_reference_counterexamples(self):
        """Checks concrete facts behind algorithm/SQL scoring with trusted local code."""
        # Counts alone incorrectly accept the nesting counterexample in t02.
        text = "([)]"
        self.assertEqual(sum(c in "([{" for c in text), sum(c in ")]}" for c in text))
        def stack_valid(text):
            stack = []
            for c in text:
                if c in "([{":
                    stack.append(c)
                elif not stack or stack.pop() != {")": "(", "]": "[", "}": "{"}[c]:
                    return False
            return not stack
        self.assertFalse(stack_valid(text))
        def broken_stack(text):
            stack = []
            for c in text:
                if c in "([{":
                    stack.append(c)
                elif not stack:
                    return False
                else:
                    stack.pop()  # Deliberately fails to compare bracket types.
            return not stack
        fixtures = [("([])", True), ("([)]", False), ("", True), ("]", False), ("((", False)]
        self.assertEqual(sum(broken_stack(x) == expected for x, expected in fixtures), 4)
        def two_sum(nums, target):
            seen = {}
            for i, n in enumerate(nums):
                if target - n in seen:
                    return [seen[target - n], i]
                seen[n] = i
            return []
        self.assertEqual(two_sum([3, 3], 6), [0, 1])
        self.assertEqual(two_sum([], 6), [])
        with sqlite3.connect(":memory:") as db:
            db.execute("CREATE TABLE applications(company TEXT, email TEXT)")
            db.executemany("INSERT INTO applications VALUES (?,?)", [("B", None), ("B", "x"), ("A", "a"), ("A", "b"), ("C", None)])
            sql = "SELECT company, COUNT(*) AS total FROM applications GROUP BY company HAVING COUNT(*) >= 2 ORDER BY total DESC, company ASC"
            self.assertEqual(db.execute(sql).fetchall(), [("A", 2), ("B", 2)])
            self.assertEqual(db.execute("SELECT COUNT(*),COUNT(email) FROM applications").fetchone(), (5, 3))


if __name__ == "__main__":
    unittest.main()
