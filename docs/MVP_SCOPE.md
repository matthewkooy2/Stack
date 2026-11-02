# Stack MVP scope

10-minute iOS demo for an AI agents class. Start as a new user; follow one real job through find → tailor resume → apply → interview prep → track. Cover all five pages, with Prep receiving the most attention.

- **Onboarding:** 2–3 quick-selection screens covering career stage, target role, location and work arrangement; resume upload.
- **Jobs:** swipe left to pass, right to save into Applications; filters; resume-to-job fit score using requirements and keywords. Continue browsing with a small “Saved · Tailor / Apply” action.
- **Resume:** PDF/DOCX upload or guided creation covering contact details, jobs, dates, education, projects, skills and bullets; standard resume editing. Jake and Classic templates; preserve originals. AI rewrites bullets and wording for job-specific ATS fit. Review and accept/reject changes → preview PDF → attach to application. Never expose LaTeX terminology.
- **Applications:** complete a real external application live; use Stack autofill if reliable, otherwise an external browser. Keep applicant-details confirmation short. Track Saved → Applied → Interviewing → Offer / Rejected, with automatic Gmail updates and optional manual edits. Notes, follow-up reminders and calendar required. Link contacts and referral progress. One tap carries job and tailored resume into job-specific Prep.

  Gmail tracking also supports a user-started scan from a chosen past date: discover and import applications for any job, including applications made outside Stack, then track their replies and interview invitations. Clear discoveries import automatically; uncertain details require confirmation. External calendar changes retain their approval step.
- **Networking:** AI discovers relevant people for a specific job; add/import known contacts. Link contact to application, track referral requested/received, draft request and send after review. Demo: find or link a contact to the same application → draft and send referral request; show discovery live only if reliable.
- **Prep:** highest demo priority. Complete job-specific mock interviews with behavioral, project and experience questions; coaching after each answer with minimal friction. Feedback includes scores, strengths, weaknesses and suggested improvements. Users can retry questions and finish early; completed or shortened interviews receive an overall assessment.

**Open:**

Answer each with **MVP / Later / Drop**, plus any quick clarification:

1. **AI resume interview:** Should users be able to chat with AI to build their resume, beyond filling out the guided sections?
2. **Match uploaded layout:** Must Stack recreate an uploaded resume’s appearance, or are Jake/Classic enough?
3. **Job search:** Must users type a role/company to find jobs, beyond swiping and filtering?
4. **Potential score:** Before tailoring, should users see an estimate of how much their resume score could improve?
5. **LinkedIn import:** Must users be able to populate resume details from LinkedIn instead of uploading or entering them?
6. **Swipe setting:** Must users choose whether saving a job continues browsing or immediately offers Tailor/Apply?
7. **LinkedIn presence:** Must users review their LinkedIn profile and get suggested rewrites?
8. **GitHub presence:** Must users get improvements to their GitHub bio, README and repository descriptions?
9. **Portfolio presence:** Must users get improvements to their portfolio headline, About section and project descriptions?
10. **Technical questions:** Must Prep include technical interview questions beyond behavioral, project and experience questions?
11. **Coding exercises:** Must users solve coding exercises in Prep?
12. **Conversational interviewer:** Must the interviewer speak questions and hold a conversation with answer-based follow-ups?
13. **Video interviewer:** Must Prep show a video of someone asking the question, like HireVue?
14. **Camera answers:** Must users be able to record video answers using their camera?
15. **Compare attempts:** Must users compare retries of the same question?
16. **Saved feedback:** Must users revisit feedback from previous answers or sessions?

**Release focus:** fast loads, polished UI, bounded scope and verification of all scoped flows on iPhone.

## Answer coaching flow

Recording transcription becomes editable local text. Get coaching sends the exact visible text snapshot and question to local Qwen. Show feedback, then store that submitted answer and feedback together. A separate draft/session save or expected revision must not block inference. Keep local edits and unsaved feedback available for recovery.
