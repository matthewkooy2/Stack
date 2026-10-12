# MAT-37 microphone candidate

This candidate builds on PR72 speech restoration. The selected reference was inspected before implementation. Source and synthetic tests are published for hosted acceptance; reference pixels, local checkpoint paths, Library identifiers and raw implementation logs are retained locally.

## Behavior

Both behavioral Prep recording and job-specific mock interviews use RecordingSurface with their actual question and progress. Six bars use measured PCM amplitude on the existing Apple on-device speech path and the durable PC fallback. Pausing drops in-flight writer buffers; stopping finishes the capture-owned meter. Stalled audio decays retained history before the next buffer so silent input cannot revive an old loud signal. Measurement covers all negotiated channels and uses each channel pointer with the buffer stride.

The live transcription button explicitly shows on/off. It changes visibility only, preserving capture, recognition and the final transcript. Unsupported recognition displays a disabled control and the actual eligibility reason; audio remains saved for PC transcription. Permission refusal offers Settings and a recording retry. Background, interruptions, route changes and other automatic stops keep partial audio and provide an explanation. Existing owner checks, transcript review/editing and upload/retry behavior remain in place.

## Observed Windows verification

- `python scripts/ci/ios-swift-static.py`: 63 Swift files passed structural checks.
- `python -m unittest tests.test_ios_swift_static tests.test_interview_contract -v`: 12 tests passed.
- `git diff --check`: passed.
- Independent read-only review reproduced the stale-level resurrection defect, verified its correction, and independently repeated the available checks. Actor annotations address an identified old-compiler inference risk; native compilation has not confirmed it.

These are structural and existing contract checks, not Swift typechecking, XCTest or UI acceptance.

## Authored synthetic native tests, not executed on Windows

`ios/StackTests/MicrophonePCMTests.swift` exercises Float32/Int16 planar and interleaved layouts including later channels, silence/nonfinite/full-scale samples, amplitude mapping, attack/release, clipping hold, quality windows, stale decay, pause/reset/terminal buffers, WAV headers and recovery, five-minute truncation, format rejection, and synthetic recorder permission/startup retry/stop/interruption/generation safety. Visibility tests preserve identity, duration and an existing original/corrected transcript sidecar. A modern-SDK test feeds the real SpeechAudioWriter and AnalyzerInput stream with generated PCM, without a recognizer or microphone.

Injected capture tests prove controller behavior; they do not establish AVAudioEngine interruption/route handling or successful SpeechAnalyzer recognition/finalization. No microphone permission, personal audio or model download was used for development.

## Remaining acceptance gates

On the exact candidate, run unsigned `bash scripts/ci/ios-swift.sh test` on hosted macOS with Xcode 26.6, Swift >=6.2 and an iOS >=26 simulator, matching `.github/workflows/speech-restoration.yml`. Keep the result bundle tied to the candidate SHA. Also compile/test the older compiler/fallback route using the existing iOS Swift workflow or an equivalent Xcode 15.4+ environment.

Rendered simulator/device acceptance must check both recording entry points, full-screen presentation/dismissal, compact screens and largest Dynamic Type, VoiceOver labels and announcements, Reduce Motion, permission denial/Settings return, pause/resume/Stop/retry, on-device eligibility and visible live text, interrupted/background/media-reset/paused-route behavior, and preserved original/final transcripts with hidden live text. Use synthetic/offline fixtures where possible; physical recording requires separately authorized test audio. Physical amplitude accuracy and latency are unmeasured.

Native and visual acceptance remains open until exact-head hosted results establish it. Publication for hosted CI is authorized; merge, deployment, signing, credential and production changes are not. MAT-37 remains In Progress.
