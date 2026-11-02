import json
import unittest
from unittest.mock import Mock

from discovery.branding import employer_logos


class EmployerBrandingTests(unittest.TestCase):
    def test_exact_domains_and_board_fallbacks(self):
        store = Mock()
        store.rows.side_effect = [[(True,)], [
            ('domain:one.example', 'one.example', 'b25l'),
            ('board:ats:one', 'one.example', 'b25l'),
            ('board:ats:two', 'two.example', 'dHdv'),
        ]]
        cards = [
            {'employer_domain': ' WWW.One.Example. '},
            {'source_id': 'ats:one'},
            {'employer_domain': 'one.example', 'source_id': 'ats:two'},
            {'employer_domain': 'unreviewed.example', 'source_id': 'ats:one'},
            {'company': 'One', 'source_id': 'ats:other'},
        ]
        logos = employer_logos(store, cards)
        self.assertEqual(logos, {'one.example': 'b25l'})
        self.assertEqual([card.get('employer_brand') for card in cards], ['one.example'] * 2 + [None] * 3)
        self.assertIn('board:ats:other', json.loads(store.rows.call_args.args[1]['wanted']))

    def test_empty_page_and_database_before_install(self):
        store = Mock()
        self.assertEqual(employer_logos(store, []), {})
        store.rows.assert_not_called()
        store.rows.return_value = [(False,)]
        card = {'source_id': 'ats:one'}
        self.assertEqual(employer_logos(store, [card]), {})
        self.assertNotIn('employer_brand', card)

