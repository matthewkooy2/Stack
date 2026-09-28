"""Differential checks against the committed Python implementation; no live calls."""
import base64;
import builtins;
import importlib;
import json;
import os;
import subprocess;
import tempfile;
import from pathlib { Path }
import from types { ModuleType }
import from unittest.mock { patch }

glob BASELINE = "a186068";
glob MODULES = ["contracts", "contacts", "prep", "study", "provider", "research",
                "documents", "security", "notifications", "pubsub", "google", "local_cli", "worker"];

def legacy(name: str) -> ModuleType {
    source = subprocess.check_output(["git", "show", BASELINE + ":agents/" + name + ".py"], text=True);
    module = ModuleType("checkpoint_" + name);
    builtins.exec(compile(source, "checkpoint/" + name + ".py", "exec"), module.__dict__);
    return module;
}

def outcome(fn: any, args: list[any]) -> any {
    try { return {"value": fn(*args)}; }
    except Exception as e { return {"error": type(e).__name__, "message": str(e)}; }
}

def compare(name: str, function: str, cases: list[list[any]]) {
    before = getattr(legacy(name), function);
    after = getattr(importlib.import_module("agents." + name), function);
    for args in cases {
        expected = outcome(before, args);actual = outcome(after, args);
        assert expected == actual, name + "." + function + ": " + repr(args) + " expected=" + repr(expected) + " actual=" + repr(actual);
    }
}

test "production imports resolve to real Jac source" {
    for name in MODULES {
        module = importlib.import_module("agents." + name);
        path = Path(module.__file__ as str);
        assert path.suffix == ".jac", str(path);
        assert "::py::" not in path.read_text(), str(path);
        assert not path.with_suffix(".py").exists(), str(path);
    }
    worker = importlib.import_module("agents.worker");
    with patch.object(worker, "call", side_effect=KeyboardInterrupt),
         patch.dict(os.environ, {"STACK_AGENT_WORKER_TOKEN": "test-token"}) {
        worker.main();
    }
}

test "permissions facts and validation preserve checkpoint behavior" {
    with patch("time.time", return_value=1000.0) {
        compare("contracts", "default_policy", [[]]);
        compare("contracts", "validate_policy", [
            [{}], [{"enabled": True, "expires_at": 2000, "actions": ["model"]}],
            [{"enabled": True, "expires_at": 900}], [{"domains": ["*.example.com"]}],
            [{"daily_limits": {"send_email": 0}}], [{"followup_limit": 4}]
        ]);
        compare("contracts", "validate_facts", [[[]], [[{"key": "resume.project", "value": " Built it ", "verified": True}]],
            [[{"key": "email", "value": "bad address"}]], [[{"key": "x", "value": "a"}, {"key": "x", "value": "b"}]]]);
        compare("contracts", "validate_contact", [[{"name": "A", "email": "A@example.com"}],
            [{"name": "A", "email": "A\nB@example.com"}], [{"name": "A", "source_url": "http://example.com"}]]);
        compare("contracts", "adapter_for", [[url] for url in ["https://jobs.lever.co/a", "http://jobs.lever.co/a",
            "https://jobs.lever.co.attacker.test/a", "https://boards.greenhouse.io/a", "https://jobs.ashbyhq.com/a"]]);
        compare("contracts", "authorize", [
            [{}, "model"], [{"enabled": True, "expires_at": 2000, "actions": ["model"]}, "model"],
            [{"enabled": True, "expires_at": 900, "actions": ["model"]}, "model"]
        ]);
    }
}

test "provider configuration and budget reservations preserve checkpoint" {
    with tempfile.TemporaryDirectory() as tmp {
        path = Path(tmp) / "config.json";
        with patch.dict(os.environ, {"STACK_AGENT_CONFIG": str(path)}) {
            for settings in [{}, {"provider": "codex-cli", "local_cli_owner": "alice", "local_cli_daily_limit": 3},
                {"model": "test", "monthly_cents": 100, "user_monthly_cents": 50,
                 "input_cents_per_million": 100, "output_cents_per_million": 500}] {
                path.write_text(json.dumps(settings));
                compare("contracts", "config", [[]]);
                compare("contracts", "model_status", [["alice"], ["bob"], [""]]);
                compare("contracts", "reserve_cents", [[{}], [{"text": "x" * 10000}]]);
            }
        }
    }
}

test "contact imports study plans and practice fixtures preserve checkpoint" {
    compare("contacts", "parse_contacts", [[s] for s in ["", "A@example.com B@example.com",
        "name,email\nAlice,a@example.com\nBob,b@example.com", "Name,Email,Selected\nAlice,a@example.com,true", "x" * 200001]]);
    compare("study", "plan", [[{"title": title}, feedback] for title in ["Nurse", "Senior Python SQL engineer", "C++ developer"]
        for feedback in [[], [{"rubric": [{"criterion": "Edge cases", "score": 1}, {"criterion": "Reflection", "score": 0}]}]]]);
    compare("prep", "catalog", [[]]);
    compare("prep", "problem", [[p] for p in ["two-sum", "brackets", "project", "missing"]]);
    compare("prep", "validate_session", [[data] for data in [
        {"problem_id": "project"}, {"problem_id": "two-sum", "language": "python", "elapsed_seconds": 42},
        {"problem_id": "project", "elapsed_seconds": True}, {"problem_id": "missing"},
        {"problem_id": "project", "answer": "x" * 30001}, {"problem_id": "project", "canvas": []}]]);
    compare("prep", "evaluate_outputs", [["two-sum", [[1, 0], [0, 1], [], [0, 2], []]],
        ["two-sum", [[0, 0], [True, 1], [], [0, 2], []]], ["brackets", [1, False, True, False, False]], ["sql-funnel", []]]);
}

test "Google message and calendar parsing preserve checkpoint" {
    compare("google", "classify", [[{"id": "m", "payload": {"headers": [{"name": "Subject", "value": subject}]}},
        [{"id": "a", "job": {"company": "Acme", "title": "Engineer"}}]]
        for subject in ["Acme Engineer: thank you for applying", "Acme: Interview", "Acme Engineer: not moving forward"]]);
    compare("google", "calendar_attachment", [[{"mimeType": "text/calendar", "body": {"data": base64.urlsafe_b64encode(s.encode()).decode()}}]
        for s in ["UID:a\nDTSTART:20261002T160000Z\nDTEND:20261002T170000Z",
                  "UID:b\nDTSTART;TZID=America/Detroit:20261002T120000\nDTEND;TZID=America/Detroit:20261002T130000",
                  "UID:c\nDTSTART;TZID=America/Detroit:20261101T013000\nDTEND;TZID=America/Detroit:20261101T023000"]]);
}

test "source validation and CLI failure behavior preserve checkpoint" {
    compare("provider", "sources_for", [[{}], [{"facts": [{"key": "resume.work", "value": "Built it", "verified": True}]}]]);
    before = legacy("provider");after = importlib.import_module("agents.provider");
    cli = importlib.import_module("agents.local_cli");
    contracts = importlib.import_module("agents.contracts");
    c = {**contracts.config(), "provider": "codex-cli", "model": ""};
    for artifact in [{"summary": "No evidence", "evidence": []},
        {"summary": "Bad evidence", "evidence": [{"source": "missing", "quote": "invented"}]}] {
        with patch.object(cli, "generate", return_value=artifact) {
            assert outcome(before.generate, ["fit", {}, c]) == outcome(after.generate, ["fit", {}, c]);
        }
    }
    draft = {"subject": "Suggested", "body": "Suggested text", "selected_fact_keys": ["resume.work"], "evidence": []};
    for company in ["", "Acme"] {
        for followup in [False, True] {
            context = {"contact": {"name": "Alice", "company": company}, "followup": followup,
                "profile": {"name": "Bob"}, "facts": [{"key": "resume.work", "value": "Built it", "verified": True}]};
            with patch.object(cli, "generate", return_value=draft) {
                assert outcome(before.generate, ["draft", context, c]) == outcome(after.generate, ["draft", context, c]);
            }
        }
    }
    for module in [legacy("local_cli"), cli] {
        with patch.object(module.subprocess, "Popen", side_effect=OSError("private detail")) {
            result = outcome(module.run, [["not-installed"], "/tmp"]);
            assert result["error"] == "ValueError";
            assert "private detail" not in result["message"];
        }
    }
}

test "security failures preserve exception messages and hide causes" {
    for module in [legacy("security"), importlib.import_module("agents.security")] {
        with patch.dict(os.environ, {"STACK_CONNECTION_KEY": "invalid"}) {
            with testraises(ValueError) as failure { module.unseal("invalid"); }
            assert failure.value is not None;
            assert str(failure.value) == "Connection could not be unlocked. Reconnect your account.";
            assert failure.value.__cause__ is None;
            assert failure.value.__suppress_context__;
        }
        with testraises(ValueError, `match="Unexpected provider redirect") {
            module.NoRedirect().redirect_request(None, None, 302, "Found", {}, "https://example.com");
        }
        with testraises(ValueError, `match="Provider destination is not allowed") {
            module.http("https://example.com");
        }
    }
}

test "PDF output preserves text checks metadata and diff" {
    modules = [legacy("documents"), importlib.import_module("agents.documents")];
    results = [];
    for module in modules {
        result = module.render_variant("Alice", "Original", [{"key": "resume.work", "value": "Built a tracker.\nUsed Python."}]);
        results.append({k: v for (k, v) in result.items() if k != "content"});
        assert "Built a tracker." in module.extract(result["content"]);
    }
    assert results[0] == results[1];
}

test "operator compatibility command preserves private configuration" {
    with tempfile.TemporaryDirectory() as tmp {
        path = Path(tmp) / "config.json";
        path.write_text(json.dumps({"monthly_cents": 123, "voice": {"enabled": False}}));
        env = {**os.environ, "STACK_AGENT_CONFIG": str(path)};
        owner = "00000000-0000-4000-8000-000000000001";
        command = ["python3", "scripts/agent-admin.py", "provider", "--provider", "codex-cli", "--owner", owner, "--daily-limit", "3"];
        saved = subprocess.run(command, env=env, capture_output=True, text=True, timeout=60);
        assert saved.returncode == 0, saved.stderr;
        config = json.loads(path.read_text());
        assert config["provider"] == "codex-cli" and config["local_cli_owner"] == owner;
        assert config["local_cli_daily_limit"] == 3 and config["monthly_cents"] == 123;
        assert config["voice"] == {"enabled": False};
        assert path.stat().st_mode & 511 == 384;
        before = path.read_text();
        rejected = subprocess.run(command[:-1] + ["101"], env=env, capture_output=True, text=True, timeout=60);
        assert rejected.returncode != 0 and "between 1 and 100" in rejected.stderr;
        assert path.read_text() == before;
    }
}
