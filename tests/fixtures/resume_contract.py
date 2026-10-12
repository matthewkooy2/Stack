"""Generate the frozen, fictional Swift contract through the real parser.

The canonical golden digest in test_resume_details pins the complete output,
including metadata and evidence. Native MAT-36 consumes the identical JSON.
"""
import json
from agents import resume_details as D


def encoded_fixture():
    rows = ['Riley Sample', 'riley.sample@example.invalid', 'Summary',
            'Fictional analyst for contract testing.', 'Education']
    for i in range(21):
        rows += [f'Fictional University {i} | 2010 - 2014', 'Bachelor of Science', 'Springfield, IL']
    rows += ['Experience', 'Northwind Labs | Software Engineer | 2020 - Present',
             '- Built a synthetic reporting tool.', 'Harbor Systems | Data Analyst | 2017 - 2019',
             '- Maintained fictional reports.', 'Skills', 'Python, SQL']
    extracted = {'pages': [{'number': 1, 'width': 612, 'height': 792,
                           'spans': [{'id': f'p1s{i}', 'text': text,
                                      'bbox': [54, 54 + i * 14, 6 * len(text), 11],
                                      'direction': 'ltr', 'endOfLine': False}
                                     for i, text in enumerate(rows)]}]}
    original = D.build(extracted)
    review = {'details': D.new_details(original)}
    values = dict(review['details']['values'])
    for field in D.GROUPS['workExperiences'][1]:
        values[f'workExperiences.0.{field}'], values[f'workExperiences.1.{field}'] = (
            values[f'workExperiences.1.{field}'], values[f'workExperiences.0.{field}'])
    review = D.save(review, values, False, 2, 1.0, 'Fictional-contract.pdf')
    fixture = {**D.view(review), 'revision': 3, 'confirmed': False, 'trusted_source': '',
               'processing': {'id': 'synthetic-import', 'status': 'completed',
                              'message': 'Fictional-contract.pdf', 'attempt': 1,
                              'timings': {'parse_ms': 1.0}},
               'records': [{'id': 'r0', 'kind': 'title', 'text': 'Riley Sample'}]}
    return (json.dumps(fixture, ensure_ascii=False, indent=2) + '\n').encode('utf-8')


if __name__ == '__main__':
    import sys
    sys.stdout.buffer.write(encoded_fixture())
