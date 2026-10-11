# Swift speech restoration candidate

Base: `f9acbaebebb6a6583942d2553298141094fa9a87`. This is an isolated local candidate, not a release.

Tracking: [MAT-33](https://linear.app/matt-kooy/issue/MAT-33/restore-on-device-and-optional-live-transcription-in-swift), verified Personal `matt-kooy` workspace / MAT team / Stack project. Bug label; In Progress. Priority remains No priority pending Matt's selection. Existing interview and PC-transcription issue ownership and scope are untouched. Linear automatically linked the mentions of MAT-5 and MAT-20 when creating this issue. Automatic approval review rejected removing those references, citing relationship preservation; they remain intact. The separate verification-only description update succeeded.

## Cause and historical behavior

Swift 0.2.0 (1010.1), built from `4cbe2c5b91d91607c4f4283f9e5c2109e24a3e16`, uses the same recorder and transcription UI source as this base. It records a complete WAV, uploads after Stop, queues PC recognition, and polls for the result. The backend runs whisper.cpp `base.en`, CPU only, in the Linux environment on the Windows host. This is not iPhone inference or an OpenAI transcription API call. Transfer, queueing, model startup and recognition all occur before the result appears. These are source findings, not measured device latencies.

The earlier Expo client has Apple's iOS 26 `SpeechAnalyzer` / `SpeechTranscriber` progressive recognition and an optional live-text display. It requires a supported device and already-installed English speech assets. The Swift migration omitted that native bridge and live display. See [PR 51](https://github.com/matthewkooy2/Stack/pull/51), [PR 56](https://github.com/matthewkooy2/Stack/pull/56), and the [Expo speech source](https://github.com/matthewkooy2/Stack/blob/f9acbaebebb6a6583942d2553298141094fa9a87/native/modules/stack-speech/ios/StackSpeechSession.swift). The old main backend does not advertise client transcript persistence; the old Prep flow can still queue redundant PC transcription even when the phone recognized text.

## Candidate behavior

- Reuse the Expo speech engine, PCM converters and transcript segment logic in Swift. Supported iOS 26 devices with installed English assets recognize during capture. Prep and mock interview recording expose an optional Show live transcript toggle. Hiding text does not stop recognition.
- Keep the existing WAV recording and PC Whisper path when Apple speech is unavailable, fails, times out or drops input. No asset download, hosted speech service, new permission or signing change is added. Builds with older Swift compilers retain fallback only.
- Close the microphone synchronously on Stop, interruption, navigation or account changes; finalize recognition asynchronously. Preserve WAVs and local transcript originals/corrections. Recover unsynced audio and reviewed edits after reopening. A late completion cannot recreate a recording deleted at sign-out.
- Extend the authenticated upload endpoint with optional `local_transcript`. Valid WAV plus a nonblank original creates an already-completed owner-scoped recording, never a Whisper job. Existing audio validation, storage limits and worker authorization remain. A repeated upload cannot replace an original or overwrite an existing PC job.
- Send the original recognized text separately from reviewed corrections. Revision-checked edits preserve the original. Exact acknowledged text is stored locally, so an edit made during sync remains pending. Cross-device text changes stop automatic replacement and retain the phone correction for explicit review.
- Check the server's `client_transcripts` capability before syncing phone text. An old server leaves it safely on the phone instead of silently redoing recognition on the PC. Coaching still requires the existing server persistence; it is not offline coaching.

## Verification and remaining gates

Completed locally using synthetic data only:

- `python3 -m unittest tests.test_transcription -v`: 16 tests pass, including validation, original/edit replay, concurrent replay, ownership, quota and no-worker-claim checks. Fake recognition CLI fixtures; no real model download or recognition latency measurement.
- `python -m unittest tests.test_interview_contract -v`: 3 tests pass.
- `python scripts/ci/ios-swift-static.py`: 57 Swift source files pass structural/backend-call checks.
- `python -m unittest tests.test_ios_swift_static -v`: 9 tests pass.
- `jac check core/transcription.jac`: passes with existing-style warnings.
- `git diff --check`: passes.

The initial endpoint run failed before registration with Jac E1032, Unknown `provider.send`, in unchanged `agents/voice.jac:165`. This was **missing pinned dependencies**, not a confirmed voice-source defect: a native-Linux copy of unmodified f9acbae reproduced the error without its venv (including websockets module-not-found warnings); the exact same source passed type-check in 3.31 seconds after connecting the task-owned pinned environment installed by `jac install --no-npm`. No source workaround was applied to voice.jac.

The final `JAC_DB_SCRATCH=1 JAC_TEST_JOBS=0 jac run --no-serve tests/test_transcription_api.py` passes **3/3 in 86.631 seconds, exit 0**. These are real Jac authenticated endpoint/storage tests through JacTestClient with disposable accounts and synthetic PCM/text, not mocked endpoint replies or device speech. They verify unauthenticated rejection, capability, completed originals/no worker job, reviewed edits/reload/replay, immutable originals and revisions, account isolation/export/deletion, invalid/oversized text, malformed/silent WAV admission, empty/whitespace originals preserving claimable PC fallback, and rejected replacement leaving a PC job unchanged. They do not measure actual Whisper recognition or microphone latency.

All runtime/dependency/cache/Postgres state for this acceptance belongs to `/tmp/stack-speech-api-Rplh3v`, with native candidate/baseline source, the candidate's `.jac/venv`, Jac 0.37.21, pinned websockets 17.0.1 and other repository dependencies, `JAC_CACHE_HOME=/tmp/stack-speech-api-Rplh3v/cache/jac`, and scratch Postgres 16 under that cache. No npm/global dependency install, production config/data, provider credentials or real models were used. Raw final API and successful baseline logs are retained in the task workspace's `speech-api-evidence/` directory. The temporary scratch Postgres is stopped after verification.

`ios/StackTests/SpeechRestorationTests.swift` adds native tests for float microphone conversion, provisional/final text replacement, original/edit durability, account paths, late-deletion safety, raw-audio sync recovery, acknowledged-old-text/newer-edit recovery, cross-device reopen conflicts, legacy-server fallback, and original/correction transport. They are not executed on Windows.

Before release acceptance, use an existing approved Mac with **Xcode 26+ / Swift 6.2+** and run the unsigned `scripts/ci/ios-swift.sh test` route. An older SDK build compiles out Apple speech and cannot validate this restoration. Then test a physical supported iPhone with installed English assets: live text on/off, immediate review after Stop, airplane-mode capture, resume/reopen and edited text, unsupported/missing-assets fallback, pause/resume, interruption, backgrounding, route changes, five-minute limit and sign-out while startup/finalization is pending. Simulator tests do not establish microphone routing, speech assets or physical latency. These gaps do not by themselves prohibit a separately authorized draft PR; publication is currently not authorized.

Measure capture-to-live-text and Stop-to-final-text separately from upload/queue/PC inference/polling using synthetic speech. No device timing, real audio, private transcript or production modification was used for this candidate. Deploy the compatible backend capability before expecting synced phone originals; release/signing remain separate approved tasks.
