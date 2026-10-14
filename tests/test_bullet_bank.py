"""Fixed fictional facts; lightweight source composition and correction checks."""
import copy
import unittest
from agents.bullet_bank import compose, save_review
from agents.record_resume import prepare

BASE = [{'id': 'r0', 'kind': 'title', 'text': 'Fictional Candidate'},
        {'id': 'r9', 'kind': 'bullet', 'text': 'Built a local dashboard.'}]
FACTS = [{'id': 'r0', 'kind': 'bullet', 'text': 'Reduced review time by 25% in 2024.'},
         {'id': 'r1', 'kind': 'bullet', 'text': 'Did not manage the team.'}]
SOURCE = {'id': 'private-source', 'name': 'Example Co analyst, 2024', 'source': 'My notes',
          'revision': 1, 'confirmed': True, 'records': FACTS}
SELECTION = [{'id': SOURCE['id'], 'revision': 1, 'record_ids': ['r1', 'r0']}]


class BulletBank(unittest.TestCase):
    def test_exact_claims_source_order_and_provenance(self):
        value = compose(BASE, SELECTION, [SOURCE])
        self.assertEqual([r['text'] for r in value['records']],
                         [r['text'] for r in BASE] + [SOURCE['name']] + [r['text'] for r in FACTS])
        self.assertEqual(len({r['id'] for r in value['records']}), 5)
        self.assertEqual(value['bank_sources'][0]['records'], FACTS)
        self.assertEqual(value['bank_sources'][0]['mapping'][0]['source_record_id'], 'r0')
        value['bank_sources'][0]['records'][0]['text'] = 'changed'
        self.assertEqual(SOURCE['records'], FACTS)

    def test_deleted_foreign_unconfirmed_changed_and_invalid_selections_fail_closed(self):
        for sources, selection in [([], SELECTION),
            ([{**SOURCE, 'confirmed': False}], SELECTION),
            ([{**SOURCE, 'revision': 2}], SELECTION),
            ([SOURCE], [{**SELECTION[0], 'record_ids': ['r2']}]),
            ([SOURCE], [{**SELECTION[0], 'record_ids': ['r0', 'r0']}]),
            ([SOURCE], [{**SELECTION[0], 'record_ids': [{}]}]),
            ([SOURCE], [{**SELECTION[0], 'id': []}]),
            ([SOURCE], SELECTION * 2)]:
            with self.subTest(sources=sources, selection=selection), self.assertRaises(ValueError):
                compose(BASE, selection, sources)

    def test_original_and_every_correction_retained_without_model_history(self):
        initial = save_review({}, SOURCE['name'], 'My original notes', FACTS, True, 0, 10)
        changed = copy.deepcopy(FACTS)
        changed[0]['text'] = 'Reduced review time by 20% in 2024.'
        final = save_review(initial, SOURCE['name'], 'Corrected from my notes', changed, False, 1, 20)
        self.assertEqual(final['original']['records'], FACTS)
        self.assertEqual(final['history'][0]['records'], FACTS)
        self.assertEqual(final['history'][1]['records'], changed)
        self.assertEqual(initial['records'], FACTS)
        self.assertEqual(final['confirmed_at'], 0)
        with self.assertRaises(ValueError):
            save_review({}, 'x', '', FACTS, True, 0, 1)

    def test_source_revision_and_label_bound_to_tailoring_digest(self):
        value = {'template': 'classic', 'upload_digest': 'fixture', 'revision': 2,
                 **compose(BASE, SELECTION, [SOURCE])}
        p = prepare(value)
        changed = copy.deepcopy(value)
        changed['bank_sources'][0]['source'] = 'corrected source'
        self.assertNotEqual(p['digest'], prepare(changed)['digest'])
        self.assertNotIn('history', p['bank_sources'][0])
        self.assertEqual(prepare({**value, **compose(BASE, [], [])})['records'], BASE)

    def test_combined_document_limits_and_no_silent_truncation(self):
        records = [{'id': 'r' + str(i), 'kind': 'bullet', 'text': 'Fact'} for i in range(300)]
        with self.assertRaises(ValueError):
            compose(records, SELECTION, [SOURCE])

    def test_imported_bullets_keep_original_employers_dates_and_credentials(self):
        imported = [{ 'id': 'r0', 'kind': 'heading', 'text': 'Work'},
                    { 'id': 'r1', 'kind': 'paragraph', 'text': 'Employer A, analyst, 2020-2021'},
                    { 'id': 'r2', 'kind': 'bullet', 'text': 'Reduced review time by 20%.'},
                    { 'id': 'r3', 'kind': 'paragraph', 'text': 'Employer B, analyst, 2022-2023'},
                    { 'id': 'r4', 'kind': 'bullet', 'text': 'Unselected fact.'}]
        source = {**SOURCE, 'editable': False, 'records': imported}
        selection = [{ 'id': source['id'], 'revision': 1, 'record_ids': ['r2']}]
        value = compose(BASE, selection, [source])
        self.assertEqual([r['text'] for r in value['records'][3:]],
                         [r['text'] for r in imported if r['id'] != 'r4'])
        self.assertEqual(value['bank_sources'][0]['records'], imported[:4])


if __name__ == '__main__':
    unittest.main()
