# Mock interview MVP proposal

Status: Proposal for team review
Related issue: #6
Date: October 2, 2026

## Current foundation

Stack already has persistent typed practice sessions and model coaching for behavioral and technical practice.

The repository also contains an OpenAI Realtime voice gateway in `agents/voice.jac`. The reviewed code supports spoken input and output, manual answer submission, interruptions, transcript collection, authenticated session claims, and budget checks.

The gateway limits sessions to five minutes and eight model responses. This does not necessarily mean eight completed questions and answers, because the initial question also counts as a response.

This review examined code and documentation only. We did not run the app or verify microphone behavior, playback, interview quality, or end-to-end persistence. Existing documentation lists live interviews as unfinished or uncertified.

## Options to evaluate

| Approach | User experience | Cost | Work needed | Main tradeoff |
| --- | --- | --- | --- | --- |
| Voice interview using the existing gateway | Spoken questions and answers with conversational follow-ups | Usage-based audio/text charges; transcription may add cost | Verify client audio, playback, interruptions, configuration, transcript persistence, and end-to-end behavior | Reuses existing backend work, but reliability and interview quality remain unverified |
| Hosted avatar interviewer, such as Tavus | Live conversation with a visible AI interviewer | Free developer plan includes 25 conversation minutes/month. Starter is $59/month with 100 minutes, then $0.37/minute overage | Integrate the service, configure interview behavior, connect results to Stack, and test phone/browser compatibility | Adds visual presence but introduces another provider; its benefit for practice remains untested |
| Custom animated 3D avatar | A character presents questions while a separate voice system handles conversation | Asset/licensing costs vary; voice/model usage still applies. No verified cost estimate in this review | Source or build the avatar, implement animation and speech synchronization, and test mobile performance | Offers visual control but adds development work beyond the existing voice gateway |
| Recorded video answers to displayed questions | Read a question, record an answer, replay it, and optionally retake it | Recording itself requires no AI service fee; storage, transcription, and coaching may add costs | Implement permissions, recording, playback, retakes, and optional upload/coaching | Useful for reviewing delivery but does not itself provide live conversational follow-ups |

A hosted avatar and a custom 3D avatar are different implementation approaches. Tavus bundles conversation services, so its per-minute price cannot be directly compared with OpenAI audio-token pricing.

### Voice pricing reference

Published USD prices per one million tokens, checked October 2, 2026:

| Model | Audio input | Audio output | Text input | Text output |
| --- | ---: | ---: | ---: | ---: |
| gpt-realtime-2.1 | $32.00 | $64.00 | $4.00 | $24.00 |
| gpt-realtime-2.1-mini | $10.00 | $20.00 | $0.60 | $2.40 |

These are reference options, not the verified model configured in Stack. The gateway reads its model from private settings and requests `whisper-1` for input transcription. Confirm compatibility and applicable transcription pricing before enabling it.

A five-minute session has no fixed price based on duration alone. Actual cost depends on audio, text/context usage, transcription, and any separate coaching request. Measure usage during controlled tests.

## Recommendation

Use the existing voice gateway as the foundation for the first mock-interview MVP, initially focused on short behavioral interviews. Keep typed practice available when voice is unavailable or the user prefers typing.

This recommendation prioritizes reuse of existing code and a smaller integration scope. It does not mean the voice feature is already complete or proven more effective than the alternatives.

The first version should show question text, interviewer playback status, recording status, a timer, and explicit Submit answer, Interrupt, and End interview controls.

Keep manual answer submission for the initial MVP, matching the gateway's current disabled automatic turn detection. Ask one question at a time and provide relevant follow-ups. Offer coaching after the session.

Defer avatars, camera recording, automatic turn-taking, and live coding interviews until the core spoken workflow passes testing. Reconsider visual features after users identify a concrete need for them.

## Proposed user flow

1. Open Prep and choose a behavioral mock interview.
2. Optionally enter a target role without requiring a resume upload.
3. Review microphone use, provider processing, transcript handling, and the five-minute session limit.
4. Start the interview and grant microphone permission. Offer typed practice if voice is unavailable.
5. Hear and read the interviewer's question.
6. Record an answer and tap Submit answer.
7. Receive a relevant follow-up or next question. Allow interruption and early ending.
8. End the session or reach its time/response limit.
9. Review the received transcript and correct transcription errors before requesting coaching.
10. Receive a strength, a specific improvement grounded in the answer, and a suggested next practice step.

Transcript correction and the coaching handoff are proposed requirements. Their compatibility with existing saved records still needs verification.

## Implementation gaps

These are tasks to implement or verify, not confirmed missing code throughout the repository.

- Client integration: Check existing web controls and determine what the native iPhone client needs for microphone capture, audio playback, and secure connectivity.
- Configuration: Confirm the selected model, API credentials, voice service deployment, pricing, and budgets. Existing CLI coaching subscriptions do not automatically provide the gateway's API voice connection.
- Interview behavior: Define behavioral questions, relevant follow-ups, and a closing response within the existing response limit.
- Interruption handling: Verify that interruption stops audible playback and accurately reports the played duration for conversation truncation.
- Transcript and coaching handoff: Verify save/reload behavior, transcript corrections, and use of the reviewed transcript for coaching.
- Failure recovery: Define behavior for denied microphone access, empty answers, connection failures, unavailable budgets, and provider errors.
- Data handling: Explain what reaches providers, what transcripts or response logs are stored, and how users can delete them. The gateway already collects records, so do not promise that nothing is saved before transcript review.
- Documentation: Update readiness claims after testing and reconcile older documentation with observed behavior.

## Acceptance criteria

These checks are proposed and have not been executed in this review.

- A tester can start a session, hear/read a question, submit at least two spoken answers, receive a relevant follow-up, end the session, and review its transcript.
- Playback, recording, and processing states are clear, and submitted answers do not create overlapping interviewer responses.
- Interrupting stops audible playback, and later conversation does not assume the user heard the interrupted portion.
- The session stops at the five-minute or eight-response limit and retains the received transcript.
- Denied microphone access or unavailable voice configuration produces a clear message and access to typed practice.
- A connection failure preserves available transcript content and does not falsely report completion.
- Saved sessions survive reload and remain accessible only to the owning account.
- Transcript corrections are retained, and coaching uses the reviewed version.
- Coaching references the user's actual answer and provides a concrete improvement without inventing experience.
- Controlled tests record actual usage and check budget enforcement against configured provider rates.
- The complete flow is tested in the supported browser and on a physical iPhone before claiming native support.

After functional checks, run a small usability pilot with three volunteers. Record whether they complete the flow without assistance, where they become confused, and whether the follow-ups and feedback are useful. Treat this as early qualitative feedback.

## Next milestone

Have the team review the recommendation, agree on MVP scope, and assign the first implementation task.

The first technical milestone should demonstrate microphone input, question playback, two submitted answers, and transcript retrieval on the intended client. Record failures before adding avatar or video work.

## Sources

### Repository materials reviewed

- Issue #6: https://github.com/matthewkooy2/Stack/issues/6
- `docs/AGENTS_IMPLEMENTATION.md`
- `docs/AGENT_PROVIDERS.md`
- `agents/voice.jac`

### Official external sources

- OpenAI Realtime guide: https://developers.openai.com/api/docs/guides/realtime
- OpenAI conversation and interruption handling: https://developers.openai.com/api/docs/guides/realtime-conversations
- OpenAI pricing: https://developers.openai.com/api/docs/pricing
- Tavus developer pricing: https://www.tavus.io/pricing
- Browser camera/microphone capture: https://developer.mozilla.org/en-US/docs/Web/API/MediaDevices/getUserMedia
- Browser recording: https://developer.mozilla.org/en-US/docs/Web/API/MediaRecorder

Sources checked October 2, 2026. No provider integration was tested in this review.

MDN describes browser APIs, not native iPhone recording. Browser media capture requires permission and a secure context, such as HTTPS or localhost. Provider pricing and model availability should be rechecked before implementation.