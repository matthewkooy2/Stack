# Local iPhone transcription

Prep → Record saves English PCM WAV audio in the iPhone document directory. Stop uploads with progress through authenticated Stack routes. Audio and job acceptance commit together in private `storage/transcription/recordings.sqlite3`; retrying the same client ID and audio returns the same recording. Jobs continue after closing the app. Original transcription is immutable, edited text saves with revision checks, and failed/cancelled jobs retry their saved audio. Explicit deletion removes the recording; no automatic retention sweep touches existing account data.

Limits: five minutes, 10 MiB, three pending jobs per owner, 50 retained recordings/500 MiB per owner, 100 globally pending jobs, 5 GiB total audio. Expiring job leases reject stale results. One audio lane lock covers setup and inference; inference uses two CPU threads. Other agent lanes remain independent.

## Provisioning through normal deployment

Existing backend packaging includes the new `agents` Python/JSON and `core` Jac files. Normal main deployment installs them and restarts the existing worker. No workflow, privileged helper, service unit, dependency contract, credential, firewall, or network grant changes are required. The unprivileged audio lane first verifies or provisions whisper.cpp v1.8.2, exact official commit `4979e04f5dcaccb36057e059bbaed8a2f5288315`, and the pinned `base.en` weights in `agents/transcription_model.json` (size and SHA-256 verified). Build uses one job, CPU only, and static Whisper/ggml libraries under `.jac/transcription/`. No system packages are installed. Missing `git`, `cmake`, `cc`, or `c++` is a concrete setup failure, reported with the missing tools. Setup has a ten-minute deadline; its own child group stops on failure. Existing source changes or invalid model files are preserved.

After setup, a short synthetic English fixture is transcribed on the PC and checked for the expected words. This verifies load/decode/inference and captures timing; it does not establish human microphone accuracy or Ryzen performance for five-minute recordings. Models and inference are refused on Mac. Model/source downloads contain no user audio. There is no external transcription fallback.

Setup progress/failure appears in the signed-in recording screen. Retry local setup requests another bounded attempt without rerecording. Queued recordings wait during failed setup. `STACK_TRANSCRIPTION_AUTO_SETUP=0` lets an operator disable automatic setup; existing explicit runtime/model overrides must verify and are preserved on failure.

The existing public web response includes only coarse `X-Stack-Transcription-State`, `-Stage`, `-Probe`, and optional `-Missing-Tools` headers. They contain no account IDs, transcript, recording, token, or private path. Signals expire after 45 seconds without a worker heartbeat. These headers allow post-deployment readiness verification through the existing HTTPS route; deployment completion alone remains insufficient evidence of readiness.

## Focused verification

Use Jac 0.37.21. Run `tests.test_transcription`, `tests.test_transcription_api`, and `tests.test_gateway` through a Jac unittest runner with disposable SSD storage. Compile with `scripts/compile-mobile.jac`, then run `node tests/transcription-native.cjs`. These use synthetic/fake model output and mocked OS boundaries; no Mac model download or inference occurs. Physical iPhone microphone permission, interruptions, WAV format, account persistence, and real PC transcription must also be checked after installation.
