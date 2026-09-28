"""Reviewed practice fixtures and deterministic execution contracts."""
import json;
with entry {
    PROBLEMS = [
        {
            'id': 'two-sum',
            'track': 'Technical',
            'topic': 'Algorithms',
            'title': 'Find a pair',
            'minutes': 20,
            'prompt': 'Return indices of two distinct values that sum to target, or an empty list. Any valid pair is accepted.',
            'languages': ['python', 'cpp'],
            'hints': [
                'Start with two loops.',
                'Store previously seen values in a map.'
            ],
            'starter': {
                'python': 'def solve(nums, target):\n    return []\n',
                'cpp': 'vector<int> solve(vector<int> nums, int target) {\n    return {};\n}\n'
            },
            'tests': [
                {'args': [[2, 7, 11, 15], 9]},
                {'args': [[3, 3], 6]},
                {'args': [[], 1]},
                {'args': [[-2, 4, 8], 6]},
                {'args': [[1, 2], 9]}
            ]
        },
        {
            'id': 'brackets',
            'track': 'Technical',
            'topic': 'Data structures',
            'title': 'Balanced brackets',
            'minutes': 15,
            'prompt': 'Return whether (), [], and {} are balanced and properly nested. Empty input is valid.',
            'languages': ['python', 'cpp'],
            'hints': [
                'Remember unmatched opening brackets.',
                'A stack preserves nesting order.'
            ],
            'starter': {
                'python': 'def solve(text):\n    return False\n',
                'cpp': 'bool solve(string text) {\n    return false;\n}\n'
            },
            'tests': [
                {'args': ['([])'], 'expected': True},
                {'args': ['([)]'], 'expected': False},
                {'args': [''], 'expected': True},
                {'args': [']'], 'expected': False},
                {'args': ['(('], 'expected': False}
            ]
        },
        {
            'id': 'sql-funnel',
            'track': 'Technical',
            'topic': 'SQL',
            'title': 'Application funnel',
            'minutes': 15,
            'prompt': 'Table applications(id INTEGER, company TEXT, status TEXT). Return company and COUNT(*) AS total for companies with at least two applications, ordered by total descending, then company ascending.',
            'languages': ['sql'],
            'hints': ['Group rows by company.', 'Use HAVING for the aggregate filter.'],
            'starter': {
                'sql': 'SELECT company, COUNT(*) AS total\nFROM applications\nGROUP BY company;'
            },
            'tests': [
                {
                    'rows': [
                        [1, 'Acme', 'Submitted'],
                        [2, 'Acme', 'Interview'],
                        [3, 'Beta', 'Submitted']
                    ],
                    'expected': [['Acme', 2]]
                },
                {'rows': [], 'expected': []},
                {
                    'rows': [
                        [1, 'B', 'Submitted'],
                        [2, 'B', 'Submitted'],
                        [3, 'A', 'Submitted'],
                        [4, 'A', 'Rejected']
                    ],
                    'expected': [['A', 2], ['B', 2]]
                }
            ]
        },
        {
            'id': 'debug-endpoint',
            'track': 'Technical',
            'topic': 'Debugging',
            'title': 'Investigate a slow endpoint',
            'minutes': 15,
            'prompt': 'A job-search endpoint slows from 100 ms to 4 s as saved applications grow. Explain your investigation, measurements, likely causes, and how you would verify a fix.',
            'languages': [],
            'hints': ['Separate database, application, and network time.']
        },
        {
            'id': 'review-cache',
            'track': 'Technical',
            'topic': 'Code review',
            'title': 'Review a shared cache',
            'minutes': 15,
            'prompt': 'A server caches GET /applications responses using only the URL as its key. Review correctness, privacy, invalidation, and concurrency risks. Propose and test a fix.',
            'languages': [],
            'hints': ['What happens when two different users request the same URL?']
        },
        {
            'id': 'fundamentals',
            'track': 'Technical',
            'topic': 'CS fundamentals',
            'title': 'Transactions and concurrency',
            'minutes': 15,
            'prompt': 'Two workers try to submit the same application. Explain transaction isolation, locks, idempotency, and why an external HTTP request cannot simply be rolled back.',
            'languages': [],
            'hints': [
                'What if the server receives the request but the response is lost?'
            ]
        },
        {
            'id': 'design-tracker',
            'track': 'Technical',
            'topic': 'System design',
            'title': 'Design an application tracker',
            'minutes': 40,
            'prompt': 'Design a job application tracker with email synchronization, reminders, and 100,000 users. Clarify requirements, draw components and data flow, then discuss deduplication, access control, failure recovery, and scaling.',
            'languages': [],
            'hints': [
                'Begin with requirements and expected traffic.',
                'Separate durable state from external side effects.'
            ]
        },
        {
            'id': 'role-specific',
            'track': 'Technical',
            'topic': 'Role-specific',
            'title': 'Explain a job requirement',
            'minutes': 15,
            'prompt': 'Choose a technical requirement from the linked job. Explain the concept, a concrete example, failure modes, and tradeoffs. Identify what you still need to learn.',
            'languages': [],
            'hints': [
                'Connect the requirement to verified experience, without inventing an example.'
            ]
        },
        {
            'id': 'project',
            'track': 'Behavioral',
            'topic': 'Ownership',
            'title': 'Tell your project story',
            'minutes': 5,
            'prompt': 'Tell me about a project you are proud of. What did you personally contribute, what tradeoff did you make, and what did you learn?',
            'languages': [],
            'hints': [
                'Use Situation, Task, Action, Result.',
                'Distinguish your work from the team’s work.'
            ]
        },
        {
            'id': 'disagreement',
            'track': 'Behavioral',
            'topic': 'Collaboration',
            'title': 'Work through disagreement',
            'minutes': 5,
            'prompt': 'Tell me about a disagreement with a teammate. How did you listen, gather evidence, and reach a decision?',
            'languages': [],
            'hints': ['Explain the shared goal without assigning blame.']
        },
        {
            'id': 'setback',
            'track': 'Behavioral',
            'topic': 'Growth',
            'title': 'Learn from a setback',
            'minutes': 5,
            'prompt': 'Describe a mistake, how you responded, and a concrete change you made afterward.',
            'languages': [],
            'hints': [
                'Choose a real example; a useful lesson does not require invented metrics.'
            ]
        }
    ];
}
def problem(problem_id: str) -> dict[(str, any)] {
    for p in PROBLEMS {
        if (p['id'] == problem_id) {
            return p;
        }
    }
    raise ValueError('Practice problem not found.');
}
def catalog() -> list[dict[(str, any)]] {
    return [
        {
            k: v
            for (k, v) in p.items()
            if (k != 'tests')
        } for p in PROBLEMS
    ];
}
def validate_session(data: dict[(str, any)]) -> dict[(str, any)] {
    p = problem(data.get('problem_id', ''));
    language = data.get('language', '');
    if (language not in (p['languages'] + ([''] if not p['languages'] else []))) {
        raise ValueError('Choose a supported language.');
    }
    out = {'problem_id': p['id'], 'language': language};
    for (field, limit) in [
        ('answer', 30000),
        ('code', 30000),
        ('notes', 10000),
        ('transcript', 30000)
    ] {
        out[field] = str(data.get(field, ''));
        if (len(out[field]) > limit) {
            raise ValueError((field.title() + ' is too long.'));
        }
    }
    canvas = data.get('canvas', {'nodes': [], 'edges': []});
    if (not isinstance(canvas, `dict) or (len(json.dumps(canvas)) > 50000)) {
        raise ValueError('Diagram is too large.');
    }
    out['canvas'] = canvas;
    seconds = data.get('elapsed_seconds', 0);
    if ((`type(seconds) is not int) or not (0 <= seconds <= 86400)) {
        raise ValueError('Invalid elapsed time.');
    }
    out['elapsed_seconds'] = seconds;
    return out;
}
def evaluate_outputs(problem_id: str, values: list[any]) -> dict[str, any] {
    p = problem(problem_id);
    if (len(values) != len(p.get('tests', []))) {
        return {
            'passed': 0,
            'total': len(p.get('tests', [])),
            'error': 'Program did not return one result per test.'
        };
    }
    checks = [];
    for (`test, value) in zip(p['tests'], values) {
        if (problem_id == 'two-sum') {
            (nums, target) = `test['args'];
            exists = `any(
                ((nums[i] + nums[j]) == target) for i in range(len(nums))
                for j in range((i + 1), len(nums))
            );
            valid = (value == []) and not exists;
            if (
                isinstance(value, `list)
                and (len(value) == 2)
                and all((`type(x) is int) for x in value)
            ) {
                (i, j) = value;
                valid = (
                    (i != j)
                    and (0 <= i < len(nums))
                    and (0 <= j < len(nums))
                    and ((nums[i] + nums[j]) == target)
                );
            }
        } else {
            valid = (
                (`type(value) is `type(`test['expected']))
                and (value == `test['expected'])
            );
        }
        checks.append(bool(valid));
    }
    return {
        'passed': sum(checks),
        'total': len(checks),
        'checks': checks,
        'basis': 'Executed fixture tests; this is separate from AI coaching.'
    };
}
