# Job-specific reviewed interviews (MAT-5)

The selected first stage is a browser-verifiable backend and functional interface
in Stack's existing Jac browser workspace. Final iPhone UI integration/refinement
and physical-device acceptance remain later stages. The original MAT-5 physical
iPhone checklist remains open. This selects manual reviewed answers, local Qwen
analysis and coaching, optional existing local transcription, and typed fallback.
Live voice, paid/cloud fallback, avatars, video, automatic turn-taking and live
coding are outside this delivery. Normal source merge and its automatic backend
deployment are authorized after checks and independent review pass. Privileged
startup installation and live configuration changes are outside this scope.

## Current implementation

In the browser workspace, select **Interview**, choose a saved role and start.
The first questions quote the saved listing and a confirmed resume fact when one
is available. With no confirmed resume facts, questions explicitly ask for a real
example or an acknowledged learning gap. A snapshot preserves the role and facts
used when the interview began. The server resolves ownership and linked resume;
clients cannot supply another user's role or unreviewed facts as interview context.

Type an answer, or record it locally and upload it to the existing authenticated
transcription queue. Browser capture produces the same 16 kHz mono PCM WAV input
used by the native recorder. Transcription stays in the existing local worker;
this flow does not use browser speech recognition or the live voice gateway.
Microphone failure leaves typing available. Hiding the page stops recording and
retains the captured WAV in the open component until upload. Capture is limited to
five minutes. Upload failure preserves it for retry while that component is open;
unuploaded audio and unsaved drafts do not survive closing/reloading the page.
Uploaded audio survives through the existing durable recording store.

Review/correct the text before **Save reviewed answer and analyze**. The general
agent worker generates a short strength, improvement and answer-dependent
follow-up. **Ask answer follow-up** inserts that question into the conversation.
The exact quoted answer detail and source evidence are shown. If inference fails,
retry local Qwen or continue with the saved role question using typing. Stop after
two to six reviewed answers, inspect/correct the saved transcript, then request
final coaching. Corrections retain originals, invalidate analysis/coaching and
cancel a pending worker lease. Unanswered generated follow-ups are removed after
a correction; already answered questions remain in history. Final coaching requires
evidence from at least two reviewed answers. Saved interviews reopen through the same authenticated practice
store and export/delete lifecycle as existing sessions.

The worker and claim gate accept only `ollama`/`lmstudio` with a Qwen model ID for
these two operations. Configure the installed model using the existing operator
instructions in [model providers](AGENT_PROVIDERS.md), including its reachable
private origin and context limits. Settings/secrets stay server/worker-side. No
model download, deployment config change, paid call or provider fallback is made
by these endpoints. Unavailable/malformed/stale output leaves reviewed answers
saved and exposes retry or typed continuation. Existing Model permission and
admission gates apply; local attempts have zero API spend and subscription calls.

The interview schema uses only constraints supported by the shared local validator;
explicit checks enforce nonempty text, length and list bounds at both model and
storage boundaries. Models select from defined coaching and practice choices and
quote reviewed answers exactly. Follow-ups combine the selected question with the
exact answer quote and saved role requirement. Arbitrary model prose, including
fabricated achievements paired with genuine quotes, is rejected. Rubric scores
remain model judgments, with source evidence visible; they do not certify skills.
Interview records have their own authenticated list endpoint; ordinary practice
lists and study-plan reuse exclude them, preserving existing practice sessions.
Final coaching requires four distinct behavioral criteria, evidence-bound strength
selections and two distinct visible practice questions. Completed transcription
offers an explicit replacement when an answer has already been typed. A delayed
upload response cannot attach an old recording to a newly opened question.

## Verification commands and limits

```sh
./scripts/jac check main.jac core/automation.jac agents/contracts.jac agents/provider.jac agents/worker.jac web/main.jac
./scripts/jac run --no-serve tests/test_interview.py
python tests/test_interview_contract.py
./scripts/jac run --no-serve tests/test_local_models.py
./scripts/jac run --no-serve scripts/interview-smoke.py --provider lmstudio --model qwen3-4b-instruct --url http://127.0.0.1:1234
```

The fixed acceptance journey provisions synthetic accounts, imports a normalized
role through discovery APIs, saves it, submits two reviewed answers, consumes
actual worker dispatch against a controlled HTTP fixture, corrects a transcript,
finishes and reloads persisted coaching. Controlled fixture responses are mock
inference. The opt-in smoke runs the same journey against an actual configured
local Qwen service and prints its artifacts and per-step latency. Run browser
interaction checks against the built functional UI separately, including connection
loss/recovery, denied microphone and typed fallback. Native microphone/backgrounding
and physical iPhone flow require device evidence before completing MAT-5.

At the initial checkpoint on October 6, 2026, Windows JavaScript/Python syntax and
Git whitespace checks passed. Full Jac/API/worker/storage, actual Qwen and browser
acceptance had not passed: WSL reported allocation failure and command timeouts
during validation. Implementation is retained for continued validation and review;
it is not merged, deployed or physically verified. Installed runtimes inspected:
Ollama qwen3:4b-instruct (`0edcdef34593`, 2.5 GB) and LM Studio model ID
`qwen3-4b-instruct`, on an RTX 2070 SUPER. Prior MAT-28 latency/model evidence does
not certify this interview flow. Record fresh successful measurements before merge.
