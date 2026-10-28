# Prepared benchmark validation

Validated on macOS on 2026-10-28. Actual API benchmarking is reserved for the PC.

- Dataset: 66 cases, 60 distinct questions; 24 behavioral and 36 technical base questions.
- Dataset validation: passed.
- Manual harness tests: 12 passed in 0.418 seconds, with provider requests mocked.
- Simulated flow: 528 candidate requests (two repeats), resumption without duplicate
  calls, 264 cross-provider reviews, complete summaries and blinded cards.
- Checked concrete algorithm and SQLite counterexamples behind technical references.
- No real API keys were read and no provider inference calls were made.
- No real provider scores, latency results, cost measurements, or winner are available.
- Windows execution, live API dialects/model access, and billed usage remain unverified
  until the PC smoke tests pass.

Commands run from the worktree root:

```text
python3 benchmarks/coaching/benchmark.py validate
python3 -m unittest discover -s benchmarks/coaching -p 'test_*.py' -v
python3 benchmarks/coaching/benchmark.py plan
```

Source baseline: `859fa64` on branch `codex/ai-coaching-benchmark`. The benchmark is
standalone and does not change the Stack runtime or CI. Reference judgments are
synthetic and provisional. See README.md for the PC sequence and interpretation.
