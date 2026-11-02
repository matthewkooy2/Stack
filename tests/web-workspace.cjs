// Manual browser acceptance against an ISOLATED local backend. No model/worker calls.
// Requires Playwright: STACK_PLAYWRIGHT_MODULE=/path/to/playwright node tests/web-workspace.cjs
// STACK_WEB_URL defaults to http://127.0.0.1:8080. Uses this checkout's worker token
// only to seed and purge explicitly labelled QA catalog listings, like test_catalog_api.py.
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const crypto = require('node:crypto');
const {chromium} = require(process.env.STACK_PLAYWRIGHT_MODULE || 'playwright');
const base = process.env.STACK_WEB_URL || 'http://127.0.0.1:8080';
const artifacts = path.resolve('.jac/web-acceptance');
const workerToken = fs.readFileSync('storage/discovery/worker-token', 'utf8').trim();
const label = 'BrowserQA' + Date.now();
const sourceURL = 'https://example.com/stack-tests/' + label;
let browser, page, authorization = '', sourceID;
const errors = [];
async function call(name, args = {}, worker = false) {
 const response = await page.request.post((worker ? process.env.STACK_API_URL || 'http://127.0.0.1:8000' : base) + '/function/' + name, {data: worker ? {token: workerToken, ...args} : args, headers: worker ? {} : {Authorization: authorization}});
 assert.equal(response.status(), 200, name + ' HTTP failure');
 const result = await response.json();
 assert.equal(result.ok, true, name + ' RPC failure');
 assert.ok(!result.data.result.error, name + ': ' + result.data.result.error);
 return result.data.result;
}
const field = name => page.getByLabel(name, {exact: true}).filter({visible: true});
const nav = name => page.getByRole('navigation', {name: 'Main navigation', exact: true}).getByRole('button', {name, exact: true});
async function visible(text) { await page.getByText(text, {exact: true}).first().waitFor({state: 'visible'}); }
async function screenshot(name) { await page.waitForTimeout(250); await page.screenshot({path: path.join(artifacts, name + '.png'), fullPage: true}); }
async function run() {
 fs.mkdirSync(artifacts, {recursive: true});
 browser = await chromium.launch({headless: true, ...(process.env.STACK_CHROME ? {executablePath: process.env.STACK_CHROME} : {})});
 page = await browser.newPage({viewport: {width: 1440, height: 1000}});
 page.setDefaultTimeout(10000);
 page.on('pageerror', error => errors.push(error.message));
 page.on('request', request => { if (request.url().includes('/function/bootstrap')) authorization = request.headers().authorization || authorization; });
 await page.goto(base);
 // First-use registration exercises admission and the actual Jac shell.
 await page.getByRole('button', {name: 'Create an account', exact: true}).click();
 const username = 'webqa_' + crypto.randomUUID().replaceAll('-', '').slice(0, 14), password = crypto.randomUUID();
 await field('Username').fill(username);
 await field('Password').fill(password);
 await page.getByRole('button', {name: 'Continue', exact: true}).click();
 await nav('Jobs').waitFor({state: 'visible', timeout: 30000});
 assert.deepEqual(await page.getByRole('navigation', {name: 'Main navigation', exact: true}).getByRole('button').allTextContents(), ['Jobs', 'Applications', 'Network', 'Resume', 'Prep']);
 await visible('No matching roles yet.');
 // Profile fields must send only the backend's accepted preference keys.
 await page.getByRole('button', {name: 'Open profile and settings'}).click();
 await field('Name').fill('Browser QA');
 await field('Roles').fill(label);
 await field('Location').fill('Detroit, MI');
 await page.getByRole('button', {name: 'Save preferences', exact: true}).click();
 await visible('Profile saved. Your preferences apply on both devices.');
 assert.equal((await call('bootstrap')).profile.name, 'Browser QA');
 await page.getByText('Rules & follow-up timing', {exact: true}).click();
 await field('Follow-ups per contact').fill('1');
 await page.getByRole('button', {name: 'Save rules', exact: true}).click();
 await visible('Agent rules saved.');
 const settings = await call('agent_settings');
 assert.equal(settings.policy.followup_limit, 1); assert.equal(settings.policy.enabled, false);
 await page.getByText('Confirmed facts', {exact: true}).click();
 await field('New fact key').fill('email');
 await field('Confirmed value').fill('browser-qa@example.com');
 await page.getByRole('button', {name: 'Add confirmed fact', exact: true}).click();
 await visible('Confirmed facts saved.');
 assert.ok((await call('agent_settings')).facts.some(f => f.key === 'email' && f.verified));
 // Seed real catalog records with the established token-gated fixture contract.
 const imported = await call('import_job_url', {url: sourceURL});
 sourceID = 'career:' + crypto.createHash('sha256').update(sourceURL).digest('hex').slice(0, 32);
 const work = await call('discovery_claim', {preferred_id: sourceID}, true);
 assert.equal(work.id, sourceID);
 const normalized = require('node:child_process').execFileSync('.jac/venv/bin/python', ['-c',
  'import json,sys,time; from discovery.normalize import normalize; s=json.loads(sys.argv[1]); label=sys.argv[2]; url=sys.argv[3]; print(json.dumps([normalize({"title":label+" Software Engineer "+str(i),"company":"Browser QA fixture","url":url+"/"+str(i),"country":"US","location":"Detroit, MI","mode":"Remote","employment_type":"Full-time","description":"Responsibilities\\nBuild reliable backend services for a clearly labelled browser QA fixture.\\nRequirements\\nExperience with Python and HTTP APIs.","posted_at":time.time()},s) for i in range(3)]))', JSON.stringify(work.config), label, sourceURL], {encoding: 'utf8'});
 const jobs = JSON.parse(normalized);
 await call('discovery_complete', {id: work.id, lease: work.lease, result: {jobs, complete: true}}, true);
 await nav('Jobs').click();
 await page.getByRole('button', {name: 'Find jobs', exact: true}).click();
 await page.getByRole('button', {name: 'Save role', exact: true}).waitFor({state: 'visible'});
 await page.getByRole('button', {name: 'Save role', exact: true}).waitFor();
 await page.waitForFunction(() => [...document.querySelectorAll('button')].some(b => b.textContent === 'Save role' && !b.disabled));
 await screenshot('jobs-desktop');
 // Filters, description, save and pass all use the server contracts.
 await page.getByText('Filters & preferences', {exact: true}).click();
 await page.getByRole('group', {name: 'Work arrangement'}).getByRole('button', {name: 'Remote', exact: true}).click();
 await page.getByRole('button', {name: 'Find jobs', exact: true}).click();
 await page.getByRole('button', {name: 'Full description', exact: true}).click();
 await visible('Hide description');
 await page.getByRole('button', {name: 'Save role', exact: true}).click();
 await visible('Saved to Applications. Apply on the employer site when you’re ready.');
 await page.getByRole('button', {name: 'Pass', exact: true}).click();
 await visible('Passed. Your next role is ready.');
 assert.equal((await call('bootstrap')).decisions.length, 2);
 await nav('Applications').click();
 await page.getByRole('button', {name: new RegExp('Browser QA fixture.*Ready to apply')}).click();
 await field('Your notes').fill('Persistent browser test notes');
 // A failed save must keep the draft and expose a retryable error.
 await page.route('**/function/save_application', route => route.fulfill({json: {ok: true, data: {result: {error: 'Synthetic save failure. Try again.'}}}}));
 await page.getByRole('button', {name: 'Save notes', exact: true}).click();
 await visible('Synthetic save failure. Try again.');
 assert.equal(await field('Your notes').inputValue(), 'Persistent browser test notes');
 await page.unroute('**/function/save_application');
 await page.getByRole('button', {name: 'Save notes', exact: true}).click();
 await visible('Notes saved.');
 await page.getByRole('button', {name: 'I submitted this application', exact: true}).click();
 await visible('Marked as submitted.');
 await page.getByRole('button', {name: 'Add follow-up', exact: true}).click();
 const future = new Date(Date.now() + 86400000); future.setMinutes(future.getMinutes() - future.getTimezoneOffset());
 await field('Remind me at').fill(future.toISOString().slice(0, 16));
 await page.getByRole('button', {name: 'Save reminder', exact: true}).click();
 await page.getByRole('button', {name: 'Follow-ups', exact: true}).click();
 await page.getByRole('button', {name: 'Mark complete', exact: true}).click();
 await page.getByText(/Completed/).first().waitFor();
 await page.getByRole('button', {name: 'Calendar', exact: true}).click();
 await page.getByRole('heading', {name: 'Calendar', exact: true}).waitFor();
 await screenshot('applications-calendar');
 // Real private file upload, default selection, rename, download, and deletion.
 await nav('Resume').click();
 const pdf = require('node:child_process').execFileSync('.jac/venv/bin/python', ['-c', 'import io,sys; from reportlab.pdfgen import canvas; data=io.BytesIO(); c=canvas.Canvas(data); c.drawString(72,720,"Browser QA resume"); c.drawString(72,700,"Experience: built Python services and tested HTTP APIs"); c.showPage(); c.save(); sys.stdout.buffer.write(data.getvalue())']);
 await page.locator('input[type=file]').setInputFiles({name: 'Browser QA.pdf', mimeType: 'application/pdf', buffer: pdf});
 if (process.platform === 'darwin') {
  // The existing bounded document worker supports Linux/Windows only.
  await page.getByRole('alert').filter({hasText: 'PDF'}).waitFor();
  await screenshot('resume-platform-error');
  console.log('LIMIT: macOS backend rejects document processing; upload error verified. Successful upload/rename/download checks require Linux/WSL.');
 } else {
  await visible('Resume uploaded privately. Processing progress appears below.');
  await page.getByRole('button', {name: 'Rename', exact: true}).click();
  await field('Resume name').fill('Browser QA renamed.pdf');
  await page.getByRole('button', {name: 'Save name', exact: true}).click();
  await page.getByRole('heading', {name: 'Browser QA renamed.pdf', exact: true}).waitFor();
  const download = page.waitForEvent('download');
  await page.getByRole('button', {name: 'Download original', exact: true}).click();
  const file = await download; await file.saveAs(path.join(artifacts, 'download.pdf'));
  assert.equal(fs.readFileSync(path.join(artifacts, 'download.pdf')).subarray(0, 5).toString(), '%PDF-');
  await screenshot('resume-desktop');
 }
 // Session drafts survive navigation; real contacts remain distinct from samples.
 await nav('Network').click();
 await page.getByText('Bio', {exact: true}).click();
 await field('Bio draft').fill('A retained browser draft');
 await nav('Jobs').click(); await nav('Network').click();
 assert.equal(await field('Bio draft').inputValue(), 'A retained browser draft');
 await page.getByRole('button', {name: 'Contacts', exact: true}).click();
 await page.getByRole('button', {name: 'Add a contact', exact: true}).click();
 await field('Name').fill('QA Contact');
 await field('Email').fill('browser-qa@example.com');
 await page.getByRole('button', {name: 'Save contact', exact: true}).click();
 await visible('Contact saved. Nothing was sent.');
 assert.equal((await call('agent_contacts')).contacts.length, 1);
 // Narrow viewport, long content, bottom navigation, and keyboard access.
 await page.setViewportSize({width: 390, height: 844});
 await nav('Jobs').click();
 await screenshot('jobs-mobile');
 assert.ok(await page.evaluate(() => document.documentElement.scrollWidth <= innerWidth), 'Jobs overflows narrow viewport');
 const bounds = await nav('Prep').boundingBox();
 assert.ok(bounds.y + bounds.height <= 844 && bounds.y > 700, 'Bottom navigation is offscreen');
 await page.getByRole('button', {name: /Search & filters/}).click();
 await field('Role or keywords').waitFor();
 await page.getByRole('button', {name: /Search & filters/}).click();
 await nav('Jobs').focus(); await page.keyboard.press('Tab'); await page.keyboard.press('Enter');
 await page.getByRole('heading', {name: 'Applications', exact: true}).waitFor();
 await page.goBack();
 await page.getByRole('heading', {name: 'Jobs', exact: true}).waitFor();
 await nav('Prep').click();
 await page.getByRole('heading', {name: 'Practice library', exact: true}).waitFor();
 await page.getByRole('button', {name: 'Start', exact: true}).first().click();
 await field('Your reasoning').fill('Synthetic reasoning saved from the browser');
 await page.getByRole('button', {name: 'Save', exact: true}).click();
 await visible('Saved. Continue on either device.');
 const state = await call('bootstrap');
 assert.equal(state.applications[0].notes, 'Persistent browser test notes');
 assert.equal(state.applications[0].status, 'Submitted');
 assert.equal(state.reminders[0].done, true);
 // Sign out and back in proves persistence and clears session-only drafts.
 await page.getByRole('button', {name: 'Open profile and settings'}).click();
 await page.getByRole('button', {name: 'Sign out', exact: true}).click();
 await field('Username').fill(username);
 await field('Password').fill(password);
 await page.getByRole('button', {name: 'Continue', exact: true}).click();
 await nav('Jobs').waitFor();
 await nav('Network').click();
 await page.getByText('Bio', {exact: true}).click();
 assert.equal(await field('Bio draft').inputValue(), '');
 assert.equal((await call('bootstrap')).applications[0].notes, 'Persistent browser test notes');
 assert.deepEqual(errors, []);
 console.log('PASS: desktop/mobile navigation, real search/save/pass, application notes/retry/submission, calendar/follow-ups, platform-appropriate file checks, contact saving, retained drafts, prep save, and sign-out isolation.');
}
(async () => { try { await run(); } catch (error) { if (page) await screenshot('failure').catch(() => {}); throw error; } finally { if (page && sourceID) await call('discovery_manage', {id: sourceID, action: 'purge'}, true).catch(() => {}); await browser?.close(); } })().catch(error => { console.error(error.message); process.exitCode = 1; });
