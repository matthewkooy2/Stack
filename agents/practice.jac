"""Practice interview library: curated question slots, rubric score parsing and attempt ranking.
Questions live in agents/data/practice_questions.json. No model calls."""
import json;
import re;
import from pathlib { Path }
with entry {
    BANK = json.loads((Path(__file__).parent / 'data' / 'practice_questions.json').read_text(encoding='utf-8'));
    CRITERIA = ['specificity', 'ownership', 'structure', 'reflection'];
    SCORE_LINE = re.compile(r'^\W*(specificity|ownership|structure|reflection)\W*[:=\-]\s*([0-4](?:\.\d)?)\s*(?:/\s*4)?\W*$', re.I | re.M);
    SCORE_HEADING = re.compile(r'^\W*scores?\W*$', re.I | re.M);
    SCORING = 'This is a recorded practice-library answer to context.problem.prompt. Coach the behavioral answer in context.session.answer. '
        'Give one specific strength, one specific improvement grounded in the answer, and one follow-up question an interviewer might ask. '
        'Do not invent experience the answer does not contain. '
        'End with a line reading SCORES, then exactly four lines in this form, each a whole number from 0 to 4: '
        'Specificity: n/4, Ownership: n/4, Structure: n/4, Reflection: n/4.';
}
def industries() -> list[dict[str, str]] {
    return BANK['industries'];
}
def tracks() -> list[dict[str, any]] {
    return BANK['tracks'];
}
def valid_industry(industry: str) -> bool {
    return any(i['id'] == industry for i in BANK['industries']);
}
def question(question_id: str) -> dict[str, any] {
    for q in BANK['questions'] {
        if q['id'] == question_id { return q; }
    }
    raise ValueError('Practice question not found.');
}
"""Core questions for everyone, then the industry's own, in a stable slot order."""
def questions_for(industry: str, track: str = 'behavioral') -> list[dict[str, any]] {
    if track != 'behavioral' { return []; }
    chosen = [q for q in BANK['questions'] if '*' in q['industries'] or industry in q['industries']];
    return sorted(chosen, key=lambda (q: any) { (q['order'], q['id']); });
}
"""Reads the trailing SCORES block. A score is reported only when all four criteria parse."""
def parse_score(text: str) -> dict[str, any] {
    rubric: dict[str, float] = {};
    for m in SCORE_LINE.finditer(text or '') {
        rubric[m.group(1).lower()] = min(4.0, max(0.0, float(m.group(2))));
    }
    feedback = text or '';
    heading = list(SCORE_HEADING.finditer(feedback));
    if heading { feedback = feedback[:heading[-1].start()]; }
    feedback = SCORE_LINE.sub('', feedback).strip();
    complete = all(c in rubric for c in CRITERIA);
    score = round(sum(rubric[c] for c in CRITERIA) / len(CRITERIA) * 25) if complete else None;
    return {'score': score, 'rubric': {c: rubric[c] for c in CRITERIA if c in rubric}, 'feedback': feedback};
}
"""Highest score first; unscored attempts after scored ones; newest first within ties."""
def rank(attempts: list[dict[str, any]]) -> list[dict[str, any]] {
    return sorted(attempts, key=lambda (a: any) { (a.get('score') is None, -(a.get('score') or 0), -a.get('created_at', 0.0)); });
}
