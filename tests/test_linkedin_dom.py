"""Run in the browser container: real DOM extraction, without LinkedIn credentials."""
import unittest
import time
from playwright.sync_api import sync_playwright
from agents.linkedin import CAPTURE_JS, scan
from agents.browser import BrowserPool, BrowserFrames


class ProfileDOM(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.driver = sync_playwright().start()
        cls.browser = cls.driver.chromium.launch(headless=True, chromium_sandbox=True)

    @classmethod
    def tearDownClass(cls):
        cls.browser.close()
        cls.driver.stop()

    def capture(self, html):
        page = self.browser.new_page(viewport={'width': 430, 'height': 780})
        try:
            page.set_content(html)
            return page.evaluate(CAPTURE_JS)
        finally:
            page.close()

    def test_legacy_sections_and_hidden_private_text(self):
        value = self.capture('''<nav>Private notification</nav><main>
        <section><h1>Candidate</h1><p>Software engineer</p>
        <span aria-hidden="true">Duplicate name</span><p style="display:none">Hidden data</p>
        <textarea>Private draft</textarea><input value="private-password"></section>
        <section><div id="about"></div><h2>About</h2><p>I build tools.</p></section>
        </main><aside>Private message</aside>''')
        self.assertIn('Candidate', value)
        self.assertIn('Software engineer', value)
        self.assertIn('I build tools.', value)
        self.assertNotIn('Hidden data', value)
        self.assertNotIn('private-password', value)
        self.assertNotIn('Private notification', value)
        self.assertNotIn('Private message', value)

    def test_mobile_cards_with_h2_name_and_heading_sections(self):
        value = self.capture('''<div role="main"><div class="artdeco-card">
        <h2>Candidate</h2><p>Software engineer</p></div>
        <div class="artdeco-card"><h2>Experience</h2><p>Built a tracker.</p></div>
        <div class="artdeco-card"><h2>Skills</h2><p>Python</p></div></div>''')
        self.assertIn('Candidate', value)
        self.assertIn('Software engineer', value)
        self.assertIn('Built a tracker.', value)
        self.assertIn('Python', value)

    def test_real_scan_waits_for_delayed_profile_and_completes(self):
        # No LinkedIn traffic: this context serves only a local controlled fixture.
        url = 'https://www.linkedin.com/in/fixture/'
        context = self.browser.new_context(viewport={'width': 430, 'height': 780})
        context.add_cookies([{'name': 'li_at', 'value': 'synthetic-fixture', 'domain': '.linkedin.com', 'path': '/'}])
        context.route('**/*', lambda route: route.fulfill(content_type='text/html', body='''<main></main><script>
          setTimeout(()=>document.querySelector('main').innerHTML='<div class="artdeco-card"><h2>Candidate</h2><p>Software engineer</p></div><section><h2>About</h2><p>I build tools.</p></section>',3500);
        </script>'''))
        page = context.new_page()
        page.goto(url)
        pool = BrowserPool.__new__(BrowserPool)
        pool.frames = BrowserFrames()
        pool.sessions = {('owner', 'task'): {'context': context, 'page': page, 'url': url, 'adapter': 'linkedin', 'touched': time.time()}}
        try:
            result = scan(pool, 'owner', 'task', {'linkedin_url': url})
            self.assertIn('Candidate', result['artifact']['sections']['profile'])
            self.assertIn('I build tools.', result['artifact']['sections']['profile'])
            self.assertFalse(pool.sessions)
        finally:
            context.close()

    def test_loading_or_incomplete_text_is_captured_without_header_validation(self):
        self.assertEqual(self.capture('<main><div>Loading…</div></main>'), 'Loading…')
        self.assertIn('Incomplete page', self.capture('<main><section><h2>About</h2><p>Incomplete page</p></section></main>'))


if __name__ == '__main__': unittest.main()
