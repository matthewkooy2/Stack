import unittest
from playwright.sync_api import sync_playwright
from agents.browser import BrowserPool, BrowserFrames

class BrowserInput(unittest.TestCase):
    def test_login_typing_paste_and_editing(self):
        with sync_playwright() as driver, driver.chromium.launch() as browser:
            page = browser.new_page()
            page.set_content('''<form><input id="user"><input id="password" type="password"><button>Login</button></form>
                <script>window.submits=0;window.keys=[];
                document.querySelector('form').addEventListener('submit',e=>{e.preventDefault();submits++});
                document.addEventListener('keydown',e=>keys.push(e.key));</script>''')
            pool = BrowserPool.__new__(BrowserPool)
            pool.frames = BrowserFrames()
            pool.sessions = {('owner', 'run'): {'page': page, 'touched': 0}}
            def text(value, **extra):
                pool.handoff('owner', 'run', {'type': 'text', 'text': value, **extra})
            def key(value, **extra):
                pool.handoff('owner', 'run', {'type': 'key', 'key': value, **extra})
            user = page.locator('#user')
            password = page.locator('#password')
            user.focus()
            text('a' * 501)
            text('CD', paste=True)
            text('ef')
            self.assertEqual(user.input_value(), 'a' * 501 + 'CDef')
            self.assertEqual(page.evaluate('window.keys'), list('a' * 501 + 'ef'))
            key('SelectAll')
            page.evaluate('window.keys=[]')
            text('name\n')
            self.assertEqual(page.evaluate('({keys,submits})'), {'keys': [], 'submits': 0})
            key('Tab')
            self.assertEqual(page.evaluate('document.activeElement.id'), 'password')
            key('Tab', shift=True)
            self.assertEqual(page.evaluate('document.activeElement.id'), 'user')
            key('Enter')
            self.assertEqual(page.evaluate('document.activeElement.id'), 'password')
            self.assertEqual(page.evaluate('window.submits'), 0)
            text('abcd')
            password.evaluate('e=>e.setSelectionRange(2,2)')
            key('Backspace')
            self.assertEqual(password.input_value(), 'acd')
            key('Delete')
            self.assertEqual(password.input_value(), 'ad')
            key('SelectAll')
            text('secret', paste=True)
            self.assertEqual(password.input_value(), 'secret')
            key('Enter')
            self.assertEqual(page.evaluate('window.submits'), 1)
