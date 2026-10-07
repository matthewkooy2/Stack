# Behavioral interview story bank

MAT-24 adds a private backend story bank to the main Stack API. A story contains
Situation, Task, Action, Result, personal contribution, team contribution, and
learning. Generated factual text is extractive: each field contains its exact
source quotation, not a model-written paraphrase. Empty fields produce explicit
follow-up questions, including unknown outcomes. Question-type recommendations
are model suggestions, not factual claims or hiring predictions.

## Source review and use

1. Call `story_sources` to read the account's explicitly confirmed imported
   resume records, verified `resume.*` facts, and completed recorded-answer
   transcripts. Imported records become available only after confirmation through
   `resume_save_records`; editing or withdrawing confirmation invalidates stale
   source selections. Unconfirmed imports, unverified facts, and incomplete
   recordings are unavailable. No facts are inferred from an unreviewed PDF.
2. Select an exact excerpt describing one event. Review its accuracy and confirm
   `reviewed_single_event=true` with `story_create(source_key, source_revision,
   excerpt, title, reviewed_single_event)`. The title is the user's label. Select
   separate excerpts and create separate stories for unrelated events. Stack
   saves the excerpt, full source, source revision, and review time. Transcripts
   also retain their original pre-correction transcription and model name.
3. Call `story_generate(id, revision)`. The persistent agent queue executes the
   `stories` workflow / `story` step with existing operator model configuration,
   account model permission, quotas, model-response logs, and worker leases.
   Only the selected event is sent to inference. The model selects exact source
   sentence/line IDs; Stack resolves their immutable quotations and source key,
   so the model never needs to reproduce opaque source keys or join text.
   The provider and API completion
   path both check every displayed field's quotation. Personal contribution needs
   an explicit I statement; team contribution needs an explicit team statement.
   Mixed or ambiguous attribution stays missing. Explicit unknown/pending outcome
   quotations also retain the missing-outcome follow-up question.
4. Read `story_get` or `story_list(topic)` using `ownership`, `conflict`,
   `decisions`, or `learning` to retrieve suggested matches and missing-detail
   questions. The source snapshot remains historical when the underlying fact or
   transcript changes; create a new story from the current source to refresh it.
5. Call `story_save(id, revision, fields)` with the details you explicitly confirm.
   Corrections carry `user-confirmed:<revision>:<field>` provenance. Prior content
   remains in history. A late worker response is blocked if the revision changed.
   Generate another draft as a separate story after corrections; generation
   cannot overwrite them. Clear a field with an empty string to mark it missing.
6. `story_delete(id, revision)` removes the bank entry. Historical agent artifacts
   follow the existing agent retention behavior. `account_export` includes the
   bank, and account deletion removes the graph stories and cancels pending work.

All bank endpoints require authentication and agent admission. IDs and source
revisions do not grant access across accounts. Worker completion additionally
requires an anonymous service call with the worker token and current run lease.

## Acceptance evidence and delivery state

Fixed, labeled fictional histories live in
`tests/fixtures/behavioral-stories.json`. They cover distinct events, personal
versus team work, a pending outcome, and sparse resume evidence. They were fixed
before real-model execution. `tests/test_stories.py` checks unsupported claims,
foreign citations, actor promotion, and correction provenance.
`tests/test_stories_api.py` exercises the actual Jac endpoints, graph reload,
worker completion, transcript corrections, stale edits, two accounts, export,
and deletion. With `STACK_STORY_REAL_MODEL=1`, it also runs the real worker
dispatch and configured local inference against those same histories, recording
latency, API test-process peak memory, structured content, and model logs under
`.jac/story-real-evidence.json`. Select an existing LM Studio model with
`STACK_STORY_MODEL_PROVIDER=lmstudio` and `STACK_STORY_MODEL=<installed id>`.
The separate model-server resource measurements belong in the acceptance receipt;
the API test-process RSS does not measure the model server.

Run from an isolated checkout with disposable data and Jac 0.37.21:

```sh
JAC_DB_SCRATCH=1 jac run --no-serve tests/test_stories.py
JAC_DB_SCRATCH=1 jac run --no-serve tests/test_stories_api.py
STACK_STORY_REAL_MODEL=1 STACK_STORY_MODEL_URL=http://127.0.0.1:11434 \
  JAC_DB_SCRATCH=1 jac run --no-serve tests/test_stories_api.py
jac check main.jac core/stories.jac core/automation.jac agents/provider.jac
```

Implementation, executed verification, confirmed merge, and deployment are
reported separately in the issue delivery record. This backend capability does
not certify model quality across real careers or physical-device behavior. A
story-bank UI, automatic event splitting, and prose rewriting are outside this
backend capability. Deployment verification is recorded separately from source
acceptance.
