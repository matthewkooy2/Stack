# Current availability

OpenResume has been removed. PDF detail extraction, PDF-only scoring and parser
checks are paused; uploaded LaTeX tailoring remains available. The descriptions
below that mention the retired parser document earlier behavior. See
[resume parser status](RESUME_PARSER.md).

# Resume Scoring

Stack scores a resume for a saved job with two separate numbers from 0 to 100. It uses no model:
the scores are deterministic, instant and reproducible (`agents/scoring.jac`).

- **Job match:** how well this resume covers this listing.
- **Resume quality:** how the resume reads, regardless of job.

The scores guide tailoring and show what it changed. They are **not a prediction of hiring**.

## Where scores appear

- **Resume → a saved job → Score my resume:**
  - scores the job's resume without a model, and nothing is stored;
  - uses the resume's LaTeX; PDF-only scoring is temporarily unavailable.
- **Tailoring review:** the score before tailoring, and with every proposed change applied.
- **The final result and Resume → Tailored resumes:** before, and the final score after your choices.

**Score details** lists:
- missing skills, marked *add only if true*;
- skills that appear only on a skill line;
- listing phrases not on the resume, and terms repeated too often;
- the years the listing asks for against the years counted from your dates;
- the top issues, each tied to its bullet.

## How scores guide tailoring

Before the model call, Stack scores the original resume and sends `score_guidance`
(`scoring.guidance`) with the tailor request. The guidance lists:
- skills only listed on a skill line;
- missing skills supported by verified facts;
- missing listing phrases;
- weak or repeated openers, unquantified bullets, and wordy bullets.

The prompt allows a change only where the original already supports it. A skill is named in a bullet
only if that bullet's work used it. No number is ever invented. `tailoring.check` still rejects new
terms and new numbers. Missing skills that nothing supports are never suggested to the model; they are
shown to you.

## Job match

| Component | Weight | How |
|---|---|---|
| Hard skills | 55 | See "Hard skills" below. |
| Job title | 10 | Word overlap between the listing title and your work headings. Level words like "new grad" and "intern" are ignored. |
| Education | 10 | The degree level the listing names (`matching.DEGREES`) against your education headings. One level short scores 50, or 75 when the listing accepts equivalent experience. |
| Experience | 10 | The years the listing asks for (`matching.YEARS`) against years from your work dates. Internships count half, and overlaps count once. |
| Other keywords | 15 | See "Other keywords" below. |

A component the listing gives no information for is left out, and the others are renormalized.

**Hard skills.** Each skill the listing names is found with the vocabulary and weighted by where it
appears:

| Where it appears | Weight |
|---|---|
| Title | ×3 |
| Requirements | ×3 |
| Nice-to-have | ×1.5 |
| Duties | ×1 |
| Company intro | ×0.5 |
| Benefits, about-us, values, pay, EEO, work authorization | ignored |

Each extra mention adds 25%, up to four. Resume credit for a skill:
- **1.0** when it appears in a bullet or heading;
- **0.8** elsewhere on the resume, such as coursework;
- **0.6** only on a skill line;
- **0** when absent.

Two more rules apply:
- **Alternatives:** a list joined by "or" ("C, C++, Rust, Java, or Go") counts as *one* requirement,
  met by any one of the skills.
- **Stuffing:** mentions past twice earn nothing, and a term used ≥4 times and more than the listing
  uses it is flagged.

**Other keywords.** Two- and three-word phrases from the listing's requirements and duties that the
listing repeats or places in its requirements. They count only when the words appear together on the
resume. A few soft skills (communication, collaboration…) count at low weight.

## Resume quality

| Component | Weight | Rule (default target) |
|---|---|---|
| Quantified results | 25 | Bullets with a number, %, $ or scale. Full credit at 75% of bullets. |
| Action verbs | 20 | A strong opening verb. Weak openers score 0: "Responsible for", "Helped", "Assisted", "Worked on"… |
| Repetition | 15 | An opening verb used in more than 2 bullets, or a word used in ≥30% of bullets. |
| Brevity | 15 | 8–35 words per bullet, 2–6 bullets per entry, and one page. |
| Clarity | 10 | Filler and buzzwords, personal pronouns, passive voice. |
| Tense | 5 | No present-tense openers in roles that have ended. |
| Parser check | 10 | Currently unavailable; omitted from the score and weight denominator. |

## Where the weights come from

Commercial checkers publish their categories but not their formulas:
- [Jobscan's match rate](https://www.jobscan.co/blog/what-jobscan-match-rate-should-i-aim-for/) weights
  hard skills over soft skills and adds title, education and keywords.
- [Resume Worded](https://resumeworded.com/score-guide) groups 20+ weighted checks as Impact, Brevity
  and Style.
- [Rezi](https://www.rezi.ai/rezi-docs/the-rezi-score-explained) runs 23 audits.

Open-source tools do the same:
- [Resume-Matcher](https://github.com/srbhr/Resume-Matcher) combines keywords with embedding similarity.
- [ats-screener](https://github.com/sunnypatell/ats-screener) scores formatting, keywords, sections,
  experience and education.

Stack follows the same families. It rewards skills you *demonstrate* over skills you list, because
[match rates alone reward keyword lists](https://four-leaf.ai/blog/jobscan-alternatives-2026).

The weights and targets above are Stack's defaults. Apart from the
[Ladders eye-tracking study](https://www.hrdive.com/news/eye-tracking-study-shows-recruiters-look-at-resumes-for-7-seconds/541582/),
published figures (for example "80% of bullets should be quantified") come from vendors. So treat
these numbers as tunable. They are constants at the top of `agents/scoring.jac` and covered by
`tests/test_scoring.py`.

## Skills vocabulary

- `agents/data/skills.json` comes from [O*NET 30.1 Technology Skills](https://www.onetcenter.org/dictionary/30.0/excel/technology_skills.html)
  (CC BY 4.0; see `discovery/NOTICE.md`). It is built with `python3 scripts/build-skills.py` and cleaned
  as follows:
  - formal names become the terms people write ("Structured query language SQL" becomes SQL);
  - categories such as "Spreadsheet software" are dropped;
  - names that are ordinary words ("Act!", "Square", "Excel") match only when capitalized as a name,
    and not at the start of a sentence.
- `agents/data/skill_aliases.json` adds concepts O*NET lacks (machine learning, REST APIs, CI/CD…),
  newer tools, and short forms (JS, Postgres, k8s, GCP).
- `agents/skills.jac` matches them, keeping C++, C#, Node.js and CI/CD whole and splitting
  "Supabase/PostgreSQL".

## Limits

- Hard skills cover technology best. For listings in other fields, the score leans on other keywords,
  title, education and experience.
- Experience counts only dated work entries.
- Listing headings are recognized from common phrasings ("What we're looking for", "Nice to have",
  "Benefits"…).
- A listing that is only an excerpt scores on what it shows.
