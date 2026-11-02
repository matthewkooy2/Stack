#if DEBUG
import Foundation

/// Two real coaching replies, with names and figures changed. The coaching step returns free-form prose and its layout
/// differs from one reply to the next, so the reader is tested against both (and the Motion Lab shows them).
enum CoachingSamples {
    /// "Overall: 0/4 — …" and a "Behavioral rubric:" list with "Name: 0/4 — reason" lines.
    static let overallStyle = #"""
Overall: 0/4 — no assessable interview answer was captured.

The transcript discusses Philadelphia fans and does not answer either the displayed ownership question or the project prompt. This may be a recording/transcription mismatch, so retry before treating the score as evidence of your interview ability.

Correctness: No test results were supplied, and this was a behavioral question, so technical correctness cannot be verified.

Behavioral rubric:
Specificity: 0/4 — no relevant situation, actions, or measurable result.
Ownership: 0/4 — your individual responsibility is not identified.
Structure: 0/4 — there is no Situation–Task–Action–Result progression.
Reflection: 0/4 — no tradeoff, lesson, or future improvement is stated.

Technical rubric: Not applicable. There was no technical solution to assess for reasoning, edge cases, complexity, tradeoffs, or communication. If your chosen project is technical, briefly explain the key engineering tradeoff, but keep the answer centered on your decisions and impact.

Focused next practice:
Retry with a 90-second STAR answer. Your billing integration may be a strong ownership story: explain how you discovered or adopted the problem, why it mattered, what you personally built, how you coordinated directly with the provider, one tradeoff you made, the outcome for the 40+ customers, and what you learned. Use “I” for your work and “we” only for genuinely shared work.

A useful outline:
“While working at Acme Corp, I noticed…”
“I took responsibility for…”
“I personally designed/built/coordinated…”
“I chose X over Y because…, accepting…”
“As a result…”
“I learned…, and next time I would…”

Follow-up questions:
1. What did you personally do that would not have happened if you had waited for someone to assign the problem?
2. What alternative did you reject, what downside did your chosen approach introduce, and how did you manage it?
"""#

    /// "Assessment: …" and "Rubric scores (0–4)" with Technical and Behavioral lists, "Name: 0 — reason" without "/4".
    static let assessmentStyle = #"""
Assessment: The response is incomplete and largely unintelligible, so an interviewer could not identify a project, your contribution, a tradeoff, or what you learned. No test results were supplied, so technical correctness cannot be verified.

Rubric scores (0–4)

Technical
Reasoning: 0 — No technical problem or reasoning was explained.
Edge cases: 0 — No risks or failure cases were discussed.
Complexity: 0 — No performance or implementation analysis was provided.
Tradeoffs: 0 — No alternatives or decision criteria were identified.
Communication: 0 — The answer did not form a coherent technical narrative.

These technical scores reflect missing evidence, not necessarily a lack of ability.

Behavioral
Specificity: 0 — No concrete project, challenge, action, or measurable outcome.
Ownership: 0 — Your individual contribution was not established.
Structure: 0 — The response did not follow a recognizable Situation–Task–Action–Result sequence.
Reflection: 0 — No lesson or subsequent behavior change was stated.

Best story to practice

Use your Acme database-performance work. It naturally demonstrates ownership, measurement, and tradeoffs:

“While working at Acme Sports, I noticed that two important endpoints were issuing 41 and 37 SQL queries per request. Although I had not been assigned a performance rewrite, I investigated the query patterns and took ownership of benchmarking alternatives. I first tested a single-query rewrite, but paired benchmarks showed that it increased median latency by 21%, so I rejected it despite its apparent simplicity. I instead introduced batched reads, reducing the query counts to 6 and 1. That improved median latency by 26% and 38%. Before review, I also narrowed the change from 12 files to 4 to reduce risk. I learned to optimize from measured behavior rather than assuming fewer queries or a more elegant design will automatically be faster.”

Focused next practice

Record a 90-second answer using five explicit beats:

1. Situation: What observable problem did you notice?
2. Ownership: Why did you act without being assigned the work?
3. Actions: What did you personally investigate, implement, and measure?
4. Tradeoff and result: What option did you reject, and what changed quantitatively?
5. Reflection: What principle will guide your future work?

Avoid beginning until you can state the story’s one-sentence headline. If speech transcription becomes garbled again, slow down, pause between sections, and check the recording setup.

Two follow-up questions

1. How did you establish that the latency improvement came from your batching change rather than normal variation in the requests?
2. What resistance or risk did you encounter when taking on this work without being asked, and how did you keep stakeholders aligned?
"""#
}
#endif
