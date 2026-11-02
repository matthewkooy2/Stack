// Manual browser-helper checks: no Apple account, external traffic or model calls.
const assert = require('node:assert/strict'), fs = require('node:fs'), path = require('node:path');
async function main() {
 const source = fs.readFileSync(path.join(__dirname, '../web/apple-auth.js'), 'utf8');
 const {beginApple, appleRedirectURI} = await import('data:text/javascript;base64,' + Buffer.from(source).toString('base64'));
 const challenge = {ok: true, state: 'fixture-state', nonce: 'fixture-nonce', client_id: 'com.fixture.stack.web', redirect_uri: 'https://stack.example.com/auth/apple'};
 let config, calls = [];
 const proof = {authorization: {state: challenge.state, id_token: 'fixture-apple-proof'}};
 global.window = {location: {origin: 'https://stack.example.com'}, AppleID: {auth: {init: value => { config = value; }, signIn: async () => proof}}};
 const request = async (route, body, authenticated) => {
  calls.push({route, body, authenticated});
  return {result: route.endsWith('auth_apple_web_begin') ? challenge : {ok: true, token: 'fixture-stack-session', username: 'apple_fixture'}};
 };
 const result = await beginApple(request);
 assert.equal(result.token, 'fixture-stack-session');
 assert.deepEqual(config, {clientId: challenge.client_id, redirectURI: challenge.redirect_uri, state: challenge.state, nonce: challenge.nonce, usePopup: true});
 assert.ok(calls.every(call => call.authenticated === false));
 assert.deepEqual(calls[1].body, {state: challenge.state, identity_token: 'fixture-apple-proof'});
 assert.equal(Object.hasOwn(config, 'scope'), false, 'Do not request email or profile access');
 // Mismatched callbacks never reach the session-issuing endpoint.
 calls = []; window.AppleID.auth.signIn = async () => ({authorization: {...proof.authorization, state: 'another-attempt'}});
 await assert.rejects(() => beginApple(request), /did not match/);
 assert.equal(calls.length, 1);
 window.AppleID.auth.signIn = async () => { throw {error: 'user_cancelled_authorize'}; };
 await assert.rejects(() => beginApple(request), /cancelled/);
 window.AppleID.auth.signIn = async () => { throw {error: 'popup_blocked_by_browser'}; };
 await assert.rejects(() => beginApple(request), /Allow the Apple sign-in popup/);
 // Fail closed when the server is missing configuration, before opening Apple.
 let opened = false; window.AppleID.auth.signIn = async () => { opened = true; return proof; };
 await assert.rejects(() => beginApple(async () => ({result: {ok: false, error: 'Missing Apple configuration'}})), /Missing Apple configuration/);
 assert.equal(opened, false);
 for (const url of ['http://stack.example.com/auth/apple', 'https://127.0.0.1/auth/apple', 'https://localhost/auth/apple', 'https://evil.example/other', 'https://stack.example.com/auth/apple#token', 'https://u:p@stack.example.com/auth/apple']) assert.throws(() => appleRedirectURI(url));
 // Local previews cannot receive Apple's response for the registered HTTPS origin.
 calls = []; opened = false; window.location.origin = 'http://127.0.0.1:18080';
 await assert.rejects(() => beginApple(request), /Open https:\/\/stack.example.com/);
 assert.equal(calls.length, 1); assert.equal(opened, false);
 window.location.origin = 'https://stack.example.com';
 // A pending popup cannot be replaced by a second concurrent request.
 let release; window.AppleID.auth.signIn = () => new Promise(resolve => { release = resolve; });
 const first = beginApple(request);
 while (!release) await new Promise(resolve => setImmediate(resolve));
 await assert.rejects(() => beginApple(request), /already open/);
 release(proof); await first;
 assert.ok(!/sessionStorage|localStorage/.test(source), 'Apple proofs must stay in memory');
 console.log('Apple web helper: signed challenge, popup configuration, proof exchange, cancellation, fail-closed setup and concurrency passed.');
}
main().catch(error => { console.error(error); process.exitCode = 1; });
