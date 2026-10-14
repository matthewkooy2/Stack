"""Manual Chromium acceptance: remote text must never act as a submit key."""
import unittest
from playwright.sync_api import sync_playwright
from agents.browser import BrowserPool, BrowserFrames


class BrowserInput(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.driver = sync_playwright().start()
        cls.browser = cls.driver.chromium.launch(headless=True)

    @classmethod
    def tearDownClass(cls):
        cls.browser.close()
        cls.driver.stop()

    def setUp(self):
        self.page = self.browser.new_page()
        self.addCleanup(self.page.close)
        self.page.set_content('''<form><input id="login"><textarea id="answer"></textarea><button>Submit</button></form>
            <script>window.submits=0;window.keys=[];
            document.querySelector('form').addEventListener('submit',e=>{e.preventDefault();submits++});
            document.addEventListener('keydown',e=>keys.push(e.key));</script>''')
        self.pool = BrowserPool.__new__(BrowserPool)
        self.pool.frames = BrowserFrames()
        self.pool.sessions = {('owner', 'run'): {'page': self.page, 'touched': 0}}

    def send(self, text, **extra):
        self.pool.handoff('owner', 'run', {'type': 'text', 'text': text, **extra})

    def test_short_multiline_paste_cannot_submit_login(self):
        for extra in ({'paste': True}, {}):
            with self.subTest(extra=extra):
                self.page.locator('#login').fill('')
                self.page.locator('#login').focus()
                self.page.evaluate('window.keys=[]')
                self.send('first\nsecond', **extra)
                self.assertEqual(self.page.evaluate('window.submits'), 0)
                self.assertEqual(self.page.evaluate('window.keys'), [])
        self.pool.handoff('owner', 'run', {'type': 'key', 'key': 'Enter'})
        self.assertEqual(self.page.evaluate('window.submits'), 1, 'only explicit Enter submits')

    def test_paste_preserves_multiline_text_in_textarea(self):
        for text in ('first\nsecond', 'first\r\nsecond', 'café 🙂\nsecond', 'x' * 501 + '\nlast', 'x' * 8000):
            with self.subTest(length=len(text)):
                self.page.locator('#answer').fill('')
                self.page.locator('#answer').focus()
                self.page.evaluate('window.keys=[]')
                self.send(text, paste=True)
                self.assertEqual(self.page.locator('#answer').input_value(), text)
                self.assertEqual(self.page.evaluate('window.keys'), [])
                self.assertEqual(self.page.evaluate('window.submits'), 0)

    def test_typing_still_triggers_key_driven_fields_but_paste_does_not(self):
        self.page.evaluate('''() => document.querySelector('#login').addEventListener('keyup',e=>{
            if (/^[0-9]{10}$/.test(e.target.value)) e.target.value='('+e.target.value.slice(0,3)+') '+e.target.value.slice(3,6)+'-'+e.target.value.slice(6);
        })''')
        self.page.locator('#login').focus()
        self.send('7345550100')
        self.assertEqual(self.page.locator('#login').input_value(), '(734) 555-0100')
        self.assertEqual(len(self.page.evaluate('window.keys')), 10)
        self.page.locator('#login').fill('')
        self.page.evaluate('window.keys=[]')
        self.send('7345550100', paste=True)
        self.assertEqual(self.page.locator('#login').input_value(), '7345550100')
        self.assertEqual(self.page.evaluate('window.keys'), [])


if __name__ == '__main__':
    unittest.main()
