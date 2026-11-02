# Job score

The job score is one number from 0 to 100: how well the resume information **you confirmed** covers one
saved job's listing. It uses no model. The same confirmed details, listing and month always give the same
score (`agents/job_score.jac`, contract `stack.job_score`, version 1).

It is a guide to where your confirmed experience lines up with a listing. It is **not a prediction of
hiring**, and it is not a writing or ATS score (see [RESUME_SCORING.md](RESUME_SCORING.md) for those).

## Where it appears

**Resume → Tailor → a saved job → Score my resume** (RPC `score_resume`). Nothing is stored.
The score uses the resume the job is attached to (else your default resume, else your only one).

Stack refuses to score, and says so, when:
- the job has no resume: "Upload your resume on the Resume tab first.";
- the resume has no confirmed details: "Confirm your details for … on the Resume tab."

Tailoring review and Tailored resumes still show the document scores from
[RESUME_SCORING.md](RESUME_SCORING.md). Tailoring rewrites wording; it adds no facts, so it cannot raise
the job score.

## What counts as evidence

Only the records you confirmed for that resume:
- records you reviewed and confirmed after a PDF/DOCX import, or the records Stack built from details
  you confirmed (`review_confirmed` with `review.records`);
- confirmed bullet-bank experience you chose for that resume.

These are **never** evidence:
- an unconfirmed import, a saved draft (saving a draft withdraws confirmation), or parser output;
- an uploaded LaTeX source on its own (it can still be tailored, but Stack never confirmed it);
- tailored or model-written text, Agents → Facts saved answers, profile settings and job preferences;
- the name line (kind `title`) and contact lines (an email address or a web address);
- any clause with a negation (`not`, `never`, `cannot`, `n't`, "no experience/knowledge/…"), so
  "Did not lead a team or hold a CPA license." earns nothing for leadership or a CPA license.

A record is split into clauses at `.`, `!`, `?` and `;`. Only the negated clause is left out.

## Canonical inputs

| Input | Canonical form |
|---|---|
| `records` | Confirmed records in order, `{id, kind, text}`, validated by `record_resume.validate_records` (whitespace collapsed). |
| `job` | `title`, `description`, `qualifications`, `eligibility` and `requirements` only. Line endings become `\n`, spaces and tabs collapse, lines are trimmed and blank lines dropped. Company, location, pay, URLs and IDs are ignored. |
| `as_of` | A month, `YYYY-MM`. It ends roles marked Present. The RPC takes an optional `as_of`; it defaults to the current month. |

`inputs.digest` is the SHA-256 of the contract, version and these three canonical inputs, so two results with the
same digest and the same `rubric.vocabulary_digest` are identical. Record IDs are part of the digest because
evidence cites them; renumbering records changes the digest and the citations, not the score.

## Rubric (version 1)

| Component | Weight | How |
|---|---|---|
| Skills | 55 | Each skill the listing names, weighted by where it appears (title and requirements ×3, nice-to-have ×1.5, duties ×1, company intro ×0.5; benefits, pay and EEO text ignored; +25% per extra mention, up to four). A list joined by "or" is one requirement met by any of them. |
| Job title | 10 | Share of the listing title's words (level words like "senior" or "intern" ignored) found in one confirmed role line in an experience section. |
| Education | 10 | The degree level the listing names against degrees in your education section (BSc/MSc/BEng/MEng included). Met 100, one level short 50, short but the listing accepts equivalent experience 75. |
| Experience | 10 | The years the listing asks for against years from the dated role lines in your experience sections, up to `as_of`. Internships count half; overlaps count once. |
| Listing phrases | 15 | Up to ten repeated or required two- and three-word listing phrases, found when the words appear together in one confirmed clause; plus common soft skills at weight 0.5. |

Skill credit depends on the section the confirmed record is in (its last heading):

| Status | Credit | Section |
|---|---|---|
| `applied` | 1.0 | Experience, employment, work, internship or projects |
| `mentioned` | 0.8 | Education, coursework, credentials, summary and any other section |
| `listed` | 0.6 | Skills, technologies, tools, competencies, languages |
| `missing` | 0 | Not in any usable confirmed clause |

A component the listing gives no information for is left out and the others are renormalized. If only the job
title is left, the status is `insufficient_job` and there is no score.

The listing parser and skills vocabulary are shared with document scoring: `scoring.job_requirements`,
`agents/skills.jac` and `discovery/matching.py`. `rubric.vocabulary_digest` identifies the vocabulary files.

## Output

```json
{
  "contract": "stack.job_score", "version": 1,
  "status": "scored",
  "score": 62,
  "components": [{"key": "skills", "label": "Skills", "weight": 55, "score": 71}],
  "requirements": [
    {"kind": "skill", "term": "Python", "alternatives": ["Python"], "required": true, "weight": 4.5,
     "status": "applied", "credit": 1.0, "via": "", "evidence": ["r4"]},
    {"kind": "experience", "term": "2+ years", "required": true, "status": "met", "credit": 1.0,
     "counted_years": 3.0, "quote": "2+ years of experience in data analysis.", "evidence": ["r3"]}
  ],
  "missing_required": ["Data analysis"],
  "listing": {"title": "Python Data Analyst", "years": {}, "education": {}},
  "inputs": {"as_of": "2026-11", "records": 10, "evidence_records": 5,
             "job_digest": "…", "records_digest": "…", "digest": "…"},
  "rubric": {"weights": {}, "credit": {}, "vocabulary_digest": "…"}
}
```

- `status`: `scored` or `insufficient_job` (then `score` is `null` and `components` is empty).
- `requirements[].kind`: `skill`, `title`, `education`, `experience`, `keyword` or `soft_skill`.
  Skills use the statuses above; the others are `met`, `partial` or `missing`.
- `evidence`: IDs of the confirmed records that earned the credit (up to three; ten for experience).
- `missing_required`: required requirements with no credit.

`score_resume` returns `{application_id, resume_id, resume_name, source: "confirmed_records", job_score, score}`.
`score` keeps the earlier summary shape for older clients: `match` is the job score and `quality` is the
writing score of the same confirmed records. New clients read `job_score`. The iOS card shows nothing but
"Update Stack to see this score" for a contract or version it does not know.

## Changing the rubric

Any change that can move a score for the same inputs (weights, credits, patterns, the shared listing parser
or the vocabulary) needs `VERSION` raised, this document updated, and the pinned case in
`tests/test_job_score.py` updated. That test fails on such a change.

## Limits

- Matching is by known skill names and exact phrases, not meaning. "Analyst" does not show "data analysis";
  a synonym the vocabulary lacks is missed. Skills cover technology best; other fields rely more on title,
  education, experience and phrases.
- Negation is by keyword. "Not only … but also …" is left out too (a missed credit, never a false one).
- Sections come from heading words. Records before any heading count as "other".
- Years count only dated role lines in experience sections; a date in a bullet is ignored.
- Credentials and licenses count only as listing phrases, not as required checks.
- A listing that is only an excerpt scores on what it shows.

Run `jac run tests/test_job_score.py` (10 cases, under a second after Jac starts).

For a reproducible old/new comparison, run `jac run tests/job_score_benchmark.py`.
The [synthetic evaluation](JOB_SCORE_EVALUATION.md) records the results and known regressions.
