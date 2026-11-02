# Practice interview library (issue #19)

Status: source implementation, unit and API tests pass. Physical iPhone acceptance is still open.
Related: #6 ([mock interview proposal](mock-interviews.md)).

## What it does

In the native iPhone app, **Prep → Practice interview** opens the library:

1. **Industry.** Asked once and saved on the profile (`Profile.industry`). Onboarding does not
   collect it. It can be changed from the track screen.
2. **Track.** Behavioral is available. Technical is listed as coming soon; coding practice
   remains in Prep → More practice tools.
3. **Slots.** One slot per curated question: ten core behavioral questions for everyone plus
   four for the chosen industry (`agents/data/practice_questions.json`). Slots are fixed, so a
   person's best answer to each one builds up over time.
4. **Interviewer.** The on-device system voice reads the question while an animated
   interviewer card shows speaking and listening states. **Skip interviewer** shows the text
   only; **Replay** repeats it. Recording can start automatically when the question ends.
5. **Answer.** The front camera records a video answer of up to three minutes. If the camera is
   refused or missing, the same session records audio only.
6. **Review.** The answer audio is transcribed by the existing transcription queue. The person
   corrects the transcript, or types it if transcription is unavailable.
7. **Score and feedback.** The existing behavioral coach (`agent_start("prep")`, 0-4 rubric:
   specificity, ownership, structure, reflection) returns a strength, an improvement and a
   follow-up question. The server parses the rubric into a 0-100 score (mean x 25). If the
   model does not return all four ratings, the attempt keeps the feedback and is marked
   **Unscored**; **Score again** retries.
8. **Library.** Each slot opens on its highest-scoring answer. **All answers** lists the rest,
   highest score first, then newest. Any answer can be deleted.

## Where data lives

| Data | Location | Deleted by |
| --- | --- | --- |
| Answer video (`.mov`) | This iPhone only: `Application Support/PracticeVideos/<account>/`, excluded from backup | Delete answer, discard during review, sign-out |
| Answer audio (16 kHz WAV) | Uploaded to the existing transcription store | Delete answer or discard during review |
| Reviewed transcript, coaching, score | Account graph, as a `PrepSession` with `mode: "library"` | Delete answer, account deletion |
| Industry | `Profile.industry` | Changing it or account deletion |

Videos never reach the server: requests are capped at 15 MB and the transcription store accepts
only audio. The transcript and the question go to the account's configured coaching model,
like other Prep coaching.

## Backend endpoints

All are `def:priv`, owner-scoped, and published in `agents/gateway.jac` and
`mobile/feature-rpcs.js`:

`practice_options`, `practice_profile(industry)`, `practice_slots(track)`,
`practice_attempts(question_id)`, `practice_attempt_get(id)`,
`practice_attempt_create(question_id, client_id, answer, recording_id, video_id, duration)` (idempotent on
`client_id`), `practice_attempt_delete(id)`.

Library attempts are excluded from `prep_sessions` and cannot be changed through `prep_save`.
Library questions resolve through `agents/prep.jac` `problem()`, but stay out of `prep_catalog`.

## Known limitations

- The technical track is not built.
- Videos stay on the phone that recorded them. On another device the transcript and score
  appear, with a note that the video is not on this phone.
- The interviewer is the system voice with an animated card, not a lip-synced avatar. It
  asks one fixed question per slot and does not ask live follow-ups.
- Scores are the coaching model's judgment of one answer, not a certification. Local models may
  ignore the score format; those attempts show feedback as Unscored.
- Transcription depends on the existing PC transcription worker. When it is unavailable, the
  person types their answer.

## Upgrade path for the interviewer

`InterviewerClip` (`ios/Stack/Features/Library/Interviewer.swift`) is the seam. The question bank
is fixed, so clips can be rendered once per question offline and shipped or served as static
assets, with no live service:

- Voice: Kokoro-82M (Apache-2.0) or Piper (MIT) text-to-speech.
- Talking head: LivePortrait (MIT), MuseTalk (MIT) or SadTalker (Apache-2.0). Check each
  model's weight license before shipping.
- Live conversational follow-ups later: Pipecat (BSD-2), or the existing `agents/voice.jac`
  realtime gateway.

## Verification

```sh
./scripts/jac check main.jac agents/practice.jac agents/prep.jac agents/provider.jac core/automation.jac agents/gateway.jac
./scripts/jac run --no-serve tests/test_practice_library.py
node tests/live-contract.cjs
bash scripts/ci/ios-swift.sh build
xcodebuild test -project ios/Stack.xcodeproj -scheme Stack -destination '<simulator>' -only-testing:StackTests/PracticeLibraryTests CODE_SIGNING_ALLOWED=NO
```

`tests/test_practice_library.py` supplies fixture coaching text through `agent_finish`; it does
not call a real model. No CI gate was added for it.

Physical iPhone checklist (not yet run):

- [ ] Choose an industry and Behavioral; the slots show core plus industry questions.
- [ ] The interviewer speaks the question; Skip interviewer and Replay work.
- [ ] Record a video answer, review the transcript, and receive a score and feedback.
- [ ] A second, better answer becomes the slot's best answer; All answers lists both.
- [ ] Delete an answer; its video and score disappear.
- [ ] Deny the camera: the answer records audio only. Deny the microphone: a clear message and Settings.
- [ ] Background the app or take a call mid-recording: the partial answer is kept.
- [ ] Sign out: the videos are removed from the phone.
