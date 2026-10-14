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
        self.assertEqual(self.page.evaluate('document.activeElement.id'), 'answer')
        self.assertEqual(self.page.evaluate('window.submits'), 0, 'Enter advances before submitting')
        self.pool.handoff('owner', 'run', {'type': 'key', 'key': 'Enter'})
        self.assertEqual(self.page.evaluate('window.submits'), 1, 'Enter on the last field submits')

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

    def key(self, key, **extra):
        self.pool.handoff('owner', 'run', {'type': 'key', 'key': key, **extra})

    def test_enter_skips_unavailable_fields_and_stays_in_its_form(self):
        self.page.set_content('''<form id="first"><input id="user"><input hidden><input disabled>
            <input type="hidden"><input tabindex="-1"><input style="visibility:hidden">
            <input id="password" type="password"><button onclick="window.clicks++">Login</button></form>
            <form><input id="other"></form><script>window.submits=0;window.clicks=0;
            document.querySelector('#first').addEventListener('submit',e=>{e.preventDefault();submits++});</script>''')
        self.page.locator('#user').focus()
        self.key('Enter')
        self.assertEqual(self.page.evaluate('document.activeElement.id'), 'password')
        self.assertEqual(self.page.evaluate('window.submits'), 0)
        self.key('Enter')
        self.assertEqual(self.page.evaluate('window.submits'), 1)
        self.assertEqual(self.page.evaluate('window.clicks'), 1, 'site click handlers must run')

    def test_enter_submission_respects_required_fields_and_disabled_buttons(self):
        self.page.set_content('''<form><input id="password" required><button id="submit">Login</button></form>
            <script>window.submits=0;document.querySelector('form').addEventListener('submit',e=>{e.preventDefault();submits++});</script>''')
        self.page.locator('#password').focus()
        self.key('Enter')
        self.assertEqual(self.page.evaluate('window.submits'), 0)
        self.send('secret')
        self.page.locator('#submit').evaluate('e=>e.disabled=true')
        self.key('Enter')
        self.assertEqual(self.page.evaluate('window.submits'), 0, 'disabled submission cannot be bypassed')
        self.page.locator('#submit').evaluate('e=>e.disabled=false')
        self.key('Enter')
        self.assertEqual(self.page.evaluate('window.submits'), 1)

    def test_enter_submits_a_form_without_a_submit_button(self):
        self.page.set_content('''<form><input id="last" name="requestSubmit" required></form>
            <script>window.submits=0;document.querySelector('form').addEventListener('submit',e=>{e.preventDefault();submits++});</script>''')
        self.page.locator('#last').focus()
        self.key('Enter')
        self.assertEqual(self.page.evaluate('window.submits'), 0)
        self.send('secret')
        self.key('Enter')
        self.assertEqual(self.page.evaluate('window.submits'), 1)

    def test_enter_follows_positive_tab_order(self):
        self.page.set_content('<form><input id="third"><input id="second" tabindex="2"><input id="first" tabindex="1"><button>Submit</button></form>')
        self.page.locator('#first').focus()
        self.key('Enter')
        self.assertEqual(self.page.evaluate('document.activeElement.id'), 'second')
        self.key('Enter')
        self.assertEqual(self.page.evaluate('document.activeElement.id'), 'third')

    def test_enter_handles_the_focused_iframe_form(self):
        self.page.set_content('''<form><input id="outside"></form><iframe srcdoc='<form><input id="user"><input id="password"><button>Login</button></form><script>window.submits=0;document.querySelector("form").addEventListener("submit",e=>{e.preventDefault();submits++});</script>'></iframe>''')
        frame = self.page.frames[1]
        frame.locator('#user').focus()
        self.key('Enter')
        self.assertEqual(frame.evaluate('document.activeElement.id'), 'password')
        self.key('Enter')
        self.assertEqual(frame.evaluate('window.submits'), 1)

    def test_tab_backspace_and_shift_tab_keep_normal_keyboard_behavior(self):
        self.page.locator('#login').focus()
        self.key('Tab')
        self.assertEqual(self.page.evaluate('document.activeElement.id'), 'answer')
        self.send('abc')
        self.key('Backspace')
        self.assertEqual(self.page.locator('#answer').input_value(), 'ab')
        self.key('Tab', shift=True)
        self.assertEqual(self.page.evaluate('document.activeElement.id'), 'login')

    def test_long_typing_still_sends_keyboard_events(self):
        self.page.locator('#answer').focus()
        self.send('x' * 700)
        self.assertEqual(self.page.locator('#answer').input_value(), 'x' * 700)
        self.assertEqual(len(self.page.evaluate('window.keys')), 700)


if __name__ == '__main__':
    unittest.main()
