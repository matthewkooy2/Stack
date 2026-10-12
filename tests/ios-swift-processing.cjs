const {test, after} = require('node:test');
const assert = require('node:assert/strict');
const {generateKeyPairSync} = require('node:crypto');
const fs = require('node:fs');
const path = require('node:path');
const os = require('node:os');
const {main} = require('../scripts/ci/ios-swift-processing.cjs');
const directory = fs.mkdtempSync(path.join(os.tmpdir(), 'stack-processing-test-'));
const keyPath = path.join(directory, 'fixture.p8');
const {privateKey} = generateKeyPairSync('ec', {namedCurve:'prime256v1'});
fs.writeFileSync(keyPath, privateKey.export({type:'pkcs8',format:'pem'}), {mode:0o600});
after(() => fs.rmSync(directory, {recursive:true, force:true}));
const env = {GITHUB_RUN_NUMBER:'17', GITHUB_RUN_ATTEMPT:'1', ASC_AUTH_KEY_PATH:keyPath,
             ASC_KEY_ID:'FIXTURE', ASC_ISSUER_ID:'fixture'};
function reply(state='IN_BETA_TESTING', version='1017.1', expired=false) {
  return {data:[{id:'build', attributes:{version, processingState:'VALID', expired},
    relationships:{preReleaseVersion:{data:{id:'version'}}, buildBetaDetail:{data:{id:'detail'}}}}],
    included:[{id:'version', type:'preReleaseVersions', attributes:{version:'0.2.0'}},
              {id:'detail', type:'buildBetaDetails', attributes:{internalBuildState:state, externalBuildState:'READY_FOR_BETA_SUBMISSION'}}]};
}
function request(result) {
  return async url => {
    assert.match(url, /^https:\/\/api\.appstoreconnect\.apple\.com\/v1\//);
    if (url.includes('/apps?')) return {ok:true,json:async()=>({data:[{id:'app'}]})};
    assert.match(url, /include=preReleaseVersion,buildBetaDetail/);
    return {ok:true,json:async()=>result};
  };
}
test('exact VALID beta actively available to existing testers completes', async () => {
  await main(env, request(reply()), () => assert.fail('unnecessary wait'));
});
test('VALID alone, missing expiry/detail and a different build cannot pass', async () => {
  const missingExpiry = reply(); delete missingExpiry.data[0].attributes.expired;
  for (const result of [reply('READY_FOR_BETA_TESTING'), reply(undefined, '1018.1'),
    {...reply(), included:reply().included.slice(0,1)}, missingExpiry, reply('IN_BETA_TESTING','1017.1',null)]) {
    await assert.rejects(main(env, request(result), async()=>{}), /remains pending/);
  }
});
test('expired and invalid builds fail rather than claiming tester availability', async () => {
  await assert.rejects(main(env, request(reply('IN_BETA_TESTING','1017.1',true)), async()=>{}), /expired/);
  const invalid = reply(); invalid.data[0].attributes.processingState = 'INVALID';
  await assert.rejects(main(env, request(invalid), async()=>{}), /failed: INVALID/);
});
