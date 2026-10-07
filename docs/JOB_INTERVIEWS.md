# Job-specific reviewed interviews (MAT-5)

The job-specific flow has a backend and browser workspace interface, plus a native
interview screen in Prep. The native screen reuses the existing recorder: save
transcript edits, choose **Use reviewed transcript in interview**, review the
answer and submit it for analysis. Existing typed drafts are preserved until the
user explicitly selects the recorded transcript. Pending submission freezes
editing and handoff controls. The original MAT-5 physical iPhone checklist remains
open until an installed build is verified. This selects manual reviewed answers, local Qwen
analysis and coaching, optional existing local transcription, and typed fallback.
Live voice, paid/cloud fallback, avatars, video, automatic turn-taking and live
coding are outside this delivery. Normal source merge and its automatic backend
deployment are authorized after checks and independent review pass. Privileged
startup installation and live configuration changes are outside this scope.

## Current implementation

Source implementation and local compiled/browser acceptance do not publish an
installed iPhone build or the live workspace bundle. Verify those release states
separately. Backend automatic deployment currently excludes workspace assets.

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
Final coaching has four required named rubric entries so a local model cannot
repeat one criterion and omit another. It requires evidence-bound strength
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

The backend/browser slice merged in PR42 and automatically deployed at9a00344.
Actual local Qwen accepted two typed synthetic turns and final coaching; actual
Chrome accepted the typed UI flow with controlled model replies. The recorded
API fixture injected a transcript; it did not run speech recognition. These
results do not establish composed speech or installed native acceptance.

The opt-in composed check is `jac run --no-serve scripts/interview-speech-smoke.py
--audio <answer-1.wav> --audio <answer-2.wav> --model qwen3-4b-instruct --url <local-url>`.
Generate fixture speech with the existing offline Windows voice using
`scripts/generate-interview-speech.ps1 -OutputDirectory <owned-fixture-folder>`.
The check requires existing integrity-verified Whisper files, disables automatic
setup, runs the real probe and actual transcription worker, submits the returned
texts/recording IDs through real interview APIs, and uses actual Qwen. It retains
raw model results, original transcripts, latency, word-sequence similarity and
reload evidence. At least85% normalized word-sequence similarity and essential
words are required; synthetic speech is not evidence of physical microphone
accuracy. No model, transcript or scoring output is injected in this check.

`scripts/compile-mobile.jac` and `tests/transcription-native.cjs` exercise the
generated native interface and existing recording adapter with controlled
OS/API/model boundaries. Native fixtures cover the explicit reviewed-transcript
handoff, preserved typed drafts, submission identity/retry, frozen controls during
a delayed save, correction, strengths/rubric/practice display and saved-session
reopen. Physical iPhone evidence remains necessary for device acceptance.
