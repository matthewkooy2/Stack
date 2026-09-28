"""Reviewed exercise selection; source keywords explain each recommendation."""
def plan(
    job: dict[(str, any)], feedback: list[dict[(str, any)]]
) -> list[dict[(str, any)]] {
    text = (str(job.get('title', '')) + ' ' + str(job.get('description', ''))).lower();
    choices = [
        ('role-specific', '', 'Practice requirements from this job description.'),
        ('project', '', 'Explain your contribution using a specific verified example.')
    ];
    if `any(
        (word in text)
        for word in ('software', 'python', 'c++', 'backend', 'frontend', 'full stack')
    ) {
        language = 'cpp' if ('c++' in text) else 'python';
        choices += [
            ('two-sum', language, 'The role includes software implementation.'),
            ('debug-endpoint', '', 'Practice explaining a debugging investigation.')
        ];
        if `any(
            (word in text)
            for word in ('senior', 'staff', 'principal', 'architect', 'distributed')
        ) {
            choices += [
                (
                    'design-tracker',
                    '',
                    'The role calls for architectural decisions and tradeoffs.'
                )
            ];
        }
    }
    if ('sql' in text) {
        choices += [('sql-funnel', 'sql', 'SQL appears in the job description.')];
    }
    weak = {
        row['criterion'].lower() for `report in feedback
        for row in `report.get('rubric', [])
        if (row.get('score', 4) < 2)
    };
    if `any(
        (('edge' in criterion) or ('correct' in criterion)) for criterion in weak
    ) {
        choices += [
            (
                'brackets',
                'python',
                'Recent feedback identified edge cases or correctness as a practice area.'
            )
        ];
    }
    if `any(('reflection' in criterion) for criterion in weak) {
        choices += [
            ('setback', '', 'Recent feedback identified reflection as a practice area.')
        ];
    }
    seen = `set();
    result = [];
    for (key, language, reason) in choices {
        if (key not in seen) {
            result.append({'problem_id': key, 'language': language, 'reason': reason});
            seen.add(key);
        }
    }
    return result[:7];
}

