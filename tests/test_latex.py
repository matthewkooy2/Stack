"""LaTeX resume sources: loading, safety, structure, content-only edits, one-page fitting and change checks."""
import base64
import io
import shutil
import unittest
import zipfile
from pathlib import Path
from agents import latex, tailoring
from agents.resume_templates import TEMPLATES, fill

FIXTURE = Path(__file__).parent / 'fixtures' / 'jake-resume.tex'
HAS_TECTONIC = bool(shutil.which('tectonic') or Path('/opt/homebrew/bin/tectonic').exists())


def source():
    return latex.load('resume.tex', FIXTURE.read_bytes())


def zipped(files):
    out = io.BytesIO()
    with zipfile.ZipFile(out, 'w') as archive:
        for name, data in files.items():
            archive.writestr(name, data)
    return out.getvalue()


class Loading(unittest.TestCase):
    def test_overleaf_zip_is_unwrapped_and_inputs_flattened(self):
        main = FIXTURE.read_text().replace('%-----------PROJECTS-----------', '\\input{sections/extra}')
        raw = zipped({'project/main.tex': main, 'project/sections/extra.tex': '\\section{Awards}\n\\resumeSubHeadingListStart\n\\resumeSubHeadingListEnd\n',
                      'project/README.md': 'notes', '__MACOSX/project/._main.tex': 'x'})
        loaded = latex.load('Resume.zip', raw)
        self.assertEqual(loaded['main'], 'main.tex')
        self.assertEqual(loaded['skipped'], ['project/README.md'])
        text = loaded['files']['main.tex'].decode()
        self.assertIn('\\section{Awards}', text)
        self.assertNotIn('\\input{sections/extra}', text)
        # Preamble inputs that are not project files stay as written.
        self.assertIn('\\input{glyphtounicode}', text)

    def test_unsafe_sources_are_refused(self):
        tex = FIXTURE.read_text()
        for bad in ('\\immediate\\write18{rm -rf ~}', '\\input{/etc/passwd}', '\\input{../secret}', '\\openin5=/etc/hosts', '\\directlua{os.exit()}'):
            with self.subTest(bad=bad), self.assertRaises(ValueError):
                latex.load('resume.tex', tex.replace('\\begin{document}', '\\begin{document}' + bad).encode())
        with self.assertRaises(ValueError):
            latex.load('resume.zip', zipped({'../escape.tex': tex}))
        with self.assertRaises(ValueError):
            latex.load('resume.docx', b'x')
        # Commented-out commands are not run, so they are allowed.
        latex.load('resume.tex', tex.replace('\\begin{document}', '\\begin{document}\n% \\write18{x}').encode())

    def test_pack_round_trip_and_digest(self):
        loaded = source()
        restored = latex.unpack(latex.pack(loaded))
        self.assertEqual(restored['main'], loaded['main'])
        self.assertEqual(latex.digest(restored), latex.digest({'main': loaded['main'], 'files': loaded['files']}))
        self.assertEqual(latex.decode(latex.encode(loaded))['files'], loaded['files'])


class Structure(unittest.TestCase):
    def test_jake_resume_structure(self):
        structure = latex.parse(source())
        self.assertEqual(latex.summary(structure), {'sections': 4, 'entries': 7, 'bullets': 20, 'lines': 5,
                                                    'titles': ['Education', 'Experience', 'Projects', 'Technical Skills']})
        outline = latex.outline(structure)
        experience = outline[1]['entries']
        self.assertEqual([e['heading'].split(' | ')[0] for e in experience],
                         ['Undergraduate Research Assistant', 'Information Technology Support Specialist', 'Artificial Intelligence Research Assistant'])
        # Commented-out entries are ignored; macros become readable text.
        self.assertEqual(len(experience[2]['bullets']), 6)
        self.assertEqual(experience[2]['bullets'][0]['text'], 'Explored methods to generate video game dungeons based off of The Legend of Zelda')
        self.assertEqual(outline[1]['entries'][0]['heading'], 'Undergraduate Research Assistant | June 2020 – Present | Texas A&M University | College Station, TX')
        self.assertEqual([(l['label'], l['text'][:12]) for l in outline[3]['lines']][:2], [('Languages', 'Java, Python'), ('Frameworks', 'React, Node.')])
        self.assertEqual(outline[0]['lines'][0]['label'], 'Relevant Coursework')

    def test_layout_items_are_not_bullets(self):
        values = {'profile.name': 'Sam', 'additional.descriptions': 'Dean’s List\nClub president'}
        structure = latex.parse(fill('jake', values))
        self.assertEqual([b['text'] for b in structure['bullets']], ["Dean's List", 'Club president'])

    def test_plain_and_escape(self):
        self.assertEqual(latex.plain('\\textbf{Gitlytics} $|$ \\emph{C\\# \\& 100\\%} -- \\href{https://x}{\\underline{site}}'),
                         '**Gitlytics** | C# & 100% – site')
        self.assertEqual(latex.escape('Cut **p99** cost 30% & $5 for C# user_ids {x} ~ ^ – →'),
                         'Cut \\textbf{p99} cost 30\\% \\& \\$5 for C\\# user\\_ids \\{x\\} \\textasciitilde{} \\textasciicircum{} -- $\\rightarrow$')


class Edits(unittest.TestCase):
    def test_apply_changes_only_content(self):
        loaded = source()
        structure = latex.parse(loaded)
        tex = latex.apply(structure, {'rewrites': {'s1.e0.b0': 'Built a **REST API** for 100% of courses & labs', 's3.l0': 'Python, SQL (Postgres)'},
                                      'omit': ['s1.e1', 's1.e2.b5'], 'entry_order': {'s2': ['s2.e1', 's2.e0']},
                                      'bullet_order': {'s1.e2': ['s1.e2.b2', 's1.e2.b0']}})
        original = structure['tex']
        begin = original.index('\\begin{document}')
        self.assertEqual(tex[:begin], original[:begin])
        self.assertIn('\\resumeItem{Built a \\textbf{REST API} for 100\\% of courses \\& labs}', tex)
        self.assertIn('\\textbf{Languages}{: Python, SQL (Postgres)}', tex)
        self.assertNotIn('Information Technology Support Specialist', tex)
        self.assertNotIn('World Conference', tex)
        self.assertLess(tex.index('Simple Paintball'), tex.index('Gitlytics'))
        self.assertLess(tex.index('Contributed 50K+'), tex.index('Explored methods'))
        after = latex.parse(latex.with_main(loaded, tex))
        self.assertEqual(latex.summary(after)['bullets'], 20 - 3 - 1)

    def test_an_entry_never_loses_every_bullet(self):
        structure = latex.parse(source())
        tex = latex.apply(structure, {'omit': ['s1.e0.b0', 's1.e0.b1', 's1.e0.b2']})
        self.assertIn('Developed a REST API', tex)


class Proposals(unittest.TestCase):
    def setUp(self):
        self.structure = latex.parse(source())

    def test_unsupported_rewrites_are_discarded_with_reasons(self):
        data = {'summary': '', 'ranking': ['s1.e2.b2'], 'entry_order': [{'section': 's2', 'entries': ['s2.e1']}], 'evidence': [],
                'omit': [{'id': 's1.e1', 'reason': 'Unrelated'}, {'id': 's0.e0', 'reason': 'x'}],
                'rewrites': [{'id': 's1.e0.b0', 'text': 'Built a REST API with FastAPI and PostgreSQL for learning systems', 'reason': 'Shorter'},
                             {'id': 's1.e0.b1', 'text': 'Developed a Kubernetes app with Flask and React', 'reason': 'x'},
                             {'id': 's1.e2.b2', 'text': 'Contributed 90K+ lines of code via Git', 'reason': 'x'},
                             {'id': 's3.l1', 'text': 'React, Django', 'reason': 'x'},
                             {'id': 's3.l0', 'text': 'Python, SQL (Postgres), Java', 'reason': 'Order'}]}
        plan, changes, notes = tailoring.check(self.structure, data, [])
        self.assertEqual(sorted(plan['rewrites']), ['s1.e0.b0', 's3.l0'])
        self.assertEqual(plan['omit'], ['s1.e1', 's0.e0'])
        self.assertEqual(plan['entry_order'], {'s2': ['s2.e1', 's2.e0']})
        self.assertEqual(plan['ranking'][0], 's1.e2.b2')
        self.assertEqual(len(plan['ranking']), 20)
        self.assertTrue(any('kubernetes' in n for n in notes))
        self.assertTrue(any('(90)' in n for n in notes))
        self.assertTrue(any('Django' in n for n in notes))
        kinds = {c['id']: c['kind'] for c in changes}
        self.assertEqual(kinds['s1.e0.b0'], 'rewrite')
        self.assertEqual(kinds['omit:s1.e1'], 'omit')
        self.assertEqual(kinds['order:s2'], 'reorder')
        self.assertEqual(kinds['order:s1.e2'], 'reorder')
        # Verified facts can support a number the bullet lacks.
        plan, _, _ = tailoring.check(self.structure, {**data, 'rewrites': data['rewrites'][2:3]}, [{'key': 'resume.x', 'value': 'Wrote 90K lines', 'verified': True}])
        self.assertIn('s1.e2.b2', plan['rewrites'])

    def test_rewrites_that_read_worse_are_discarded(self):
        """A rewrite may not drop a number or add a weak opener, filler, a pronoun or passive voice."""
        first = self.structure['bullets'][0]
        target = next(b for b in self.structure['bullets'] if tailoring._numbers(b['text']))
        number = sorted(tailoring._numbers(target['text']))[0]
        data = {'ranking': [], 'rewrites': [
            {'id': target['id'], 'text': target['text'].replace(number, 'many'), 'reason': 'x'},
            {'id': first['id'], 'text': 'Helped with ' + first['text'][0].lower() + first['text'][1:], 'reason': 'x'},
            {'id': self.structure['bullets'][1]['id'], 'text': 'I ' + self.structure['bullets'][1]['text'][0].lower() + self.structure['bullets'][1]['text'][1:], 'reason': 'x'}]}
        plan, _, notes = tailoring.check(self.structure, data, [])
        self.assertEqual(plan['rewrites'], {})
        self.assertTrue(any('dropped ' + number in n for n in notes), notes)
        self.assertTrue(any('opens with "helped"' in n for n in notes), notes)
        self.assertTrue(any('a personal pronoun' in n for n in notes), notes)

    def test_unknown_ranking_ids_are_dropped(self):
        first = self.structure['bullets'][0]['id']
        plan, changes, _ = tailoring.check(self.structure, {'ranking': ['s9.e9.b9', first, self.structure['lines'][0]['id']]}, [])
        self.assertEqual(plan['ranking'][0], first)
        self.assertEqual(set(plan['ranking']), {b['id'] for b in self.structure['bullets']})
        plan, _, notes = tailoring.check(self.structure, {'rewrites': [{'id': 's9.e9.b9', 'text': 'Invented'}]}, [])
        self.assertEqual(plan['rewrites'], {})
        self.assertIn('Ignored a rewrite for an unknown item.', notes)

    def test_rejected_changes_are_removed(self):
        plan = {'rewrites': {'a': 'x', 'b': 'y'}, 'omit': ['c'], 'entry_order': {'s1': []}, 'bullet_order': {'s1.e0': []}, 'ranking': []}
        kept = tailoring.effective(plan, ['a', 'omit:c', 'order:s1'])
        self.assertEqual((kept['rewrites'], kept['omit'], kept['entry_order'], kept['bullet_order']), ({'b': 'y'}, [], {}, {'s1.e0': []}))


@unittest.skipUnless(HAS_TECTONIC, 'Install Tectonic (brew install tectonic) to run compile tests.')
class Compile(unittest.TestCase):
    def test_uploaded_source_and_templates_compile_to_one_page(self):
        self.assertEqual(latex.compile(source())['pages'], 1)
        for name in TEMPLATES:
            self.assertEqual(latex.compile(fill(name, {'profile.name': 'Sam', 'workExperiences.0.jobTitle': 'Analyst',
                                                       'workExperiences.0.descriptions': 'Cut costs 10% & grew C# usage'}))['pages'], 1)

    def test_errors_name_the_problem_and_line(self):
        broken = FIXTURE.read_text().replace('\\section{Projects}', '\\section{Projects}\\undefinedmacro')
        line = broken[:broken.index('\\undefinedmacro')].count('\n') + 1
        with self.assertRaisesRegex(ValueError, rf'Undefined control sequence\. \(line {line}\)'):
            latex.compile(latex.load('resume.tex', broken.encode()))

    def test_long_resume_is_fit_to_one_page_and_finalized(self):
        extra = '\n'.join('        \\resumeItem{Extra detail %d about building distributed data pipelines for research teams}' % i for i in range(30))
        tex = FIXTURE.read_text().replace('\\resumeItem{Presented virtually to the World Conference on Computational Intelligence}',
                                          '\\resumeItem{Presented virtually to the World Conference on Computational Intelligence}\n' + extra)
        loaded = latex.load('resume.tex', tex.encode())
        self.assertEqual(latex.compile(loaded)['pages'], 2)
        prepared = tailoring.prepare(latex.encode(loaded))
        top = 's1.e0.b0'
        proposal = tailoring.tailor(prepared, {'summary': 'APIs', 'ranking': [top], 'entry_order': [], 'omit': [], 'evidence': [],
                                               'rewrites': [{'id': top, 'text': 'Built a REST API with FastAPI and PostgreSQL for learning systems', 'reason': 'r'}]}, [])
        self.assertEqual(proposal['pdf']['pages'], 1)
        self.assertTrue(proposal['dropped'])
        self.assertTrue(all('Extra detail' in d['text'] or d['id'] != top for d in proposal['dropped']))
        self.assertIn('Built a REST API with FastAPI', proposal['pdf']['text'])
        final = tailoring.finalize(prepared, {**proposal, 'rejected': [top]})
        self.assertEqual(final['tailor']['pdf']['pages'], 1)
        self.assertNotIn('Built a REST API with FastAPI', final['tailor']['pdf']['text'])
        self.assertEqual(final['summary'], 'Applied 0 of 1 changes.')
        with self.assertRaises(ValueError):
            tailoring.finalize({**prepared, 'digest': 'changed'}, proposal)

    @unittest.skipUnless(HAS_TECTONIC, 'Tectonic is not installed')
    def test_skill_block_with_line_breaks_keeps_its_layout(self):
        """Regression: a skills \\item of \\textbf{Label:} lines split by \\\\[3pt] was read as one bullet, and a rewrite
        printed "[3pt]" and dropped a label. Each line is now a skill line; Experience keeps its date order."""
        tex = (Path(__file__).parent / 'fixtures' / 'linebreak-skills-resume.tex').read_text()
        prepared = tailoring.prepare(latex.encode(latex.load('resume.tex', tex.encode())))
        structure = prepared['structure']
        lines = {l['label']: l for l in structure['lines']}
        self.assertEqual(list(lines), ['Languages', 'Frameworks & Runtimes', 'Data & ML', 'Platforms & Tools'])
        self.assertEqual(lines['Data & ML']['text'], 'PostgreSQL, DuckDB, pandas, NumPy, scikit-learn, OpenCV')
        self.assertFalse([b for b in structure['bullets'] if 'Languages' in b['text']])
        sections = {s['title']: s['id'] for s in structure['sections']}
        experience = [e['id'] for e in structure['entries'] if e['section'] == sections['Experience']]
        projects = [e['id'] for e in structure['entries'] if e['section'] == sections['Projects']]
        proposal = tailoring.tailor(prepared, {'summary': 's', 'ranking': [], 'omit': [], 'evidence': [],
            'entry_order': [{'section': sections['Experience'], 'entries': experience[::-1]}, {'section': sections['Projects'], 'entries': projects[::-1]}],
            'rewrites': [{'id': lines['Languages']['id'], 'text': 'SQL, Python, C++', 'reason': 'r'}]}, [])
        out = proposal['tex']
        self.assertEqual(out[out.index('\\section{Technical Skills}'):].count('\\\\[3pt]'), 3)
        self.assertIn('\\textbf{Data \\& ML:}', out)
        self.assertIn('\\textbf{Languages:}\n      SQL, Python, C++ \\\\[3pt]', out)
        pdf_text = tailoring._pdf_text(base64.b64decode(proposal['pdf']['content']))
        self.assertNotIn('[3pt]', pdf_text)
        self.assertIn('Data & ML', pdf_text)
        self.assertLess(out.index('Harbor Logistics'), out.index('Lakeside Analytics'), 'Experience keeps its date order')
        self.assertLess(out.index('Court Vision Tracker'), out.index('Transit Delay Forecaster'), 'Undated projects may move')
        self.assertEqual([c['kind'] for c in proposal['changes']], ['rewrite', 'reorder'])

    @unittest.skipUnless(HAS_TECTONIC, 'Tectonic is not installed')
    def test_leaked_latex_is_never_handed_over(self):
        tex = FIXTURE.read_text().replace('\\resumeItem{Presented virtually', '\\resumeItem{Spacing [3pt] leaked. Presented virtually')
        prepared = tailoring.prepare(latex.encode(latex.load('resume.tex', tex.encode())))
        with self.assertRaisesRegex(ValueError, r'LaTeX code \(\[3pt\]\)'):
            tailoring.tailor(prepared, {'summary': 's', 'ranking': [], 'entry_order': [], 'omit': [], 'evidence': [], 'rewrites': []}, [])


if __name__ == '__main__':
    unittest.main()
