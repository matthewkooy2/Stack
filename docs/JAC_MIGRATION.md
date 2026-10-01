# Jac migration

Checkpoint before migration: `a186068` (September 28, 2026). The source checkpoint
includes existing uncommitted work, but excludes ignored account data and secrets.
Never delete the project `.jac` directory.

## First milestone

Moved 13 agent modules from Python to real Jac source: contracts, contacts, prep,
study, provider, research, documents, security, notifications, pubsub, Google,
local CLI execution, and worker dispatch. Moved the operator utility to
`scripts/agent-admin.jac`; its old Python command is a small compatibility launcher.
There are no inline Python blocks or duplicate Python implementations in the
migrated modules. Imports keep their original `agents.<module>` names.

This is a source-language migration, not an architecture or database rewrite.
The graph, endpoints, payloads, permissions, budgets, subscription quotas, schemas,
provider commands, and external-action controls remain unchanged. Backend agent
code is pinned to server placement so compilation cannot move it to a client or
introduce native execution during this migration. Python libraries such as pypdf,
ReportLab, cryptography, and the standard library remain dependencies imported
directly from Jac.

## Verification

First-milestone results: 34 existing agent/provider unit tests, nine checkpoint
parity tests, the isolated durable workflow test, actual PDF generation checks,
and the native-screen regression passed. Seventeen Jac source checks passed with
lint warnings. The local API, discovery worker, agent worker, and Metro were
restarted successfully. No live model, Google, browser-submission, voice, or
remote-sandbox certification was performed as part of this migration.

Run from the repository root, with Jac 0.37.21:

```sh
./scripts/jac check agents/*.jac scripts/agent-admin.jac scripts/agent-worker.jac main.jac
./scripts/jac run --no-serve tests/test_agents.py
./scripts/jac run --no-serve tests/test_agent_providers.py
JAC_TEST_JOBS=0 ./scripts/jac test tests/agent_migration_tests.jac
JAC_TEST_JOBS=0 ./scripts/jac test tests/provider_workflow_tests.jac
./scripts/jac run --no-serve tests/agent_documents.jac
node tests/native.cjs
```

Python regression tests run inside the pinned Jac runtime, which provides the
Jac import hook. The native regression requires a running local API. Workflow
tests use a temporary account store. Differential tests read the original Python
source from the checkpoint with `git show`, so retain that commit in test clones.
They check outputs and errors, source resolution, practice fixtures, permissions,
configuration, provider source validation, outreach copy, calendar parsing, PDF
content, and operator command compatibility. They make no live provider calls.

Compiler translation alone is insufficient: this batch required fixing dropped
conditional-expression parentheses and reversed exception chaining. Tests verify
those branches against the checkpoint. Previously unverified external integrations
remain unverified; a language migration does not certify them.

## Remaining work

- Discovery: normalization, matching, ranking, timeline analysis, provider fetches.
- Unchanged sandbox supervision and its exercise harnesses.
- Native and web JavaScript bindings: evaluate one platform API at a time, keeping
  generated React Native/Expo glue where required.
- Development, catalog, backup tooling and existing Python/JavaScript test suites.

Browser sessions, browser HTTP service, LinkedIn, gateway, voice, tailoring, LaTeX,
templates, scoring, skills, parser comparison, and shared experience now use Jac.
Their hosts need the pinned Jac 0.37.21 runtime. Browser images contain only an
explicit source allowlist, Jac, Playwright, and public-URL validation; they have no
account database or model credentials. The unchanged sandbox host still uses its
existing Python boundary. Candidate Python/C++/SQL exercises and their sandbox
harnesses remain in their target languages; converting them would change the app.
JSON data, CSS, manifests, and deployment files are not application-logic migration
targets. Continue in tested batches, without enabling new integrations or changing
account storage as part of the rewrite.
